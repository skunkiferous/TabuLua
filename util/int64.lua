-- Module name
local NAME = "int64"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 32, 0)

-- Dependencies
local read_only = require("util.read_only")
local readOnly = read_only.readOnly
local string_utils = require("util.string_utils")
local formatInteger = string_utils.formatInteger

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.32.0")
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- Exact 64-bit signed integer values, carried as canonical decimal STRINGS.
--
-- LuaJIT has no native 64-bit integers: every number is a double, exact only
-- through ±2^53, and tonumber() rounds bigger literals before any code can
-- react. A true int64 therefore cannot exist as a NUMBER on LuaJIT — the only
-- portable carrier is its decimal text. This module implements comparison and
-- add/sub arithmetic directly on that text, so the same inputs produce the
-- same results on every supported Lua (5.3, 5.4, 5.5, LuaJIT) with one code
-- path and no version probes in the results.
--
-- Rejected alternatives: FFI int64_t cdata is LuaJIT-only and leaks a foreign
-- type into every downstream boundary (tostring "LL" suffix, type() == "cdata",
-- no interning as table keys, off-limits in the sandbox); hex strings do not
-- dodge the problem, since converting decimal text above 2^53 to hex already
-- requires the bignum math implemented here.
--
-- Contract: every function normalizes its arguments through of() and returns
-- nil plus an error message when an argument is not an int64 or a result
-- overflows the int64 range. A canonical int64 string is an optional '-'
-- followed by digits, no leading zeros, no '-0', within
-- [-9223372036854775808, 9223372036854775807].
-- ============================================================

-- Canonical range bounds (MIN_MAG is MIN without its sign)
local MAX = "9223372036854775807"
local MIN = "-9223372036854775808"
local MIN_MAG = "9223372036854775808"

-- Largest magnitude a double represents exactly AND identically on every
-- supported Lua (2^53). Doubles beyond it may not be the number the caller
-- meant (LuaJIT rounds bigger literals at parse time), so of() rejects them
-- even on versions where this particular double happens to be exact:
-- accepting them would make the same expression version-dependent.
local SAFE_LIMIT = 9007199254740992

-- True native 64-bit integers (Lua 5.3+). compat53 defines a fake math.type
-- on LuaJIT that calls every whole double "integer", so probe with a float.
local HAS_NATIVE_INTEGERS = math.type ~= nil and math.type(1.0) == "float"

--- Compares two magnitudes (digit strings without sign or leading zeros).
--- @param a string First magnitude
--- @param b string Second magnitude
--- @return number -1 if a < b, 0 if equal, 1 if a > b
local function cmpMag(a, b)
    if #a ~= #b then
        return #a < #b and -1 or 1
    end
    if a == b then
        return 0
    end
    return a < b and -1 or 1
end

-- Validates a canonical int64 string; returns it as-is, or nil and an error
-- message.
local function checkString(s)
    if not s:match("^%-?%d+$") then
        return nil, "'" .. s .. "' is not an int64 string "
            .. "(expected an optional '-' followed by digits)"
    end
    local negative = s:sub(1, 1) == "-"
    local mag = negative and s:sub(2) or s
    if #mag > 1 and mag:sub(1, 1) == "0" then
        return nil, "'" .. s .. "' is not canonical (leading zeros)"
    end
    if negative and mag == "0" then
        return nil, "'" .. s .. "' is not canonical (negative zero)"
    end
    if cmpMag(mag, negative and MIN_MAG or MAX) > 0 then
        return nil, "'" .. s .. "' is outside the int64 range ["
            .. MIN .. ", " .. MAX .. "]"
    end
    return s
end

