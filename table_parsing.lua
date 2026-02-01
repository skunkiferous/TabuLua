-- Module name
local NAME = "table_parsing"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 3, 0)

-- Dependencies
local ltcn = require("ltcn")

local read_only = require("read_only")
local readOnly = read_only.readOnly

local error_reporting = require("error_reporting")
local withColType = error_reporting.withColType

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- Maximum table depth
local MAX_TABLE_DEPTH = 10

--- Gets the maximum nesting depth of tables in a value.
--- @param value any The value to check (returns 0 for non-tables)
--- @param in_process table|nil Internal: tracks tables to detect recursion
--- @return number|nil The max depth, or nil on error
--- @return string|nil Error message if recursive table detected
local function getMaxTableDepth(value, in_process)
    -- Handle non-table values
    if type(value) ~= "table" then
        return 0
    end

    -- Initialize in_process on first call
    in_process = in_process or {}

    -- Check for recursion
    if in_process[value] then
        return nil, "recursive table detected"
    end

    -- Mark this table as being processed
    in_process[value] = true

    -- Track maximum depth of nested tables
    local max_depth = 0

    -- Check depth of all table values
    for _, v in pairs(value) do
        if type(v) == "table" then
            local depth, err = getMaxTableDepth(v, in_process)
            if not depth then
                return nil, err -- Propagate recursion error
            end
            max_depth = math.max(max_depth, depth)
        end
    end

    -- Remove this table from the processing set before returning
    in_process[value] = nil

    -- Add 1 for this table's depth
    return max_depth + 1
end

--- Parses a Lua table literal from a string using ltcn (safe parser, not eval).
--- Does not support: tables as keys, nil values (use '' instead).
--- @param badVal table A badVal instance for error reporting
--- @param col_type string The column type name (for error messages)
--- @param value string The string containing the Lua table literal
--- @return table|nil The parsed table, or nil on failure
--- @error Logs errors via badVal for: parse errors, non-table result, recursion,
---        or depth exceeding MAX_TABLE_DEPTH
local function parseTableStr(badVal, col_type, value)
    local ct = type(col_type)
    assert(ct == "string", "col_type must be a string: "..ct)
    local success, parsed = pcall(ltcn.parse, "return " .. value)

    withColType(badVal, col_type, function()
        if not success then
            badVal(value, parsed)  -- On failure, parsed contains the error message
            return nil
        end

        if type(parsed) ~= "table" then
            badVal(value, "not a table")
            return nil
        end

        -- Check table depth and recursion
        local depth, err = getMaxTableDepth(parsed)
        if not depth then
            badVal(value, "Invalid table: " .. err)
            return nil
        end
        if depth > MAX_TABLE_DEPTH then
            badVal(value, "Table exceeds maximum depth of " .. MAX_TABLE_DEPTH)
            return nil
        end
    end)
    return parsed
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getMaxTableDepth=getMaxTableDepth,
    getVersion=getVersion,
    parseTableStr=parseTableStr,
    MAX_TABLE_DEPTH = MAX_TABLE_DEPTH,
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
