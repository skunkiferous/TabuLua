-- parsers_simple_spec.lua
-- Tests for simple/basic type parsers

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local pending = busted.pending

local parsers = require("parsers")
local error_reporting = require("infra.error_reporting")
local string_utils = require("util.string_utils")
local escapeText = string_utils.escapeText
local read_only = require("util.read_only")
local unwrap = read_only.unwrap

local semver = require("semver")

-- True only where integers and floats are distinct native types (Lua 5.3+).
-- `math.type ~= nil` is NOT a valid probe: compat53 defines math.type on
-- LuaJIT too, and there it calls every whole double an "integer" — only a
-- native runtime answers "float" for 1.0.
local HAS_NATIVE_INTEGERS = math.type ~= nil and math.type(1.0) == "float"

-- Version-specific tests: 'long' has native-integer semantics on Lua 5.3+,
-- and is deterministically rejected at type resolution on LuaJIT
local it_native = HAS_NATIVE_INTEGERS and it or pending
local it_luajit = HAS_NATIVE_INTEGERS and pending or it

-- Returns a "badVal" object that store errors in the given table
local function mockBadVal(log_messages)
    local log = function(self, msg) table.insert(log_messages, msg) end
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

describe("parsers - simple types", function()

  describe("basic type parsers", function()
    it("should validate boolean", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local boolParser = parsers.parseType(badVal, "boolean")
      assert.is.not_nil(boolParser, "boolParser is nil")
      assert_equals_2(true, "true", boolParser(badVal, "true"))
      assert_equals_2(false, "false", boolParser(badVal, "false"))
      assert_equals_2(true, "true", boolParser(badVal, "yes"))
      assert_equals_2(false, "false", boolParser(badVal, "no"))
      assert_equals_2(true, "true", boolParser(badVal, "1"))
      assert_equals_2(false, "false", boolParser(badVal, "0"))
      assert_equals_2(nil, "invalid", boolParser(badVal, "invalid"))
      assert.same({"Bad boolean  in test on line 1: 'invalid' (expected 'true', 'false', 'yes', 'no', '1', or '0')"}, log_messages)
    end)

    it("should validate number", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local numberParser = parsers.parseType(badVal, "number")
      assert.is.not_nil(numberParser, "numberParser is nil")
      assert_equals_2(123, "123", numberParser(badVal, "123"))
      assert_equals_2(42, "42", numberParser(badVal, "042"))
      assert_equals_2(1.23, "1.23", numberParser(badVal, "1.23"))
      assert_equals_2(nil, "invalid", numberParser(badVal, "invalid"))
      assert.same({"Bad number  in test on line 1: 'invalid'"}, log_messages)
    end)

    it("should validate string", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local stringParser = parsers.parseType(badVal, "string")
      assert.is.not_nil(stringParser, "stringParser is nil")
      assert_equals_2("hello", "hello", stringParser(badVal, "hello"))
      assert_equals_2("123", "123", stringParser(badVal, "123"))
      assert_equals_2("", "", stringParser(badVal, ""))
      -- Non-strings should be reported as errors
      assert_equals_2(nil, "42", stringParser(badVal, 42))
      assert.same({"Bad string  in test on line 1: '42'"}, log_messages)
    end)

    it("should validate comment", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local commentParser = parsers.parseType(badVal, "comment")
      assert.is.not_nil(commentParser, "commentParser is nil")
      assert_equals_2("# A comment", "# A comment", commentParser(badVal, "# A comment"))
      assert_equals_2("", "", commentParser(badVal, ""))
      -- Non-strings should be reported as errors
      assert_equals_2(nil, "42", commentParser(badVal, 42))
      assert.same({"Bad comment  in test on line 1: '42'"}, log_messages)
    end)

    it("should validate text", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local textParser = parsers.parseType(badVal, "text")
      assert.is.not_nil(textParser, "textParser is nil")
      -- Test regular text
      assert_equals_2("Simple text", "Simple text", textParser(badVal, "Simple text"))
      -- Test escaped characters
      assert_equals_2("Line 1\nLine 2", "Line 1\\nLine 2", textParser(badVal, "Line 1\\nLine 2"))
      assert_equals_2("Col1\tCol2", "Col1\\tCol2", textParser(badVal, "Col1\\tCol2"))
      -- Test escaped backslash
      assert_equals_2("Path\\File", "Path\\\\File", textParser(badVal, "Path\\\\File"))
      -- Non-strings should be reported as errors
      assert_equals_2(nil, "42", textParser(badVal, 42))
      assert.same({"Bad text  in test on line 1: '42'"}, log_messages)
    end)

    it("should validate identifier", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local identifierParser = parsers.parseType(badVal, "identifier")
      assert.is.not_nil(identifierParser, "identifierParser is nil")
      -- Valid identifiers
      assert_equals_2("abc", "abc", identifierParser(badVal, "abc"))
      assert_equals_2("_abc", "_abc", identifierParser(badVal, "_abc"))
      assert_equals_2("abc123", "abc123", identifierParser(badVal, "abc123"))
      assert_equals_2("_123", "_123", identifierParser(badVal, "_123"))
      -- Invalid identifiers
      assert_equals_2(nil, "123abc", identifierParser(badVal, "123abc"))
      assert_equals_2(nil, "abc-def", identifierParser(badVal, "abc-def"))
      assert_equals_2(nil, "abc.def", identifierParser(badVal, "abc.def"))
      assert_equals_2(nil, "", identifierParser(badVal, ""))
      assert.same({
        "Bad identifier  in test on line 1: '123abc'",
        "Bad identifier  in test on line 1: 'abc-def'",
        "Bad identifier  in test on line 1: 'abc.def'",
        "Bad identifier  in test on line 1: ''",
      }, log_messages)
    end)

    it("should validate name", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local nameParser = parsers.parseType(badVal, "name")
      assert.is.not_nil(nameParser, "nameParser is nil")
      -- Valid names
      assert_equals_2("abc", "abc", nameParser(badVal, "abc"))
      assert_equals_2("abc.def", "abc.def", nameParser(badVal, "abc.def"))
      assert_equals_2("abc.def.ghi", "abc.def.ghi", nameParser(badVal, "abc.def.ghi"))
      assert_equals_2("_abc._def", "_abc._def", nameParser(badVal, "_abc._def"))
      -- Invalid names
      assert_equals_2(nil, "123.abc", nameParser(badVal, "123.abc"))
      assert_equals_2(nil, "abc..def", nameParser(badVal, "abc..def"))
      assert_equals_2(nil, ".abc.def", nameParser(badVal, ".abc.def"))
      assert_equals_2(nil, "abc.def.", nameParser(badVal, "abc.def."))
      assert.same({
        "Bad name  in test on line 1: '123.abc'",
        "Bad name  in test on line 1: 'abc..def'",
        "Bad name  in test on line 1: '.abc.def'",
        "Bad name  in test on line 1: 'abc.def.'",
      }, log_messages)
    end)

    it("should validate integer within safe range (±2^53)", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local integerParser = parsers.parseType(badVal, "integer")
      assert.is.not_nil(integerParser, "integerParser is nil")
      -- Valid integers
      assert_equals_2(123, "123", integerParser(badVal, "123"))
      assert_equals_2(-456, "-456", integerParser(badVal, "-456"))
      assert_equals_2(0, "0", integerParser(badVal, "0"))
      -- We cannot prevent using 1e2, because we could fail in TSV context,
      -- but Lua would still parse it as a number within a "structure",
      -- and we don't want to differentiate
      assert_equals_2(100, "100", integerParser(badVal, "1e2"))
      -- Safe integer boundary values (±2^53)
      assert_equals_2(9007199254740992, "9007199254740992", integerParser(badVal, "9007199254740992"))
      assert_equals_2(-9007199254740992, "-9007199254740992", integerParser(badVal, "-9007199254740992"))
      -- Invalid integers (non-integer values)
      assert_equals_2(nil, "1.23", integerParser(badVal, "1.23"))
      assert_equals_2(nil, "abc", integerParser(badVal, "abc"))
      assert_equals_2(nil, "", integerParser(badVal, ""))
      if HAS_NATIVE_INTEGERS then
        -- Values outside safe integer range should be rejected
        assert_equals_2(nil, "9007199254740993", integerParser(badVal, "9007199254740993"))
        assert_equals_2(nil, "-9007199254740993", integerParser(badVal, "-9007199254740993"))
        assert.same({
          "Bad integer  in test on line 1: '1.23'",
          "Bad integer  in test on line 1: 'abc'",
          "Bad integer  in test on line 1: ''",
          "Bad integer  in test on line 1: '9007199254740993' (value outside safe integer range (±2^53))",
          "Bad integer  in test on line 1: '-9007199254740993' (value outside safe integer range (±2^53))",
        }, log_messages)
      else
        -- All numbers are doubles (LuaJIT): tonumber("9007199254740993")
        -- ROUNDS to 2^53 before the parser ever sees it, so the value is
        -- indistinguishable from valid input and is accepted at the rounded
        -- value. This documents the boundary precision loss, it does not
        -- endorse it.
        assert_equals_2(9007199254740992, "9007199254740992",
          integerParser(badVal, "9007199254740993"))
        assert.same({
          "Bad integer  in test on line 1: '1.23'",
          "Bad integer  in test on line 1: 'abc'",
          "Bad integer  in test on line 1: ''",
        }, log_messages)
      end
    end)

    it("should validate float", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local floatParser = parsers.parseType(badVal, "float")
      assert.is.not_nil(floatParser, "floatParser is nil")
      -- Float values should always have decimal point in reformatted output
      assert_equals_2(123.0, "123.0", floatParser(badVal, "123"))
      assert_equals_2(0.0, "0.0", floatParser(badVal, "0"))
      assert_equals_2(-456.0, "-456.0", floatParser(badVal, "-456"))
      -- Already float values
      assert_equals_2(1.23, "1.23", floatParser(badVal, "1.23"))
      assert_equals_2(-0.5, "-0.5", floatParser(badVal, "-0.5"))
      -- Large numbers: tostring() doesn't use scientific notation for 1e10
      assert_equals_2(1e10, "10000000000.0", floatParser(badVal, "1e10"))
      -- Very large numbers that tostring() puts in scientific notation pass through as-is
      assert_equals_2(1e100, "1e+100", floatParser(badVal, "1e100"))
      -- Invalid floats
      assert_equals_2(nil, "abc", floatParser(badVal, "abc"))
      assert_equals_2(nil, "", floatParser(badVal, ""))
      assert.same({
        "Bad float  in test on line 1: 'abc'",
        "Bad float  in test on line 1: ''",
      }, log_messages)
    end)

    it_native("should validate long (full 64-bit range on Lua 5.3+)", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local longParser = parsers.parseType(badVal, "long")
      assert.is.not_nil(longParser, "longParser is nil")
      -- Valid long integers
      assert_equals_2(123, "123", longParser(badVal, "123"))
      assert_equals_2(-456, "-456", longParser(badVal, "-456"))
      assert_equals_2(0, "0", longParser(badVal, "0"))
      -- Large values that exceed safe integer range (2^53) - valid on Lua 5.3+
      assert_equals_2(9007199254740993, "9007199254740993", longParser(badVal, "9007199254740993"))
      assert_equals_2(9223372036854775807, "9223372036854775807", longParser(badVal, "9223372036854775807"))
      assert_equals_2(-9223372036854775808, "-9223372036854775808", longParser(badVal, "-9223372036854775808"))
      -- Invalid longs (non-integer values)
      assert_equals_2(nil, "1.23", longParser(badVal, "1.23"))
      assert_equals_2(nil, "abc", longParser(badVal, "abc"))
      assert.same({
        "Bad long  in test on line 1: '1.23'",
        "Bad long  in test on line 1: 'abc'",
      }, log_messages)
    end)

    it_luajit("should reject the long TYPE at resolution time on LuaJIT", function()
      -- 'long' fails DETERMINISTICALLY on LuaJIT — at type resolution, before
      -- any data value is seen — so a manifest with a long column fails the
      -- same way whether its tables are empty or full (a range-limited parser
      -- would make loading depend on the values in the data)
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      assert.is_nil(parsers.parseType(badVal, "long"))
      assert.matches("use 'int64' instead", log_messages[1])
      -- The failure reaches long wherever it hides in a composite spec
      assert.is_nil(parsers.parseType(badVal, "long|nil"))
      assert.is_nil(parsers.parseType(badVal, "{long}"))
      -- But the type name itself stays KNOWN: the logical extends-number
      -- relation must survive, so tag member lists naming 'long' still load
      local introspection = require("parsers.introspection")
      assert.is_true(introspection.typeSameOrExtends("long", "number"))
    end)

    it("should validate int64 (exact 64-bit range on EVERY Lua version)", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local int64Parser = parsers.parseType(badVal, "int64")
      assert.is.not_nil(int64Parser, "int64Parser is nil")
      -- The parsed value is an int64 BOX (interning makes the expected box the
      -- very same object); the reformatted text stays the canonical digits, so
      -- TSV output is unchanged
      local i64 = require("util.int64")
      assert_equals_2(i64.of("123"), "123", int64Parser(badVal, "123"))
      assert_equals_2(i64.of("-456"), "-456", int64Parser(badVal, "-456"))
      assert_equals_2(i64.of("0"), "0", int64Parser(badVal, "0"))
      -- Lenient input, canonical output
      assert_equals_2(i64.of("42"), "42", int64Parser(badVal, "042"))
      assert_equals_2(i64.of("5"), "5", int64Parser(badVal, "+5"))
      assert_equals_2(i64.of("0"), "0", int64Parser(badVal, "-0"))
      -- The parsed value really is an int64, recognizable without a schema
      assert.is_true(i64.is((int64Parser(badVal, "123"))))
      -- The full 64-bit range works UNGATED — including on LuaJIT, which is
      -- the whole point of the type: the text never touches tonumber()
      assert_equals_2(i64.of("9007199254740993"), "9007199254740993",
        int64Parser(badVal, "9007199254740993"))
      assert_equals_2(i64.of("9223372036854775807"), "9223372036854775807",
        int64Parser(badVal, "9223372036854775807"))
      assert_equals_2(i64.of("-9223372036854775808"), "-9223372036854775808",
        int64Parser(badVal, "-9223372036854775808"))
      -- Numbers (from Lua-defined content) convert exactly
      assert_equals_2(i64.of("123"), "123", int64Parser(badVal, 123))
      -- Re-parsing a parsed value is idempotent
      assert_equals_2(i64.of("123"), "123", int64Parser(badVal, i64.of("123")))
      -- Invalid values
      assert_equals_2(nil, "1.5", int64Parser(badVal, "1.5"))
      assert_equals_2(nil, "abc", int64Parser(badVal, "abc"))
      assert_equals_2(nil, "9223372036854775808", int64Parser(badVal, "9223372036854775808"))
      assert_equals_2(nil, "1.5", int64Parser(badVal, 1.5))
      assert.same({
        "Bad int64  in test on line 1: '1.5'",
        "Bad int64  in test on line 1: 'abc'",
        "Bad int64  in test on line 1: '9223372036854775808' "
          .. "('9223372036854775808' is outside the int64 range "
          .. "[-9223372036854775808, 9223372036854775807])",
        "Bad int64  in test on line 1: '1.5' ('1.5' has a fractional part)",
      }, log_messages)
    end)

    it("should have int64 extend number, not string", function()
      -- The EXTENDS relation describes what the parsed value IS. int64
      -- extended string only because its value used to be a string; a box is
      -- not a string. "number" and not "integer", mirroring long: integer is
      -- the ±2^53 safe-range type, and int64's range is wider.
      local introspection = require("parsers.introspection")
      assert.is_true(introspection.typeSameOrExtends("int64", "number"))
      assert.is_false(introspection.typeSameOrExtends("int64", "string"))
      assert.is_false(introspection.typeSameOrExtends("int64", "integer"))
    end)

    it("should parse {int64} arrays element-wise", function()
      -- REGRESSION GUARD. While int64 extended "string", the array parser's
      -- "assume a single unquoted string" shortcut fired for every {int64}
      -- cell, so "123,456" silently became a ONE-element array holding the
      -- literal text "123,456" instead of two int64s. Only the explicitly
      -- quoted form worked. Extending "number" retires that shortcut.
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local arrParser = parsers.parseType(badVal, "{int64}")
      assert.is.not_nil(arrParser)
      local i64 = require("util.int64")

      -- Array cells carry no outer braces: table_parser supplies them
      local parsed = arrParser(badVal, "123,456")
      assert.equals(2, #parsed)
      assert.is_true(i64.is(parsed[1]))
      assert.equals("123", i64.tostring(parsed[1]))
      assert.equals("456", i64.tostring(parsed[2]))

      -- A single element still works
      parsed = arrParser(badVal, "123")
      assert.equals(1, #parsed)
      assert.equals("123", i64.tostring(parsed[1]))
      assert.same({}, log_messages)

      -- Past 2^53 the QUOTED form is the portable one, and it is what
      -- TabuLua itself writes (see the reformat assertion below), so our own
      -- files round-trip exactly on every runtime
      parsed = arrParser(badVal, '"9223372036854775807","-1"')
      assert.equals(2, #parsed)
      assert.equals("9223372036854775807", i64.tostring(parsed[1]))
      assert.equals("-1", i64.tostring(parsed[2]))

      local _, reformatted = arrParser(badVal, "123,456")
      assert.equals('"123","456"', reformatted)
    end)

    -- KNOWN GAP, to be closed by the read-path phase (TODO/boxed_int64.md
    -- Phase 5). A container cell is parsed by ltcn, which LEXES a bare number
    -- literal before any int64 code runs -- so on LuaJIT a bare value past
    -- 2^53 has already been rounded to a double by then. The scalar int64
    -- column is unaffected: it receives the raw cell TEXT, never a number.
    -- The plan currently assumes only UNTYPED containers need the ltcn tag
    -- treatment; this shows a DECLARED {int64} needs it too.
    it("should reject a bare over-2^53 literal in an {int64} cell", function()
      -- THE SAME ANSWER ON EVERY RUNTIME is the whole point. Before this
      -- check, a bare 9007199254740993 was exact on Lua 5.3+ (ltcn lexes a
      -- native integer) but on LuaJIT rounded to ...992 and was accepted
      -- SILENTLY, because the rounded value lands back inside the acceptance
      -- range. The literal is now rejected on the cell TEXT, before ltcn ever
      -- lexes it, so both runtimes agree.
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local arrParser = parsers.parseType(badVal, "{int64}")
      local i64 = require("util.int64")

      assert.is_nil(arrParser(badVal, "9007199254740993"))
      assert.matches("cannot be represented exactly", log_messages[1])
      assert.matches("__int64", log_messages[1])
      assert.is_nil(arrParser(badVal, "9223372036854775807,-1"))

      -- The two forms that DO survive, and are what the message recommends
      log_messages = {}
      badVal = mockBadVal(log_messages)
      arrParser = parsers.parseType(badVal, "{int64}")
      assert.equals("9007199254740993",
          i64.tostring((arrParser(badVal, '"9007199254740993"'))[1]))
      assert.equals("9007199254740993",
          i64.tostring((arrParser(badVal, '{__int64="9007199254740993"}'))[1]))
      -- ...and small bare literals are untouched, on both runtimes
      assert.equals("-1", i64.tostring((arrParser(badVal, "-1"))[1]))
      assert.same({}, log_messages)
    end)

    it("should reject min/max on an int64 type, for now", function()
      -- The parent change makes restrictNumber ACCEPT int64, but its validator
      -- compares against plain-number bounds and the unspecified side defaults
      -- to ±math.huge, which no int64 can be compared against. Rejecting here
      -- beats generating a parser that errors on its first value.
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local parser = parsers.restrictNumber(badVal, "int64", 0, nil, "positive_id")
      assert.is_nil(parser)
      assert.matches("not supported on an int64 type yet", log_messages[1])
    end)

    it("should validate percent", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local percentParser = parsers.parseType(badVal, "percent")
      assert.is.not_nil(percentParser, "percentParser is nil")
      -- Valid percentages as %
      assert_equals_2(1.0, "100%", percentParser(badVal, "100%"))
      assert_equals_2(0, "0%", percentParser(badVal, "0%"))
      assert_equals_2(0.3333, "33.33%", percentParser(badVal, "33.33%"))
      assert_equals_2(-0.1, "-10%", percentParser(badVal, "-10%"))
      -- Valid percentages as fractions
      assert_equals_2(1.0, "5/5", percentParser(badVal, "5/5"))
      assert_equals_2(0, "0/42", percentParser(badVal, "0/42"))
      assert_equals_2(-0.1, "-1/10", percentParser(badVal, "-1/10"))
      assert_equals_2(0.33333333333333333333, "1/3", percentParser(badVal, "1/3"))
      -- Invalid percentages
      assert_equals_2(0.5, "50%", percentParser(badVal, 50))
      assert_equals_2(nil, "abc", percentParser(badVal, "abc"))
      assert_equals_2(nil, "", percentParser(badVal, ""))
      assert.same({
        "Bad percent  in test on line 1: '50' (percent must be a string ending with % or be a fraction)",
        "Bad percent  in test on line 1: 'abc'",
        "Bad percent  in test on line 1: ''",
      }, log_messages)
    end)

    it("should validate http", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local httpParser = parsers.parseType(badVal, "http")
      assert.is.not_nil(httpParser, "httpParser is nil")
      assert_equals_2("http://example.com", "http://example.com", httpParser(badVal, "http://example.com"))
      assert_equals_2("https://example.com:8080/path?q=1", "https://example.com:8080/path?q=1", httpParser(badVal, "https://example.com:8080/path?q=1"))
      -- Bad strings should be reported as errors
      assert_equals_2(nil, "ftp://example.com", httpParser(badVal, "ftp://example.com"))
      -- Non-strings should be reported as errors
      assert_equals_2(nil, "42", httpParser(badVal, 42))
      assert.same({"Bad http  in test on line 1: 'ftp://example.com'",
        "Bad http  in test on line 1: '42'"}, log_messages)
    end)

    it("should validate ascii", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local asciiParser = parsers.parseType(badVal, "ascii")
      assert.is.not_nil(asciiParser, "asciiParser is nil")
      -- Valid ASCII strings
      assert_equals_2("Hello", "Hello", asciiParser(badVal, "Hello"))
      assert_equals_2("Hello, World!", "Hello, World!", asciiParser(badVal, "Hello, World!"))
      assert_equals_2("123 ABC", "123 ABC", asciiParser(badVal, "123 ABC"))
      assert_equals_2("", "", asciiParser(badVal, ""))
      -- Non-ASCII strings should be reported as errors
      assert_equals_2(nil, "café", asciiParser(badVal, "café"))
      assert_equals_2(nil, "日本語", asciiParser(badVal, "日本語"))
      -- Non-strings should be reported as errors
      assert_equals_2(nil, "42", asciiParser(badVal, 42))
      assert.same({"Bad ascii  in test on line 1: 'café'",
        "Bad ascii  in test on line 1: '日本語'",
        "Bad ascii  in test on line 1: '42'"}, log_messages)
    end)

    it("should validate asciitext", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local asciitextParser = parsers.parseType(badVal, "asciitext")
      assert.is.not_nil(asciitextParser, "asciitextParser is nil")
      -- Test regular ASCII text
      assert_equals_2("Simple text", "Simple text", asciitextParser(badVal, "Simple text"))
      -- Test escaped characters (like text type)
      assert_equals_2("Line 1\nLine 2", "Line 1\\nLine 2", asciitextParser(badVal, "Line 1\\nLine 2"))
      assert_equals_2("Col1\tCol2", "Col1\\tCol2", asciitextParser(badVal, "Col1\\tCol2"))
      -- Test escaped backslash
      assert_equals_2("Path\\File", "Path\\\\File", asciitextParser(badVal, "Path\\\\File"))
      -- Non-ASCII strings should be reported as errors
      assert_equals_2(nil, "café", asciitextParser(badVal, "café"))
      assert_equals_2(nil, "日本語", asciitextParser(badVal, "日本語"))
      -- Non-strings should be reported as errors
      assert_equals_2(nil, "42", asciitextParser(badVal, 42))
      assert.same({"Bad asciitext  in test on line 1: 'café'",
        "Bad asciitext  in test on line 1: '日本語'",
        "Bad asciitext  in test on line 1: '42'"}, log_messages)
    end)
  end)

  describe("true and nil parsers", function()
    it("should validate true", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local trueParser = parsers.parseType(badVal, "true")
      assert.is.not_nil(trueParser, "trueParser is nil")

      assert_equals_2(true, "true", trueParser(badVal, "true", "tsv"))
      assert_equals_2(nil, "false", trueParser(badVal, "false", "tsv"))
      assert_equals_2(true, "true", trueParser(badVal, true, "parsed"))
      assert_equals_2(nil, "true", trueParser(badVal, "true", "parsed"))
      assert_equals_2(nil, "false", trueParser(badVal, false, "parsed"))
      assert.same({"Bad true  in test on line 1: 'false'",
        "Bad true  in test on line 1: 'true'",
        "Bad true  in test on line 1: 'false'"}, log_messages)
    end)

    it("should validate nil", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local nilParser = parsers.parseType(badVal, "nil")
      assert.is.not_nil(nilParser, "nilParser is nil")
      badVal.line_no = 2
      assert_equals_2(nil, "", nilParser(badVal, "", "tsv"))
      badVal.line_no = 3
      assert_equals_2(nil, "nil", nilParser(badVal, "nil", "tsv"))
      badVal.line_no = 4
      assert_equals_2(nil, "", nilParser(badVal, "", "parsed"))
      badVal.line_no = 5
      assert_equals_2(nil, "", nilParser(badVal, nil, "parsed"))
      badVal.line_no = 6
      assert_equals_2(nil, "nil", nilParser(badVal, "nil", "parsed"))
      badVal.line_no = 7
      assert_equals_2(nil, "false", nilParser(badVal, false, "parsed"))
      assert.same({"Bad nil  in test on line 3: 'nil' (nil should be represented with '')",
      "Bad nil  in test on line 6: 'nil' (context was 'parsed', was expecting (nil)/'')",
      "Bad nil  in test on line 7: 'false' (context was 'parsed', was expecting (nil)/'')"},
      log_messages)
    end)

    it("should validate nil", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local optParser = parsers.parseType(badVal, "{number}|nil")
      assert.is.not_nil(optParser, "optParser is nil")
      assert_equals_2(nil, "", optParser(badVal, "", "tsv"))
      --assert_equals_2(nil, "", optParser(badVal, "", "parsed"))
      --assert_equals_2(nil, "", optParser(badVal, nil, "parsed"))
      assert.same({},
      log_messages)
    end)
  end)

  describe("version parser", function()
    local log_messages
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should parse valid version strings", function()
      local versionParser = parsers.parseType(badVal, "version")
      assert.is.not_nil(versionParser, "versionParser is nil")
      assert_equals_2(semver(1, 2, 3), "1.2.3",
        versionParser(badVal, "1.2.3"))
      assert.same({}, log_messages)
    end)

    it("should return nil for invalid version strings", function()
      local versionParser = parsers.parseType(badVal, "version")
      assert.is.not_nil(versionParser, "versionParser is nil")
      assert_equals_2(nil, "1.2", versionParser(badVal, "1.2"))
      assert_equals_2(nil, "1.2.3.4", versionParser(badVal, "1.2.3.4"))
      assert_equals_2(nil, "a.b.c", versionParser(badVal, "a.b.c"))
      assert.same({"Bad version  in test on line 1: '1.2' (expected format: X.Y.Z (e.g., 1.0.0))",
        "Bad version  in test on line 1: '1.2.3.4' (expected format: X.Y.Z (e.g., 1.0.0))",
        "Bad version  in test on line 1: 'a.b.c' (expected format: X.Y.Z (e.g., 1.0.0))"}, log_messages)
    end)

    it("should handle version numbers with leading zeros", function()
      local versionParser = parsers.parseType(badVal, "version")
      assert.is.not_nil(versionParser, "versionParser is nil")
      assert_equals_2(semver(1, 2, 3), "1.2.3",
        versionParser(badVal, "01.02.03"))
    end)
  end)

  describe("version comparison parser", function()
    local log_messages
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    it("should parse valid version strings", function()
      local versionParser = parsers.parseType(badVal, "cmp_version")
      assert.is.not_nil(versionParser, "versionParser is nil")
      assert_equals_2("=1.2.3", "=1.2.3", versionParser(badVal, "=1.2.3"))
      assert.same({}, log_messages)
    end)

    it("should parse valid version strings, when used inside collections", function()
      local versionArrayParser = parsers.parseType(badVal, "{cmp_version}")
      assert.is.not_nil(versionArrayParser, "versionArrayParser is nil")
      assert_equals_2({"=1.2.3","<4.5.6"},'"=1.2.3","<4.5.6"',
        versionArrayParser(badVal, "'=1.2.3','<4.5.6'"))
      assert.same({}, log_messages)
    end)

    it("should parse all valid operator strings", function()
      local versionParser = parsers.parseType(badVal, "cmp_version")
      assert.is.not_nil(versionParser, "versionParser is nil")
      assert_equals_2("=1.2.3", "=1.2.3", versionParser(badVal, "=1.2.3"))
      assert_equals_2("=1.2.3", "=1.2.3", versionParser(badVal, "==1.2.3"))
      assert_equals_2("<1.2.3", "<1.2.3", versionParser(badVal, "<1.2.3"))
      assert_equals_2("<=1.2.3", "<=1.2.3", versionParser(badVal, "<=1.2.3"))
      assert_equals_2(">1.2.3", ">1.2.3", versionParser(badVal, ">1.2.3"))
      assert_equals_2(">=1.2.3", ">=1.2.3", versionParser(badVal, ">=1.2.3"))
      assert_equals_2("~1.2.3", "~1.2.3", versionParser(badVal, "~1.2.3"))
      assert_equals_2("^1.2.3", "^1.2.3", versionParser(badVal, "^1.2.3"))
      assert.same({}, log_messages)
    end)

    it("should return nil for invalid version strings", function()
      local versionParser = parsers.parseType(badVal, "cmp_version")
      assert.is.not_nil(versionParser, "versionParser is nil")
      assert_equals_2(nil, "=1.2", versionParser(badVal, "=1.2"))
      assert_equals_2(nil, "=1.2.3.4", versionParser(badVal, "=1.2.3.4"))
      assert_equals_2(nil, "=a.b.c", versionParser(badVal, "=a.b.c"))
      assert.same({"Bad cmp_version  in test on line 1: '=1.2'",
        "Bad cmp_version  in test on line 1: '=1.2.3.4'",
        "Bad cmp_version  in test on line 1: '=a.b.c'"}, log_messages)
    end)

    it("should return nil for invalid operator strings", function()
      local versionParser = parsers.parseType(badVal, "cmp_version")
      assert.is.not_nil(versionParser, "versionParser is nil")
      assert_equals_2(nil, "<>1.2.3", versionParser(badVal, "<>1.2.3"))
      assert_equals_2(nil, "~=1.2.3", versionParser(badVal, "~=1.2.3"))
      assert_equals_2(nil, "1.2.3", versionParser(badVal, "1.2.3"))
      assert.same({"Bad cmp_version  in test on line 1: '<>1.2.3'",
        "Bad cmp_version  in test on line 1: '~=1.2.3'",
        "Bad cmp_version  in test on line 1: '1.2.3'"}, log_messages)
    end)

    it("should handle version numbers with leading zeros", function()
      local versionParser = parsers.parseType(badVal, "cmp_version")
      assert.is.not_nil(versionParser, "versionParser is nil")
      assert_equals_2("=1.2.3", "=1.2.3",
        versionParser(badVal, "=01.02.03"))
    end)
  end)

  describe("Markdown Parser", function()
    local log_messages
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    local function shouldBeValid(text)
        local markdownParser = parsers.parseType(badVal, "markdown")
        assert.is.not_nil(markdownParser, "markdownParser is nil")
        if type(text) == "string" then
          text = escapeText(text)
        end
        assert.is_not_nil((markdownParser(badVal, text)))
    end

    local function shouldBeInvalid(text)
      local markdownParser = parsers.parseType(badVal, "markdown")
      assert.is.not_nil(markdownParser, "markdownParser is nil")
      if type(text) == "string" then
        text = escapeText(text)
      end
      assert.is_nil((markdownParser(badVal, text)))
    end

    it("accepts basic paragraphs", function()
        shouldBeValid("This is a simple paragraph.\n")
        shouldBeValid("This is a paragraph\nwith multiple lines.\n")
        shouldBeValid("First paragraph.\n\nSecond paragraph.\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("accepts headers", function()
        shouldBeValid("# Header 1\n")
        shouldBeValid("## Header 2\n")
        shouldBeValid("### Header 3\n")
        shouldBeValid("# Header 1\nWith content below\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("accepts emphasis", function()
        shouldBeValid("This is *emphasized* text.\n")
        shouldBeValid("This is _also emphasized_ text.\n")
        shouldBeValid("This is **strong** text.\n")
        shouldBeValid("This is __also strong__ text.\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("accepts code blocks", function()
        shouldBeValid("```\ncode block\n```\n")
        shouldBeValid("```lua\nlocal x = 1\n```\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("accepts lists", function()
        shouldBeValid("- Item 1\n")
        shouldBeValid("* Item 1\n")
        shouldBeValid("+ Item 1\n")
        shouldBeValid("- Item 1\n- Item 2\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("accepts links", function()
        shouldBeValid("[Link text](url)\n")
        shouldBeValid("Here's a [link](http://example.com) in text.\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("accepts blockquotes", function()
        shouldBeValid("> This is a quote\n")
        shouldBeValid("> Multi-line\n> quote\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("accepts escaped characters", function()
        shouldBeValid("\\* Not emphasis \\*\n")
        shouldBeValid("\\[Not a link\\]\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("accepts inline code", function()
        shouldBeValid("Use the `print()` function.\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("rejects invalid input", function()
        shouldBeInvalid(nil)
        shouldBeInvalid(123)
        shouldBeInvalid("")
        shouldBeInvalid("Incomplete *emphasis\n")
        shouldBeInvalid("Invalid #header\n")  -- No space after #
        shouldBeInvalid("```\nUnclosed code block\n")
        shouldBeInvalid("[Incomplete link\n")
        -- Verify no errors were logged
        assert.same({"Bad markdown  in test on line 1: 'nil'",
          "Bad markdown  in test on line 1: '123'"}, log_messages)
    end)

    it("handles complex documents", function()
        local complex = [[
# Main Header

This is a paragraph with *emphasis* and **strong** text.

## Subheader

- List item 1
- List item 2
- With `inline code`
- And [a link](http://example.com)

> A blockquote with some *emphasized* text.

```lua
local function example()
return "code block"
end
```
]]
      shouldBeValid(complex)
        -- Verify no errors were logged
      assert.same({}, log_messages)
    end)
  end)

  describe("ASCII Markdown Parser", function()
    local log_messages
    local badVal

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
    end)

    local function shouldBeValid(text)
        local asciimarkdownParser = parsers.parseType(badVal, "asciimarkdown")
        assert.is.not_nil(asciimarkdownParser, "asciimarkdownParser is nil")
        if type(text) == "string" then
          text = escapeText(text)
        end
        assert.is_not_nil((asciimarkdownParser(badVal, text)))
    end

    local function shouldBeInvalid(text)
      local asciimarkdownParser = parsers.parseType(badVal, "asciimarkdown")
      assert.is.not_nil(asciimarkdownParser, "asciimarkdownParser is nil")
      if type(text) == "string" then
        text = escapeText(text)
      end
      assert.is_nil((asciimarkdownParser(badVal, text)))
    end

    it("accepts basic ASCII paragraphs", function()
        shouldBeValid("This is a simple paragraph.\n")
        shouldBeValid("This is a paragraph\nwith multiple lines.\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("accepts ASCII headers", function()
        shouldBeValid("# Header 1\n")
        shouldBeValid("## Header 2\n")
        shouldBeValid("# Header 1\nWith content below\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("accepts ASCII emphasis", function()
        shouldBeValid("This is *emphasized* text.\n")
        shouldBeValid("This is **strong** text.\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("accepts ASCII code blocks", function()
        shouldBeValid("```\ncode block\n```\n")
        shouldBeValid("```lua\nlocal x = 1\n```\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("accepts ASCII lists", function()
        shouldBeValid("- Item 1\n")
        shouldBeValid("- Item 1\n- Item 2\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("accepts ASCII links", function()
        shouldBeValid("[Link text](url)\n")
        shouldBeValid("Here's a [link](http://example.com) in text.\n")
        -- Verify no errors were logged
        assert.same({}, log_messages)
    end)

    it("rejects non-ASCII markdown", function()
        -- Non-ASCII content should be rejected
        shouldBeInvalid("This has café in it.\n")
        shouldBeInvalid("# Header with émoji\n")
        shouldBeInvalid("日本語テキスト\n")
        -- Verify errors were logged for ascii validation
        assert.same({"Bad asciimarkdown  in test on line 1: 'This has café in it.\\n'",
          "Bad asciimarkdown  in test on line 1: '# Header with émoji\\n'",
          "Bad asciimarkdown  in test on line 1: '日本語テキスト\\n'"}, log_messages)
    end)

    it("rejects invalid markdown even if ASCII", function()
        shouldBeInvalid(nil)
        shouldBeInvalid(123)
        shouldBeInvalid("")
        shouldBeInvalid("Incomplete *emphasis\n")
        shouldBeInvalid("Invalid #header\n")  -- No space after #
        -- Verify errors were logged
        assert.same({"Bad asciimarkdown  in test on line 1: 'nil'",
          "Bad asciimarkdown  in test on line 1: '123'"}, log_messages)
    end)

    it("handles complex ASCII documents", function()
        local complex = [[
# Main Header

This is a paragraph with *emphasis* and **strong** text.

## Subheader

- List item 1
- List item 2
- With `inline code`
- And [a link](http://example.com)

> A blockquote with some *emphasized* text.

```lua
local function example()
return "code block"
end
```
]]
      shouldBeValid(complex)
      -- Verify no errors were logged
      assert.same({}, log_messages)
    end)
  end)

  describe("raw type", function()
    local log_messages = {}
    local badVal
    local rawParser

    before_each(function()
        log_messages = {}
        badVal = mockBadVal(log_messages)
        rawParser = parsers.parseType(badVal, "raw")
        assert.is_not_nil(rawParser, "rawParser is nil")
    end)

    it("should accept boolean values", function()
        assert_equals_2(true, "true", rawParser(badVal, "true"))
        assert_equals_2(false, "false", rawParser(badVal, "false"))
    end)

    it("should accept number values", function()
        assert_equals_2(42, "42", rawParser(badVal, "42"))
        assert_equals_2(3.14, "3.14", rawParser(badVal, "3.14"))
    end)

    it("should accept string values", function()
        assert_equals_2("test", "test", rawParser(badVal, "test"))
    end)

    it("should accept table values", function()
        assert_equals_2({1,2,3}, "1,2,3", rawParser(badVal, "1,2,3"))
        assert_equals_2({a=1}, "a=1", rawParser(badVal, "a=1"))
    end)

    it("should accept nil values", function()
        assert_equals_2(nil, "", rawParser(badVal, ""))
    end)

    -- The raw type should not accept non-raw values
    it("should reject function values", function()
        assert_equals_2(nil, "function", rawParser(badVal, function() end))
        assert.same({"Bad boolean|number|table|string|nil  in test on line 1: 'function'"},
          log_messages)
    end)
  end)

  describe("any type", function()
    local log_messages = {}
    local badVal
    local anyParser
    local registerEnumParser = parsers.registerEnumParser
    local table_utils = require("util.table_utils")
    local clearSeq = table_utils.clearSeq

    before_each(function()
        log_messages = {}
        badVal = mockBadVal(log_messages)
        anyParser = parsers.parseType(badVal, "any")
        assert.is_not_nil(anyParser, "anyParser is nil")
    end)

    it("should accept valid type-value pairs", function()
        -- Test basic types
        assert_equals_2({"string", "test"}, '"string","test"',
            anyParser(badVal, '"string","test"'))
        assert_equals_2({"number", 42}, '"number",42',
            anyParser(badVal, '"number",42'))
        assert_equals_2({"boolean", true}, '"boolean",true',
            anyParser(badVal, '"boolean",true'))

        -- Test complex types
        assert_equals_2({"{string}", {"a","b"}}, '"{string}",{"a","b"}',
            anyParser(badVal, '"{string}",{"a","b"}'))
    end)

    it("should reject invalid types", function()
        assert_equals_2(nil, '"invalid",42',
            anyParser(badVal, '"invalid",42'))
        assert.is_true(#log_messages > 0)
        -- With self-ref, the dynamic type lookup fails with the actual type name
        assert.matches("unknown", log_messages[1])
    end)

    it("should reject values not matching their type", function()
        -- String value for number type
        assert_equals_2(nil, '"number","not a number"',
            anyParser(badVal, '"number","not a number"'))
        assert.is_true(#log_messages > 0)
        assert.matches("Bad number", log_messages[1])
    end)

    it("should handle complex type validations", function()
        -- Test array type validation
        assert_equals_2({"{string}", {"test"}}, '"{string}",{"test"}',
            anyParser(badVal, '"{string}",{"test"}'))

        -- Test with wrong array content
        clearSeq(log_messages)
        assert_equals_2(nil, '"{string}",{42}',
            anyParser(badVal, '"{string}",{42}'))
        assert.is_true(#log_messages > 0)
        assert.matches("Bad string", log_messages[1])

        -- Test map type validation
        clearSeq(log_messages)
        assert_equals_2({"{string:number}", {test=42}}, '"{string:number}",{test=42}',
            anyParser(badVal, '"{string:number}",{test=42}'))
    end)

    it("should handle custom type validations", function()
        -- Test with an enum type
        assert(registerEnumParser(badVal, {"Red", "Green", "Blue"}, "Color"))

        clearSeq(log_messages)
        assert_equals_2({"Color", "Red"}, '"Color","Red"',
            anyParser(badVal, '"Color","Red"'))

        -- Test with invalid enum value
        clearSeq(log_messages)
        assert_equals_2(nil, '"Color","Yellow"',
            anyParser(badVal, '"Color","Yellow"'))
        assert.is_true(#log_messages > 0)
        assert.matches("Bad.*Yellow", log_messages[1])
    end)
  end)

  describe("regex parser", function()
    local log_messages
    local badVal
    local regexParser

    before_each(function()
      log_messages = {}
      badVal = mockBadVal(log_messages)
      regexParser = parsers.parseType(badVal, "regex")
      assert.is.not_nil(regexParser, "regexParser is nil")
    end)

    local function translate(pattern)
        local result = (regexParser(badVal, pattern))
        local err = table.concat(log_messages, "\n")
        --print(pattern, ' => ', tostring(result), err)
        return result, err
    end

    describe("basic functionality", function()
        it("should translate basic patterns", function()
            assert.equals("(?:abc)|(?:def)|(?:ghi)", translate("abc|def|ghi"))
        end)

        it("should handle single patterns", function()
            assert.equals("(?:abc)", translate("abc"))
        end)

        it("should handle patterns with spaces", function()
            assert.equals("(?:abc )|(?: def)|(?: ghi )", translate("abc | def| ghi "))
        end)
    end)

    describe("character classes", function()
        it("should translate Lua character classes", function()
            assert.equals("(?:\\d+)|(?:[[:alpha:]]+)", translate("%d+|%a+"))
        end)

        it("should translate character sets", function()
            assert.equals("(?:[aeiou])|(?:[0-9])", translate("[aeiou]|[0-9]"))
        end)
    end)

    describe("escaped characters", function()
        it("should handle escaped pipes", function()
            assert.equals("(?:a\\|b)|(?:c)", translate("a%|b|c"))
        end)

        it("should handle multiple escaped pipes", function()
            assert.equals("(?:a\\|b\\|c)|(?:d)", translate("a%|b%|c|d"))
        end)

        it("should handle escaped percent signs", function()
            assert.equals("(?:%)|(?:\\d+)|(?:[[:alpha:]]+)", translate("%%|%d+|%a+"))
        end)
    end)

    describe("error handling", function()
        it("should handle nil and empty input", function()
            local result, err = translate(nil)
            assert.is_nil(result)
            assert.equals("Bad regex  in test on line 1: 'nil'", err)

            log_messages = {}
            -- Since "" is used to mean "nil", this is a weird case that behaves differently
            -- from translateMultiPatternToPCRE()
            result, err = translate("")
            assert.is_nil(result)
            assert.equals("", err)
        end)

        it("should handle empty alternatives", function()
            local result, err = translate("|abc")
            assert.is_nil(result)
            assert.matches("Empty pattern found", err)
        end)

        it("should handle invalid patterns", function()
            -- Pattern with unmatched bracket
            local result, err = translate("abc|[def|ghi")
            assert.is_nil(result)
            assert.same("Bad regex  in test on line 1: 'abc|[def|ghi' (Invalid pattern: abc|[def|ghi)", err)  -- Error in second pattern
        end)
    end)

    describe("complex patterns", function()
        it("should handle email patterns", function()
            local pattern = "^[A-Za-z0-9%.%%%+%-]+@[A-Za-z0-9%.%-]+%.%w%w%w?$|" ..
                          "^[A-Za-z0-9%.%%%+%-]+@%[%d+%.%d+%.%d+%.%d+%]$"
            local result = translate(pattern)
            assert.is_not_nil(result)
            assert.matches("^%(%?:\\A.*\\Z%)|%(%?:\\A.*\\Z%)$", result)
        end)

        it("should handle version number patterns", function()
            local pattern = "^%d+%.%d+%.%d+$|^%d+%.%d+$"
            local result = translate(pattern)
            assert.is_not_nil(result)
            assert.same("(?:\\A\\d+\\.\\d+\\.\\d+\\Z)|(?:\\A\\d+\\.\\d+\\Z)", result)
        end)

        it("should handle mixed literals and patterns", function()
            local result = translate("hello|%d+|world%|earth")
            assert.equals("(?:hello)|(?:\\d+)|(?:world\\|earth)", result)
        end)
    end)
  end)
end)
