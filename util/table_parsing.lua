-- Module name
local NAME = "table_parsing"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 32, 0)

-- Dependencies
local ltcn = require("ltcn")

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

local error_reporting = require("infra.error_reporting")
local withColType = error_reporting.withColType

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- Maximum table depth
local MAX_TABLE_DEPTH = 10

local int64 = require("util.int64")

-- The Lua-literal int64 tag written by serialization.lua: {__int64 = "<digits>"}.
-- ltcn lexes a bare number literal before any int64 code can see it, so an
-- int64 inside a table cell has to arrive wrapped or it arrives as a double.
local INT64_WRAPPER_KEY = "__int64"

-- 2^53: the first magnitude a double cannot hold exactly, as text.
local DOUBLE_EXACT_LIMIT = "9007199254740992"

-- True if a run of decimal digits denotes a magnitude >= 2^53.
local function exceedsDoubleRange(digits)
    digits = digits:gsub("^0+", "")
    if #digits > #DOUBLE_EXACT_LIMIT then
        return true
    end
    return #digits == #DOUBLE_EXACT_LIMIT and digits >= DOUBLE_EXACT_LIMIT
end

-- Finds a BARE integer literal in a table cell that a double cannot represent
-- exactly, or nil if there is none.
--
-- WHY THIS EXISTS. ltcn lexes number literals itself, before any type-specific
-- code runs, so a declared {int64} cell never gets the chance to parse its own
-- text. MEASURED on LuaJIT, where every number is a double:
--
--     {9007199254740993, 9007199254740994}
--       elem 1 -> 9007199254740992   -- SILENTLY wrong, no error
--       elem 2 -> rejected as "beyond +/-2^53"
--
-- On Lua 5.3+ the same cell is exact, because ltcn produces a native integer.
-- So the same data file means different things on different runtimes -- the
-- precise version-dependence int64 was introduced to remove -- and one of the
-- two outcomes is silent corruption.
--
-- Detection is TEXTUAL and therefore identical on every runtime: by the time a
-- value exists, the digits the author wrote are already gone. Quoted strings
-- are skipped, since a quoted "9007199254740993" is the CORRECT way to write
-- one and must keep working. Anything with a fractional part or an exponent is
-- left alone: it is a float, and was never claiming to be exact.
local function findUnsafeIntegerLiteral(text)
    local i = 1
    local n = #text
    while i <= n do
        local c = text:sub(i, i)
        if c == '"' or c == "'" then
            -- Skip the string, honouring backslash escapes
            local quote = c
            i = i + 1
            while i <= n do
                local ch = text:sub(i, i)
                if ch == "\\" then
                    i = i + 2
                elseif ch == quote then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
        elseif c:match("%d") then
            local s, e = text:find("^%d+", i)
            local before = s > 1 and text:sub(s - 1, s - 1) or ""
            local after = text:sub(e + 1, e + 1)
            -- Part of a float, a hex literal or an identifier: not our business
            local isPlainInteger = not before:match("[%w_.]")
                and not after:match("[%w_.]")
            if isPlainInteger and exceedsDoubleRange(text:sub(s, e)) then
                return text:sub(s, e)
            end
            i = e + 1
        else
            i = i + 1
        end
    end
    return nil
end

-- Converts {__int64 = "<canonical digits>"} nodes into int64 boxes, in place.
--
-- Deliberately narrow, exactly as the typed-JSON tag is: the table must have
-- that ONE key and nothing else, and the value must be a string int64.of()
-- accepts. Anything else is left alone, so a user table that merely happens to
-- contain a __int64 field keeps its own meaning.
local function unwrapInt64(value, in_process)
    if type(value) ~= "table" then
        return value
    end
    in_process = in_process or {}
    if in_process[value] then
        return value          -- recursion is reported by getMaxTableDepth
    end
    in_process[value] = true
    local digits = value[INT64_WRAPPER_KEY]
    if type(digits) == "string" and next(value, next(value)) == nil then
        local box = int64.of(digits)
        if box ~= nil then
            in_process[value] = nil
            return box
        end
    end
    for k, v in pairs(value) do
        if type(v) == "table" then
            local converted = unwrapInt64(v, in_process)
            if converted ~= v then
                value[k] = converted
            end
        end
    end
    in_process[value] = nil
    return value
end

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

    local valid = withColType(badVal, col_type, function()
        -- Checked on the TEXT, before anything looks at the parsed value: by
        -- then the digits are gone and the damage is done (see
        -- findUnsafeIntegerLiteral).
        local unsafe = findUnsafeIntegerLiteral(value)
        if unsafe then
            badVal(value, "the integer literal " .. unsafe .. " cannot be "
                .. "represented exactly by a Lua number on every runtime "
                .. "(it exceeds 2^53), so it would be silently rounded here. "
                .. "Write it as a quoted string, or as {" .. INT64_WRAPPER_KEY
                .. "=\"" .. unsafe .. "\"} to read it back as an int64")
            return false
        end
        if not success then
            badVal(value, parsed)  -- On failure, parsed contains the error message
            return false
        end

        if type(parsed) ~= "table" then
            badVal(value, "not a table")
            return false
        end

        -- Check table depth and recursion
        local depth, err = getMaxTableDepth(parsed)
        if not depth then
            badVal(value, "Invalid table: " .. err)
            return false
        end
        if depth > MAX_TABLE_DEPTH then
            badVal(value, "Table exceeds maximum depth of " .. MAX_TABLE_DEPTH)
            return false
        end
        return true
    end)
    if not valid then
        return nil
    end
    -- The walk would otherwise run over every parsed table cell in the model,
    -- so the raw text is checked for the marker first -- a plain substring scan
    -- that fails immediately on the overwhelming majority of cells.
    if value:find(INT64_WRAPPER_KEY, 1, true) then
        parsed = unwrapInt64(parsed)
    end
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
