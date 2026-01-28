-- parsers_generators_spec.lua
-- Tests for parser generator functions (accessible through public API)

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

describe("parsers - generator functions", function()

    describe("parser name validation (via registerAlias)", function()
        local log_messages
        local badVal

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
        end)

        it("should accept valid names", function()
            -- These should succeed
            assert.is_true(parsers.registerAlias(badVal, "genTest_valid1", "string"))
            assert.is_true(parsers.registerAlias(badVal, "genTest.valid2", "number"))
            assert.same({}, log_messages)
        end)

        it("should reject non-string names", function()
            assert.is_false(parsers.registerAlias(badVal, nil, "string"))
            assert.is_false(parsers.registerAlias(badVal, 123, "string"))
            assert.is_true(#log_messages > 0)
        end)

        it("should reject invalid name formats", function()
            -- Invalid: starts with number
            assert.is_false(parsers.registerAlias(badVal, "123abc", "string"))
            -- Invalid: double dots
            assert.is_false(parsers.registerAlias(badVal, "a..b", "string"))
            -- Invalid: starts with dot
            assert.is_false(parsers.registerAlias(badVal, ".abc", "string"))
            -- Invalid: ends with dot
            assert.is_false(parsers.registerAlias(badVal, "abc.", "string"))
            -- Note: errors are logged to badVal, check count increased
        end)

        it("should reject empty string name", function()
            local result = parsers.registerAlias(badVal, "", "string")
            assert.is_false(result)
        end)

        it("should reject registering duplicate names with different types", function()
            log_messages = {}
            -- First registration should succeed
            assert.is_true(parsers.registerAlias(badVal, "genTestDupe", "string"))
            log_messages = {}
            -- Second registration with different type should fail
            local result = parsers.registerAlias(badVal, "genTestDupe", "number")
            assert.is_false(result)
        end)

        it("should allow re-registering same alias with same type", function()
            log_messages = {}
            assert.is_true(parsers.registerAlias(badVal, "genTestSame", "{string}"))
            -- Re-registering with the same type should succeed
            assert.is_true(parsers.registerAlias(badVal, "genTestSame", "{string}"))
            assert.same({}, log_messages)
        end)
    end)

    describe("getComparator", function()
        local log_messages
        local badVal

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
        end)

        it("should return comparators for built-in types", function()
            local stringComp = parsers.getComparator("string")
            assert.is_function(stringComp)
            assert.is_true(stringComp("a", "b"))

            local numberComp = parsers.getComparator("number")
            assert.is_function(numberComp)
            assert.is_true(numberComp(1, 2))

            local boolComp = parsers.getComparator("boolean")
            assert.is_function(boolComp)
            assert.is_true(boolComp(false, true))
        end)

        it("should return comparators for complex types", function()
            local arrayComp = parsers.getComparator("{string}")
            assert.is_function(arrayComp)

            local mapComp = parsers.getComparator("{string:number}")
            assert.is_function(mapComp)

            local tupleComp = parsers.getComparator("{string,number}")
            assert.is_function(tupleComp)
        end)

        it("should return comparators for custom extended types", function()
            -- Create a custom type
            parsers.restrictWithValidator(badVal, "string", "genTestCustom",
                function(_) return true end)

            local comp = parsers.getComparator("genTestCustom")
            assert.is_function(comp)

            -- Should inherit string's comparator behavior
            assert.is_true(comp("a", "b"))
            assert.is_false(comp("b", "a"))
        end)

        it("should return nil for invalid types", function()
            assert.is_nil(parsers.getComparator("unknown_type_xyz"))
            assert.is_nil(parsers.getComparator("{string"))  -- malformed
            assert.is_nil(parsers.getComparator(""))
        end)
    end)

    describe("findParserSpec", function()
        local log_messages
        local badVal

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
        end)

        it("should find parser spec for registered parsers", function()
            local stringParser = parsers.parseType(badVal, "string")
            assert.equals("string", parsers.findParserSpec(stringParser))

            local numberParser = parsers.parseType(badVal, "number")
            assert.equals("number", parsers.findParserSpec(numberParser))

            local booleanParser = parsers.parseType(badVal, "boolean")
            assert.equals("boolean", parsers.findParserSpec(booleanParser))
        end)

        it("should find parser spec for array parsers", function()
            local arrayParser = parsers.parseType(badVal, "{string}")
            assert.equals("{string}", parsers.findParserSpec(arrayParser))

            local nestedParser = parsers.parseType(badVal, "{{number}}")
            assert.equals("{{number}}", parsers.findParserSpec(nestedParser))
        end)

        it("should find parser spec for map parsers", function()
            local mapParser = parsers.parseType(badVal, "{string:number}")
            assert.equals("{string:number}", parsers.findParserSpec(mapParser))
        end)

        it("should find parser spec for tuple parsers", function()
            local tupleParser = parsers.parseType(badVal, "{string,number,boolean}")
            assert.equals("{string,number,boolean}", parsers.findParserSpec(tupleParser))
        end)

        it("should find parser spec for record parsers", function()
            local recordParser = parsers.parseType(badVal, "{name:string,age:number}")
            assert.equals("{age:number,name:string}", parsers.findParserSpec(recordParser))
        end)

        it("should find parser spec for union parsers", function()
            local unionParser = parsers.parseType(badVal, "number|boolean|string")
            assert.equals("number|boolean|string", parsers.findParserSpec(unionParser))
        end)

        it("should find parser spec for custom enum parsers", function()
            assert(registerEnumParser(badVal, {"Alpha", "Beta", "Gamma"}, "GenTestEnum2"))
            local enumParser = parsers.parseType(badVal, "GenTestEnum2")
            local spec = parsers.findParserSpec(enumParser)
            -- Should find the internal enum spec
            assert.is_string(spec)
            assert.matches("enum:", spec)
        end)

        it("should return nil for unknown parsers", function()
            local unknownParser = function() end
            assert.is_nil(parsers.findParserSpec(unknownParser))
        end)
    end)

    describe("callParser behavior", function()
        local log_messages
        local badVal

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
        end)

        it("should return parsed and reformatted values for valid input", function()
            local stringParser = parsers.parseType(badVal, "string")
            local parsed, reformatted = stringParser(badVal, "hello")
            assert.equals("hello", parsed)
            assert.equals("hello", reformatted)
        end)

        it("should always return reformatted as string", function()
            local numberParser = parsers.parseType(badVal, "number")
            local parsed, reformatted = numberParser(badVal, "42")
            assert.equals(42, parsed)
            assert.is_string(reformatted)
            assert.equals("42", reformatted)

            local boolParser = parsers.parseType(badVal, "boolean")
            parsed, reformatted = boolParser(badVal, "true")
            assert.equals(true, parsed)
            assert.is_string(reformatted)
            assert.equals("true", reformatted)
        end)

        it("should return nil parsed but string reformatted on error", function()
            local numberParser = parsers.parseType(badVal, "number")
            local parsed, reformatted = numberParser(badVal, "not_a_number")
            assert.is_nil(parsed)
            assert.is_string(reformatted)
        end)

        it("should handle array parsing", function()
            local arrayParser = parsers.parseType(badVal, "{number}")
            local parsed, reformatted = arrayParser(badVal, "1,2,3")
            assert.same({1, 2, 3}, parsed)
            assert.is_string(reformatted)
        end)

        it("should handle map parsing", function()
            local mapParser = parsers.parseType(badVal, "{string:number}")
            local parsed, reformatted = mapParser(badVal, "a=1,b=2")
            assert.same({a=1, b=2}, parsed)
            assert.is_string(reformatted)
        end)
    end)

    describe("type extension chain", function()
        local log_messages
        local badVal

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
        end)

        it("should support extending types multiple levels", function()
            -- Create a chain: string -> level1 -> level2 -> level3
            assert(parsers.restrictWithValidator(badVal, "string", "genLevel1",
                function(_) return true end))
            assert(parsers.restrictWithValidator(badVal, "genLevel1", "genLevel2",
                function(_) return true end))
            assert(parsers.restrictWithValidator(badVal, "genLevel2", "genLevel3",
                function(_) return true end))

            -- All levels should work
            local level3Parser = parsers.parseType(badVal, "genLevel3")
            assert.is_not_nil(level3Parser)

            local parsed, reformatted = level3Parser(badVal, "test")
            assert.equals("test", parsed)
        end)

        it("should inherit parent comparator through chain", function()
            -- Comparators should be inherited
            local comp = parsers.getComparator("genLevel3")
            assert.is_function(comp)
            assert.is_true(comp("a", "b"))
        end)
    end)
end)
