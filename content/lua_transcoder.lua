-- Module name
local NAME = "lua_transcoder"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 32, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

-- error_reporting gives us an isolated badVal for the parser/model machinery, so
-- type-parsing of the header and cell re-serialisation report through their own
-- collector instead of mutating the loader's col_types stack (mirrors
-- xml_transcoder / tsv_transcoders).
local error_reporting = require("infra.error_reporting")

-- The .lua data file is EXECUTED (it is `return { … }` Lua source), so it runs in
-- the same sandbox + instruction-quota machinery code libraries use
-- (manifest_info.loadCodeLibrary): sandbox.protect compiles under a restricted env,
-- and the quota bounds a hostile data file that loops instead of just building a
-- literal table (content_pipeline.md §3.7).
local sandbox = require("sandbox")
local sandbox_env = require("infra.sandbox_env")

-- serialization re-renders each cell on the reverse path: exporter.exportLua uses
-- serialize(value, false) (nil -> the literal `nil`, not an empty string), so the
-- reverse encode matches the export byte-for-byte at the cell level.
local serialization = require("serde.serialization")
local serialize = serialization.serialize

-- parsers / tsv_model are the SAME machinery the loader and reformatter use, so the
-- in-cell form produced for every column agrees with the rest of the pipeline.
-- parseType(badVal, typeSpec) -> parser(badVal, value, mode); mode "parsed" turns a
-- Lua value into native cell text.
local parsers = require("parsers")
local parseType = parsers.parseType
local type_parser_partial = parsers.internal.type_parser_partial
local tsv_model = require("tsv.tsv_model")
local processTSV = tsv_model.processTSV
local defaultOptionsExtractor = tsv_model.defaultOptionsExtractor
local expressionEvaluatorGenerator = tsv_model.expressionEvaluatorGenerator

local raw_tsv = require("tsv.raw_tsv")
local stringToRawTSV = raw_tsv.stringToRawTSV
local rawTSVToString = raw_tsv.rawTSVToString

local string_utils = require("util.string_utils")
local trim = string_utils.trim

-- Instruction-quota floor for executing a .lua data file. A literal `return { … }`
-- table costs roughly one VM op per element, so the quota is scaled by the file
-- size (with this floor) — ample for any honest data file, while a hostile file
-- that loops instead of returning a literal aborts well before it can hang the
-- load. Mirrors the bounded execution of manifest_info.loadCodeLibrary.
local QUOTA_FLOOR = 1000000

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- Lua-file <-> wide-TSV transcoder for the content pipeline
-- (TODO/export_format_reimport.md). Reads back TabuLua's `--file=lua` export — a
-- single `return { <header>, <row>, <row>, … }` table (sequence of sequences), row
-- 1 being the `name:type` header — the inverse of exporter.exportLua. A Lua
-- application can export its data this way and read it straight back with the
-- native `load`, no TSV reader needed on its side; this stage gives the *engine*
-- the same round-trip.
--
-- It is id-only (id="lua:tabulua", no `extensions`): a `.lua` is a CODE LIBRARY to
-- the loader by default, so a data .lua must be opted in explicitly with
-- transcoder=lua:tabulua in Files.tsv — it never auto-fires. inputExtensions={"lua"}
-- is a guard, not a matcher. Schema-free: column names/types come from the file's
-- own header (row 1), not a typeName. Reversible: the reformatter rewrites the .lua
-- source from the reformatted wide TSV via `encode` (a .lua misses the native-TSV
-- rewrite branch, so no reformatter change is needed — like .xml/.eav).
-- ============================================================

-- Returns a `fail(msg)` closure that reports via badVal and returns nil, so the
-- forward transcoder can `return fail("…")`. Shared message prefix.
local function failer(name, badVal)
    return function(msg)
        badVal(name, "lua transcoder: " .. msg .. " in '" .. name .. "'")
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
-- e.g. {a:integer}, is not mis-split, and a trailing `:default` is dropped). A
-- header cell with no ':' defaults to "string". (Identical to xml/tsv transcoders.)
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

