-- parsers_map_spec.lua
-- Tests for map type parsers

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

describe("parsers - map types", function()

  describe("map type parsers", function()
    it("should validate maps", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local mapParser = parsers.parseType(badVal, "{identifier:number}")
      assert.is.not_nil(mapParser, "mapParser is nil")

      assert_equals_2({a=1,b=2,c=3}, "a=1,b=2,c=3", mapParser(badVal, "a=1,b=2,['c']=3"))
      assert_equals_2(nil, "1='a'", mapParser(badVal, "1='a'"))
      assert.same({"Bad map  in test on line 1: '{1='a'}' (not a table)"}, log_messages)
    end)

    it("should validate sets", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local setParser = parsers.parseType(badVal, "{string:true}")
      assert.is.not_nil(setParser, "setParser is nil")
      -- '[' comes before letters
      -- TODO since the number parser does tonumber(v), in the end, [123] and ['123']
      -- give the same result, which is obviously wrong!
      assert_equals_2({["123"]=true,a=true}, '["123"]=true,a=true', setParser(badVal, "a=true,['123']=true"))
      assert_equals_2(nil, "a=true,[123]=true", setParser(badVal, "a=true,[123]=true"))
      assert.same({"Bad string  in test on line 1: '123'"}, log_messages)
    end)

    it("should validate recursive maps", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local mapParser = parsers.parseType(badVal, "{identifier:{number:true}}")
      assert.is.not_nil(mapParser, "mapParser is nil")
      assert_equals_2({a={[3]=true}}, "a={[3]=true}", mapParser(badVal, "a={[3]=true}"))

      assert.same({}, log_messages)
    end)

    it("should validate nested maps", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local nestedParser = parsers.parseType(badVal, "{string:{string:number}}")
      assert.is.not_nil(nestedParser, "nestedParser is nil")
      assert_equals_2({a={x=1,y=2}}, 'a={x=1,y=2}', nestedParser(badVal, 'a={x=1,y=2}'))

      assert.same({}, log_messages)
    end)
  end)

  describe("mapKVType", function()
    local log_messages = {}
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should extract key and value types from valid map types", function()
      -- Test basic map types
      local key_type, value_type = parsers.mapKVType("{string:number}")
      assert.equals("string", key_type)
      assert.equals("number", value_type)

      key_type, value_type = parsers.mapKVType("{identifier:boolean}")
      assert.equals("identifier", key_type)
      assert.equals("boolean", value_type)

      -- Test maps with complex value types
      key_type, value_type = parsers.mapKVType("{string:{number}}")
      assert.equals("string", key_type)
      assert.equals("{number}", value_type)

      key_type, value_type = parsers.mapKVType("{number:{string:boolean}}")
      assert.equals("number", key_type)
      assert.equals("{string:boolean}", value_type)

      -- Test maps with complex key and value types
      key_type, value_type = parsers.mapKVType("{identifier:{name:string,age:number}}")
      assert.equals("identifier", key_type)
      assert.equals("{age:number,name:string}", value_type)
    end)

    it("should handle map type aliases", function()
      -- Register some map type aliases
      assert(parsers.registerAlias(badVal, "StringToNumber", "{string:number}"))
      assert(parsers.registerAlias(badVal, "IdentifierToString", "{identifier:string}"))
      assert(parsers.registerAlias(badVal, "StringToArray", "{string:{number}}"))

      -- Test alias resolution
      local key_type, value_type = parsers.mapKVType("StringToNumber")
      assert.equals("string", key_type)
      assert.equals("number", value_type)

      key_type, value_type = parsers.mapKVType("IdentifierToString")
      assert.equals("identifier", key_type)
      assert.equals("string", value_type)

      key_type, value_type = parsers.mapKVType("StringToArray")
      assert.equals("string", key_type)
      assert.equals("{number}", value_type)

      assert.same({}, log_messages)
    end)

    it("should return nil for non-map types", function()
      -- Test nil input
      local key_type, value_type = parsers.mapKVType(nil)
      assert.is_nil(key_type)
      assert.is_nil(value_type)

      -- Test non-string input
      key_type, value_type = parsers.mapKVType(123)
      assert.is_nil(key_type)

      key_type, value_type = parsers.mapKVType({})
      assert.is_nil(key_type)

      key_type, value_type = parsers.mapKVType(true)
      assert.is_nil(key_type)

      -- Test invalid type specs
      key_type, value_type = parsers.mapKVType("not_a_map")
      assert.is_nil(key_type)

      key_type, value_type = parsers.mapKVType("{string:}") -- Malformed map
      assert.is_nil(key_type)

      -- Test valid type specs that aren't maps
      key_type, value_type = parsers.mapKVType("string")
      assert.is_nil(key_type)

      key_type, value_type = parsers.mapKVType("{string}")  -- Array type
      assert.is_nil(key_type)

      key_type, value_type = parsers.mapKVType("{string,number}")  -- Tuple type
      assert.is_nil(key_type)

      key_type, value_type = parsers.mapKVType("{age:number,name:string}")  -- Record type
      assert.is_nil(key_type)

      key_type, value_type = parsers.mapKVType("number|string")  -- Union type
      assert.is_nil(key_type)
    end)

    it("should handle custom key and value types", function()
      -- Register an enum type
      assert(registerEnumParser(badVal, {"Red", "Green", "Blue"}, "Color"))

      -- Register a complex custom type
      assert(parsers.registerAlias(badVal, "Point", "{x:number,y:number}"))

      -- Test map with custom types
      local key_type, value_type = parsers.mapKVType("{string:Color}")
      assert.equals("string", key_type)
      assert.equals("Color", value_type)

      key_type, value_type = parsers.mapKVType("{Color:Point}")
      assert.equals("Color", key_type)
      assert.equals("Point", value_type)

      assert.same({}, log_messages)
    end)

    it("should handle enum map types", function()
      -- Test enum maps which are a special case
      local key_type, value_type = parsers.mapKVType("{enum:red|green|blue}")
      assert.equals("enum", key_type)
      assert.equals("red|green|blue", value_type)

      assert.same({}, log_messages)
    end)
  end)

  describe("getComparator for maps", function()
    it("should return valid comparators for maps", function()
        local mapCmp = parsers.getComparator("{string:number}")
        assert.is_not_nil(mapCmp)

        -- Compare maps with different keys
        assert.is_true(mapCmp({a=1}, {b=1}))
        assert.is_false(mapCmp({b=1}, {a=1}))

        -- Compare maps with same keys but different values
        assert.is_true(mapCmp({a=1}, {a=2}))
        assert.is_false(mapCmp({a=2}, {a=1}))

        -- Equal maps
        assert.is_false(mapCmp({a=1}, {a=1}))

        -- Empty maps
        assert.is_false(mapCmp({}, {}))
    end)
  end)

  describe("isNeverTable for maps", function()
    it("should NOT match map types", function()
      assert(not parsers.isNeverTable("{identifier:number}"))
      assert(not parsers.isNeverTable("{string:boolean}"))
    end)
  end)
end)
