-- Module name
local NAME = "global_reset"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 17, 0)

-- Internal state: list of registered reset functions
local resetFunctions = {}

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

--- Registers a function to be called when reset() is invoked.
--- Modules with modifiable internal state (e.g., caches) should call this
--- during initialization, passing a function that restores their state to
--- its original (post-load) condition.
--- @param fn function A no-argument function that resets the calling module's state
--- @error Throws if fn is not a function
local function register(fn)
    assert(type(fn) == "function", "Expected function, got " .. type(fn))
    resetFunctions[#resetFunctions + 1] = fn
end

--- Calls all registered reset functions, restoring every registered module
--- to its original state. The order of invocation is unspecified.
--- After reset() completes, the registered functions remain registered and
--- can be called again by a subsequent reset().
local function reset()
    for i = 1, #resetFunctions do
        resetFunctions[i]()
    end
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    register = register,
    reset = reset,
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

-- Inline read-only wrapper (no project dependencies)
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
