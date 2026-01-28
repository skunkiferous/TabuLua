-- round_trip_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local round_trip = require("round_trip")

describe("round_trip", function()
    describe("isNaN", function()
        it("should return true for NaN", function()
            assert.is_true(round_trip.isNaN(0/0))
        end)

        it("should return false for regular numbers", function()
            assert.is_false(round_trip.isNaN(42))
            assert.is_false(round_trip.isNaN(3.14))
            assert.is_false(round_trip.isNaN(0))
            assert.is_false(round_trip.isNaN(-1))
        end)

        it("should return false for infinity", function()
            assert.is_false(round_trip.isNaN(math.huge))
            assert.is_false(round_trip.isNaN(-math.huge))
        end)

        it("should return false for non-numbers", function()
            assert.is_false(round_trip.isNaN("nan"))
            assert.is_false(round_trip.isNaN(nil))
            assert.is_false(round_trip.isNaN({}))
        end)
    end)

    describe("deepEquals", function()
        it("should return true for equal primitives", function()
            local eq, diff = round_trip.deepEquals(42, 42)
            assert.is_true(eq)
            assert.is_nil(diff)

            eq, diff = round_trip.deepEquals("hello", "hello")
            assert.is_true(eq)
            assert.is_nil(diff)

            eq, diff = round_trip.deepEquals(true, true)
            assert.is_true(eq)
            assert.is_nil(diff)
        end)

        it("should return true for equal nil values", function()
            local eq, diff = round_trip.deepEquals(nil, nil)
            assert.is_true(eq)
            assert.is_nil(diff)
        end)

        it("should return true for NaN values", function()
            local eq, diff = round_trip.deepEquals(0/0, 0/0)
            assert.is_true(eq)
            assert.is_nil(diff)
        end)

        it("should return false for different primitives", function()
            local eq, diff = round_trip.deepEquals(42, 43)
            assert.is_false(eq)
            assert.is_not_nil(diff)

            eq, diff = round_trip.deepEquals("hello", "world")
            assert.is_false(eq)
            assert.is_not_nil(diff)
        end)

        it("should return false for type mismatch", function()
            local eq, diff = round_trip.deepEquals(42, "42")
            assert.is_false(eq)
            assert.matches("type mismatch", diff)
        end)

        it("should return true for equal tables", function()
            local eq, diff = round_trip.deepEquals({1, 2, 3}, {1, 2, 3})
            assert.is_true(eq)
            assert.is_nil(diff)
        end)

        it("should return true for equal nested tables", function()
            local a = {a = {b = {c = 1}}, d = {2, 3}}
            local b = {a = {b = {c = 1}}, d = {2, 3}}
            local eq, diff = round_trip.deepEquals(a, b)
            assert.is_true(eq)
            assert.is_nil(diff)
        end)

        it("should return false for tables with different keys", function()
            local eq, diff = round_trip.deepEquals({a = 1}, {b = 1})
            assert.is_false(eq)
            assert.matches("missing", diff)
        end)

        it("should return false for tables with different values", function()
            local eq, diff = round_trip.deepEquals({a = 1}, {a = 2})
            assert.is_false(eq)
            assert.matches("mismatch", diff)
        end)

        it("should return false for tables with extra keys", function()
            local eq, diff = round_trip.deepEquals({a = 1}, {a = 1, b = 2})
            assert.is_false(eq)
            assert.matches("extra key", diff)
        end)

        it("should handle mixed key types", function()
            local a = {1, 2, a = "test"}
            local b = {1, 2, a = "test"}
            local eq, diff = round_trip.deepEquals(a, b)
            assert.is_true(eq)
            assert.is_nil(diff)
        end)

        it("should handle special float values", function()
            local a = {inf = math.huge, ninf = -math.huge, nan = 0/0}
            local b = {inf = math.huge, ninf = -math.huge, nan = 0/0}
            local eq, diff = round_trip.deepEquals(a, b)
            assert.is_true(eq)
            assert.is_nil(diff)
        end)
    end)

    describe("compareWithTolerance", function()
        it("should behave like deepEquals for lua format", function()
            local a = {1, 2, 3}
            local b = {1, 2, 3}
            local eq, diff = round_trip.compareWithTolerance(a, b, "lua")
            assert.is_true(eq)
            assert.is_nil(diff)
        end)

        it("should allow integer/float equivalence for json-natural", function()
            -- In natural JSON, 42 and 42.0 are equivalent
            local eq, diff = round_trip.compareWithTolerance(42, 42.0, "json-natural")
            assert.is_true(eq)
            assert.is_nil(diff)
        end)

        it("should detect number differences in json-natural", function()
            local eq, diff = round_trip.compareWithTolerance(42, 43, "json-natural")
            assert.is_false(eq)
            assert.matches("mismatch", diff)
        end)

        it("should work for nested structures with json-natural", function()
            local a = {values = {1, 2, 3}}
            local b = {values = {1.0, 2.0, 3.0}}
            local eq, diff = round_trip.compareWithTolerance(a, b, "json-natural")
            assert.is_true(eq)
            assert.is_nil(diff)
        end)
    end)

    describe("testLuaRoundTrip", function()
        it("should pass for basic types", function()
            local ok, err = round_trip.testLuaRoundTrip(42)
            assert.is_true(ok)
            assert.is_nil(err)

            ok, err = round_trip.testLuaRoundTrip("hello")
            assert.is_true(ok)
            assert.is_nil(err)

            ok, err = round_trip.testLuaRoundTrip(true)
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should pass for tables", function()
            local ok, err = round_trip.testLuaRoundTrip({1, 2, 3})
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should pass for nested tables", function()
            local ok, err = round_trip.testLuaRoundTrip({a = {b = {c = 1}}})
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should pass for special float values", function()
            local ok, err = round_trip.testLuaRoundTrip(math.huge)
            assert.is_true(ok)
            assert.is_nil(err)

            ok, err = round_trip.testLuaRoundTrip(-math.huge)
            assert.is_true(ok)
            assert.is_nil(err)
        end)
    end)

    describe("testTypedJSONRoundTrip", function()
        it("should pass for basic types", function()
            local ok, err = round_trip.testTypedJSONRoundTrip(42)
            assert.is_true(ok)
            assert.is_nil(err)

            ok, err = round_trip.testTypedJSONRoundTrip("hello")
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should pass for tables", function()
            local ok, err = round_trip.testTypedJSONRoundTrip({1, 2, 3})
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should preserve integer type", function()
            local ok, err = round_trip.testTypedJSONRoundTrip(42)
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should pass for special float values", function()
            local ok, err = round_trip.testTypedJSONRoundTrip(math.huge)
            assert.is_true(ok)
            assert.is_nil(err)

            ok, err = round_trip.testTypedJSONRoundTrip(0/0)  -- NaN
            assert.is_true(ok)
            assert.is_nil(err)
        end)
    end)

    describe("testNaturalJSONRoundTrip", function()
        it("should pass for basic types", function()
            local ok, err = round_trip.testNaturalJSONRoundTrip(42)
            assert.is_true(ok)
            assert.is_nil(err)

            ok, err = round_trip.testNaturalJSONRoundTrip("hello")
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should pass for arrays", function()
            local ok, err = round_trip.testNaturalJSONRoundTrip({1, 2, 3})
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should pass for objects", function()
            local ok, err = round_trip.testNaturalJSONRoundTrip({a = 1, b = "test"})
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should pass for special float values", function()
            local ok, err = round_trip.testNaturalJSONRoundTrip(math.huge)
            assert.is_true(ok)
            assert.is_nil(err)

            ok, err = round_trip.testNaturalJSONRoundTrip(0/0)  -- NaN
            assert.is_true(ok)
            assert.is_nil(err)
        end)
    end)

    describe("testXMLRoundTrip", function()
        it("should pass for basic types", function()
            local ok, err = round_trip.testXMLRoundTrip(42)
            assert.is_true(ok)
            assert.is_nil(err)

            ok, err = round_trip.testXMLRoundTrip("hello")
            assert.is_true(ok)
            assert.is_nil(err)

            ok, err = round_trip.testXMLRoundTrip(true)
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should pass for tables", function()
            local ok, err = round_trip.testXMLRoundTrip({1, 2, 3})
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should pass for nested tables", function()
            local ok, err = round_trip.testXMLRoundTrip({a = {b = 1}})
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should pass for strings with special XML characters", function()
            local ok, err = round_trip.testXMLRoundTrip('<tag>&"test\'')
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should pass for special float values", function()
            local ok, err = round_trip.testXMLRoundTrip(math.huge)
            assert.is_true(ok)
            assert.is_nil(err)

            ok, err = round_trip.testXMLRoundTrip(0/0)  -- NaN
            assert.is_true(ok)
            assert.is_nil(err)
        end)
    end)

    describe("testMessagePackRoundTrip", function()
        it("should pass for basic types", function()
            local ok, err = round_trip.testMessagePackRoundTrip(42)
            assert.is_true(ok)
            assert.is_nil(err)

            ok, err = round_trip.testMessagePackRoundTrip("hello")
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should pass for tables", function()
            local ok, err = round_trip.testMessagePackRoundTrip({1, 2, 3})
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("should pass for nested tables", function()
            local ok, err = round_trip.testMessagePackRoundTrip({a = {b = {c = 1}}})
            assert.is_true(ok)
            assert.is_nil(err)
        end)
    end)

    describe("testAllRoundTrips", function()
        it("should test all formats", function()
            local results = round_trip.testAllRoundTrips({1, 2, 3})

            assert.is_not_nil(results.lua)
            assert.is_not_nil(results["json-typed"])
            assert.is_not_nil(results["json-natural"])
            assert.is_not_nil(results.xml)
            assert.is_not_nil(results.mpk)
        end)

        it("should return success for all formats with simple data", function()
            local results = round_trip.testAllRoundTrips({a = 1, b = "test"})

            assert.is_true(results.lua[1])
            assert.is_true(results["json-typed"][1])
            assert.is_true(results["json-natural"][1])
            assert.is_true(results.xml[1])
            assert.is_true(results.mpk[1])
        end)
    end)

    describe("module API", function()
        describe("getVersion", function()
            it("should return a version string", function()
                local version = round_trip.getVersion()
                assert.is_string(version)
                assert.matches("^%d+%.%d+%.%d+$", version)
            end)
        end)

        describe("callable API", function()
            it("should return version when called with 'version'", function()
                local version = round_trip("version")
                assert.is_not_nil(version)
                assert.are.equal(round_trip.getVersion(), tostring(version))
            end)

            it("should call API functions when called with function name", function()
                local result = round_trip("isNaN", 0/0)
                assert.is_true(result)
            end)

            it("should error on unknown operation", function()
                assert.has_error(function()
                    round_trip("nonexistent_operation")
                end, "Unknown operation: nonexistent_operation")
            end)
        end)

        describe("__tostring", function()
            it("should return module name and version", function()
                local str = tostring(round_trip)
                assert.is_string(str)
                assert.matches("^round_trip version %d+%.%d+%.%d+$", str)
            end)
        end)
    end)
end)
