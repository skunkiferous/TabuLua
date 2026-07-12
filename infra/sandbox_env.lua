-- Module name
local NAME = "sandbox_env"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 31, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

local predicates = require("util.predicates")
local string_utils = require("util.string_utils")
local table_utils = require("util.table_utils")
local comparators = require("util.comparators")

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- Curated safe building blocks
--
-- This module is the SINGLE owner of "the safe API surface" — what user
-- code (validators, processors, code libraries, custom-type `validate`
-- expressions, `transformCells` expressions, cell expressions, COG scripts)
-- is allowed to see inside the kikito sandbox.
--
-- The tables below are module-level constants. They are NEVER mutated after
-- construction, so they can be shared across every environment this module
-- hands out. Per-run, mutable environment TABLES are produced fresh by the
-- factory functions further down — the sandbox assigns `env._G = env` and
-- call sites inject per-run keys (`self`, `value`, `rows`, ...), so a shared
-- env table would be unsafe.
-- ============================================================

-- Lua globals every sandbox may safely have.
-- Deliberately EXCLUDES: require/module, load/loadstring/loadfile, dofile,
-- collectgarbage, rawget/rawset/rawequal, set/getmetatable, debug, io, os,
-- print, _G. Any of those would defeat the read-only layer or the sandbox.
local SAFE_BUILTINS = {
    assert = assert,
    error = error,
    ipairs = ipairs,
    next = next,
    pairs = pairs,
    pcall = pcall,
    select = select,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    unpack = unpack or table.unpack,
    xpcall = xpcall,
}

-- Curated subset of the `string` library.
-- Excludes `dump` (leaks compiled bytecode) and `rep` (cheap
-- memory-exhaustion vector; the kikito sandbox nils it during execution
-- anyway). Every remaining entry is a pure, side-effect-free function.
local SAFE_STRING = {
    byte = string.byte,
    char = string.char,
    find = string.find,
    format = string.format,
    gmatch = string.gmatch,
    gsub = string.gsub,
    len = string.len,
    lower = string.lower,
    match = string.match,
    pack = string.pack,
    packsize = string.packsize,
    reverse = string.reverse,
    sub = string.sub,
    unpack = string.unpack,
    upper = string.upper,
}

-- Curated subset of the `table` library.
-- Every `table` function is a pure data operation, so all are included --
-- notably `concat`, which the stock sandbox BASE_ENV omits and which COG
-- scripts depend on.
local SAFE_TABLE = {
    concat = table.concat,
    insert = table.insert,
    move = table.move,
    pack = table.pack,
    remove = table.remove,
    sort = table.sort,
    unpack = table.unpack,
}

-- The TabuLua helper block: pure, side-effect-free utilities exposed to EVERY
-- sandbox this module hands out — validators, processors, code libraries,
-- custom-type `validate` expressions, `transformCells`, and (as of v0.22.0)
-- cell expressions and COG scripts too. The cell-expression / COG surface was
-- unified with the code-library surface so that, e.g., a COG doc block and the
-- library it calls see exactly the same safe API (see `cogGlobals`).
local SAFE_UTILS = {
    predicates = predicates,
    stringUtils = {
        trim = string_utils.trim,
        split = string_utils.split,
        parseVersion = string_utils.parseVersion,
    },
    tableUtils = {
        keys = table_utils.keys,
        values = table_utils.values,
        pairsCount = table_utils.pairsCount,
        longestMatchingPrefix = table_utils.longestMatchingPrefix,
        sortCaseInsensitive = table_utils.sortCaseInsensitive,
    },
    equals = comparators.equals,
}

-- ============================================================
-- Environment factories
-- ============================================================

--- Builds a FRESH sandbox environment table.
--- The returned table contains the safe builtins, `math`, the curated
--- `string`/`table` subsets, and the TabuLua helper block (`predicates`,
--- `stringUtils`, `tableUtils`, `equals`). `extras` (if given) is
--- shallow-merged on top, so a call site can add its own keys and may
--- override shared ones.
---
--- A fresh table is returned on every call: the sandbox assigns
--- `env._G = env` and call sites inject per-run keys, so the result must
--- never be shared between sandbox runs.
--- @param extras table|nil Call-site-specific environment entries
--- @return table A fresh sandbox environment
local function new(extras)
    local env = {
        math = math,
        string = SAFE_STRING,
        table = SAFE_TABLE,
    }
    for k, v in pairs(SAFE_BUILTINS) do
        env[k] = v
    end
    for k, v in pairs(SAFE_UTILS) do
        env[k] = v
    end
    if extras then
        for k, v in pairs(extras) do
            env[k] = v
        end
    end
    return env
end

--- Builds a FRESH set of safe globals for cell expressions and COG scripts.
--- As of v0.22.0 this is IDENTICAL to `new()` (including the TabuLua helper
--- block `predicates` / `stringUtils` / `tableUtils` / `equals`): the
--- cell-expression / COG surface was unified with the code-library surface, so
--- a COG doc block and the code library it calls share exactly the same safe
--- API. Kept as a distinct, intention-revealing factory because it is used as
--- the `__index` fallback of the `loadEnv` table that backs cell expressions
--- and COG scripts.
--- @return table A fresh table of safe globals
local function cogGlobals()
    return new()
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    new = new,
    cogGlobals = cogGlobals,
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
