-- Module name
local NAME = "bit_ops"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 31, 0)

-- Dependencies
local read_only = require("util.read_only")
local readOnly = read_only.readOnly

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.31.0")
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- Cross-version 32-bit bitwise primitives.
--
-- Lua 5.3+ has native bitwise OPERATORS (&, |, ~, <<, >>); LuaJIT (5.1
-- syntax) cannot even PARSE them, so any file spelling them out is
-- unloadable there — no runtime shim can help a syntax error. This module
-- is the one place allowed to know that: the native path is compiled from
-- a STRING (load), so this file itself stays parseable everywhere, and
-- LuaJIT falls back to its `bit` library (Lua 5.2's `bit32` as a last
-- resort).
--
-- Contract: arguments are integers in [0, 2^32); results are ALWAYS
-- normalized to that same unsigned range. That normalization is the other
-- reason this module exists: LuaJIT's bit.* returns SIGNED 32-bit numbers
-- (bit.bxor can be negative), which would corrupt comparisons against
-- unsigned values parsed from file bytes (CRC-32 checks, zip fields).
-- ============================================================

-- 2^32, for signed→unsigned normalization (Lua's % takes the divisor's
-- sign, so a negative signed-32-bit value lands on the right unsigned one).
local MOD32 = 0x100000000

-- Lua 5.3+ native operators, compiled from a string so LuaJIT never parses
-- them. Inputs in-contract produce in-range results directly; the 64-bit
-- masks keep an out-of-range shift from leaking sign bits.
local NATIVE_SRC = [[
return {
    band = function(a, b) return a & b end,
    bor = function(a, b) return a | b end,
    bxor = function(a, b) return a ~ b end,
    lshift = function(a, n) return (a << n) & 0xFFFFFFFF end,
    rshift = function(a, n) return (a & 0xFFFFFFFF) >> n end,
}
]]

local function buildNative()
    local chunk = (load or loadstring)(NATIVE_SRC)
    if not chunk then
        return nil
    end
    local ok, ops = pcall(chunk)
    if ok and type(ops) == "table" then
        return ops
    end
    return nil
end

-- LuaJIT `bit` (or Lua 5.2 `bit32`): wrap each op to re-normalize the
-- signed results into the unsigned contract.
local function buildFromLibrary()
    local ok, lib = pcall(require, "bit")
    if not ok or type(lib) ~= "table" then
        ok, lib = pcall(require, "bit32")
    end
    if not ok or type(lib) ~= "table" then
        return nil
    end
    return {
        band = function(a, b) return lib.band(a, b) % MOD32 end,
        bor = function(a, b) return lib.bor(a, b) % MOD32 end,
        bxor = function(a, b) return lib.bxor(a, b) % MOD32 end,
        lshift = function(a, n) return lib.lshift(a, n) % MOD32 end,
        rshift = function(a, n) return lib.rshift(a, n) % MOD32 end,
    }
end

local ops = buildNative() or buildFromLibrary()
if not ops then
    error(NAME .. ": no bitwise implementation available "
        .. "(need Lua 5.3+ operators, LuaJIT's bit, or Lua 5.2's bit32)")
end

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    band = ops.band,
    bor = ops.bor,
    bxor = ops.bxor,
    lshift = ops.lshift,
    rshift = ops.rshift,
    getVersion = getVersion,
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
