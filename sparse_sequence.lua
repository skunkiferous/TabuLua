-- Module name
local NAME = "sparse_sequence"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 8, 0)

-- Dependencies
local read_only = require("read_only")
local readOnly = read_only.readOnly

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- Constants for sparse sequences
local MAX_NIL_GAP = 10  -- Maximum number of consecutive nil values allowed
local MAX_NIL_RATIO = 0.5  -- Maximum ratio of nil values to total sequence length

-- Constants for insertRemoveNils function
local MAX_NIL_GAP_IRN = 100
local MAX_NIL_RATIO_IRN = 0.95

--- Returns the "size" (max index) of a sparse sequence if valid, otherwise nil.
--- A valid sparse sequence must satisfy:
--- 1. All numeric keys are integers
--- 2. The sequence starts at index 1 (no keys below 1)
--- 3. Gaps between valid elements don't exceed maxNilGap
--- 4. Total ratio of nil values doesn't exceed maxNilRatio
--- 5. No non-numeric keys exist
---
--- @param t table The table to check
--- @param maxNilGap number|nil Maximum consecutive nil values allowed (default: MAX_NIL_GAP=10)
--- @param maxNilRatio number|nil Maximum ratio of nil values to total length (default: MAX_NIL_RATIO=0.5)
--- @return number|nil The max index if valid sparse sequence, nil otherwise
local function getSparseSequenceSize(t, maxNilGap, maxNilRatio)
    if type(t) ~= "table" then
        return nil
    end

    maxNilGap = maxNilGap or MAX_NIL_GAP
    maxNilRatio = maxNilRatio or MAX_NIL_RATIO

    -- Find the min and max numeric keys
    local min_key = math.huge
    local max_key = -math.huge
    local numeric_keys = {}
    local non_numeric_exists = false

    for k, _ in pairs(t) do
        if type(k) == "number" and (math.type(k) == "integer" or math.floor(k) == k) then
            min_key = math.min(min_key, k)
            max_key = math.max(max_key, k)
            numeric_keys[k] = true
        else
            non_numeric_exists = true
        end
    end

    -- If we found non-numeric keys, it's not a sequence
    if non_numeric_exists then
        return nil
    end

    -- If we found no keys, it's an empty sequence
    if min_key == math.huge then
        return 0
    end

    -- Check if sequence starts before 1
    if min_key < 1 then
        return nil
    end

    -- Count gaps and check gap sizes
    local nil_count = 0
    local current_gap = 0

    for i = 1, max_key do
        if not numeric_keys[i] then
            nil_count = nil_count + 1
            current_gap = current_gap + 1
            if current_gap > maxNilGap then
                return nil
            end
        else
            current_gap = 0
        end
    end

    -- Check nil ratio
    local total_length = max_key
    local nil_ratio = nil_count / total_length

    if nil_ratio <= maxNilRatio then
        return max_key
    else
        return nil
    end
end

--- Checks if a table represents a valid sparse sequence.
--- See getSparseSequenceSize() for the definition of a valid sparse sequence.
---
--- @param t table The table to check
--- @param maxNilGap number|nil Maximum consecutive nil values allowed (default: MAX_NIL_GAP=10)
--- @param maxNilRatio number|nil Maximum ratio of nil values to total length (default: MAX_NIL_RATIO=0.5)
--- @return boolean True if t is a valid sparse sequence, false otherwise
local function isSparseSequence(t, maxNilGap, maxNilRatio)
    return getSparseSequenceSize(t,maxNilGap,maxNilRatio) ~= nil
end