--- Normalizes a value to a canonical int64 string.
---
--- Strings must already be canonical int64 text (see the module comment) and
--- are returned unchanged. Numbers are converted exactly: native 64-bit
--- integers (Lua 5.3+) through the full int64 range, doubles only when
--- integral and within ±2^53 — beyond that a double may not be the value the
--- caller meant on every Lua version, so it is rejected with instructions to
--- pass the value as a string instead.
--- @param v string|number The value to normalize
--- @return string|nil The canonical int64 string, or nil on failure
--- @return string|nil The error message when the first result is nil
local function of(v)
    local t = type(v)
    if t == "string" then
        return checkString(v)
    end
    if t ~= "number" then
        return nil, "expected an int64 string or a number, got " .. t
    end
    if v ~= v then
        return nil, "NaN is not an int64"
    end
    if v == math.huge or v == -math.huge then
        return nil, "infinity is not an int64"
    end
    if v % 1 ~= 0 then
        return nil, "'" .. tostring(v) .. "' has a fractional part"
    end
    if HAS_NATIVE_INTEGERS and math.type(v) == "integer" then
        -- Native integers are exact through the full int64 range, and
        -- tostring() of one never uses scientific notation
        return tostring(v)
    end
    if v < -SAFE_LIMIT or v > SAFE_LIMIT then
        return nil, "'" .. tostring(v) .. "' is a number beyond +/-2^53 and "
            .. "may not be exact on every Lua version; "
            .. "pass the value as an int64 string instead"
    end
    local s = formatInteger(v)
    if s == "-0" then
        s = "0"
    end
    return s
end

-- Splits a canonical int64 string into sign and magnitude.
local function split(s)
    if s:sub(1, 1) == "-" then
        return true, s:sub(2)
    end
    return false, s
end

-- Schoolbook addition of two magnitudes.
local function magAdd(a, b)
    if #a < #b then
        a, b = b, a
    end
    local la, lb = #a, #b
    local res = {}
    local carry = 0
    for i = 0, la - 1 do
        local d = a:byte(la - i) - 48 + carry
        if i < lb then
            d = d + b:byte(lb - i) - 48
        end
        if d >= 10 then
            d = d - 10
            carry = 1
        else
            carry = 0
        end
        res[la - i] = string.char(48 + d)
    end
    local out = table.concat(res)
    if carry > 0 then
        out = "1" .. out
    end
    return out
end

-- Schoolbook subtraction of two magnitudes; requires a >= b.
local function magSub(a, b)
    local la, lb = #a, #b
    local res = {}
    local borrow = 0
    for i = 0, la - 1 do
        local d = a:byte(la - i) - 48 - borrow
        if i < lb then
            d = d - (b:byte(lb - i) - 48)
        end
        if d < 0 then
            d = d + 10
            borrow = 1
        else
            borrow = 0
        end
        res[la - i] = string.char(48 + d)
    end
    local out = table.concat(res):gsub("^0+", "")
    if out == "" then
        return "0"
    end
    return out
end

-- Signed addition on (sign, magnitude) pairs; returns sign, magnitude.
local function signedAdd(negA, magA, negB, magB)
    if negA == negB then
        return negA, magAdd(magA, magB)
    end
    local c = cmpMag(magA, magB)
    if c == 0 then
        return false, "0"
    end
    if c > 0 then
        return negA, magSub(magA, magB)
    end
    return negB, magSub(magB, magA)
end

-- Renders a (sign, magnitude) pair back to a canonical int64 string, or
-- returns nil when it overflows the int64 range.
local function render(negative, mag)
    if mag == "0" then
        return "0"
    end
    if cmpMag(mag, negative and MIN_MAG or MAX) > 0 then
        return nil
    end
    if negative then
        return "-" .. mag
    end
    return mag
end

--- Compares two int64 values numerically.
--- @param a string|number First value (anything of() accepts)
--- @param b string|number Second value (anything of() accepts)
--- @return number|nil -1 if a < b, 0 if equal, 1 if a > b; nil on failure
--- @return string|nil The error message when the first result is nil
local function compare(a, b)
    local sa, err = of(a)
    if not sa then
        return nil, err
    end
    local sb, err2 = of(b)
    if not sb then
        return nil, err2
    end
    if sa == sb then
        return 0
    end
    local negA, magA = split(sa)
    local negB, magB = split(sb)
    if negA ~= negB then
        return negA and -1 or 1
    end
    local c = cmpMag(magA, magB)
    if negA then
        return -c
    end
    return c
end

