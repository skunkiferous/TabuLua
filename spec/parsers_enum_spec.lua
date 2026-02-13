-- parsers_enum_spec.lua
-- Tests for enum type parsers

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each

local parsers = require("parsers")
local registerEnumParser = parsers.registerEnumParser
local error_reporting = require("error_reporting")

-- Returns a "badVal" object that store errors in the given table
local function mockBadVal(log_messages)
    local log = function(_self, msg) table.insert(log_messages, msg) end
    local badVal = error_reporting.badValGen(log)
    badVal.source_name = "test"
    badVal.line_no = 1
    return badVal
end

local function assert_equals_2(a1, b1, a2, b2)
  local success = true
  local error_message = ""

  -- Check first pair (a1, a2)
  if type(a1) == "number" and type(a2) == "number" then
    if math.abs(a1 - a2) >= 0.00000001 then
      success = false
      error_message = string.format("First pair numeric values differ: %s ~= %s",
                                    tostring(a1), tostring(a2))
    end
  else
    local same_a = pcall(function() assert.same(a1, a2) end)
    if not same_a then
      success = false
      error_message = string.format("First pair values differ: %s ~= %s",
                                   tostring(a1), tostring(a2))
    end
  end

  -- Check second pair (b1, b2)
  local same_b = pcall(function() assert.same(b1, b2) end)
  if not same_b then
    if success then  -- Only overwrite message if first pair passed
      success = false
      error_message = string.format("Second pair values differ: %s ~= %s",
                                   tostring(b1), tostring(b2))
    else  -- Both pairs failed
      error_message = error_message .. " AND " ..
                     string.format("Second pair values differ: %s ~= %s",
                                  tostring(b1), tostring(b2))
    end
  end

  -- Assert at the end to provide the informative message
  assert(success, error_message)
end

