-- parsers_record_spec.lua
-- Tests for record type parsers

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
local type_parser = parsers.internal.type_parser
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

local function assert_parser_found(found , b1, a2, b2)
  if found then
    assert.is.not_nil(a2, "parser is nil")
  else
    assert.is_nil(a2, "parser is not nil")
  end
  assert.same(b1, b2)
end

describe("parsers - record types", function()

  describe("record type specifications", function()
    local log_messages
    local badVal
    local typeParser

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
      typeParser = parsers.parseType(badVal, "type")
      assert.is.not_nil(typeParser, "typeParser is nil")
    end)

    it("should validate record type specifications", function()
      -- Basic record types
      assert_parser_found("{name:string,age:number}", "{age:number,name:string}",
          typeParser(badVal, "{name:string,age:number}"))

      -- Record with multiple fields of different types
      assert_parser_found("{id:string,count:number,active:boolean}",
          "{active:boolean,count:number,id:string}",
          typeParser(badVal, "{id:string,count:number,active:boolean}"))

      -- Record with complex field types
      assert_parser_found("{data:{string},meta:{name:string,tags:{string}}}",
          "{data:{string},meta:{name:string,tags:{string}}}",
          typeParser(badVal, "{data:{string},meta:{name:string,tags:{string}}}"))

      -- Record with union field types
      assert(registerEnumParser(badVal,
        {"active", "pending", "completed"}, "status"))
      assert_parser_found("{status:status,value:number|string}",
          "{status:status,value:number|string}",
          typeParser(badVal, "{status:status,value:number|string}"))

      -- Should reject invalid record specifications
      assert_parser_found(nil, "{:string,age:number}", typeParser(badVal,
        "{:string,age:number}"))
      assert_parser_found(nil, "{name:}", typeParser(badVal, "{name:}"))
      assert_parser_found(nil, "{name:string,}", typeParser(badVal,
        "{name:string,}"))

      -- Check error messages
      assert.same({
          "Bad type  in test on line 1: '{:string,age:number}' (Cannot parse type specification)",
          "Bad type  in test on line 1: '{name:}' (Cannot parse type specification)",
          "Bad type  in test on line 1: '{name:string,}' (Cannot parse type specification)"
      }, log_messages)
    end)

    it("should distinguish between maps and records", function()
      -- Single key-value pair should be parsed as a map
      local map_type = type_parser("{string:number}")
      assert.equals("map", map_type.tag)

      -- Multiple key-value pairs should be parsed as a record
      local record_type = type_parser("{name:string,age:number}")
      assert.equals("record", record_type.tag)

      -- Should be able to nest maps in records
      local complex_type = type_parser("{data:{string:number},info:string}")
      assert.equals("record", complex_type.tag)
      assert.equals("map", complex_type.value[1].value.tag)
    end)

    it("should validate record field names", function()
      -- Valid field names
      assert_parser_found("{valid:string,also_valid:number}", "{also_valid:number,valid:string}",
          typeParser(badVal, "{valid:string,also_valid:number}"))

      -- Invalid field names should be rejected
      assert_parser_found(nil, "{age:number,true:string}",
          typeParser(badVal, "{true:string,age:number}"))
      assert_parser_found(nil, "{invalid-name:string,age:number}",
          typeParser(badVal, "{invalid-name:string,age:number}"))

      assert.same({
          "Bad record  in test on line 1: '{age:number,true:string}' (field name cannot be a keyword: true)",
          "Bad type  in test on line 1: '{invalid-name:string,age:number}' (Cannot parse type specification)"
      }, log_messages)
    end)

    it("should validate records with optional fields", function()
      -- The fields in the reformatted value are sorted alphabetically
      -- NOTE: 'three' is alphabetically before 'two'!!!
      local optParser = parsers.parseType(badVal,
        "{one:number|nil,two:boolean|nil,three:{number}|nil}")
      assert.is_not_nil(optParser, "optParser is not nil")
      assert_equals_2({one=42,two=true,three={5}}, 'one=42,three={5},two=true',
        optParser(badVal, 'one=42,two=true,three={5}'))
      assert_equals_2({one=nil,two=true,three={5}}, 'one="",three={5},two=true',
        optParser(badVal, 'one="",two=true,three={5}'))
      assert_equals_2({one=42,two=nil,three={5}}, 'one=42,three={5},two=""',
        optParser(badVal, 'one=42,two="",three={5}'))
      assert_equals_2({one=42,two=true,three=nil}, 'one=42,three="",two=true',
        optParser(badVal, 'one=42,two=true,three=""'))
      assert.same({}, log_messages)
    end)
  end)

  describe("recordFieldNames", function()
    it("should return field names", function()
      assert.same({"attributes","name","scores"}, parsers.recordFieldNames(
        "{name:string,attributes:{string:string},scores:{number}|nil}"))
    end)

    it("should return nil for non-record types", function()
      assert.is_nil(parsers.recordFieldNames("{name:number}"))
    end)
  end)

  describe("recordOptionalFieldNames", function()
    it("should return optional fields", function()
      assert.same({"scores"}, parsers.recordOptionalFieldNames(
        "{name:string,attributes:{string:string},scores:{number}|nil}"))
    end)

    it("should return nil for non-record types", function()
      assert.is_nil(parsers.recordOptionalFieldNames("{name:number}"))
    end)

    it("should return {} for record types without optional fields", function()
      assert.same({}, parsers.recordOptionalFieldNames(
        "{name:string,attributes:{string:string}}"))
    end)
  end)

  describe("recordFieldTypes", function()
    it("should map field names to type specs", function()
      assert.same({["attributes"]="{string:string}",["name"]="string",["scores"]="{number}|nil"},
        parsers.recordFieldTypes(
        "{name:string,attributes:{string:string},scores:{number}|nil}"))
    end)

    it("should return nil for non-record types", function()
      assert.is_nil(parsers.recordFieldTypes("{name:number}"))
    end)
  end)

  describe("getComparator for records", function()
    it("should return valid comparators for records", function()
        local recordCmp = parsers.getComparator("{name:string,age:number}")
        assert.is_not_nil(recordCmp)

        -- Compare records field by field
        assert.is_true(recordCmp({name="Alice", age=20}, {name="Bob", age=20}))
        assert.is_true(recordCmp({name="Alice", age=20}, {name="Alice", age=25}))
        assert.is_false(recordCmp({name="Bob", age=20}, {name="Alice", age=20}))
        assert.is_false(recordCmp({name="Alice", age=25}, {name="Alice", age=20}))
        assert.is_false(recordCmp({name="Alice", age=20}, {name="Alice", age=20}))
    end)
  end)

  describe("record inheritance", function()
    local log_messages
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should parse basic record inheritance syntax", function()
      -- First register a base record type
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))

      -- Test extending with single field
      local parser = parsers.parseType(badVal, "{extends:Person,job:string}")
      assert.is_not_nil(parser, "Extended record parser should not be nil")

      -- Test the parser works correctly
      assert_equals_2({name="John", age=30, job="Engineer"},
        'age=30,job="Engineer",name="John"',
        parser(badVal, 'name="John",age=30,job="Engineer"'))
      assert.same({}, log_messages)
    end)

    it("should parse record inheritance with multiple additional fields", function()
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))

      local parser = parsers.parseType(badVal, "{extends:Person,job:string,salary:number}")
      assert.is_not_nil(parser)

      assert_equals_2({name="Jane", age=25, job="Designer", salary=50000},
        'age=25,job="Designer",name="Jane",salary=50000',
        parser(badVal, 'name="Jane",age=25,job="Designer",salary=50000'))
      assert.same({}, log_messages)
    end)

    it("should handle nested record inheritance", function()
      -- Create a chain of inheritance
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))
      assert(parsers.registerAlias(badVal, "Employee", "{extends:Person,job:string}"))

      local parser = parsers.parseType(badVal, "{extends:Employee,salary:number}")
      assert.is_not_nil(parser)

      assert_equals_2({name="Alice", age=28, job="Manager", salary=75000},
        'age=28,job="Manager",name="Alice",salary=75000',
        parser(badVal, 'name="Alice",age=28,job="Manager",salary=75000'))
      assert.same({}, log_messages)
    end)

    it("should validate parent record type exists", function()
      local parser = parsers.parseType(badVal, "{extends:NonExistentRecord,field:string}")
      assert.is_nil(parser)

      assert.same({
        "Bad type  in test on line 1: 'NonExistentRecord' (unknown/bad type)"
      }, log_messages)
    end)

    it("should validate parent is actually a record type", function()
      -- Test with non-record parent
      local parser = parsers.parseType(badVal, "{extends:string,field:string}")
      assert.is_nil(parser)

      assert.same({
        "Bad extends  in test on line 1: '{extends:string,field:string}' (parent type is not record: string)"
      }, log_messages)
    end)

    it("bare extends should create ancestor constraint parser", function()
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))

      local parser = parsers.parseType(badVal, "{extends:Person}")
      assert.is_not_nil(parser)
      -- Bare extends: values must be type names extending Person
      -- Person itself should be accepted
      local parsed, _ = parser(badVal, "Person")
      assert.are.equal("Person", parsed)
    end)

    it("should validate additional field names are identifiers", function()
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))

      local parser = parsers.parseType(badVal, "{extends:Person,123:string}")
      assert.is_nil(parser)

      assert.same({
        "Bad type  in test on line 1: '{extends:Person,123:string}' (Cannot parse type specification)"
      }, log_messages)
    end)

    it("should validate additional field types are valid", function()
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))

      local parser = parsers.parseType(badVal, "{extends:Person,job:invalid_type}")
      assert.is_nil(parser)

      assert.same({
        "Bad type  in test on line 1: 'invalid_type' (unknown/bad type)"
      }, log_messages)
    end)

    it("should prevent field name conflicts", function()
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))

      local parser = parsers.parseType(badVal, "{extends:Person,name:string}")
      assert.is_nil(parser)

      assert.same({
        "Bad record  in test on line 1: '{extends:Person,name:string}' (field name 'name' conflicts with parent type)"
      }, log_messages)
    end)

    it("should maintain proper inheritance relationship", function()
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))
      assert(parsers.registerAlias(badVal, "Employee", "{extends:Person,job:string}"))

      -- Employee should extend Person
      assert.is_true(parsers.extendsOrRestrict("Employee", "Person"))
      assert.is_true(parsers.extendsOrRestrict("Employee", "record"))

      assert.same({}, log_messages)
    end)

    it("should work with complex parent record types", function()
      -- Register complex types
      assert(registerEnumParser(badVal, {"Active", "Inactive"}, "Status"))
      assert(parsers.registerAlias(badVal, "Entity", "{id:string,status:Status,created:{number}}"))

      local parser = parsers.parseType(badVal, "{extends:Entity,description:text}")
      assert.is_not_nil(parser)

      assert_equals_2({id="test", status="Active", created={1234567890}, description="Test entity"},
        'created={1234567890},description="Test entity",id="test",status="Active"',
        parser(badVal, 'id="test",status="Active",created={1234567890},description="Test entity"'))
      assert.same({}, log_messages)
    end)

    it("should reject keyword field names", function()
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))

      local parser = parsers.parseType(badVal, "{extends:Person,true:string}")
      assert.is_nil(parser)

      assert.same({
        "Bad record  in test on line 1: '{extends:Person,true:string}' (field name cannot be a keyword: true)"
      }, log_messages)
    end)

    it("should support optional fields in extensions", function()
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))

      local parser = parsers.parseType(badVal, "{extends:Person,nickname:string|nil}")
      assert.is_not_nil(parser)

      -- Test with optional field present
      assert_equals_2({name="Bob", age=35, nickname="Bobby"},
        'age=35,name="Bob",nickname="Bobby"',
        parser(badVal, 'name="Bob",age=35,nickname="Bobby"'))

      -- Test with optional field missing (nil)
      assert_equals_2({name="Bob", age=35, nickname=nil},
        'age=35,name="Bob",nickname=""',
        parser(badVal, 'name="Bob",age=35,nickname=""'))

      assert.same({}, log_messages)
    end)

    it("should handle multiple levels of record inheritance", function()
      assert(parsers.registerAlias(badVal, "Entity3", "{id:string,epoch:number}"))
      assert(parsers.registerAlias(badVal, "NamedEntity", "{extends:Entity3,name:string}"))
      assert(parsers.registerAlias(badVal, "TimestampedEntity", "{extends:NamedEntity,created:number}"))
      assert(parsers.registerAlias(badVal, "User", "{extends:TimestampedEntity,email:string}"))

      local parser = parsers.parseType(badVal, "User")
      assert.is_not_nil(parser)

      assert_equals_2({id="123", epoch=1, name="John", created=1234567890, email="john@example.com"},
        'created=1234567890,email="john@example.com",epoch=1,id="123",name="John"',
        parser(badVal, 'id="123",epoch=1,name="John",created=1234567890,email="john@example.com"'))

      -- Verify inheritance chain
      assert.is_true(parsers.extendsOrRestrict("User", "TimestampedEntity"))
      assert.is_true(parsers.extendsOrRestrict("User", "NamedEntity"))
      assert.is_true(parsers.extendsOrRestrict("User", "Entity3"))
      assert.is_true(parsers.extendsOrRestrict("User", "record"))

      assert.same({}, log_messages)
    end)

    it("should handle inheritance with custom types", function()
      -- Register custom enum and restricted types
      assert(registerEnumParser(badVal, {"Small", "Medium", "Large"}, "Size"))
      local _, posIntName = parsers.restrictNumber(badVal, "integer", 1, nil, "PositiveInt")

      assert(parsers.registerAlias(badVal, "Product", "{name:string,size:Size}"))

      local parser = parsers.parseType(badVal, "{extends:Product,price:PositiveInt,quantity:PositiveInt}")
      assert.is_not_nil(parser)

      assert_equals_2({name="Widget", size="Medium", price=100, quantity=50},
        'name="Widget",price=100,quantity=50,size="Medium"',
        parser(badVal, 'name="Widget",size="Medium",price=100,quantity=50'))

      assert.same({}, log_messages)
    end)

    it("should not allow inheritance with map types", function()
      assert(parsers.registerAlias(badVal, "SSMap", "{string:string}"))

      local parser = parsers.parseType(badVal, "{extends:SSMap,tags:{string}}")
      assert.is_nil(parser)

      assert.same({
        "Bad extends  in test on line 1: '{extends:SSMap,tags:{string}}' (parent type is not record: SSMap)"
      }, log_messages)
    end)

    it("should handle inheritance with union types", function()
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))

      local parser = parsers.parseType(badVal, "{extends:Person,status:string|nil}")
      assert.is_not_nil(parser)

      assert_equals_2({name="Test", age=25, status="active"},
        'age=25,name="Test",status="active"',
        parser(badVal, 'name="Test",age=25,status="active"'))

      assert_equals_2({name="Test", age=25, status=nil},
        'age=25,name="Test",status=""',
        parser(badVal, 'name="Test",age=25,status=""'))

      assert.same({}, log_messages)
    end)

    it("should work with recordFieldNames for inherited records", function()
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))
      assert(parsers.registerAlias(badVal, "Employee2", "{extends:Person,job:string,salary:number}"))

      local fields = parsers.recordFieldNames("Employee2")
      assert.is_not_nil(fields)
      assert.same({"age", "job", "name", "salary"}, fields)  -- Should be sorted

      assert.same({}, log_messages)
    end)

    it("should work with recordFieldTypes for inherited records", function()
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))
      assert(parsers.registerAlias(badVal, "Employee3", "{extends:Person,job:string,active:boolean|nil}"))

      local fieldTypes = parsers.recordFieldTypes("Employee3")
      assert.is_not_nil(fieldTypes)
      assert.same({
        name = "string",
        age = "number",
        job = "string",
        active = "boolean|nil"
      }, fieldTypes)

      assert.same({}, log_messages)
    end)

    it("should work with recordOptionalFieldNames for inherited records", function()
      assert(parsers.registerAlias(badVal, "Person2", "{name:string,age:number|nil}"))
      assert(parsers.registerAlias(badVal, "Employee4", "{extends:Person2,job:string,salary:number|nil}"))

      local optionalFields = parsers.recordOptionalFieldNames("Employee4")
      assert.is_not_nil(optionalFields)
      assert.same({"age", "salary"}, optionalFields)  -- Should be sorted

      assert.same({}, log_messages)
    end)

    it("should roundtrip record inheritance specifications", function()
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))

      local input = "{extends:Person,job:string}"
      local parsed = parsers.internal.type_parser(input)
      local result = parsers.internal.parsedTypeSpecToStr(parsed)

      -- The result should be equivalent (though may be in expanded form)
      local parser1 = parsers.parseType(badVal, input)
      local parser2 = parsers.parseType(badVal, result)
      assert.is_not_nil(parser1)
      assert.is_not_nil(parser2)

      -- Both parsers should behave identically
      local testData = 'name="John",age=30,job="Engineer"'
      local expected = {name="John", age=30, job="Engineer"}
      assert_equals_2(expected, 'age=30,job="Engineer",name="John"', parser1(badVal, testData))
      assert_equals_2(expected, 'age=30,job="Engineer",name="John"', parser2(badVal, testData))

      assert.same({}, log_messages)
    end)

    it("should work with extendsOrRestrict for inherited records", function()
      assert(parsers.registerAlias(badVal, "Person", "{name:string,age:number}"))
      assert(parsers.registerAlias(badVal, "Employee", "{extends:Person,job:string}"))
      assert(parsers.registerAlias(badVal, "Manager", "{extends:Employee,team_size:number}"))

      -- Test direct inheritance
      assert.is_true(parsers.extendsOrRestrict("Employee", "Person"))
      assert.is_true(parsers.extendsOrRestrict("Manager", "Employee"))

      -- Test transitive inheritance
      assert.is_true(parsers.extendsOrRestrict("Manager", "Person"))

      -- Test base type inheritance
      assert.is_true(parsers.extendsOrRestrict("Employee", "record"))
      assert.is_true(parsers.extendsOrRestrict("Manager", "record"))

      assert.same({}, log_messages)
    end)

    it("should handle record inheritance with extendsOrRestrict", function()
      assert.is_true(parsers.extendsOrRestrict("{name:string,age:integer,employment:string}",
        "{name:string,age:number}"))
      assert.is_false(parsers.extendsOrRestrict("{name:string,age:integer}",
        "{name:string,age:integer,employment:string}"))

      assert(parsers.registerAlias(badVal, "person", "{name:string,age:number}"))
      assert(parsers.registerAlias(badVal, "employee", "{name:string,age:integer,employment:string}"))
      assert.is_true(parsers.extendsOrRestrict("employee", "person"))
      assert.is_false(parsers.extendsOrRestrict("person", "employee"))
    end)

    it("should provide clear error messages for invalid extends syntax", function()
      -- Missing colon in record extends
      local parser = parsers.parseType(badVal, "{extends Person,job:string}")
      assert.is_nil(parser)
      assert.matches("Cannot parse type specification", log_messages[#log_messages])

      clearSeq(log_messages)

      -- Try to extend from an array type (not allowed for records)
      parser = parsers.parseType(badVal, "{extends:{string},field:string}")
      assert.is_nil(parser)
      assert.same("Bad extends  in test on line 1: '{extends:{string},field:string}' (parent type is not record: {string})", log_messages[#log_messages])
    end)
  end)
end)
