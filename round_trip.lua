-- Module name
local NAME = "round_trip"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 14, 0)

-- Dependencies
local read_only = require("read_only")
local readOnly = read_only.readOnly

local serialization = require("serialization")
local deserialization = require("deserialization")

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================================
-- DEEP COMPARISON
-- ============================================================================

--- Checks if a value is NaN.
--- @param v any The value to check
--- @return boolean True if v is NaN
local function isNaN(v)
    return type(v) == "number" and v ~= v
end

--- Compares two values for deep equality.
--- Handles special cases like NaN, sparse sequences, and nested tables.
--- @param a any First value
--- @param b any Second value
--- @param path string|nil Current path for error reporting
--- @param visited table|nil Visited tables for cycle detection
--- @return boolean True if values are equal
--- @return string|nil Description of first difference found, or nil if equal
local function deepEquals(a, b, path, visited)
    path = path or "root"
    visited = visited or {}

    -- Handle NaN specially (NaN ~= NaN in IEEE 754)
    if isNaN(a) and isNaN(b) then
        return true, nil
    end

    -- Handle nil
    if a == nil and b == nil then
        return true, nil
    end
    if a == nil then
        return false, path .. ": a is nil, b is " .. type(b)
    end
    if b == nil then
        return false, path .. ": a is " .. type(a) .. ", b is nil"
    end

    -- Check types
    local ta, tb = type(a), type(b)
    if ta ~= tb then
        return false, path .. ": type mismatch: " .. ta .. " vs " .. tb
    end

    -- For non-table types, use direct comparison
    if ta ~= "table" then
        if a == b then
            return true, nil
        else
            return false, path .. ": value mismatch: " .. tostring(a) .. " vs " .. tostring(b)
        end
    end

    -- Cycle detection
    if visited[a] or visited[b] then
        -- If both have been visited and they were the same reference, they're equal
        -- Otherwise, we can't compare cyclic structures
        if visited[a] == b then
            return true, nil
        end
        return false, path .. ": cyclic reference detected"
    end
    visited[a] = b
    visited[b] = a

    -- Compare tables
    -- First, collect all keys from both tables
    local keysA = {}
    local keysB = {}
    for k in pairs(a) do keysA[k] = true end
    for k in pairs(b) do keysB[k] = true end

    -- Check all keys from a
    for k in pairs(keysA) do
        if not keysB[k] then
            -- Key missing in b: treat as equal if a[k] is nil
            -- (Lua can't distinguish "key missing" from "key = nil")
            if a[k] ~= nil then
                return false, path .. ": key " .. tostring(k) .. " missing in b"
            end
        else
            local childPath = path .. "[" .. tostring(k) .. "]"
            local eq, diff = deepEquals(a[k], b[k], childPath, visited)
            if not eq then
                return false, diff
            end
            keysB[k] = nil  -- Mark as checked
        end
    end

    -- Check for extra keys in b
    for k in pairs(keysB) do
        if keysB[k] then  -- Not yet processed
            -- Extra key in b: treat as equal if b[k] is nil
            if b[k] ~= nil then
                return false, path .. ": extra key " .. tostring(k) .. " in b"
            end
        end
    end

    return true, nil
end

--- Compares two values with tolerance for known format limitations.
--- For example, natural JSON can't distinguish integers from floats.
--- @param a any Original value
--- @param b any Imported value
--- @param format string The format name (e.g., "lua", "json-typed", "json-natural")
--- @param path string|nil Current path for error reporting
--- @param visited table|nil Visited tables for cycle detection
--- @return boolean True if values are equivalent for the given format
--- @return string|nil Description of first difference found, or nil if equal
local function compareWithTolerance(a, b, format, path, visited)
    path = path or "root"
    visited = visited or {}

    -- Handle NaN specially
    if isNaN(a) and isNaN(b) then
        return true, nil
    end

    -- Handle nil
    if a == nil and b == nil then
        return true, nil
    end
    if a == nil then
        return false, path .. ": original is nil, imported is " .. type(b)
    end
    if b == nil then
        return false, path .. ": original is " .. type(a) .. ", imported is nil"
    end

    local ta, tb = type(a), type(b)

    -- Float tolerance comparison for all formats
    -- Serialization/deserialization can introduce small precision differences
    if ta == "number" and tb == "number" then
        if a == b then
            return true, nil
        end
        -- Check if values are within tolerance (handles float precision issues)
        if math.abs(a - b) < 1e-10 then
            return true, nil
        end
        -- Also check relative tolerance for larger numbers
        local maxAbs = math.max(math.abs(a), math.abs(b))
        if maxAbs > 0 and math.abs(a - b) / maxAbs < 1e-10 then
            return true, nil
        end
        return false, path .. ": number mismatch: " .. tostring(a) .. " vs " .. tostring(b)
    end

    -- Type mismatch
    if ta ~= tb then
        return false, path .. ": type mismatch: " .. ta .. " vs " .. tb
    end

    -- For non-table types, use direct comparison
    if ta ~= "table" then
        if a == b then
            return true, nil
        else
            return false, path .. ": value mismatch: " .. tostring(a) .. " vs " .. tostring(b)
        end
    end

    -- Cycle detection
    if visited[a] then
        if visited[a] == b then
            return true, nil
        end
        return false, path .. ": cyclic reference detected"
    end
    visited[a] = b

    -- Compare tables
    local keysA = {}
    local keysB = {}
    for k in pairs(a) do keysA[k] = true end
    for k in pairs(b) do keysB[k] = true end

    -- Check all keys from a
    for k in pairs(keysA) do
        if not keysB[k] then
            -- Key missing in b: treat as equal if a[k] is nil
            if a[k] ~= nil then
                return false, path .. ": key " .. tostring(k) .. " missing in imported"
            end
        else
            local childPath = path .. "[" .. tostring(k) .. "]"
            local eq, diff = compareWithTolerance(a[k], b[k], format, childPath, visited)
            if not eq then
                return false, diff
            end
            keysB[k] = nil
        end
    end

    -- Check for extra keys in b
    for k in pairs(keysB) do
        if keysB[k] then
            -- Extra key in b: treat as equal if b[k] is nil
            if b[k] ~= nil then
                return false, path .. ": extra key " .. tostring(k) .. " in imported"
            end
        end
    end

    return true, nil
end

-- ============================================================================
-- ROUND-TRIP TESTS
-- ============================================================================

--- Tests round-trip serialization/deserialization for Lua format.
--- @param value any The value to test
--- @return boolean True if round-trip preserves value
--- @return string|nil Error message if failed
local function testLuaRoundTrip(value)
    local serialized = serialization.serialize(value)
    local deserialized, err = deserialization.deserialize(serialized)
    if err then
        return false, "Deserialization failed: " .. err
    end
    local eq, diff = deepEquals(value, deserialized)
    if not eq then
        return false, "Round-trip mismatch: " .. diff
    end
    return true, nil
end

--- Tests round-trip serialization/deserialization for typed JSON format.
--- @param value any The value to test
--- @return boolean True if round-trip preserves value
--- @return string|nil Error message if failed
local function testTypedJSONRoundTrip(value)
    local serialized = serialization.serializeJSON(value)
    local deserialized, err = deserialization.deserializeJSON(serialized)
    if err then
        return false, "Deserialization failed: " .. err
    end
    local eq, diff = deepEquals(value, deserialized)
    if not eq then
        return false, "Round-trip mismatch: " .. diff
    end
    return true, nil
end

--- Tests round-trip serialization/deserialization for natural JSON format.
--- Note: This format has limitations (can't distinguish integers from floats).
--- @param value any The value to test
--- @return boolean True if round-trip preserves value (with tolerance)
--- @return string|nil Error message if failed
local function testNaturalJSONRoundTrip(value)
    local serialized = serialization.serializeNaturalJSON(value)
    local deserialized, err = deserialization.deserializeNaturalJSON(serialized)
    if err then
        return false, "Deserialization failed: " .. err
    end
    local eq, diff = compareWithTolerance(value, deserialized, "json-natural")
    if not eq then
        return false, "Round-trip mismatch: " .. diff
    end
    return true, nil
end

--- Tests round-trip serialization/deserialization for XML format.
--- @param value any The value to test
--- @return boolean True if round-trip preserves value
--- @return string|nil Error message if failed
local function testXMLRoundTrip(value)
    local serialized = serialization.serializeXML(value)
    local deserialized, _pos, err = deserialization.deserializeXML(serialized)
    if err then
        return false, "Deserialization failed: " .. err
    end
    local eq, diff = deepEquals(value, deserialized)
    if not eq then
        return false, "Round-trip mismatch: " .. diff
    end
    return true, nil
end

--- Tests round-trip serialization/deserialization for MessagePack format.
--- @param value any The value to test
--- @return boolean True if round-trip preserves value
--- @return string|nil Error message if failed
local function testMessagePackRoundTrip(value)
    local serialized = serialization.serializeMessagePack(value)
    local deserialized, err = deserialization.deserializeMessagePack(serialized)
    if err then
        return false, "Deserialization failed: " .. err
    end
    local eq, diff = deepEquals(value, deserialized)
    if not eq then
        return false, "Round-trip mismatch: " .. diff
    end
    return true, nil
end

--- Tests all round-trip formats for a value.
--- @param value any The value to test
--- @return table Results for each format: {format_name = {success, error_message}, ...}
local function testAllRoundTrips(value)
    return {
        lua = {testLuaRoundTrip(value)},
        ["json-typed"] = {testTypedJSONRoundTrip(value)},
        ["json-natural"] = {testNaturalJSONRoundTrip(value)},
        xml = {testXMLRoundTrip(value)},
        mpk = {testMessagePackRoundTrip(value)},
    }
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    compareWithTolerance = compareWithTolerance,
    deepEquals = deepEquals,
    getVersion = getVersion,
    isNaN = isNaN,
    testAllRoundTrips = testAllRoundTrips,
    testLuaRoundTrip = testLuaRoundTrip,
    testMessagePackRoundTrip = testMessagePackRoundTrip,
    testNaturalJSONRoundTrip = testNaturalJSONRoundTrip,
    testTypedJSONRoundTrip = testTypedJSONRoundTrip,
    testXMLRoundTrip = testXMLRoundTrip,
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
