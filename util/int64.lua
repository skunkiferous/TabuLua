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
-- Exact 64-bit signed integer VALUES, carried as an opaque immutable box.
--
-- A box is an EMPTY table with the shared metatable below; its payload (a
-- native 64-bit integer on Lua 5.3+, an FFI int64_t cdata on LuaJIT) lives in
-- a module-private weak map, so next(box) cannot leak it and sandboxed code
-- cannot reach it. The box is the ONLY public form: no native integer and no
-- cdata ever escapes this module, so nothing downstream sees a
-- platform-specific type.
--
-- Why a box and not the canonical decimal STRING this module used to carry:
-- the serializers are value-driven, with no access to the schema, so a string
-- int64 is indistinguishable from a genuine string at serialization time. A
-- schema lookup cannot fix that, because untyped containers ('table', 'raw'),
-- arrays and map keys have no schema. A box answers int64.is(v) at any depth.
--
-- Boxes are INTERNED: of() returns the same box for the same value, so
-- identity IS value and a box works as a table key. Every value this module
-- returns comes from the registry -- see the contract on intern() below.
--
-- Contract: every function normalizes its arguments through of() and returns
-- nil plus an error message when an argument is not an int64 or a result
-- overflows the int64 range. A canonical int64 string is an optional '-'
-- followed by digits, no leading zeros, no '-0', within
-- [-9223372036854775808, 9223372036854775807].
--
-- Plain Lua operators on a box: <, <=, > and >= are exact (metamethods); ==
-- against another box is exact; == against a STRING is always false, and '..',
-- '#', string methods and math.* do not work. That is by design -- use
-- int64.tostring / compare / add / sub / abs / sign / toNumber instead.
-- ============================================================

-- Canonical range bounds (MIN_MAG is MIN without its sign)
local MAX_STR = "9223372036854775807"
local MIN_STR = "-9223372036854775808"
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
--
-- This RANGE CHECK IS LOAD-BEARING and must run before any conversion: both
-- payload backends wrap silently, and on Lua 5.3+ tonumber("9223372036854775808")
-- quietly yields a FLOAT. Validating in the string domain is what stands
-- between us and a wrong value.
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
    if cmpMag(mag, negative and MIN_MAG or MAX_STR) > 0 then
        return nil, "'" .. s .. "' is outside the int64 range ["
            .. MIN_STR .. ", " .. MAX_STR .. "]"
    end
    return s
end

-- ============================================================
-- The payload backend
--
-- Two implementations of the same five primitives. Everything above this line
-- is version-independent; everything below it is chosen once, at load time.
-- Neither payload type ever leaves the module.
-- ============================================================

-- parsePayload(negative, mag) -> payload, for an ALREADY RANGE-CHECKED
-- magnitude. Both backends accumulate NEGATIVELY, because the negative side of
-- the range is one larger than the positive side: building 9223372036854775808
-- to then negate it would overflow, whereas -9223372036854775808 is exact.
-- (This is also why tonumber(MIN_STR) is wrong on Lua 5.3+: it lexes the
-- magnitude first, which does not fit, so it yields a float.)
local parsePayload
-- renderPayload(payload) -> canonical decimal string
local renderPayload
-- addPayload/subPayload(x, y) -> payload or nil on overflow
local addPayload, subPayload
-- toNumberPayload(payload) -> Lua number (lossy beyond 2^53)
local toNumberPayload
-- ZERO payload, for sign comparisons
local ZERO

if HAS_NATIVE_INTEGERS then
    ZERO = 0

    parsePayload = function(negative, mag)
        local n = 0
        for i = 1, #mag do
            n = n * 10 - (mag:byte(i) - 48)
        end
        if negative then
            return n
        end
        return -n
    end

    -- Native integers never render in scientific notation
    renderPayload = tostring

    toNumberPayload = function(p)
        return p + 0.0
    end
else
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then
        error(NAME .. " needs either native 64-bit integers (Lua 5.3+) or "
            .. "the LuaJIT FFI; this Lua has neither")
    end
    local i64 = ffi.typeof("int64_t")
    ZERO = i64(0)

    parsePayload = function(negative, mag)
        local n = i64(0)
        for i = 1, #mag do
            n = n * 10 - (mag:byte(i) - 48)
        end
        if negative then
            return n
        end
        return -n
    end

    -- tostring() of an int64_t cdata appends an "LL" suffix
    renderPayload = function(p)
        return (tostring(p):gsub("LL$", ""))
    end

    toNumberPayload = tonumber