--- Inserts or removes nil gaps in a sparse sequence by shifting elements.
--- When count > 0: shifts elements at index and above up by count positions (inserting nils).
--- When count < 0: removes |count| nil positions starting at index (shifting elements down).
---
--- @param t table The sparse sequence to modify (must be valid per MAX_NIL_GAP_IRN/MAX_NIL_RATIO_IRN)
--- @param index integer The position at which to insert/remove nils (must be >= 1)
--- @param count integer Number of nils to insert (positive) or remove (negative); 0 is a no-op
--- @return boolean|nil True on success, nil on failure
--- @return string|nil Error message on failure, nil on success
--- @side_effect Modifies t in place by shifting elements
--- @error Returns nil and error message for: non-table input, non-integer index/count,
---        index < 1, invalid sparse sequence, count exceeds MAX_NIL_GAP_IRN,
---        integer overflow, or not enough nils to remove
local function insertRemoveNils(t, index, count)
    -- Validate inputs
    if type(t) ~= "table" then
        return nil, "Expected table as first parameter, got " .. type(t)
    end
    if type(index) ~= "number" or math.type(index) ~= "integer" then
        return nil, "Expected integer index as second parameter"
    end
    if index < 1 then
        return nil, "Index cannot be less than 1"
    end
    if type(count) ~= "number" or math.type(count) ~= "integer" then
        return nil, "Expected integer count as third parameter"
    end
    if count == 0 then
        return true
    end
    
    -- Get sequence size
    local size = getSparseSequenceSize(t, MAX_NIL_GAP_IRN, MAX_NIL_RATIO_IRN)
    if not size then
        return nil, "Input is not a valid sparse sequence"
    end

    if count > 0 then
        if count > MAX_NIL_GAP_IRN then
            return nil, "Insert count exceeds maximum allowed gap"
        end
        -- Check for integer overflow
        local total = size + count
        if total > math.maxinteger or total < 0 then
            return nil, "Operation would exceed maximum integer value"
        end
        total = index + count
        if total > math.maxinteger or total < 0 then
            return nil, "Operation would exceed maximum integer value"
        end
        -- Moving up (inserting nils)
        -- Only move values that exist
        for i = size, index, -1 do
            if t[i] ~= nil then
                t[i + count] = t[i]
                t[i] = nil
            end
        end
        -- Verify the result is still a valid sparse sequence
        if not isSparseSequence(t, MAX_NIL_GAP_IRN, MAX_NIL_RATIO_IRN) then
            error("Operation created an invalid sparse sequence")
        end
    else
        -- Moving down (removing nils)
        for i = index, index - count - 1 do -- "-count" because count is negative
            if t[i] ~= nil then
                return nil, "Not enough nils to remove"
            end
        end
        for i = index, size do
            t[i] = t[i-count] -- "-count" because count is negative
            t[i-count] = nil
        end
    end

    return true
end

--- Checks if sub_set is a (non-strict) subset of super_set.
--- Both must be valid sparse sequences.
---
--- @param super_set table The potential superset sequence
--- @param sub_set table The potential subset sequence
--- @param check_ordered boolean|nil If true, sub_set elements must appear in the same order as in super_set (default: false)
--- @return boolean True if sub_set is a subset of super_set, false otherwise (including if either is not a valid sparse sequence)
local function isSubSetSequence(super_set, sub_set, check_ordered)
    if type(super_set) ~= "table" or type(sub_set) ~= "table" then
        return false
    end
    check_ordered = check_ordered or false
    local super_size = getSparseSequenceSize(super_set)
    local sub_size = getSparseSequenceSize(sub_set)
    if super_size == nil or sub_size == nil then
        return false
    end
    if super_size < sub_size then
        return false
    end
    if check_ordered then
        local j = 1
        for i = 1, #sub_set do
            while j <= #super_set and super_set[j] ~= sub_set[i] do
                j = j + 1
            end
            if super_set[j] ~= sub_set[i] then
                return false
            end
        end
    else
        -- We want to validate the presence of all sub_set values, including nils.
        -- But we can't use nil as an hash key, so use the set itself as nil-marker,
        -- as it cannot already be in the sub_set.
        local set = {}
        for i = 1, super_size do
            local val = super_set[i]
            if val == nil then
                val = set
            end
            set[val] = true
        end
        for i = 1, sub_size do
            local val = sub_set[i]
            if val == nil then
                val = set
            end
            if not set[val] then
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
    getSparseSequenceSize=getSparseSequenceSize,
    getVersion=getVersion,
    insertRemoveNils=insertRemoveNils,
    isSparseSequence=isSparseSequence,
    isSubSetSequence=isSubSetSequence,
    -- Constants for sparse sequences
    MAX_NIL_GAP = MAX_NIL_GAP,  -- Maximum number of consecutive nil values allowed
    MAX_NIL_RATIO = MAX_NIL_RATIO,  -- Maximum ratio of nil values to total sequence length
    -- Constants for insertRemoveNils function
    MAX_NIL_GAP_IRN = MAX_NIL_GAP_IRN,
    MAX_NIL_RATIO_IRN = MAX_NIL_RATIO_IRN,
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
