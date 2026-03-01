-- Module name
local NAME = "number_identifiers"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 14, 0)

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- Dependencies
local read_only = require("read_only")
local readOnly = read_only.readOnly
local error_reporting = require("error_reporting")

--- Logs a bad value using the error reporting system.
--- @param badVal function The badVal callback for logging errors
--- @param type string The expected type name for the value
--- @param value any The invalid value that was encountered
--- @param error string The error message describing the problem
--- @return any The return value from badVal
local function log(badVal, type, value, error)
    return error_reporting.withColType(badVal, type, function()
        badVal(value, error)
    end)
end

--- Converts a number to a valid Lua identifier string.
--- Handles special cases: NaN becomes "_NaN", infinity becomes "_Infinity"/"_NegativeInfinity".
--- Integers are encoded as "_I<num>" or "_I_<num>" (for negative).
--- Floats are encoded as "_F<int>_<decimal>" or "_F_<int>_<decimal>" (for negative).
---
--- @param badVal function The badVal callback for logging errors
--- @param num number The number to convert
--- @return string|nil The identifier string, or nil if num is not a number
--- @error Logs error via badVal if num is not a number
local function numberToIdentifier(badVal, num)
    local t = type(num)
    if t ~= "number" then
        log(badVal, 'number', num, 'num must be a number')
        return nil
    end

    if num ~= num then -- Check for NaN
        return "_NaN"
    end
    if num == math.huge then
        return "_Infinity"
    end
    if num == -math.huge then
        return "_NegativeInfinity"
    end

    local mt = math.type(num)
    if mt == "integer" then
        if num < 0 then
            return "_I_" .. tostring(num):sub(2)
        else
            return "_I" .. num
        end
    else
        -- Format float with minimum precision needed for round-trip
        local str = string.format("%.17f", num)  -- Fallback (always overwritten)
        for precision = 1, 17 do
            str = string.format("%." .. precision .. "f", num)
            if tonumber(str) == num then
                break
            end
        end
        str = str:gsub("0+$", "")
        if num < 0 then
            return "_F_" .. str:sub(2):gsub("%.", "_") -- Skip the minus sign
        else
            return "_F" .. str:gsub("%.", "_")
        end
    end
end

--- Converts an identifier string back to the number it represents.
--- Inverse of numberToIdentifier(). Handles "_NaN", "_Infinity", "_NegativeInfinity",
--- "_I..." (integers), and "_F..." (floats).
---
--- @param badVal function The badVal callback for logging errors
--- @param id string The identifier string to convert
--- @return number|nil The number value, or nil if id is invalid
--- @error Logs error via badVal if id is not a string or has invalid format
local function identifierToNumber(badVal, id)
    if type(id) ~= "string" then
        log(badVal, 'string', id, 'id must be a string')
        return nil
    end

    -- Handle special cases first
    if id == "_NaN" then
        return 0/0  -- NaN
    end
    if id == "_Infinity" then
        return math.huge
    end
    if id == "_NegativeInfinity" then
        return -math.huge
    end

    -- Check prefix format
    local prefix = id:sub(1, 2)
    if prefix ~= "_I" and prefix ~= "_F" then
        log(badVal, 'string', id, 'id must start with _I or _F')
        return nil
    end

    -- Handle integers
    if prefix == "_I" then
        -- Check if it's negative (has extra underscore)
        if id:sub(3, 3) == "_" then
            return -tonumber(id:sub(4))
        else
            return tonumber(id:sub(3))
        end
    end

    -- Handle floats
    if prefix == "_F" then
        -- Check if it's negative
        if id:sub(3, 3) == "_" then
            -- Replace underscore with decimal point, skip the _F_ prefix
            local numStr = id:sub(4):gsub("_", ".", 1)
            return -tonumber(numStr)
        else
            -- Replace underscore with decimal point, skip the _F prefix
            local numStr = id:sub(3):gsub("_", ".", 1)
            return tonumber(numStr)
        end
    end
    -- Should never get here
    return nil
end

