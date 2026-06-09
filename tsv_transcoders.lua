-- Module name
local NAME = "tsv_transcoders"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 27, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

-- error_reporting gives us an isolated badVal for the parser/model machinery, so
-- type-parsing of the header and cell re-serialisation report through their own
-- collector instead of mutating the loader's col_types stack (mirrors
-- xml_transcoder / json_transcoders).
local error_reporting = require("error_reporting")

-- deserialization reads one cell value from its alternate encoding (the inverse of
-- the export-side serialisers): `deserialize` for Lua literals, `deserializeJSON`
-- for typed JSON, `deserializeNaturalJSON` for natural JSON. These are exactly the
-- per-cell readers importer.lua already pairs with the export serialisers; this
-- module lifts them into the production loader (TODO/export_format_reimport.md).
local deserialization = require("deserialization")
local deserialize = deserialization.deserialize
local deserializeJSON = deserialization.deserializeJSON
local deserializeNaturalJSON = deserialization.deserializeNaturalJSON

-- serialization holds the matching forward serialisers, used by the reversible
-- `encode` to rewrite a cell back into its alternate encoding (brace/quote mode),
-- exactly as exporter.exportLuaTSV / exportJSONTSV / exportNaturalJSONTSV do.
local serialization = require("serialization")
local serialize = serialization.serialize
local serializeJSON = serialization.serializeJSON
local serializeNaturalJSON = serialization.serializeNaturalJSON

-- parsers / tsv_model are the SAME machinery the loader and reformatter use, so the
-- in-cell form produced for every column (scalars and composites alike) agrees with
-- the rest of the pipeline — no third form. parseType(badVal, typeSpec) ->
-- parser(badVal, value, mode): mode "parsed" turns a Lua value into native cell text.
local parsers = require("parsers")
local parseType = parsers.parseType
local type_parser_partial = parsers.internal.type_parser_partial
local tsv_model = require("tsv_model")
local processTSV = tsv_model.processTSV
local defaultOptionsExtractor = tsv_model.defaultOptionsExtractor
local expressionEvaluatorGenerator = tsv_model.expressionEvaluatorGenerator

local raw_tsv = require("raw_tsv")
local stringToRawTSV = raw_tsv.stringToRawTSV
local rawTSVToString = raw_tsv.rawTSVToString

local string_utils = require("string_utils")
local trim = string_utils.trim

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- TSV-with-alternate-cell-encoding <-> wide-TSV transcoders for the content
-- pipeline (TODO/export_format_reimport.md). These read back the three TSV export
-- variants whose *container* is the native wide TSV but whose *cells* are rendered
-- in an alternate codec (exporter.exportLuaTSV / exportJSONTSV /
-- exportNaturalJSONTSV):
--
--   tsv:lua           cells are Lua literals       {attack=80,defense=40}
--   tsv:json-typed    cells are typed JSON         [0,["attack",{"int":"80"}],...]
--   tsv:json-natural  cells are natural JSON       {"attack":80,"defense":40}
--
-- They share the native TSV's skeleton — the SAME `name:type` header, columns and
-- rows — so the inverse is symmetric: read the identical TSV structure, re-parse
-- each cell from its alternate encoding back to a native Lua value, and emit the
-- native wide TSV the loader's parser expects. The header cells are themselves
-- serialised in the export ("name:identifier"), so they too are read back through
-- the cell codec.
--
-- They are id-selected (never auto-fire by extension — these share the .tsv
-- extension with native data, so auto-matching would be ambiguous and dangerous)
-- and reversible: the reformatter rewrites a tsv:* source from the reformatted wide
-- TSV via `encode`, reached through the id-selected reversibleTranscode path (the
-- reformatter routes a transcoder-assigned .tsv there rather than down the native
-- rewrite). Schema-free: like xml_transcoder, the column names/types come from the
-- file's own header, not a typeName.
-- ============================================================

-- Returns a `fail(msg)` closure that reports via badVal and returns nil, so the
-- forward transcoder can `return fail("…")`. Shared message prefix.
local function failer(name, badVal)
    return function(msg)
        badVal(name, "tsv transcoder: " .. msg .. " in '" .. name .. "'")
        return nil
    end
end

