-- Module name
local NAME = "sql_transcoder"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 33, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

-- error_reporting gives us an isolated badVal for the parser/model machinery, so
-- type-parsing of the header and cell re-serialisation report through their own
-- collector instead of mutating the loader's col_types stack (mirrors
-- xml_transcoder / tsv_transcoders).
local error_reporting = require("infra.error_reporting")

-- importer.parseSQLContent is the SQL text parser -- the same one the round-trip
-- tooling uses -- and it already reads the embedded tabulua_schema table,
-- returning the schema as its third result. This module is the pipeline's
-- adapter over it, not a second parser. NOTE: the pure-Lua text parser only;
-- lsqlite3 is deliberately not involved, so a .sql loads identically whether or
-- not that rock happens to be installed (TODO/sql_input_round_trip.md).
local importer = require("serde.importer")
local parseSQLContent = importer.parseSQLContent

-- The per-cell decoders for the four cell encodings a .sql export can carry
-- (--data=json-typed | json-natural | xml | mpk). Which one a file uses is NOT
-- sniffable from the SQL, so the stage id says it -- exactly as tsv:* does.
local deserialization = require("serde.deserialization")
local deserializeJSON = deserialization.deserializeJSON
local deserializeNaturalJSON = deserialization.deserializeNaturalJSON
local deserializeXML = deserialization.deserializeXML
local deserializeMessagePackSQLBlob = deserialization.deserializeMessagePackSQLBlob

-- parsers / raw_tsv are the SAME machinery the loader and reformatter use, so
-- the in-cell form produced for every column (scalars and composites alike)
-- agrees with the rest of the pipeline -- no third form.
local parsers = require("parsers")
local parseType = parsers.parseType
local extendsOrRestrict = parsers.extendsOrRestrict

local tsv_model = require("tsv.tsv_model")
local processTSV = tsv_model.processTSV
local defaultOptionsExtractor = tsv_model.defaultOptionsExtractor
local expressionEvaluatorGenerator = tsv_model.expressionEvaluatorGenerator

local raw_tsv = require("tsv.raw_tsv")
local rawTSVToString = raw_tsv.rawTSVToString
local stringToRawTSV = raw_tsv.stringToRawTSV

-- The writer half. tableSQL emits the metadata block, the CREATE TABLE and the
-- INSERT exactly as exporter.exportSQL assembles them, so a reformatted .sql is
-- byte-identical to the exported one it came from.
local sql_schema = require("serde.sql_schema")
local tableSQL = sql_schema.tableSQL

-- The composite-cell serialisers, one per --data encoding: the forward pairing
-- of the four deserialisers above, and the same functions exportSQL is handed.
local serialization = require("serde.serialization")

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- SQL -> wide-TSV transcoder for the content pipeline
-- (TODO/sql_input_round_trip.md). Reads back exporter.exportSQL's output: a
-- CREATE TABLE + INSERT pair, preceded by the embedded `tabulua_schema` table
-- that carries the model column names, their type_specs and their defaults.
--
-- Shaped like tsv_transcoders -- one factory over four cell codecs -- because
-- the situation is the same: the container is unambiguous, the CELL encoding is
-- not sniffable, so the id names it (sql:json-typed, sql:json-natural, sql:xml,
-- sql:mpk).
--
-- Id-only selection: a .sql is never auto-interpreted as data. That id is also
-- the "is this file ours?" marker in the sense that the AUTHOR opted in; the
-- file's own answer is the presence of tabulua_schema, which SQL has no
-- namespace to express (where .xml has xmlns).
-- ============================================================

-- Returns a `fail(msg)` closure that reports via badVal and returns nil, so the
-- forward transcoder can `return fail("…")`. Shared message prefix.
local function failer(name, badVal)
    return function(msg)
        badVal(name, "sql transcoder: " .. msg .. " in '" .. name .. "'")
        return nil
    end
end

