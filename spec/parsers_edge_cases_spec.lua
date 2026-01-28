-- parsers_edge_cases_spec.lua
-- Tests for edge cases: ratio type, comparators, context handling

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

describe("parsers - edge cases", function()

    describe("ratio type", function()
        local log_messages
        local badVal
        local ratioParser

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
            ratioParser = parsers.parseType(badVal, "ratio")
            assert.is_not_nil(ratioParser, "ratioParser is nil")
        end)

        it("should accept valid ratios that sum to 100%", function()
            -- Ratio format uses quoted percentage strings
            -- The parsed result keeps the original string values
            local parsed, reformatted = ratioParser(badVal, "a='50%',b='50%'")
            assert.is_not_nil(parsed)
            assert.equals('50%', parsed.a)
            assert.equals('50%', parsed.b)
            assert.same({}, log_messages)
            -- Reformatted uses double quotes
            assert.is_string(reformatted)
        end)

        it("should accept fractions that sum to 1", function()
            local parsed, reformatted = ratioParser(badVal, "a='1/3',b='2/3'")
            assert.is_not_nil(parsed)
            -- Parsed keeps original string format
            assert.equals('1/3', parsed.a)
            assert.equals('2/3', parsed.b)
            assert.same({}, log_messages)
        end)

        it("should accept mixed percentages and fractions", function()
            local parsed, reformatted = ratioParser(badVal, "a='50%',b='1/2'")
            assert.is_not_nil(parsed)
            assert.equals('50%', parsed.a)
            assert.equals('1/2', parsed.b)
            assert.same({}, log_messages)
        end)

        it("should reject ratios that don't sum to 100%", function()
            local parsed, reformatted = ratioParser(badVal, "a='30%',b='30%'")
            assert.is_nil(parsed)
            assert.is_true(#log_messages > 0)
            assert.matches("100%%", log_messages[1])
        end)

        it("should accept single 100% value", function()
            local parsed, reformatted = ratioParser(badVal, "only='100%'")
            assert.is_not_nil(parsed)
            assert.equals('100%', parsed.only)
            assert.same({}, log_messages)
        end)

        it("should handle three-way split", function()
            local parsed, reformatted = ratioParser(badVal, "a='33%',b='33%',c='34%'")
            assert.is_not_nil(parsed)
            assert.equals('33%', parsed.a)
            assert.equals('33%', parsed.b)
            assert.equals('34%', parsed.c)
            assert.same({}, log_messages)
        end)
    end)

    describe("comparator behavior", function()
        local log_messages
        local badVal

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
        end)

        describe("string comparator", function()
            it("should compare case-insensitively", function()
                local comp = parsers.getComparator("string")
                assert.is_function(comp)

                -- Case insensitive comparison
                assert.is_true(comp("Apple", "banana"))
                assert.is_false(comp("banana", "Apple"))

                -- Same value (case insensitive) returns false
                assert.is_false(comp("ABC", "abc"))
            end)
        end)

        describe("number comparator", function()
            it("should compare numerically", function()
                local comp = parsers.getComparator("number")
                assert.is_function(comp)

                assert.is_true(comp(1, 2))
                assert.is_false(comp(2, 1))
                assert.is_false(comp(1, 1))

                -- Negative numbers
                assert.is_true(comp(-10, -5))
                assert.is_false(comp(-5, -10))

                -- Floats
                assert.is_true(comp(1.5, 1.6))
            end)
        end)

        describe("boolean comparator", function()
            it("should sort false before true", function()
                local comp = parsers.getComparator("boolean")
                assert.is_function(comp)

                assert.is_true(comp(false, true))
                assert.is_false(comp(true, false))
                assert.is_false(comp(false, false))
                assert.is_false(comp(true, true))
            end)
        end)

        describe("array comparator", function()
            it("should compare arrays element by element", function()
                local comp = parsers.getComparator("{number}")
                assert.is_function(comp)

                -- Shorter array comes first
                assert.is_true(comp({1}, {1, 2}))
                assert.is_false(comp({1, 2}, {1}))

                -- Compare by first differing element
                assert.is_true(comp({1, 2}, {1, 3}))
                assert.is_false(comp({1, 3}, {1, 2}))

                -- Equal arrays
                assert.is_false(comp({1, 2}, {1, 2}))
            end)
        end)

        describe("tuple comparator", function()
            it("should compare tuples element by element", function()
                local comp = parsers.getComparator("{string,number}")
                assert.is_function(comp)

                -- Compare by first element
                assert.is_true(comp({"a", 1}, {"b", 1}))
                assert.is_false(comp({"b", 1}, {"a", 1}))

                -- If first equal, compare by second
                assert.is_true(comp({"a", 1}, {"a", 2}))
                assert.is_false(comp({"a", 2}, {"a", 1}))

                -- Equal tuples
                assert.is_false(comp({"a", 1}, {"a", 1}))
            end)
        end)

        describe("map comparator", function()
            it("should compare maps", function()
                local comp = parsers.getComparator("{string:number}")
                assert.is_function(comp)

                -- Maps with different keys
                assert.is_true(comp({a=1}, {b=1}))
                assert.is_false(comp({b=1}, {a=1}))

                -- Maps with same keys, different values
                assert.is_true(comp({a=1}, {a=2}))
                assert.is_false(comp({a=2}, {a=1}))

                -- Equal maps
                assert.is_false(comp({a=1}, {a=1}))
            end)
        end)

        describe("enum comparator", function()
            it("should compare enums alphabetically", function()
                assert(registerEnumParser(badVal, {"Alpha", "Beta", "Gamma"}, "EdgeTestEnum"))
                local comp = parsers.getComparator("EdgeTestEnum")
                assert.is_function(comp)

                assert.is_true(comp("Alpha", "Beta"))
                assert.is_false(comp("Beta", "Alpha"))
                assert.is_true(comp("Beta", "Gamma"))
                assert.is_false(comp("Alpha", "Alpha"))
            end)
        end)

        describe("union comparator", function()
            it("should handle optional types with nil", function()
                local comp = parsers.getComparator("number|nil")
                assert.is_function(comp)

                -- nil comes before any value
                assert.is_true(comp(nil, 1))
                assert.is_false(comp(1, nil))

                -- Non-nil values compare normally
                assert.is_true(comp(1, 2))
                assert.is_false(comp(2, 1))

                -- Equal values
                assert.is_false(comp(nil, nil))
                assert.is_false(comp(1, 1))
            end)
        end)
    end)

    describe("context handling (tsv vs parsed)", function()
        local log_messages
        local badVal

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
        end)

        describe("boolean parser", function()
            it("should accept string in tsv context", function()
                local boolParser = parsers.parseType(badVal, "boolean")
                local parsed, reformatted = boolParser(badVal, "true", "tsv")
                assert.equals(true, parsed)
                assert.equals("true", reformatted)
            end)

            it("should accept boolean in parsed context", function()
                local boolParser = parsers.parseType(badVal, "boolean")
                local parsed, reformatted = boolParser(badVal, true, "parsed")
                assert.equals(true, parsed)
                assert.equals("true", reformatted)
            end)

            it("should reject boolean in tsv context", function()
                local boolParser = parsers.parseType(badVal, "boolean")
                local parsed, reformatted = boolParser(badVal, true, "tsv")
                assert.is_nil(parsed)
                assert.is_true(#log_messages > 0)
            end)
        end)

        describe("number parser", function()
            it("should accept string in tsv context", function()
                local numberParser = parsers.parseType(badVal, "number")
                local parsed, reformatted = numberParser(badVal, "42", "tsv")
                assert.equals(42, parsed)
            end)

            it("should accept number in parsed context", function()
                local numberParser = parsers.parseType(badVal, "number")
                local parsed, reformatted = numberParser(badVal, 42, "parsed")
                assert.equals(42, parsed)
            end)

            it("should reject number in tsv context", function()
                local numberParser = parsers.parseType(badVal, "number")
                local parsed, reformatted = numberParser(badVal, 42, "tsv")
                assert.is_nil(parsed)
                assert.is_true(#log_messages > 0)
            end)

            it("should reject string in parsed context", function()
                local numberParser = parsers.parseType(badVal, "number")
                local parsed, reformatted = numberParser(badVal, "42", "parsed")
                assert.is_nil(parsed)
                assert.is_true(#log_messages > 0)
            end)
        end)

        describe("table parser", function()
            it("should accept string in tsv context", function()
                local tableParser = parsers.parseType(badVal, "table")
                local parsed, reformatted = tableParser(badVal, "a=1,b=2", "tsv")
                assert.same({a=1, b=2}, parsed)
            end)

            it("should accept table in parsed context", function()
                local tableParser = parsers.parseType(badVal, "table")
                local parsed, reformatted = tableParser(badVal, {a=1, b=2}, "parsed")
                assert.same({a=1, b=2}, parsed)
            end)

            it("should reject table in tsv context", function()
                local tableParser = parsers.parseType(badVal, "table")
                local parsed, reformatted = tableParser(badVal, {a=1}, "tsv")
                assert.is_nil(parsed)
                assert.is_true(#log_messages > 0)
            end)
        end)

        describe("nil parser", function()
            it("should accept empty string in tsv context", function()
                local nilParser = parsers.parseType(badVal, "nil")
                local parsed, reformatted = nilParser(badVal, "", "tsv")
                assert.is_nil(parsed)
                assert.equals("", reformatted)
                assert.same({}, log_messages)
            end)

            it("should accept nil in parsed context", function()
                local nilParser = parsers.parseType(badVal, "nil")
                local parsed, reformatted = nilParser(badVal, nil, "parsed")
                assert.is_nil(parsed)
                assert.equals("", reformatted)
                assert.same({}, log_messages)
            end)

            it("should reject non-empty string in tsv context as nil", function()
                local nilParser = parsers.parseType(badVal, "nil")
                local parsed, reformatted = nilParser(badVal, "something", "tsv")
                assert.is_nil(parsed)
                assert.is_true(#log_messages > 0)
            end)
        end)

        describe("true parser", function()
            it("should accept 'true' string in tsv context", function()
                local trueParser = parsers.parseType(badVal, "true")
                local parsed, reformatted = trueParser(badVal, "true", "tsv")
                assert.equals(true, parsed)
                assert.equals("true", reformatted)
            end)

            it("should accept true boolean in parsed context", function()
                local trueParser = parsers.parseType(badVal, "true")
                local parsed, reformatted = trueParser(badVal, true, "parsed")
                assert.equals(true, parsed)
                assert.equals("true", reformatted)
            end)

            it("should reject 'true' string in parsed context", function()
                local trueParser = parsers.parseType(badVal, "true")
                local parsed, reformatted = trueParser(badVal, "true", "parsed")
                assert.is_nil(parsed)
                assert.is_true(#log_messages > 0)
            end)
        end)
    end)

    describe("nested types", function()
        local log_messages
        local badVal

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
        end)

        it("should handle nested arrays (2 levels)", function()
            local parser = parsers.parseType(badVal, "{{number}}")
            assert.is_not_nil(parser)

            -- Use proper nested table syntax
            local parsed, reformatted = parser(badVal, "{1,2},{3,4}")
            assert.is_not_nil(parsed, "Parser should handle nested arrays: " ..
                table.concat(log_messages, "; "))
            assert.same({{1,2},{3,4}}, parsed)
        end)

        it("should handle nested maps", function()
            local parser = parsers.parseType(badVal, "{string:{string:number}}")
            assert.is_not_nil(parser)

            local parsed, reformatted = parser(badVal, "a={x=1,y=2}")
            assert.is_not_nil(parsed, "Parser should handle nested maps: " ..
                table.concat(log_messages, "; "))
            assert.equals(1, parsed.a.x)
            assert.equals(2, parsed.a.y)
        end)

        it("should handle map of arrays", function()
            local parser = parsers.parseType(badVal, "{string:{number}}")
            assert.is_not_nil(parser)

            local parsed, reformatted = parser(badVal, "data={1,2,3}")
            assert.is_not_nil(parsed, "Parser should handle map of arrays: " ..
                table.concat(log_messages, "; "))
            assert.same({1,2,3}, parsed.data)
        end)
    end)

    describe("empty and edge value handling", function()
        local log_messages
        local badVal

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
        end)

        it("should handle empty arrays", function()
            local parser = parsers.parseType(badVal, "{string}")
            local parsed, reformatted = parser(badVal, "")
            assert.same({}, parsed)
        end)

        it("should handle empty maps", function()
            local parser = parsers.parseType(badVal, "{string:number}")
            local parsed, reformatted = parser(badVal, "")
            assert.same({}, parsed)
        end)

        it("should handle empty records", function()
            local parser = parsers.parseType(badVal, "{name:string|nil,age:number|nil}")
            local parsed, reformatted = parser(badVal, "")
            assert.same({}, parsed)
        end)

        it("should handle special number values", function()
            local parser = parsers.parseType(badVal, "number")

            -- Zero
            local parsed, reformatted = parser(badVal, "0")
            assert.equals(0, parsed)

            -- Negative zero
            parsed, reformatted = parser(badVal, "-0")
            assert.equals(0, parsed)

            -- Scientific notation
            parsed, reformatted = parser(badVal, "1e10")
            assert.equals(1e10, parsed)

            parsed, reformatted = parser(badVal, "1e-10")
            assert.equals(1e-10, parsed)
        end)

        it("should handle empty string as string value", function()
            local parser = parsers.parseType(badVal, "string")
            local parsed, reformatted = parser(badVal, "")
            assert.equals("", parsed)
        end)
    end)
end)
