-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 26, 0)

-- Module name
local NAME = "raw_eav"

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

local read_only = require("read_only")
local readOnly = read_only.readOnly

local raw_tsv = require("raw_tsv")
local stringToRawTSV = raw_tsv.stringToRawTSV
local rawTSVToString = raw_tsv.rawTSVToString
local fileToRawTSV = raw_tsv.fileToRawTSV
local isRawTSV = raw_tsv.isRawTSV

-- A cell is "empty" if it is missing or the empty string. Entity and attribute
-- cells must be non-empty; value cells may be empty.
local function isEmptyCell(cell)
    return cell == nil or cell == ""
end

--- Rebuilds a wide table from an EAV (long, 3-column) raw TSV structure.
--- Entities become rows and attributes become columns, both in first-seen
--- order. Missing (entity, attribute) pairs become empty cells. A header row
--- {keyColumn, attr1, attr2, ...} is prepended (the entity column's name is
--- synthesized, since EAV files carry no header).
--- Comment/blank lines in the input are ignored.
--- @param eav table A raw TSV structure of 3-cell rows
--- @param opts table|nil { keyColumn="name", onConflict="error"|"first"|"last" }
--- @return table A wide raw TSV structure (header row + one row per entity)
--- @error Throws if eav is not a table, a data row does not have exactly 3
---        cells, an entity/attribute cell is empty, or a duplicate
---        (entity, attribute) pair is seen while onConflict="error"
local function eavToTable(eav, opts)
    local tp = type(eav)
    assert(tp == "table", "Argument must be a table: " .. tp)
    opts = opts or {}
    local keyColumn = opts.keyColumn or "name"
    local onConflict = opts.onConflict or "error"

    local entities = {}          -- insertion-ordered list of entity keys
    local entitySeen = {}        -- entity -> true
    local attributes = {}        -- insertion-ordered list of attribute names
    local attributeSeen = {}     -- attribute -> true
    local values = {}            -- entity -> { attribute -> value }
    local valueRow = {}          -- entity -> { attribute -> row index (first seen) }

    for r, row in ipairs(eav) do
        if type(row) ~= "string" then
            local width = #row
            if width ~= 3 then
                error(string.format("Row %d must have exactly 3 cells, found %d", r, width), 2)
            end
            local entity, attribute, value = row[1], row[2], row[3]
            if isEmptyCell(entity) then
                error(string.format("Row %d has an empty entity cell", r), 2)
            end
            if isEmptyCell(attribute) then
                error(string.format("Row %d has an empty attribute cell", r), 2)
            end
            if value == nil then
                value = ""
            end

            if not entitySeen[entity] then
                entitySeen[entity] = true
                table.insert(entities, entity)
                values[entity] = {}
                valueRow[entity] = {}
            end
            if not attributeSeen[attribute] then
                attributeSeen[attribute] = true
                table.insert(attributes, attribute)
            end

            local prevRow = valueRow[entity][attribute]
            if prevRow then
                if onConflict == "first" then
                    -- keep earliest value, ignore this triple
                elseif onConflict == "last" then
                    values[entity][attribute] = value
                    valueRow[entity][attribute] = r
                else
                    error(string.format(
                        "Duplicate (entity, attribute) pair (%s, %s) at rows %d and %d",
                        tostring(entity), tostring(attribute), prevRow, r), 2)
                end
            else
                values[entity][attribute] = value
                valueRow[entity][attribute] = r
            end
        end
    end

    if #entities == 0 then
        return {}
    end

    local result = {}
    local header = { keyColumn }
    for _, attribute in ipairs(attributes) do
        table.insert(header, attribute)
    end
    table.insert(result, header)

    for _, entity in ipairs(entities) do
        local dataRow = { entity }
        local entityValues = values[entity]
        for _, attribute in ipairs(attributes) do
            table.insert(dataRow, entityValues[attribute] or "")
        end
        table.insert(result, dataRow)
    end

    return result
end

