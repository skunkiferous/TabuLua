-- string_utils_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local string_utils = require("string_utils")

describe("string_utils", function()
  describe("parseVersion", function()
    it("should parse valid version strings", function()
      local result = string_utils.parseVersion("1.2.3")
      assert.are.same({major = 1, minor = 2, patch = 3}, result)
    end)

    it("should return nil for invalid version strings", function()
      assert.is_nil(string_utils.parseVersion("1.2"))
      assert.is_nil(string_utils.parseVersion("1.2.3.4"))
      assert.is_nil(string_utils.parseVersion("a.b.c"))
    end)

    it("should handle version numbers with leading zeros", function()
      local result = string_utils.parseVersion("01.02.03")
      assert.are.same({major = 1, minor = 2, patch = 3}, result)
    end)

    it("should return nil for non-string inputs", function()
      assert.is_nil(string_utils.parseVersion(123))
      assert.is_nil(string_utils.parseVersion(nil))
      assert.is_nil(string_utils.parseVersion({}))
    end)
  end)

  describe("trim", function()
    it("should trim whitespace from both ends of a string", function()
      assert.are.equal("hello", string_utils.trim("  hello  "))
      assert.are.equal("world", string_utils.trim("world  "))
      assert.are.equal("test", string_utils.trim("  test"))
      assert.are.equal("no trim", string_utils.trim("no trim"))
    end)

    it("should trim tabs", function()
      assert.are.equal("hello", string_utils.trim("\thello\t"))
      assert.are.equal("hello", string_utils.trim("\t\thello"))
      assert.are.equal("hello", string_utils.trim("hello\t\t"))
    end)

    it("should trim newlines", function()
      assert.are.equal("hello", string_utils.trim("\nhello\n"))
      assert.are.equal("hello", string_utils.trim("\r\nhello\r\n"))
      assert.are.equal("hello", string_utils.trim("\rhello\r"))
    end)

    it("should trim mixed whitespace characters", function()
      assert.are.equal("hello", string_utils.trim(" \t\n\r hello \r\n\t "))
      assert.are.equal("a\tb", string_utils.trim("  a\tb  "))
      assert.are.equal("a\nb", string_utils.trim("\t\ta\nb\n\n"))
    end)

    it("should error on nil input", function()
      assert.has_error(function() string_utils.trim(nil) end)
    end)

    it("should error on non-string input", function()
      assert.has_error(function() string_utils.trim(123) end)
      assert.has_error(function() string_utils.trim({}) end)
      assert.has_error(function() string_utils.trim(true) end)
    end)
  end)

  describe("split", function()
    it("should split a string by delimiter", function()
      assert.are.same({"a", "b", "c"}, string_utils.split("a;b;c", ";"))
      assert.are.same({"", "a", "b", ""}, string_utils.split("\ta\tb\t"))
      assert.are.same({"a", "", "b", "c"}, string_utils.split("a\t\tb\tc", "\t"))
      assert.are.same({""}, string_utils.split("", "\t"))
      assert.are.same({"", ""}, string_utils.split("\t", "\t"))
    end)

    it("should error on nil source", function()
      assert.has_error(function() string_utils.split(nil) end)
    end)

    it("should error on non-string source", function()
      assert.has_error(function() string_utils.split(123) end)
      assert.has_error(function() string_utils.split({}) end)
    end)

    it("should error on non-string delimiter", function()
      assert.has_error(function() string_utils.split("abc", 123) end)
      assert.has_error(function() string_utils.split("abc", {}) end)
    end)
  end)

  describe("escapeText", function()
    it("should escape and unescape text for TSV", function()
      local original = "Hello\tWorld\nNew\\Line"
      local escaped = string_utils.escapeText(original)
      assert.are.equal("Hello\\tWorld\\nNew\\\\Line", escaped)
      assert.are.equal(original, string_utils.unescapeText(escaped))
    end)

    it("should normalize CRLF to LF", function()
      assert.are.equal("a\\nb", string_utils.escapeText("a\r\nb"))
      assert.are.equal("a\\nb\\nc", string_utils.escapeText("a\r\nb\r\nc"))
    end)

    it("should normalize CR to LF", function()
      assert.are.equal("a\\nb", string_utils.escapeText("a\rb"))
      assert.are.equal("a\\nb\\nc", string_utils.escapeText("a\rb\rc"))
    end)

    it("should handle mixed line endings", function()
      assert.are.equal("a\\nb\\nc\\nd", string_utils.escapeText("a\nb\rc\r\nd"))
    end)

    it("should error on nil input", function()
      assert.has_error(function() string_utils.escapeText(nil) end)
    end)

    it("should error on non-string input", function()
      assert.has_error(function() string_utils.escapeText(123) end)
      assert.has_error(function() string_utils.escapeText({}) end)
    end)
  end)

  describe("unescapeText", function()
    it("should unescape tab and newline sequences", function()
      assert.are.equal("a\tb", string_utils.unescapeText("a\\tb"))
      assert.are.equal("a\nb", string_utils.unescapeText("a\\nb"))
      assert.are.equal("a\\b", string_utils.unescapeText("a\\\\b"))
    end)

    it("should normalize CRLF to LF in result", function()
      assert.are.equal("a\nb", string_utils.unescapeText("a\r\nb"))
      assert.are.equal("a\nb\nc", string_utils.unescapeText("a\r\nb\r\nc"))
    end)

    it("should normalize CR to LF in result", function()
      assert.are.equal("a\nb", string_utils.unescapeText("a\rb"))
      assert.are.equal("a\nb\nc", string_utils.unescapeText("a\rb\rc"))
    end)

    it("should handle unknown escape sequences leniently", function()
      -- Unknown escapes just return the character after backslash
      assert.are.equal("ax", string_utils.unescapeText("a\\x"))
      assert.are.equal("a0", string_utils.unescapeText("a\\0"))
      assert.are.equal("ar", string_utils.unescapeText("a\\r"))
      assert.are.equal("a ", string_utils.unescapeText("a\\ "))
    end)

    it("should error on nil input", function()
      assert.has_error(function() string_utils.unescapeText(nil) end)
    end)

    it("should error on non-string input", function()
      assert.has_error(function() string_utils.unescapeText(123) end)
      assert.has_error(function() string_utils.unescapeText({}) end)
    end)
  end)

  describe("stringToIdentifier", function()
    local stringToIdentifier = string_utils.stringToIdentifier

    it("should test valid identifier characters", function()
      assert(stringToIdentifier("abc123") == "_abc123")
      assert(stringToIdentifier("ABC_123") == "_ABC_123")
    end)

    it("should test spaces", function()
      assert(stringToIdentifier("hello world") == "_hello0x20world")
    end)

    it("should test punctuation", function()
      assert(stringToIdentifier("test.txt") == "_test0x2Etxt")
      assert(stringToIdentifier("$") == "_0x24")
    end)

    it("should test empty string", function()
      assert(stringToIdentifier("") == "_")
    end)

    it("should test all ASCII characters", function()
      local all_ascii = ""
      for i = 0, 127 do
          all_ascii = all_ascii .. string.char(i)
      end
      assert(#stringToIdentifier(all_ascii) > #all_ascii)
    end)

    it("handles UTF-8 characters", function()
      assert.are.equal("_caf0xC30xA9", stringToIdentifier("café"))
    end)

    it("should error on nil input", function()
      assert.has_error(function() stringToIdentifier(nil) end)
    end)

    it("should error on non-string input", function()
      assert.has_error(function() stringToIdentifier(123) end)
      assert.has_error(function() stringToIdentifier({}) end)
    end)
  end)

  describe("module API", function()
    describe("getVersion", function()
      it("should return a version string", function()
        local version = string_utils.getVersion()
        assert.is_string(version)
        assert.matches("^%d+%.%d+%.%d+$", version)
      end)
    end)

    describe("callable API", function()
      it("should return version when called with 'version'", function()
        local version = string_utils("version")
        assert.is_not_nil(version)
        -- Version is a semver object
        assert.are.equal(string_utils.getVersion(), tostring(version))
      end)

      it("should call API functions when called with function name", function()
        local result = string_utils("trim", "  hello  ")
        assert.are.equal("hello", result)
      end)

      it("should error on unknown operation", function()
        assert.has_error(function()
          string_utils("nonexistent_operation")
        end, "Unknown operation: nonexistent_operation")
      end)
    end)

    describe("__tostring", function()
      it("should return module name and version", function()
        local str = tostring(string_utils)
        assert.is_string(str)
        assert.matches("^string_utils version %d+%.%d+%.%d+$", str)
      end)
    end)
  end)
end)
