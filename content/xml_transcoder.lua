-- Module name
local NAME = "xml_transcoder"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 28, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

-- error_reporting gives us an isolated badVal for the parser/model machinery, so
-- type-parsing of the header and cell (de)serialisation report through their own
-- collector instead of mutating the loader's col_types stack.
local error_reporting = require("infra.error_reporting")

-- deserialization.deserializeXML decodes one typed XML cell value (the inverse of
-- serialization.serializeXML), advancing past it — including nested <table> cells
-- (the inverse of serializeTableXML), which is how composite cells round-trip.
local deserialization = require("serde.deserialization")
local deserializeXML = deserialization.deserializeXML

-- serialization.serializeXML re-emits a Lua value as a typed XML element (handles
-- <table>); the reverse encode reuses it per cell, exactly as exporter.exportXML.
local serialization = require("serde.serialization")
local serializeXML = serialization.serializeXML

-- parsers / tsv_model are the SAME machinery the loader and reformatter use, so
-- the in-cell form the transcoder produces/consumes for every column (scalars and
-- composites alike) agrees with the rest of the pipeline — no third form.
--   parseType(badVal, typeSpec) -> parser(badVal, value, mode) -> (parsed, reformatted)
--     mode "parsed": value is a Lua value  -> `reformatted` is the native cell text
--     mode "tsv":    value is native text  -> `parsed` is the Lua value
local parsers = require("parsers")
local parseType = parsers.parseType
local type_parser_partial = parsers.internal.type_parser_partial
local tsv_model = require("tsv.tsv_model")
local processTSV = tsv_model.processTSV
local defaultOptionsExtractor = tsv_model.defaultOptionsExtractor

local raw_tsv = require("tsv.raw_tsv")
local stringToRawTSV = raw_tsv.stringToRawTSV
local rawTSVToString = raw_tsv.rawTSVToString

local string_utils = require("util.string_utils")
local trim = string_utils.trim

