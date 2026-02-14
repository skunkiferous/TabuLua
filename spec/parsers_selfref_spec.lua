-- parsers_selfref_spec.lua
-- Tests for self-referencing field types (self._N for tuples, self.fieldname for records)

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each

local parsers = require("parsers")
local error_reporting = require("error_reporting")
local read_only = require("read_only")
local unwrap = read_only.unwrap

local function mockBadVal(log_messages)
    local log = function(_self, msg) table.insert(log_messages, msg) end
    local badVal = error_reporting.badValGen(log)
    badVal.source_name = "test"
    badVal.line_no = 1
    return badVal
end

local function clearSeq(t)
    for i = #t, 1, -1 do t[i] = nil end
end

describe("parsers - self-referencing field types", function()

  describe("tuple self-ref", function()
    local log_messages
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should parse {number_type,self._1} with matching value", function()
      local parser = parsers.parseType(badVal, "{number_type,self._1}")
      assert.is_not_nil(parser)
      local parsed, reformatted = parser(badVal, '"integer",42')
      assert.is_not_nil(parsed)
      assert.equals("integer", unwrap(parsed)[1])
      assert.equals(42, unwrap(parsed)[2])
    end)

    it("should reject {number_type,self._1} when value doesn't match type", function()
      local parser = parsers.parseType(badVal, "{number_type,self._1}")
      assert.is_not_nil(parser)
      local parsed = parser(badVal, '"integer",3.5')
      assert.is_nil(parsed)
      assert.is_true(#log_messages > 0)
    end)

    it("should parse {type,self._1} with string value", function()
      local parser = parsers.parseType(badVal, "{type,self._1}")
      assert.is_not_nil(parser)
      local parsed = parser(badVal, '"string","hello"')
      assert.is_not_nil(parsed)
      assert.equals("string", unwrap(parsed)[1])
      assert.equals("hello", unwrap(parsed)[2])
    end)

    it("should parse {type,self._1} with boolean value", function()
      local parser = parsers.parseType(badVal, "{type,self._1}")
      assert.is_not_nil(parser)
      local parsed = parser(badVal, '"boolean",true')
      assert.is_not_nil(parsed)
      assert.equals("boolean", unwrap(parsed)[1])
      assert.equals(true, unwrap(parsed)[2])
    end)

    it("should reject {type,self._1} when value doesn't match type", function()
      local parser = parsers.parseType(badVal, "{type,self._1}")
      assert.is_not_nil(parser)
      local parsed = parser(badVal, '"integer","not a number"')
      assert.is_nil(parsed)
      assert.is_true(#log_messages > 0)
    end)

    it("should work with self-ref in non-last position", function()
      local parser = parsers.parseType(badVal, "{self._2,number_type}")
      assert.is_not_nil(parser)
      local parsed = parser(badVal, '42,"integer"')
      assert.is_not_nil(parsed)
      assert.equals(42, unwrap(parsed)[1])
      assert.equals("integer", unwrap(parsed)[2])
    end)

    it("should reject self._N referencing non-existent field", function()
      local parser = parsers.parseType(badVal, "{number_type,self._3}")
      assert.is_nil(parser)
      assert.is_true(#log_messages > 0)
      assert.matches("non%-existent field", log_messages[#log_messages])
    end)

    it("should reject self-referencing (field references itself)", function()
      local parser = parsers.parseType(badVal, "{self._1,number}")
      assert.is_nil(parser)
      assert.is_true(#log_messages > 0)
      assert.matches("cannot reference itself", log_messages[#log_messages])
    end)

    it("should reject mutual self-refs (both fields are selfrefs)", function()
      local parser = parsers.parseType(badVal, "{self._2,self._1}")
      assert.is_nil(parser)
      assert.is_true(#log_messages > 0)
      assert.matches("another self%-ref", log_messages[#log_messages])
    end)

    it("should reject self._1 at top level", function()
      local parser = parsers.parseType(badVal, "self._1")
      assert.is_nil(parser)
      assert.is_true(#log_messages > 0)
      assert.matches("inside a tuple or record", log_messages[#log_messages])
    end)

    it("should reject self-ref to field with non-type-producing type", function()
      local parser = parsers.parseType(badVal, "{integer,self._1}")
      assert.is_nil(parser)
      assert.is_true(#log_messages > 0)
      assert.matches("does not produce type names", log_messages[#log_messages])
    end)

    it("should reject self.fieldname in tuple context", function()
      local parser = parsers.parseType(badVal, "{number_type,self.unit}")
      assert.is_nil(parser)
      assert.is_true(#log_messages > 0)
      assert.matches("_N format", log_messages[#log_messages])
    end)

    it("should report tupleFieldTypes with self-ref", function()
      local parser = parsers.parseType(badVal, "{number_type,self._1}")
      assert.is_not_nil(parser)
      local fieldTypes = parsers.tupleFieldTypes("{number_type,self._1}")
      assert.is_not_nil(fieldTypes)
      assert.equals("number_type", fieldTypes[1])
      assert.equals("self._1", fieldTypes[2])
    end)
  end)

  describe("record self-ref", function()
    local log_messages
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should parse {unit:number_type,value:self.unit} with matching value", function()
      local parser = parsers.parseType(badVal, "{unit:number_type,value:self.unit}")
      assert.is_not_nil(parser)
      local parsed = parser(badVal, 'unit="integer",value=42')
      assert.is_not_nil(parsed)
      assert.equals("integer", parsed.unit)
      assert.equals(42, parsed.value)
    end)

    it("should reject record self-ref when value doesn't match type", function()
      local parser = parsers.parseType(badVal, "{unit:number_type,value:self.unit}")
      assert.is_not_nil(parser)
      local parsed = parser(badVal, 'unit="integer",value=3.5')
      assert.is_nil(parsed)
      assert.is_true(#log_messages > 0)
    end)

    it("should reject self-referencing field", function()
      local parser = parsers.parseType(badVal, "{a:number,b:self.b}")
      assert.is_nil(parser)
      assert.is_true(#log_messages > 0)
      assert.matches("cannot reference itself", log_messages[#log_messages])
    end)

    it("should reject circular self-refs", function()
      local parser = parsers.parseType(badVal, "{a:self.b,b:self.a}")
      assert.is_nil(parser)
      assert.is_true(#log_messages > 0)
      assert.matches("another self%-ref", log_messages[#log_messages])
    end)

    it("should reject self-ref to non-existent field", function()
      local parser = parsers.parseType(badVal, "{a:number,b:self.c}")
      assert.is_nil(parser)
      assert.is_true(#log_messages > 0)
      assert.matches("does not exist", log_messages[#log_messages])
    end)

    it("should reject tuple-style index in record self-ref", function()
      local parser = parsers.parseType(badVal, "{a:number_type,b:self._1}")
      assert.is_nil(parser)
      assert.is_true(#log_messages > 0)
      assert.matches("field names, not tuple indices", log_messages[#log_messages])
    end)

    it("should reject self-ref to non-type-producing field", function()
      local parser = parsers.parseType(badVal, "{a:integer,b:self.a}")
      assert.is_nil(parser)
      assert.is_true(#log_messages > 0)
      assert.matches("does not produce type names", log_messages[#log_messages])
    end)

    it("should report recordFieldTypes with self-ref", function()
      local parser = parsers.parseType(badVal, "{unit:number_type,value:self.unit}")
      assert.is_not_nil(parser)
      local fieldTypes = parsers.recordFieldTypes("{unit:number_type,value:self.unit}")
      assert.is_not_nil(fieldTypes)
      assert.equals("number_type", fieldTypes.unit)
      assert.equals("self.unit", fieldTypes.value)
    end)
  end)

  describe("LPEG selfref parsing", function()
    local lpeg_parser = require("parsers.lpeg_parser")

    it("should produce selfref tag for self._1", function()
      local parsed = lpeg_parser.type_parser("self._1")
      assert.is_not_nil(parsed)
      assert.equals("selfref", parsed.tag)
      assert.equals("_1", parsed.value)
    end)

    it("should produce selfref tag for self.fieldname", function()
      local parsed = lpeg_parser.type_parser("self.unit")
      assert.is_not_nil(parsed)
      assert.equals("selfref", parsed.tag)
      assert.equals("unit", parsed.value)
    end)

    it("should round-trip selfref through parsedTypeSpecToStr", function()
      local parsed = lpeg_parser.type_parser("self._1")
      local str = lpeg_parser.parsedTypeSpecToStr(parsed)
      assert.equals("self._1", str)
    end)

    it("should keep self alone as name tag", function()
      local parsed = lpeg_parser.type_parser("self")
      assert.is_not_nil(parsed)
      assert.equals("name", parsed.tag)
      assert.equals("self", parsed.value)
    end)

    it("should parse selfref inside tuple", function()
      local parsed = lpeg_parser.type_parser("{number_type,self._1}")
      assert.is_not_nil(parsed)
      assert.equals("tuple", parsed.tag)
      assert.equals("selfref", parsed.value[2].tag)
      assert.equals("_1", parsed.value[2].value)
    end)

    it("should parse selfref inside record", function()
      local parsed = lpeg_parser.type_parser("{unit:number_type,value:self.unit}")
      assert.is_not_nil(parsed)
      assert.equals("record", parsed.tag)
      -- Find the value field
      local found = false
      for _, kv in ipairs(parsed.value) do
        if kv.key.value == "value" then
          assert.equals("selfref", kv.value.tag)
          assert.equals("unit", kv.value.value)
          found = true
        end
      end
      assert.is_true(found)
    end)
  end)
end)
