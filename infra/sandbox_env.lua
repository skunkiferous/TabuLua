-- Module name
local NAME = "sandbox_env"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 35, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

-- The kikito sandbox rock, needed only for its quota_supported capability
-- flag (see protectOptions below).
local sandbox = require("sandbox")

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

-- ============================================================
-- Quota hardening
--
-- kikito's quota is a `debug.sethook` count hook that, when it fires, REMOVES
-- itself (restoring `string.rep` too) and raises 'Quota exceeded: <n>'. Two
-- stock-sandbox globals let user code survive that:
--   * `pcall` / `xpcall` catch the quota error, after which the code runs on
--     with no hook at all (and with `string.rep` back);
--   * `coroutine`: hooks are per-thread, so a body run via coroutine.wrap /
--     resume is never counted (and resume also catches the quota error).
-- So every sandbox gets quota-rethrowing pcall/xpcall and no coroutines.
-- ============================================================

-- Marker of the error kikito's quota hook raises ('Quota exceeded: ' .. quota).
local QUOTA_MARKER = "Quota exceeded: "

local function isQuotaError(e)
    return type(e) == "string" and e:find(QUOTA_MARKER, 1, true) ~= nil
end

-- Passes pcall/xpcall results through, but re-raises a quota error.
local function rethrowQuota(ok, ...)
    if not ok and isQuotaError((...)) then
        error((...), 0)
    end
    return ok, ...
end

local function safePcall(f, ...)
    return rethrowQuota(pcall(f, ...))
end

-- The handler runs AFTER the quota hook removed itself, so it must never see
-- a quota error: it could otherwise loop unbounded.
local function safeXpcall(f, handler, ...)
    local function guarded(e)
        if isQuotaError(e) then
            return e
        end
        return handler(e)
    end
    return rethrowQuota(xpcall(f, guarded, ...))
end

-- Stands in for the sandbox library's `coroutine`; any use fails clearly.
local NO_COROUTINE = setmetatable({}, {
    __index = function(_, k)
        error("coroutine." .. tostring(k) .. " is not available in the sandbox", 2)
    end,
    __newindex = function()
        error("coroutine is not available in the sandbox", 2)
    end,
    __metatable = false,
})

--- Builds the options table for `sandbox.protect`, applying the instruction
--- quota only where the sandbox library can enforce one. kikito's sandbox
--- implements quotas with `debug.sethook` count hooks, which LuaJIT does not
--- support — passing `quota` there raises instead of protecting, so every
--- call site that hard-codes `{quota = n, env = e}` is broken on LuaJIT.
--- This is the single place allowed to know that; on LuaJIT the code runs
--- sandboxed but without an operation limit.
---
--- `env` is layered under a thin table that overrides `pcall`, `xpcall` and
--- `coroutine` (see "Quota hardening"). The sandbox copies its own base
--- globals from the passed env only where that env has a non-nil value, so
--- this layer is the only way to replace them; other keys fall through to
--- `env`, including ones the caller adds after this call.
--- @param quota number Maximum operations allowed (ignored where unsupported)
--- @param env table|nil The sandbox environment
--- @return table Options for sandbox.protect
local function protectOptions(quota, env)
    local layered = setmetatable({
        coroutine = NO_COROUTINE,
        pcall = safePcall,
        xpcall = safeXpcall,
    }, {__index = env})
    local opt = {env = layered}
    if sandbox.quota_supported then
        opt.quota = quota
    end
    return opt
end

-- Instruction-quota floor for a data chunk. A literal costs roughly one VM op
-- per element, so the quota scales with the source size, with this floor.
local DATA_QUOTA_FLOOR = 1000000

--- Returns the instruction quota for a data chunk of the given source.
--- @param code string The chunk source
--- @return number The quota
local function dataQuota(code)
    return math.max(DATA_QUOTA_FLOOR, #code * 16)
end

--- Compiles and runs a DATA chunk: Lua source that should only build a value
--- (a `.lua` import, a serialized cell), not compute. It is compiled
--- text-only (never bytecode) in `env` alone, and runs under an instruction
--- quota where the runtime supports one (not LuaJIT). String methods are
--- switched off while it runs, so e.g. `("x"):rep(1e9)` cannot be reached
--- through the string metatable. Neither the quota nor the string
--- metatable can be escaped: `env` holds no pcall or coroutine. A hook
--- already installed (e.g. by an enclosing sandbox run) is restored after.
---
--- The count hook also counts runData's OWN instructions, around the
--- protected call: it raises only when the running function is not runData
--- itself. Raising there would escape the pcall, leaving string methods off
--- and the hook installed for whatever runs next.
--- @param code string The chunk source
--- @param chunkname string The chunk name used in error messages
--- @param env table The chunk's entire global environment
--- @param quota number|nil Maximum operations (default: dataQuota(code))
--- @return boolean ok True on success
--- @return any The chunk's first result, or the error message
--- @return string|nil On failure, "compile" or "run"
local function runData(code, chunkname, env, quota)
    local fn, err = load(code, chunkname, "t", env)
    if not fn then
        return false, err, "compile"
    end
    quota = quota or dataQuota(code)
    local useHook = sandbox.quota_supported and type(debug) == "table"
        and type(debug.sethook) == "function"
    local oldHook, oldMask, oldCount
    if useHook then
        oldHook, oldMask, oldCount = debug.gethook()
        debug.sethook(function()
            -- Level 2: the function that was running when the hook fired
            if debug.getinfo(2, "f").func ~= runData then
                error(QUOTA_MARKER .. tostring(quota), 2)
            end
        end, "", quota)
    end
    local stringMeta = getmetatable("")
    local stringIndex = stringMeta.__index
    stringMeta.__index = nil
    local ok, result = pcall(fn)
    stringMeta.__index = stringIndex
    if useHook then
        -- A hook set from C reads back as the string "external hook", and
        -- cannot be reinstalled from Lua
        if type(oldHook) == "function" then
            debug.sethook(oldHook, oldMask, oldCount)
        else
            debug.sethook()
        end
    end
    if not ok then
        return false, result, "run"
    end
    return true, result
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
    protectOptions = protectOptions,
    dataQuota = dataQuota,
    runData = runData,
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
