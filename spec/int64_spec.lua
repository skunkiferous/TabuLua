-- int64_spec.lua
-- Exact 64-bit integers as interned immutable BOXES (util/int64.lua). The
-- point of the module is that these answers are IDENTICAL on Lua 5.3+ and
-- LuaJIT -- one API over two payload backends (native 64-bit integers vs FFI
-- int64_t), no version probes in the results -- so the assertions below are
-- version-independent by design. The only gated tests are the ones whose
-- INPUTS (native 64-bit integers) cannot exist on LuaJIT in the first place.

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local pending = busted.pending

local int64 = require("util.int64")

-- True native 64-bit integers (Lua 5.3+); compat53's fake math.type on
-- LuaJIT calls every whole double "integer", so probe with a float
local HAS_NATIVE_INTEGERS = math.type ~= nil and math.type(1.0) == "float"
local it_native = HAS_NATIVE_INTEGERS and it or pending

local MAX = "9223372036854775807"
local MIN = "-9223372036854775808"

-- Shorthand: the canonical digits of an int64, for comparing against text
local function s(v)
    return int64.tostring(v)
end

describe("int64", function()
  describe("of", function()
    it("should accept canonical int64 strings", function()
      assert.equals("0", s(int64.of("0")))
      assert.equals("42", s(int64.of("42")))
      assert.equals("-1", s(int64.of("-1")))
      assert.equals(MAX, s(int64.of(MAX)))
      assert.equals(MIN, s(int64.of(MIN)))
    end)

    it("should be idempotent on an int64", function()
      local v = int64.of("42")
      assert.is_true(rawequal(v, int64.of(v)))
    end)

    it("should reject malformed strings", function()
      for _, str in ipairs({"", "abc", "+5", " 5", "5 ", "1.5", "12e3",
                            "0x10", "--5", "-"}) do
        local v, err = int64.of(str)
        assert.is_nil(v)
        assert.is_string(err)
      end
    end)

    it("should reject non-canonical strings", function()
      for _, str in ipairs({"007", "-0", "-007", "00"}) do
        local v, err = int64.of(str)
        assert.is_nil(v)
        assert.is_string(err)
      end
    end)

    it("should reject strings outside the int64 range", function()
      local v, err = int64.of("9223372036854775808")
      assert.is_nil(v)
      assert.matches("outside the int64 range", err)
      v, err = int64.of("-9223372036854775809")
      assert.is_nil(v)
      assert.matches("outside the int64 range", err)
    end)

    it("should convert exact integral numbers", function()
      assert.equals("42", s(int64.of(42)))
      assert.equals("-7", s(int64.of(-7)))
      assert.equals("0", s(int64.of(0)))
      assert.equals("3", s(int64.of(3.0)))
      assert.equals("0", s(int64.of(-0.0)))
      -- 2^53 is the last double exact on every Lua version; tostring() of it
      -- goes scientific, so this also proves the exact-digit formatting
      assert.equals("9007199254740992", s(int64.of(2^53)))
      assert.equals("-9007199254740992", s(int64.of(-2^53)))
    end)

    it("should reject fractional and non-finite numbers", function()
      for _, n in ipairs({1.5, -0.25, math.huge, -math.huge, 0/0}) do
        local v, err = int64.of(n)
        assert.is_nil(v)
        assert.is_string(err)
      end
    end)

    it("should reject doubles beyond the safe range on every version", function()
      -- 2^53 + 2 is exactly representable as a double, but doubles past 2^53
      -- may not be the number the caller meant (LuaJIT rounds bigger literals
      -- at parse time), so of() must reject them UNIFORMLY -- accepting them
      -- where they happen to be exact would be version-dependent behavior.
      -- Built with ^ so the value is a double on Lua 5.3+ too.
      local v, err = int64.of(2^53 + 2)
      assert.is_nil(v)
      assert.matches("pass the value as an int64 string", err)
      v, err = int64.of(-(2^53 + 2))
      assert.is_nil(v)
      assert.is_string(err)
      v, err = int64.of(2^63)
      assert.is_nil(v)
      assert.is_string(err)
    end)

    it("should reject values that are neither string nor number", function()
      for _, x in ipairs({true, {}, print}) do
        local v, err = int64.of(x)
        assert.is_nil(v)
        assert.matches("expected an int64 string or a number", err)
      end
      local v, err = int64.of(nil)
      assert.is_nil(v)
      assert.is_string(err)
    end)

    it_native("should convert native integers through the full range", function()
      assert.equals(MAX, s(int64.of(math.maxinteger)))
      assert.equals(MIN, s(int64.of(math.mininteger)))
      assert.equals("9007199254740993", s(int64.of(math.tointeger(2^53) + 1)))
    end)
  end)

  -- The box is what makes an int64 recognizable at any depth, without a
  -- schema -- which is the entire reason this representation exists.
  describe("the box", function()
    it("should be recognized by is(), which type() cannot do", function()
      local v = int64.of("42")
      assert.is_true(int64.is(v))
      -- Both of these are silently WRONG, which is why is() must exist
      assert.equals("table", type(v))
      if math.type then
        assert.is_nil(math.type(v))
      end
    end)

    it("should not report unrelated values as int64", function()
      for _, x in ipairs({"42", 42, true, {}, {1, 2}, print}) do
        assert.is_false(int64.is(x))
      end
      assert.is_false(int64.is(nil))
    end)

    it("should be empty, so it cannot leak its payload", function()
      local v = int64.of(MAX)
      assert.is_nil(next(v))
    end)

    it("should mask its metatable and expose the type tag", function()
      assert.equals("int64", getmetatable(int64.of("1")))
    end)

    it("should be immutable for both new and integer keys", function()
      local v = int64.of(MAX)
      -- The empty-proxy shape is what makes this work: a box holding its
      -- payload at [1] would let v[1] = 5 slip past __newindex entirely, and
      -- because boxes are INTERNED that would corrupt the value for every
      -- holder in the dataset
      assert.has_error(function() v[1] = 5 end, "int64 values are immutable")
      assert.has_error(function() v.x = 5 end, "int64 values are immutable")
      assert.equals(MAX, s(v))
    end)

    it("should error, naming the API, on field access and length", function()
      local v = int64.of("1")
      assert.has_error(function() return v.foo end)
      assert.has_error(function() return #v end)
    end)

    it("should compare exactly with the plain operators", function()
      local a, b = int64.of("100"), int64.of("99")
      -- Lexically "100" < "99"; numerically it is not. Ordering strings was
      -- the bug the COMPARATORS.int64 hook existed to paper over.
      assert.is_true(b < a)
      assert.is_false(a < b)
      assert.is_true(a <= a)
      assert.is_true(a > b)
      assert.is_true(a >= a)
      assert.is_true(int64.of(MIN) < int64.of(MAX))
    end)

    it("should sort numerically", function()
      local t = {int64.of("100"), int64.of("30"), int64.of("9")}
      table.sort(t)
      assert.equals("9", s(t[1]))
      assert.equals("30", s(t[2]))
      assert.equals("100", s(t[3]))
    end)

    it("should never equal the string that spells it", function()
      -- The contract users must know: compare int64 to int64, never to text
      assert.is_false(int64.of(MAX) == MAX)
      assert.is_false(int64.of("42") == "42")
    end)

    it("should not equal an unrelated table, and must not raise", function()
      assert.is_false(int64.of("1") == {})
      assert.is_false(int64.of("1") == setmetatable({}, {}))
    end)

    it("should render canonical digits through tostring()", function()
      assert.equals(MAX, tostring(int64.of(MAX)))
      assert.equals(MIN, tostring(int64.of(MIN)))
      -- int64.tostring accepts anything of() accepts, so it doubles as the
      -- mandated pre-step for concatenation
      assert.equals("42", int64.tostring(42))
      assert.equals("7", int64.tostring("7"))
      local v, err = int64.tostring("nope")
      assert.is_nil(v)
      assert.is_string(err)
    end)
  end)

  -- Interning is what makes a box usable as a MAP KEY: identity becomes value
  -- by construction. Breaking it would not show up in any arithmetic test.
  describe("interning", function()
    it("should return the same box for the same value", function()
      assert.is_true(rawequal(int64.of(MAX), int64.of(MAX)))
      assert.is_true(rawequal(int64.of("42"), int64.of(42)))
    end)

    it("should work as a table key", function()
      local t = {}
      t[int64.of(MAX)] = "found"
      assert.equals("found", t[int64.of(MAX)])
      -- One distinct key, not two
      local n = 0
      t[int64.of(MAX)] = "again"
      for _ in pairs(t) do n = n + 1 end
      assert.equals(1, n)
    end)

    it("should never let a non-interned box escape", function()
      -- The implementation contract: every value of/add/sub/neg/abs returns
      -- must come from the registry, or two equal values become two different
      -- table keys and key parity breaks SILENTLY
      assert.is_true(rawequal(int64.add("1", "2"), int64.of("3")))
      assert.is_true(rawequal(int64.sub("10", "3"), int64.of("7")))
      assert.is_true(rawequal(int64.neg("5"), int64.of("-5")))
      assert.is_true(rawequal(int64.abs("-5"), int64.of("5")))
      assert.is_true(rawequal(int64.abs("5"), int64.of("5")))
      -- Values past 2^53, where the payload backends actually differ
      assert.is_true(rawequal(int64.add(MAX, "-1"),
          int64.of("9223372036854775806")))
    end)
  end)

  describe("compare and predicates", function()
    it("should order values numerically, not lexically", function()
      assert.equals(-1, int64.compare("5", "7"))
      assert.equals(1, int64.compare("7", "5"))
      assert.equals(0, int64.compare("5", "5"))
      -- lexical order would say "100" < "99"
      assert.equals(1, int64.compare("100", "99"))
      assert.equals(-1, int64.compare("-100", "-99"))
    end)

    it("should order across signs", function()
      assert.equals(-1, int64.compare("-5", "3"))
      assert.equals(1, int64.compare("3", "-5"))
      assert.equals(1, int64.compare("-3", "-5"))
      assert.equals(-1, int64.compare(MIN, MAX))
      assert.equals(-1, int64.compare("-1", "0"))
    end)

    it("should accept numbers and boxes as arguments", function()
      assert.equals(1, int64.compare(100, "99"))
      assert.equals(0, int64.compare("42", 42))
      assert.equals(0, int64.compare(int64.of("42"), "42"))
    end)

    it("should expose eq/lt/le/gt/ge", function()
      assert.is_true(int64.eq("5", 5))
      assert.is_false(int64.eq("5", "6"))
      assert.is_true(int64.lt("-1", "0"))
      assert.is_false(int64.lt("5", "5"))
      assert.is_true(int64.le("5", "5"))
      assert.is_true(int64.le(MIN, MAX))
      assert.is_false(int64.le(MAX, MIN))
      assert.is_true(int64.gt("0", "-1"))
      assert.is_false(int64.gt("5", "5"))
      assert.is_true(int64.ge("5", "5"))
      assert.is_true(int64.ge(MAX, MIN))
      assert.is_false(int64.ge(MIN, MAX))
    end)

    it("should propagate conversion errors in gt/ge", function()
      local c, err = int64.gt("abc", 1)
      assert.is_nil(c)
      assert.is_string(err)
      c, err = int64.ge(1, "1.5")
      assert.is_nil(c)
      assert.is_string(err)
    end)

    it("should propagate conversion errors", function()
      local c, err = int64.compare("abc", 1)
      assert.is_nil(c)
      assert.is_string(err)
      c, err = int64.eq(1, "1.5")
      assert.is_nil(c)
      assert.is_string(err)
    end)
  end)

  describe("add", function()
    it("should add small values with carries", function()
      assert.equals("3", s(int64.add("1", "2")))
      assert.equals("1000", s(int64.add("999", "1")))
      assert.equals("0", s(int64.add("5", "-5")))
      assert.equals("2", s(int64.add("-5", "7")))
      assert.equals("-2", s(int64.add("5", "-7")))
      assert.equals("-12", s(int64.add("-5", "-7")))
      assert.equals("3", s(int64.add(1, 2)))
    end)

    it("should be exact at the edges of the range", function()
      assert.equals(MAX, s(int64.add(MAX, "0")))
      assert.equals("9223372036854775806", s(int64.add(MAX, "-1")))
      assert.equals(MAX, s(int64.add("9223372036854775806", "1")))
      assert.equals("-9223372036854775807", s(int64.add(MIN, "1")))
      -- exact past 2^53: impossible with doubles, the whole point on LuaJIT
      assert.equals("9007199254740993", s(int64.add("9007199254740992", "1")))
    end)

    it("should report overflow instead of wrapping", function()
      -- Both payload backends WRAP silently, so overflow is caught by sign
      -- analysis after the fact -- these are the cases that would otherwise
      -- return a plausible, wrong answer
      local v, err = int64.add(MAX, "1")
      assert.is_nil(v)
      assert.matches("overflow", err)
      v, err = int64.add(MIN, "-1")
      assert.is_nil(v)
      assert.matches("overflow", err)
      v, err = int64.add(MAX, MAX)
      assert.is_nil(v)
      assert.matches("overflow", err)
      v, err = int64.add(MIN, MIN)
      assert.is_nil(v)
      assert.matches("overflow", err)
    end)

    it("should not report overflow for mixed signs at the edges", function()
      assert.equals("-1", s(int64.add(MIN, MAX)))
      assert.equals("-1", s(int64.add(MAX, MIN)))
      assert.equals(MIN, s(int64.add(MIN, "0")))
    end)

    it("should propagate conversion errors", function()
      local v, err = int64.add("1.5", 1)
      assert.is_nil(v)
      assert.is_string(err)
    end)
  end)

  describe("sub", function()
    it("should subtract with borrows and sign crossings", function()
      assert.equals("7", s(int64.sub("10", "3")))
      assert.equals("-7", s(int64.sub("3", "10")))
      assert.equals("0", s(int64.sub(MIN, MIN)))
      assert.equals("9007199254740993", s(int64.sub("9007199254740992", -1)))
    end)

    it("should report overflow instead of wrapping", function()
      local v, err = int64.sub(MIN, "1")
      assert.is_nil(v)
      assert.matches("overflow", err)
      -- 0 - MIN would be 2^63, one past MAX
      v, err = int64.sub("0", MIN)
      assert.is_nil(v)
      assert.matches("overflow", err)
      v, err = int64.sub(MAX, MIN)
      assert.is_nil(v)
      assert.matches("overflow", err)
    end)

    it("should NOT overflow where negate-then-add would", function()
      -- (-1) - MIN == MAX is a VALID result, but computing it as
      -- (-1) + (-MIN) overflows on the intermediate. This is exactly why sub
      -- is implemented directly rather than via neg.
      assert.equals(MAX, s(int64.sub("-1", MIN)))
      assert.equals("0", s(int64.sub(MIN, MIN)))
      -- ...while MIN - MAX really does overflow (unlike MIN + MAX == -1),
      -- so the sign analysis must separate the two
      local v, err = int64.sub(MIN, MAX)
      assert.is_nil(v)
      assert.matches("overflow", err)
    end)
  end)

  describe("neg", function()
    it("should negate exactly", function()
      assert.equals("-5", s(int64.neg("5")))
      assert.equals("5", s(int64.neg("-5")))
      assert.equals("0", s(int64.neg("0")))
      assert.equals("-" .. MAX, s(int64.neg(MAX)))
      assert.equals(MAX, s(int64.neg("-" .. MAX)))
    end)

    it("should report overflow for MIN", function()
      local v, err = int64.neg(MIN)
      assert.is_nil(v)
      assert.matches("overflow", err)
    end)
  end)

  -- math.* is closed to non-numbers, so these have no builtin equivalent
  describe("abs, sign and toNumber", function()
    it("should compute abs", function()
      assert.equals("5", s(int64.abs("5")))
      assert.equals("5", s(int64.abs("-5")))
      assert.equals("0", s(int64.abs("0")))
      assert.equals(MAX, s(int64.abs("-" .. MAX)))
    end)

    it("should report overflow for abs(MIN)", function()
      -- MIN has no positive counterpart in the range
      local v, err = int64.abs(MIN)
      assert.is_nil(v)
      assert.matches("overflow", err)
    end)

    it("should compute sign as a plain number", function()
      assert.equals(1, int64.sign("5"))
      assert.equals(-1, int64.sign("-5"))
      assert.equals(0, int64.sign("0"))
      assert.equals(1, int64.sign(MAX))
      assert.equals(-1, int64.sign(MIN))
    end)

    it("should convert to a Lua number, exactly within the safe range",
        function()
      assert.equals(42, int64.toNumber("42"))
      assert.equals(-7, int64.toNumber("-7"))
      assert.equals(0, int64.toNumber("0"))
      assert.equals(2^53, int64.toNumber("9007199254740992"))
    end)

    it("should propagate conversion errors", function()
      for _, fn in ipairs({int64.abs, int64.sign, int64.toNumber}) do
        local v, err = fn("nope")
        assert.is_nil(v)
        assert.is_string(err)
      end
    end)
  end)

  describe("module API", function()
    it("should expose the range bounds as int64 values", function()
      assert.is_true(int64.is(int64.MAX))
      assert.is_true(int64.is(int64.MIN))
      assert.equals(MAX, s(int64.MAX))
      assert.equals(MIN, s(int64.MIN))
      -- and they are the interned boxes, not copies
      assert.is_true(rawequal(int64.MAX, int64.of(MAX)))
      assert.is_true(rawequal(int64.MIN, int64.of(MIN)))
    end)

    it("should return a version string", function()
      local version = int64.getVersion()
      assert.is_string(version)
      assert.matches("^%d+%.%d+%.%d+$", version)
    end)
  end)
end)
