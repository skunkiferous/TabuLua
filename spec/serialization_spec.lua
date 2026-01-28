-- serialization_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local serialization = require("serialization")

describe("serialization", function()
  describe("serialize and serializeTable", function()
    it("should serialize basic types and tables", function()
      assert.are.equal('"test"', serialization.serialize("test"))
      assert.are.equal('123', serialization.serialize(123))
      assert.are.equal('true', serialization.serialize(true))
      assert.are.equal('{1,2,3,a="test"}', serialization.serializeTable({1, 2, 3, a = "test"}, false, nil, 0))
    end)

    it("should handle nested tables", function()
      local t = {1, {2, 3}, a = {b = "test"}}
      assert.are.equal('{1,{2,3},a={b="test"}}', serialization.serializeTable(t, false, nil, 0))
    end)

    it("should throw an error for circular references", function()
      local t = {1, 2, 3}
      t.self = t
      assert.has_error(function() serialization.serializeTable(t) end, "recursive table")
    end)

    it("should handle nil-as-empty-strings", function()
      assert.are.equal('nil', serialization.serialize(nil, false))
      assert.are.equal('', serialization.serialize(nil, true))
      assert.are.equal("{1,nil,3}", serialization.serializeTable({1, nil, 3}, false))
      assert.are.equal("{1,'',3}", serialization.serializeTable({1, nil, 3}, true))
    end)
  end)

  describe("unquotedStr", function()
    it("should handle strings", function()
      local t = serialization.unquotedStr("abc")
      assert.are.same("abc", tostring(t))
    end)

    it("serializeTable should handle unquotedStr values", function()
      local t = serialization.unquotedStr("abc")
      assert.are.equal('{1,abc,a=abc}', serialization.serializeTable({1, t, a = t}, false, nil, 0))
    end)

    it("should not accept non-string values", function()
      assert.has_error(function()
      serialization.unquotedStr(true)
        end, "not a string: boolean")
    end)

    -- UNQUOTED_MT edge cases
    it("should handle empty strings", function()
      local t = serialization.unquotedStr("")
      assert.are.equal("", tostring(t))
      assert.are.equal("{}", serialization.serializeTable({t}, false, nil, 0))
    end)

    it("should handle strings with special characters", function()
      local t = serialization.unquotedStr("foo(bar)")
      assert.are.equal("foo(bar)", tostring(t))
      assert.are.equal("{foo(bar)}", serialization.serializeTable({t}, false, nil, 0))
    end)

    it("should handle strings that look like Lua code", function()
      local t = serialization.unquotedStr("nil")
      assert.are.equal("{nil}", serialization.serializeTable({t}, false, nil, 0))

      local t2 = serialization.unquotedStr("true")
      assert.are.equal("{true}", serialization.serializeTable({t2}, false, nil, 0))
    end)

    it("should serialize same unquotedStr used multiple times", function()
      local u = serialization.unquotedStr("VAR")
      assert.are.equal("{VAR,VAR,x=VAR}", serialization.serializeTable({u, u, x = u}, false, nil, 0))
    end)

    it("should work in deeply nested tables", function()
      local u = serialization.unquotedStr("CONST")
      local nested = {a = {b = {c = u}}}
      assert.are.equal("{a={b={c=CONST}}}", serialization.serializeTable(nested, false, nil, 0))
    end)
  end)

  describe("dump", function()
    local old_print
    local captured

    before_each(function()
      captured = {}
      old_print = print
      _G.print = function(msg) table.insert(captured, msg) end
    end)

    after_each(function()
      _G.print = old_print
    end)

    it("should print serialized value without name", function()
      serialization.dump({a = 1, b = 2})
      assert.equals(1, #captured)
      assert.equals('{a=1,b=2}', captured[1])
    end)

    it("should print serialized value with optional name", function()
      serialization.dump({x = 1, y = 2}, "myTable")
      assert.equals(1, #captured)
      assert.equals('myTable = {x=1,y=2}', captured[1])
    end)

    it("should handle basic types", function()
      serialization.dump(42)
      assert.equals('42', captured[1])

      captured = {}
      serialization.dump("test")
      assert.equals('"test"', captured[1])

      captured = {}
      serialization.dump(true)
      assert.equals('true', captured[1])
    end)
  end)

  describe("warnDump", function()
    it("should log serialized value as warning", function()
      local log_messages = {}
      local test_logger = require("named_logger").new(function(self, level, message)
        table.insert(log_messages, {level = level, message = message})
        return true
      end)

      serialization.warnDump({a = 1}, nil, test_logger)
      assert.equals(1, #log_messages)
      assert.equals("WARN", log_messages[1].level)
      assert.equals('{a=1}', log_messages[1].message)
    end)

    it("should log with optional name", function()
      local log_messages = {}
      local test_logger = require("named_logger").new(function(self, level, message)
        table.insert(log_messages, {level = level, message = message})
        return true
      end)

      serialization.warnDump({x = 1}, "myVar", test_logger)
      assert.equals(1, #log_messages)
      assert.equals("WARN", log_messages[1].level)
      assert.equals('myVar = {x=1}', log_messages[1].message)
    end)
  end)

  describe("toPlainNumber", function()
    it("should return nil for nil input", function()
      assert.is_nil(serialization.toPlainNumber(nil))
    end)

    it("should error for non-number input", function()
      assert.has_error(function() serialization.toPlainNumber("123") end)
      assert.has_error(function() serialization.toPlainNumber({}) end)
      assert.has_error(function() serialization.toPlainNumber(true) end)
    end)

    it("should handle integers", function()
      assert.equals("0", serialization.toPlainNumber(0))
      assert.equals("42", serialization.toPlainNumber(42))
      assert.equals("-100", serialization.toPlainNumber(-100))
    end)

    it("should handle floats without trailing zeros", function()
      assert.equals("3.14159", serialization.toPlainNumber(3.14159))
      assert.equals("0.5", serialization.toPlainNumber(0.5))
      assert.equals("-2.5", serialization.toPlainNumber(-2.5))
    end)

    it("should avoid scientific notation for large numbers", function()
      local result = serialization.toPlainNumber(1234567890123)
      assert.equals("1234567890123", result)
      assert.is_nil(result:match("e"))
    end)

    it("should avoid scientific notation for small numbers", function()
      local result = serialization.toPlainNumber(0.000001)
      assert.equals("0.000001", result)
      assert.is_nil(result:match("e"))
    end)

    it("should handle special float values", function()
      assert.equals("nan", serialization.toPlainNumber(0/0))
      assert.equals("inf", serialization.toPlainNumber(math.huge))
      assert.equals("-inf", serialization.toPlainNumber(-math.huge))
    end)
  end)

  describe("serializeJSON", function()
    it("should serialize nil as null", function()
      assert.equals("null", serialization.serializeJSON(nil))
    end)

    it("should serialize booleans", function()
      assert.equals("true", serialization.serializeJSON(true))
      assert.equals("false", serialization.serializeJSON(false))
    end)

    it("should serialize strings with proper escaping", function()
      assert.equals('"hello"', serialization.serializeJSON("hello"))
      assert.equals('"hello\\"world"', serialization.serializeJSON('hello"world'))
    end)

    it("should serialize integers with type wrapper", function()
      assert.equals('{"int":"42"}', serialization.serializeJSON(42))
      assert.equals('{"int":"-100"}', serialization.serializeJSON(-100))
      assert.equals('{"int":"0"}', serialization.serializeJSON(0))
    end)

    it("should serialize floats as plain numbers", function()
      local result = serialization.serializeJSON(3.14)
      assert.is_not_nil(result:match("^3%.14"))
    end)

    it("should serialize special float values with type wrapper", function()
      assert.equals('{"float":"nan"}', serialization.serializeJSON(0/0))
      assert.equals('{"float":"inf"}', serialization.serializeJSON(math.huge))
      assert.equals('{"float":"-inf"}', serialization.serializeJSON(-math.huge))
    end)

    it("should serialize functions as placeholder string", function()
      assert.equals('"<function>"', serialization.serializeJSON(function() end))
    end)

    it("should handle nil_as_empty_str option", function()
      assert.equals("", serialization.serializeJSON(nil, true))
      assert.equals("null", serialization.serializeJSON(nil, false))
    end)
  end)

  describe("serializeTableJSON", function()
    it("should serialize empty table", function()
      local result = serialization.serializeTableJSON({})
      -- Should be valid JSON: [0] not [0,]
      assert.is_nil(result:match(",%]"), "Empty table should not have trailing comma")
      assert.equals("[0]", result)
    end)

    it("should serialize sequence tables", function()
      local result = serialization.serializeTableJSON({"a", "b", "c"})
      assert.equals('[3,"a","b","c"]', result)
    end)

    it("should serialize sequence with integers", function()
      local result = serialization.serializeTableJSON({1, 2, 3})
      assert.equals('[3,{"int":"1"},{"int":"2"},{"int":"3"}]', result)
    end)

    it("should serialize map tables with size 0", function()
      local result = serialization.serializeTableJSON({a = 1})
      -- Map: size is 0, then key-value pairs
      assert.equals('[0,["a",{"int":"1"}]]', result)
    end)

    it("should serialize mixed tables", function()
      local result = serialization.serializeTableJSON({1, 2, a = "test"})
      -- Should have size 2 for sequence part, plus keyed entry
      assert.equals('[2,{"int":"1"},{"int":"2"},["a","test"]]', result)
    end)

    it("should serialize nested tables", function()
      local result = serialization.serializeTableJSON({{1, 2}, {3, 4}})
      -- Inner tables should also be serialized
      assert.equals('[2,[2,{"int":"1"},{"int":"2"}],[2,{"int":"3"},{"int":"4"}]]', result)
    end)

    it("should throw an error for non-table input", function()
      assert.has_error(function() serialization.serializeTableJSON("not a table") end)
      assert.has_error(function() serialization.serializeTableJSON(123) end)
    end)

    it("should throw an error for circular references", function()
      local t = {1, 2, 3}
      t.self = t
      assert.has_error(function() serialization.serializeTableJSON(t) end, "recursive table")
    end)

    it("should handle nil_as_empty_str in sequences", function()
      local result_null = serialization.serializeTableJSON({1, nil, 3}, false)
      local result_empty = serialization.serializeTableJSON({1, nil, 3}, true)
      assert.is_not_nil(result_null:match("null"))
      assert.is_not_nil(result_empty:match('""'))
    end)

    it("should handle boolean keys", function()
      local result = serialization.serializeTableJSON({[true] = "yes", [false] = "no"})
      assert.is_not_nil(result:match("%[true,"))
      assert.is_not_nil(result:match("%[false,"))
    end)

    it("should produce valid JSON without trailing commas", function()
      -- Test various table structures for trailing comma issues
      local test_cases = {
        {},
        {1},
        {a = 1},
        {1, 2, 3},
        {a = 1, b = 2},
        {1, a = 1},
      }
      for _, t in ipairs(test_cases) do
        local result = serialization.serializeTableJSON(t)
        assert.is_nil(result:match(",%]"), "Should not have trailing comma: " .. result)
        assert.is_nil(result:match("%[,"), "Should not have leading comma after [: " .. result)
      end
    end)
  end)

  describe("serializeSQL", function()
    it("should serialize nil as NULL", function()
      assert.equals("NULL", serialization.serializeSQL(nil))
    end)

    it("should serialize strings with single quotes", function()
      assert.equals("'hello'", serialization.serializeSQL("hello"))
      assert.equals("'Iron Sword'", serialization.serializeSQL("Iron Sword"))
    end)

    it("should escape single quotes in strings", function()
      assert.equals("'Hero''s Shield'", serialization.serializeSQL("Hero's Shield"))
      assert.equals("'It''s a ''test'''", serialization.serializeSQL("It's a 'test'"))
    end)

    it("should handle strings with newlines", function()
      local result = serialization.serializeSQL("Line one\nLine two")
      assert.equals("'Line one\nLine two'", result)
    end)

    it("should serialize integers", function()
      assert.equals("42", serialization.serializeSQL(42))
      assert.equals("-100", serialization.serializeSQL(-100))
      assert.equals("0", serialization.serializeSQL(0))
    end)

    it("should serialize floats", function()
      assert.equals("3.14", serialization.serializeSQL(3.14))
      assert.equals("-2.5", serialization.serializeSQL(-2.5))
      assert.equals("0.001", serialization.serializeSQL(0.001))
    end)

    it("should serialize booleans as 1 or 0", function()
      assert.equals("1", serialization.serializeSQL(true))
      assert.equals("0", serialization.serializeSQL(false))
    end)

    it("should serialize tables as JSON strings by default", function()
      -- Should be a quoted JSON string
      assert.equals("'[0,[\"a\",{\"int\":\"1\"}]]'", serialization.serializeSQL({a = 1}))
    end)

    it("should escape single quotes in JSON table output", function()
      local result = serialization.serializeSQL({name = "Hero's"})
      -- The JSON contains a single quote, which should be escaped
      assert.is_not_nil(result:match("''"), "Should escape single quotes in JSON")
    end)

    it("should use custom tableSerializer when provided", function()
      -- Use XML serializer instead of JSON
      local result = serialization.serializeSQL({a = 1}, serialization.serializeTableXML)
      assert.equals("'<table><key_value><string>a</string><integer>1</integer></key_value></table>'", result)
    end)

    it("should escape single quotes in XML table output", function()
      local result = serialization.serializeSQL({name = "Hero's"}, serialization.serializeTableXML)
      -- The XML contains a single quote (as &apos;), output should have escaped SQL quotes
      assert.is_not_nil(result:match("&apos;"), "Should contain XML-escaped apostrophe")
    end)

    it("should use Lua serializer when provided", function()
      local result = serialization.serializeSQL({1, 2, 3}, serialization.serializeTable)
      assert.equals("'{1,2,3}'", result)
    end)

    it("should serialize functions as placeholder string", function()
      assert.equals("'<function>'", serialization.serializeSQL(function() end))
    end)

    it("should error for unsupported types", function()
      local co = coroutine.create(function() end)
      assert.has_error(function() serialization.serializeSQL(co) end)
    end)

    -- Security-focused escaping tests
    it("should remove null bytes from strings", function()
      -- Null bytes can truncate strings in some database parsers
      assert.equals("'hello'", serialization.serializeSQL("hel\0lo"))
      assert.equals("'test'", serialization.serializeSQL("\0test"))
      assert.equals("'test'", serialization.serializeSQL("test\0"))
      assert.equals("''", serialization.serializeSQL("\0\0\0"))
    end)

    it("should escape backslashes for MySQL compatibility", function()
      -- MySQL treats backslash as escape character by default
      assert.equals("'path\\\\to\\\\file'", serialization.serializeSQL("path\\to\\file"))
      assert.equals("'C:\\\\Users\\\\test'", serialization.serializeSQL("C:\\Users\\test"))
      assert.equals("'\\\\'", serialization.serializeSQL("\\"))
    end)

    it("should handle combination of special characters", function()
      -- Test null byte + backslash + single quote together
      assert.equals("'it''s a \\\\path'", serialization.serializeSQL("it's a \0\\path"))
      -- Backslash before quote
      assert.equals("'test\\\\''value'", serialization.serializeSQL("test\\'value"))
    end)

    it("should escape special chars in table serialization output", function()
      -- Table with string containing backslash
      local result = serialization.serializeSQL({path = "C:\\test"}, serialization.serializeTable)
      assert.is_not_nil(result:match("\\\\\\\\"), "Should have escaped backslashes")
    end)
  end)

  describe("serializeXML", function()
    it("should serialize nil as <null/>", function()
      assert.equals("<null/>", serialization.serializeXML(nil))
    end)

    it("should serialize booleans", function()
      assert.equals("<true/>", serialization.serializeXML(true))
      assert.equals("<false/>", serialization.serializeXML(false))
    end)

    it("should serialize empty string as <string/>", function()
      assert.equals("<string/>", serialization.serializeXML(""))
    end)

    it("should serialize strings with content", function()
      assert.equals("<string>hello</string>", serialization.serializeXML("hello"))
      assert.equals("<string>hello world</string>", serialization.serializeXML("hello world"))
    end)

    it("should escape XML special characters in strings", function()
      assert.equals("<string>&amp;</string>", serialization.serializeXML("&"))
      assert.equals("<string>&lt;</string>", serialization.serializeXML("<"))
      assert.equals("<string>&gt;</string>", serialization.serializeXML(">"))
      assert.equals("<string>&quot;</string>", serialization.serializeXML('"'))
      assert.equals("<string>&apos;</string>", serialization.serializeXML("'"))
      assert.equals("<string>&lt;tag&gt;&amp;&quot;test&apos;</string>",
                    serialization.serializeXML('<tag>&"test\''))
    end)

    it("should serialize integers with <integer> tag", function()
      assert.equals("<integer>42</integer>", serialization.serializeXML(42))
      assert.equals("<integer>-100</integer>", serialization.serializeXML(-100))
      assert.equals("<integer>0</integer>", serialization.serializeXML(0))
    end)

    it("should serialize floats with <number> tag", function()
      assert.equals("<number>3.14</number>", serialization.serializeXML(3.14))
      assert.equals("<number>-2.5</number>", serialization.serializeXML(-2.5))
    end)

    it("should serialize special float values", function()
      assert.equals("<number>nan</number>", serialization.serializeXML(0/0))
      assert.equals("<number>inf</number>", serialization.serializeXML(math.huge))
      assert.equals("<number>-inf</number>", serialization.serializeXML(-math.huge))
    end)

    it("should serialize functions as <function/>", function()
      assert.equals("<function/>", serialization.serializeXML(function() end))
    end)

    it("should handle nil_as_empty_str option", function()
      assert.equals("", serialization.serializeXML(nil, true))
      assert.equals("<null/>", serialization.serializeXML(nil, false))
    end)
  end)

  describe("serializeTableXML", function()
    it("should serialize empty table", function()
      assert.equals("<table></table>", serialization.serializeTableXML({}))
    end)

    it("should serialize sequence tables", function()
      local result = serialization.serializeTableXML({"a", "b", "c"})
      assert.equals("<table><string>a</string><string>b</string><string>c</string></table>", result)
    end)

    it("should serialize sequence with integers", function()
      local result = serialization.serializeTableXML({1, 2, 3})
      assert.equals("<table><integer>1</integer><integer>2</integer><integer>3</integer></table>", result)
    end)

    it("should serialize map tables with key_value elements", function()
      local result = serialization.serializeTableXML({a = 1})
      assert.equals("<table><key_value><string>a</string><integer>1</integer></key_value></table>", result)
    end)

    it("should serialize mixed tables", function()
      local result = serialization.serializeTableXML({1, 2, a = "test"})
      assert.equals("<table><integer>1</integer><integer>2</integer><key_value><string>a</string><string>test</string></key_value></table>", result)
    end)

    it("should serialize nested tables", function()
      local result = serialization.serializeTableXML({{1, 2}})
      assert.equals("<table><table><integer>1</integer><integer>2</integer></table></table>", result)
    end)

    it("should throw an error for non-table input", function()
      assert.has_error(function() serialization.serializeTableXML("not a table") end)
      assert.has_error(function() serialization.serializeTableXML(123) end)
    end)

    it("should throw an error for circular references", function()
      local t = {1, 2, 3}
      t.self = t
      assert.has_error(function() serialization.serializeTableXML(t) end, "recursive table")
    end)

    it("should handle nil_as_empty_str in sequences", function()
      local result_null = serialization.serializeTableXML({1, nil, 3}, false)
      local result_empty = serialization.serializeTableXML({1, nil, 3}, true)
      assert.is_not_nil(result_null:match("<null/>"))
      assert.is_not_nil(result_empty:match("<string/>"))
    end)

    it("should sort keyed entries for consistent output", function()
      local result = serialization.serializeTableXML({z = 1, a = 2, m = 3})
      -- Keys should appear in sorted order: a, m, z
      local a_pos = result:find("<string>a</string>")
      local m_pos = result:find("<string>m</string>")
      local z_pos = result:find("<string>z</string>")
      assert.is_true(a_pos < m_pos)
      assert.is_true(m_pos < z_pos)
    end)
  end)

  describe("serializeMessagePack", function()
    local mpk = require("MessagePack")

    it("should serialize nil", function()
      local result = serialization.serializeMessagePack(nil)
      assert.equals(nil, mpk.unpack(result))
    end)

    it("should serialize booleans", function()
      assert.equals(true, mpk.unpack(serialization.serializeMessagePack(true)))
      assert.equals(false, mpk.unpack(serialization.serializeMessagePack(false)))
    end)

    it("should serialize strings", function()
      assert.equals("hello", mpk.unpack(serialization.serializeMessagePack("hello")))
      assert.equals("", mpk.unpack(serialization.serializeMessagePack("")))
    end)

    it("should serialize numbers", function()
      assert.equals(42, mpk.unpack(serialization.serializeMessagePack(42)))
      assert.equals(3.14, mpk.unpack(serialization.serializeMessagePack(3.14)))
      assert.equals(-100, mpk.unpack(serialization.serializeMessagePack(-100)))
    end)

    it("should serialize tables", function()
      local t = {1, 2, 3}
      local result = mpk.unpack(serialization.serializeMessagePack(t))
      assert.are.same(t, result)
    end)

    it("should serialize nested tables", function()
      local t = {a = {b = {c = 1}}}
      local result = mpk.unpack(serialization.serializeMessagePack(t))
      assert.are.same(t, result)
    end)

    it("should return a binary string", function()
      local result = serialization.serializeMessagePack({foo = "bar"})
      assert.equals("string", type(result))
      -- MessagePack output is typically not valid UTF-8 text
    end)

    it("should ignore nil_as_empty_str parameter (API consistency)", function()
      -- The parameter exists for API consistency but is ignored by MessagePack
      local result1 = serialization.serializeMessagePack(nil, false)
      local result2 = serialization.serializeMessagePack(nil, true)
      assert.equals(result1, result2)
    end)
  end)

  describe("serializeSQLBlob", function()
    it("should convert empty string to empty blob", function()
      assert.equals("X''", serialization.serializeSQLBlob(""))
    end)

    it("should convert ASCII string to hex blob", function()
      -- "Hello" = 48 65 6C 6C 6F in hex
      assert.equals("X'48656C6C6F'", serialization.serializeSQLBlob("Hello"))
    end)

    it("should convert single byte to hex", function()
      assert.equals("X'00'", serialization.serializeSQLBlob("\x00"))
      assert.equals("X'FF'", serialization.serializeSQLBlob("\xFF"))
      assert.equals("X'41'", serialization.serializeSQLBlob("A"))
    end)

    it("should handle binary data with null bytes", function()
      local binary = "\x00\x01\x02\x03"
      assert.equals("X'00010203'", serialization.serializeSQLBlob(binary))
    end)

    it("should handle all byte values", function()
      -- Test a string with bytes 0-255
      local all_bytes = ""
      for i = 0, 255 do
        all_bytes = all_bytes .. string.char(i)
      end
      local result = serialization.serializeSQLBlob(all_bytes)
      -- Should start with X' and end with '
      assert.is_not_nil(result:match("^X'"))
      assert.is_not_nil(result:match("'$"))
      -- Should be X' + 512 hex chars (2 per byte) + '
      assert.equals(3 + 512, #result)
    end)

    it("should produce uppercase hex digits", function()
      local result = serialization.serializeSQLBlob("\xAB\xCD\xEF")
      assert.equals("X'ABCDEF'", result)
    end)
  end)

  describe("serializeMessagePackSQLBlob", function()
    local mpk = require("MessagePack")

    it("should produce valid SQL BLOB literal", function()
      local result = serialization.serializeMessagePackSQLBlob("test")
      assert.is_not_nil(result:match("^X'"))
      assert.is_not_nil(result:match("'$"))
    end)

    it("should be reversible via hex decode and MessagePack unpack", function()
      local original = {foo = "bar", num = 42}
      local blob = serialization.serializeMessagePackSQLBlob(original)

      -- Extract hex string (remove X' prefix and ' suffix)
      local hex = blob:sub(3, -2)

      -- Convert hex back to binary
      local binary = hex:gsub("..", function(h)
        return string.char(tonumber(h, 16))
      end)

      -- Unpack MessagePack
      local decoded = mpk.unpack(binary)
      assert.are.same(original, decoded)
    end)

    it("should handle nil value", function()
      local result = serialization.serializeMessagePackSQLBlob(nil)
      assert.is_not_nil(result:match("^X'"))
      assert.is_not_nil(result:match("'$"))
    end)

    it("should handle empty table", function()
      local result = serialization.serializeMessagePackSQLBlob({})
      assert.is_not_nil(result:match("^X'"))
    end)

    it("should handle complex nested structure", function()
      local complex = {
        name = "test",
        values = {1, 2, 3},
        nested = {a = {b = {c = "deep"}}}
      }
      local blob = serialization.serializeMessagePackSQLBlob(complex)

      -- Extract and decode
      local hex = blob:sub(3, -2)
      local binary = hex:gsub("..", function(h)
        return string.char(tonumber(h, 16))
      end)
      local decoded = mpk.unpack(binary)

      assert.are.same(complex, decoded)
    end)

    it("should ignore nil_as_empty_str parameter", function()
      -- Parameter exists for API consistency but is ignored
      local result1 = serialization.serializeMessagePackSQLBlob(nil, false)
      local result2 = serialization.serializeMessagePackSQLBlob(nil, true)
      assert.equals(result1, result2)
    end)
  end)

  describe("MAX_TABLE_DEPTH handling", function()
    -- Helper to create deeply nested table
    local function createNestedTable(depth)
      local t = {value = "leaf"}
      for _ = 1, depth - 1 do
        t = {nested = t}
      end
      return t
    end

    describe("serializeTable", function()
      it("should serialize table at depth 10 (at max)", function()
        local t = createNestedTable(10)
        -- Should succeed without error (depth check happens before increment)
        local result = serialization.serializeTable(t, false, nil, 0)
        assert.is_not_nil(result)
        assert.is_not_nil(result:match("leaf"))
      end)

      it("should error at depth 11 (exceeds MAX_TABLE_DEPTH)", function()
        local t = createNestedTable(11)
        assert.has_error(function()
          serialization.serializeTable(t, false, nil, 0)
        end, "Maximal depth reached!")
      end)

      it("should error for tables far exceeding MAX_TABLE_DEPTH", function()
        local t = createNestedTable(15)
        assert.has_error(function()
          serialization.serializeTable(t, false, nil, 0)
        end, "Maximal depth reached!")
      end)

      it("should respect initial depth parameter", function()
        -- Starting at depth 8, only 2 more levels allowed
        local t = {a = {b = "value"}}  -- 2 levels deep
        local result = serialization.serializeTable(t, false, nil, 8)
        assert.is_not_nil(result)

        -- Starting at depth 9, only 1 more level allowed - nested table should fail
        local t2 = {a = {b = "value"}}  -- 2 levels deep
        assert.has_error(function()
          serialization.serializeTable(t2, false, nil, 9)
        end, "Maximal depth reached!")
      end)
    end)

    describe("serializeTableJSON", function()
      it("should serialize table at depth 10 (at max)", function()
        local t = createNestedTable(10)
        local result = serialization.serializeTableJSON(t, false, nil, 0)
        assert.is_not_nil(result)
        assert.is_not_nil(result:match("leaf"))
      end)

      it("should error at depth 11", function()
        local t = createNestedTable(11)
        assert.has_error(function()
          serialization.serializeTableJSON(t, false, nil, 0)
        end, "Maximal depth reached!")
      end)
    end)

    describe("serializeTableXML", function()
      it("should serialize table at depth 10 (at max)", function()
        local t = createNestedTable(10)
        local result = serialization.serializeTableXML(t, false, nil, 0)
        assert.is_not_nil(result)
        assert.is_not_nil(result:match("leaf"))
      end)

      it("should error at depth 11", function()
        local t = createNestedTable(11)
        assert.has_error(function()
          serialization.serializeTableXML(t, false, nil, 0)
        end, "Maximal depth reached!")
      end)
    end)

    it("should expose MAX_TABLE_DEPTH constant", function()
      assert.equals(10, serialization.MAX_TABLE_DEPTH)
    end)
  end)

  describe("serializeNaturalJSON", function()
    it("should serialize nil as null", function()
      assert.equals("null", serialization.serializeNaturalJSON(nil))
    end)

    it("should serialize booleans", function()
      assert.equals("true", serialization.serializeNaturalJSON(true))
      assert.equals("false", serialization.serializeNaturalJSON(false))
    end)

    it("should serialize strings with proper escaping", function()
      assert.equals('"hello"', serialization.serializeNaturalJSON("hello"))
      assert.equals('"hello\\"world"', serialization.serializeNaturalJSON('hello"world'))
    end)

    it("should serialize integers as plain numbers (no type wrapper)", function()
      assert.equals("42", serialization.serializeNaturalJSON(42))
      assert.equals("-100", serialization.serializeNaturalJSON(-100))
      assert.equals("0", serialization.serializeNaturalJSON(0))
    end)

    it("should serialize floats as plain numbers", function()
      local result = serialization.serializeNaturalJSON(3.14)
      assert.is_not_nil(result:match("^3%.14"))
    end)

    it("should serialize special float values as uppercase strings", function()
      assert.equals('"NAN"', serialization.serializeNaturalJSON(0/0))
      assert.equals('"INF"', serialization.serializeNaturalJSON(math.huge))
      assert.equals('"-INF"', serialization.serializeNaturalJSON(-math.huge))
    end)

    it("should serialize functions as <FUNCTION> string", function()
      assert.equals('"<FUNCTION>"', serialization.serializeNaturalJSON(function() end))
    end)

    it("should handle nil_as_empty_str option", function()
      assert.equals("", serialization.serializeNaturalJSON(nil, true))
      assert.equals("null", serialization.serializeNaturalJSON(nil, false))
    end)
  end)

  describe("serializeTableNaturalJSON", function()
    it("should serialize empty table as empty array", function()
      assert.equals("[]", serialization.serializeTableNaturalJSON({}))
    end)

    it("should serialize sequence tables as JSON arrays", function()
      local result = serialization.serializeTableNaturalJSON({"a", "b", "c"})
      assert.equals('["a","b","c"]', result)
    end)

    it("should serialize sequence with numbers (integers as plain numbers)", function()
      local result = serialization.serializeTableNaturalJSON({1, 2, 3})
      assert.equals("[1,2,3]", result)
    end)

    it("should serialize map tables as JSON objects", function()
      local result = serialization.serializeTableNaturalJSON({a = 1})
      assert.equals('{"a":1}', result)
    end)

    it("should serialize mixed tables as objects (since they're not pure sequences)", function()
      local result = serialization.serializeTableNaturalJSON({1, 2, a = "test"})
      -- Mixed tables are not pure sequences, so they become objects
      assert.is_not_nil(result:match('^{'))
      assert.is_not_nil(result:match('"a":"test"'))
    end)

    it("should serialize nested tables", function()
      local result = serialization.serializeTableNaturalJSON({{1, 2}, {3, 4}})
      assert.equals("[[1,2],[3,4]]", result)
    end)

    it("should serialize nested objects", function()
      local result = serialization.serializeTableNaturalJSON({outer = {inner = "value"}})
      assert.equals('{"outer":{"inner":"value"}}', result)
    end)

    it("should throw an error for non-table input", function()
      assert.has_error(function() serialization.serializeTableNaturalJSON("not a table") end)
      assert.has_error(function() serialization.serializeTableNaturalJSON(123) end)
    end)

    it("should throw an error for circular references", function()
      local t = {1, 2, 3}
      t.self = t
      assert.has_error(function() serialization.serializeTableNaturalJSON(t) end, "recursive table")
    end)

    it("should handle nil_as_empty_str in sequences", function()
      local result_null = serialization.serializeTableNaturalJSON({1, nil, 3}, false)
      local result_empty = serialization.serializeTableNaturalJSON({1, nil, 3}, true)
      assert.is_not_nil(result_null:match("null"))
      assert.is_not_nil(result_empty:match('""'))
    end)

    it("should stringify number keys for objects", function()
      -- Non-sequence table with numeric key
      local result = serialization.serializeTableNaturalJSON({[10] = "ten", [20] = "twenty"})
      assert.is_not_nil(result:match('"10"'))
      assert.is_not_nil(result:match('"20"'))
    end)

    it("should stringify boolean keys for objects", function()
      local result = serialization.serializeTableNaturalJSON({[true] = "yes", [false] = "no"})
      assert.is_not_nil(result:match('"true"'))
      assert.is_not_nil(result:match('"false"'))
    end)

    it("should stringify special float keys", function()
      local result = serialization.serializeTableNaturalJSON({[math.huge] = "inf_val"})
      assert.is_not_nil(result:match('"INF"'))
    end)

    it("should stringify table keys", function()
      local key = {a = 1}
      local result = serialization.serializeTableNaturalJSON({[key] = "value"})
      -- Table key becomes stringified JSON
      assert.is_not_nil(result:match('%{"'))
    end)

    it("should produce valid JSON without trailing commas", function()
      local test_cases = {
        {},
        {1},
        {a = 1},
        {1, 2, 3},
        {a = 1, b = 2},
      }
      for _, t in ipairs(test_cases) do
        local result = serialization.serializeTableNaturalJSON(t)
        assert.is_nil(result:match(",%]"), "Should not have trailing comma in array: " .. result)
        assert.is_nil(result:match(",%}"), "Should not have trailing comma in object: " .. result)
        assert.is_nil(result:match("%[,"), "Should not have leading comma after [: " .. result)
        assert.is_nil(result:match("{,"), "Should not have leading comma after {: " .. result)
      end
    end)

    it("should sort object keys for consistent output", function()
      local result = serialization.serializeTableNaturalJSON({z = 1, a = 2, m = 3})
      local a_pos = result:find('"a"')
      local m_pos = result:find('"m"')
      local z_pos = result:find('"z"')
      assert.is_true(a_pos < m_pos)
      assert.is_true(m_pos < z_pos)
    end)

    it("should handle sparse sequences as arrays with nulls", function()
      -- Create sparse sequence: {[1]="a", [3]="c"} with size 3
      local t = {[1] = "a", [3] = "c"}
      local result = serialization.serializeTableNaturalJSON(t)
      assert.equals('["a",null,"c"]', result)
    end)

    it("should handle special values in arrays", function()
      local result = serialization.serializeTableNaturalJSON({math.huge, 0/0, -math.huge})
      assert.equals('["INF","NAN","-INF"]', result)
    end)

    it("should handle special values in objects", function()
      local result = serialization.serializeTableNaturalJSON({inf = math.huge, nan = 0/0})
      assert.is_not_nil(result:match('"inf":"INF"'))
      assert.is_not_nil(result:match('"nan":"NAN"'))
    end)

    it("should handle functions in arrays", function()
      local result = serialization.serializeTableNaturalJSON({function() end, "test"})
      assert.equals('["<FUNCTION>","test"]', result)
    end)

    it("should handle functions in objects", function()
      local result = serialization.serializeTableNaturalJSON({callback = function() end})
      assert.equals('{"callback":"<FUNCTION>"}', result)
    end)
  end)

  describe("serializeTableNaturalJSON MAX_TABLE_DEPTH", function()
    local function createNestedTable(depth)
      local t = {value = "leaf"}
      for _ = 1, depth - 1 do
        t = {nested = t}
      end
      return t
    end

    it("should serialize table at depth 10 (at max)", function()
      local t = createNestedTable(10)
      local result = serialization.serializeTableNaturalJSON(t, false, nil, 0)
      assert.is_not_nil(result)
      assert.is_not_nil(result:match("leaf"))
    end)

    it("should error at depth 11", function()
      local t = createNestedTable(11)
      assert.has_error(function()
        serialization.serializeTableNaturalJSON(t, false, nil, 0)
      end, "Maximal depth reached!")
    end)
  end)

  describe("module API", function()
    describe("getVersion", function()
      it("should return a version string", function()
        local version = serialization.getVersion()
        assert.is_string(version)
        assert.matches("^%d+%.%d+%.%d+$", version)
      end)
    end)

    describe("callable API", function()
      it("should return version when called with 'version'", function()
        local version = serialization("version")
        assert.is_not_nil(version)
        -- Version is a semver object
        assert.are.equal(serialization.getVersion(), tostring(version))
      end)

      it("should call API functions when called with function name", function()
        local result = serialization("serialize", 42)
        assert.are.equal("42", result)
      end)

      it("should error on unknown operation", function()
        assert.has_error(function()
          serialization("nonexistent_operation")
        end, "Unknown operation: nonexistent_operation")
      end)
    end)

    describe("__tostring", function()
      it("should return module name and version", function()
        local str = tostring(serialization)
        assert.is_string(str)
        assert.matches("^serialization version %d+%.%d+%.%d+$", str)
      end)
    end)
  end)
end)