end

-- Overflow detection is SIGN ANALYSIS, not a structural check.
--
-- This is new work, not a port: the old string implementation detected
-- overflow structurally, by noticing that the rendered magnitude ran past the
-- bound. Both payload backends instead WRAP silently (Lua 5.3+ integer
-- arithmetic and cdata int64_t alike), so the wrapped result must be caught
-- after the fact, from the signs of the operands and the result.
addPayload = function(x, y)
    local r = x + y
    -- Adding same-signed operands must not change the sign; mixed signs and
    -- zero operands can never overflow
    if x > ZERO and y > ZERO and r <= ZERO then
        return nil
    end
    if x < ZERO and y < ZERO and r >= ZERO then
        return nil
    end
    return r
end

subPayload = function(x, y)
    local r = x - y
    -- Only a mixed-sign subtraction can overflow, and it does so by landing on
    -- the sign of y rather than of x. Note this is NOT neg-then-add: negating
    -- MIN overflows on its own, which would spuriously reject valid results
    -- such as (-1) - MIN == MAX.
    if x >= ZERO and y < ZERO and r < ZERO then
        return nil
    end
    if x < ZERO and y > ZERO and r >= ZERO then
        return nil
    end
    return r
end

-- ============================================================
-- The box
-- ============================================================

-- Weak-KEYED map from a box to its {payload, canonical string} record. Keeping
-- it out of the box is what makes the box empty, so next(box) leaks nothing
-- and sandboxed code cannot reach a native integer or an FFI cdata.
local box_to_value = setmetatable({}, { __mode = "k" })

-- Intern registry: canonical decimal string -> box.
--
-- Weak-VALUED, NOT weak-keyed. The keys are strings, and Lua never removes
-- strings from a weak table (they behave like values, not objects), so a
-- weak-keyed registry would pin every box forever. Weak values let an entry go
-- exactly when nothing references its box -- and if nothing references it, no
-- live table key can be compared against it either.
--
-- It deliberately does NOT register a global_reset hook: clearing it would be
-- safe for comparisons (__eq below is a safety net) but NOT for table-key
-- lookups, which are identity-based, so a pre-reset box would silently stop
-- matching a post-reset one used as a key. Unreferenced boxes are collected,
-- so persisting does not leak.
local registry = setmetatable({}, { __mode = "v" })

-- Forward declarations: the metamethods normalize through of()
local of

local function payloadOf(v)
    local rec = box_to_value[v]
    if rec == nil then
        return nil
    end
    return rec[1]
end

--- Tests whether a value is an int64 box.
---
--- This is the ONLY correct way to ask: type(v) answers "table" and math.type(v)
--- answers nil, both silently wrong.
--- @param v any The value to test
--- @return boolean True if v is an int64 value
local function is(v)
    return type(v) == "table" and box_to_value[v] ~= nil
end

-- Compares two payloads numerically.
local function cmpPayload(x, y)
    if x == y then
        return 0
    end
    return x < y and -1 or 1
end

-- The ONE shared metatable for every box, created once and never replaced.
--
-- Sharing a single metatable is required, not merely tidy: LuaJIT follows Lua
-- 5.1 semantics, where a comparison metamethod is only consulted when both
-- operands carry the SAME one. A per-box or rebuilt-on-reset metatable would
-- make comparisons silently fall back to raw behavior there.
local box_mt

--- Formats an int64 as its canonical decimal digits.
---
--- Also the mandated pre-step for concatenation: '..' cannot be overloaded for
--- a box on every supported Lua, so build strings from this.
--- @param v any An int64 value (or anything of() accepts)
--- @return string|nil The canonical decimal digits, or nil on failure
--- @return string|nil The error message when the first result is nil
local function toString(v)
    local rec = type(v) == "table" and box_to_value[v] or nil
    if rec ~= nil then
        return rec[2]
    end
    local b, err = of(v)
    if b == nil then
        return nil, err
    end
    return box_to_value[b][2]
end

