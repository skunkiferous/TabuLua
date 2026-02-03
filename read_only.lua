-- Module name
local NAME = "read_only"

local os = require("os")

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 5, 0)
local semver_mt = getmetatable(VERSION)

-- Dependencies
local table_utils = require("table_utils")
local tableShallowCopy = table_utils.tableShallowCopy
local wrappedPairs = table_utils.wrappedPairs
local wrappedIpairs = table_utils.wrappedIpairs

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- Special key used to store the original table in the read-only proxy
local ROP_t = {}

--- Unwraps a read-only proxy to get the original table.
--- If the value is not a read-only proxy, returns it unchanged.
--- This is useful for testing/comparison purposes where you need to access the raw data.
---
--- @param t any The value to unwrap
--- @return any The unwrapped table if t is a read-only proxy, otherwise t unchanged
local function unwrap(t)
    if type(t) == "table" and t[ROP_t] then
        return t[ROP_t]
    end
    return t
end

-- Forward declaration of readOnly
local readOnlyRef

-- Shared read-only metatable
local readOnly_mt = {
    -- Child-tables are read-only too
    __index = function(p, k)
        return readOnlyRef(p[ROP_t][k])
    end,
    -- The whole point is that we can't update a read-only table
    __newindex = function(_p, _k, _v)
        error("attempt to update a read-only table", 2)
    end,
    -- We need to make the values read-only before returning them
    __pairs =  function (p) return wrappedPairs(p[ROP_t], readOnlyRef) end,
    -- We need to make the values read-only before returning them
    __ipairs =  function (p) return wrappedIpairs(p[ROP_t], readOnlyRef) end,
    __len =  function (p) return #p[ROP_t] end,
    __metatable = "read-only table"
}

-- Cache for meta-tables for read-only tables, which were created using opt_index
local readOnly_mt_cache = {}
setmetatable(readOnly_mt_cache, { __mode = "k" })

