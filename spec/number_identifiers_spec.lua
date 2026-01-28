-- number_identifiers_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local number_identifiers = require("number_identifiers")
local error_reporting = require("error_reporting")

describe("number_identifiers", function()
  local nullBadVal = error_reporting.nullBadVal

  describe("numberToIdentifier", function()
    it("should handle regular integers", function()
      assert.equals("_I0", number_identifiers.numberToIdentifier(nullBadVal, 0))
      assert.equals("_I42", number_identifiers.numberToIdentifier(nullBadVal, 42))
      assert.equals("_I_42", number_identifiers.numberToIdentifier(nullBadVal, -42))
    end)

    it("should handle regular floats", function()
      assert.equals("_F3_14", number_identifiers.numberToIdentifier(nullBadVal, 3.14))
      assert.equals("_F_3_14", number_identifiers.numberToIdentifier(nullBadVal, -3.14))
      -- Should trim trailing zeros
      assert.equals("_F1_5", number_identifiers.numberToIdentifier(nullBadVal, 1.50))
    end)

    it("should handle special values", function()
      assert.equals("_NaN", number_identifiers.numberToIdentifier(nullBadVal, 0/0))
      assert.equals("_Infinity", number_identifiers.numberToIdentifier(nullBadVal, 1/0))
      assert.equals("_NegativeInfinity", number_identifiers.numberToIdentifier(nullBadVal, -1/0))
    end)

    it("should handle scientific notation correctly", function()
      assert.equals("_F1000000_", number_identifiers.numberToIdentifier(nullBadVal, 1e6))
      assert.equals("_F0_000001", number_identifiers.numberToIdentifier(nullBadVal, 1e-6))
    end)

    it("should return nil for non-numbers", function()
      assert.is_nil(number_identifiers.numberToIdentifier(nullBadVal, "not a number"))
      assert.is_nil(number_identifiers.numberToIdentifier(nullBadVal, nil))
      assert.is_nil(number_identifiers.numberToIdentifier(nullBadVal, {}))
      assert.is_nil(number_identifiers.numberToIdentifier(nullBadVal, true))
    end)

    it("should handle very large integers (near maxinteger)", function()
      local maxint = math.maxinteger
      local minint = math.mininteger

      -- Test max integer
      local id = number_identifiers.numberToIdentifier(nullBadVal, maxint)
      assert.is_not_nil(id)
      assert.equals("_I" .. tostring(maxint), id)

      -- Test min integer
      id = number_identifiers.numberToIdentifier(nullBadVal, minint)
      assert.is_not_nil(id)
      assert.equals("_I_" .. tostring(minint):sub(2), id)

      -- Test values near the boundaries
      assert.is_not_nil(number_identifiers.numberToIdentifier(nullBadVal, maxint - 1))
      assert.is_not_nil(number_identifiers.numberToIdentifier(nullBadVal, minint + 1))
    end)

    it("should handle very small floats (subnormal numbers)", function()
      -- Smallest positive subnormal: approximately 5e-324 (2^-1074)
      local smallest_subnormal = 2^-1074
      local small_subnormal = 2^-1073

      -- Test that we can create identifiers for subnormal numbers
      local id1 = number_identifiers.numberToIdentifier(nullBadVal, smallest_subnormal)
      assert.is_not_nil(id1)
      assert.is_true(id1:sub(1, 2) == "_F")

      local id2 = number_identifiers.numberToIdentifier(nullBadVal, small_subnormal)
      assert.is_not_nil(id2)

      -- Test negative subnormals
      local id3 = number_identifiers.numberToIdentifier(nullBadVal, -smallest_subnormal)
      assert.is_not_nil(id3)
      assert.is_true(id3:sub(1, 3) == "_F_")
    end)

    it("should handle float precision edge cases", function()
      -- Numbers that are tricky for floating-point representation
      local precision_cases = {
        0.1,                    -- Cannot be exactly represented in binary
        0.2,                    -- Cannot be exactly represented in binary
        0.1 + 0.2,              -- Classic floating-point precision example
        1/3,                    -- Repeating decimal
        math.pi,                -- Irrational number
        2.2204460492503131e-16, -- Machine epsilon
        1 + 2.2204460492503131e-16, -- 1 + epsilon
        9007199254740993.0,     -- 2^53 + 1 (beyond integer precision for floats)
      }

      for _, num in ipairs(precision_cases) do
        local id = number_identifiers.numberToIdentifier(nullBadVal, num)
        assert.is_not_nil(id, "Failed to create identifier for: " .. tostring(num))
      end
    end)
  end)

  

  describe("identifierToNumber", function()
    it("should handle regular integers", function()
      assert.equals(0, number_identifiers.identifierToNumber(nullBadVal, "_I0"))
      assert.equals(42, number_identifiers.identifierToNumber(nullBadVal, "_I42"))
      assert.equals(-42, number_identifiers.identifierToNumber(nullBadVal, "_I_42"))
    end)

    it("should handle regular floats", function()
      assert.equals(3.14, number_identifiers.identifierToNumber(nullBadVal, "_F3_14"))
      assert.equals(-3.14, number_identifiers.identifierToNumber(nullBadVal, "_F_3_14"))
      assert.equals(1.5, number_identifiers.identifierToNumber(nullBadVal, "_F1_5"))
    end)

    it("should handle special values", function()
      -- For NaN, we can't use equals
      local nan = number_identifiers.identifierToNumber(nullBadVal, "_NaN")
      assert.is_true(nan ~= nan)  -- NaN is not equal to itself

      assert.equals(math.huge, number_identifiers.identifierToNumber(nullBadVal, "_Infinity"))
      assert.equals(-math.huge, number_identifiers.identifierToNumber(nullBadVal, "_NegativeInfinity"))
    end)

    it("should handle conversion of numberToIdentifier output", function()
      local numbers = {0, 42, -42, 3.14, -3.14, 1e6, 1e-6, 1/0, -1/0}
      for _, num in ipairs(numbers) do
        local id = number_identifiers.numberToIdentifier(nullBadVal, num)
        local back = number_identifiers.identifierToNumber(nullBadVal, id)
        assert.equals(num, back)
      end

      -- Special case for NaN since it doesn't equal itself
      local id = number_identifiers.numberToIdentifier(nullBadVal, 0/0)
      local back = number_identifiers.identifierToNumber(nullBadVal, id)
      assert.is_true(back ~= back)  -- Test that it's NaN
    end)

    it("should round-trip very large integers (near maxinteger)", function()
      local large_integers = {
        math.maxinteger,
        math.mininteger,
        math.maxinteger - 1,
        math.mininteger + 1,
        math.maxinteger - 1000,
        math.mininteger + 1000,
      }

      for _, num in ipairs(large_integers) do
        local id = number_identifiers.numberToIdentifier(nullBadVal, num)
        local back = number_identifiers.identifierToNumber(nullBadVal, id)
        assert.equals(num, back, "Round-trip failed for: " .. tostring(num))
      end
    end)

    it("should round-trip very small floats (subnormal numbers)", function()
      -- Note: True subnormals (2^-1074 etc.) cannot round-trip because
      -- the fixed-point format "%.Nf" rounds them to 0.
      -- This tests the smallest floats that CAN round-trip with the current implementation.
      local small_floats = {
        1e-17,                -- Very small but representable
        1e-16,                -- Another small value
        1e-15,                -- Slightly larger
        -1e-17,               -- Negative very small
        -1e-16,               -- Negative small
      }

      for _, num in ipairs(small_floats) do
        local id = number_identifiers.numberToIdentifier(nullBadVal, num)
        local back = number_identifiers.identifierToNumber(nullBadVal, id)
        assert.equals(num, back, "Round-trip failed for small float: " .. tostring(num))
      end
    end)

    it("should document that true subnormals lose precision", function()
      -- True subnormals cannot round-trip due to fixed-point format limitations
      local smallest_subnormal = 2^-1074
      local id = number_identifiers.numberToIdentifier(nullBadVal, smallest_subnormal)
      local back = number_identifiers.identifierToNumber(nullBadVal, id)
      -- Documents that subnormals become 0 (known limitation)
      assert.equals(0, back)
    end)

    it("should round-trip float precision edge cases", function()
      local precision_cases = {
        0.1,                    -- Cannot be exactly represented in binary
        0.2,                    -- Cannot be exactly represented in binary
        0.1 + 0.2,              -- Classic floating-point precision example
        1/3,                    -- Repeating decimal
        math.pi,                -- Irrational number
        1.0000000000000002,     -- 1 + epsilon (smallest distinguishable from 1)
        0.30000000000000004,    -- The actual result of 0.1 + 0.2
      }

      for _, num in ipairs(precision_cases) do
        local id = number_identifiers.numberToIdentifier(nullBadVal, num)
        local back = number_identifiers.identifierToNumber(nullBadVal, id)
        assert.equals(num, back, "Round-trip failed for precision case: " .. tostring(num))
      end
    end)

    it("should document that machine epsilon loses precision", function()
      -- Machine epsilon (2.2e-16) is too small for fixed-point format
      local epsilon = 2.2204460492503131e-16
      local id = number_identifiers.numberToIdentifier(nullBadVal, epsilon)
      local back = number_identifiers.identifierToNumber(nullBadVal, id)
      -- Documents that very small values lose precision (known limitation)
      assert.is_not_nil(back)
      assert.not_equals(epsilon, back)
    end)

    it("should return nil for invalid inputs", function()
      assert.is_nil(number_identifiers.identifierToNumber(nullBadVal, "_not_a_number"))
      assert.is_nil(number_identifiers.identifierToNumber(nullBadVal, "_IX123"))  -- invalid integer format
      assert.is_nil(number_identifiers.identifierToNumber(nullBadVal, "_FX123"))  -- invalid float format
      assert.is_nil(number_identifiers.identifierToNumber(nullBadVal, 123))       -- not a string
      assert.is_nil(number_identifiers.identifierToNumber(nullBadVal, nil))       -- nil input
      assert.is_nil(number_identifiers.identifierToNumber(nullBadVal, ""))        -- empty string
      assert.is_nil(number_identifiers.identifierToNumber(nullBadVal, "_K123"))   -- invalid prefix
    end)
  end)

  

  describe("rangeToIdentifier and identifierToRange", function()
    describe("rangeToIdentifier", function()
      it("should handle single bounds", function()
          assert.equals("_R_GE_I0", number_identifiers.rangeToIdentifier(nullBadVal, 0, nil))
          assert.equals("_R_LE_I100", number_identifiers.rangeToIdentifier(nullBadVal, nil, 100))
      end)

      it("should handle both bounds", function()
          assert.equals("_R_GE_I0_LE_I100", number_identifiers.rangeToIdentifier(nullBadVal, 0, 100))
          assert.equals("_R_GE_F_1_5_LE_F2_5", number_identifiers.rangeToIdentifier(nullBadVal, -1.5, 2.5))
      end)

      it("should reject invalid inputs", function()
          assert.is_nil(number_identifiers.rangeToIdentifier(nullBadVal, nil, nil))
          assert.is_nil(number_identifiers.rangeToIdentifier(nullBadVal, "not a number", 100))
          assert.is_nil(number_identifiers.rangeToIdentifier(nullBadVal, 0, "not a number"))
          assert.is_nil(number_identifiers.rangeToIdentifier(nullBadVal, 100, 0))  -- min > max
          assert.is_nil(number_identifiers.rangeToIdentifier(nullBadVal, 0/0, 100))  -- NaN
          assert.is_nil(number_identifiers.rangeToIdentifier(nullBadVal, 0, 0/0))   -- NaN
          assert.is_nil(number_identifiers.rangeToIdentifier(nullBadVal, math.huge, 100))  -- infinite
          assert.is_nil(number_identifiers.rangeToIdentifier(nullBadVal, 0, math.huge))    -- infinite
      end)
    end)

    describe("identifierToRange", function()
      it("should handle single bounds", function()
          local min, max = number_identifiers.identifierToRange(nullBadVal, "_R_GE_I0")
          assert.equals(0, min)
          assert.is_nil(max)

          min, max = number_identifiers.identifierToRange(nullBadVal, "_R_LE_I100")
          assert.is_nil(min)
          assert.equals(100, max)
      end)

      it("should handle both bounds", function()
          local min, max = number_identifiers.identifierToRange(nullBadVal, "_R_GE_I0_LE_I100")
          assert.equals(0, min)
          assert.equals(100, max)

          min, max = number_identifiers.identifierToRange(nullBadVal, "_R_GE_F_1_5_LE_F2_5")
          assert.equals(-1.5, min)
          assert.equals(2.5, max)
      end)

      it("should handle conversion of rangeToIdentifier output", function()
          local ranges = {
              {0, nil},
              {nil, 100},
              {0, 100},
              {-1.5, 2.5},
              {-42, 42}
          }

          for _, range in ipairs(ranges) do
              local id = number_identifiers.rangeToIdentifier(nullBadVal, range[1], range[2])
              local min, max = number_identifiers.identifierToRange(nullBadVal, id)
              assert.equals(range[1], min)
              assert.equals(range[2], max)
          end
      end)

      it("should reject invalid inputs with appropriate error messages", function()
          local log_messages = {}
          local badVal = error_reporting.badValGen(function(self, msg)
              table.insert(log_messages, msg)
          end)

          -- Test non-string input
          local min, max = number_identifiers.identifierToRange(badVal, 123)
          assert.is_nil(min)
          assert.is_nil(max)
          assert.equals("Bad string  in  on line 0: '123' (id must be a string)", log_messages[1])

          -- Clear messages for next test
          for i in ipairs(log_messages) do log_messages[i] = nil end

          -- Test wrong prefix
          min, max = number_identifiers.identifierToRange(badVal, "_X_GE_I0")
          assert.is_nil(min)
          assert.is_nil(max)
          assert.equals("Bad string  in  on line 0: '_X_GE_I0' (id must start with _R)", log_messages[1])

          -- Clear messages
          for i in ipairs(log_messages) do log_messages[i] = nil end

          -- Test empty range
          min, max = number_identifiers.identifierToRange(badVal, "_R")
          assert.is_nil(min)
          assert.is_nil(max)
          assert.equals("Bad string  in  on line 0: '_R' (Empty range not allowed)", log_messages[1])

          -- Clear messages
          for i in ipairs(log_messages) do log_messages[i] = nil end

          -- Test invalid min number
          min, max = number_identifiers.identifierToRange(badVal, "_R_GE_IX100")
          assert.is_nil(min)
          assert.is_nil(max)
          assert.equals("Bad string  in  on line 0: '_R_GE_IX100' (min number invalid)", log_messages[1])

          -- Clear messages
          for i in ipairs(log_messages) do log_messages[i] = nil end

          -- Test invalid max part
          min, max = number_identifiers.identifierToRange(badVal, "_R_GE_I0_XX")
          assert.is_nil(min)
          assert.is_nil(max)
          assert.equals("Bad string  in  on line 0: '_R_GE_I0_XX' (min number invalid)", log_messages[1])

          -- Clear messages
          for i in ipairs(log_messages) do log_messages[i] = nil end

          -- Test invalid max number
          min, max = number_identifiers.identifierToRange(badVal, "_R_GE_I0_LE_IX100")
          assert.is_nil(min)
          assert.is_nil(max)
          assert.equals("Bad string  in  on line 0: '_R_GE_I0_LE_IX100' (max number invalid)", log_messages[1])

          -- Clear messages
          for i in ipairs(log_messages) do log_messages[i] = nil end

          -- Test min > max
          min, max = number_identifiers.identifierToRange(badVal, "_R_GE_I100_LE_I0")
          assert.is_nil(min)
          assert.is_nil(max)
          assert.equals("Bad string  in  on line 0: '_R_GE_I100_LE_I0' (min cannot be greater than max)", log_messages[1])
      end)
    end)
  end)

  describe("module API", function()
    describe("getVersion", function()
      it("should return a version string", function()
        local version = number_identifiers.getVersion()
        assert.is_string(version)
        assert.matches("^%d+%.%d+%.%d+$", version)
      end)
    end)

    describe("callable API", function()
      it("should return version when called with 'version'", function()
        local version = number_identifiers("version")
        assert.is_not_nil(version)
        -- Version is a semver object
        assert.are.equal(number_identifiers.getVersion(), tostring(version))
      end)

      it("should call API functions when called with function name", function()
        local result = number_identifiers("numberToIdentifier", nullBadVal, 42)
        assert.are.equal("_I42", result)
      end)

      it("should error on unknown operation", function()
        assert.has_error(function()
          number_identifiers("nonexistent_operation")
        end, "Unknown operation: nonexistent_operation")
      end)
    end)

    describe("__tostring", function()
      it("should return module name and version", function()
        local str = tostring(number_identifiers)
        assert.is_string(str)
        assert.matches("^number_identifiers version %d+%.%d+%.%d+$", str)
      end)
    end)
  end)
end)
