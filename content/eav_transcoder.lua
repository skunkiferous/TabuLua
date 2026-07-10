-- Module name
local NAME = "eav_transcoder"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 30, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

-- raw_eav pivots the long (entity, attribute, value) triples to/from the wide
-- table; parsers supplies the typeName schema that types the rebuilt header;
-- raw_tsv parses/serialises the TSV text the pipeline passes around.
local raw_eav = require("tsv.raw_eav")
local stringToTable = raw_eav.stringToTable
local tableToEav = raw_eav.tableToEav
local parsers = require("parsers")
local recordFieldNames = parsers.recordFieldNames
local recordFieldTypes = parsers.recordFieldTypes
local raw_tsv = require("tsv.raw_tsv")
local stringToRawTSV = raw_tsv.stringToRawTSV
local rawTSVToString = raw_tsv.rawTSVToString

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- EAV <-> TSV transcoder for the content pipeline (eav_long_format.md
-- "After It's Done", content_pipeline.md Phase 3).
--
-- EAV is unambiguous by extension (.eav), so builtin_content_stages registers
-- this as an extension-AUTO-matched `transcode` stage (also `id="eav"` for an
-- explicit override on a non-.eav file). Unlike JSON it is also reversible, so
-- the reformatter can rewrite an .eav source from the reformatted wide TSV.
--
-- Forward (eavToTSV): the rebuilt wide table is projected onto the file's
-- `typeName` schema — typed `name:type` headers in schema field order, the key
-- column being the schema's first field — so the existing type/validation
-- machinery applies unchanged. Cells stay strings (raw_eav does no coercion).
-- Reverse (tsvToEav): strip the header types and compress back to triples.
-- ============================================================

-- Returns a `fail(msg)` closure that reports via badVal and returns nil, so the
-- forward transcoder can `return fail("…")`. Shared message prefix.
local function failer(name, badVal)
    return function(msg)
        badVal(name, "eav transcoder: " .. msg .. " in '" .. name .. "'")
        return nil
    end
end

-- Resolves ctx.typeName to (fieldNames, fieldTypes, fieldIndex) where fieldIndex
-- maps a field name to its 1-based position. Returns (nil, errmsg) on failure.
local function resolveSchema(ctx)
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
    local fieldIndex = {}
    for i, fname in ipairs(fieldNames) do
        fieldIndex[fname] = i
    end
    return fieldNames, fieldTypes, fieldIndex
end

-- eavToTSV — forward source transform. A header-less .eav file is pivoted to the
-- wide table and projected onto the schema: typed header in schema field order,
-- one row per entity, a schema field absent from the data becoming an empty cell.
-- An unknown typeName, a malformed EAV (bad arity / empty key / duplicate pair),
-- or an EAV attribute not in the schema all abort the file via badVal.
local function eavToTSV(name, content, _env, badVal, ctx)
    local fail = failer(name, badVal)

    local fieldNames, fieldTypes, fieldIndex = resolveSchema(ctx)
    if not fieldNames then return fail(fieldTypes) end   -- fieldTypes holds the error message

    -- Typed schema header, in schema field order; the key column is field 1.
    local header = {}
    for i, fname in ipairs(fieldNames) do
        header[i] = fname .. ":" .. fieldTypes[fname]
    end

    -- Pivot the triples to the wide table (raw_eav errors are caught and reported).
    local ok, wide = pcall(stringToTable, content,
        {keyColumn = fieldNames[1], onConflict = "error"})
    if not ok then return fail(tostring(wide)) end

    local rows = {header}
    if #wide > 0 then
        local wideHeader = wide[1]
        -- Every attribute in the rebuilt header (cells 2..N; cell 1 is the PK
        -- column, named after fieldNames[1] by construction) must be a schema field.
        for c = 2, #wideHeader do
            local attr = wideHeader[c]
            if not fieldIndex[attr] then
                return fail("attribute '" .. tostring(attr)
                    .. "' is not a field of type '" .. tostring(ctx.typeName) .. "'")
            end
        end
        for r = 2, #wide do
            local wr = wide[r]
            local row = {}
            for i = 1, #fieldNames do row[i] = "" end
            row[1] = wr[1]                       -- entity / PK
            for c = 2, #wideHeader do
                row[fieldIndex[wideHeader[c]]] = wr[c] or ""
            end
            rows[#rows + 1] = row
        end
    end

    local ok2, tsvText = pcall(rawTSVToString, rows)
    if not ok2 then return fail("cannot serialise to TSV: " .. tostring(tsvText)) end
    return tsvText
end

-- tsvToEav — reverse encode (round-trip on reformat). Takes the reformatted wide
-- TSV text, strips the `:type` suffix from the header cells (EAV files are
-- header-less and untyped), compresses to sparse triples, and serialises.
-- Returns (eavText) or (nil, reason), matching the decode `encode` contract.
local function tsvToEav(content, _env, _badVal)
    local ok, rawtsv = pcall(stringToRawTSV, content)
    if not ok then return nil, "cannot parse TSV: " .. tostring(rawtsv) end

    -- De-type the header (the first cell-sequence row): "title:string" -> "title".
    for _, row in ipairs(rawtsv) do
        if type(row) == "table" then
            for i = 1, #row do
                if type(row[i]) == "string" then
                    row[i] = (row[i]:gsub(":.*", ""))
                end
            end
            break
        end
    end

    local ok2, triples = pcall(tableToEav, rawtsv, {skipEmpty = true})
    if not ok2 then return nil, "cannot compress to EAV: " .. tostring(triples) end
    local ok3, text = pcall(rawTSVToString, triples)
    if not ok3 then return nil, "cannot serialise EAV: " .. tostring(text) end
    return text
end

-- ============================================================
-- Public API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    eavToTSV = eavToTSV,
    tsvToEav = tsvToEav,
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
