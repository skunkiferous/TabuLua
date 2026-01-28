-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each
local pending = busted.pending

local predicates = require("predicates")
local isMixedTable = predicates.isMixedTable
local isCallable = predicates.isCallable
local isValidASCII = predicates.isValidASCII
local isValidUTF8 = predicates.isValidUTF8
local isValidRegex = predicates.isValidRegex

describe("predicates", function()
  describe("isBasic", function()
    it("returns true for basic types", function()
      assert.is_true(predicates.isBasic(nil))
      assert.is_true(predicates.isBasic(true))
      assert.is_true(predicates.isBasic(false))
      assert.is_true(predicates.isBasic(42))
      assert.is_true(predicates.isBasic("string"))
    end)

    it("returns false for non-basic types", function()
      assert.is_false(predicates.isBasic({}))
      assert.is_false(predicates.isBasic(function() end))
    end)
  end)

  describe("isBlankStr", function()
    it("returns true for blank strings", function()
      assert.is_true(predicates.isBlankStr(""))
      assert.is_true(predicates.isBlankStr("  "))
      assert.is_true(predicates.isBlankStr("\t\n"))
    end)

    it("returns false for non-blank strings and non-strings", function()
      assert.is_false(predicates.isBlankStr("a"))
      assert.is_false(predicates.isBlankStr(" a "))
      assert.is_false(predicates.isBlankStr(nil))
      assert.is_false(predicates.isBlankStr(42))
    end)
  end)

  describe("isBoolean", function()
    it("returns true for booleans", function()
      assert.is_true(predicates.isBoolean(true))
      assert.is_true(predicates.isBoolean(false))
    end)

    it("returns false for non-booleans", function()
      assert.is_false(predicates.isBoolean(nil))
      assert.is_false(predicates.isBoolean(0))
      assert.is_false(predicates.isBoolean("true"))
    end)
  end)

  describe("isDefault", function()
    it("returns true for default values", function()
      assert.is_true(predicates.isDefault(nil))
      assert.is_true(predicates.isDefault(false))
      assert.is_true(predicates.isDefault(0))
      assert.is_true(predicates.isDefault(0.0))
      assert.is_true(predicates.isDefault(""))
      assert.is_true(predicates.isDefault({}))
    end)

    it("returns false for non-default values", function()
      assert.is_false(predicates.isDefault(true))
      assert.is_false(predicates.isDefault(1))
      assert.is_false(predicates.isDefault("a"))
      assert.is_false(predicates.isDefault({1}))
    end)
  end)

  describe("isFileName", function()
    it("returns true for valid file names", function()
      assert.is_true(predicates.isFileName("file.txt"))
      assert.is_true(predicates.isFileName("my_file"))
      assert.is_true(predicates.isFileName("file-name"))
      assert.is_true(predicates.isFileName("file123"))
      assert.is_true(predicates.isFileName(".gitignore"))
      assert.is_true(predicates.isFileName("file.tar.gz"))
    end)

    it("returns true for unicode file names", function()
      assert.is_true(predicates.isFileName("文件.txt"))
      assert.is_true(predicates.isFileName("файл.doc"))
      assert.is_true(predicates.isFileName("αρχείο.pdf"))
      assert.is_true(predicates.isFileName("日本語ファイル"))
    end)

    it("returns false for empty or whitespace names", function()
      assert.is_false(predicates.isFileName(""))
      assert.is_false(predicates.isFileName("file "))
      assert.is_false(predicates.isFileName("file."))
    end)

    it("returns false for names with path separators", function()
      assert.is_false(predicates.isFileName("file/name"))
      assert.is_false(predicates.isFileName("file\\name"))
    end)

    it("returns false for names with invalid characters", function()
      assert.is_false(predicates.isFileName("file:name"))
      assert.is_false(predicates.isFileName("file<name"))
      assert.is_false(predicates.isFileName("file>name"))
      assert.is_false(predicates.isFileName("file|name"))
      assert.is_false(predicates.isFileName("file?name"))
      assert.is_false(predicates.isFileName("file*name"))
      assert.is_false(predicates.isFileName('file"name'))
    end)

    it("returns false for Windows reserved names", function()
      assert.is_false(predicates.isFileName("CON"))
      assert.is_false(predicates.isFileName("con"))
      assert.is_false(predicates.isFileName("Con"))
      assert.is_false(predicates.isFileName("PRN"))
      assert.is_false(predicates.isFileName("AUX"))
      assert.is_false(predicates.isFileName("NUL"))
      assert.is_false(predicates.isFileName("COM1"))
      assert.is_false(predicates.isFileName("LPT1"))
    end)

    it("returns false for Windows reserved names with extensions", function()
      assert.is_false(predicates.isFileName("CON.txt"))
      assert.is_false(predicates.isFileName("con.txt"))
      assert.is_false(predicates.isFileName("PRN.doc"))
      assert.is_false(predicates.isFileName("AUX.tar.gz"))
      assert.is_false(predicates.isFileName("NUL.anything"))
      assert.is_false(predicates.isFileName("COM1.log"))
      assert.is_false(predicates.isFileName("LPT1.out"))
    end)

    it("returns false for triple dots", function()
      assert.is_false(predicates.isFileName("file...txt"))
    end)
  end)

  describe("isFullSeq", function()
    it("returns true for full sequences", function()
      assert.is_true(predicates.isFullSeq({}))
      assert.is_true(predicates.isFullSeq({1, 2, 3}))
    end)

    it("returns false for non-full sequences", function()
      assert.is_false(predicates.isFullSeq({a=1}))
      assert.is_false(predicates.isFullSeq({1, 2, nil, 4}))
    end)
  end)

  describe("isIdentifier", function()
    it("returns true for valid identifiers", function()
      assert.is_true(predicates.isIdentifier("var"))
      assert.is_true(predicates.isIdentifier("_var"))
    end)

    it("returns false for invalid identifiers", function()
      assert.is_false(predicates.isIdentifier("1var"))
      assert.is_false(predicates.isIdentifier("var-name"))
    end)
  end)

  describe("isInteger", function()
    it("returns true for integers", function()
      assert.is_true(predicates.isInteger(0))
      assert.is_true(predicates.isInteger(42))
      assert.is_true(predicates.isInteger(-1))
    end)

    it("returns false for non-integers", function()
      assert.is_false(predicates.isInteger(3.14))
      assert.is_false(predicates.isInteger("42"))
    end)
  end)

  describe("isIntegerValue", function()
    it("returns true for integer values", function()
      assert.is_true(predicates.isIntegerValue(0))
      assert.is_true(predicates.isIntegerValue(42))
      assert.is_true(predicates.isIntegerValue(-1))
      assert.is_true(predicates.isIntegerValue(42.0))
    end)

    it("returns false for non-integer values", function()
      assert.is_false(predicates.isIntegerValue(3.14))
      assert.is_false(predicates.isIntegerValue("42"))
    end)
  end)

  describe("isName", function()
    it("returns true for valid names", function()
      assert.is_true(predicates.isName("var"))
      assert.is_true(predicates.isName("var_name"))
      assert.is_true(predicates.isName("var.name"))
    end)

    it("returns false for invalid names", function()
      assert.is_false(predicates.isName("1var"))
      assert.is_false(predicates.isName("var-name"))
      assert.is_false(predicates.isName("var.1name"))
    end)
  end)

  describe("isNonBlankStr", function()
    it("returns true for non-blank strings", function()
      assert.is_true(predicates.isNonBlankStr("a"))
      assert.is_true(predicates.isNonBlankStr(" a "))
    end)

    it("returns false for blank strings and non-strings", function()
      assert.is_false(predicates.isNonBlankStr(""))
      assert.is_false(predicates.isNonBlankStr("  "))
      assert.is_false(predicates.isNonBlankStr(nil))
    end)
  end)

  describe("isNonDefault", function()
    it("returns true for non-default values", function()
      assert.is_true(predicates.isNonDefault(true))
      assert.is_true(predicates.isNonDefault(1))
      assert.is_true(predicates.isNonDefault("a"))
      assert.is_true(predicates.isNonDefault({1}))
    end)

    it("returns false for default values", function()
      assert.is_false(predicates.isNonDefault(nil))
      assert.is_false(predicates.isNonDefault(false))
      assert.is_false(predicates.isNonDefault(0))
      assert.is_false(predicates.isNonDefault(0.0))
      assert.is_false(predicates.isNonDefault(""))
      assert.is_false(predicates.isNonDefault({}))
    end)
  end)

  describe("isNonEmptyStr", function()
    it("returns true for non-empty strings", function()
      assert.is_true(predicates.isNonEmptyStr("a"))
      assert.is_true(predicates.isNonEmptyStr(" "))
    end)

    it("returns false for empty strings and non-strings", function()
      assert.is_false(predicates.isNonEmptyStr(""))
      assert.is_false(predicates.isNonEmptyStr(nil))
    end)
  end)

  describe("isNonEmptyTable", function()
    it("returns true for non-empty tables", function()
      assert.is_true(predicates.isNonEmptyTable({1}))
      assert.is_true(predicates.isNonEmptyTable({a=1}))
    end)

    it("returns false for empty tables and non-tables", function()
      assert.is_false(predicates.isNonEmptyTable({}))
      assert.is_false(predicates.isNonEmptyTable(nil))
    end)
  end)

  describe("isNonZeroInteger", function()
    it("returns true for non-zero integers", function()
      assert.is_true(predicates.isNonZeroInteger(1))
      assert.is_true(predicates.isNonZeroInteger(-1))
    end)

    it("returns false for zero and non-integers", function()
      assert.is_false(predicates.isNonZeroInteger(0))
      assert.is_false(predicates.isNonZeroInteger(3.14))
    end)
  end)

  describe("isNonZeroNumber", function()
    it("returns true for non-zero numbers", function()
      assert.is_true(predicates.isNonZeroNumber(1))
      assert.is_true(predicates.isNonZeroNumber(-1))
      assert.is_true(predicates.isNonZeroNumber(3.14))
    end)

    it("returns false for zero and non-numbers", function()
      assert.is_false(predicates.isNonZeroNumber(0))
      assert.is_false(predicates.isNonZeroNumber("1"))
    end)
  end)

  describe("isNumber", function()
    it("returns true for numbers", function()
      assert.is_true(predicates.isNumber(0))
      assert.is_true(predicates.isNumber(3.14))
    end)

    it("returns false for non-numbers", function()
      assert.is_false(predicates.isNumber("42"))
      assert.is_false(predicates.isNumber(nil))
    end)
  end)

  describe("isPath", function()
    it("returns true for valid paths", function()
      assert.is_true(predicates.isPath("file.txt"))
      assert.is_true(predicates.isPath("dir/file.txt"))
    end)

    it("returns false for invalid paths", function()
      assert.is_false(predicates.isPath(""))
      assert.is_false(predicates.isPath("file:name"))
      -- Windows path syntax is NOT supported
      assert.is_false(predicates.isPath("C:/file.txt"))
      assert.is_false(predicates.isPath("dir\\file.txt"))
    end)
  end)

  describe("isPositiveInteger", function()
    it("returns true for positive integers", function()
      assert.is_true(predicates.isPositiveInteger(1))
      assert.is_true(predicates.isPositiveInteger(42))
    end)

    it("returns false for non-positive integers and non-integers", function()
      assert.is_false(predicates.isPositiveInteger(0))
      assert.is_false(predicates.isPositiveInteger(-1))
      assert.is_false(predicates.isPositiveInteger(3.14))
    end)
  end)

  describe("isPositiveNumber", function()
    it("returns true for positive numbers", function()
      assert.is_true(predicates.isPositiveNumber(1))
      assert.is_true(predicates.isPositiveNumber(3.14))
    end)

    it("returns false for non-positive numbers and non-numbers", function()
      assert.is_false(predicates.isPositiveNumber(0))
      assert.is_false(predicates.isPositiveNumber(-1))
      assert.is_false(predicates.isPositiveNumber("1"))
    end)
  end)

  describe("isString", function()
    it("returns true for strings", function()
      assert.is_true(predicates.isString(""))
      assert.is_true(predicates.isString("abc"))
    end)

    it("returns false for non-strings", function()
      assert.is_false(predicates.isString(nil))
      assert.is_false(predicates.isString(42))
    end)
  end)

  describe("isTable", function()
    it("returns true for tables", function()
      assert.is_true(predicates.isTable({}))
      assert.is_true(predicates.isTable({1, 2, 3}))
    end)

    it("returns false for non-tables", function()
      assert.is_false(predicates.isTable(nil))
      assert.is_false(predicates.isTable("table"))
    end)
  end)

  describe("isTrue", function()
    it("returns true for true", function()
      assert.is_true(predicates.isTrue(true))
    end)

    it("returns false for anything else", function()
      assert.is_false(predicates.isTrue(""))
      assert.is_false(predicates.isTrue("a"))
      assert.is_false(predicates.isTrue(false))
      assert.is_false(predicates.isTrue(nil))
      assert.is_false(predicates.isTrue(42))
      assert.is_false(predicates.isTrue({}))
    end)
  end)

  describe("isFalse", function()
    it("returns true for false", function()
      assert.is_true(predicates.isFalse(false))
    end)

    it("returns false for anything else", function()
      assert.is_false(predicates.isFalse(""))
      assert.is_false(predicates.isFalse("a"))
      assert.is_false(predicates.isFalse(true))
      assert.is_false(predicates.isFalse(nil))
      assert.is_false(predicates.isFalse(42))
      assert.is_false(predicates.isFalse({}))
    end)
  end)

  describe("isVersion", function()
    it("returns true for valid version strings", function()
      assert.is_true(predicates.isVersion("1.0.0"))
      assert.is_true(predicates.isVersion("0.1.0"))
    end)

    it("returns false for invalid version strings and non-strings", function()
      assert.is_false(predicates.isVersion("1.0"))
      assert.is_false(predicates.isVersion("1.0.a"))
      assert.is_false(predicates.isVersion(1))
    end)
  end)

  describe("isComparable", function()
    it("returns true for string and number", function()
      assert.is_true(predicates.isComparable(""))
      assert.is_true(predicates.isComparable("a"))
      assert.is_true(predicates.isComparable(42))
      assert.is_true(predicates.isComparable(-123.456))
    end)

    it("returns false for anything else", function()
      assert.is_false(predicates.isComparable(true))
      assert.is_false(predicates.isComparable(false))
      assert.is_false(predicates.isComparable(nil))
      assert.is_false(predicates.isComparable({}))
      assert.is_false(predicates.isComparable(function() end))
    end)
  end)

  describe("getPredName", function()
    it("returns the name for predicates", function()
      assert.same("isVersion", predicates.getPredName(predicates.isVersion))
      assert.same("isTable", predicates.getPredName(predicates.isTable))
    end)

    it("returns nil for anything else", function()
      assert.is_nil(predicates.getPredName(""))
      assert.is_nil(predicates.getPredName("a"))
      assert.is_nil(predicates.getPredName(false))
      assert.is_nil(predicates.getPredName(nil))
      assert.is_nil(predicates.getPredName(42))
      assert.is_nil(predicates.getPredName({}))
    end)
  end)

  describe("isValueKeyword", function()
    it("returns true for nil, false and true", function()
      assert.is_true(predicates.isValueKeyword("nil"))
      assert.is_true(predicates.isValueKeyword("false"))
      assert.is_true(predicates.isValueKeyword("true"))
    end)

    it("returns false for anything else", function()
      assert.is_false(predicates.isValueKeyword("abc"))
      assert.is_false(predicates.isValueKeyword(42))
      assert.is_false(predicates.isValueKeyword(-123.456))
      assert.is_false(predicates.isValueKeyword(true))
      assert.is_false(predicates.isValueKeyword(false))
      assert.is_false(predicates.isValueKeyword(nil))
      assert.is_false(predicates.isValueKeyword({}))
      assert.is_false(predicates.isValueKeyword(function() end))
    end)
  end)

  describe("isPercent", function()
    it("returns true for nil, false and true", function()
      assert.is_true(predicates.isPercent("42%"), "42%")
      assert.is_true(predicates.isPercent("12.34%"), "12.34%")
      assert.is_true(predicates.isPercent("-42%"), "-42%")
      assert.is_true(predicates.isPercent("-12.34%"), "-12.34%")
      assert.is_true(predicates.isPercent("12/34"), "12/34")
      assert.is_true(predicates.isPercent("-12/34"), "-12/34")
    end)

    it("returns false for anything else", function()
      assert.is_false(predicates.isPercent("12.%"), "12.%")
      assert.is_false(predicates.isPercent(".34%"), ".34%")
      assert.is_false(predicates.isPercent("-12.%"), "-12.%")
      assert.is_false(predicates.isPercent("-.34%"), "-.34%")
      assert.is_false(predicates.isPercent("12/"), "12/")
      assert.is_false(predicates.isPercent("12/000"), "12/000")
      assert.is_false(predicates.isPercent("-12/0"), "-12/0")
      assert.is_false(predicates.isPercent("12.34/56"), "12.34/56")
      assert.is_false(predicates.isPercent("-12/34.56"), "-12/34.56")
      assert.is_false(predicates.isPercent("abc"), "abc")
      assert.is_false(predicates.isPercent(true), "true")
      assert.is_false(predicates.isPercent(false), "false")
      assert.is_false(predicates.isPercent(nil), "nil")
      assert.is_false(predicates.isPercent({}), "{}")
      assert.is_false(predicates.isPercent(function() end), "function")
    end)
  end)
  
  describe("isMixedTable", function()
    it("should reject non-table values", function()
        assert.is_false(isMixedTable(nil))
        assert.is_false(isMixedTable(42))
        assert.is_false(isMixedTable("string"))
        assert.is_false(isMixedTable(true))
        assert.is_false(isMixedTable(function() end))
    end)

    it("should reject pure sequences", function()
        assert.is_false(isMixedTable({}))
        assert.is_false(isMixedTable({1, 2, 3}))
        assert.is_false(isMixedTable({"a", "b", "c"}))
    end)

    it("should reject pure maps", function()
        assert.is_false(isMixedTable({x = 1}))
        assert.is_false(isMixedTable({foo = "bar", baz = "qux"}))
        assert.is_false(isMixedTable({[5] = "five", [7] = "seven"}))
    end)

    it("should accept tables with both sequence and map parts", function()
        assert.is_true(isMixedTable({1, 2, 3, x = "extra"}))
        assert.is_true(isMixedTable({1, 2, [5] = "five"}))
        assert.is_true(isMixedTable({"a", "b", foo = "bar"}))
        assert.is_true(isMixedTable({1, nil, 3, extra = "value"}))
    end)
  end)

  describe("isValidHttpUrl", function()
    it("returns true for valid HTTP(S) URLs", function()
      assert.is_true(predicates.isValidHttpUrl("http://example.com"), "http://example.com")
      assert.is_true(predicates.isValidHttpUrl("https://example.com"), "https://example.com")
      assert.is_true(predicates.isValidHttpUrl("https://sub.example.com"), "https://sub.example.com")
      assert.is_true(predicates.isValidHttpUrl("https://example.com:8080"), "https://example.com:8080")
      assert.is_true(predicates.isValidHttpUrl("https://example.com:8080/path"), "https://example.com:8080/path")
      assert.is_true(predicates.isValidHttpUrl("https://example.com:8080/path?q=1"), "https://example.com:8080/path?q=1")
      assert.is_true(predicates.isValidHttpUrl("https://example.com/page#section"), "https://example.com/page#section")
      assert.is_true(predicates.isValidHttpUrl("https://example.com/page?q=1#top"), "https://example.com/page?q=1#top")
    end)

    it("returns false for anything else", function()
      assert.is_false(predicates.isValidHttpUrl(42), "42")
      assert.is_false(predicates.isValidHttpUrl("ftp://example.com"), "ftp://example.com")
      assert.is_false(predicates.isValidHttpUrl("not-a-url"), "not-a-url")
      assert.is_false(predicates.isValidHttpUrl("http://"), "http://")
      assert.is_false(predicates.isValidHttpUrl("http://example.com:"), "http://example.com:")
      assert.is_false(predicates.isValidHttpUrl("http://example.com:abc"), "http://example.com:abc")
    end)
  end)

  describe("isCallable", function()
  
    -- Test regular functions
    it("should return true for regular functions", function()
        local fn = function() end
        assert.is_true(isCallable(fn))
    end)
    
    -- Test built-in functions
    it("should return true for built-in functions", function()
        assert.is_true(isCallable(print))
        assert.is_true(isCallable(type))
        assert.is_true(isCallable(assert))
    end)
    
    -- Test callable tables
    it("should return true for tables with __call metamethod", function()
        local t = {}
        setmetatable(t, {__call = function() end})
        assert.is_true(isCallable(t))
    end)
    
    -- Test non-callable tables
    it("should return false for regular tables", function()
        local t = {}
        assert.is_false(isCallable(t))
    end)
    
    it("should return false for tables with metatable but no __call", function()
        local t = {}
        setmetatable(t, {__index = {}})
        assert.is_false(isCallable(t))
    end)
    
    it("should return false for tables with non-function __call", function()
        local t = {}
        setmetatable(t, {__call = "not a function"})
        assert.is_false(isCallable(t))
    end)
    
    -- Test other value types
    it("should return false for strings", function()
        assert.is_false(isCallable("test"))
    end)
    
    it("should return false for numbers", function()
        assert.is_false(isCallable(42))
        assert.is_false(isCallable(3.14))
    end)
    
    it("should return false for booleans", function()
        assert.is_false(isCallable(true))
        assert.is_false(isCallable(false))
    end)
    
    it("should return false for nil", function()
        assert.is_false(isCallable(nil))
    end)
    
    -- Test protected metatables
    it("should handle protected metatables gracefully", function()
        -- Create a table with a protected metatable (can't be accessed with getmetatable)
        if newproxy then
            local t = newproxy(true) or {}
            if getmetatable(t) then  -- Only test if we can actually create protected metatables
                assert.is_false(isCallable(t))
            end
        end
    end)
  end)

  describe("UTF-8 Validator", function()
    it("should return true for valid UTF-8 strings", function()
        assert.is_true(isValidUTF8("Hello"))  -- ASCII
        assert.is_true(isValidUTF8("สวัสดี"))  -- Thai
        assert.is_true(isValidUTF8("こんにちは")) -- Japanese
        assert.is_true(isValidUTF8("🌍🌎🌏"))    -- Emoji
        assert.is_true(isValidUTF8(""))        -- Empty string
    end)

    it("should return false for invalid UTF-8 sequences", function()
        -- Create some invalid UTF-8 sequences
        assert.is_false(isValidUTF8(string.char(0xFF)))         -- Invalid single byte
        assert.is_false(isValidUTF8(string.char(0xC0, 0x00)))   -- Invalid 2-byte sequence
        assert.is_false(isValidUTF8(string.char(0xE0, 0x00)))   -- Incomplete sequence
    end)

    it("should return false for non-string inputs", function()
        assert.is_false(isValidUTF8(nil))
        assert.is_false(isValidUTF8(123))
        assert.is_false(isValidUTF8(true))
        assert.is_false(isValidUTF8({}))
        assert.is_false(isValidUTF8(function() end))
    end)

    it("should handle edge cases", function()
        -- Max valid code points
        assert.is_true(isValidUTF8("\u{7F}"))      -- Max 1-byte
        assert.is_true(isValidUTF8("\u{7FF}"))     -- Max 2-byte
        assert.is_true(isValidUTF8("\u{FFFF}"))    -- Max 3-byte
        assert.is_true(isValidUTF8("\u{10FFFF}"))  -- Max 4-byte

        -- Mixed valid content with invalid sequences
        assert.is_false(isValidUTF8("Hello" .. string.char(0xFF) .. "World"))
    end)
  end)

  describe("ASCII Validator", function()
    it("should return true for valid ASCII strings", function()
        assert.is_true(isValidASCII("Hello"))
        assert.is_true(isValidASCII("Hello, World!"))
        assert.is_true(isValidASCII("123 ABC"))
        assert.is_true(isValidASCII(""))  -- Empty string
        assert.is_true(isValidASCII("\t\n\r"))  -- Control characters within ASCII range
        assert.is_true(isValidASCII(string.char(0)))  -- NUL character
        assert.is_true(isValidASCII(string.char(127)))  -- DEL character (max ASCII)
    end)

    it("should return false for non-ASCII strings", function()
        assert.is_false(isValidASCII("สวัสดี"))  -- Thai
        assert.is_false(isValidASCII("こんにちは"))  -- Japanese
        assert.is_false(isValidASCII("🌍🌎🌏"))  -- Emoji
        assert.is_false(isValidASCII("café"))  -- Accented character
        assert.is_false(isValidASCII(string.char(128)))  -- First non-ASCII byte
        assert.is_false(isValidASCII(string.char(255)))  -- High byte
        assert.is_false(isValidASCII("Hello" .. string.char(200) .. "World"))  -- Mixed
    end)

    it("should return false for non-string inputs", function()
        assert.is_false(isValidASCII(nil))
        assert.is_false(isValidASCII(123))
        assert.is_false(isValidASCII(true))
        assert.is_false(isValidASCII({}))
        assert.is_false(isValidASCII(function() end))
    end)
  end)

  describe("Regex Validator", function()
    it("should return true for valid regex strings", function()
      assert.is_true(isValidRegex("Hello"))
      assert.is_true(isValidRegex("%d"))
    end)

    it("should return false for invalid regex sequences", function()
        assert.is_false(isValidRegex("[invalid"))
    end)
  end)

  describe("testPredicate", function()
    it("should pass for valid predicates", function()
      -- A valid predicate always returns a boolean
      local validPredicate = function(v) return v == true end
      assert.has_no.errors(function()
        predicates.testPredicate(validPredicate, "validPredicate")
      end)
    end)

    it("should fail for predicates that return non-boolean", function()
      -- This predicate returns nil instead of false
      local badPredicate = function(v) if v then return true end end
      assert.has_error(function()
        predicates.testPredicate(badPredicate, "badPredicate")
      end)
    end)

    it("should fail for non-functions", function()
      assert.has_error(function()
        predicates.testPredicate("not a function", "notFunction")
      end)
      assert.has_error(function()
        predicates.testPredicate(42, "number")
      end)
      assert.has_error(function()
        predicates.testPredicate(nil, "nil")
      end)
    end)
  end)

  describe("module API", function()
    describe("getVersion", function()
      it("should return a version string", function()
        local version = predicates.getVersion()
        assert.is_string(version)
        assert.matches("^%d+%.%d+%.%d+$", version)
      end)
    end)

    describe("callable API", function()
      it("should return version when called with 'version'", function()
        local version = predicates("version")
        assert.is_not_nil(version)
        -- Version is a semver object
        assert.are.equal(predicates.getVersion(), tostring(version))
      end)

      it("should call API functions when called with function name", function()
        local result = predicates("isNumber", 42)
        assert.is_true(result)
      end)

      it("should error on unknown operation", function()
        assert.has_error(function()
          predicates("nonexistent_operation")
        end, "Unknown operation: nonexistent_operation")
      end)
    end)

    describe("__tostring", function()
      it("should return module name and version", function()
        local str = tostring(predicates)
        assert.is_string(str)
        assert.matches("^predicates version %d+%.%d+%.%d+$", str)
      end)
    end)
  end)
end)