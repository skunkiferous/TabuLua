-- parsers_tuple_spec.lua
-- Tests for tuple type parsers

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each

local table_utils = require("table_utils")
local clearSeq = table_utils.clearSeq
local parsers = require("parsers")
local registerEnumParser = parsers.registerEnumParser
local error_reporting = require("error_reporting")
local read_only = require("read_only")
local unwrap = read_only.unwrap

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

  -- Unwrap read-only tables for comparison
  a2 = unwrap(a2)

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

describe("parsers - tuple types", function()

  describe("tuple type parsers", function()
    it("should validate tuples", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local tupleParser = parsers.parseType(badVal, "{number,boolean,string}")
      assert.is.not_nil(tupleParser, "tupleParser is nil")
      assert_equals_2({1,true,"way"}, '1,true,"way"', tupleParser(badVal, "1,'yes','way'"))
      assert_equals_2(nil, '42,"nope","a"', tupleParser(badVal, '42,"nope","a"'))
      assert.same({"Bad boolean  in test on line 1: 'nope'"}, log_messages)
    end)

    it("should validate tuples with optional fields", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local optParser = parsers.parseType(badVal, "{number|nil,boolean|nil,{number}|nil}")
      assert.is_not_nil(optParser, "optParser is not nil")
      assert_equals_2({42,true,{5}}, '42,true,{5}', optParser(badVal, '42,true,{5}'))
      assert_equals_2({nil,true,{5}}, '"",true,{5}', optParser(badVal, '"",true,{5}'))
      assert_equals_2({42,nil,{5}}, '42,"",{5}', optParser(badVal, '42,"",{5}'))
      assert_equals_2({42,true,nil}, '42,true,""', optParser(badVal, '42,true,""'))
      assert.same({}, log_messages)
    end)
  end)

  describe("tupleFieldTypes", function()
    it("should break tuples into field type specs", function()
      assert.same({"string","{string:string}","{number}|nil"},
        parsers.tupleFieldTypes(
        "{string,{string:string},{number}|nil}"))
    end)

    it("should return nil for non-tuple types", function()
      assert.is_nil(parsers.tupleFieldTypes("{name:number}"))
    end)
  end)

  describe("getComparator for tuples", function()
    it("should return valid comparators for tuples", function()
        local tupleCmp = parsers.getComparator("{string,number}")
        assert.is_not_nil(tupleCmp)

        -- Compare tuples element by element
        assert.is_true(tupleCmp({"a", 1}, {"b", 1}))
        assert.is_true(tupleCmp({"a", 1}, {"a", 2}))
        assert.is_false(tupleCmp({"b", 1}, {"a", 1}))
        assert.is_false(tupleCmp({"a", 2}, {"a", 1}))
        assert.is_false(tupleCmp({"a", 1}, {"a", 1}))
    end)
  end)

  describe("tuple inheritance", function()
    local log_messages
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should parse basic tuple inheritance syntax", function()
      -- First register a base tuple type
      assert(parsers.registerAlias(badVal, "Point2DT", "{number,number}"))

      -- Test extending with single type
      local parser = parsers.parseType(badVal, "{extends,Point2DT,number}")
      assert.is_not_nil(parser, "Extended tuple parser should not be nil")

      -- Test the parser works correctly
      assert_equals_2({1, 2, 3}, "1,2,3", parser(badVal, "1,2,3"))
      assert.same({}, log_messages)
    end)

    it("should parse tuple inheritance with multiple additional types", function()
      -- Register base types
      assert(parsers.registerAlias(badVal, "Point2DT", "{number,number}"))
      assert(parsers.registerAlias(badVal, "Vector2D", "{number,number}"))

      -- Test extending with multiple types
      local parser = parsers.parseType(badVal, "{extends,Point2DT,number,boolean}")
      assert.is_not_nil(parser)

      assert_equals_2({1.5, 2.5, 10.0, true}, "1.5,2.5,10,true",
        parser(badVal, "1.5,2.5,10,true"))
      assert.same({}, log_messages)
    end)

    it("should handle nested tuple inheritance", function()
      -- Create a chain of inheritance
      assert(parsers.registerAlias(badVal, "Point2DT", "{number,number}"))
      assert(parsers.registerAlias(badVal, "Point3DT", "{extends,Point2DT,number}"))

      local parser = parsers.parseType(badVal, "{extends,Point3DT,string}")
      assert.is_not_nil(parser)

      assert_equals_2({1, 2, 3, "test"}, '1,2,3,"test"',
        parser(badVal, '1,2,3,"test"'))
      assert.same({}, log_messages)
    end)

    it("should validate parent tuple type exists", function()
      local parser = parsers.parseType(badVal, "{extends,NonExistentTuple,number}")
      assert.is_nil(parser)

      assert.same({
        "Bad extends  in test on line 1: '{extends,NonExistentTuple,number}' (extends in tuple requires a tuple parent)"
      }, log_messages)
    end)

    it("should validate parent is actually a tuple type", function()
      -- Test with non-tuple parent
      local parser = parsers.parseType(badVal, "{extends,string,number}")
      assert.is_nil(parser)

      assert.same({
        "Bad extends  in test on line 1: '{extends,string,number}' (extends in tuple requires a tuple parent)"
      }, log_messages)
    end)

    it("bare extends should create ancestor constraint parser", function()
      assert(parsers.registerAlias(badVal, "Point2DT", "{number,number}"))

      local parser = parsers.parseType(badVal, "{extends,Point2DT}")
      assert.is_not_nil(parser)
      -- Bare extends: values must be type names extending Point2DT
      -- Point2DT itself should be accepted
      local parsed, _ = parser(badVal, "Point2DT")
      assert.are.equal("Point2DT", parsed)
    end)

    it("should validate additional types are valid", function()
      assert(parsers.registerAlias(badVal, "Point2DT", "{number,number}"))

      local parser = parsers.parseType(badVal, "{extends,Point2DT,invalid_type}")
      assert.is_nil(parser)

      assert.same({
        "Bad type  in test on line 1: 'invalid_type' (unknown/bad type)"
      }, log_messages)
    end)

    it("should maintain proper inheritance relationship", function()
      assert(parsers.registerAlias(badVal, "Point2DT", "{number,number}"))
      assert(parsers.registerAlias(badVal, "Point3DT", "{extends,Point2DT,number}"))

      -- Point3DT should extend Point2DT
      assert.is_true(parsers.extendsOrRestrict("Point3DT", "Point2DT"))
      assert.is_true(parsers.extendsOrRestrict("Point3DT", "tuple"))

      assert.same({}, log_messages)
    end)

    it("should work with complex parent tuple types", function()
      -- Register a complex tuple type
      assert(registerEnumParser(badVal, {"Red", "Green", "Blue"}, "Color"))
      assert(parsers.registerAlias(badVal, "ColoredPoint", "{number,number,Color}"))

      local parser = parsers.parseType(badVal, "{extends,ColoredPoint,boolean}")
      assert.is_not_nil(parser)

      assert_equals_2({1, 2, "Red", true}, '1,2,"Red",true',
        parser(badVal, '1,2,"Red",true'))
      assert.same({}, log_messages)
    end)

    it("should handle multiple levels of tuple inheritance", function()
      assert(parsers.registerAlias(badVal, "Point2DT", "{number,number}"))
      assert(parsers.registerAlias(badVal, "Point3DT", "{extends,Point2DT,number}"))
      assert(parsers.registerAlias(badVal, "Point4D", "{extends,Point3DT,number}"))

      local parser = parsers.parseType(badVal, "Point4D")
      assert.is_not_nil(parser)

      assert_equals_2({1, 2, 3, 4}, "1,2,3,4", parser(badVal, "1,2,3,4"))

      -- Verify inheritance chain
      assert.is_true(parsers.extendsOrRestrict("Point4D", "Point3DT"))
      assert.is_true(parsers.extendsOrRestrict("Point4D", "Point2DT"))
      assert.is_true(parsers.extendsOrRestrict("Point4D", "tuple"))

      assert.same({}, log_messages)
    end)

    it("should not allow inheritance with array", function()
      assert(parsers.registerAlias(badVal, "MyNums", "{number}"))

      local parser = parsers.parseType(badVal, "{extends,MyNums,{string:string}}")
      assert.is_nil(parser)

      assert.same({
        "Bad extends  in test on line 1: '{extends,MyNums,{string:string}}' (extends in tuple requires a tuple parent)"
      }, log_messages)
    end)

    it("should work with tupleFieldTypes for inherited tuples", function()
      assert(parsers.registerAlias(badVal, "Point2DT", "{number,number}"))
      assert(parsers.registerAlias(badVal, "Point3DT", "{extends,Point2DT,number}"))

      local fieldTypes = parsers.tupleFieldTypes("Point3DT")
      assert.is_not_nil(fieldTypes)
      assert.same({"number", "number", "number"}, fieldTypes)

      assert.same({}, log_messages)
    end)

    it("should roundtrip tuple inheritance specifications", function()
      assert(parsers.registerAlias(badVal, "Point2DT", "{number,number}"))

      local input = "{extends,Point2DT,number}"
      local parsed = parsers.internal.type_parser(input)
      local result = parsers.internal.parsedTypeSpecToStr(parsed)

      -- The result should be equivalent (though may be in expanded form)
      local parser1 = parsers.parseType(badVal, input)
      local parser2 = parsers.parseType(badVal, result)
      assert.is_not_nil(parser1)
      assert.is_not_nil(parser2)

      -- Both parsers should behave identically
      assert_equals_2({1, 2, 3}, "1,2,3", parser1(badVal, "1,2,3"))
      assert_equals_2({1, 2, 3}, "1,2,3", parser2(badVal, "1,2,3"))

      assert.same({}, log_messages)
    end)

    it("should handle tuple inheritance with extendsOrRestrict", function()
      assert(parsers.registerAlias(badVal, "Point2DT", "{number,number}"))
      assert(parsers.registerAlias(badVal, "Point3DT", "{extends,Point2DT,number}"))

      assert.is_true(parsers.extendsOrRestrict("{string,integer,string}",
        "{string,number}"))
      assert.is_false(parsers.extendsOrRestrict("{string,integer}",
        "{string,integer,string}"))

      assert(parsers.registerAlias(badVal, "t_person", "{string,number}"))
      assert(parsers.registerAlias(badVal, "t_employee", "{string,integer,string}"))
      assert.is_true(parsers.extendsOrRestrict("t_employee", "t_person"))
      assert.is_false(parsers.extendsOrRestrict("t_person", "t_employee"))
    end)

    it("should provide clear error messages for invalid extends syntax", function()
      -- Missing comma in tuple extends
      local parser = parsers.parseType(badVal, "{extends Point2DT,number}")
      assert.is_nil(parser)
      assert.matches("Cannot parse type specification", log_messages[#log_messages])

      clearSeq(log_messages)

      -- Using wrong extends syntax (record syntax for tuple)
      assert(parsers.registerAlias(badVal, "Point2DT", "{number,number}"))
      parser = parsers.parseType(badVal, "{extends:Point2DT,number}")
      assert.is_nil(parser)
      assert.matches("Cannot parse type specification", log_messages[#log_messages])
    end)

    it("should handle inheritance from invalid parent types gracefully", function()
      -- Try to extend from a union type (not allowed)
      local parser = parsers.parseType(badVal, "{extends,string|number,field:string}")
      assert.is_nil(parser)
      assert.matches("Cannot parse type specification", log_messages[#log_messages])
    end)
  end)
end)
