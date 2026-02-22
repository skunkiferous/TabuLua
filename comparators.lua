-- Module name
local NAME = "comparators"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 10, 0)

-- Dependencies
local sparse_sequence = require("sparse_sequence")
local table_utils = require("table_utils")
local read_only = require("read_only")
local readOnly = read_only.readOnly

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

--- Generates a comparator function for sorting sparse sequences.
--- The returned function compares two sequences element-by-element using the provided value comparator.
--- Nil values are considered less than any other value.
--- @param value_comparator function A function(v1, v2) -> boolean that returns true if v1 < v2
--- @return function A comparator function(t1, t2) -> boolean for use with table.sort
--- @error Throws if value_comparator is not a function, or if t1/t2 are not sparse sequences
local function genSeqComparator(value_comparator)
    assert(type(value_comparator) == "function", "value_comparator must be a function")
    -- The returned function is called with two tables to compare
    return function(t1, t2)
        local s1 = sparse_sequence.getSparseSequenceSize(t1)
        assert(type(s1) == "number", "t1 is not a (sparse) sequence")
        local s2 = sparse_sequence.getSparseSequenceSize(t2)
        assert(type(s2) == "number", "t2 is not a (sparse) sequence")
        if s1 == 0 and s2 == 0 then
            -- t1 & t2 empty
            return false
        end

        -- Now compare value by value
        local i = 1
        local min_idx = math.min(s1, s2)
        while i <= min_idx do
            -- compare values
            local v1 = t1[i]
            local v2 = t2[i]
            -- If values are different, compare them
            if v1 ~= v2 then
                if v1 == nil then
                    return true
                elseif v2 == nil then
                    return false
                end
                return value_comparator(v1, v2)
            end
            -- If values are equal, continue to next key
            i = i + 1
        end

        if s1 == s2 then
            -- All values were equal
            return false
        end
        if i > s1 then
            -- t1 ran out first
            return true
        end
        -- t2 ran out first
        return false
    end
end