box_mt = {
    __tostring = function(b)
        return box_to_value[b][2]
    end,
    -- The box is EMPTY, so every key is a new key and __newindex ALWAYS fires.
    -- That is the whole reason for the empty-proxy shape: a box holding its
    -- payload at [1] would let `v[1] = 5` slip past __newindex and, because
    -- boxes are interned, corrupt that value for every holder in the dataset.
    __newindex = function(_b, _k, _v)
        error("int64 values are immutable", 2)
    end,
    __index = function(_b, k)
        error("int64 values have no field '" .. tostring(k)
            .. "'; use int64.tostring/compare/add/sub/abs/sign/toNumber", 2)
    end,
    __len = function(_b)
        error("int64 values have no length; use int64.tostring(v) first", 2)
    end,
    -- __eq only ever fires with two tables. It must never raise: a box
    -- compared with an unrelated table is simply not equal.
    --
    -- Interning already makes equal values the SAME object, so rawequal
    -- settles every real comparison before this runs. It exists as a safety
    -- net, so that a non-interned box could only ever make an answer slower to
    -- reach, never wrong.
    __eq = function(a, b)
        local pa, pb = payloadOf(a), payloadOf(b)
        if pa == nil or pb == nil then
            return false
        end
        return pa == pb
    end,
    __lt = function(a, b)
        local x, xerr = of(a)
        if x == nil then
            error(xerr, 2)
        end
        local y, yerr = of(b)
        if y == nil then
            error(yerr, 2)
        end
        return cmpPayload(payloadOf(x), payloadOf(y)) < 0
    end,
    __le = function(a, b)
        local x, xerr = of(a)
        if x == nil then
            error(xerr, 2)
        end
        local y, yerr = of(b)
        if y == nil then
            error(yerr, 2)
        end
        return cmpPayload(payloadOf(x), payloadOf(y)) <= 0
    end,
    -- Masks the metatable from tampering AND doubles as the type tag the
    -- serializers dispatch on: getmetatable(box) == "int64"
    __metatable = NAME,
}

-- Returns the interned box for an already-validated canonical string.
--
-- IMPLEMENTATION CONTRACT: this is the ONLY place a box is created, and every
-- value of/add/sub/neg/abs returns must come from here. Returning a
-- non-interned box would silently break key parity -- two equal values would
-- be different table keys -- which no test of arithmetic would catch.
local function intern(canon, payload)
    local box = registry[canon]
    if box == nil then
        box = setmetatable({}, box_mt)
        box_to_value[box] = { payload, canon }
        registry[canon] = box
    end
    return box
end

-- Interns from a payload, rendering its canonical form first.
local function fromPayload(payload)
    return intern(renderPayload(payload), payload)
end

--- Normalizes a value to an int64 box.
---
--- An int64 is returned unchanged (of() is idempotent). Strings must already be
--- canonical int64 text (see the module comment). Numbers are converted
--- exactly: native 64-bit integers (Lua 5.3+) through the full int64 range,
--- doubles only when integral and within +/-2^53 -- beyond that a double may not
--- be the value the caller meant on every Lua version, so it is rejected with
--- instructions to pass the value as a string instead.
--- @param v any The value to normalize
--- @return table|nil The int64 box, or nil on failure
--- @return string|nil The error message when the first result is nil
of = function(v)
    local t = type(v)
    if t == "table" then
        if box_to_value[v] ~= nil then
            return v
        end
        return nil, "expected an int64 string or a number, got table"
    end
    local canon
    if t == "string" then
        local s, err = checkString(v)
        if s == nil then
            return nil, err
        end
        canon = s
    elseif t ~= "number" then
        return nil, "expected an int64 string or a number, got " .. t
    elseif v ~= v then
        return nil, "NaN is not an int64"
    elseif v == math.huge or v == -math.huge then
        return nil, "infinity is not an int64"
    elseif v % 1 ~= 0 then
        return nil, "'" .. tostring(v) .. "' has a fractional part"
    elseif HAS_NATIVE_INTEGERS and math.type(v) == "integer" then
        -- Native integers are exact through the full int64 range, and
        -- tostring() of one never uses scientific notation
        canon = tostring(v)
    elseif v < -SAFE_LIMIT or v > SAFE_LIMIT then
        return nil, "'" .. tostring(v) .. "' is a number beyond +/-2^53 and "
            .. "may not be exact on every Lua version; "
            .. "pass the value as an int64 string instead"
    else
        canon = formatInteger(v)
        if canon == "-0" then
            canon = "0"
        end
    end
    local box = registry[canon]
    if box ~= nil then
        return box
    end
    local negative = canon:sub(1, 1) == "-"
    local mag = negative and canon:sub(2) or canon
    return intern(canon, parsePayload(negative, mag))
