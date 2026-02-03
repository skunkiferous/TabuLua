-- parsers_validators_spec.lua
-- Tests for validator-related parser types: expression, error_level, validator_spec

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

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

describe("parsers - validator types", function()

  -- ============================================================
  -- expression type
  -- ============================================================

  describe("expression type", function()
    it("should parse a valid simple expression", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "expression")
      assert.is_not_nil(parser)
      local parsed, reformatted = parser(badVal, "x > 0")
      assert.are.equal("x > 0", parsed)
    end)

    it("should parse a valid or-pattern expression", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "expression")
      local parsed, reformatted = parser(badVal,
        "self.price.parsed > 0 or 'price must be positive'")
      assert.are.equal(
        "self.price.parsed > 0 or 'price must be positive'", parsed)
    end)

    it("should parse a valid arithmetic expression", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "expression")
      local parsed, reformatted = parser(badVal, "math.floor(x) == x")
      assert.are.equal("math.floor(x) == x", parsed)
    end)

    it("should parse expression with string methods", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "expression")
      local parsed, reformatted = parser(badVal,
        "value:match('^[A-Z]') ~= nil or 'must start with uppercase'")
      assert.is_not_nil(parsed)
    end)

    it("should reject invalid Lua syntax", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "expression")
      local errors_before = badVal.errors
      local parsed, reformatted = parser(badVal, "if then end")
      assert.is_nil(parsed)
      assert.is.truthy(badVal.errors > errors_before)
    end)

    it("should reject incomplete expression", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "expression")
      local errors_before = badVal.errors
      local parsed, reformatted = parser(badVal, "x >")
      assert.is_nil(parsed)
      assert.is.truthy(badVal.errors > errors_before)
    end)
  end)

  -- ============================================================
  -- error_level type
  -- ============================================================

  describe("error_level type", function()
    it("should parse 'error'", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "error_level")
      assert.is_not_nil(parser)
      local parsed, reformatted = parser(badVal, "error")
      assert.are.equal("error", parsed)
      assert.are.equal("error", reformatted)
    end)

    it("should parse 'warn'", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "error_level")
      local parsed, reformatted = parser(badVal, "warn")
      assert.are.equal("warn", parsed)
      assert.are.equal("warn", reformatted)
    end)

    it("should reject 'info'", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "error_level")
      local errors_before = badVal.errors
      local parsed, _reformatted = parser(badVal, "info")
      assert.is_nil(parsed)
      assert.is.truthy(badVal.errors > errors_before)
    end)

    it("should reject 'fatal'", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "error_level")
      local errors_before = badVal.errors
      local parsed, _reformatted = parser(badVal, "fatal")
      assert.is_nil(parsed)
      assert.is.truthy(badVal.errors > errors_before)
    end)

    it("should reject empty string", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "error_level")
      local errors_before = badVal.errors
      local parsed, _reformatted = parser(badVal, "")
      assert.is_nil(parsed)
      assert.is.truthy(badVal.errors > errors_before)
    end)
  end)

  -- ============================================================
  -- validator_spec type
  -- ============================================================

  describe("validator_spec type", function()
    it("should parse a simple expression string", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "validator_spec")
      assert.is_not_nil(parser)
      local parsed, reformatted = parser(badVal,
        "self.x > 0 or 'x must be positive'")
      -- Union resolves to expression (string) branch
      assert.are.equal("self.x > 0 or 'x must be positive'", parsed)
    end)

    it("should parse a record literal as expression (valid Lua syntax)", function()
      -- Note: When given as a raw string, a record literal like {expr="...",level="warn"}
      -- IS valid Lua syntax, so the expression branch of the union accepts it.
      -- The record branch only activates when input is a parsed table (inside arrays).
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "validator_spec")
      local parsed, reformatted = parser(badVal,
        '{expr="x > 0",level="warn"}')
      -- Parsed as expression string, not as record
      assert.is_not_nil(parsed)
      assert.are.equal("string", type(parsed))
    end)

    it("should reject completely invalid Lua", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "validator_spec")
      local errors_before = badVal.errors
      local parsed, _reformatted = parser(badVal, "@@invalid@@")
      assert.is_nil(parsed)
      assert.is.truthy(badVal.errors > errors_before)
    end)
  end)

  -- ============================================================
  -- {validator_spec} array type
  -- ============================================================

  describe("{validator_spec} array type", function()
    it("should parse array of simple expression strings", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "{validator_spec}")
      assert.is_not_nil(parser)
      local parsed, reformatted = parser(badVal,
        '"x > 0","y > 0"')
      assert.is_not_nil(parsed)
      local p = unwrap(parsed)
      assert.are.equal(2, #p)
    end)

    it("should parse array with mixed string and record specs", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "{validator_spec}")
      local parsed, reformatted = parser(badVal,
        '"x > 0",{expr="y > 0",level="warn"}')
      assert.is_not_nil(parsed)
      local p = unwrap(parsed)
      assert.are.equal(2, #p)
      -- First element is a string (expression)
      assert.are.equal("x > 0", p[1])
      -- Second element is a record
      local second = unwrap(p[2])
      assert.are.equal("y > 0", second.expr)
      assert.are.equal("warn", second.level)
    end)

    it("should parse nullable array", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "{validator_spec}|nil")
      assert.is_not_nil(parser)
      -- Empty/nil should return nil
      local parsed, reformatted = parser(badVal, "")
      assert.is_nil(parsed)
    end)

    it("should parse nullable array with value", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.parseType(badVal, "{validator_spec}|nil")
      local parsed, reformatted = parser(badVal,
        '{expr="count(rows) > 0 or \'need rows\'",level="warn"}')
      assert.is_not_nil(parsed)
    end)
  end)
end)