--- Tests whether two int64 values are numerically equal.
--- @return boolean|nil True if equal; nil on failure
--- @return string|nil The error message when the first result is nil
local function eq(a, b)
    local c, err = compare(a, b)
    if c == nil then
        return nil, err
    end
    return c == 0
end

--- Tests whether a is numerically less than b.
--- @return boolean|nil True if a < b; nil on failure
--- @return string|nil The error message when the first result is nil
local function lt(a, b)
    local c, err = compare(a, b)
    if c == nil then
        return nil, err
    end
    return c < 0
end

--- Tests whether a is numerically less than or equal to b.
--- @return boolean|nil True if a <= b; nil on failure
--- @return string|nil The error message when the first result is nil
local function le(a, b)
    local c, err = compare(a, b)
    if c == nil then
        return nil, err
    end
    return c <= 0
end

--- Tests whether a is numerically greater than b.
--- @return boolean|nil True if a > b; nil on failure
--- @return string|nil The error message when the first result is nil
local function gt(a, b)
    local c, err = compare(a, b)
    if c == nil then
        return nil, err
    end
    return c > 0
end

--- Tests whether a is numerically greater than or equal to b.
--- @return boolean|nil True if a >= b; nil on failure
--- @return string|nil The error message when the first result is nil
local function ge(a, b)
    local c, err = compare(a, b)
    if c == nil then
        return nil, err
    end
    return c >= 0
end

--- Adds two int64 values exactly.
--- @param a string|number First value (anything of() accepts)
--- @param b string|number Second value (anything of() accepts)
--- @return string|nil The canonical int64 sum, or nil on failure
--- @return string|nil The error message when the first result is nil
local function add(a, b)
    local sa, err = of(a)
    if not sa then
        return nil, err
    end
    local sb, err2 = of(b)
    if not sb then
        return nil, err2
    end
    local negA, magA = split(sa)
    local negB, magB = split(sb)
    local negative, mag = signedAdd(negA, magA, negB, magB)
    local out = render(negative, mag)
    if not out then
        return nil, "int64 overflow: " .. sa .. " + " .. sb
    end
    return out
end

--- Subtracts b from a exactly.
--- @param a string|number First value (anything of() accepts)
--- @param b string|number Second value (anything of() accepts)
--- @return string|nil The canonical int64 difference, or nil on failure
--- @return string|nil The error message when the first result is nil
local function sub(a, b)
    local sa, err = of(a)
    if not sa then
        return nil, err
    end
    local sb, err2 = of(b)
    if not sb then
        return nil, err2
    end
    local negA, magA = split(sa)
    local negB, magB = split(sb)
    -- a - b == a + (-b); the sign flip happens on the (sign, magnitude) pair,
    -- so negating MIN here cannot spuriously overflow an intermediate value
    local negative, mag = signedAdd(negA, magA, not negB, magB)
    local out = render(negative, mag)
    if not out then
        return nil, "int64 overflow: " .. sa .. " - " .. sb
    end
    return out
end

--- Negates an int64 value exactly.
--- @param a string|number The value (anything of() accepts)
--- @return string|nil The canonical negated int64, or nil on failure
--- @return string|nil The error message when the first result is nil
local function neg(a)
    local sa, err = of(a)
    if not sa then
        return nil, err
    end
    local negative, mag = split(sa)
    local out = render(not negative, mag)
    if not out then
        return nil, "int64 overflow: -(" .. sa .. ")"
    end
    return out
end

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    MAX = MAX,
    MIN = MIN,
    of = of,
    compare = compare,
    eq = eq,
    lt = lt,
    le = le,
    gt = gt,
    ge = ge,
    add = add,
    sub = sub,
    neg = neg,
    getVersion = getVersion,
}

-- Enables the module to be called as a function
local function apiCall(_, operation, ...)
    if operation == "version" then
        return VERSION
    end
    local op = API[operation]
    if type(op) == "function" then
        return op(...)
    elseif op ~= nil then
        return op
    else
        error("Unknown operation: " .. tostring(operation), 2)
    end
end

return readOnly(API, {__tostring = apiToString, __call = apiCall, __type = NAME})
