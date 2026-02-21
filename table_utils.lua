-- Module name
local NAME = "table_utils"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 9, 0)

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

--- Creates a shallow copy of a table.
--- Copies all key-value pairs but does not copy metatables or nested tables.
--- @param t table The table to copy
--- @return table A new table containing the same key-value pairs
local function tableShallowCopy(t)
    assert(type(t) == "table", "Expected table t, got " .. type(t))
    local result = {}
    for k, v in pairs(t) do
        result[k] = v
    end
    return result
end

--- Creates a pairs iterator that applies a manipulator function to each value.
--- @param t table The table to iterate over
--- @param manipulator function A function that transforms each value: function(value) -> transformed_value
--- @return function, table, any Iterator function, table, and initial key for use in a for loop
local function wrappedPairs(t, manipulator)
    assert(type(t) == "table", "Expected table t, got " .. type(t))
    assert(type(manipulator) == "function", "Expected function manipulator, got " .. type(manipulator))
    local orig_next, orig_t, orig_k = pairs(t)
    return function(_, k)
        local next_k, next_v = orig_next(orig_t, k)
        if next_k ~= nil then
            return next_k, manipulator(next_v)
        end
    end, t, orig_k
end

--- Creates an ipairs iterator that applies a manipulator function to each value.
--- @param t table The sequence to iterate over
--- @param manipulator function A function that transforms each value: function(value) -> transformed_value
--- @return function, table, number Iterator function, table, and initial index for use in a for loop
local function wrappedIpairs(t, manipulator)
    assert(type(t) == "table", "Expected table t, got " .. type(t))
    assert(type(manipulator) == "function", "Expected function manipulator, got " .. type(manipulator))
    local orig_next, orig_t, orig_i = ipairs(t)
    return function(_, i)
        local next_i, next_v = orig_next(orig_t, i)
        if next_i ~= nil then
            return next_i, manipulator(next_v)
        end
    end, t, orig_i
end

--- Clears all sequential (array) elements from a table.
--- Non-sequential keys are preserved.
--- @param t table The sequence to clear
--- @return nil
--- @side_effect Modifies the input table in place
local function clearSeq(t)
    assert(type(t) == "table", "Expected table t, got " .. type(t))
    for i = 1, #t do
        t[i] = nil
    end
end

