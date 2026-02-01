-- parsers_custom_types_spec.lua
-- Tests for registerTypesFromSpec (data-driven custom type registration)

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local parsers = require("parsers")
local error_reporting = require("error_reporting")

-- Returns a "badVal" object that stores errors in the given table
local function mockBadVal(log_messages)
    local log = function(_self, msg) table.insert(log_messages, msg) end
    local badVal = error_reporting.badValGen(log)
    badVal.source_name = "test"
    badVal.line_no = 1
    return badVal
end

describe("parsers - registerTypesFromSpec", function()

  describe("basic validation", function()
    it("should reject non-table input", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      assert.is_false(parsers.registerTypesFromSpec(badVal, "not a table"))
      assert.is_true(#log_messages > 0)
    end)

    it("should reject specs with empty name", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "", parent = "integer", min = 1 }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)

    it("should reject specs with missing parent", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "myType", parent = "" }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)

    it("should reject specs mixing constraint types", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      -- Mixing numeric and string constraints
      local specs = {{ name = "mixedType", parent = "string", min = 0, minLen = 1 }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)

    it("should succeed with empty specs table", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      assert.is_true(parsers.registerTypesFromSpec(badVal, {}))
      assert.equals(0, #log_messages)
    end)
  end)

  describe("numeric type restrictions", function()
    it("should register integer with min constraint", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctPositiveInt", parent = "integer", min = 1 }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))
      assert.equals(0, #log_messages)

      -- Test the registered type
      local parser = parsers.parseType(badVal, "ctPositiveInt")
      assert.is_not_nil(parser)

      -- Valid values
      local val1 = parser(badVal, "5", "tsv")
      assert.equals(5, val1)

      local val2 = parser(badVal, "1", "tsv")
      assert.equals(1, val2)

      -- Invalid values (below min)
      local val3 = parser(badVal, "0", "tsv")
      assert.is_nil(val3)

      local val4 = parser(badVal, "-5", "tsv")
      assert.is_nil(val4)
    end)

    it("should register number with min and max constraints", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctPercentage", parent = "number", min = 0, max = 100 }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctPercentage")
      assert.is_not_nil(parser)

      -- Valid values
      assert.equals(0, parser(badVal, "0", "tsv"))
      assert.equals(50, parser(badVal, "50", "tsv"))
      assert.equals(100, parser(badVal, "100", "tsv"))
      assert.equals(33.33, parser(badVal, "33.33", "tsv"))

      -- Invalid values (outside range)
      assert.is_nil(parser(badVal, "-1", "tsv"))
      assert.is_nil(parser(badVal, "101", "tsv"))
      assert.is_nil(parser(badVal, "200", "tsv"))
    end)

    it("should register integer with max only constraint", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctSmallInt", parent = "integer", max = 10 }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctSmallInt")
      assert.is_not_nil(parser)

      -- Valid values
      assert.equals(-100, parser(badVal, "-100", "tsv"))
      assert.equals(0, parser(badVal, "0", "tsv"))
      assert.equals(10, parser(badVal, "10", "tsv"))

      -- Invalid values (above max)
      assert.is_nil(parser(badVal, "11", "tsv"))
    end)

    it("should reject numeric constraints on non-numeric parent", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "badNumeric", parent = "string", min = 0 }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)
  end)

  describe("string type restrictions", function()
    it("should register string with minLen constraint", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctNonEmptyStr", parent = "string", minLen = 1 }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctNonEmptyStr")
      assert.is_not_nil(parser)

      -- Valid values
      assert.equals("a", parser(badVal, "a", "tsv"))
      assert.equals("hello", parser(badVal, "hello", "tsv"))

      -- Invalid values (empty string)
      assert.is_nil(parser(badVal, "", "tsv"))
    end)

    it("should register string with minLen and maxLen constraints", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctShortCode", parent = "string", minLen = 2, maxLen = 5 }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctShortCode")
      assert.is_not_nil(parser)

      -- Valid values
      assert.equals("AB", parser(badVal, "AB", "tsv"))
      assert.equals("ABCDE", parser(badVal, "ABCDE", "tsv"))

      -- Invalid values
      assert.is_nil(parser(badVal, "A", "tsv"))  -- too short
      assert.is_nil(parser(badVal, "ABCDEF", "tsv"))  -- too long
    end)

    it("should register string with pattern constraint (requires minLen)", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      -- Note: pattern requires at least minLen or maxLen due to restrictString implementation
      local specs = {{ name = "ctUpperCode", parent = "string", minLen = 1, pattern = "^[A-Z]+$" }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctUpperCode")
      assert.is_not_nil(parser)

      -- Valid values (uppercase only)
      assert.equals("ABC", parser(badVal, "ABC", "tsv"))
      assert.equals("XYZ", parser(badVal, "XYZ", "tsv"))

      -- Invalid values (contains lowercase or digits)
      assert.is_nil(parser(badVal, "abc", "tsv"))
      assert.is_nil(parser(badVal, "ABC123", "tsv"))
      assert.is_nil(parser(badVal, "AbC", "tsv"))
    end)

    it("should register string with combined length and pattern constraints", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{
        name = "ctProductCode",
        parent = "string",
        minLen = 3,
        maxLen = 6,
        pattern = "^[A-Z][0-9]+$"
      }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctProductCode")
      assert.is_not_nil(parser)

      -- Valid values (letter followed by digits, 3-6 chars)
      assert.equals("A12", parser(badVal, "A12", "tsv"))
      assert.equals("B12345", parser(badVal, "B12345", "tsv"))

      -- Invalid: too short
      assert.is_nil(parser(badVal, "A1", "tsv"))
      -- Invalid: too long
      assert.is_nil(parser(badVal, "A123456", "tsv"))
      -- Invalid: wrong pattern
      assert.is_nil(parser(badVal, "123", "tsv"))
      assert.is_nil(parser(badVal, "ABC", "tsv"))
    end)

    it("should reject string constraints on non-string parent", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "badString", parent = "number", minLen = 1 }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)
  end)

  describe("enum type restrictions", function()
    it("should register enum with restricted values", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- First create a base enum
      parsers.registerEnumParser(badVal, {"red", "green", "blue", "yellow", "orange"}, "ctColorFull")

      -- Now restrict it
      local specs = {{ name = "ctPrimaryColor", parent = "ctColorFull", values = {"red", "green", "blue"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctPrimaryColor")
      assert.is_not_nil(parser)

      -- Valid values (primary colors)
      assert.equals("red", parser(badVal, "red", "tsv"))
      assert.equals("green", parser(badVal, "green", "tsv"))
      assert.equals("blue", parser(badVal, "blue", "tsv"))

      -- Invalid values (not in restricted set)
      assert.is_nil(parser(badVal, "yellow", "tsv"))
      assert.is_nil(parser(badVal, "orange", "tsv"))
      assert.is_nil(parser(badVal, "purple", "tsv"))
    end)

    it("should reject enum constraints on non-enum parent", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "badEnum", parent = "number", values = {"a", "b"} }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)
  end)

  describe("alias registration (no constraints)", function()
    it("should register type alias when no constraints specified", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctMyInteger", parent = "integer" }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))
      assert.equals(0, #log_messages)

      -- Test the registered alias
      local parser = parsers.parseType(badVal, "ctMyInteger")
      assert.is_not_nil(parser)
      assert.equals(42, parser(badVal, "42", "tsv"))
    end)

    it("should register alias to complex type", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctOptionalInt", parent = "integer|nil" }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctOptionalInt")
      assert.is_not_nil(parser)
      assert.equals(42, parser(badVal, "42", "tsv"))
      assert.equals(nil, parser(badVal, "", "tsv"))
    end)
  end)

  describe("multiple type registration", function()
    it("should register multiple types in sequence", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local specs = {
        { name = "ctPosNum", parent = "number", min = 0 },
        { name = "ctShortStr", parent = "string", maxLen = 10 },
        { name = "ctMyBool", parent = "boolean" },
      }
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))
      assert.equals(0, #log_messages)

      -- Verify all types work
      local p1 = parsers.parseType(badVal, "ctPosNum")
      assert.equals(5.5, p1(badVal, "5.5", "tsv"))
      assert.is_nil(p1(badVal, "-1", "tsv"))

      local p2 = parsers.parseType(badVal, "ctShortStr")
      assert.equals("hello", p2(badVal, "hello", "tsv"))
      assert.is_nil(p2(badVal, "this is too long", "tsv"))

      local p3 = parsers.parseType(badVal, "ctMyBool")
      assert.equals(true, p3(badVal, "true", "tsv"))
    end)

    it("should stop on first error but continue processing", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local specs = {
        { name = "ctGoodType1", parent = "integer", min = 0 },
        { name = "ctBadType", parent = "string", min = 0 },  -- Invalid: min on string
        { name = "ctGoodType2", parent = "string", minLen = 1 },
      }
      -- Should return false due to error
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      -- But should still have registered the valid types
      assert.is_not_nil(parsers.parseType(badVal, "ctGoodType1"))
      assert.is_not_nil(parsers.parseType(badVal, "ctGoodType2"))
    end)
  end)

  describe("expression-based validators", function()
    it("should register type with simple expression validator", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctEvenInt", parent = "integer", validate = "value % 2 == 0" }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))
      assert.equals(0, #log_messages)

      local parser = parsers.parseType(badVal, "ctEvenInt")
      assert.is_not_nil(parser)

      -- Valid values (even numbers)
      assert.equals(0, parser(badVal, "0", "tsv"))
      assert.equals(2, parser(badVal, "2", "tsv"))
      assert.equals(100, parser(badVal, "100", "tsv"))
      assert.equals(-4, parser(badVal, "-4", "tsv"))

      -- Invalid values (odd numbers)
      assert.is_nil(parser(badVal, "1", "tsv"))
      assert.is_nil(parser(badVal, "3", "tsv"))
      assert.is_nil(parser(badVal, "-7", "tsv"))
    end)

    it("should register type with comparison expression", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctPositiveExpr", parent = "number", validate = "value > 0" }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctPositiveExpr")
      assert.is_not_nil(parser)

      -- Valid values
      assert.equals(1, parser(badVal, "1", "tsv"))
      assert.equals(0.5, parser(badVal, "0.5", "tsv"))
      assert.equals(1000, parser(badVal, "1000", "tsv"))

      -- Invalid values
      assert.is_nil(parser(badVal, "0", "tsv"))
      assert.is_nil(parser(badVal, "-1", "tsv"))
    end)

    it("should register type with string pattern expression", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctCoords", parent = "string", validate = "value:match('^%-?%d+,%-?%d+$')" }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctCoords")
      assert.is_not_nil(parser)

      -- Valid coordinates
      assert.equals("10,20", parser(badVal, "10,20", "tsv"))
      assert.equals("-5,100", parser(badVal, "-5,100", "tsv"))
      assert.equals("0,0", parser(badVal, "0,0", "tsv"))

      -- Invalid coordinates
      assert.is_nil(parser(badVal, "10", "tsv"))
      assert.is_nil(parser(badVal, "a,b", "tsv"))
      assert.is_nil(parser(badVal, "10,20,30", "tsv"))
    end)

    it("should provide access to math functions in expression", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctSqrtable", parent = "number", validate = "value >= 0 and math.sqrt(value) == math.floor(math.sqrt(value))" }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctSqrtable")
      assert.is_not_nil(parser)

      -- Perfect squares
      assert.equals(0, parser(badVal, "0", "tsv"))
      assert.equals(1, parser(badVal, "1", "tsv"))
      assert.equals(4, parser(badVal, "4", "tsv"))
      assert.equals(9, parser(badVal, "9", "tsv"))
      assert.equals(16, parser(badVal, "16", "tsv"))

      -- Not perfect squares
      assert.is_nil(parser(badVal, "2", "tsv"))
      assert.is_nil(parser(badVal, "3", "tsv"))
      assert.is_nil(parser(badVal, "-1", "tsv"))
    end)

    it("should provide access to predicates in expression", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctValidId", parent = "string", validate = "predicates.isIdentifier(value)" }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctValidId")
      assert.is_not_nil(parser)

      -- Valid identifiers
      assert.equals("foo", parser(badVal, "foo", "tsv"))
      assert.equals("_bar", parser(badVal, "_bar", "tsv"))
      assert.equals("myVar123", parser(badVal, "myVar123", "tsv"))

      -- Invalid identifiers
      assert.is_nil(parser(badVal, "123abc", "tsv"))
      assert.is_nil(parser(badVal, "foo-bar", "tsv"))
      assert.is_nil(parser(badVal, "", "tsv"))
    end)

    it("should provide access to stringUtils in expression", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctTrimmedNonEmpty", parent = "string", validate = "#stringUtils.trim(value) > 0" }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctTrimmedNonEmpty")
      assert.is_not_nil(parser)

      -- Non-empty after trim
      assert.equals("hello", parser(badVal, "hello", "tsv"))
      assert.equals("  hello  ", parser(badVal, "  hello  ", "tsv"))

      -- Empty after trim
      assert.is_nil(parser(badVal, "", "tsv"))
      assert.is_nil(parser(badVal, "   ", "tsv"))
    end)

    it("should reject expression that doesn't compile", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctBadExpr", parent = "integer", validate = "value >" }}  -- Syntax error
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)

    it("should reject mixing expression with data-driven constraints", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      -- Try to mix validate with min
      local specs = {{ name = "ctMixedExpr", parent = "integer", validate = "value > 0", min = 1 }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)

    it("should handle expression that returns false for invalid values", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local specs = {{ name = "ctDivisibleBy5", parent = "integer", validate = "value % 5 == 0" }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctDivisibleBy5")
      assert.is_not_nil(parser)

      -- Divisible by 5
      assert.equals(0, parser(badVal, "0", "tsv"))
      assert.equals(5, parser(badVal, "5", "tsv"))
      assert.equals(10, parser(badVal, "10", "tsv"))
      assert.equals(-15, parser(badVal, "-15", "tsv"))

      -- Not divisible by 5
      assert.is_nil(parser(badVal, "1", "tsv"))
      assert.is_nil(parser(badVal, "7", "tsv"))
    end)

    it("should work with complex parent types", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      -- Use integer|nil as parent, validate only non-nil values
      local specs = {{ name = "ctOptionalPositive", parent = "integer|nil", validate = "value == nil or value > 0" }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ctOptionalPositive")
      assert.is_not_nil(parser)

      -- Valid: positive or nil
      assert.equals(1, parser(badVal, "1", "tsv"))
      assert.equals(100, parser(badVal, "100", "tsv"))
      assert.equals(nil, parser(badVal, "", "tsv"))  -- nil is valid

      -- Invalid: zero or negative
      assert.is_nil(parser(badVal, "0", "tsv"))
      assert.is_nil(parser(badVal, "-1", "tsv"))
    end)
  end)

end)