-- A private badVal that collects messages, used to drive parseType / processTSV
-- without touching the loader's badVal (in particular its col_types stack). Pass
-- seedColType=true for the forward path (calling parsers directly, which read
-- col_types[1]); leave it false for processTSV, which pushes its own col_type via
-- withColType and asserts the stack is empty on entry. Mirrors xml_transcoder.
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
-- e.g. {a:integer}, is not mis-split, and a trailing `:default` is dropped). A
-- header cell with no ':' defaults to "string". (Identical to xml_transcoder's.)
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

-- ------------------------------------------------------------
-- Forward: alternate-cell TSV -> native wide TSV.
-- ------------------------------------------------------------

-- Factory: wraps the cell decoder (`deserializeCell(cellText) -> (value, err)`) with
-- the shared TSV-skeleton walk and the content-pipeline transform signature
-- (name, content, env, badVal, ctx). Comment/blank lines (kept by stringToRawTSV as
-- plain strings) pass straight through; the first cell-row is the header. Each
-- non-empty cell is decoded to a Lua value and re-serialised to native text via the
-- column's own parser, so the result is byte-for-byte the wide TSV any other source
-- for that schema would produce. A malformed cell, or a value that won't serialise
-- under its column type, aborts the file via badVal.
local function makeTranscoder(deserializeCell)
    return function(name, content, _env, badVal, _ctx)
        local fail = failer(name, badVal)

        local ok, rawtsv = pcall(stringToRawTSV, content)
        if not ok then return fail("cannot parse TSV: " .. tostring(rawtsv)) end

        local pbad = privateBadVal(true)
        local header                -- sequence of `name:type` strings
        local parserCache = {}      -- column index -> parser (or false if none)
        local out = {}              -- output rows (header first; comments verbatim)

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

        for _, row in ipairs(rawtsv) do
            if type(row) == "string" then
                out[#out + 1] = row             -- comment / blank line: passthrough
            elseif not header then
                -- Header row: each cell is the serialised `name:type` string.
                header = {}
                for i = 1, #row do
                    local v, derr = deserializeCell(row[i])
                    if derr then
                        return fail("could not decode header cell " .. i
                            .. ": " .. tostring(derr))
                    end
                    if type(v) ~= "string" then
                        return fail("header cell " .. i .. " is not a string")
                    end
                    header[i] = v
                end
                out[#out + 1] = header
            else
                local orow = {}
                for i = 1, #header do
                    local cell = row[i]
                    if cell == nil or cell == "" then
                        orow[i] = ""            -- empty/absent -> empty cell
                    else
                        local v, derr = deserializeCell(cell)
                        if derr then
                            return fail("could not decode cell " .. i
                                .. ": " .. tostring(derr))
                        end
                        if v == nil then
                            orow[i] = ""        -- decoded to nil (e.g. JSON null)
                        else
                            local parser = getParser(i)
                            if parser then
                                local _parsed, reformatted = parser(pbad, v, "parsed")
                                orow[i] = reformatted
                            else
                                orow[i] = tostring(v)
                            end
                        end
                    end
                end
                out[#out + 1] = orow
            end
        end

        if not header then return fail("no header row") end
        if pbad.errors > 0 then
            return fail("could not re-serialise a cell to its column type")
        end

        local ok2, tsvText = pcall(rawTSVToString, out)
        if not ok2 then return fail("cannot serialise to TSV: " .. tostring(tsvText)) end
        return tsvText
    end
end

-- ------------------------------------------------------------
-- Reverse: native wide TSV -> alternate-cell TSV (reversible `encode`).
-- ------------------------------------------------------------

-- Parses native wide-TSV text into a typed model with the loader's machinery (so
-- every cell's parsed Lua value is available). Returns (file, header) or
-- (nil, errmsg). Mirrors json_transcoders.parseWideTSV / xml_transcoder.tsvToXml.
local function parseWideTSV(content)
    local ok, rawtsv = pcall(stringToRawTSV, content)
    if not ok then return nil, "cannot parse TSV: " .. tostring(rawtsv) end

    local pbad, msgs = privateBadVal()
    local loadEnv = {files = {}}
    local expr_eval = expressionEvaluatorGenerator(loadEnv)
    local file = processTSV(defaultOptionsExtractor, expr_eval, parseType,
        "tsv-encode", rawtsv, pbad, {}, false, nil)
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
    return file, header
end

-- Factory: wraps the cell encoder (`serializeCell(value, nilAsEmpty) -> text`) with
-- the shared wide-TSV parse and the content-pipeline encode signature
-- (content, env, badVal). The header `name:type` cells are re-serialised through the
-- same codec (matching the export, which serialises every cell including the
-- header), so the output is a faithful tsv:* file. Returns (tsvText) or
-- (nil, reason), matching the transcode `encode` contract.
local function makeEncoder(serializeCell)
    return function(content, _env, _badVal)
        local file, headerOrErr = parseWideTSV(content)
        if not file then return nil, headerOrErr end   -- headerOrErr holds the error

        local header = headerOrErr
        local out = {}
        local hrow = {}
        for i, col in ipairs(header) do
            hrow[i] = serializeCell(col.parsed, true)
        end
        out[1] = hrow
        for r = 2, #file do
            local row = file[r]
            if type(row) == "table" then
                local orow = {}
                for i = 1, #header do
                    local cell = row[i]
                    orow[i] = serializeCell(cell and cell.parsed, true)
                end
                out[#out + 1] = orow
            end
        end

        local ok, text = pcall(rawTSVToString, out)
        if not ok then return nil, "cannot serialise TSV: " .. tostring(text) end
        return text
    end
end

-- The forward transforms (one per cell codec).
local luaToTSV         = makeTranscoder(deserialize)
local jsonTypedToTSV   = makeTranscoder(deserializeJSON)
local jsonNaturalToTSV = makeTranscoder(deserializeNaturalJSON)

-- The reverse encoders (the inverse export serialiser per codec; brace/quote mode
-- on, matching exporter.exportLuaTSV / exportJSONTSV / exportNaturalJSONTSV).
local tsvToLua         = makeEncoder(serialize)
local tsvToJsonTyped   = makeEncoder(serializeJSON)
local tsvToJsonNatural = makeEncoder(serializeNaturalJSON)

-- ============================================================
-- Public API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    luaToTSV = luaToTSV,
    jsonTypedToTSV = jsonTypedToTSV,
    jsonNaturalToTSV = jsonNaturalToTSV,
    tsvToLua = tsvToLua,
    tsvToJsonTyped = tsvToJsonTyped,
    tsvToJsonNatural = tsvToJsonNatural,
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