--- Creates an identifier string representing an inclusive numeric interval [min, max].
--- Format: "_R_GE<min_id>_LE<max_id>" where min_id/max_id are numberToIdentifier() outputs.
--- Either min or max can be nil (unbounded), but not both.
---
--- @param badVal function The badVal callback for logging errors
--- @param min number|nil The minimum bound (inclusive), or nil for unbounded below
--- @param max number|nil The maximum bound (inclusive), or nil for unbounded above
--- @return string|nil The range identifier, or nil on error
--- @error Logs error via badVal if: both min and max are nil, either is NaN/infinite,
---        min > max, or either is not a number/nil
local function rangeToIdentifier(badVal, min, max)
    local t_min = type(min)
    local t_max = type(max)
    if t_min ~= "number" and t_min ~= "nil" then
        log(badVal, 'number', min, 'min must be a number or nil')
        return nil
    end
    if t_max ~= "number" and t_max ~= "nil" then
        log(badVal, 'number', max, 'max must be a number or nil')
        return nil
    end
    if t_min == "nil" and t_max == "nil" then
        log(badVal, 'number', nil, 'min and max cannot both be nil')
        return nil
    end
    if min then
        if min ~= min then
            log(badVal, 'number', min, 'min cannot be NaN')
            return nil
        end
        if min == math.huge or min == -math.huge then
            log(badVal, 'number', min, 'min cannot be infinite')
            return nil
        end
    end
    if max then
        if max ~= max then
            log(badVal, 'number', max, 'max cannot be NaN')
            return nil
        end
        if max == math.huge or max == -math.huge then
            log(badVal, 'number', max, 'max cannot be infinite')
            return nil
        end
    end
    if min and max and min > max then
        log(badVal, 'range', string.format("[%s,%s]", min, max),
            'min must be <= max')
        return nil
    end

    local result = '_R'  -- 'R' for Range
    if t_min ~= "nil" then
        -- "value" must be "greater-or-equal" to min, if defined
        result = result .. '_GE' .. numberToIdentifier(badVal, min)
    end
    if t_max ~= "nil" then
        -- "value" must be "lesser-or-equal" to max, if defined
        result = result .. '_LE' .. numberToIdentifier(badVal, max)
    end
    return result
end

--- Parses a range identifier back to its min and max bounds.
--- Inverse of rangeToIdentifier().
---
--- @param badVal function The badVal callback for logging errors
--- @param id string The range identifier string (must start with "_R")
--- @return number|nil, number|nil The min and max bounds, or nil,nil on error
--- @error Logs error via badVal if: id is not a string, doesn't start with "_R",
---        is empty ("_R"), has invalid format, or min > max
local function identifierToRange(badVal, id)
    if type(id) ~= "string" then
        log(badVal, 'string', id, 'id must be a string')
        return nil, nil
    end

    -- Must start with _R prefix
    if id:sub(1, 2) ~= "_R" then
        log(badVal, 'string', id, 'id must start with _R')
        return nil, nil
    end

    -- Empty range not allowed
    if #id == 2 then
        log(badVal, 'string', id, 'Empty range not allowed')
        return nil, nil
    end

    local min, max = nil, nil
    local rest = id:sub(3)  -- Skip _R prefix

    -- Check if we have a GE part
    if rest:sub(1, 3) == "_GE" then
        -- Find where the GE number ends
        local le_pos = rest:find("_LE", 4, true)
        local num_str
        if le_pos then
            num_str = rest:sub(4, le_pos - 1)
        else
            num_str = rest:sub(4)
        end
        min = identifierToNumber(badVal, num_str)
        if not min then
            log(badVal, 'string', id, 'min number invalid')
            return nil, nil
        end
        rest = le_pos and rest:sub(le_pos) or ""
    end

    -- Check if we have a LE part
    if rest ~= "" then
        if rest:sub(1, 3) ~= "_LE" then
            log(badVal, 'string', id, 'max part invalid')
            return nil, nil
        end
        local num_str = rest:sub(4)
        max = identifierToNumber(badVal, num_str)
        if not max then
            log(badVal, 'string', id, 'max number invalid')
            return nil, nil
        end
    end

    -- At least one bound must be defined
    if min == nil and max == nil then
        log(badVal, 'string', id, 'min and max cannot be both nil')
        return nil, nil
    end

    -- If both bounds are defined, min must be <= max
    if min and max and min > max then
        log(badVal, 'string', id, 'min cannot be greater than max')
        return nil, nil
    end

    return min, max
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion=getVersion,
    identifierToNumber=identifierToNumber,
    identifierToRange=identifierToRange,
    numberToIdentifier=numberToIdentifier,
    rangeToIdentifier=rangeToIdentifier,
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
