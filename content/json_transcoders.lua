-- Module name
local NAME = "json_transcoders"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 32, 0)

local read_only = require("util.read_only")
local formatInteger = require("util.string_utils").formatInteger
local readOnly = read_only.readOnly

-- dkjson parses the input; parsers gives the typed schema for the file's
-- typeName; raw_tsv serialises the resulting rows to TSV text.
local dkjson = require("dkjson")
local parsers = require("parsers")
local raw_tsv = require("tsv.raw_tsv")
local error_reporting = require("infra.error_reporting")
local recordFieldNames = parsers.recordFieldNames
local recordFieldTypes = parsers.recordFieldTypes
local rawTSVToString = raw_tsv.rawTSVToString
local stringToRawTSV = raw_tsv.stringToRawTSV

-- The reverse encoders (tsvToJson) parse the reformatter's wide TSV back into a
-- typed model with the SAME machinery the loader uses, so each cell's parsed Lua
-- value agrees with the rest of the pipeline (json_input_round_trip.md Step 1).
local tsv_model = require("tsv.tsv_model")
local processTSV = tsv_model.processTSV
local defaultOptionsExtractor = tsv_model.defaultOptionsExtractor
local expressionEvaluatorGenerator = tsv_model.expressionEvaluatorGenerator

-- Type introspection drives type-DIRECTED reconstruction of composite cells
-- (json_complex_values.md D6): keys and leaves are rebuilt according to the
-- column's declared type rather than guessed, so e.g. a map<string,…> key "01"
-- stays the string "01" while a map<integer,…> key "1" becomes the number 1 (the
-- map parser requires the key's Lua type to match the declared key type).
local parseType = parsers.parseType
local mapKVType = parsers.mapKVType
local arrayElementType = parsers.arrayElementType
local tupleFieldTypes = parsers.tupleFieldTypes
local unionTypes = parsers.unionTypes
local isNeverTable = parsers.isNeverTable
local extendsOrRestrict = parsers.extendsOrRestrict
local nullBadVal = error_reporting.nullBadVal

-- Reconstruction + native serialisation of composite cell values. A composite
-- JSON value is turned into a Lua value and then into TabuLua's native,
-- brace-less cell text, which the column's own table parser re-parses and
-- validates (content_pipeline.md Phase 3, json_complex_values.md D1).
local deserialization = require("serde.deserialization")
local serialization = require("serde.serialization")
local processNaturalValue = deserialization.processNaturalValue
local processTypedValue = deserialization.processTypedValue
local serializeTable = serialization.serializeTable

-- The reverse encoders serialise each parsed cell value per layout: natural ids
-- use serializeNaturalJSON, the :typed ids use serializeJSON (the self-describing
-- {"int":…} form) — the same per-cell serialisers exporter.exportJSON uses.
local serializeNaturalJSON = serialization.serializeNaturalJSON
local serializeJSON = serialization.serializeJSON

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- JSON <-> TSV transcoders for the content pipeline (content_pipeline.md Phase 3).
-- The forward transforms (JSON -> TSV) are below; the reversible `encode`
-- functions (TSV -> JSON, json_input_round_trip.md) are further down, so a .json
-- source round-trips in the reformatter like .xml/.eav.
--
-- Several JSON layouts encode the same tabular data — object-per-row,
-- array-per-row, array-per-column — so they can't be told apart by extension;
-- the author selects one per file via the Files.tsv `transcoder` column. Each
-- layout is one factory here, parametrised by the cell-value reconstruction codec
-- and registered by builtin_content_stages as id-selected `transcode` stages.
-- Two codecs are wired per layout: json-natural (the bare json:* ids; conventional
-- JSON, type-directed reconstruction) and json-typed (the json:*:typed ids; the
-- self-describing read-back of exportJSON).
--
-- In every layout the column NAMES, TYPES and ORDER come from the file's typeName
-- schema (ctx.typeName, in sorted field order), NOT from the JSON, so the emitted
-- TSV carries a correctly typed `name:type` header and the existing
-- type/validation machinery applies unchanged. The array layouts are therefore
-- positional: each value aligns to the schema's sorted field order.
--
-- A cell may itself be a composite value (a JSON object/array matching a
-- table-typed column). It is reconstructed to a Lua value and serialised to
-- native cell text; the column parser does the final typing (json_complex_values.md).
--
-- The id-selected transcoders:
--   json:objects        [ {name:…, price:…}, … ]   one object per row
--   json:rows           [ [v, v, …], … ]           one array per row
--   json:columns        [ [v, v, …], … ]           one array per column
-- ============================================================

-- Resolves ctx.typeName to the ordered schema field names, a typed TSV header
-- row (one `name:type` cell per field, in the schema's sorted field order) and
-- the field→type map (used to type-direct composite-cell reconstruction).
-- Returns (fieldNames, headerRow, fieldTypes) or (nil, errmsg).
--
-- Note: a column type with a table-typed map KEY needs no special handling here —
-- the type parser itself rejects such a type ("map key_type can never be a
-- table"), so recordFieldTypes returns nil and this aborts with the message
-- below. (json_complex_values.md D4.)
local function schemaHeader(ctx)
    local typeName = ctx and ctx.typeName
    if not typeName or typeName == "" then
        return nil, "no typeName (set the typeName column in Files.tsv)"
    end
    local fieldNames = recordFieldNames(typeName)
    local fieldTypes = recordFieldTypes(typeName)
    if not fieldNames or not fieldTypes then
        return nil, "typeName '" .. tostring(typeName)
            .. "' is not a known record type (define it before this file loads)"
    end
    local header = {}
    for i, fname in ipairs(fieldNames) do
        header[i] = fname .. ":" .. fieldTypes[fname]
    end
    return fieldNames, header, fieldTypes
end

-- Serialises a reconstructed Lua value to native, brace-less cell text (what the
-- column's table parser consumes: it re-wraps in {} and evaluates via ltcn).
local function toCellText(luaValue)
    return serializeTable(luaValue):sub(2, -2)
end

-- Recursively reports every non-finite number (NaN/±Inf) via `flag` — values that
-- cannot round-trip through JSON (json_complex_values.md D5). Reporting only; it
-- never aborts. `seen` guards cyclic tables.
local function flagNonFinite(value, flag, where, seen)
    local t = type(value)
    if t == "number" then
        if value ~= value then
            flag("NaN " .. where .. " (not representable in JSON)")
        elseif value == math.huge or value == -math.huge then
            flag("infinite number " .. where .. " (not representable in JSON)")
        end
    elseif t == "table" then
        seen = seen or {}
        if seen[value] then return end
        seen[value] = true
        for k, v in pairs(value) do
            flagNonFinite(k, flag, where, seen)
            flagNonFinite(v, flag, where, seen)
        end
    end
end

-- Is `typeSpec` a numeric leaf type? Only then are the JSON sentinel strings
-- "NAN"/"INF"/"-INF" read back as the float values; in any other slot they stay
-- literal strings (so a string-typed "NAN" is preserved).
local function isNumericType(typeSpec)
    return typeSpec == "number" or extendsOrRestrict(typeSpec, "number")
end

-- Reconstructs a leaf (non-table) JSON value, type-directed: special-float
-- sentinels only in a numeric slot, "<FUNCTION>" always nil, everything else
-- verbatim.
local function leafValue(v, typeSpec)
    if type(v) == "string" then
        if v == "<FUNCTION>" then
            return nil
        end
        if isNumericType(typeSpec) then
            if v == "NAN" then return 0/0
            elseif v == "INF" then return math.huge
            elseif v == "-INF" then return -math.huge end
        end
    end
    return v
end

-- If `typeSpec` is a union, returns its single table-typed member (e.g. the map
-- in `{string:string}|nil`) so reconstruction can see through optional
-- containers; returns `typeSpec` unchanged when there is no union, or no/ambiguous
-- container member.
local function containerType(typeSpec)
    local members = unionTypes(typeSpec)
    if not members then return typeSpec end
    local found
    for _, m in ipairs(members) do
        if not isNeverTable(m) then          -- m can be a table → a container
            if found then return typeSpec end  -- 2+ containers: ambiguous
            found = m
        end
    end
    return found or typeSpec
end

-- json-natural codec: type-DIRECTED reconstruction of a JSON-decoded value into
-- the Lua shape the column parser expects (json_complex_values.md D6). The
-- decisive case is map KEYS: each is rebuilt with the key type's own parser, so
-- the key's Lua type matches the declared key type. Falls back to the type-blind
-- processNaturalValue for untyped (`table`/`raw`) or ambiguous-union slots, where
-- there is no key type to honour.
local function reconstructNatural(v, typeSpec)
    if type(v) ~= "table" then
        return leafValue(v, typeSpec)
    end

    local ts = containerType(typeSpec)

    local keyType, valueType = mapKVType(ts)
    if keyType then
        local keyParser = parseType(nullBadVal, keyType, "tsv")
        local out = {}
        for jsonKey, jsonVal in pairs(v) do
            local key = jsonKey
            if type(jsonKey) == "string" and keyParser then
                local parsedKey = keyParser(nullBadVal, jsonKey, "tsv")
                if parsedKey ~= nil then key = parsedKey end
            end
            out[key] = reconstructNatural(jsonVal, valueType)
        end
        return out
    end

    local elemType = arrayElementType(ts)
    if elemType then
        local out = {}
        for i, e in ipairs(v) do out[i] = reconstructNatural(e, elemType) end
        return out
    end

    local tupleTypes = tupleFieldTypes(ts)
    if tupleTypes then
        local out = {}
        for i = 1, #tupleTypes do out[i] = reconstructNatural(v[i], tupleTypes[i]) end
        return out
    end

    local fieldTypes = recordFieldTypes(ts)
    if fieldTypes then
        local out = {}
        for fname, ftype in pairs(fieldTypes) do
            out[fname] = reconstructNatural(v[fname], ftype)
        end
        return out
    end

    -- Untyped (`table`/`raw`) or ambiguous union: no key type to honour.
    return processNaturalValue(v)
end

-- Renders a scalar for the wide-TSV cell. Numbers normally pass through
-- (rawTSVToString stringifies), but an INTEGRAL number that tostring() would
-- render in scientific notation is written as its exact digit string instead:
-- on LuaJIT tostring(9007199254740991) is "9.007199254741e+15" — rounded! —
-- which would corrupt a {"int":"…"} wrapper on its way into the TSV.
-- (Finite check is implicit: tostring of inf/nan has no exponent marker.)
local function scalarToCell(v)
    if type(v) == "number" and v == math.floor(v) and tostring(v):find("[eE]") then
        return formatInteger(v)
    end
    return v
end

-- Converts one JSON value to a raw-TSV cell, guided by the column's `fieldType`.
--   * missing/null            -> empty cell
--   * JSON table              -> reconstruct, then native cell text (composite
--                                result) or pass-through (scalar result — the typed
--                                format wraps a scalar int as {"int":"100"}, which
--                                decodes to a table but reconstructs to a number)
--   * plain scalar            -> passed through (rawTSVToString stringifies)
-- Non-finite numbers (at any depth) are flagged via `flag` but NOT rejected (D5).
-- Returns (cell) or (nil, errmsg); an errmsg is a structural failure that aborts.
local function valueToCell(v, fieldType, reconstruct, flag, where)
    if v == nil or v == dkjson.null then
        return ""
    elseif type(v) == "table" then
        -- reconstruct may raise (e.g. a "NAN" object key is an invalid Lua key),
        -- so guard it; (lv, derr) is the normal (value, errmsg) convention.
        local ok, lv, derr = pcall(reconstruct, v, fieldType)
        if not ok then
            return nil, "could not reconstruct composite " .. where
                .. ": " .. tostring(lv)
        end
        if lv == nil then
            if derr then
                return nil, "could not reconstruct composite " .. where
                    .. ": " .. tostring(derr)
            end
            return ""   -- reconstructed to nil (e.g. an empty/null wrapper)
        end
        flagNonFinite(lv, flag, where)
        if type(lv) ~= "table" then
            return scalarToCell(lv)   -- typed scalar wrapper unwrapped to a scalar
        end
        local serOk, txt = pcall(toCellText, lv)
        if not serOk then
            return nil, "could not serialise composite " .. where
                .. ": " .. tostring(txt)
        end
        return txt
    end
    if type(v) == "number" then
        flagNonFinite(v, flag, where)
    end
    return scalarToCell(v)   -- string / number / boolean; rawTSVToString stringifies
end

-- Decodes JSON content, requiring a top-level array. Returns (array) or (nil, errmsg).
local function decodeArray(content)
    local parsed, _pos, err = dkjson.decode(content)
    if err then
        return nil, "invalid JSON: " .. tostring(err)
    end
    if type(parsed) ~= "table" then
        return nil, "expected a top-level JSON array"
    end
    return parsed
end

-- Serialises a raw-TSV structure to text. Returns (text) or (nil, errmsg).
local function serialize(rows)
    local ok, tsvText = pcall(rawTSVToString, rows)
    if not ok then
        return nil, "cannot serialise to TSV: " .. tostring(tsvText)
    end
    return tsvText
end

-- Returns a `fail(msg)` closure that reports via badVal and returns nil, so each
-- transcoder can `return fail("…")`. Shared message prefix across the layouts.
local function failer(name, badVal)
    return function(msg)
        badVal(name, "json transcoder: " .. msg .. " in '" .. name .. "'")
        return nil
    end
end

-- Like failer, but reports without returning nil — for non-fatal fidelity
-- warnings that are flagged while the transcode carries on (D5).
local function flagger(name, badVal)
    return function(msg)
        badVal(name, "json transcoder: " .. msg .. " in '" .. name .. "'")
    end
end

-- ------------------------------------------------------------
-- Per-layout body functions. Each takes the decoded top-level array plus the
-- resolved schema and shared helpers, and returns the TSV text or nil (after
-- reporting via `fail`). Composite/non-finite handling lives in valueToCell.
-- ------------------------------------------------------------

-- json:objects — a top-level array of objects, one object per row; fields pulled
-- by name in schema order, a missing/null field becoming an empty cell.
local function objectsBody(parsed, fieldNames, fieldTypes, header, reconstruct, fail, flag)
    local rows = {header}
    for idx, obj in ipairs(parsed) do
        if type(obj) ~= "table" then
            return fail("element " .. idx .. " is not an object")
        end
        local row = {}
        for i, fname in ipairs(fieldNames) do
            local where = "field '" .. fname .. "' of element " .. idx
            local cell, cellErr = valueToCell(obj[fname], fieldTypes[fname],
                reconstruct, flag, where)
            if cellErr then return fail(cellErr) end
            row[i] = cell
        end
        rows[#rows + 1] = row
    end
    return serialize(rows)
end

-- json:rows — a top-level array of arrays, one inner array per row; values
-- positional to the schema's sorted field order. A missing trailing value becomes
-- an empty cell; more values than fields is an error.
local function rowsBody(parsed, fieldNames, fieldTypes, header, reconstruct, fail, flag)
    local rows = {header}
    for idx, arr in ipairs(parsed) do
        if type(arr) ~= "table" then
            return fail("element " .. idx .. " is not an array")
        end
        if #arr > #fieldNames then
            return fail("row " .. idx .. " has " .. #arr .. " values but the schema has "
                .. #fieldNames .. " field(s)")
        end
        local row = {}
        for i = 1, #fieldNames do
            local where = "value " .. i .. " of row " .. idx
            local cell, cellErr = valueToCell(arr[i], fieldTypes[fieldNames[i]],
                reconstruct, flag, where)
            if cellErr then return fail(cellErr) end
            row[i] = cell
        end
        rows[#rows + 1] = row
    end
    return serialize(rows)
end

-- json:columns — a top-level array of arrays, one inner array per column, in the
-- schema's sorted field order (the transpose of json:rows). Exactly one column
-- per schema field. A missing/null cell becomes empty.
--
-- Row count is the highest index present across the columns, NOT Lua's `#`: a
-- JSON null decodes (via dkjson) to nil, a hole that makes `#` unreliable, so a
-- column with nulls would otherwise look short. Consequently columns may differ
-- in apparent length (the shorter ones are null-padded), and a trailing row that
-- is null in EVERY column cannot be represented (anchor length with a non-null
-- column such as the PK).
local function columnsBody(parsed, fieldNames, fieldTypes, header, reconstruct, fail, flag)
    if #parsed ~= #fieldNames then
        return fail("expected " .. #fieldNames .. " column(s) (one per schema field) but got "
            .. #parsed)
    end
    for c = 1, #fieldNames do
        if type(parsed[c]) ~= "table" then
            return fail("column " .. c .. " is not an array")
        end
    end

    local nRows = 0
    for c = 1, #fieldNames do
        for k in pairs(parsed[c]) do
            if type(k) == "number" and k > nRows then nRows = k end
        end
    end

    local rows = {header}
    for r = 1, nRows do
        local row = {}
        for c = 1, #fieldNames do
            local where = "value " .. r .. " of column " .. c
            local cell, cellErr = valueToCell(parsed[c][r], fieldTypes[fieldNames[c]],
                reconstruct, flag, where)
            if cellErr then return fail(cellErr) end
            row[c] = cell
        end
        rows[#rows + 1] = row
    end
    return serialize(rows)
end

-- ------------------------------------------------------------
-- Factory: wraps a per-layout body with the shared prologue (schema resolution,
-- JSON decode) and the content-pipeline signature (name, content, env, badVal,
-- ctx). `reconstruct(decodedValue, fieldType) -> (lua, err)` is the cell-format
-- codec (json-natural is type-directed and consults fieldType; a future `:typed`
-- codec is self-describing and ignores it).
-- ------------------------------------------------------------
local function makeTranscoder(body, reconstruct)
    return function(name, content, _env, badVal, ctx)
        local fail = failer(name, badVal)
        local flag = flagger(name, badVal)

        local fieldNames, header, fieldTypes = schemaHeader(ctx)
        if not fieldNames then return fail(header) end   -- `header` holds the error message

        local parsed, err = decodeArray(content)
        if not parsed then return fail(err) end

        local tsvText, serr = body(parsed, fieldNames, fieldTypes, header,
            reconstruct, fail, flag)
        if not tsvText then return serr and fail(serr) or nil end
        return tsvText
    end
end

-- The natural (default) stages. The bare json:* ids map here; natural handles
-- both simple and composite cell values, reconstructing composites type-directed
-- (reconstructNatural).
local objectsToTSV = makeTranscoder(objectsBody, reconstructNatural)
local rowsToTSV    = makeTranscoder(rowsBody,    reconstructNatural)
local columnsToTSV = makeTranscoder(columnsBody, reconstructNatural)

-- json-typed codec: the typed JSON encoding is self-describing ({"int":…} /
-- {"float":…} wrappers and the [size,…] table form preserve every type, including
-- non-string and table-valued map keys), so it ignores the column type. This is
-- the read-back of `exportJSON` (json_complex_values.md Phase 2).
local function reconstructTypedJSON(v, _fieldType)
    return processTypedValue(v)
end

-- The `:typed` stages, registered under json:objects:typed / :rows:typed /
-- :columns:typed by builtin_content_stages.
local objectsToTSVTyped = makeTranscoder(objectsBody, reconstructTypedJSON)
local rowsToTSVTyped    = makeTranscoder(rowsBody,    reconstructTypedJSON)
local columnsToTSVTyped = makeTranscoder(columnsBody, reconstructTypedJSON)

-- ============================================================
-- Reverse encoders: wide TSV -> JSON (json_input_round_trip.md). These are the
-- `encode` of each reversible transcode stage; the reformatter calls them to
-- rewrite a .json source from the reformatted wide TSV, so a JSON input round-trips
-- like .xml/.eav. Schema-free, symmetric with xml_transcoder.tsvToXml: column
-- NAMES, TYPES and ORDER all come from the wide-TSV `name:type` header (which the
-- forward path already wrote in the schema's sorted field order), NOT from a
-- typeName, so no ctx is needed. The round-trip is NORMALIZING (canonical JSON),
-- not byte-identical: object key order becomes the header order, and number/
-- whitespace formatting is canonical. :typed is value-lossless; natural carries the
-- conventional-JSON caveats documented in json_complex_values.md.
--
-- The header row is NEVER emitted (the JSON layouts carry no header — the schema
-- lived in typeName, not the file); only data rows are written.
-- ============================================================

-- A private badVal that collects messages, used to drive processTSV without
-- touching the loader's badVal/col_types stack (mirrors xml_transcoder; the Open
-- item in the plan notes this ~scaffold is mirrored rather than shared for now).
-- processTSV pushes its own col_type via withColType and asserts the stack is empty
-- on entry, so col_types is left unseeded.
local function privateBadVal()
    local msgs = {}
    local bv = error_reporting.badValGen(function(_self, m) msgs[#msgs + 1] = m end)
    bv.logger = error_reporting.nullLogger
    return bv, msgs
end

-- Parses wide-TSV text into a typed model with the loader's machinery. Returns
-- (file, header) — file[1] is the header (columns carry .name/.type_spec), file[2..]
-- are rows of cells (.parsed is the Lua value) — or (nil, errmsg).
local function parseWideTSV(content)
    local ok, rawtsv = pcall(stringToRawTSV, content)
    if not ok then return nil, "cannot parse TSV: " .. tostring(rawtsv) end

    local pbad, msgs = privateBadVal()
    local loadEnv = {files = {}}
    local expr_eval = expressionEvaluatorGenerator(loadEnv)
    local file = processTSV(defaultOptionsExtractor, expr_eval, parseType,
        "json-encode", rawtsv, pbad, {}, false, nil)
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

-- Wraps a sequence of already-serialised row/column strings as a top-level JSON
-- array, matching exporter.exportJSON's multi-line layout. An empty sequence emits
-- the bare `[]` (json:columns instead always emits one array per column, so it never
-- reaches here empty).
local function wrapArray(items)
    if #items == 0 then return "[]" end
    return "[\n" .. table.concat(items, ",\n") .. "\n]"
end

-- The parsed Lua value of cell `i` of a row (nil if the cell is missing/empty).
local function cellValue(row, i)
    local cell = row[i]
    return cell and cell.parsed
end

-- json:objects — one JSON object per data row, fields keyed by the header column
-- names in header order. A missing/null cell becomes `"field":null` (D4): the
-- forward path collapses absent and null to an empty cell, so re-emitting null is a
-- faithful representative, and emitting the key keeps every row the same shape.
local function objectsAssembler(file, header, serializeValue)
    local rows = {}
    for r = 2, #file do
        local row = file[r]
        if type(row) == "table" then
            local cells = {}
            for i = 1, #header do
                cells[i] = dkjson.encode(header[i].name) .. ":"
                    .. serializeValue(cellValue(row, i), false)
            end
            rows[#rows + 1] = "{" .. table.concat(cells, ",") .. "}"
        end
    end
    return wrapArray(rows)
end

-- json:rows — one JSON array per data row, values positional in header order.
local function rowsAssembler(file, header, serializeValue)
    local rows = {}
    for r = 2, #file do
        local row = file[r]
        if type(row) == "table" then
            local cells = {}
            for i = 1, #header do
                cells[i] = serializeValue(cellValue(row, i), false)
            end
            rows[#rows + 1] = "[" .. table.concat(cells, ",") .. "]"
        end
    end
    return wrapArray(rows)
end

-- json:columns — the transpose of rows: one JSON array per column (always exactly
-- #header arrays, in header order), each holding that column's values down the rows.
local function columnsAssembler(file, header, serializeValue)
    local nCols = #header
    local cols = {}
    for c = 1, nCols do cols[c] = {} end
    for r = 2, #file do
        local row = file[r]
        if type(row) == "table" then
            for c = 1, nCols do
                local col = cols[c]
                col[#col + 1] = serializeValue(cellValue(row, c), false)
            end
        end
    end
    local colStrings = {}
    for c = 1, nCols do
        colStrings[c] = "[" .. table.concat(cols[c], ",") .. "]"
    end
    return wrapArray(colStrings)
end

-- Factory: wraps a layout assembler with the shared wide-TSV parse and the
-- content-pipeline encode signature (content, env, badVal). `serializeValue` is the
-- per-cell JSON serialiser (serializeNaturalJSON for the natural ids, serializeJSON
-- for the :typed ids). Returns (jsonText) or (nil, reason), matching the encode
-- contract; the reformatter writes the text output via safeReplaceFile.
local function makeEncoder(assembler, serializeValue)
    return function(content, _env, _badVal)
        local file, headerOrErr = parseWideTSV(content)
        if not file then return nil, headerOrErr end   -- headerOrErr holds the error
        return assembler(file, headerOrErr, serializeValue)
    end
end

local objectsToJson = makeEncoder(objectsAssembler, serializeNaturalJSON)
local rowsToJson    = makeEncoder(rowsAssembler,    serializeNaturalJSON)
local columnsToJson = makeEncoder(columnsAssembler, serializeNaturalJSON)

local objectsToJsonTyped = makeEncoder(objectsAssembler, serializeJSON)
local rowsToJsonTyped    = makeEncoder(rowsAssembler,    serializeJSON)
local columnsToJsonTyped = makeEncoder(columnsAssembler, serializeJSON)

-- ============================================================
-- Public API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    objectsToTSV = objectsToTSV,
    rowsToTSV = rowsToTSV,
    columnsToTSV = columnsToTSV,
    objectsToTSVTyped = objectsToTSVTyped,
    rowsToTSVTyped = rowsToTSVTyped,
    columnsToTSVTyped = columnsToTSVTyped,
    objectsToJson = objectsToJson,
    rowsToJson = rowsToJson,
    columnsToJson = columnsToJson,
    objectsToJsonTyped = objectsToJsonTyped,
    rowsToJsonTyped = rowsToJsonTyped,
    columnsToJsonTyped = columnsToJsonTyped,
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
