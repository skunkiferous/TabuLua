-- parsers_union_spec.lua
-- Tests for union type parsers

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

local semver = require("semver")

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

describe("parsers - union types", function()

  describe("union type parsers", function()
    it("should validate unions", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local unionParser = parsers.parseType(badVal, "number|boolean|string")
      assert.is.not_nil(unionParser, "unionParser is nil")
      assert_equals_2(1, '1', unionParser(badVal, "1"))
      assert_equals_2(true, 'true', unionParser(badVal, "yes"))
      assert_equals_2('hello', 'hello', unionParser(badVal, 'hello'))
      unionParser = parsers.parseType(badVal, "number|boolean")
      assert_equals_2(nil, 'bye', unionParser(badVal, 'bye'))
      assert.same({"Bad number|boolean  in test on line 1: 'bye'"}, log_messages)
    end)

    it("should support {} in unions", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local unionParser = parsers.parseType(badVal, "{}|string")

      assert.is_not_nil(unionParser, "unionParser is nil")

      -- Test with table value
      assert_equals_2({a=1}, "a=1", unionParser(badVal, "a=1"))

      -- Test with string value
      assert_equals_2("hello", "hello", unionParser(badVal, "hello"))

      assert.same({}, log_messages)
    end)
  end)

  describe("optional types", function()
    local log_messages
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should be supported directly", function()
      local optParser = parsers.parseType(badVal, "number|nil")
      assert.is_not_nil(optParser, "optParser is not nil")
      assert_equals_2(42, "42", optParser(badVal, "42"))
      assert_equals_2(nil, "", optParser(badVal, ""))
      assert.same({}, log_messages)
    end)

    it("should be supported with strings", function()
      local optParser = parsers.parseType(badVal, "string|nil")
      assert.is_not_nil(optParser, "optParser is not nil")
      assert_equals_2("abc", "abc", optParser(badVal, "abc"))
      -- Basically, in THIS case (string|nil) we interpret '' as nil (nil wins over "empty-string")
      assert_equals_2(nil, "", optParser(badVal, ""))
      assert.same({}, log_messages)
    end)

    it("should be supported inside arrays", function()
      local optParser = parsers.parseType(badVal, "{number|nil}")
      assert.is_not_nil(optParser, "optParser is not nil")
      assert_equals_2({42,24}, "42,24", optParser(badVal, "42,24"))
      assert_equals_2({}, "", optParser(badVal, ""))
      assert_equals_2({123,nil}, '123,""', optParser(badVal, "123,''"))
      assert_equals_2({123,nil}, '123,""', optParser(badVal, '123,""'))
      assert.same({}, log_messages)
    end)

    it("should be supported outside arrays", function()
      local optParser = parsers.parseType(badVal, "{name}|nil")
      assert.is_not_nil(optParser, "optParser is not nil")
      assert_equals_2({'A'}, '"A"', optParser(badVal, "'A'"))
      assert.same({}, log_messages)
    end)

    it("should not be supported as map keys", function()
      local noParser = parsers.parseType(badVal, "{number|nil:boolean}")
      assert.is_nil(noParser, "noParser is not nil")
      assert.same({"Bad type  in test on line 1: 'number|nil' (map key_type can never be nil)"},
        log_messages)
    end)

    it("should not be supported as map values", function()
      local noParser = parsers.parseType(badVal, "{boolean:number|nil}")
      assert.is_nil(noParser, "noParser is not nil")
      assert.same({"Bad type  in test on line 1: 'number|nil' (map value_type can never be nil)"},
        log_messages)
    end)
  end)

  describe("unionTypes", function()
    it("should extract types from valid union types", function()
        -- Test basic union type
        local types = parsers.unionTypes("number|boolean|string")
        assert.is_not_nil(types)
        assert.same({"number", "boolean", "string"}, types)

        -- Test union with complex types
        types = parsers.unionTypes("{string}|{number:boolean}|nil")
        assert.is_not_nil(types)
        assert.same({"{string}", "{number:boolean}", "nil"}, types)
    end)

    it("should return nil for invalid inputs", function()
        -- Test nil input
        assert.is_nil(parsers.unionTypes(nil))

        -- Test non-string input
        assert.is_nil(parsers.unionTypes(123))
        assert.is_nil(parsers.unionTypes({}))
        assert.is_nil(parsers.unionTypes(true))

        -- Test invalid type specifications
        assert.is_nil(parsers.unionTypes("not_a_union"))
        assert.is_nil(parsers.unionTypes("|string|"))
        assert.is_nil(parsers.unionTypes("number||string"))

        -- Test valid type specs that aren't unions
        assert.is_nil(parsers.unionTypes("string"))
        assert.is_nil(parsers.unionTypes("{string}"))
        assert.is_nil(parsers.unionTypes("{string:number}"))
    end)

    it("should work with registered types and aliases", function()
        -- First register some types
        local log_messages = {}
        local badVal = mockBadVal(log_messages)

        assert(registerEnumParser(badVal, {"A", "B", "C"}, "Letters"))
        assert(parsers.registerAlias(badVal, "OptionalNumber", "number|nil"))
        assert(parsers.registerAlias(badVal, "NumberOrString", "number|string"))

        -- Test union with custom enum
        local types = parsers.unionTypes("Letters|nil")
        assert.is_not_nil(types)
        assert.same({"Letters", "nil"}, types)

        -- Test union through alias
        types = parsers.unionTypes("OptionalNumber")
        assert.is_not_nil(types)
        assert.same({"number", "nil"}, types)

        -- Test union with multiple aliases
        types = parsers.unionTypes("OptionalNumber|NumberOrString")
        assert.is_not_nil(types)
        assert.same({"OptionalNumber", "NumberOrString"}, types)

        assert.same({}, log_messages)
    end)
  end)

  describe("restrictUnion", function()
    local log_messages = {}
    local badVal

    before_each(function()
        log_messages = {}
        badVal = mockBadVal(log_messages)
    end)

    it("should handle basic union restrictions", function()
        -- Create base union type
        local baseParser = parsers.parseType(badVal, "number|boolean|version")
        assert.is_not_nil(baseParser)

        -- Create restricted union with fewer types
        local parser, name = parsers.restrictUnion(badVal, "number|boolean|version",
            {"number","version"}, "numOrVer")
        assert.is_not_nil(parser)
        assert.equals("number|version", name)

        -- Test valid values
        assert_equals_2({major=1,minor=2,patch=3}, "1.2.3", parser(badVal, "1.2.3"))
        assert_equals_2(42, "42", parser(badVal, "42"))

        -- Test invalid values (value from parent union but not in restriction)
        assert_equals_2(nil, "true", parser(badVal, "true"))
        assert.same({
            'Bad number|version  in test on line 1: \'true\''
        }, log_messages)
    end)

    it("should preserve order of types", function()
        -- Create a restricted union, specifying types in different order than original
        local parser, name = parsers.restrictUnion(badVal, "number|boolean|version",
            {"boolean", "number"}, "numOrBool")
        assert.is_not_nil(parser)
        -- Should use order from original union
        assert.equals("number|boolean", name)

        -- The first matching type should win
        assert_equals_2(42, "42", parser(badVal, "42"))  -- matches number first
        assert_equals_2(true, "true", parser(badVal, "true"))  -- only matches boolean
    end)

    it("should preserve nil handling", function()
        -- Create base union with nil
        local baseParser = parsers.parseType(badVal, "number|version|nil")
        assert.is_not_nil(baseParser)

        -- Create restricted union including nil
        local parser1, name1 = parsers.restrictUnion(badVal, "number|version|nil",
            {"version", "nil"}, "optVersion")
        assert.is_not_nil(parser1)
        assert.equals("version|nil", name1)

        -- Test nil value
        assert_equals_2(nil, "", parser1(badVal, ""))

        -- Test restricted union with nil removed
        local parser2, name2 = parsers.restrictUnion(badVal, "number|version|nil",
            {"version", "number"}, "numOrVer")
        assert.is_not_nil(parser2)
        assert.equals("number|version", name2)

        -- Test that nil is no longer accepted
        assert_equals_2(nil, "", parser2(badVal, ""))
        assert.same({
            "Bad number|version  in test on line 1: ''"
        }, log_messages)
    end)

    it("should reject invalid union types", function()
        -- Try to restrict a non-union type
        local parser1 = parsers.restrictUnion(badVal, "string", {"string"})
        assert.is_nil(parser1)

        -- Try to restrict with types not in original union
        local parser2 = parsers.restrictUnion(badVal, "number|string", {"string", "boolean"})
        assert.is_nil(parser2)

        assert.same({
            'Bad type  in test on line 1: \'string\' (unionType must be a union type)',
            'Bad type  in test on line 1: \'boolean\' (type is not part of union number|string)'
        }, log_messages)
    end)

    it("should handle aliases", function()
        -- Create restricted union with alias
        local parser1, name1 = parsers.restrictUnion(badVal, "number|boolean|string",
            {"string", "number"}, "numStrType")
        assert.is_not_nil(parser1)
        assert.equals("number|string", name1)

        -- Verify alias works
        local parser2 = parsers.parseType(badVal, "numStrType")
        assert.equals(parser1, parser2)

        -- Try to create same restriction with different alias
        local parser3, name3 = parsers.restrictUnion(badVal, "number|boolean|string",
            {"string", "number"}, "anotherNumStr")
        assert.is_not_nil(parser3)
        assert.equals(name1, name3)  -- Should still return the original name
        assert.same({}, log_messages)
    end)

    it("should handle inheritance between restricted unions", function()
        -- Create first restriction
        local parser1, name1 = parsers.restrictUnion(badVal, "number|boolean|version",
            {"version", "number"}, "numOrVer")
        assert.is_not_nil(parser1)

        -- Create further restriction
        local parser2, name2 = parsers.restrictUnion(badVal, "numOrVer",
            {"version"}, "verOnly")
        assert.is_not_nil(parser2)

        -- Test valid values
        assert_equals_2({major=1,minor=2,patch=3}, "1.2.3", parser2(badVal, "1.2.3"))

        -- Test invalid values (valid in parent but not in child)
        assert_equals_2(nil, "42", parser2(badVal, "42"))
        assert_equals_2(nil, "true", parser2(badVal, "true"))

        assert.same({
            'Bad version  in test on line 1: \'42\' (expected format: X.Y.Z (e.g., 1.0.0))',
            'Bad version  in test on line 1: \'true\' (expected format: X.Y.Z (e.g., 1.0.0))'
        }, log_messages)
    end)

    it("should reject empty or invalid type lists", function()
        -- Try with non-table type list
        local parser1 = parsers.restrictUnion(badVal, "number|string", "string")
        assert.is_nil(parser1)

        -- Try with empty type list
        local parser2 = parsers.restrictUnion(badVal, "number|string", {})
        assert.is_nil(parser2)

        -- Try with invalid type names
        local parser3 = parsers.restrictUnion(badVal, "number|string", {"invalid_type"})
        assert.is_nil(parser3)

        assert.same({
            'Bad table  in test on line 1: \'string\' (allowedTypes must be a table)',
            'Bad table  in test on line 1: \'{}\' (no valid types)',
            'Bad type  in test on line 1: \'invalid_type\' (type is not part of union number|string)'
        }, log_messages)
    end)
  end)

  describe("extendsOrRestrict for unions", function()
    local log_messages = {}
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should handle union subset extension", function()
      -- Create simple unions with basic types
      local parser1 = parsers.parseType(badVal, "number|boolean|string")
      assert.is_not_nil(parser1)
      local parser2 = parsers.parseType(badVal, "number|boolean")
      assert.is_not_nil(parser2)

      -- Test subset extension
      assert.is_true(parsers.extendsOrRestrict("number|boolean", "number|boolean|string"))
      assert.is_false(parsers.extendsOrRestrict("number|boolean|string", "number|boolean"))

      -- Test extension by single type
      assert.is_true(parsers.extendsOrRestrict("number", "number|boolean|string"))
      assert.is_true(parsers.extendsOrRestrict("boolean", "number|boolean|string"))
      -- version is a string, so technically it's a "sub-set" of the union
      assert.is_true(parsers.extendsOrRestrict("version", "number|boolean|string"))
      assert.is_false(parsers.extendsOrRestrict("table", "number|boolean|string"))

      -- Test with custom types
      assert(registerEnumParser(badVal, {"Red", "Green", "Blue"}, "Color"))
      assert(parsers.registerAlias(badVal, "ColorOrNumber", "Color|number"))
      assert.is_true(parsers.extendsOrRestrict("Color", "Color|number"))
      assert.is_true(parsers.extendsOrRestrict("number", "Color|number"))
      assert.is_false(parsers.extendsOrRestrict("string", "Color|number"))

      -- Complex union extension
      assert.is_true(parsers.extendsOrRestrict("{string}|number", "{string}|number|boolean"))
      assert.is_false(parsers.extendsOrRestrict("{string}|version", "{string}|number|boolean"))

      assert.same({}, log_messages)
    end)
  end)

  describe("extendsOrRestrict for union common ancestor", function()
    local log_messages = {}
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should recognize union of number subtypes as extending number", function()
      -- integer and float both extend number
      assert.is_true(parsers.extendsOrRestrict("integer|float", "number"))

      -- ubyte and ushort both extend integer
      assert.is_true(parsers.extendsOrRestrict("ubyte|ushort", "integer"))

      -- ubyte extends integer->number, float extends number
      assert.is_true(parsers.extendsOrRestrict("ubyte|float", "number"))

      assert.same({}, log_messages)
    end)

    it("should recognize union of string subtypes as extending string", function()
      -- text and markdown both extend string (markdown extends text extends string)
      assert.is_true(parsers.extendsOrRestrict("text|markdown", "string"))

      assert.same({}, log_messages)
    end)

    it("should reject when not all members extend the parent", function()
      -- float does not extend integer
      assert.is_false(parsers.extendsOrRestrict("ubyte|float", "integer"))

      -- string does not extend number
      assert.is_false(parsers.extendsOrRestrict("integer|string", "number"))

      assert.same({}, log_messages)
    end)

    it("should reject unions containing nil", function()
      -- nil does not extend number
      assert.is_false(parsers.extendsOrRestrict("integer|float|nil", "number"))

      -- nil does not extend string
      assert.is_false(parsers.extendsOrRestrict("text|markdown|nil", "string"))

      assert.same({}, log_messages)
    end)

    it("should work with custom types extending a common ancestor", function()
      -- Register custom types extending integer and float
      parsers.restrictWithValidator(badVal, "integer", "IntUnit",
        function(n) return n >= 0 end)
      parsers.restrictWithValidator(badVal, "float", "FloatUnit",
        function(n) return n >= 0 end)

      -- Both extend number through their respective parents
      assert.is_true(parsers.extendsOrRestrict("IntUnit|FloatUnit", "number"))

      -- FloatUnit does not extend integer
      assert.is_false(parsers.extendsOrRestrict("IntUnit|FloatUnit", "integer"))

      assert.same({}, log_messages)
    end)

    it("should preserve existing union-extends-union behavior", function()
      -- integer|float still extends union (structural kind)
      assert.is_true(parsers.extendsOrRestrict("integer|float", "union"))

      -- subset relationship still works
      assert.is_true(parsers.extendsOrRestrict("integer|float", "integer|float|string"))

      assert.same({}, log_messages)
    end)
  end)

  describe("getComparator for optional types", function()
    it("should return comparators for optional types", function()
        local optNumCmp = parsers.getComparator("number|nil")
        assert.is_not_nil(optNumCmp)

        -- nil comes before any value
        assert.is_true(optNumCmp(nil, 1))
        assert.is_false(optNumCmp(1, nil))

        -- When both values are non-nil, compare normally
        assert.is_true(optNumCmp(1, 2))
        assert.is_false(optNumCmp(2, 1))

        -- Equal values
        assert.is_false(optNumCmp(nil, nil))
        assert.is_false(optNumCmp(1, 1))
    end)

    it("should return nil for invalid type specifications", function()
        assert.is_nil(parsers.getComparator("invalid_type"))
        assert.is_nil(parsers.getComparator("{string")) -- Malformed array
        assert.is_nil(parsers.getComparator("{string:}")) -- Malformed map
        assert.is_nil(parsers.getComparator("number|")) -- Malformed union
    end)
  end)

  describe("createDefaultValue for unions", function()
    it("should handle union types appropriately", function()
        -- Union types should default based on their first type
        assert.equals(0, parsers.createDefaultValue("number|nil"))
        -- Special case; "string" in a union must always be evaluated *last*, so this union
        -- is INVALID
        assert.equals(nil, parsers.createDefaultValue("string|number"))
        assert.equals(false, parsers.createDefaultValue("boolean|number|string"))
    end)
  end)
end)