--- Compresses a wide table into an EAV (long, 3-column) raw TSV structure.
--- Row 1 is treated as the header; cell 1 (the PK column's name) is discarded,
--- cells 2..N are the attribute names. Each data row yields one triple per
--- non-empty value (all values when opts.skipEmpty is false). Output is
--- header-less triples in row-major (per-entity, then per-attribute) order.
--- @param tbl table A wide raw TSV structure (header row + data rows)
--- @param opts table|nil { skipEmpty=true }
--- @return table A raw TSV structure of 3-cell rows
--- @error Throws if tbl is not a table, has no header row, has a duplicate or
---        empty attribute name in the header, or a data row has an empty entity
local function tableToEav(tbl, opts)
    local tp = type(tbl)
    assert(tp == "table", "Argument must be a table: " .. tp)
    opts = opts or {}
    local skipEmpty = opts.skipEmpty
    if skipEmpty == nil then
        skipEmpty = true
    end

    -- Find the header: the first cell-sequence row (skip leading comment/blank).
    local headerIndex
    for i, row in ipairs(tbl) do
        if type(row) ~= "string" then
            headerIndex = i
            break
        end
    end
    if not headerIndex then
        error("Table has no header row", 2)
    end

    local header = tbl[headerIndex]
    local attrSeen = {}
    for c = 2, #header do
        local attr = header[c]
        if isEmptyCell(attr) then
            error(string.format("Header has an empty attribute name at column %d", c), 2)
        end
        if attrSeen[attr] then
            error(string.format("Header has a duplicate attribute name %q at column %d",
                tostring(attr), c), 2)
        end
        attrSeen[attr] = true
    end

    local result = {}
    for r = headerIndex + 1, #tbl do
        local row = tbl[r]
        if type(row) ~= "string" then
            local entity = row[1]
            if isEmptyCell(entity) then
                error(string.format("Row %d has an empty entity cell", r), 2)
            end
            for c = 2, #header do
                local value = row[c]
                if value == nil then
                    value = ""
                end
                if not (value == "" and skipEmpty) then
                    table.insert(result, { entity, header[c], value })
                end
            end
        end
    end

    return result
end

--- Parses an EAV-format string into a wide raw TSV structure.
--- Equivalent to eavToTable(raw_tsv.stringToRawTSV(s), opts): inherits the
--- UTF-8 check, EOL normalization, comment/blank handling, and tab splitting.
--- @param s string The EAV file contents (valid UTF-8)
--- @param opts table|nil see eavToTable
--- @return table A wide raw TSV structure
--- @error Throws on the same conditions as stringToRawTSV / eavToTable
local function stringToTable(s, opts)
    return eavToTable(stringToRawTSV(s), opts)
end

--- Reads an EAV-format file and rebuilds the wide raw TSV structure.
--- Extension-agnostic; dispatch on extension (if wanted) belongs elsewhere.
--- @param file string The file path to read
--- @param opts table|nil see eavToTable
--- @return table|nil The wide raw TSV structure, or nil on read error
--- @return string|nil Error message on read failure, nil on success
local function fileToTable(file, opts)
    local raw, err = fileToRawTSV(file)
    if not raw then
        return nil, err
    end
    return eavToTable(raw, opts)
end

--- Serializes a wide raw TSV structure to an EAV-format string.
--- Equivalent to raw_tsv.rawTSVToString(tableToEav(tbl, opts)).
--- @param tbl table A wide raw TSV structure
--- @param opts table|nil see tableToEav
--- @return string The EAV file contents (header-less triples)
--- @error Throws on the same conditions as tableToEav / rawTSVToString
local function tableToString(tbl, opts)
    return rawTSVToString(tableToEav(tbl, opts))
end

--- Checks whether a value is a well-formed EAV (long) raw TSV structure:
--- a valid raw TSV whose every non-comment row has exactly 3 cells with a
--- non-empty entity and attribute. Does not check for duplicate pairs.
--- @param t any The value to check
--- @return boolean
local function isEav(t)
    if not isRawTSV(t) then
        return false
    end
    for _, row in ipairs(t) do
        if type(row) ~= "string" then
            if #row ~= 3 then
                return false
            end
            if isEmptyCell(row[1]) or isEmptyCell(row[2]) then
                return false
            end
        end
    end
    return true
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    eavToTable    = eavToTable,
    fileToTable   = fileToTable,
    getVersion    = getVersion,
    isEav         = isEav,
    stringToTable = stringToTable,
    tableToEav    = tableToEav,
    tableToString = tableToString,
}

-- Enables the module to be called as a function
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
