-- parsers_utility_spec.lua
-- Tests for utility functions

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
local serialization = require("serialization")
local serializeTable = serialization.serializeTable

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

  -- Takes two values. Returns true if both must be sequences of numbers, which are
  -- approximately equal.
local function assert_eq_flt_seq(seq1,seq2)
  if seq1 ~= nil or seq2 ~= nil then
    assert.is.not_nil(seq1, "seq1 is nil")
    assert.is.not_nil(seq2, "seq2 is nil")
    assert.are.same(#seq1, #seq2)
    for i=1,#seq1 do
      assert.same('number', type(seq1[i]), "Type of seq1["..i.."] is "..type(seq1[i]))
      assert.same('number', type(seq2[i]), "Type of seq2["..i.."] is "..type(seq2[i]))
      assert(math.abs(seq1[i] - seq2[i]) < 0.00000001)
    end
  end
end

describe("parsers - utility functions", function()

  describe("registerAlias", function()
    it("should support valid type specifications", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      assert(parsers.registerAlias(badVal,"bool","boolean"))
      assert(parsers.registerAlias(badVal,"num","number"))
      assert(parsers.registerAlias(badVal,"my.pct","percent"))
      assert(parsers.registerAlias(badVal,"not.a.string","boolean|number"))
      assert(#log_messages == 0)
    end)

    it("should NOT support invalid type specifications", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      assert(not parsers.registerAlias(badVal,"nope","abcdefg"))
      assert(not parsers.registerAlias(badVal,"nada","boolean|hjiklmn"))
      assert(not parsers.registerAlias(badVal,"also.no",123))
      assert(not parsers.registerAlias(badVal,"boolean","number"))
      assert(not parsers.registerAlias(badVal,false,"number"))
      assert.same({
        "Bad type  in test on line 1: 'abcdefg' (unknown/bad type)",
        "Bad type  in test on line 1: 'hjiklmn' (unknown/bad type)",
        "Bad type  in test on line 1: '123' (Cannot parse type specification: 123)",
        "Bad type  in test on line 1: 'boolean' (Parser with name 'boolean' is already exists)",
        "Bad type  in test on line 1: 'false' (Parser name 'false' must be a string, but was boolean)"},
        log_messages)
    end)
  end)

  describe("typeParent", function()
    local log_messages = {}
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should identify simple type parents", function()
      -- Register some enum parsers to test inheritance
      assert(registerEnumParser(badVal, {"Red", "Green", "Blue"}, "ColorRGB"))
      assert(parsers.registerAlias(badVal, "bool", "boolean"))
      assert.same({}, log_messages)

      -- Test basic type inheritance
      assert.equals("string", parsers.typeParent("enum"))
      assert.equals("{enum:blue|green|red}", parsers.typeParent("ColorRGB"))
      assert.equals("enum", parsers.typeParent("{enum:blue|green|red}"))
      assert.equals("number", parsers.typeParent("integer"))
      assert.equals("boolean", parsers.typeParent("bool"))
    end)

    it("should identify collection type parents", function()
      -- Array types
      assert.equals("array", parsers.typeParent("{string}"))
      assert.equals("array", parsers.typeParent("{number}"))

      -- Map types
      assert.equals("map", parsers.typeParent("{string:number}"))
      assert.equals("map", parsers.typeParent("{identifier:boolean}"))

      -- Tuple types
      assert.equals("tuple", parsers.typeParent("{string,number}"))
      assert.equals("tuple", parsers.typeParent("{boolean,string,number}"))

      -- Record types
      assert.equals("record", parsers.typeParent("{name:string,age:number}"))

      -- Union types
      assert.equals("union", parsers.typeParent("string|number"))
    end)

    it("should return nil for invalid or unknown types", function()
      -- Invalid type specifications
      assert.is_nil(parsers.typeParent(nil))
      assert.is_nil(parsers.typeParent(123))
      assert.is_nil(parsers.typeParent(""))
      assert.is_nil(parsers.typeParent("unknown_type"))
      assert.is_nil(parsers.typeParent("{invalid:syntax"))
    end)

    it("should handle primitive types correctly", function()
      -- Primitive types that don't inherit from anything
      assert.is_nil(parsers.typeParent("string"))
      assert.is_nil(parsers.typeParent("number"))
      assert.is_nil(parsers.typeParent("boolean"))
    end)

    it("should handle complex nested types", function()
      -- Complex nested types should return their outer type
      assert.equals("array", parsers.typeParent("{{string}}"))
      assert.equals("map", parsers.typeParent("{{string:number}:boolean}"))
      assert.equals("tuple", parsers.typeParent("{string,{number}}"))
      assert.equals("record", parsers.typeParent("{data:{string},meta:{name:string}}"))
    end)
  end)

  describe("extendsOrRestrict", function()
    local log_messages = {}
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should identify direct type inheritance", function()
      -- Set up some basic type inheritance
      assert(registerEnumParser(badVal, {"Red", "Green", "Blue"}, "Color"))
      assert(parsers.registerAlias(badVal, "bool", "boolean"))

      -- Test direct inheritance
      assert.is_true(parsers.extendsOrRestrict("enum", "string"))
      assert.is_true(parsers.extendsOrRestrict("bool", "boolean"))
      assert.is_true(parsers.extendsOrRestrict("Color", "enum"))

      -- Test non-inheritance
      assert.is_false(parsers.extendsOrRestrict("string", "number"))
      assert.is_false(parsers.extendsOrRestrict("boolean", "string"))
    end)

    it("should identify indirect type inheritance", function()
      -- Set up multi-level inheritance
      assert(registerEnumParser(badVal, {"North", "South", "East", "West"}, "Direction"))
      assert(parsers.registerAlias(badVal, "cardinal", "Direction"))

      -- Test multi-level inheritance
      assert.equals("{enum:east|north|south|west}", parsers.typeParent("Direction"))
      assert.equals("{enum:east|north|south|west}", parsers.typeParent("cardinal"))
      assert.is_true(parsers.extendsOrRestrict("cardinal", "Direction"))
      assert.is_true(parsers.extendsOrRestrict("Direction", "enum"))
      assert.is_true(parsers.extendsOrRestrict("cardinal", "enum"))
      assert.is_true(parsers.extendsOrRestrict("cardinal", "string"))
    end)

    it("should handle collection type inheritance", function()
      -- Test collection type inheritance
      assert.is_true(parsers.extendsOrRestrict("{string}", "array"))
      assert.is_true(parsers.extendsOrRestrict("{{number}}", "array"))
      assert.is_true(parsers.extendsOrRestrict("{string:number}", "map"))
      assert.is_true(parsers.extendsOrRestrict("{string,number}", "tuple"))
      assert.is_true(parsers.extendsOrRestrict("{name:string,age:integer}", "record"))
      assert.is_true(parsers.extendsOrRestrict("string|number", "union"))

      -- Test non-inheritance between different collection types
      assert.is_false(parsers.extendsOrRestrict("{string}", "map"))
      assert.is_false(parsers.extendsOrRestrict("{string:number}", "array"))
      assert.is_false(parsers.extendsOrRestrict("{string,number}", "record"))
    end)

    it("should handle invalid or primitive types", function()
      -- Invalid types should not extend anything
      assert.is_false(parsers.extendsOrRestrict(nil, "string"))
      assert.is_false(parsers.extendsOrRestrict(123, "number"))
      assert.is_false(parsers.extendsOrRestrict("", "string"))
      assert.is_false(parsers.extendsOrRestrict("invalid_type", "string"))

      -- Primitive types don't extend anything
      assert.is_false(parsers.extendsOrRestrict("string", "any"))
      assert.is_false(parsers.extendsOrRestrict("number", "any"))
      assert.is_false(parsers.extendsOrRestrict("boolean", "any"))
    end)

    it("should handle complex nested types", function()
      -- Complex nested types should properly identify their inheritance
      assert.is_true(parsers.extendsOrRestrict("{{string}}", "array"))
      assert.is_true(parsers.extendsOrRestrict("{data:{string},meta:{name:string}}", "record"))
      assert.is_true(parsers.extendsOrRestrict("{string:enum}", "map"))

      -- Register an enum type and test with it
      assert(registerEnumParser(badVal, {"A", "B", "C"}, "Letters"))
      assert.is_true(parsers.extendsOrRestrict("{Letters}", "array"))
      assert.is_true(parsers.extendsOrRestrict("{string:Letters}", "map"))
      assert.is_true(parsers.extendsOrRestrict("{Letters,number}", "tuple"))
    end)
  end)

  describe("getComparator", function()
    local log_messages = {}
    local badVal

    before_each(function()
        log_messages = {}
        badVal = mockBadVal(log_messages)
    end)

    it("should return valid comparators for basic types", function()
        -- Test number comparator
        local numCmp = parsers.getComparator("number")
        assert.is_not_nil(numCmp)
        assert.is_true(numCmp(1, 2))
        assert.is_false(numCmp(2, 1))
        assert.is_false(numCmp(1, 1))

        -- Test string comparator
        local strCmp = parsers.getComparator("string")
        assert.is_not_nil(strCmp)
        assert.is_true(strCmp("a", "b"))
        assert.is_false(strCmp("b", "a"))
        assert.is_false(strCmp("a", "a"))

        -- Test case-insensitive string comparison
        assert.is_true(strCmp("A", "b"))
        assert.is_false(strCmp("B", "a"))
        assert.is_false(strCmp("A", "a"))
    end)
  end)

  describe("createDefaultValue", function()
    local log_messages
    local badVal

    before_each(function()
        log_messages = {}
        badVal = mockBadVal(log_messages)
    end)

    it("should create default values for basic types", function()
        -- Test basic types
        assert.equals(false, parsers.createDefaultValue("boolean"))
        assert.equals(0, parsers.createDefaultValue("number"))
        assert.equals(0, parsers.createDefaultValue("integer"))
        assert.equals("", parsers.createDefaultValue("string"))
        assert.equals("", parsers.createDefaultValue("text"))
        assert.equals("", parsers.createDefaultValue("name"))
        assert.equals("", parsers.createDefaultValue("identifier"))

        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("should create default values for collection types", function()
        -- All collection types should default to empty tables
        assert.same({}, parsers.createDefaultValue("{string}"))
        assert.same({}, parsers.createDefaultValue("{string:number}"))
        assert.same({}, parsers.createDefaultValue("{string,number}"))
        assert.same({}, parsers.createDefaultValue("{name:string,age:number}"))
        assert.same({}, parsers.createDefaultValue("table"))

        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("should create default values for custom types", function()
        -- Register an enum type
        assert(registerEnumParser(badVal, {"Red", "Green", "Blue"}, "Color"))
        assert(parsers.registerAlias(badVal, "positive", "number"))

        -- Test custom types
        assert.equals('', parsers.createDefaultValue("Color")) -- extends enum which extends string
        assert.equals(0, parsers.createDefaultValue("positive")) -- extends number

        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("should return nil for invalid types", function()
        -- Test invalid/unknown types
        assert.is_nil(parsers.createDefaultValue("invalid_type"))
        assert.is_nil(parsers.createDefaultValue(nil))
        assert.is_nil(parsers.createDefaultValue(123))
        assert.is_nil(parsers.createDefaultValue(""))
        assert.is_nil(parsers.createDefaultValue("{malformed:type"))

        -- No errors should be logged as returning nil is the expected behavior
        assert.same({}, log_messages)
    end)
  end)

  describe("generic table and ratio parsers", function()
    it("should validate generic tables", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local tableParser = parsers.parseType(badVal, "table")
      assert.is_not_nil(tableParser, "tableParser is nil")

      assert_equals_2({'a',1,c=3}, "'a',1,['c']=3", tableParser(badVal, "'a',1,['c']=3"))
      assert_equals_2(nil, "1='a'", tableParser(badVal, "1='a'"))
      assert.same({"Bad table  in test on line 1: '{1='a'}' (not a table)"}, log_messages)
    end)

    it("should validate ratio", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local ratioParser = parsers.parseType(badVal, "ratio")
      assert.is_not_nil(ratioParser, "ratioParser is nil")
      local a2,b2 = ratioParser(badVal, "a='33.0%',b='33%',c='34.000%'")
      assert_eq_flt_seq({a=0.33,b=0.33,c=0.34},a2)
      assert.same('a="33%",b="33%",c="34%"', b2)
      assert.same({}, log_messages)
      assert_equals_2(nil, "a='33%',b='33%'", ratioParser(badVal, "a='33%',b='33%'"))
      assert.same({"Bad ratio  in test on line 1: 'a='33%',b='33%'' (Does not add up to ~100%)"}, log_messages)
    end)
  end)

  describe("restrictNumber", function()
    local log_messages = {}
    local badVal

    before_each(function()
        log_messages = {}
        badVal = error_reporting.badValGen(function(_self, msg)
            table.insert(log_messages, msg)
        end)
    end)

    it("should handle basic number ranges", function()
        -- Simple range
        local parser, name = parsers.restrictNumber(badVal, "number", 0, 100)
        assert.is_not_nil(parser, serializeTable(log_messages))
        assert.equals("number._R_GE_I0_LE_I100", name)

        -- Test valid values
        assert.equals(0, parser(badVal, "0"))
        assert.equals(50, parser(badVal, "50"))
        assert.equals(100, parser(badVal, "100"))

        -- Test invalid values
        assert.is_nil(parser(badVal, "-1"))
        assert.is_nil(parser(badVal, "101"))
    end)

    it("should handle integer ranges", function()
        local parser, name = parsers.restrictNumber(badVal, "integer", 1, 10)
        assert.is_not_nil(parser)
        assert.equals("integer._R_GE_I1_LE_I10", name)

        -- Test valid values
        assert.equals(1, parser(badVal, "1"))
        assert.equals(5, parser(badVal, "5"))
        assert.equals(10, parser(badVal, "10"))

        -- Test invalid values
        assert.is_nil(parser(badVal, "0"))
        assert.is_nil(parser(badVal, "11"))
        assert.is_nil(parser(badVal, "5.5"))
    end)

    it("should handle single bounds", function()
        -- Only min bound
        local parser1, name1 = parsers.restrictNumber(badVal, "number", 0, nil)
        assert.is_not_nil(parser1)
        assert.equals("number._R_GE_I0", name1)

        -- Only max bound
        local parser2, name2 = parsers.restrictNumber(badVal, "number", nil, 100)
        assert.is_not_nil(parser2)
        assert.equals("number._R_LE_I100", name2)

        -- Test valid values
        assert.equals(1, parser1(badVal, "1"))
        assert.equals(99, parser2(badVal, "99"))

        -- Test invalid values
        assert.is_nil(parser1(badVal, "-10"))
        assert.is_nil(parser2(badVal, "150"))
    end)

    it("should reject invalid ranges", function()
        -- Both bounds nil
        local parser, name = parsers.restrictNumber(badVal, "number", nil, nil)
        assert.is_nil(parser)
        assert.matches("min and max cannot both be nil", log_messages[1])

        -- Min > Max
        parser, name = parsers.restrictNumber(badVal, "number", 100, 0)
        assert.is_nil(parser)
        assert.equals("Bad range  in  on line 0: '[100,0]' (min must be <= max)",
          log_messages[#log_messages])
    end)

    it("should handle aliases", function()
        -- Create parser with alias
        local parser1, name1 = parsers.restrictNumber(badVal, "number", 0, 100, "percentage")
        assert.is_not_nil(parser1)
        assert.equals("number._R_GE_I0_LE_I100", name1)

        -- Verify alias works
        local parser2 = parsers.parseType(badVal, "percentage")
        assert.equals(parser1, parser2)

        -- Try to create same range with different alias
        local parser3, name3 = parsers.restrictNumber(badVal, "number", 0, 100, "percent")
        assert.is_nil(parser3)
        assert.equals(name1, name3)  -- Should still return the original name
        assert.equals(
          "Bad type  in  on line 0: 'percent' (Parser with name 'percent' is already exists)",
          log_messages[#log_messages])
    end)

    it("should handle inheritance from restricted types", function()
        -- Create base restricted type
        local parser1, name1 = parsers.restrictNumber(badVal, "number", 0, 100)
        assert.is_not_nil(parser1)

        -- Create more restricted subtype
        local parser2, name2 = parsers.restrictNumber(badVal, name1, 25, 75)
        assert.is_not_nil(parser2)

        -- Test valid values
        assert.equals(25, parser2(badVal, "25"))
        assert.equals(50, parser2(badVal, "50"))
        assert.equals(75, parser2(badVal, "75"))

        -- Test invalid values (within parent range but outside subtype range)
        assert.is_nil(parser2(badVal, "0"))
        assert.is_nil(parser2(badVal, "100"))
    end)

    it("should reject invalid inheritance", function()
        -- Create base restricted type
        local parser1, name1 = parsers.restrictNumber(badVal, "number", 0, 100)
        assert.is_not_nil(parser1)

        -- Try to create subtype with invalid range
        local parser2, name2 = parsers.restrictNumber(badVal, name1, -50, 150)
        assert.is_nil(parser2)
        -- Should check about both bounds
        assert.same("Bad number  in  on line 0: '-50' (cannot be less than existing min 0)",
          log_messages[#log_messages])
    end)

    it("should handle floating point values for integer types", function()
        local parser, name = parsers.restrictNumber(badVal, "integer", 1.0, 10.0)
        assert.is_not_nil(parser)
        -- Should floor the values
        assert.equals("integer._R_GE_I1_LE_I10", name)

        -- Test boundaries
        assert.equals(1, parser(badVal, "1"))
        assert.equals(10, parser(badVal, "10"))
        assert.is_nil(parser(badVal, "0"))
        assert.is_nil(parser(badVal, "11"))
    end)
  end)

  describe("restrictString", function()
    local log_messages = {}
    local badVal

    before_each(function()
        log_messages = {}
        badVal = mockBadVal(log_messages)
    end)

    it("should handle basic string length ranges", function()
        -- Simple range
        local parser, name = parsers.restrictString(badVal, "string", 1, 10)
        assert.is_not_nil(parser, serializeTable(log_messages))
        assert.equals("string._RS_R_GE_I1_LE_I10", name)

        -- Test valid values
        assert.equals("a", parser(badVal, "a"))
        assert.equals("12345", parser(badVal, "12345"))
        assert.equals("abcdefghij", parser(badVal, "abcdefghij"))

        -- Test invalid values
        assert.is_nil(parser(badVal, ""))
        assert.is_nil(parser(badVal, "abcdefghijk"))
    end)

    it("should handle single bounds", function()
        -- Only min bound
        local parser1, name1 = parsers.restrictString(badVal, "string", 1, nil)
        assert.is_not_nil(parser1)
        assert.equals("string._RS_R_GE_I1", name1)

        -- Only max bound
        local parser2, name2 = parsers.restrictString(badVal, "string", nil, 10)
        assert.is_not_nil(parser2)
        assert.equals("string._RS_R_LE_I10", name2)

        -- Test valid values
        assert.equals("a", parser1(badVal, "a"))
        assert.equals("abcdefghij", parser2(badVal, "abcdefghij"))

        -- Test invalid values
        assert.is_nil(parser1(badVal, ""))
        assert.is_nil(parser2(badVal, "abcdefghijk"))
    end)

    it("should handle regex patterns", function()
        -- String matching email pattern
        local parser, name = parsers.restrictString(badVal, "string", nil, 100,
            "^[A-Za-z0-9%.%%%+%-]+@[A-Za-z0-9%.%-]+%.%w%w%w?$")
        assert.is_not_nil(parser)

        -- Test valid values
        assert.equals("user@example.com", parser(badVal, "user@example.com"))
        assert.equals("test+123@test.co", parser(badVal, "test+123@test.co"))

        -- Test invalid values
        assert.is_nil(parser(badVal, "not_an_email"))
        assert.is_nil(parser(badVal, "invalid@email"))
    end)

    it("should reject invalid ranges", function()
        -- Both bounds nil
        local parser, name = parsers.restrictString(badVal, "string", nil, nil)
        assert.is_nil(parser)
        assert.same("Bad range  in test on line 1: 'nil,nil.nil' (min, max and regex cannot be all nil)", log_messages[1])

        -- Min > Max
        parser, name = parsers.restrictString(badVal, "string", 10, 1)
        assert.is_nil(parser)
        assert.equals("Bad range  in test on line 1: '[10,1]' ((ORIGINAL)min must be <= max)",
          log_messages[#log_messages])
    end)

    it("should handle floating point values", function()
        local parser, name = parsers.restrictString(badVal, "string", 1.0, 10.0)
        assert.same({}, log_messages)
        assert.is_not_nil(parser)
        assert.equals("string._RS_R_GE_I1_LE_I10", name)

        -- Test boundaries
        assert.equals("a", parser(badVal, "a"))
        assert.equals("abcdefghij", parser(badVal, "abcdefghij"))
        assert.is_nil(parser(badVal, ""))
        assert.is_nil(parser(badVal, "abcdefghijk"))
    end)

    it("should reject non-integer bounds", function()
        local parser, name = parsers.restrictString(badVal, "string", 1.5, 10)
        assert.is_nil(parser)
        assert.matches("min must be an integer", log_messages[#log_messages])
    end)

    it("should reject negative bounds", function()
        local parser, name = parsers.restrictString(badVal, "string", -1, 10)
        assert.is_nil(parser)
        assert.matches("min cannot be negative", log_messages[#log_messages])
    end)

    it("should handle aliases", function()
        -- Create parser with alias
        local parser1, name1 = parsers.restrictString(badVal, "string", 1, 50, nil, "shortString")
        assert.is_not_nil(parser1)
        assert.equals("string._RS_R_GE_I1_LE_I50", name1)

        -- Verify alias works
        local parser2 = parsers.parseType(badVal, "shortString")
        assert.equals(parser1, parser2)

        -- Try to create same range with different alias
        local parser3, name3 = parsers.restrictString(badVal, "string", 1, 50, nil, "smallString")
        assert.is_not_nil(parser3)
        assert.equals(name1, name3)  -- Should still return the original name
        assert.equals(0, #log_messages)
    end)

    it("should handle inheritance", function()
        -- Create base restricted type
        local parser1, name1 = parsers.restrictString(badVal, "string", 1, 100)
        assert.is_not_nil(parser1)

        -- Create more restricted subtype
        local parser2, name2 = parsers.restrictString(badVal, name1, 10, 50)
        assert.is_not_nil(parser2)

        -- Test valid values
        assert.equals("abcdefghij", parser2(badVal, "abcdefghij"))  -- length 10
        assert.equals("abcdefghijklmnopqrst", parser2(badVal, "abcdefghijklmnopqrst"))  -- length 20
        assert.equals("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWX",
            parser2(badVal, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWX"))  -- length 50

        -- Test invalid values (within parent range but outside subtype range)
        assert.is_nil(parser2(badVal, "a"))  -- length 1
        assert.is_nil(parser2(badVal, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXY"))  -- length 51
    end)

    it("should handle regex inheritance", function()
        -- Create base type with regex
        local parser1, name1 = parsers.restrictString(badVal, "string", nil, 100, "^[a-z]+$")
        assert.is_not_nil(parser1)

        -- Create subtype with more restrictions
        local parser2, name2 = parsers.restrictString(badVal, name1, 3, 10, "^[aeiou]+$")
        assert.is_not_nil(parser2)

        -- Test valid values
        assert.equals("aei", parser2(badVal, "aei"))
        assert.equals("aeiouaeiou", parser2(badVal, "aeiouaeiou"))

        -- Test invalid values
        assert.is_nil(parser2(badVal, "ae"))  -- too short
        assert.is_nil(parser2(badVal, "aeiouaeioua"))  -- too long
        assert.is_nil(parser2(badVal, "abc"))  -- matches parent regex but not child
        assert.is_nil(parser2(badVal, "ABC"))  -- matches neither regex
    end)

    it("should reject invalid regex patterns", function()
        local parser, name = parsers.restrictString(badVal, "string", 1, 10, "[invalid")
        assert.is_nil(parser)
        assert.same("Bad regex  in test on line 1: '[invalid' (Invalid pattern: [invalid)", log_messages[#log_messages])
    end)
  end)

  describe("getSchemaColumnNames", function()
    it("should return column names in correct order", function()
      local names = parsers.getSchemaColumnNames()
      assert.is_table(names)
      assert.equals(9, #names)
      assert.same({
        "name", "definition", "kind", "parent", "is_builtin",
        "min", "max", "regex", "enum_labels"
      }, names)
    end)
  end)

  describe("getSchemaColumns", function()
    it("should return column definitions with required fields", function()
      local columns = parsers.getSchemaColumns()
      assert.is_table(columns)
      assert.equals(9, #columns)

      -- Each column should have name, type, and description
      for i, col in ipairs(columns) do
        assert.is_string(col.name, "column " .. i .. " missing name")
        assert.is_string(col.type, "column " .. i .. " missing type")
        assert.is_string(col.description, "column " .. i .. " missing description")
      end
    end)

    it("should define correct column types", function()
      local columns = parsers.getSchemaColumns()

      -- Build a lookup by name
      local byName = {}
      for _, col in ipairs(columns) do
        byName[col.name] = col
      end

      -- Check specific column types
      assert.equals("name", byName.name.type)
      assert.equals("type_spec", byName.definition.type)
      assert.equals("{enum:name|array|map|tuple|record|union|enum|table}", byName.kind.type)
      assert.equals("type_spec|nil", byName.parent.type)
      assert.equals("boolean", byName.is_builtin.type)
      assert.equals("number|nil", byName.min.type)
      assert.equals("number|nil", byName.max.type)
      assert.equals("string|nil", byName.regex.type)
      assert.equals("string|nil", byName.enum_labels.type)
    end)
  end)

  describe("getSchemaModel", function()
    it("should return a non-empty array of records", function()
      local model = parsers.getSchemaModel()
      assert.is_table(model)
      assert.is_true(#model > 0, "schema model should not be empty")
    end)

    it("should include all required fields in each record", function()
      local model = parsers.getSchemaModel()
      local expectedFields = {
        "name", "definition", "kind", "parent", "is_builtin",
        "min", "max", "regex", "enum_labels"
      }

      for i, record in ipairs(model) do
        for _, field in ipairs(expectedFields) do
          assert.is_not_nil(record[field],
            "record " .. i .. " (" .. (record.name or "?") .. ") missing field: " .. field)
        end
      end
    end)

    it("should include built-in types", function()
      local model = parsers.getSchemaModel()

      -- Build a lookup by name
      local byName = {}
      for _, record in ipairs(model) do
        byName[record.name] = record
      end

      -- Check some core built-in types exist
      assert.is_not_nil(byName.boolean, "missing boolean type")
      assert.is_not_nil(byName.number, "missing number type")
      assert.is_not_nil(byName.string, "missing string type")
      assert.is_not_nil(byName.integer, "missing integer type")
      assert.is_not_nil(byName.table, "missing table type")

      -- Check they're marked as built-in
      assert.equals("true", byName.boolean.is_builtin)
      assert.equals("true", byName.number.is_builtin)
      assert.equals("true", byName.string.is_builtin)
    end)

    it("should have correct kinds for built-in types", function()
      local model = parsers.getSchemaModel()

      local byName = {}
      for _, record in ipairs(model) do
        byName[record.name] = record
      end

      -- Check primitive types have kind "name"
      assert.equals("name", byName.boolean.kind)
      assert.equals("name", byName.number.kind)
      assert.equals("name", byName.string.kind)
      assert.equals("name", byName.integer.kind)

      -- Check table type has kind "table" (special case)
      assert.equals("table", byName.table.kind)
    end)

    it("should have correct kinds for complex types", function()
      local model = parsers.getSchemaModel()

      local byName = {}
      for _, record in ipairs(model) do
        byName[record.name] = record
      end

      -- The 'raw' union type (stored by its definition, not alias name)
      local rawDef = "boolean|number|table|string|nil"
      assert.is_not_nil(byName[rawDef], "missing raw union type")
      assert.equals("union", byName[rawDef].kind)

      -- {name:percent} is a map
      assert.is_not_nil(byName["{name:percent}"])
      assert.equals("map", byName["{name:percent}"].kind)

      -- {type,raw} is a tuple
      assert.is_not_nil(byName["{type,raw}"])
      assert.equals("tuple", byName["{type,raw}"].kind)
    end)

    it("should include parent information for derived types", function()
      local model = parsers.getSchemaModel()

      local byName = {}
      for _, record in ipairs(model) do
        byName[record.name] = record
      end

      -- integer extends number
      assert.is_not_nil(byName.integer)
      assert.equals("number", byName.integer.parent)

      -- identifier extends name
      assert.is_not_nil(byName.identifier)
      assert.equals("name", byName.identifier.parent)

      -- text extends string
      assert.is_not_nil(byName.text)
      assert.equals("string", byName.text.parent)
    end)

    it("should include numeric constraints for restricted number types", function()
      local model = parsers.getSchemaModel()

      local byName = {}
      for _, record in ipairs(model) do
        byName[record.name] = record
      end

      -- ubyte should have max=255 (min=0 is omitted as default)
      local ubyteSpec = "integer._R_GE_I0_LE_I255"
      assert.is_not_nil(byName[ubyteSpec], "missing ubyte type spec")
      assert.equals("", byName[ubyteSpec].min)  -- 0 is omitted
      assert.equals("255", byName[ubyteSpec].max)

      -- byte should have min=-128, max=127
      local byteSpec = "integer._R_GE_I_128_LE_I127"
      assert.is_not_nil(byName[byteSpec], "missing byte type spec")
      assert.equals("-128", byName[byteSpec].min)
      assert.equals("127", byName[byteSpec].max)
    end)

    it("should handle user-registered enum types", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- Register a custom enum
      local parser, _ = registerEnumParser(badVal, {"One", "Two", "Three"}, "SchemaTestEnum")
      assert.is_not_nil(parser, serializeTable(log_messages))

      -- Get the model and check for our new type
      local model = parsers.getSchemaModel()
      local byName = {}
      for _, record in ipairs(model) do
        byName[record.name] = record
      end

      -- The enum type spec is stored, not the alias name
      -- Find the enum by looking for its definition pattern
      local enumDef = "{enum:one|three|two}"
      assert.is_not_nil(byName[enumDef], "missing enum type definition")
      assert.equals("false", byName[enumDef].is_builtin)
      assert.equals("enum", byName[enumDef].kind)

      -- Check enum labels are sorted and pipe-separated
      assert.is_not_nil(byName[enumDef].enum_labels)
      assert.equals("one|three|two", byName[enumDef].enum_labels)
    end)

    it("should have all string values in records", function()
      local model = parsers.getSchemaModel()

      -- All field values should be strings (for TSV compatibility)
      for i, record in ipairs(model) do
        for field, value in pairs(record) do
          assert.equals("string", type(value),
            "record " .. i .. " (" .. record.name .. ") field " .. field ..
            " should be string, got " .. type(value))
        end
      end
    end)
  end)
end)