--- Generates a comparator function for sorting tables with arbitrary keys.
--- Compares tables by iterating through sorted keys, comparing first by key then by value.
--- @param key_comparator function A function(k1, k2) -> boolean for comparing keys
--- @param value_comparator function A function(v1, v2) -> boolean for comparing values
--- @return function A comparator function(t1, t2) -> boolean for use with table.sort
--- @error Throws if key_comparator or value_comparator is not a function, or if t1/t2 are not tables
local function genTableComparator(key_comparator, value_comparator)
    assert(type(key_comparator) == "function", "key_comparator must be a function")
    assert(type(value_comparator) == "function", "value_comparator must be a function")
    -- The returned function is called with two tables to compare
    return function(t1, t2)
        assert(type(t1) == "table", "t1 is not a table")
        assert(type(t2) == "table", "t2 is not a table")
        -- First collect and sort all keys from both tables
        local t1_keys = {}
        for k in pairs(t1) do
            t1_keys[#t1_keys + 1] = k
        end
        local t2_keys = {}
        for k in pairs(t2) do
            t2_keys[#t2_keys + 1] = k
        end
        -- Sort keys using provided comparator
        table.sort(t1_keys, key_comparator)
        table.sort(t2_keys, key_comparator)

        local s1 = #t1_keys
        local s2 = #t2_keys

        if s1 == 0 and s2 == 0 then
            -- t1 & t2 empty
            return false
        end

        -- Now compare key by key
        local i = 1
        while i <= s1 and i <= s2 do
            local k1 = t1_keys[i]
            local k2 = t2_keys[i]
            if k1 ~= k2 then
                -- Keys don't match; compare keys
                local result = key_comparator(k1, k2)
                return result
            end
            -- Keys DO match, compare values
            local v1 = t1[k1]
            local v2 = t2[k2]
            -- If values are different, compare them
            if v1 ~= v2 then
                local result = value_comparator(v1, v2)
                return result
            end
            -- If values are equal, continue to next key
            i = i + 1
        end

        if s1 == s2 then
            -- All values were equal
            return false
        end
        if i > s1 then
            -- t1 ran out of keys first
            return true
        end
        -- t2 ran out of keys first
        return false
    end
end

--- Composes multiple comparators into a single tuple comparator.
--- Each comparator in the list handles one field position of the tuple.
--- @param comparators table A sequence of comparator functions, one per tuple field
--- @return function A comparator function(t1, t2) -> boolean for use with table.sort
--- @error Throws if comparators is not a table of functions, or if t1/t2 are not sparse sequences
local function composeComparator(comparators)
    assert(type(comparators) == "table", "comparators must be a list of functions")
    for _, cmp in ipairs(comparators) do
        assert(type(cmp) == "function", "comparators[x] must be a function")
    end
    local count = #comparators
    -- The returned function is called with two tables to compare
    return function(t1, t2)
        assert(sparse_sequence.isSparseSequence(t1), "t1 is not a (sparse) sequence")
        assert(sparse_sequence.isSparseSequence(t2), "t2 is not a (sparse) sequence")
        for i = 1, count do
            -- compare values
            local v1 = t1[i]
            local v2 = t2[i]
            -- If values are different, compare them
            if v1 ~= v2 then
                if v1 == nil then
                    return true
                elseif v2 == nil then
                    return false
                end
                return comparators[i](v1, v2)
            end
            -- If values are equal, continue to next key
        end
        -- No value of t1 was "less than" t2
        return false
    end
end

-- Maximum table depth for equals
local MAX_TABLE_DEPTH = 10

--- Compares two values for deep content equality.
--- For non-tables, uses standard equality. For tables, recursively compares all keys and values.
--- Handles table keys by recursive comparison.
--- @param a any First value to compare
--- @param b any Second value to compare
--- @param in_process table|nil Internal: tracks tables being processed to detect recursion
--- @param depth number|nil Internal: current recursion depth (default: 1)
--- @return boolean|nil True if equal, false if not equal, nil on error
--- @return string|nil Error message if recursion detected or MAX_TABLE_DEPTH exceeded
local function equals(a, b, in_process, depth)
    -- Handle identity case first
    if a == b then
        return true
    end

    -- If only one is table, they're not equal
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end

    -- Initialize tracking for first call
    in_process = in_process or {}
    depth = depth or 1

    -- Check depth limit
    if depth > MAX_TABLE_DEPTH then
        return nil, "maximum table depth exceeded"
    end

    -- Check for recursion
    if in_process[a] or in_process[b] then
        return nil, "recursive table detected"
    end

    -- Mark both tables as being processed
    in_process[a] = true
    in_process[b] = true

    -- Get number of keys in each table
    local a_count = 0
    local b_count = table_utils.pairsCount(b)

    -- For each key in a, try to find matching key and value in b
    for ak, av in pairs(a) do
        a_count = a_count + 1
        local found = false

        -- Optimization: for non-table keys, directly look up in b (O(1) instead of O(n))
        if type(ak) ~= "table" then
            local bv = b[ak]
            if bv ~= nil then
                local values_equal, err = equals(av, bv, in_process, depth + 1)
                if values_equal == nil then
                    in_process[a] = nil
                    in_process[b] = nil
                    return nil, err
                end
                found = values_equal
            end
        else
            -- Key is a table, must iterate to find matching key
            for bk, bv in pairs(b) do
                -- Check if keys are equal (recursively if they're tables)
                local keys_equal, err = equals(ak, bk, in_process, depth + 1)
                if keys_equal == nil then
                    in_process[a] = nil
                    in_process[b] = nil
                    return nil, err
                end

                if keys_equal then
                    -- Keys match, check values
                    local values_equal, err = equals(av, bv, in_process, depth + 1)
                    if values_equal == nil then
                        in_process[a] = nil
                        in_process[b] = nil
                        return nil, err
                    end
                    if values_equal then
                        found = true
                        break
                    end
                end
            end
        end

        if not found then
            in_process[a] = nil
            in_process[b] = nil
            return false
        end
    end

    -- Remove tables from processing set
    in_process[a] = nil
    in_process[b] = nil

    -- Tables are equal if they have same number of keys and all keys/values matched
    return a_count == b_count
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    composeComparator=composeComparator,
    equals=equals,
    genSeqComparator=genSeqComparator,
    genTableComparator=genTableComparator,
    getVersion=getVersion,
    MAX_TABLE_DEPTH=MAX_TABLE_DEPTH,
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