end

--- Compares two int64 values numerically.
--- @param a any First value (anything of() accepts)
--- @param b any Second value (anything of() accepts)
--- @return number|nil -1 if a < b, 0 if equal, 1 if a > b; nil on failure
--- @return string|nil The error message when the first result is nil
local function compare(a, b)
    local x, err = of(a)
    if x == nil then
        return nil, err
    end
    local y, err2 = of(b)
    if y == nil then
        return nil, err2
    end
    return cmpPayload(payloadOf(x), payloadOf(y))
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
--- @param a any First value (anything of() accepts)
--- @param b any Second value (anything of() accepts)
--- @return table|nil The int64 sum, or nil on failure
--- @return string|nil The error message when the first result is nil
local function add(a, b)
    local x, err = of(a)
    if x == nil then
        return nil, err
    end
    local y, err2 = of(b)
    if y == nil then
        return nil, err2
    end
    local r = addPayload(payloadOf(x), payloadOf(y))
    if r == nil then
        return nil, "int64 overflow: " .. box_to_value[x][2]
            .. " + " .. box_to_value[y][2]
    end
    return fromPayload(r)
end

--- Subtracts b from a exactly.
--- @param a any First value (anything of() accepts)
--- @param b any Second value (anything of() accepts)
--- @return table|nil The int64 difference, or nil on failure
--- @return string|nil The error message when the first result is nil
local function sub(a, b)
    local x, err = of(a)
    if x == nil then
        return nil, err
    end
    local y, err2 = of(b)
    if y == nil then
        return nil, err2
    end
    local r = subPayload(payloadOf(x), payloadOf(y))
    if r == nil then
        return nil, "int64 overflow: " .. box_to_value[x][2]
            .. " - " .. box_to_value[y][2]
    end
    return fromPayload(r)
end

--- Negates an int64 value exactly.
--- @param a any The value (anything of() accepts)
--- @return table|nil The negated int64, or nil on failure
--- @return string|nil The error message when the first result is nil
local function neg(a)
    local x, err = of(a)
    if x == nil then
        return nil, err
    end
    -- MIN is the one value whose negation leaves the range
    local r = subPayload(ZERO, payloadOf(x))
    if r == nil then
        return nil, "int64 overflow: -(" .. box_to_value[x][2] .. ")"
    end
    return fromPayload(r)
end

--- Returns the absolute value of an int64.
--- math.abs is closed to non-numbers, so this is the only way to ask.
--- @param a any The value (anything of() accepts)
--- @return table|nil The absolute value, or nil on failure (including abs(MIN))
--- @return string|nil The error message when the first result is nil
local function abs(a)
    local x, err = of(a)
    if x == nil then
        return nil, err
    end
    if payloadOf(x) >= ZERO then
        return x
    end
    return neg(x)
end

--- Returns the sign of an int64 as a plain Lua number.
--- @param a any The value (anything of() accepts)
--- @return number|nil -1, 0 or 1; nil on failure
--- @return string|nil The error message when the first result is nil
local function sign(a)
    local x, err = of(a)
    if x == nil then
        return nil, err
    end
    return cmpPayload(payloadOf(x), ZERO)
end

--- Converts an int64 to a plain Lua number.
---
--- EXPLICITLY LOSSY beyond +/-2^53, which is why it is not called tonumber:
--- the conversion is silent, so it must be asked for by name.
--- @param a any The value (anything of() accepts)
--- @return number|nil The value as a Lua number, or nil on failure
--- @return string|nil The error message when the first result is nil
local function toNumber(a)
    local x, err = of(a)
    if x == nil then
        return nil, err
    end
    return toNumberPayload(payloadOf(x))
end

-- The range bounds, as int64 VALUES (boxes), not strings
local MAX = of(MAX_STR)
local MIN = of(MIN_STR)

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    MAX = MAX,
    MIN = MIN,
    is = is,
    of = of,
    tostring = toString,
    compare = compare,
    eq = eq,
    lt = lt,
    le = le,
    gt = gt,
    ge = ge,
    add = add,
    sub = sub,
    neg = neg,
    abs = abs,
    sign = sign,
    toNumber = toNumber,
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
