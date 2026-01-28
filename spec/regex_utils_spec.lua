-- regex_utils_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local regex_utils = require("regex_utils")

describe("regex_utils", function()

    describe("translateLuaPatternToPCRE", function()
        local function translate(pattern)
            local result, err = regex_utils.translateLuaPatternToPCRE(pattern)
            --print(pattern, ' => ', tostring(result), err)
            return result, err
        end


        describe("basic input validation", function()
            it("should handle nil and empty input", function()
                local result, err = translate(nil)
                assert.is_nil(result)
                assert.equals("Pattern must be a non-empty string", err)

                result, err = translate("")
                assert.is_nil(result)
                assert.equals("Pattern must be a non-empty string", err)
            end)
        end)

        describe("character classes", function()
            it("should translate simple character classes", function()
                assert.same("\\d+", (translate("%d+")))
                assert.same("[[:alpha:]]", (translate("%a")))
                assert.same("\\s", (translate("%s")))
                assert.same("[a-zA-Z0-9]", (translate("%w")))
                assert.same("[\\w]", (translate("[%w_]")))
                assert.same("[\\w]", (translate("[_%w]")))
            end)

            it("should translate negated character classes", function()
                assert.same("\\D", (translate("%D")))
                assert.same("[^[:alpha:]]", (translate("%A")))
                assert.same("\\S", (translate("%S")))
                assert.same("[^a-zA-Z0-9]", (translate("%W")))
                assert.same("[^\\w]", (translate("[^_%w]")))
                assert.same("[^\\w]", (translate("[^%w_]")))
            end)

            it("should translate multiple character classes in a pattern", function()
                assert.same("\\d[[:alpha:]]\\s", (translate("%d%a%s")))
                assert.same("\\D[^[:alpha:]]\\S", (translate("%D%A%S")))
            end)

            it("should reject invalid character classes", function()
                local result, err = translate("%k")
                assert.is_nil(result)
                assert.matches("Invalid or unsupported character class", err)
            end)
        end)

        describe("custom character sets", function()
            it("should handle simple character sets", function()
                assert.same("[abc]", (translate("[abc]")))
                assert.same("[^abc]", (translate("[^abc]")))
            end)

            it("should catch unclosed character sets", function()
                local result, err = translate("[abc")
                assert.is_nil(result)
                assert.same("Invalid pattern: [abc", err)
            end)

            it("should catch nested character sets", function()
                local result, err = translate("[a[b]c]")
                assert.is_nil(result)
                assert.equals("Nested [] at position 3", err)
            end)
        end)

        describe("escaping special characters", function()
            it("should escape magic characters", function()
                assert.same("\\.", (translate("%.")))
                assert.same("\\+", (translate("%+")))
                assert.same("\\*", (translate("%*")))
                assert.same("\\?", (translate("%?")))
                assert.same("\\(", (translate("%(")))
                assert.same("\\)", (translate("%)")))
                assert.same("\\[", (translate("%[")))
                assert.same("\\]", (translate("%]")))
                assert.same("\\^", (translate("%^")))
                assert.same("\\$", (translate("%$")))
            end)

            it("should preserve literal percent signs", function()
                assert.same("%", (translate("%%")))
                assert.same("100%", (translate("100%%")))
            end)

            it("should catch unescaped magic characters", function()
                local result, err = translate("a$b")
                assert.is_nil(result)
                assert.matches("Unescaped magic character '$'", err)
            end)
        end)

        describe("anchors", function()
            it("should translate start and end anchors", function()
                assert.same("\\Aabc", (translate("^abc")))
                assert.same("abc\\Z", (translate("abc$")))
                assert.same("\\Aabc\\Z", (translate("^abc$")))
            end)
        end)

        describe("unsupported features", function()
            it("should reject balanced patterns", function()
                local result, err = translate("%b()")
                assert.is_nil(result)
                assert.matches("Balanced pattern match", err)
            end)

            it("should reject frontier patterns", function()
                local result, err = translate("%f[%w]")
                assert.is_nil(result)
                assert.matches("Frontier pattern", err)
            end)

            it("should reject capture references", function()
                local result, err = translate("(.)%1")
                assert.is_nil(result)
                assert.matches("Capture references", err)
            end)
        end)

        describe("complex patterns", function()
            it("should translate email pattern", function()
                local email_pattern = "^[A-Za-z0-9%.%%%+%-]+@[A-Za-z0-9%.%-_]+%.%w%w%w?$"
                local result = translate(email_pattern)
                assert.is_not_nil(result)
                -- Should be something like: \A[A-Za-z0-9\.%+\-]+@[A-Za-z0-9\.\-]+\.[A-Za-z0-9_]{3,4}\Z
                assert.matches("\\A.*\\Z", result)
                assert.matches("@", result)
            end)

            it("should translate identifier pattern", function()
                local id_pattern = "^%a[%w_]*$"
                local result = translate(id_pattern)
                assert.is_not_nil(result)
                -- Should be: \A[[:alpha:]][\\w_]*\Z
                assert.matches("\\A.*\\Z", result)
                assert.matches("[A-Za-z]", result)
                assert.matches("[A-Za-z0-9_]", result)
            end)

            it("should translate numeric patterns", function()
                local num_pattern = "^%-?%d+%.?%d*$"
                local result = translate(num_pattern)
                assert.is_not_nil(result)
                -- Should be: \A-?\d+\.?\d*\Z
                assert.matches("\\A.*\\Z", result)
                assert.matches("%-?", result)
                assert.matches("\\d+", result)
                assert.matches("\\.", result)
            end)
        end)

        describe("edge cases", function()
            it("should handle patterns with multiple escaped percents", function()
                assert.same("100%%", (translate("100%%%%")))
                assert.same("50% or 100%%", (translate("50%% or 100%%%%")))
            end)

            it("should handle consecutive special characters", function()
                assert.same("\\[\\]", (translate("%[%]")))
                assert.same("\\(\\)", (translate("%(%)")))
                assert.same("\\^\\$", (translate("%^%$")))
            end)

            it("should handle character classes next to special characters", function()
                assert.same("\\d\\.", (translate("%d%.")))
                assert.same("\\d\\+", (translate("%d%+")))
                assert.same("[[:alpha:]]\\?", (translate("%a%?")))
            end)

            it("should handle empty character sets as invalid", function()
                assert.is_nil((translate("[]")))
                assert.is_nil((translate("[^]")))
            end)
        end)
    end)

    describe("splitPatterns", function()
        -- Load the splitPatterns function
        local splitPatterns = regex_utils.splitPatterns

        describe("basic functionality", function()
            it("should split basic patterns", function()
                assert.same({"abc", "def", "ghi"}, splitPatterns("abc|def|ghi"))
            end)
    
            it("should handle single patterns", function()
                assert.same({"abc"}, splitPatterns("abc"))
            end)
    
            it("should handle patterns with spaces", function()
                assert.same({"abc ", " def", " ghi "}, splitPatterns("abc | def| ghi "))
            end)
    
            it("should preserve special Lua pattern characters", function()
                assert.same({"%d+", "%w+", "[a-z]+"}, splitPatterns("%d+|%w+|[a-z]+"))
            end)
        end)
    
        describe("escaped pipes", function()
            it("should handle escaped pipes", function()
                assert.same({"abc|def", "ghi"}, splitPatterns("abc%|def|ghi"))
            end)
    
            it("should handle multiple escaped pipes", function()
                assert.same({"abc|def|ghi", "jkl"}, splitPatterns("abc%|def%|ghi|jkl"))
            end)
    
            it("should handle escaped pipes at pattern boundaries", function()
                assert.same({"|abc", "def|", "ghi"}, splitPatterns("%|abc|def%||ghi"))
            end)
    
            it("should handle consecutive escaped pipes", function()
                assert.same({"||"}, splitPatterns("%|%|"))
                assert.same({"a||b"}, splitPatterns("a%|%|b"))
            end)
        end)
    
        describe("error handling", function()
            it("should reject nil input", function()
                local result, err = splitPatterns(nil)
                assert.is_nil(result)
                assert.equals("Pattern must be a non-empty string", err)
            end)
    
            it("should reject empty string", function()
                local result, err = splitPatterns("")
                assert.is_nil(result)
                assert.equals("Pattern must be a non-empty string", err)
            end)
    
            it("should reject patterns with empty alternatives", function()
                local result, err = splitPatterns("|abc")
                assert.is_nil(result)
                assert.equals("Empty pattern found at position 1", err)
    
                result, err = splitPatterns("abc|")
                assert.is_nil(result)
                assert.equals("Empty pattern found at end of string", err)
    
                result, err = splitPatterns("abc||def")
                assert.is_nil(result)
                assert.equals("Empty pattern found at position 5", err)
            end)
    
            it("should reject patterns containing null bytes", function()
                local result, err = splitPatterns("abc\0def")
                assert.is_nil(result)
                assert.equals("\\0 and \\1 not allowed in pattern, as they're used internally", err)
            end)
        end)
    
        describe("complex patterns", function()
            it("should handle complex Lua patterns", function()
                local patterns = {
                    "^%s*(.-)%s*$",           -- trim pattern
                    "%d+%.?%d*",              -- number pattern
                    "[%w_][%w_%.]*",          -- identifier pattern
                    "^#[0-9A-Fa-f]+$"         -- hex color pattern
                }
                local combined = table.concat(patterns, "|")
                assert.same(patterns, splitPatterns(combined))
            end)
    
            it("should handle patterns containing special characters", function()
                local result = splitPatterns("%%|%d+|%s+")
                assert.same({"%%", "%d+", "%s+"}, result)
            end)
    
            it("should handle patterns with character classes", function()
                local result = splitPatterns("[a-z]+|[^0-9]|[%w%p]")
                assert.same({"[a-z]+", "[^0-9]", "[%w%p]"}, result)
            end)
        end)
    
        describe("edge cases", function()
            it("should handle escaped escape character before pipe", function()
                assert.same({"a%%", "b"}, splitPatterns("a%%|b"))
            end)
    
            it("should handle pattern containing only escaped pipe", function()
                assert.same({"|"}, splitPatterns("%|"))
            end)
    
            it("should handle multiple sequential escaped and unescaped pipes", function()
                assert.same({"a|b", "c|d", "e"}, splitPatterns("a%|b|c%|d|e"))
            end)
        end)
    end)

    describe("multiMatcher", function()
        -- Load the multiMatcher function
        local multiMatcher = regex_utils.multiMatcher

        describe("basic functionality", function()
            it("should match basic patterns", function()
                local matcher = assert(multiMatcher("cat|dog|fish"))
                assert.is_true(matcher("I have a cat"))
                assert.is_true(matcher("dogs are nice"))
                assert.is_true(matcher("fishing"))
                assert.is_false(matcher("birds are cool"))
            end)
    
            it("should handle single patterns", function()
                local matcher = assert(multiMatcher("abc"))
                assert.is_true(matcher("abc"))
                assert.is_true(matcher("abcdef"))
                assert.is_false(matcher("def"))
            end)
    
            it("should handle patterns with spaces", function()
                local matcher = assert(multiMatcher("hello world| goodbye world"))
                assert.is_true(matcher("hello world!"))
                assert.is_true(matcher("say goodbye world"))
                assert.is_false(matcher("greetings universe"))
            end)
        end)
    
        describe("Lua pattern characters", function()
            it("should handle character classes", function()
                local matcher = assert(multiMatcher("%d+|%a+"))
                assert.is_true(matcher("123"))
                assert.is_true(matcher("abc"))
                assert.is_false(matcher("!@#"))
            end)
    
            it("should handle pattern anchors", function()
                local matcher = assert(multiMatcher("^start|end$|^full$"))
                assert.is_true(matcher("start of string"))
                assert.is_true(matcher("the end"))
                assert.is_true(matcher("full"))
                assert.is_false(matcher("full house"))
                assert.is_false(matcher("ending"))
            end)
    
            it("should handle character sets", function()
                local matcher = assert(multiMatcher("[aeiou]|[0-9]"))
                assert.is_true(matcher("apple"))
                assert.is_true(matcher("123"))
                assert.is_false(matcher("xyz"))
            end)
    
            it("should handle escaped percent signs", function()
                local matcher = assert(multiMatcher("%%|%d+|%a+"))
                assert.is_true(matcher("50%"))
                assert.is_true(matcher("123"))
                assert.is_true(matcher("abc"))
                assert.is_false(matcher("#"))
            end)
        end)
    
        describe("escaped pipes", function()
            it("should handle escaped pipes in patterns", function()
                local matcher = assert(multiMatcher("a%|b|c%|d|e"))
                assert.is_true(matcher("a|b"))
                assert.is_true(matcher("c|d"))
                assert.is_true(matcher("e"))
                assert.is_false(matcher("a"))
                assert.is_false(matcher("b"))
            end)
    
            it("should handle multiple escaped pipes", function()
                local matcher = assert(multiMatcher("a%|b%|c|d"))
                assert.is_true(matcher("a|b|c"))
                assert.is_true(matcher("d"))
                assert.is_false(matcher("a"))
                assert.is_false(matcher("b"))
                assert.is_false(matcher("c"))
            end)
        end)
    
        describe("error handling", function()
            it("should handle nil input", function()
                local matcher, err = multiMatcher(nil)
                assert.is_nil(matcher)
                assert.equals("Pattern must be a non-empty string", err)
            end)
    
            it("should handle empty string", function()
                local matcher, err = multiMatcher("")
                assert.is_nil(matcher)
                assert.equals("Pattern must be a non-empty string", err)
            end)
    
            it("should handle empty alternatives", function()
                local matcher, err = multiMatcher("|abc")
                assert.is_nil(matcher)
                assert.matches("Empty pattern found", err)
    
                matcher, err = multiMatcher("abc|")
                assert.is_nil(matcher)
                assert.matches("Empty pattern found", err)
            end)
    
            it("should handle invalid Lua patterns", function()
                local matcher, err = multiMatcher("[a-z]|[ABC")  -- Unclosed character class is invalid
                assert.is_nil(matcher)
                assert.same("Invalid pattern: [a-z]|[ABC", err)
            end)
        end)
    
        describe("cache behavior", function()
            it("should cache matchers for same pattern", function()
                regex_utils.clearMultiMatcherCache()
                assert.equals(0, regex_utils.multiMatcherCacheSize())

                local matcher1 = assert(multiMatcher("foo|bar"))
                assert.equals(1, regex_utils.multiMatcherCacheSize())

                local matcher2 = assert(multiMatcher("foo|bar"))
                assert.equals(1, regex_utils.multiMatcherCacheSize())

                assert.are.equal(matcher1, matcher2)
            end)

            it("should cache different patterns separately", function()
                regex_utils.clearMultiMatcherCache()
                assert.equals(0, regex_utils.multiMatcherCacheSize())

                multiMatcher("pattern1")
                assert.equals(1, regex_utils.multiMatcherCacheSize())

                multiMatcher("pattern2")
                assert.equals(2, regex_utils.multiMatcherCacheSize())

                multiMatcher("pattern3")
                assert.equals(3, regex_utils.multiMatcherCacheSize())
            end)

            it("should clear cache and reset size", function()
                regex_utils.clearMultiMatcherCache()
                multiMatcher("a")
                multiMatcher("b")
                multiMatcher("c")
                assert.equals(3, regex_utils.multiMatcherCacheSize())

                regex_utils.clearMultiMatcherCache()
                assert.equals(0, regex_utils.multiMatcherCacheSize())
            end)

            it("should return new matcher after cache clear", function()
                regex_utils.clearMultiMatcherCache()
                local matcher1 = assert(multiMatcher("test"))
                regex_utils.clearMultiMatcherCache()
                local matcher2 = assert(multiMatcher("test"))

                assert.are_not.equal(matcher1, matcher2)
                -- Both should still work
                assert.is_true(matcher1("test"))
                assert.is_true(matcher2("test"))
            end)

            it("should cache errors too", function()
                regex_utils.clearMultiMatcherCache()
                assert.equals(0, regex_utils.multiMatcherCacheSize())

                local matcher1, err1 = multiMatcher("[invalid")
                assert.is_nil(matcher1)
                assert.equals(1, regex_utils.multiMatcherCacheSize())

                local matcher2, err2 = multiMatcher("[invalid")
                assert.is_nil(matcher2)
                assert.equals(1, regex_utils.multiMatcherCacheSize())
                assert.equals(err1, err2)
            end)
        end)

        describe("complex patterns", function()
            it("should match email addresses", function()
                local matcher = assert(multiMatcher(
                    "^[A-Za-z0-9%.%%%+%-]+@[A-Za-z0-9%.%-]+%.%a%a%a?$"
                    .. "|"
                    .. "^[A-Za-z0-9%.%%%+%-]+@%[%d+%.%d+%.%d+%.%d+%]$"
                ))
                assert.is_true(matcher("user@example.com"))
                assert.is_true(matcher("user.name+tag@sub.example.co.uk"))
                assert.is_true(matcher("user@[192.168.1.1]"))
                assert.is_false(matcher("not@an@email.com"))
                assert.is_false(matcher("no spaces@allowed.com"))
            end)
    
            it("should match version numbers", function()
                local matcher = assert(multiMatcher(
                    "^%d+%.%d+%.%d+$" ..
                    "|" ..
                    "^%d+%.%d+$"
                ))
                assert.is_true(matcher("1.0.0"))
                assert.is_true(matcher("2.1"))
                assert.is_false(matcher("1.0.0.0"))
                assert.is_false(matcher(".1"))
            end)
    
            it("should handle mixed literal and pattern matching", function()
                local matcher = assert(multiMatcher("hello|%d+|world%|earth"))
                assert.is_true(matcher("hello"))
                assert.is_true(matcher("42"))
                assert.is_true(matcher("world|earth"))
                assert.is_false(matcher("goodbye"))
                assert.is_false(matcher("world"))
            end)
        end)
    end)

    describe("translateMultiPatternToPCRE", function()
        local function translate(pattern)
            local result, err = regex_utils.translateMultiPatternToPCRE(pattern)
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
                assert.equals("Pattern must be a non-empty string", err)

                result, err = translate("")
                assert.is_nil(result)
                assert.equals("Pattern must be a non-empty string", err)
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
                assert.same("Invalid pattern: abc|[def|ghi", err)
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

    describe("module API", function()
        describe("getVersion", function()
            it("should return a version string", function()
                local version = regex_utils.getVersion()
                assert.is_string(version)
                assert.matches("^%d+%.%d+%.%d+$", version)
            end)
        end)

        describe("callable API", function()
            it("should return version when called with 'version'", function()
                local version = regex_utils("version")
                assert.is_not_nil(version)
                -- Version is a semver object
                assert.are.equal(regex_utils.getVersion(), tostring(version))
            end)

            it("should call API functions when called with function name", function()
                local result = regex_utils("splitPatterns", "a|b|c")
                assert.same({"a", "b", "c"}, result)
            end)

            it("should error on unknown operation", function()
                assert.has_error(function()
                    regex_utils("nonexistent_operation")
                end, "Unknown operation: nonexistent_operation")
            end)
        end)

        describe("__tostring", function()
            it("should return module name and version", function()
                local str = tostring(regex_utils)
                assert.is_string(str)
                assert.matches("^regex_utils version %d+%.%d+%.%d+$", str)
            end)
        end)
    end)
end)