-- Executes the `return { … }` source in the sandbox under an instruction quota and
-- returns the resulting table, or (nil, errmsg). The table must be a
-- sequence-of-sequences (row 1 = header). A compile error, a runtime error (incl.
-- exceeding the quota), or a non-table result all report a clear reason.
local function loadLuaTable(content)
    local quota = math.max(QUOTA_FLOOR, #content * 16)
    local ok, fn = pcall(sandbox.protect, content, {quota = quota, env = sandbox_env.new()})
    if not ok then
        return nil, "cannot compile: " .. tostring(fn)
    end
    local ranOk, result = pcall(fn)
    if not ranOk then
        return nil, "cannot execute: " .. tostring(result)
    end
    if type(result) ~= "table" then
        return nil, "the file must `return` a table (sequence of rows), got "
            .. type(result)
    end
    return result
end

-- luaToTSV — forward source transform. Loads the `return { <header>, <row>, … }`
-- table; row 1 is the typed `name:type` header (already strings — the export
-- serialised them as Lua string literals); each later row's cells are already
-- native Lua values, re-serialised to the native in-cell form via the column's own
-- parser so the result is byte-for-byte the wide TSV any other source for that
-- schema would produce. Schema-free: no ctx.typeName is consulted.
local function luaToTSV(name, content, _env, badVal, _ctx)
    local fail = failer(name, badVal)

    local data, err = loadLuaTable(content)
    if not data then return fail(err) end

    local header = data[1]
    if type(header) ~= "table" then
        return fail("first element must be the header row (a sequence of name:type strings)")
    end

    local pbad = privateBadVal(true)
    local out = {}
    local hrow = {}
    for i = 1, #header do
        local h = header[i]
        if type(h) ~= "string" then
            return fail("header cell " .. i .. " is not a string")
        end
        hrow[i] = h
    end
    out[1] = hrow

    local parserCache = {}
    local function getParser(colIdx)
        local cached = parserCache[colIdx]
        if cached ~= nil then
            return cached or nil
        end
        local p = parseType(pbad, columnTypeSpec(hrow[colIdx] or ""))
        parserCache[colIdx] = p or false
        return p
    end

    for r = 2, #data do
        local row = data[r]
        if type(row) ~= "table" then
            return fail("row " .. r .. " is not a sequence")
        end
        local orow = {}
        for i = 1, #hrow do
            local value = row[i]
            if value == nil then
                orow[i] = ""                -- absent / nil -> empty cell
            else
                local parser = getParser(i)
                if parser then
                    local _parsed, reformatted = parser(pbad, value, "parsed")
                    orow[i] = reformatted
                else
                    orow[i] = tostring(value)
                end
            end
        end
        out[#out + 1] = orow
    end

    if pbad.errors > 0 then
        return fail("could not re-serialise a cell to its column type")
    end

    local ok, tsvText = pcall(rawTSVToString, out)
    if not ok then return fail("cannot serialise to TSV: " .. tostring(tsvText)) end
    return tsvText
end

-- Parses native wide-TSV text into a typed model with the loader's machinery (so
-- every cell's parsed Lua value is available). Returns (file, header) or
-- (nil, errmsg). Mirrors tsv_transcoders / xml_transcoder.
local function parseWideTSV(content)
    local ok, rawtsv = pcall(stringToRawTSV, content)
    if not ok then return nil, "cannot parse TSV: " .. tostring(rawtsv) end

    local pbad, msgs = privateBadVal()
    local loadEnv = {files = {}}
    local expr_eval = expressionEvaluatorGenerator(loadEnv)
    local file = processTSV(defaultOptionsExtractor, expr_eval, parseType,
        "lua-encode", rawtsv, pbad, {}, false, nil)
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

-- Serialises one model row (sequence of cells with .parsed) as a Lua table literal
-- `{v1,v2,…}`, each cell via serialize(value, false) — matching exporter.exportLua
-- (a nil cell becomes the literal `nil`, not an empty string).
local function rowLiteral(cells, count)
    local parts = {}
    for i = 1, count do
        local cell = cells[i]
        parts[i] = serialize(cell and cell.parsed, false)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- tsvToLua — reversible `encode`. Re-parses the reformatted wide TSV and regenerates
-- the `return { <header>, <row>, … }` document, exactly as exporter.exportLua: the
-- header `name:type` cells and every data cell are re-serialised through `serialize`.
-- Returns (luaText) or (nil, reason), matching the transcode `encode` contract.
local function tsvToLua(content, _env, _badVal)
    local file, headerOrErr = parseWideTSV(content)
    if not file then return nil, headerOrErr end   -- headerOrErr holds the error

    local header = headerOrErr
    local lines = {rowLiteral(header, #header)}
    for r = 2, #file do
        local row = file[r]
        if type(row) == "table" then
            lines[#lines + 1] = rowLiteral(row, #header)
        end
    end
    return "return {\n" .. table.concat(lines, ",\n") .. "\n}"
end

-- ============================================================
-- Public API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    luaToTSV = luaToTSV,
    tsvToLua = tsvToLua,
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