--- Converts a value to a string representation for debugging.
--- This is a local implementation to avoid circular dependency with serialization module.
--- @param t any The value to convert to string
--- @return string A string representation of the value
local function dump(t)
    if type(t) == "table" then
        local r = {'{'}
        local sep = ''
        local meta = getmetatable(t)
        if meta ~= nil then
            sep = ','
            r[#r+1] = '<metatable>='
            if meta == t then
                r[#r+1] = '<self>'
            else
                r[#r+1] = dump(meta)
            end
        end
        for k, v in pairs(t) do
            r[#r+1] = sep
            sep = ','
            r[#r+1] = dump(k)
            r[#r+1] = '='
            r[#r+1] = dump(v)
        end
        r[#r+1] = '}'
        return table.concat(r)
    else
        return (t == nil) and "nil" or (type(t) .. ":" .. tostring(t))
    end
end

--- Creates a read-only proxy for a table, preventing modifications.
--- Non-table values are returned unchanged (they are inherently immutable).
--- Tables with existing metatables (except 'badVal' and semver) are returned unchanged with an error logged.
---
--- @param t any The value to make read-only. If not a table, returns t unchanged.
--- @param opt_index table|nil Optional table providing additional index entries and metamethod overrides:
---   - Regular keys: Added to the proxy's index (accessible as properties)
---   - __tostring: Custom string conversion function
---   - __call: Makes the proxy callable
---   - __index: Custom index function called when key not found: function(original_table, key) -> value
---   - __type: Custom type string (assigned to __metatable, returned by getmetatable)
--- @return any A read-only proxy if t is a table without metatable, otherwise t unchanged
--- @side_effect Logs an error if t has a metatable (except 'badVal' and semver objects)
--- @warning This protection can be bypassed using next() - this is a Lua limitation
local function readOnly(t, opt_index)
    -- Don't wrap already-read-only tables, or tables with a metatable
    if type(t) == "table" and not t[ROP_t] then
        local t_mt = getmetatable(t)
        if t_mt ~= nil then
            -- Ignore badVal and semver objects
            if t_mt ~= 'badVal' and t_mt ~= semver_mt then
                local now = os.date("%Y-%m-%d %H:%M:%S")..'.000000 '
                print(now.."ERROR [read_only] Can't make tables with a metatable read only: ".. dump(t))
            end
            return t
        end
        local proxy = {}
        -- The user of the proxy does no have access to ROP_t, and so cannot get t
        proxy[ROP_t] = t
        -- We have a default meta-table, if t has no opt_index
        -- Tables with a non-empty opt_index have their own meta-table,
        -- and therefore are "more expensive" to create
        local mt = readOnly_mt
        if type(opt_index) == "table" and next(opt_index) then
            mt = readOnly_mt_cache[opt_index]
            if not mt then
                -- Create a new meta-table
                -- Does opt_index define a custom __index?
                local opt_if = type(opt_index.__index) == "function"
                    and opt_index.__index or nil
                mt = tableShallowCopy(readOnly_mt)
                mt.__index = function(p, k)
                    -- The primary purpose of opt_index is to serve as an index
                    local v = opt_index[k]
                    if v == nil then
                        -- If the key is not found in opt_index, it is checked in the
                        -- original table
                        local tb = p[ROP_t]
                        v = tb[k]
                        -- And if the key is still not found, and opt_index defines
                        -- a __index, it is called
                        if opt_if and v == nil then
                            v = opt_if(tb, k)
                        end
                    end
                    -- No matter where v comes from, still make sure it is read-only
                    return readOnlyRef(v)
                end
                -- Does opt_index define a custom __tostring?
                if opt_index.__tostring then
                    mt.__tostring = opt_index.__tostring
                end
                -- Does opt_index define a custom __call?
                if opt_index.__call then
                    mt.__call = opt_index.__call
                end
                -- Does opt_index define a custom __type?
                -- (Only useful when using a a custom type(x) function)
                if opt_index.__type then
                    mt.__metatable = opt_index.__type
                end
                -- Just in case opt_index is reused, we cache the meta-table too
                readOnly_mt_cache[opt_index] = mt
            end
        end
        -- Now that we have our meta-table, we can use it on the proxy,
        -- so that the proxy act like t, except not modifiable
        setmetatable(proxy, mt)
        return proxy
    end
    -- Everything else is read-only anyway
    return t
end
readOnlyRef = readOnly

-- Shared opt_index for tuples, providing _<integer> aliases
local tuple_opt_index = {
    __index = function(tb, k)
        if type(k) == "string" then
            local idx = k:match("^_(%d+)$")
            if idx then
                idx = tonumber(idx)
                if idx > 0 then
                    return tb[idx]
                end
            end
        end
        return nil
    end,
    __type = "tuple"
}

--- Creates a read-only proxy for a tuple table with _<integer> field aliases.
--- Allows accessing tuple fields both by index (tuple[1]) and by alias (tuple._1).
---
--- @param t table The tuple table to make read-only. Must be a table.
--- @param validate boolean|nil If true, validates that t is a proper tuple (sequential integer keys starting at 1)
--- @return table|nil A read-only tuple proxy, or nil if validation fails
--- @return string|nil Error message if validation fails
local function readOnlyTuple(t, validate)
    if type(t) ~= "table" then
        return nil, "readOnlyTuple expects a table, got " .. type(t)
    end
    if validate then
        -- Check that the table has sequential integer keys starting at 1
        local count = 0
        for k, _ in pairs(t) do
            if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
                return nil, "tuple contains non-positive-integer key: " .. tostring(k)
            end
            count = count + 1
        end
        -- Check for holes
        for i = 1, count do
            if t[i] == nil then
                return nil, "tuple has a hole at index " .. i
            end
        end
    end
    return readOnly(t, tuple_opt_index)
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion=getVersion,
    readOnly=readOnly,
    readOnlyTuple=readOnlyTuple,
    unwrap=unwrap,
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
