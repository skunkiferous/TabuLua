-- parsers_type_spec.lua
-- Tests for type specification parser and related utilities

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each

local parsers = require("parsers")
local registerEnumParser = parsers.registerEnumParser
local parsedTypeSpecToStr = parsers.internal.parsedTypeSpecToStr
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

local function assert_parser_found(found , b1, a2, b2)
  if found then
    assert.is.not_nil(a2, "parser is nil")
  else
    assert.is_nil(a2, "parser is not nil")
  end
  assert.same(b1, b2)
end

describe("parsers - type specifications", function()

  describe("type specification parser", function()
    local log_messages = {}
    local badVal
    local typeParser

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
      typeParser = parsers.parseType(badVal, "type")
      assert.is.not_nil(typeParser, "typeParser is nil")
    end)

    it("should validate basic types", function()
      -- Basic type names
      assert_parser_found("string", "string", typeParser(badVal, "string"))
      assert_parser_found("number", "number", typeParser(badVal, "number"))
      assert_parser_found("boolean", "boolean", typeParser(badVal, "boolean"))
      assert_parser_found("integer", "integer", typeParser(badVal, "integer"))
    end)

    it("should validate empty table type", function()
      -- Test empty table type syntax
      assert_parser_found("{}", "{}", typeParser(badVal, "{}"))

      -- Test that it's properly aliased
      assert_parser_found("{}", "table", typeParser(badVal, "table"))
    end)

    it("should validate array type specifications", function()
      -- Array types
      assert_parser_found("{string}", "{string}", typeParser(badVal, "{string}"))
      assert_parser_found("{number}", "{number}", typeParser(badVal, "{number}"))
      -- Nested arrays
      assert_parser_found("{{string}}", "{{string}}", typeParser(badVal, "{{string}}"))
    end)

    it("should validate map type specifications", function()
      -- Map types
      assert_parser_found("{string:number}", "{string:number}", typeParser(badVal, "{string:number}"))
      assert_parser_found("{identifier:boolean}", "{identifier:boolean}",
        typeParser(badVal, "{identifier:boolean}"))
      -- Complex map types
      assert_parser_found("{string:{number:boolean}}", "{string:{number:boolean}}",
        typeParser(badVal, "{string:{number:boolean}}"))
    end)

    it("should validate tuple type specifications", function()
      -- Tuple types
      assert_parser_found("{string,number}", "{string,number}", typeParser(badVal, "{string,number}"))
      assert_parser_found("{boolean,string,number}", "{boolean,string,number}",
        typeParser(badVal, "{boolean,string,number}"))
      -- Complex tuple types
      assert_parser_found("{string,{number}}", "{string,{number}}",
        typeParser(badVal, "{string,{number}}"))
    end)

    it("should validate union type specifications", function()
      -- Union types
      assert_parser_found("number|string", "number|string", typeParser(badVal, "number|string"))
      assert_parser_found("boolean|number|string", "boolean|number|string",
        typeParser(badVal, "boolean|number|string"))
      -- Complex union types
      assert_parser_found("{string}|{number}", "{string}|{number}",
        typeParser(badVal, "{string}|{number}"))
      assert_parser_found(nil, "string|number", typeParser(badVal, "string|number"))

      -- Check error messages
      assert.same({
        [[Bad union  in test on line 1: 'string|number' (string must be last (or before nil))]]
      }, log_messages)
    end)

    it("should validate comments in type specifications", function()
      local typeSpec = [[
        # This is a comment
        {string:    # Key type
        number     # Value type
        }
      ]]
      assert_parser_found("{string:number}", "{string:number}", typeParser(badVal, typeSpec))

      -- Check error messages
      assert.same({}, log_messages)
    end)

    it("should reject invalid type specifications", function()
      -- Invalid basic types
      assert_parser_found(nil, "invalid_type", typeParser(badVal, "invalid_type"))
      -- Invalid array syntax
      assert_parser_found(nil, "{string", typeParser(badVal, "{string"))
      assert_parser_found(nil, "string}", typeParser(badVal, "string}"))
      -- Invalid map syntax
      assert_parser_found(nil, "{string:}", typeParser(badVal, "{string:}"))
      assert_parser_found(nil, "{:number}", typeParser(badVal, "{:number}"))
      -- Invalid tuple syntax
      assert_parser_found(nil, "{string,}", typeParser(badVal, "{string,}"))
      assert_parser_found(nil, "{,number}", typeParser(badVal, "{,number}"))

      -- Check error messages
      assert.same({
        'Bad type  in test on line 1: \'invalid_type\' (unknown/bad type)',
        'Bad type  in test on line 1: \'{string\' (Cannot parse type specification)',
        'Bad type  in test on line 1: \'string}\' (Cannot parse type specification)',
        'Bad type  in test on line 1: \'{string:}\' (Cannot parse type specification)',
        'Bad type  in test on line 1: \'{:number}\' (Cannot parse type specification)',
        'Bad type  in test on line 1: \'{string,}\' (Cannot parse type specification)',
        'Bad type  in test on line 1: \'{,number}\' (Cannot parse type specification)'
      }, log_messages)
    end)

    it("should handle whitespace in type specifications", function()
      -- Whitespace around basic types
      assert_parser_found("string", "string", typeParser(badVal, " string "))
      -- Whitespace in array types
      assert_parser_found("{string}", "{string}", typeParser(badVal, "{ string }"))
      -- Whitespace in map types
      assert_parser_found("{string:number}", "{string:number}",
        typeParser(badVal, "{ string : number }"))
      -- Whitespace in tuple types
      assert_parser_found("{string,number}", "{string,number}",
        typeParser(badVal, "{ string , number }"))
    end)

    it("should validate complex nested type specifications", function()
      -- Complex nested types
      assert_parser_found("{string:{number,{boolean:string}}}",
        "{string:{number,{boolean:string}}}",
        typeParser(badVal, "{string:{number,{boolean:string}}}"))

      -- Complex(table) key types are not accepted
      assert_parser_found(nil, "{{string:number}:{boolean,{string}}}",
        typeParser(badVal, "{{string:number}:{boolean,{string}}}"))
    end)
  end)

  describe("parsedTypeSpecToStr", function()
    local function test_roundtrip(input)
        local parsed = type_parser(input)
        local result = parsedTypeSpecToStr(parsed)
        assert.equals(input, result)
    end

    it("should handle simple names", function()
        test_roundtrip("number")
        test_roundtrip("string")
        test_roundtrip("fruits.apple")
    end)

    it("should handle array types", function()
        test_roundtrip("{number}")
        test_roundtrip("{string}")
        test_roundtrip("{fruits.apple}")
    end)

    it("should handle tuple types", function()
        test_roundtrip("{number,string}")
        test_roundtrip("{string,number,boolean}")
        test_roundtrip("{fruits.apple,vegetables.carrot}")
    end)

    it("should handle map types", function()
        test_roundtrip("{string:number}")
        test_roundtrip("{number:string}")
        test_roundtrip("{fruits.apple:vegetables.carrot}")
    end)

    it("should handle union types", function()
        test_roundtrip("number|string")
        test_roundtrip("fruits.apple|vegetables.carrot")
        test_roundtrip("number|string|boolean")
    end)

    it("should handle complex nested types", function()
        test_roundtrip("{number|string}")
        test_roundtrip("{{string:number}}")
        test_roundtrip("{number|string,boolean}")
        test_roundtrip("{string:{number:boolean}}")
    end)

    it("should reject invalid inputs", function()
        assert.has_error(function()
          parsedTypeSpecToStr("not a table")
        end, "Expected table, got string")

        assert.has_error(function()
          parsedTypeSpecToStr({invalid_structure = true})
        end, "Invalid node structure: missing tag: {invalid_structure=true}")

        assert.has_error(function()
          parsedTypeSpecToStr({tag = "invalid", value = "something"})
        end, "Unknown node type: invalid")
    end)

    it("should handle record types", function()
      -- Simple record
      test_roundtrip("{age:number,name:string}")

      -- Record with multiple fields
      test_roundtrip("{active:boolean,count:number,id:string}")

      -- Record with nested complex types
      test_roundtrip("{data:{string},meta:{name:string,tags:{string}}}")

      -- Record with union types in fields
      test_roundtrip("{config:{string:boolean},status:boolean|string}")

      -- Record with mixed simple and complex fields
      test_roundtrip("{attributes:{string:string},name:string,scores:{number}}")
    end)
  end)

  describe("findParserSpec", function()
    it("should find simple types", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local numberParser = parsers.parseType(badVal, "number")
      assert.is.not_nil(numberParser, "numberParser is nil")
      assert.same("number", parsers.findParserSpec(numberParser))
    end)

    it("should complex types", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local arrayParser = parsers.parseType(badVal, "{{identifier:number}}")
      assert.is.not_nil(arrayParser, "arrayParser is nil")
      assert.same("{{identifier:number}}", parsers.findParserSpec(arrayParser))
    end)
  end)

  describe("isNeverTable", function()
    it("should match simple types", function()
      assert(parsers.isNeverTable("boolean"))
      assert(parsers.isNeverTable("number"))
      assert(parsers.isNeverTable("percent"))
      assert(parsers.isNeverTable("boolean|number"))
    end)

    it("should NOT match complex types", function()
      assert(not parsers.isNeverTable("ratio"))
      assert(not parsers.isNeverTable("{{identifier:number}}"))
      assert(not parsers.isNeverTable("boolean|ratio"))
    end)

    it("should correctly identify {} as a table type", function()
      assert(not parsers.isNeverTable("{}"))
      assert(not parsers.isNeverTable("table"))
      assert(parsers.isNeverTable("boolean"))
      assert(parsers.isNeverTable("string"))
      assert(parsers.isNeverTable("number"))
    end)
  end)

  describe("getTypeKind", function()
    local log_messages = {}
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should identify basic type kinds", function()
      -- Test basic built-in types
      assert.same({"name", "string"}, {parsers.getTypeKind("string")})
      assert.same({"name", "number"}, {parsers.getTypeKind("number")})
      assert.same({"name", "boolean"}, {parsers.getTypeKind("boolean")})
      assert.same({"name", "number"}, {parsers.getTypeKind("integer")})
      assert.same({"name", "nil"}, {parsers.getTypeKind("nil")})
      assert.same({}, log_messages)
    end)

    it("should identify collection type kinds", function()
      -- Test array types
      assert.equals("array", parsers.getTypeKind("{string}"))
      assert.equals("array", parsers.getTypeKind("{number}"))
      assert.equals("array", parsers.getTypeKind("{{string}}"))

      -- Test map types
      assert.equals("map", parsers.getTypeKind("{string:number}"))
      assert.equals("map", parsers.getTypeKind("{identifier:boolean}"))

      -- Test tuple types
      assert.equals("tuple", parsers.getTypeKind("{string,number}"))
      assert.equals("tuple", parsers.getTypeKind("{boolean,string,number}"))

      -- Test record types
      assert.equals("record", parsers.getTypeKind("{name:string,age:number}"))
      assert.equals("record", parsers.getTypeKind("{x:number,y:number,z:number}"))

      -- Test empty table type
      assert.equals("table", parsers.getTypeKind("{}"))
      assert.equals("table", parsers.getTypeKind("table"))

      -- Test union types
      assert.equals("union", parsers.getTypeKind("number|string"))
      assert.equals("union", parsers.getTypeKind("boolean|number|string"))
      assert.same({}, log_messages)
    end)

    it("should identify enum types", function()
      -- Register an enum type for testing
      assert(registerEnumParser(badVal, {"Red", "Green", "Blue"}, "Color"))
      assert(registerEnumParser(badVal, {"North", "South", "East", "West"}, "Direction"))

      -- Test direct enum specifications
      assert.equals("enum", parsers.getTypeKind("{enum:red|green|blue}"))
      assert.equals("enum", parsers.getTypeKind("{enum:north|south|east|west}"))

      -- Test registered enum types
      assert.equals("enum", parsers.getTypeKind("Color"))
      assert.equals("enum", parsers.getTypeKind("Direction"))
      assert.same({}, log_messages)
    end)

    it("should resolve aliases to their actual type kind", function()
      -- Register some aliases
      assert(parsers.registerAlias(badVal, "Text", "string"))
      assert(parsers.registerAlias(badVal, "IntArray", "{integer}"))
      assert(parsers.registerAlias(badVal, "Point", "{x:number,y:number}"))
      assert(parsers.registerAlias(badVal, "NumberOrText", "number|Text"))

      -- Test resolution of aliases
      assert.equals("name", parsers.getTypeKind("Text"))
      assert.equals("array", parsers.getTypeKind("IntArray"))
      assert.equals("record", parsers.getTypeKind("Point"))
      assert.equals("union", parsers.getTypeKind("NumberOrText"))
      assert.same({}, log_messages)
    end)

    it("should handle multi-level aliases", function()
      -- Register nested aliases
      assert(parsers.registerAlias(badVal, "Natural", "integer"))
      assert(parsers.registerAlias(badVal, "Count", "Natural"))
      assert(parsers.registerAlias(badVal, "Index", "Count"))

      -- Test deep resolution
      assert.equals("name", parsers.getTypeKind("Index"))
      assert.same({}, log_messages)
    end)

    it("should handle restricted types", function()
      -- Create restricted types
      local posIntParser, posIntName = parsers.restrictNumber(badVal, "integer", 1, nil, "PositiveInt")
      local shortStrParser, shortStrName = parsers.restrictString(badVal, "string", 1, 10, nil, "ShortStr")

      -- Test restricted types
      assert.equals("name", parsers.getTypeKind("PositiveInt"))
      assert.equals("name", parsers.getTypeKind("ShortStr"))
      assert.same({}, log_messages)
    end)

    it("should handle custom complex types", function()
      -- Register some complex types
      assert(parsers.registerAlias(badVal, "StringDict", "{string:string}"))
      assert(parsers.registerAlias(badVal, "Point2D", "{x:number,y:number}"))
      assert(parsers.registerAlias(badVal, "Point3D", "{x:number,y:number,z:number}"))
      assert(parsers.registerAlias(badVal, "Coordinate", "Point2D|Point3D"))

      -- Test nested complex types
      assert.equals("map", parsers.getTypeKind("StringDict"))
      assert.equals("record", parsers.getTypeKind("Point2D"))
      assert.equals("record", parsers.getTypeKind("Point3D"))
      assert.equals("union", parsers.getTypeKind("Coordinate"))

      -- Test even more complex nested types
      assert(parsers.registerAlias(badVal, "PointMap", "{string:Point2D}"))
      assert(parsers.registerAlias(badVal, "PointList", "{Point2D}"))
      assert.equals("map", parsers.getTypeKind("PointMap"))
      assert.equals("array", parsers.getTypeKind("PointList"))
      assert.same({}, log_messages)
    end)

    it("should handle invalid or unknown types", function()
      -- Test invalid inputs
      assert.is_nil(parsers.getTypeKind(nil))
      assert.is_nil(parsers.getTypeKind(123))
      assert.is_nil(parsers.getTypeKind(true))
      assert.is_nil(parsers.getTypeKind({}))
      assert.is_nil(parsers.getTypeKind(""))

      -- Test malformed type specifications
      assert.is_nil(parsers.getTypeKind("unknown_type"))
      assert.is_nil(parsers.getTypeKind("{string"))
      assert.is_nil(parsers.getTypeKind("{string:}"))
      assert.is_nil(parsers.getTypeKind("{string,}"))
      assert.is_nil(parsers.getTypeKind("number|"))
    end)

    it("should correctly identify special type categories", function()
      -- Test that specialized string types resolve to their fundamental kind
      assert.same({"name", "string"}, {parsers.getTypeKind("comment")})
      assert.same({"name", "string"}, {parsers.getTypeKind("text")})
      assert.same({"name", "string"}, {parsers.getTypeKind("markdown")})
      assert.same({"name", "string"}, {parsers.getTypeKind("version")})
      assert.same({"name", "string"}, {parsers.getTypeKind("cmp_version")})
      assert.same({"name", "string"}, {parsers.getTypeKind("regex")})

      -- Test specialized number types
      assert.equals("name", parsers.getTypeKind("percent"))
      assert.equals("table", parsers.getTypeKind("ratio"))
      assert.same({}, log_messages)
    end)
  end)

  describe("empty table type", function()
    local log_messages = {}
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should validate empty table type", function()
      local tableParser = parsers.parseType(badVal, "{}")
      assert.is_not_nil(tableParser, "tableParser is nil")

      -- Test with empty table
      local result, formatted = tableParser(badVal, "")
      assert.same({}, result)
      assert.same("", formatted)

      -- Test with inner table
      result, formatted = tableParser(badVal, "{}")
      assert.same({{}}, result)
      assert.same("{}", formatted)

      -- Test with simple table
      result, formatted = tableParser(badVal, "a=1")
      assert.same({a=1}, result)
      assert.same("a=1", formatted)

      result, formatted = tableParser(badVal, "1,2,3")
      assert.same({1,2,3}, result)
      assert.same("1,2,3", formatted)

      -- Test with mixed table (both sequence and map parts)
      result, formatted = tableParser(badVal, "1,2,a=3")
      assert.same({1,2,a=3}, result)
      assert.same("1,2,a=3", formatted)

      -- Verify that {} and table are equivalent
      local tableParser2 = parsers.parseType(badVal, "table")
      assert.equals(tableParser, tableParser2)

      assert.same({}, log_messages)
    end)

    it("should treat {} as equivalent to table", function()
      local tableParser = parsers.parseType(badVal, "table")
      local emptyTableParser = parsers.parseType(badVal, "{}")

      assert.is_not_nil(tableParser, "tableParser is nil")
      assert.is_not_nil(emptyTableParser, "emptyTableParser is nil")
      assert.are.equal(tableParser, emptyTableParser, "table and {} should be equivalent")

      -- Test with various inputs to ensure both parsers behave identically
      local testCases = {
        "",
        "{}",
        "a=1",
        "1,2,3",
        "a=1,b='test'",
        "1,2,a=3,b=4",
      }

      for _, testCase in ipairs(testCases) do
        local result1, formatted1 = tableParser(badVal, testCase)
        local result2, formatted2 = emptyTableParser(badVal, testCase)

        assert.are.same(result1, result2, "Results should be the same for: " .. testCase)
        assert.are.same(formatted1, formatted2, "Formatted outputs should be the same for: " .. testCase)
      end

      assert.same({}, log_messages)
    end)

    it("should create default empty table for {}", function()
      -- Test that {} creates an empty table default value
      assert.same({}, parsers.createDefaultValue("{}"))

      -- Test that it matches the table type default
      assert.same(
        parsers.createDefaultValue("table"),
        parsers.createDefaultValue("{}"),
        "Default values for table and {} should be the same"
      )
    end)
  end)
end)
