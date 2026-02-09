-- parsers_tagged_number_spec.lua
-- Tests for number_type and tagged_number type parsers

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each

local parsers = require("parsers")
local error_reporting = require("error_reporting")
local read_only = require("read_only")
local unwrap = read_only.unwrap

-- Returns a "badVal" object that stores errors in the given table
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

describe("parsers - number_type and tagged_number", function()

  describe("number_type parser", function()
    local log_messages
    local badVal
    local numberTypeParser

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
      numberTypeParser = parsers.parseType(badVal, "number_type")
      assert.is_not_nil(numberTypeParser, "numberTypeParser is nil")
    end)

    it("should accept 'number' as a valid number type", function()
      assert_equals_2("number", "number", numberTypeParser(badVal, "number"))
      assert.same({}, log_messages)
    end)

    it("should accept 'integer' as a valid number type", function()
      assert_equals_2("integer", "integer", numberTypeParser(badVal, "integer"))
      assert.same({}, log_messages)
    end)

    it("should accept 'float' as a valid number type", function()
      assert_equals_2("float", "float", numberTypeParser(badVal, "float"))
      assert.same({}, log_messages)
    end)

    it("should accept 'long' as a valid number type", function()
      assert_equals_2("long", "long", numberTypeParser(badVal, "long"))
      assert.same({}, log_messages)
    end)

    it("should accept 'percent' as a valid number type", function()
      assert_equals_2("percent", "percent", numberTypeParser(badVal, "percent"))
      assert.same({}, log_messages)
    end)

    it("should reject 'string' (not a number type)", function()
      local val, _reformatted = numberTypeParser(badVal, "string")
      assert.is_nil(val)
      assert.equals(1, #log_messages)
      assert.matches("is not a type that extends number", log_messages[1])
    end)

    it("should reject 'boolean' (not a number type)", function()
      local val, _reformatted = numberTypeParser(badVal, "boolean")
      assert.is_nil(val)
      assert.equals(1, #log_messages)
      assert.matches("is not a type that extends number", log_messages[1])
    end)

    it("should reject unknown type names", function()
      local val, _reformatted = numberTypeParser(badVal, "nonexistent_type")
      assert.is_nil(val)
      assert.is_true(#log_messages > 0)
    end)

    it("should reject empty string", function()
      local val, _reformatted = numberTypeParser(badVal, "")
      assert.is_nil(val)
    end)

    it("should work in parsed context", function()
      assert_equals_2("integer", "integer", numberTypeParser(badVal, "integer", "parsed"))
      assert.same({}, log_messages)
    end)
  end)

  describe("tagged_number parser", function()
    local log_messages
    local badVal
    local tagged_numberParser

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
      tagged_numberParser = parsers.parseType(badVal, "tagged_number")
      assert.is_not_nil(tagged_numberParser, "tagged_numberParser is nil")
    end)

    it("should accept valid number tagged_number", function()
      assert_equals_2({"number", 42}, '"number",42',
        tagged_numberParser(badVal, '"number",42'))
      assert.same({}, log_messages)
    end)

    it("should accept valid integer tagged_number", function()
      assert_equals_2({"integer", 5}, '"integer",5',
        tagged_numberParser(badVal, '"integer",5'))
      assert.same({}, log_messages)
    end)

    it("should accept valid float tagged_number", function()
      assert_equals_2({"float", 3.5}, '"float",3.5',
        tagged_numberParser(badVal, '"float",3.5'))
      assert.same({}, log_messages)
    end)

    it("should accept negative numbers", function()
      assert_equals_2({"number", -10}, '"number",-10',
        tagged_numberParser(badVal, '"number",-10'))
      assert.same({}, log_messages)
    end)

    it("should accept zero", function()
      assert_equals_2({"integer", 0}, '"integer",0',
        tagged_numberParser(badVal, '"integer",0'))
      assert.same({}, log_messages)
    end)

    it("should reject value not matching declared type (float for integer)", function()
      local val, _reformatted = tagged_numberParser(badVal, '"integer",3.5')
      assert.is_nil(val)
      assert.is_true(#log_messages > 0)
      assert.matches("Value does not match expected type integer", log_messages[#log_messages])
    end)

    it("should reject non-number type in first field", function()
      local val, _reformatted = tagged_numberParser(badVal, '"string","hello"')
      assert.is_nil(val)
      assert.is_true(#log_messages > 0)
      assert.matches("is not a type that extends number", log_messages[1])
    end)

    it("should reject unknown type in first field", function()
      local val, _reformatted = tagged_numberParser(badVal, '"nonexistent",42')
      assert.is_nil(val)
      assert.is_true(#log_messages > 0)
    end)

    it("should reject non-numeric value in second field", function()
      local val, _reformatted = tagged_numberParser(badVal, '"number","not_a_number"')
      assert.is_nil(val)
      assert.is_true(#log_messages > 0)
    end)
  end)

  describe("quantity parser", function()
    local log_messages
    local badVal
    local quantityParser

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
      quantityParser = parsers.parseType(badVal, "quantity")
      assert.is_not_nil(quantityParser, "quantityParser is nil")
    end)

    it("should accept valid number quantity", function()
      assert_equals_2({"number", 42}, "42number",
        quantityParser(badVal, "42number"))
      assert.same({}, log_messages)
    end)

    it("should accept valid integer quantity", function()
      assert_equals_2({"integer", 5}, "5integer",
        quantityParser(badVal, "5integer"))
      assert.same({}, log_messages)
    end)

    it("should accept valid float quantity", function()
      assert_equals_2({"float", 3.5}, "3.5float",
        quantityParser(badVal, "3.5float"))
      assert.same({}, log_messages)
    end)

    it("should accept negative numbers", function()
      assert_equals_2({"number", -10}, "-10number",
        quantityParser(badVal, "-10number"))
      assert.same({}, log_messages)
    end)

    it("should accept zero", function()
      assert_equals_2({"integer", 0}, "0integer",
        quantityParser(badVal, "0integer"))
      assert.same({}, log_messages)
    end)

    it("should reject value not matching declared type (float for integer)", function()
      local val, _reformatted = quantityParser(badVal, "3.5integer")
      assert.is_nil(val)
      assert.is_true(#log_messages > 0)
      assert.matches("Value does not match expected type integer", log_messages[#log_messages])
    end)

    it("should reject non-number type", function()
      local val, _reformatted = quantityParser(badVal, "42string")
      assert.is_nil(val)
      assert.is_true(#log_messages > 0)
    end)

    it("should reject unknown type name", function()
      local val, _reformatted = quantityParser(badVal, "42nonexistent")
      assert.is_nil(val)
      assert.is_true(#log_messages > 0)
    end)

    it("should reject reversed format (type before number)", function()
      local val, _reformatted = quantityParser(badVal, "kilogram3.5")
      assert.is_nil(val)
      assert.is_true(#log_messages > 0)
      assert.matches("expected format", log_messages[1])
    end)

    it("should reject plain text with no number", function()
      local val, _reformatted = quantityParser(badVal, "hello")
      assert.is_nil(val)
      assert.is_true(#log_messages > 0)
    end)

    it("should reject empty string", function()
      local val, _reformatted = quantityParser(badVal, "")
      assert.is_nil(val)
    end)

    it("should reject bare number with no type", function()
      local val, _reformatted = quantityParser(badVal, "42")
      assert.is_nil(val)
      assert.is_true(#log_messages > 0)
      assert.matches("expected format", log_messages[1])
    end)

    it("should work in parsed context", function()
      assert_equals_2({"integer", 5}, "5integer",
        quantityParser(badVal, {"integer", 5}, "parsed"))
      assert.same({}, log_messages)
    end)
  end)
end)