describe("parsers - enum types", function()

  describe("registerEnumParser", function()
    local log_messages
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should register valid enum parsers", function()
      -- Basic enum with simple labels
      local parser = registerEnumParser(badVal, {"Red", "Green", "Blue"}, "Color")
      assert.is_not_nil(parser)
      assert_equals_2("Red", "Red", parser(badVal, "red"))
      assert_equals_2("Green", "Green", parser(badVal, "GREEN"))
      assert_equals_2("Blue", "Blue", parser(badVal, "blue"))
      assert.same({}, log_messages)

      -- Test different capitalization is normalized
      assert_equals_2("Red", "Red", parser(badVal, "RED"))
      assert_equals_2("Green", "Green", parser(badVal, "green"))
      assert.same({}, log_messages)

      -- Different enum with underscores
      parser = registerEnumParser(badVal, {"Wood_Log", "Stone_Block"}, "Resource_Type")
      assert.is_not_nil(parser)
      assert_equals_2("Wood_Log", "Wood_Log", parser(badVal, "wood_log"))
      assert_equals_2("Stone_Block", "Stone_Block", parser(badVal, "STONE_BLOCK"))
      assert.same({}, log_messages)
    end)

    it("should reject invalid enum names", function()
      -- Test invalid enum names
      assert.is_nil(registerEnumParser(badVal, {"Red", "Green"}, "2Color"))
      assert.is_nil(registerEnumParser(badVal, {"Red", "Green"}, "Color-Type"))
      assert.is_nil(registerEnumParser(badVal, {"Red", "Green"}, ""))
      assert.is_nil(registerEnumParser(badVal, {"Red", "Green"}, 123))
      assert.is_nil(registerEnumParser(badVal, {"Red", "Green"}, true))
      assert.is_nil(registerEnumParser(badVal, {"Red", "Green"}, "nil")) -- Reserved keyword
      assert.is_nil(registerEnumParser(badVal, {"Red", "Green"}, "self")) -- Reserved name
      assert.is_nil(registerEnumParser(badVal, {"Red", "Green"}, "_1")) -- Tuple field name
      assert.is_nil(registerEnumParser(badVal, {"Red", "Green"}, "MyEnum_")) -- Trailing underscore

      assert.same({
        "Bad type  in test on line 1: '2Color' (Parser name '2Color' format is not valid)",
        "Bad type  in test on line 1: 'Color-Type' (Parser name 'Color-Type' format is not valid)",
        "Bad type  in test on line 1: '' (Parser name '' format is not valid)",
        "Bad type  in test on line 1: '123' (Parser name '123' must be a string, but was number)",
        "Bad type  in test on line 1: 'true' (Parser name 'true' must be a string, but was boolean)",
        "Bad type  in test on line 1: 'nil' (Parser name 'nil' cannot be a keyword)",
        "Bad type  in test on line 1: 'self' (Parser name 'self' is a reserved name)",
        "Bad type  in test on line 1: '_1' (Parser name '_1' is reserved for tuples)",
        "Bad type  in test on line 1: 'MyEnum_' (Parser name 'MyEnum_' cannot end with '_')"
      }, log_messages)
    end)

    it("should reject invalid enum labels", function()
      -- Test invalid enum labels
      assert.is_nil(parsers.registerEnumParser(badVal, {"2Red", "Green-Blue"}, "ColorA"))
      assert.is_nil(parsers.registerEnumParser(badVal, {123, "Green"}, "ColorB"))
      assert.is_nil(parsers.registerEnumParser(badVal, {"Red", "red"}, "ColorC")) -- Case-insensitive duplicate
      assert.is_nil(parsers.registerEnumParser(badVal, {"true", "false"}, "ColorD")) -- Reserved keywords
      assert.is_nil(parsers.registerEnumParser(badVal, {"Self", "Other"}, "ColorE")) -- Reserved name (case-insensitive)
      assert.is_nil(parsers.registerEnumParser(badVal, {"_1", "_2"}, "ColorF")) -- Tuple field names
      assert.is_nil(parsers.registerEnumParser(badVal, "Not_A_Table", "ColorG"))

      assert.same({
        "Bad enum_label  in test on line 1: '2Red' (enum_labels[i] must be an identifier: 2Red)",
        "Bad enum_label  in test on line 1: 'Green-Blue' (enum_labels[i] must be an identifier: Green-Blue)",
        "Bad enum_label  in test on line 1: '123' (enum_labels[i] must be a string: number)",
        "Bad enum_label  in test on line 1: 'red' (enum_labels[i] must be unique: red)",
        "Bad enum_label  in test on line 1: 'true' (enum_labels[i] cannot be a keyword: true)",
        "Bad enum_label  in test on line 1: 'false' (enum_labels[i] cannot be a keyword: false)",
        "Bad enum_label  in test on line 1: 'Self' (enum_labels[i] cannot be a reserved name: Self)",
        "Bad enum_label  in test on line 1: '_1' (enum_labels[i] is reserved for tuples: _1)",
        "Bad enum_label  in test on line 1: '_2' (enum_labels[i] is reserved for tuples: _2)",
        "Bad enum_labels  in test on line 1: 'Not_A_Table' (enum_labels must be a table string: string)"
      }, log_messages)
    end)

    it("should handle parser reuse appropriately", function()
      -- First registration should succeed
      local parser1 = parsers.registerEnumParser(badVal, {"Active", "Inactive"}, "Status")
      assert.is_not_nil(parser1)
      assert.same({}, log_messages)

      -- Registering same enum with same labels should succeed and return same parser
      local parser2 = parsers.registerEnumParser(badVal, {"Active", "Inactive"}, "Status")
      assert.is_not_nil(parser2)
      assert.are.equal(parser1, parser2)
      assert.same({}, log_messages)

      -- Registering same enum with different labels should fail
      local parser3 = parsers.registerEnumParser(badVal,{"On", "Off"}, "Status")
      assert.is_nil(parser3)
      assert.same({
        "Bad type  in test on line 1: '{enum:off|on}' (Alias 'Status' is already registered to a different type: {enum:active|inactive})"
      }, log_messages)
    end)

    it("should handle invalid values when parsing", function()
      local parser = parsers.registerEnumParser(badVal, {"North", "South", "East", "West"}, "Direction")
      assert.is_not_nil(parser)

      -- Clear messages from registration
      log_messages = {}
      badVal = mockBadVal(log_messages)

      -- Test invalid values
      assert_equals_2(nil, "Invalid", parser(badVal, "Invalid"))
      assert_equals_2(nil, "123", parser(badVal, 123))
      assert_equals_2(nil, "true", parser(badVal, true))

      assert.same({
        "Bad {enum:east|north|south|west}  in test on line 1: 'Invalid'",
        "Bad {enum:east|north|south|west}  in test on line 1: '123'",
        "Bad {enum:east|north|south|west}  in test on line 1: 'true'"
      }, log_messages)
    end)
  end)

  describe("restrictEnum", function()
    local log_messages = {}
    local badVal

    before_each(function()
        log_messages = {}
        badVal = mockBadVal(log_messages)
    end)

    it("should handle basic enum restrictions", function()
        -- First create a base enum type
        assert(registerEnumParser(badVal, {"Red", "Green", "Blue", "Yellow"}, "FourColors"))

        -- Create restricted enum with subset of values
        local parser, name = parsers.restrictEnum(badVal, "FourColors", {"Red", "Blue"},
          "DeathmatchColor")
        assert.is_not_nil(parser)
        assert.equals("{enum:blue|red}", name)

        -- Test valid values
        assert.equals("Red", parser(badVal, "red"))
        assert.equals("Blue", parser(badVal, "BLUE"))

        -- Test invalid values (values from parent enum but not in restriction)
        assert.is_nil(parser(badVal, "Green"))
        assert.is_nil(parser(badVal, "Yellow"))
        assert.same({
            'Bad {enum:blue|red}  in test on line 1: \'Green\'',
            'Bad {enum:blue|red}  in test on line 1: \'Yellow\''
        }, log_messages)
    end)

    it("should handle case insensitivity", function()
        -- Create base enum
        assert(registerEnumParser(badVal, {"North", "South", "East", "West"}, "Direction"))

        -- Create restricted enum
        local parser = parsers.restrictEnum(badVal, "Direction", {"North", "South"})
        assert.is_not_nil(parser)

        -- Test case variations
        assert.equals("North", parser(badVal, "north"))
        assert.equals("North", parser(badVal, "NORTH"))
        assert.equals("South", parser(badVal, "south"))
        assert.equals("South", parser(badVal, "SOUTH"))
    end)

    it("should reject invalid base enum types", function()
        -- Try to restrict a non-enum type
        local parser = parsers.restrictEnum(badVal, "string", {"Value1", "Value2"})
        assert.is_nil(parser)
        assert.same({
            'Bad type  in test on line 1: \'string\' (enumType must extend enum)'
        }, log_messages)
    end)

    it("should reject invalid label lists", function()
        -- Create base enum
        assert(registerEnumParser(badVal, {"One", "Two", "Three"}, "Numbers"))

        -- Test with non-table labels
        local parser1 = parsers.restrictEnum(badVal, "Numbers", "One")
        assert.is_nil(parser1)

        -- Test with invalid label value
        local parser2 = parsers.restrictEnum(badVal, "Numbers", {"One", "Four"})
        assert.is_nil(parser2)

        -- Test with empty label list
        local parser3 = parsers.restrictEnum(badVal, "Numbers", {})
        assert.is_nil(parser3)

        assert.same({
            'Bad table  in test on line 1: \'One\' (labels must be a table)',
            'Bad label  in test on line 1: \'Four\' (label is not valid for enum type Numbers)',
            'Bad table  in test on line 1: \'{}\' (no valid label)'
        }, log_messages)
    end)

    it("should handle aliases", function()
        -- Create base enum
        assert(registerEnumParser(badVal, {"Spring", "Summer", "Fall", "Winter"}, "Season"))

        -- Create restricted enum with alias
        local parser1, name1 = parsers.restrictEnum(badVal, "Season",
            {"Spring", "Summer"}, "WarmSeason")
        assert.is_not_nil(parser1)

        -- Verify alias works
        local parser2 = parsers.parseType(badVal, "WarmSeason")
        assert.equals(parser1, parser2)

        -- Try to create same restriction with different alias
        local parser3, name3 = parsers.restrictEnum(badVal, "Season",
            {"Spring", "Summer"}, "HotSeason")
        assert.is_not_nil(parser3)
        assert.equals(name1, name3)  -- Should still return the original name
        assert.same({}, log_messages)
    end)

    it("should handle inheritance between restricted enums", function()
        -- Create base enum
        assert(registerEnumParser(badVal, {"A", "B", "C", "D", "E"}, "Letters5"))

        -- Create first restriction
        local parser1 = parsers.restrictEnum(badVal, "Letters5", {"A", "B", "C"}, "ABC")
        assert.is_not_nil(parser1)

        -- Create further restriction
        local parser2 = parsers.restrictEnum(badVal, "ABC", {"A", "B"}, "AB")
        assert.is_not_nil(parser2)

        -- Test valid values
        assert.equals("A", parser2(badVal, "A"))
        assert.equals("B", parser2(badVal, "B"))

        -- Test invalid values (valid in parent but not in child)
        assert.is_nil(parser2(badVal, "C"))
        assert.is_nil(parser2(badVal, "D"))

        assert.same({
            'Bad {enum:a|b}  in test on line 1: \'C\'',
            'Bad {enum:a|b}  in test on line 1: \'D\''
        }, log_messages)
    end)
  end)

  describe("enumLabels", function()
    it("should extract labels from valid enum types", function()
        -- Test basic enum type
        local labels = parsers.enumLabels("{enum:Red|Green|Blue}")
        assert.is_not_nil(labels)
        assert.same({"blue", "green", "red"}, labels)  -- Should be sorted case-insensitively

        -- Test enum with mixed case
        labels = parsers.enumLabels("{enum:Monday|TUESDAY|wEdNeSdAy}")
        assert.is_not_nil(labels)
        assert.same({"monday", "tuesday", "wednesday"}, labels)
    end)

    it("should return nil for invalid inputs", function()
        -- Test nil input
        assert.is_nil(parsers.enumLabels(nil))

        -- Test non-string input
        assert.is_nil(parsers.enumLabels(123))
        assert.is_nil(parsers.enumLabels({}))
        assert.is_nil(parsers.enumLabels(true))

        -- Test invalid type specifications
        assert.is_nil(parsers.enumLabels("not_an_enum"))
        assert.is_nil(parsers.enumLabels("{string}"))
        assert.is_nil(parsers.enumLabels("{enum:}"))
        assert.is_nil(parsers.enumLabels("{enum:123}"))  -- Non-name value
        assert.is_nil(parsers.enumLabels("{enum:{Red}}"))  -- Non-name value

        -- Test enum with single value, which is not recognized as a "union"
        assert.is_nil(parsers.enumLabels("{enum:Single}"))

        -- Duplicate labels are not accepted
        assert.is_nil(parsers.enumLabels("{enum:Red|Green|Red|Blue|GREEN}"))

        -- Test valid type specs that aren't enums
        assert.is_nil(parsers.enumLabels("string"))
        assert.is_nil(parsers.enumLabels("{string:number}"))
        assert.is_nil(parsers.enumLabels("number|string"))
    end)

    it("should work with registered enum types", function()
        -- First register some enum types
        local log_messages = {}
        local badVal = mockBadVal(log_messages)

        assert(registerEnumParser(badVal, {"North", "South", "East", "West"}, "Direction"))
        assert(parsers.registerAlias(badVal, "CardinalDirection", "Direction"))

        -- Test the registered enum type
        local labels = parsers.enumLabels("Direction")
        assert.is_not_nil(labels)
        assert.same({"east", "north", "south", "west"}, labels)

        -- Test the alias
        labels = parsers.enumLabels("CardinalDirection")
        assert.is_not_nil(labels)
        assert.same({"east", "north", "south", "west"}, labels)

        assert.same({}, log_messages)
    end)
  end)

  describe("getComparator for enums", function()
    local log_messages
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should handle custom enums", function()
        -- Register an enum type
        assert(parsers.registerEnumParser(badVal, {"Low", "Medium", "High"}, "Priority"))
        local enumCmp = parsers.getComparator("Priority")
        assert.is_not_nil(enumCmp)

        -- Case-insensitive comparison
        assert.is_true(enumCmp("Low", "Medium"))
        assert.is_true(enumCmp("low", "MEDIUM"))
        assert.is_true(enumCmp("HIGH", "medium"))
        assert.is_false(enumCmp("low", "LOW"))
    end)
  end)

  describe("extendsOrRestrict for enums", function()
    local log_messages
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should handle enum subset extension", function()
      -- Create base enum with multiple values
      assert(registerEnumParser(badVal, {"Red", "Green", "Blue", "Yellow"}, "AllColors"))

      -- Create another enum that's a subset of AllColors
      assert(registerEnumParser(badVal, {"Red", "Blue"}, "PrimaryColors"))

      -- Create a third enum with non-overlapping values
      assert(registerEnumParser(badVal, {"Purple", "Orange"}, "OtherColors"))

      -- Test explicit extension (registered via registerEnumParser)
      assert.is_true(parsers.extendsOrRestrict("PrimaryColors", "enum"))
      assert.is_true(parsers.extendsOrRestrict("AllColors", "enum"))

      -- Test implicit extension (subset of labels)
      assert.is_true(parsers.extendsOrRestrict("{enum:red|blue}", "AllColors"))
      assert.is_true(parsers.extendsOrRestrict("{enum:red|blue}", "{enum:red|blue|yellow}"))

      -- Test non-extension cases
      assert.is_false(parsers.extendsOrRestrict("AllColors", "PrimaryColors"))  -- superset doesn't extend subset
      assert.is_false(parsers.extendsOrRestrict("OtherColors", "AllColors"))   -- different sets don't extend
      assert.is_false(parsers.extendsOrRestrict("{enum:purple}", "AllColors")) -- different labels

      assert.same({}, log_messages)
    end)
  end)

  describe("typeParent for enums", function()
    local log_messages
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should identify enum type parents", function()
      -- Register some enum parsers to test inheritance
      assert(registerEnumParser(badVal, {"Red", "Green", "Blue"}, "ColorRGB"))
      assert.same({}, log_messages)

      -- Test basic type inheritance
      assert.equals("string", parsers.typeParent("enum"))
      assert.equals("{enum:blue|green|red}", parsers.typeParent("ColorRGB"))
      assert.equals("enum", parsers.typeParent("{enum:blue|green|red}"))
    end)
  end)

  describe("createDefaultValue for enums", function()
    local log_messages
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should create default values for custom types", function()
        -- Register an enum type
        assert(registerEnumParser(badVal, {"Red", "Green", "Blue"}, "Color"))

        -- Test custom types
        assert.equals('', parsers.createDefaultValue("Color")) -- extends enum which extends string

        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)
  end)
end)