-- A private badVal that collects messages, used to drive parseType / processTSV
-- without touching the loader's badVal (in particular its col_types stack). Pass
-- seedColType=true for the forward path (calling parsers directly, which read
-- col_types[1]); leave it false for processTSV, which pushes its own col_type
-- via withColType and asserts the stack is empty on entry. Mirrors
-- xml_transcoder / tsv_transcoders.
local function privateBadVal(seedColType)
    local msgs = {}
    local bv = error_reporting.badValGen(function(_self, m) msgs[#msgs + 1] = m end)
    bv.logger = error_reporting.nullLogger
    if seedColType then
        bv.col_types = {''}
    end
    return bv, msgs
end

-- The header cell for a metadata column: `name:type[:default]`, the same
-- spelling a native wide TSV uses. The default is carried because the metadata
-- table has a column for it -- the retired type comment did not, so it was lost.
local function headerCell(col)
    local cell = col.name .. ":" .. col.typeSpec
    if col.default ~= nil and col.default ~= "" then
        cell = cell .. ":" .. col.default
    end
    return cell
end

-- True if a column's declared type is a boolean (or extends one).
--
-- SQL has no boolean: exportSQL writes a SMALLINT holding 1 or 0
-- (serialization.serializeSQL), so the value coming back is a NUMBER where the
-- model wants a boolean, and the column's own parser would reject it. This is
-- the one type whose SQL representation is not also its model value.
local function isBooleanColumn(typeSpec)
    local base = typeSpec:match("^(.+)|nil$") or typeSpec
    return base == "boolean" or extendsOrRestrict(base, "boolean")
end

-- Factory: wraps a cell decoder (the deserializer parseSQLContent uses for
-- composite cells) in the content-pipeline transform signature
-- (name, content, env, badVal, ctx).
--
-- The embedded schema is the source of truth: the header is rebuilt from it
-- (model names, type_specs, defaults, in stored position order) and each value
-- is re-serialised to native cell text through the column's OWN parser, so the
-- result is byte-for-byte the wide TSV any other source for that schema would
-- produce. Schema-free in the loader's sense: no ctx.typeName is consulted.
local function makeTranscoder(tableDeserializer)
    return function(name, content, _env, badVal, _ctx)
        local fail = failer(name, badVal)

        -- Every structural refusal the reader can make -- no data table, two of
        -- them, metadata that does not match the table, a malformed literal --
        -- arrives here as a message, and aborts the file.
        local rows, err, schema = parseSQLContent(content, tableDeserializer)
        if not rows then return fail(err) end

        if not schema then
            return fail("no '" .. sql_schema.METADATA_TABLE .. "' table, so the "
                .. "model column names and types cannot be recovered (SQL alone "
                .. "cannot spell 'stats.attack', and BIGINT cannot say whether a "
                .. "column was integer or int64); re-export with a current "
                .. "TabuLua")
        end
        if schema.collapsed then
            return fail("written with --collapse-exploded, so each exploded "
                .. "group is one composite column and the model's header would "
                .. "be spelled differently from the source it came from "
                .. "('stats', not 'stats.attack'); re-export without that flag "
                .. "to import it")
        end

        local pbad, pmsgs = privateBadVal(true)
        local parserCache = {}      -- column index -> parser (or false if none)
        local function getParser(colIdx)
            local cached = parserCache[colIdx]
            if cached ~= nil then
                return cached or nil
            end
            local p = parseType(pbad, schema.columns[colIdx].typeSpec)
            parserCache[colIdx] = p or false
            return p
        end

        local out = {}
        local header = {}
        for i, col in ipairs(schema.columns) do
            header[i] = headerCell(col)
        end
        out[1] = header

        for r = 2, #rows do
            local row = rows[r]
            local orow = {}
            for i = 1, #header do
                local value = row[i]
                if value == nil then
                    orow[i] = ""            -- NULL / absent -> empty cell
                else
                    if type(value) == "number"
                        and isBooleanColumn(schema.columns[i].typeSpec) then
                        value = value ~= 0
                    end
                    local parser = getParser(i)
                    if parser then
                        local _parsed, reformatted = parser(pbad, value, "parsed")
                        orow[i] = reformatted
                    else
                        -- Unknown column type (no parser): keep a plain rendering.
                        orow[i] = tostring(value)
                    end
                end
            end
            out[#out + 1] = orow
        end

        if pbad.errors > 0 then
            -- Carry the underlying reason: "a cell would not serialise" on its
            -- own leaves the author with a whole file to search.
            return fail("could not re-serialise a cell to its column type: "
                .. (pmsgs[1] or "unknown error"))
        end

        local ok, tsvText = pcall(rawTSVToString, out)
        if not ok then return fail("cannot serialise to TSV: " .. tostring(tsvText)) end
        return tsvText
    end
end

-- ------------------------------------------------------------
-- Reverse: native wide TSV -> .sql (the reversible `encode`).
-- ------------------------------------------------------------

-- Factory: wraps a composite-cell serialiser in the content-pipeline encode
-- signature (content, env, badVal, fileName).
--
-- The reformatter hands back the REFORMATTED wide TSV, which is parsed with the
-- loader's own machinery (so every cell's parsed Lua value is available) and
-- re-emitted through sql_schema.tableSQL -- the same writer exporter.exportSQL
-- assembles, so reformatting an exported .sql is a no-op rather than a
-- reshuffle. The table is named for the file, which is why the file name is
-- part of the encode contract.
--
-- NORMALIZING, not byte-preserving, as for json/xml: a `.sql` has no
-- representation for the `__comment` placeholder rows the native TSV
-- reformatter keeps, so comment ROWS are lost. (Column defaults are not: the
-- metadata table carries them.)
local function makeEncoder(tableSerializer)
    return function(content, _env, _badVal, fileName)
        local ok, rawtsv = pcall(stringToRawTSV, content)
        if not ok then return nil, "cannot parse TSV: " .. tostring(rawtsv) end

        local pbad, msgs = privateBadVal()
        local expr_eval = expressionEvaluatorGenerator({files = {}})
        local file = processTSV(defaultOptionsExtractor, expr_eval, parseType,
            fileName or "sql-encode", rawtsv, pbad, {}, false, nil)
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

        local rows = {}
        for r = 2, #file do
            local row = file[r]
            if type(row) == "table" then
                local values = {}
                for i = 1, #header do
                    local cell = row[i]
                    -- NOT `cell and cell.parsed or nil`: a parsed FALSE is a
                    -- value, and that idiom turns it into nil -- which wrote
                    -- NULL into a NOT NULL boolean column, so the file no
                    -- longer re-read. Holes stay holes (cellSQL -> NULL).
                    if cell ~= nil then
                        values[i] = cell.parsed
                    end
                end
                rows[#rows + 1] = values
            end
        end

        local ok2, text = pcall(tableSQL, header, rows, fileName or "",
            tableSerializer)
        if not ok2 then return nil, "cannot serialise SQL: " .. tostring(text) end
        return text
    end
end

-- The forward transforms (one per cell codec), pairing with the --data flag
-- that produced the file: exportSQL's tableSerializer and this deserializer are
-- the two halves of one encoding.
local sqlJsonTypedToTSV   = makeTranscoder(deserializeJSON)
local sqlJsonNaturalToTSV = makeTranscoder(deserializeNaturalJSON)
local sqlXmlToTSV         = makeTranscoder(deserializeXML)
local sqlMpkToTSV         = makeTranscoder(deserializeMessagePackSQLBlob)

-- The reverse encoders: the same serialisers reformatter.lua hands exportSQL
-- for each --data (its DATA_FORMATS[...].sqlTableSerializer).
local tsvToSqlJsonTyped   = makeEncoder(serialization.serializeTableJSON)
local tsvToSqlJsonNatural = makeEncoder(serialization.serializeTableNaturalJSON)
local tsvToSqlXml         = makeEncoder(serialization.serializeTableXML)
local tsvToSqlMpk         = makeEncoder(serialization.serializeMessagePackSQLBlob)

-- ============================================================
-- Public API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    sqlJsonTypedToTSV = sqlJsonTypedToTSV,
    sqlJsonNaturalToTSV = sqlJsonNaturalToTSV,
    sqlXmlToTSV = sqlXmlToTSV,
    sqlMpkToTSV = sqlMpkToTSV,
    tsvToSqlJsonTyped = tsvToSqlJsonTyped,
    tsvToSqlJsonNatural = tsvToSqlJsonNatural,
    tsvToSqlXml = tsvToSqlXml,
    tsvToSqlMpk = tsvToSqlMpk,
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
