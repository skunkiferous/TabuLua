-- parsers_array_spec.lua
-- Tests for array type parsers

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

describe("parsers - array types", function()

  describe("array type parsers", function()
    it("should validate arrays", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local arrayParser = parsers.parseType(badVal, "{number}")
      assert.is.not_nil(arrayParser, "arrayParser is nil")

      assert_equals_2({1,2,3}, "1,2,3", arrayParser(badVal, "1,2,3"))
      assert_equals_2(nil, "1,2,'a'", arrayParser(badVal, "1,2,'a'"))
      assert.same({"Bad number  in test on line 1: 'a' (context was 'parsed', was expecting a number)"}, log_messages)
    end)

    it("should validate recursive arrays", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local arrayParser = parsers.parseType(badVal, "{{identifier:number}}")
      assert.is.not_nil(arrayParser, "arrayParser is nil")
      assert_equals_2({{a=1},{b=2}}, "{a=1},{b=2}", arrayParser(badVal, "{a=1},{b=2}"))

      assert.same({}, log_messages)
    end)

    it("should validate nested arrays", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local nestedParser = parsers.parseType(badVal, "{{number}}")
      assert.is.not_nil(nestedParser, "nestedParser is nil")
      assert_equals_2({{1,2},{3,4}}, "{1,2},{3,4}", nestedParser(badVal, "{1,2},{3,4}"))

      assert.same({}, log_messages)
    end)

    it("should handle empty arrays", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local arrayParser = parsers.parseType(badVal, "{number}")
      assert.is.not_nil(arrayParser, "arrayParser is nil")
      assert_equals_2({}, "", arrayParser(badVal, ""))

      assert.same({}, log_messages)
    end)
  end)

  describe("arrayElementType", function()
    local log_messages = {}
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should extract element type from valid array types", function()
      -- Test basic array types
      assert.equals("string", parsers.arrayElementType("{string}"))
      assert.equals("number", parsers.arrayElementType("{number}"))
      assert.equals("boolean", parsers.arrayElementType("{boolean}"))

      -- Test nested array types
      assert.equals("{string}", parsers.arrayElementType("{{string}}"))
      assert.equals("{number}", parsers.arrayElementType("{{number}}"))

      -- Test complex element types
      assert.equals("number|string", parsers.arrayElementType("{number|string}"))
      assert.equals("{string:number}", parsers.arrayElementType("{{string:number}}"))
      assert.equals("{age:number,name:string}",
        parsers.arrayElementType("{{name:string,age:number}}"))
    end)

    it("should handle array type aliases", function()
      -- Register some array type aliases
      assert(parsers.registerAlias(badVal, "StringArray", "{string}"))
      assert(parsers.registerAlias(badVal, "NumberArray", "{number}"))
      assert(parsers.registerAlias(badVal, "ArrayOfArrays", "{{string}}"))

      -- Test alias resolution
      assert.equals("string", parsers.arrayElementType("StringArray"))
      assert.equals("number", parsers.arrayElementType("NumberArray"))
      assert.equals("{string}", parsers.arrayElementType("ArrayOfArrays"))

      assert.same({}, log_messages)
    end)

    it("should return nil for non-array types", function()
      -- Test nil input
      assert.is_nil(parsers.arrayElementType(nil))

      -- Test non-string input
      assert.is_nil(parsers.arrayElementType(123))
      assert.is_nil(parsers.arrayElementType({}))
      assert.is_nil(parsers.arrayElementType(true))

      -- Test invalid type specs
      assert.is_nil(parsers.arrayElementType("not_an_array"))
      assert.is_nil(parsers.arrayElementType("{string")) -- Malformed array

      -- Test valid type specs that aren't arrays
      assert.is_nil(parsers.arrayElementType("string"))
      assert.is_nil(parsers.arrayElementType("{string:number}")) -- Map type
      assert.is_nil(parsers.arrayElementType("{string,number}")) -- Tuple type
      assert.is_nil(parsers.arrayElementType("{name:string}")) -- Record type
      assert.is_nil(parsers.arrayElementType("number|string")) -- Union type
    end)

    it("should handle custom element types", function()
      -- Register an enum type
      assert(registerEnumParser(badVal, {"Red", "Green", "Blue"}, "Color"))

      -- Test array with custom enum element type
      assert.equals("Color", parsers.arrayElementType("{Color}"))

      -- Register a complex custom type
      assert(parsers.registerAlias(badVal, "Point", "{x:number,y:number}"))
      assert.equals("Point", parsers.arrayElementType("{Point}"))

      assert.same({}, log_messages)
    end)
  end)

  describe("getComparator for arrays", function()
    it("should return valid comparators for arrays", function()
        local arrayCmp = parsers.getComparator("{number}")
        assert.is_not_nil(arrayCmp)

        -- Compare arrays of different lengths
        assert.is_true(arrayCmp({1, 2}, {1, 2, 3}))
        assert.is_false(arrayCmp({1, 2, 3}, {1, 2}))

        -- Compare arrays element by element
        assert.is_true(arrayCmp({1, 2}, {1, 3}))
        assert.is_false(arrayCmp({1, 3}, {1, 2}))
        assert.is_false(arrayCmp({1, 2}, {1, 2}))

        -- Empty arrays
        assert.is_false(arrayCmp({}, {}))
    end)
  end)

  describe("isNeverTable for arrays", function()
    it("should NOT match array types", function()
      assert(not parsers.isNeverTable("{number}"))
      assert(not parsers.isNeverTable("{{identifier:number}}"))
      assert(not parsers.isNeverTable("{string}"))
    end)
  end)
end)
