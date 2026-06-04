-- Module name
local NAME = "json_transcoders"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 23, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

-- dkjson parses the input; parsers gives the typed schema for the file's
-- typeName; raw_tsv serialises the resulting rows to TSV text.
local dkjson = require("dkjson")
local parsers = require("parsers")
local raw_tsv = require("raw_tsv")
local recordFieldNames = parsers.recordFieldNames
local recordFieldTypes = parsers.recordFieldTypes
local rawTSVToString = raw_tsv.rawTSVToString

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- JSON -> TSV transcoders for the content pipeline (content_pipeline.md Phase 3).
--
-- Several JSON layouts encode the same tabular data — object-per-row,
-- array-per-row, array-per-column — so they can't be told apart by extension;
-- the author selects one per file via the Files.tsv `transcoder` column. Each
-- layout is one function here with the content-pipeline transform signature
-- (name, content, env, badVal, ctx); builtin_content_stages.lua registers them
-- as id-selected `transcode` stages.
--
-- In every layout the column NAMES, TYPES and ORDER come from the file's typeName
-- schema (ctx.typeName, in sorted field order), NOT from the JSON, so the emitted
-- TSV carries a correctly typed `name:type` header and the existing
-- type/validation machinery applies unchanged. The array layouts are therefore
-- positional: each value aligns to the schema's sorted field order. The
-- schema-resolution, value->cell and serialisation helpers below are shared.
--
-- The three id-selected transcoders:
--   json:objects  [ {name:…, price:…}, … ]   one object per row (self-describing)
--   json:rows     [ [v, v, …], … ]           one array per row  (values in field order)
--   json:columns  [ [v, v, …], … ]           one array per column (transpose of rows)
-- ============================================================

-- Resolves ctx.typeName to the ordered schema field names and a typed TSV header
-- row (one `name:type` cell per field, in the schema's sorted field order).
-- Returns (fieldNames, headerRow) or (nil, errmsg).
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
    return fieldNames, header
end

-- Converts one JSON value to a raw-TSV cell. A missing/null value is an empty
-- cell; a composite (table) value is rejected. Returns (cell) or (nil, errmsg).
local function valueToCell(v)
    if v == nil or v == dkjson.null then
        return ""
    elseif type(v) == "table" then
        return nil, "composite value, which is not supported yet"
    end
    return v   -- string / number / boolean; rawTSVToString stringifies
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

-- json:objects — a top-level JSON array of objects, one object per row. Fields
-- are pulled by name in schema order; a missing/null field becomes an empty
-- cell. An unknown typeName, malformed JSON, a non-object element, or a
-- composite field value all abort the file via badVal.
local function objectsToTSV(name, content, _env, badVal, ctx)
    local fail = failer(name, badVal)

    local fieldNames, header = schemaHeader(ctx)
    if not fieldNames then return fail(header) end   -- `header` holds the error message

    local parsed, err = decodeArray(content)
    if not parsed then return fail(err) end

    local rows = {header}
    for idx, obj in ipairs(parsed) do
        if type(obj) ~= "table" then
            return fail("element " .. idx .. " is not an object")
        end
        local row = {}
        for i, fname in ipairs(fieldNames) do
            local cell, cellErr = valueToCell(obj[fname])
            if cellErr then
                return fail("field '" .. fname .. "' of element " .. idx .. " is a " .. cellErr)
            end
            row[i] = cell
        end
        rows[#rows + 1] = row
    end

    local tsvText, serr = serialize(rows)
    if not tsvText then return fail(serr) end
    return tsvText
end

-- json:rows — a top-level JSON array of arrays, one inner array per row. Values
-- are positional, aligning to the schema's sorted field order; a missing trailing
-- value becomes an empty cell, and more values than fields is an error. A
-- non-array element, composite value, etc. abort via badVal.
local function rowsToTSV(name, content, _env, badVal, ctx)
    local fail = failer(name, badVal)

    local fieldNames, header = schemaHeader(ctx)
    if not fieldNames then return fail(header) end

    local parsed, err = decodeArray(content)
    if not parsed then return fail(err) end

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
            local cell, cellErr = valueToCell(arr[i])
            if cellErr then
                return fail("value " .. i .. " of row " .. idx .. " is a " .. cellErr)
            end
            row[i] = cell
        end
        rows[#rows + 1] = row
    end

    local tsvText, serr = serialize(rows)
    if not tsvText then return fail(serr) end
    return tsvText
end

-- json:columns — a top-level JSON array of arrays, one inner array per column,
-- in the schema's sorted field order (the transpose of json:rows). There must be
-- exactly one column per schema field. A missing/null cell becomes empty.
--
-- Row count is the highest index present across the columns, NOT Lua's `#`: a
-- JSON null decodes (via dkjson) to nil, a hole that makes `#` unreliable, so a
-- column with nulls would otherwise look short. Consequently columns may differ
-- in apparent length (the shorter ones are null-padded), and a trailing row that
-- is null in EVERY column cannot be represented (anchor length with a non-null
-- column such as the PK).
local function columnsToTSV(name, content, _env, badVal, ctx)
    local fail = failer(name, badVal)

    local fieldNames, header = schemaHeader(ctx)
    if not fieldNames then return fail(header) end

    local parsed, err = decodeArray(content)
    if not parsed then return fail(err) end

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
            local cell, cellErr = valueToCell(parsed[c][r])
            if cellErr then
                return fail("value " .. r .. " of column " .. c .. " is a " .. cellErr)
            end
            row[c] = cell
        end
        rows[#rows + 1] = row
    end

    local tsvText, serr = serialize(rows)
    if not tsvText then return fail(serr) end
    return tsvText
end

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