-- The TabuLua table namespace baked into every exported <file> (see
-- TODO/xml_input_round_trip.md and exporter.exportXML). The transcoder verifies
-- the root carries it before treating an .xml file as data — defense-in-depth on
-- top of the explicit id-only selection.
local NAMESPACE = "urn:tabulua:table:1"

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- XML <-> wide-TSV transcoder for the content pipeline
-- (TODO/xml_input_round_trip.md). Mirrors eav_transcoder in shape — a forward
-- `transform` (xmlToTSV) plus a reversible `encode` (tsvToXml) — but is
-- id-selected (never auto-fires on a stray .xml), schema-free (column
-- names/types come from the file's own <header>, not a typeName), and namespaced
-- (the root's xmlns answers "is this XML ours?").
-- ============================================================

-- Returns a `fail(msg)` closure that reports via badVal and returns nil, so the
-- forward transcoder can `return fail("…")`. Shared message prefix.
local function failer(name, badVal)
    return function(msg)
        badVal(name, "xml transcoder: " .. msg .. " in '" .. name .. "'")
        return nil
    end
end

-- A private badVal that collects messages, used to drive parseType / processTSV
-- without touching the loader's badVal (in particular its col_types stack). Pass
-- seedColType=true for the forward path (calling parsers directly, which read
-- col_types[1]); leave it false for processTSV, which pushes its own col_type via
-- withColType and asserts the stack is empty on entry.
local function privateBadVal(seedColType)
    local msgs = {}
    local bv = error_reporting.badValGen(function(_self, m) msgs[#msgs + 1] = m end)
    bv.logger = error_reporting.nullLogger
    if seedColType then
        bv.col_types = {''}
    end
    return bv, msgs
end

-- Extracts the type-spec from a `name:type[:default]` header cell, using the same
-- partial type parser tsv_model.newHeaderColumn uses (so a type containing ':',
-- e.g. {a:integer}, is not mis-split, and a trailing `:default` is dropped).
-- A header cell with no ':' defaults to "string".
local function columnTypeSpec(headerCell)
    local pos = headerCell:find(":", 1, true)
    if not pos then return "string" end
    local after = headerCell:sub(pos + 1)
    local parsed_type, remainder = type_parser_partial(after)
    if parsed_type and remainder and remainder ~= "" then
        return trim(after:sub(1, -(#remainder + 1)))
    end
    local spec = trim(after)
    if spec == "" then return "string" end
    return spec
end

-- Locates the opening <file ...> tag, validates its namespace, and returns the
-- document body (between the opening tag and </file>). Returns (body) or, on a
-- structural / namespace problem, (nil, message).
local function fileBody(content)
    local fileOpen = content:find("<file", 1, true)
    if not fileOpen then
        return nil, "missing <file> root element"
    end
    local openEnd = content:find(">", fileOpen, true)
    if not openEnd then
        return nil, "malformed <file> opening tag"
    end
    local openTag = content:sub(fileOpen, openEnd)
    local ns = openTag:match('xmlns%s*=%s*"([^"]*)"')
        or openTag:match("xmlns%s*=%s*'([^']*)'")
    if ns ~= NAMESPACE then
        return nil, "root <file> is not in the TabuLua namespace '" .. NAMESPACE
            .. "' (found " .. (ns and ("'" .. ns .. "'") or "no namespace")
            .. "); this XML is not a TabuLua data file"
    end
    local dataEnd = content:find("</file>", openEnd, true)
    if not dataEnd then
        return nil, "missing </file> closing tag"
    end
    if openEnd >= dataEnd then
        return nil, "malformed <file> opening tag"
    end
    return content:sub(openEnd + 1, dataEnd - 1)
end

-- Parses the cells of one <header>/<row> body into a sequence of Lua values,
-- decoding each typed XML element (including nested <table>) via deserializeXML.
-- Returns (cells, count) or (nil, errmsg). count is the explicit cell count so a
-- trailing <null/> (nil) cell is not lost.
local function parseCells(inner)
    local cells = {}
    local count = 0
    local pos = 1
    while pos <= #inner do
        pos = inner:match("^%s*()", pos)
        if pos > #inner then break end
        local val, newPos, err = deserializeXML(inner:sub(pos))
        if err then
            return nil, err
        end
        if not newPos then break end
        count = count + 1
        cells[count] = val
        pos = pos + newPos - 1
    end
    return cells, count
end

-- Walks the <header>/<row> elements of the document body, invoking
-- visit(tagName, cells, count) for each. Returns true, or (nil, errmsg).
local function eachRow(body, visit)
    local pos = 1
    while pos <= #body do
        pos = body:match("^%s*()", pos)
        if pos > #body then break end
        local tagStart, tagEnd, tagName = body:find("<(header)>", pos)
        if not tagStart or tagStart ~= pos then
            tagStart, tagEnd, tagName = body:find("<(row)>", pos)
        end
        if not tagStart or tagStart ~= pos then
            -- Anything other than a <header>/<row> at this position is unexpected.
            return nil, "unexpected content at position " .. pos
        end
        local closeTag = "</" .. tagName .. ">"
        local closeStart = body:find(closeTag, tagEnd + 1, true)
        if not closeStart then
            return nil, "missing closing </" .. tagName .. "> tag"
        end
        local inner = body:sub(tagEnd + 1, closeStart - 1)
        local cells, count = parseCells(inner)
        if not cells then
            return nil, count   -- count holds the error message
        end
        local ok, verr = visit(tagName, cells, count)
        if not ok then
            return nil, verr
        end
        pos = closeStart + #closeTag
    end
    return true
end

-- xmlToTSV — forward source transform. Reads a namespaced <file>/<header>/<row>
-- document and rebuilds the wide, typed TSV. The <header>'s `name:type` cells
-- become the typed TSV header verbatim; each <row>'s typed cells (including
-- composite <table> cells) are decoded to Lua values and re-serialised into the
-- native in-cell form via the column's own parser, so the result is byte-for-byte
-- the same wide TSV any other source for that schema would produce. Schema-free:
-- no ctx.typeName is consulted. A wrong namespace, a malformed document, or a
-- value that won't serialise under its column type aborts the file via badVal.
local function xmlToTSV(name, content, _env, badVal, _ctx)
    local fail = failer(name, badVal)

    local body, err = fileBody(content)
    if not body then return fail(err) end

    local pbad = privateBadVal(true)
    local header                -- sequence of `name:type` strings
    local parserCache = {}      -- column index -> parser (or false if none)
    local rows = {}             -- output rows (header first)

    local function getParser(colIdx)
        local cached = parserCache[colIdx]
        if cached ~= nil then
            return cached or nil
        end
        local typeSpec = columnTypeSpec(header[colIdx] or "")
        local p = parseType(pbad, typeSpec)
        parserCache[colIdx] = p or false
        return p
    end

    local ok, verr = eachRow(body, function(tagName, cells, count)
        if tagName == "header" then
            if header then
                return nil, "more than one <header> element"
            end
            header = {}
            for i = 1, count do
                local h = cells[i]
                if type(h) ~= "string" then
                    return nil, "header cell " .. i .. " is not a string"
                end
                header[i] = h
            end
            rows[1] = header
            return true
        end
        -- data row
        if not header then
            return nil, "<row> before <header>"
        end
        local out = {}
        for i = 1, #header do
            local value = cells[i]
            if value == nil then
                out[i] = ""             -- <null/> / absent -> empty cell
            else
                local parser = getParser(i)
                if parser then
                    local _parsed, reformatted = parser(pbad, value, "parsed")
                    out[i] = reformatted
                else
                    -- Unknown column type (no parser): keep a plain rendering.
                    out[i] = tostring(value)
                end
            end
        end
        rows[#rows + 1] = out
        return true
    end)
    if not ok then return fail(verr) end
    if not header then return fail("no <header> element") end
    if pbad.errors > 0 then
        return fail("could not re-serialise a cell to its column type")
    end

    local ok2, tsvText = pcall(rawTSVToString, rows)
    if not ok2 then return fail("cannot serialise to TSV: " .. tostring(tsvText)) end
    return tsvText
end

-- tsvToXml — reversible `encode` (round-trip on reformat). Takes the reformatted
-- wide TSV text, parses it into a typed model with the SAME machinery the loader
-- uses (so every cell's parsed Lua value is available), and regenerates the
-- namespaced <file> document by serialising each cell with serializeXML — exactly
-- the wrapping/cell encoding exporter.exportXML uses. Returns (xmlText) or
-- (nil, reason), matching the decode/transcode `encode` contract.
local function tsvToXml(content, _env, _badVal)
    local ok, rawtsv = pcall(stringToRawTSV, content)
    if not ok then return nil, "cannot parse TSV: " .. tostring(rawtsv) end

    local pbad, msgs = privateBadVal()
    local loadEnv = {files = {}}
    local expr_eval = tsv_model.expressionEvaluatorGenerator(loadEnv)
    local file = processTSV(defaultOptionsExtractor, expr_eval, parseType,
        "xml-encode", rawtsv, pbad, {}, false, nil)
    if not file then
        return nil, "cannot parse wide TSV: " .. (msgs[1] or "unknown error")
    end
    if pbad.errors > 0 then
        return nil, "wide TSV did not validate: " .. (msgs[1] or "unknown error")
    end

    local header = file[1]
    if not header then
        return nil, "wide TSV has no header"
    end

    local out = {'<?xml version="1.0" encoding="UTF-8"?>',
        '<file xmlns="' .. NAMESPACE .. '">'}

    -- Header: the column specs (name:type[:default]) as <string> cells.
    local hcells = {"<header>"}
    for _, col in ipairs(header) do
        hcells[#hcells + 1] = serializeXML(col.parsed, false)
    end
    hcells[#hcells + 1] = "</header>"
    out[#out + 1] = table.concat(hcells)

    -- Data rows.
    for r = 2, #file do
        local row = file[r]
        if type(row) == "table" then
            local rcells = {"<row>"}
            for _, cell in ipairs(row) do
                rcells[#rcells + 1] = serializeXML(cell.parsed, false)
            end
            rcells[#rcells + 1] = "</row>"
            out[#out + 1] = table.concat(rcells)
        end
    end

    out[#out + 1] = "</file>"
    return table.concat(out, "\n")
end

-- ============================================================
-- Public API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    xmlToTSV = xmlToTSV,
    tsvToXml = tsvToXml,
    NAMESPACE = NAMESPACE,
}

local function apiCall(_, operation, ...)
    if operation == "version" then
        return VERSION
    elseif API[operation] then
        return API[operation](...)
    else
        error("Unknown operation: " .. tostring(operation), 2)
    end
end

return readOnly(API, {__tostring = apiToString, __call = apiCall, __type = NAME})
