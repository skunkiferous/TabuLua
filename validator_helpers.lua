-- Module name
local NAME = "validator_helpers"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 9, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local serialization = require("serialization")
local serialize = serialization.serialize

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- Collection Predicates
-- ============================================================

--- Checks if all values in a column are unique across rows.
--- @param rows table Array of row objects (with parsed values directly accessible)
--- @param column string|number Column name or index
--- @return boolean True if all values are unique, false otherwise
local function unique(rows, column)
    local seen = {}
    for _, row in ipairs(rows) do
        local val = row[column]
        if val ~= nil then
            local key = serialize(val)
            if seen[key] then
                return false
            end
            seen[key] = true
        end
    end
    return true
end

--- Sums numeric values in a column.
--- @param rows table Array of row objects (with parsed values directly accessible)
--- @param column string|number Column name or index
--- @return number Sum of all numeric values in the column
local function sum(rows, column)
    local total = 0
    for _, row in ipairs(rows) do
        local val = row[column]
        if type(val) == "number" then
            total = total + val
        end
    end
    return total
end

--- Finds the minimum value in a column.
--- @param rows table Array of row objects (with parsed values directly accessible)
--- @param column string|number Column name or index
--- @return number|nil Minimum value or nil if no numeric values
local function min(rows, column)
    local result = nil
    for _, row in ipairs(rows) do
        local val = row[column]
        if type(val) == "number" then
            if result == nil or val < result then
                result = val
            end
        end
    end
    return result
end

--- Finds the maximum value in a column.
--- @param rows table Array of row objects (with parsed values directly accessible)
--- @param column string|number Column name or index
--- @return number|nil Maximum value or nil if no numeric values
local function max(rows, column)
    local result = nil
    for _, row in ipairs(rows) do
        local val = row[column]
        if type(val) == "number" then
            if result == nil or val > result then
                result = val
            end
        end
    end
    return result
end

--- Calculates the average value in a column.
--- @param rows table Array of row objects (with parsed values directly accessible)
--- @param column string|number Column name or index
--- @return number|nil Average value or nil if no numeric values
local function avg(rows, column)
    local total = 0
    local n = 0
    for _, row in ipairs(rows) do
        local val = row[column]
        if type(val) == "number" then
            total = total + val
            n = n + 1
        end
    end
    if n == 0 then
        return nil
    end
    return total / n
end

--- Counts rows, optionally filtering by a predicate.
--- @param rows table Array of row objects, or dictionary of named entries
--- @param predicate function|nil Optional predicate function(row) -> boolean
--- @return number Count of rows (matching predicate if provided)
local function count(rows, predicate)
    if predicate == nil then
        local len = #rows
        if len > 0 then
            return len
        end
        -- Handle dictionary-style tables (string keys, e.g. package files)
        local n = 0
        for _ in pairs(rows) do
            n = n + 1
        end
        return n
    end
    local result = 0
    for _, row in ipairs(rows) do
        if predicate(row) then
            result = result + 1
        end
    end
    return result
end

-- ============================================================
-- Iteration Helpers
-- ============================================================

--- Checks if all rows satisfy a predicate.
--- @param rows table Array of row objects
--- @param predicate function Predicate function(row) -> boolean
--- @return boolean True if all rows satisfy the predicate
local function all(rows, predicate)
    for _, row in ipairs(rows) do
        if not predicate(row) then
            return false
        end
    end
    return true
end

--- Checks if any row satisfies a predicate.
--- @param rows table Array of row objects
--- @param predicate function Predicate function(row) -> boolean
--- @return boolean True if at least one row satisfies the predicate
local function any(rows, predicate)
    for _, row in ipairs(rows) do
        if predicate(row) then
            return true
        end
    end
    return false
end

--- Checks if no rows satisfy a predicate.
--- @param rows table Array of row objects
--- @param predicate function Predicate function(row) -> boolean
--- @return boolean True if no rows satisfy the predicate
local function none(rows, predicate)
    return not any(rows, predicate)
end

--- Returns rows matching a predicate.
--- @param rows table Array of row objects
--- @param predicate function Predicate function(row) -> boolean
--- @return table Array of matching rows
local function filter(rows, predicate)
    local result = {}
    for _, row in ipairs(rows) do
        if predicate(row) then
            result[#result + 1] = row
        end
    end
    return result
end

--- Finds the first row matching a predicate.
--- @param rows table Array of row objects
--- @param predicate function Predicate function(row) -> boolean
--- @return table|nil First matching row or nil
local function find(rows, predicate)
    for _, row in ipairs(rows) do
        if predicate(row) then
            return row
        end
    end
    return nil
end

-- ============================================================
-- Lookup Helpers
-- ============================================================

--- Finds a row where a column equals a specific value.
--- @param rows table Array of row objects (with parsed values directly accessible)
--- @param column string|number Column name or index
--- @param value any Value to search for
--- @return table|nil Matching row or nil
local function lookup(rows, column, value)
    for _, row in ipairs(rows) do
        if row[column] == value then
            return row
        end
    end
    return nil
end

--- Groups rows by the value of a column.
--- @param rows table Array of row objects (with parsed values directly accessible)
--- @param column string|number Column name or index
--- @return table Map of column value -> array of rows with that value
local function groupBy(rows, column)
    local result = {}
    for _, row in ipairs(rows) do
        local val = row[column]
        if val ~= nil then
            local keyStr = serialize(val)
            if not result[keyStr] then
                result[keyStr] = {}
            end
            result[keyStr][#result[keyStr] + 1] = row
        end
    end
    return result
end

-- ============================================================
-- Type Introspection Helpers
-- ============================================================

local introspection = require("parsers.introspection")

--- Returns a sorted array of member type names for a type tag, or nil if not a tag.
--- @param tagName string The name of the type tag
--- @return table|nil Sorted array of member type names, or nil if tag doesn't exist
local function listMembersOfTag(tagName)
    return introspection.listMembersOfTag(tagName)
end

--- Returns true if typeName is a member of the type tag tagName.
--- Checks direct membership, subtype membership, and transitive tag membership.
--- @param tagName string The name of the type tag
--- @param typeName string The type name to check
--- @return boolean true if typeName is a member (directly, via subtype, or via nested tag)
local function isMemberOfTag(tagName, typeName)
    return introspection.isMemberOfTag(tagName, typeName)
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    -- Collection predicates
    unique = unique,
    sum = sum,
    min = min,
    max = max,
    avg = avg,
    count = count,
    -- Iteration helpers
    all = all,
    any = any,
    none = none,
    filter = filter,
    find = find,
    -- Lookup helpers
    lookup = lookup,
    groupBy = groupBy,
    -- Type introspection helpers
    listMembersOfTag = listMembersOfTag,
    isMemberOfTag = isMemberOfTag,
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