--- Appends all elements from the second sequence to the first.
--- @param t1 table The destination sequence (will be modified)
--- @param t2 table The source sequence to append from
--- @return table The modified t1 table
--- @side_effect Modifies t1 in place by adding elements from t2
local function appendSeq(t1, t2)
    assert(type(t1) == "table", "Expected table t1, got " .. type(t1))
    assert(type(t2) == "table", "Expected table t2, got " .. type(t2))
    for i = 1, #t2 do
        t1[#t1 + 1] = t2[i]
    end
    return t1
end

--- Filters a sequence, splitting it into matching and non-matching elements.
--- Elements matching the predicate are returned in a new table.
--- Elements NOT matching the predicate remain in the original table.
--- @param t table The sequence to filter (will be modified)
--- @param predicate function A function that returns true for elements to extract: function(element) -> boolean
--- @return table A new sequence containing elements where predicate returned true
--- @side_effect Modifies t in place, leaving only elements where predicate returned false
local function filterSeq(t, predicate)
    assert(type(t) == "table", "Expected table t, got " .. type(t))
    assert(type(predicate) == "function", "Expected function predicate, got " .. type(predicate))
    local result = {}
    local writeIdx = 1
    for i = 1, #t do
        if predicate(t[i]) then
            result[#result + 1] = t[i]
        else
            t[writeIdx] = t[i]
            writeIdx = writeIdx + 1
        end
    end
    -- Clear remaining elements
    for i = writeIdx, #t do
        t[i] = nil
    end
    return result
end

--- Returns all keys from a table as a sorted sequence.
--- Keys are sorted by type first (boolean < number < string < other), then by value.
--- @param t table The table to extract keys from
--- @return table A new sequence containing all keys, sorted
local function keys(t)
    assert(type(t) == "table", "Expected table t, got " .. type(t))

    local result = {}
    for k, _ in pairs(t) do
        result[#result + 1] = k
    end

    table.sort(result, function(a, b)
        local ta, tb = type(a), type(b)
        if ta == tb then
            if ta == "number" or ta == "string" then
                return a < b
            elseif ta == "boolean" then
                return (not a) and b
            else
                return tostring(a) < tostring(b)
            end
        else
            return ta < tb
        end
    end)

    return result
end

--- Returns all values from a table as a sequence, ordered by sorted keys.
--- @param t table The table to extract values from
--- @return table A new sequence containing all values in sorted key order
local function values(t)
    local ks = keys(t)
    local result = {}
    for i = 1, #ks do
        result[i] = t[ks[i]]
    end
    return result
end

--- Converts a set (table with truthy values) to a sequence of keys.
--- Only keys with truthy values are included in the result.
--- @param set table A table representing a set (keys are elements, values are truthy)
--- @return table A new sequence containing the keys with truthy values (unordered)
local function setToSeq(set)
    assert(type(set) == "table", "Expected table set, got " .. type(set))
    local result = {}
    for k, v in pairs(set) do
        if v then
            result[#result + 1] = k
        end
    end
    return result
end

--- Finds the longest string in the sequence that is a prefix of the given string.
--- @param sequence table A sequence of strings to search for prefixes
--- @param str string The string to match prefixes against
--- @return string The longest matching prefix, or empty string if no match found
local function longestMatchingPrefix(sequence, str)
    assert(type(sequence) == "table", "Expected table sequence, got " .. type(sequence))
    assert(type(str) == "string", "Expected string str, got " .. type(str))
    local longest = ""
    for _, prefix in ipairs(sequence) do
        if #prefix > #longest and str:sub(1, #prefix) == prefix then
            longest = prefix
        end
    end
    return longest
end

--- Creates a new table with keys and values swapped.
--- @param t table The table to invert (values must be unique and usable as keys)
--- @return table A new table where original values become keys and original keys become values
--- @error Throws if any value appears multiple times in the input table
local function inverseMapping(t)
    assert(type(t) == "table", "Expected table t, got " .. type(t))
    local result = {}
    for k, v in pairs(t) do
        if v ~= nil then
            if result[v] ~= nil then
                error("Value " .. tostring(v) .. " appears multiple times in the input table", 2)
            end
            result[v] = k
        end
    end
    return result
end

--- Counts the number of key-value pairs in a table.
--- @param t table The table to count pairs in
--- @return number The total number of key-value pairs
local function pairsCount(t)
    assert(type(t) == "table", "Expected table t, got " .. type(t))
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

--- Case-insensitive comparator function for use with table.sort.
--- Converts values to lowercase strings before comparing.
--- @param a any First value to compare
--- @param b any Second value to compare
--- @return boolean True if a should come before b in sorted order
local function sortCaseInsensitive(a, b)
    return tostring(a):lower() < tostring(b):lower()
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    appendSeq=appendSeq,
    clearSeq=clearSeq,
    filterSeq=filterSeq,
    getVersion=getVersion,
    inverseMapping=inverseMapping,
    keys=keys,
    longestMatchingPrefix=longestMatchingPrefix,
    pairsCount=pairsCount,
    setToSeq=setToSeq,
    sortCaseInsensitive=sortCaseInsensitive,
    tableShallowCopy=tableShallowCopy,
    values=values,
    wrappedIpairs=wrappedIpairs,
    wrappedPairs=wrappedPairs,
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

-- Simplified read-only wrapper
local function readOnly(t, opt_index)
    local proxy = {}
    local mt = {
        __index = function(_p, k)
            if opt_index and opt_index[k] then
                return opt_index[k]
            end
            return t[k]
        end,
        __newindex = function(_p, _k, _v)
            error("attempt to update a read-only table", 2)
        end,
        __metatable = opt_index and opt_index.__type or "read-only table",
        __tostring = opt_index and opt_index.__tostring or nil,
        __call = opt_index and opt_index.__call or nil,
    }
    return setmetatable(proxy, mt)
end

return readOnly(API, {__tostring = apiToString, __call = apiCall, __type = NAME})
