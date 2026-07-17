-- int64_spec.lua
-- Exact 64-bit integers as canonical decimal strings (util/int64.lua). The
-- point of the module is that these answers are IDENTICAL on Lua 5.3+ and
-- LuaJIT — one string-based code path, no version probes in the results — so
-- the assertions below are version-independent by design. The only gated
-- tests are the ones whose INPUTS (native 64-bit integers) cannot exist on
-- LuaJIT in the first place.

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

describe("int64", function()
  describe("of", function()
    it("should return canonical int64 strings as-is", function()
      assert.equals("0", int64.of("0"))
      assert.equals("42", int64.of("42"))
      assert.equals("-1", int64.of("-1"))
      assert.equals(MAX, int64.of(MAX))
      assert.equals(MIN, int64.of(MIN))
    end)

    it("should reject malformed strings", function()
      for _, s in ipairs({"", "abc", "+5", " 5", "5 ", "1.5", "12e3",
                          "0x10", "--5", "-"}) do
        local v, err = int64.of(s)
        assert.is_nil(v)
        assert.is_string(err)
      end
    end)

    it("should reject non-canonical strings", function()
      for _, s in ipairs({"007", "-0", "-007", "00"}) do
        local v, err = int64.of(s)
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
      assert.equals("42", int64.of(42))
      assert.equals("-7", int64.of(-7))
      assert.equals("0", int64.of(0))
      assert.equals("3", int64.of(3.0))
      assert.equals("0", int64.of(-0.0))
      -- 2^53 is the last double exact on every Lua version; tostring() of it
      -- goes scientific, so this also proves the exact-digit formatting
      assert.equals("9007199254740992", int64.of(2^53))
      assert.equals("-9007199254740992", int64.of(-2^53))
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
      -- at parse time), so of() must reject them UNIFORMLY — accepting them
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
      assert.equals(MAX, int64.of(math.maxinteger))
      assert.equals(MIN, int64.of(math.mininteger))
      assert.equals("9007199254740993", int64.of(math.tointeger(2^53) + 1))
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

    it("should accept numbers as arguments", function()
      assert.equals(1, int64.compare(100, "99"))
      assert.equals(0, int64.compare("42", 42))
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
      assert.equals("3", int64.add("1", "2"))
      assert.equals("1000", int64.add("999", "1"))
      assert.equals("0", int64.add("5", "-5"))
      assert.equals("2", int64.add("-5", "7"))
      assert.equals("-2", int64.add("5", "-7"))
      assert.equals("-12", int64.add("-5", "-7"))
      assert.equals("3", int64.add(1, 2))
    end)

    it("should be exact at the edges of the range", function()
      assert.equals(MAX, int64.add(MAX, "0"))
      assert.equals("9223372036854775806", int64.add(MAX, "-1"))
      assert.equals(MAX, int64.add("9223372036854775806", "1"))
      assert.equals("-9223372036854775807", int64.add(MIN, "1"))
      -- exact past 2^53: impossible with doubles, the whole point on LuaJIT
      assert.equals("9007199254740993", int64.add("9007199254740992", "1"))
    end)

    it("should report overflow instead of wrapping", function()
      local v, err = int64.add(MAX, "1")
      assert.is_nil(v)
      assert.matches("overflow", err)
      v, err = int64.add(MIN, "-1")
      assert.is_nil(v)
      assert.matches("overflow", err)
    end)

    it("should propagate conversion errors", function()
      local v, err = int64.add("1.5", 1)
      assert.is_nil(v)
      assert.is_string(err)
    end)
  end)

  describe("sub", function()
    it("should subtract with borrows and sign crossings", function()
      assert.equals("7", int64.sub("10", "3"))
      assert.equals("-7", int64.sub("3", "10"))
      assert.equals("0", int64.sub(MIN, MIN))
      assert.equals("9007199254740993", int64.sub("9007199254740992", -1))
    end)

    it("should report overflow instead of wrapping", function()
      local v, err = int64.sub(MIN, "1")
      assert.is_nil(v)
      assert.matches("overflow", err)
      -- 0 - MIN would be 2^63, one past MAX; the sign flip must not
      -- overflow an intermediate either — the failure is the RESULT's
      v, err = int64.sub("0", MIN)
      assert.is_nil(v)
      assert.matches("overflow", err)
      v, err = int64.sub(MAX, MIN)
      assert.is_nil(v)
      assert.matches("overflow", err)
    end)
  end)

  describe("neg", function()
    it("should negate exactly", function()
      assert.equals("-5", int64.neg("5"))
      assert.equals("5", int64.neg("-5"))
      assert.equals("0", int64.neg("0"))
      assert.equals("-" .. MAX, int64.neg(MAX))
      assert.equals(MAX, int64.neg("-" .. MAX))
    end)

    it("should report overflow for MIN", function()
      local v, err = int64.neg(MIN)
      assert.is_nil(v)
      assert.matches("overflow", err)
    end)
  end)

  describe("module API", function()
    it("should expose the range bounds", function()
      assert.equals(MAX, int64.MAX)
      assert.equals(MIN, int64.MIN)
    end)

    it("should return a version string", function()
      local version = int64.getVersion()
      assert.is_string(version)
      assert.matches("^%d+%.%d+%.%d+$", version)
    end)
  end)
end)
