-- table_utils_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local table_utils = require("table_utils")

describe("table_utils", function()
  describe("tableShallowCopy", function()
    it("should create a shallow copy of a table", function()
      local original = {1, 2, 3, a = "test"}
      local copy = table_utils.tableShallowCopy(original)
      assert.are.same(original, copy)
      assert.are_not.equal(original, copy)
    end)

    it("with tables containing metatables", function()
      local mt = {
        __index = function(_, k)
          return "default_" .. k
        end
      }
      local original = setmetatable({a = 1, b = 2}, mt)
      local copy = table_utils.tableShallowCopy(original)

      -- Copy should have the same key-value pairs
      assert.are.equal(1, copy.a)
      assert.are.equal(2, copy.b)

      -- But copy should NOT have the metatable (shallow copy doesn't copy metatable)
      assert.is_nil(getmetatable(copy))

      -- Original should still have metatable behavior
      assert.are.equal("default_missing", original.missing)

      -- Copy should NOT have metatable behavior
      assert.is_nil(copy.missing)
    end)

    it("with nil input", function()
      assert.has_error(function()
        table_utils.tableShallowCopy(nil)
      end, "Expected table t, got nil")
    end)
  end)

  describe("wrappedPairs and wrappedIpairs", function()
    it("should wrap pairs and ipairs with a manipulator function", function()
      local t = {1, 2, 3, a = "test"}
      local manipulator = function(v) return type(v) == "number" and v * 2 or v end

      local result = {}
      for k, v in table_utils.wrappedPairs(t, manipulator) do
        result[k] = v
      end
      assert.are.same({2, 4, 6, a = "test"}, result)

      local iresult = {}
      for i, v in table_utils.wrappedIpairs(t, manipulator) do
        iresult[i] = v
      end
      assert.are.same({2, 4, 6}, iresult)
    end)
  end)

  describe("longestMatchingPrefix", function()
    it("should find the longest matching prefix", function()
      local sequence = {"a", "ab", "abc", "b", "bc"}
      assert.are.equal("abc", table_utils.longestMatchingPrefix(sequence, "abcdef"))
      assert.are.equal("bc", table_utils.longestMatchingPrefix(sequence, "bcd"))
      assert.are.equal("", table_utils.longestMatchingPrefix(sequence, "cde"))
    end)
  end)

  describe("filterSeq", function()
    it("should filter a sequence based on a predicate function", function()
      local numbers = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}

      -- Filter even numbers
      local isEven = function(n) return n % 2 == 0 end
      local evenNumbers = table_utils.filterSeq(numbers, isEven)

      -- Check the filtered result
      assert.are.same({2, 4, 6, 8, 10}, evenNumbers)

      -- Check that the original array was modified
      assert.are.same({1, 3, 5, 7, 9}, numbers)
    end)

    it("should handle empty sequences", function()
      local emptySeq = {}
      local result = table_utils.filterSeq(emptySeq, function() return true end)
      assert.are.same({}, result)
      assert.are.same({}, emptySeq)
    end)

    it("should handle sequences where no elements match", function()
      local numbers = {1, 3, 5, 7, 9}
      local isEven = function(n) return n % 2 == 0 end
      local evenNumbers = table_utils.filterSeq(numbers, isEven)

      assert.are.same({}, evenNumbers)
      assert.are.same({1, 3, 5, 7, 9}, numbers)
    end)

    it("should handle sequences where all elements match", function()
      local numbers = {2, 4, 6, 8, 10}
      local isEven = function(n) return n % 2 == 0 end
      local evenNumbers = table_utils.filterSeq(numbers, isEven)

      assert.are.same({2, 4, 6, 8, 10}, evenNumbers)
      assert.are.same({}, numbers)
    end)
  end)

  describe("appendSeq", function()
    it("should append one sequence to another", function()
      local t1 = {1, 2, 3}
      local t2 = {4, 5, 6}
      local result = table_utils.appendSeq(t1, t2)
      assert.are.same({1, 2, 3, 4, 5, 6}, result)
      assert.are.equal(t1, result) -- should modify t1 in place
    end)

    it("should handle empty sequences", function()
      local t1 = {}
      local t2 = {1, 2, 3}
      local result = table_utils.appendSeq(t1, t2)
      assert.are.same({1, 2, 3}, result)

      t1 = {1, 2, 3}
      t2 = {}
      result = table_utils.appendSeq(t1, t2)
      assert.are.same({1, 2, 3}, result)
    end)
  end)

  describe("clearSeq", function()
    it("should clear all elements from a sequence", function()
      local t = {1, 2, 3, 4, 5}
      table_utils.clearSeq(t)
      assert.are.same({}, t)
    end)

    it("should handle empty sequences", function()
      local t = {}
      table_utils.clearSeq(t)
      assert.are.same({}, t)
    end)

    it("should not affect non-sequence parts of a table", function()
      local t = {1, 2, 3, a = "test", b = "keep"}
      table_utils.clearSeq(t)
      assert.are.same({a = "test", b = "keep"}, t)
    end)
  end)

  describe("setToSeq", function()
    it("should convert a set to a sequence", function()
      local set = {a = true, b = true, c = true}
      local result = table_utils.setToSeq(set)
      table.sort(result) -- Sort for consistent ordering
      assert.are.same({"a", "b", "c"}, result)
    end)

    it("should handle empty sets", function()
      local set = {}
      local result = table_utils.setToSeq(set)
      assert.are.same({}, result)
    end)

    it("should ignore non-true values", function()
      local set = {a = true, b = false, c = true, d = nil, e = 1}
      local result = table_utils.setToSeq(set)
      table.sort(result) -- Sort for consistent ordering
      assert.are.same({"a", "c", "e"}, result)
    end)
  end)

  describe("sortCaseInsensitive", function()
    it("should sort lowercase strings correctly", function()
        local arr = {"cat", "apple", "dog", "banana"}
        table.sort(arr, table_utils.sortCaseInsensitive)
        assert.same({"apple", "banana", "cat", "dog"}, arr)
    end)

    it("should sort uppercase strings correctly", function()
        local arr = {"CAT", "APPLE", "DOG", "BANANA"}
        table.sort(arr, table_utils.sortCaseInsensitive)
        assert.same({"APPLE", "BANANA", "CAT", "DOG"}, arr)
    end)

    it("should sort mixed case strings correctly", function()
        local arr = {"Cat", "APPLE", "dog", "Banana"}
        table.sort(arr, table_utils.sortCaseInsensitive)
        assert.same({"APPLE", "Banana", "Cat", "dog"}, arr)
    end)

    it("should handle strings with numbers", function()
        local arr = {"item10", "Item2", "ITEM1", "item20"}
        table.sort(arr, table_utils.sortCaseInsensitive)
        assert.same({"ITEM1", "item10", "Item2", "item20"}, arr)
    end)

    it("should handle numbers converted to strings", function()
        local arr = {10, 2, 1, 20}
        table.sort(arr, table_utils.sortCaseInsensitive)
        assert.same({1, 10, 2, 20}, arr)
    end)

    it("should handle empty strings", function()
        local arr = {"", "a", "", "B"}
        table.sort(arr, table_utils.sortCaseInsensitive)
        assert.same({"", "", "a", "B"}, arr)
    end)

    it("should handle strings with special characters", function()
        local arr = {"a-1", "A-2", "a-10", "A-20"}
        table.sort(arr, table_utils.sortCaseInsensitive)
        assert.same({"a-1", "a-10", "A-2", "A-20"}, arr)
    end)

    it("should handle mixed types converted to strings", function()
        local arr = {123, "abc", 456, "DEF"}
        table.sort(arr, table_utils.sortCaseInsensitive)
        assert.same({123, 456, "abc", "DEF"}, arr)
    end)

    it("should maintain stability for equal elements", function()
        local arr = {"ABC", "abc", "ABC", "abc"}
        table.sort(arr, table_utils.sortCaseInsensitive)
        -- Order of equal elements should be preserved
        local lowerCount = 0
        local upperCount = 0
        for i = 1, #arr do
            if arr[i] == "abc" then lowerCount = lowerCount + 1 end
            if arr[i] == "ABC" then upperCount = upperCount + 1 end
        end
        assert.equal(2, lowerCount)
        assert.equal(2, upperCount)
    end)

    it("should handle unicode strings", function()
        local arr = {"é", "e", "É", "E"}
        table.sort(arr, table_utils.sortCaseInsensitive)
        -- Note: The exact order might depend on the Lua implementation's handling of Unicode
        assert.equal(4, #arr)
        assert.truthy(arr[1]:lower() <= arr[2]:lower())
        assert.truthy(arr[2]:lower() <= arr[3]:lower())
        assert.truthy(arr[3]:lower() <= arr[4]:lower())
    end)
  end)

  describe("inverseMapping", function()
    it("should correctly inverse a simple string mapping", function()
        local input = {
            a = "x",
            b = "y",
            c = "z"
        }
        local expected = {
            x = "a",
            y = "b",
            z = "c"
        }
        assert.same(expected, table_utils.inverseMapping(input))
    end)

    it("should correctly inverse a number-to-string mapping", function()
        local input = {
            [1] = "one",
            [2] = "two",
            [3] = "three"
        }
        local expected = {
            one = 1,
            two = 2,
            three = 3
        }
        assert.same(expected, table_utils.inverseMapping(input))
    end)

    it("should handle empty tables", function()
        assert.same({}, table_utils.inverseMapping({}))
    end)

    it("should handle boolean values", function()
        local input = {
            yes = true,
            no = false
        }
        local expected = {
            [true] = "yes",
            [false] = "no"
        }
        assert.same(expected, table_utils.inverseMapping(input))
    end)

    it("should handle mixed type keys and values", function()
        local input = {
            [1] = "one",
            ["two"] = 2,
            [true] = "bool",
            ["key"] = false
        }
        local expected = {
            one = 1,
            [2] = "two",
            bool = true,
            [false] = "key"
        }
        assert.same(expected, table_utils.inverseMapping(input))
    end)

    it("should fail when values are duplicate strings", function()
        local input = {
            a = "same",
            b = "same"
        }
        assert.has_error(function()
            table_utils.inverseMapping(input)
        end, "Value same appears multiple times in the input table")
    end)

    it("should fail when values are duplicate numbers", function()
        local input = {
            first = 1,
            second = 1
        }
        assert.has_error(function()
            table_utils.inverseMapping(input)
        end, "Value 1 appears multiple times in the input table")
    end)

    it("should fail when values are duplicate booleans", function()
        local input = {
            yes = true,
            affirmative = true
        }
        assert.has_error(function()
            table_utils.inverseMapping(input)
        end, "Value true appears multiple times in the input table")
    end)

    it("should handle nil values by ignoring them", function()
        local input = {
            a = "x",
            b = nil,
            c = "z"
        }
        local expected = {
            x = "a",
            z = "c"
        }
        assert.same(expected, table_utils.inverseMapping(input))
    end)

    it("should handle tables as keys", function()
        local key1 = {1, 2, 3}
        local key2 = {4, 5, 6}
        local input = {
            [key1] = "array1",
            [key2] = "array2"
        }
        local result = table_utils.inverseMapping(input)
        assert.equals(key1, result.array1)
        assert.equals(key2, result.array2)
    end)

    it("should fail with tables as duplicate values", function()
        local value = 123
        local input = {
            a = value,
            b = value
        }
        assert.has_error(function()
            table_utils.inverseMapping(input)
        end, "Value " .. tostring(value) .. " appears multiple times in the input table")
    end)
  end)

  describe("keys", function()
    it("should handle empty tables", function()
        local t = {}
        assert.same({}, table_utils.keys(t))
    end)

    it("should sort string keys alphabetically", function()
        local t = {
            charlie = 3,
            alpha = 1,
            beta = 2
        }
        assert.same({"alpha", "beta", "charlie"}, table_utils.keys(t))
    end)

    it("should sort numeric keys numerically", function()
        local t = {
            [3] = "third",
            [1] = "first",
            [2] = "second"
        }
        assert.same({1, 2, 3}, table_utils.keys(t))
    end)

    it("should handle mixed string and number keys", function()
        local t = {
            [1] = "one",
            ["b"] = "bee",
            [2] = "two",
            ["a"] = "ay"
        }
        local keys = table_utils.keys(t)
        table.sort(keys, table_utils.sortCaseInsensitive)
        local expected = {"a", "b", 1, 2}
        table.sort(expected, table_utils.sortCaseInsensitive)
        assert.same(expected, keys)
    end)

    it("should handle boolean keys", function()
        local t = {
            [true] = "yes",
            [false] = "no"
        }
        assert.same({false, true}, table_utils.keys(t))
    end)

    it("should handle sparse array-like tables", function()
        local t = {
            [1] = "one",
            [4] = "four",
            [2] = "two"
        }
        assert.same({1, 2, 4}, table_utils.keys(t))
    end)

    it("should handle large number of keys", function()
        local t = {}
        for i = 100, 1, -1 do
            t[i] = "value" .. i
        end
        local keys = table_utils.keys(t)
        assert.equals(100, #keys)
        for i = 1, 100 do
            assert.equals(i, keys[i])
        end
    end)

    it("should fail gracefully with non-table input", function()
        assert.has_error(function()
            table_utils.keys("not a table")
        end, "Expected table t, got string")

        assert.has_error(function()
            table_utils.keys(123)
        end, "Expected table t, got number")

        assert.has_error(function()
            table_utils.keys(nil)
        end, "Expected table t, got nil")
    end)
  end)

  describe("values", function()
    local values = table_utils.values
    -- Helper function to check if a value is in a set of possible values
    local function contains(possible_values, value)
        for _, v in ipairs(possible_values) do
            if v == value then
                return true
            end
        end
        return false
    end

    it("should handle empty tables", function()
        local t = {}
        assert.same({}, values(t))
    end)

    it("should return values in order of sorted string keys", function()
        local t = {
            charlie = 3,
            alpha = 1,
            beta = 2
        }
        assert.same({1, 2, 3}, values(t))
    end)

    it("should return values in order of sorted numeric keys", function()
        local t = {
            [3] = "third",
            [1] = "first",
            [2] = "second"
        }
        assert.same({"first", "second", "third"}, values(t))
    end)

    it("should maintain original order when keys are mixed types", function()
        local t = {
            [1] = "one",
            ["b"] = "bee",
            [2] = "two",
            ["a"] = "ay"
        }
        local vals = values(t)
        local possible_values = {"one", "two", "bee", "ay"}

        -- Check length
        assert.equals(4, #vals)

        -- Check each value is one of the possible values
        for i = 1, #vals do
            assert.truthy(contains(possible_values, vals[i]),
                string.format("Value '%s' at position %d is not in the expected set", vals[i], i))
        end

        -- Check each possible value appears exactly once
        local count = {}
        for _, v in ipairs(vals) do
            count[v] = (count[v] or 0) + 1
        end
        for _, v in ipairs(possible_values) do
            assert.equals(1, count[v],
                string.format("Value '%s' should appear exactly once", v))
        end
    end)

    it("should handle boolean values", function()
        local t = {
            a = true,
            b = false,
            c = true
        }
        assert.same({true, false, true}, values(t))
    end)

    it("should handle nil values in sparse arrays", function()
        local t = {
            [1] = "one",
            [3] = "three"
            -- key 2 is missing
        }
        assert.same({"one", "three"}, values(t))
    end)

    it("should handle table values", function()
        local t = {
            a = {1, 2},
            b = {3, 4},
            c = {5, 6}
        }
        local vals = values(t)
        assert.same({1, 2}, vals[1])
        assert.same({3, 4}, vals[2])
        assert.same({5, 6}, vals[3])
    end)

    it("should handle function values", function()
        local f1 = function() return 1 end
        local f2 = function() return 2 end
        local t = {
            a = f1,
            b = f2
        }
        local vals = values(t)
        assert.equals(2, #vals)
        assert.equals(1, vals[1]())
        assert.equals(2, vals[2]())
    end)

    it("should maintain original order with non-sortable keys", function()
        local k1 = {}
        local k2 = {}
        local t = {
            [k1] = "value1",
            [k2] = "value2"
        }
        local vals = values(t)
        local possible_values = {"value1", "value2"}

        -- Check length
        assert.equals(2, #vals)

        -- Check each value is one of the possible values
        for i = 1, #vals do
            assert.truthy(contains(possible_values, vals[i]),
                string.format("Value '%s' at position %d is not in the expected set", vals[i], i))
        end

        -- Check each possible value appears exactly once
        local count = {}
        for _, v in ipairs(vals) do
            count[v] = (count[v] or 0) + 1
        end
        for _, v in ipairs(possible_values) do
            assert.equals(1, count[v],
                string.format("Value '%s' should appear exactly once", v))
        end
    end)

    it("should handle large tables with numeric keys", function()
        local t = {}
        for i = 100, 1, -1 do
            t[i] = "value" .. i
        end
        local vals = values(t)
        assert.equals(100, #vals)
        for i = 1, 100 do
            assert.equals("value" .. i, vals[i])
        end
    end)

    it("should fail gracefully with non-table input", function()
        assert.has_error(function()
            values("not a table")
        end, "Expected table t, got string")

        assert.has_error(function()
            values(123)
        end, "Expected table t, got number")

        assert.has_error(function()
            values(nil)
        end, "Expected table t, got nil")
    end)

    it("should handle mixed numeric values", function()
        local t = {
            a = 1.5,
            b = -2,
            c = 0,
            d = 3.14
        }
        assert.same({1.5, -2, 0, 3.14}, values(t))
    end)
  end)

  describe("pairsCount", function()
    local pairsCount = table_utils.pairsCount

    it("should count pairs in sequence tables", function()
        assert.equals(0, pairsCount({}))
        assert.equals(3, pairsCount({1, 2, 3}))
        assert.equals(2, pairsCount({"a", "b"}))
    end)

    it("should count pairs in associative tables", function()
        assert.equals(2, pairsCount({a = 1, b = 2}))
        assert.equals(3, pairsCount({x = "foo", y = "bar", z = "baz"}))
    end)

    it("should count pairs in mixed tables", function()
        assert.equals(4, pairsCount({1, 2, x = "foo", y = "bar"}))
        assert.equals(3, pairsCount({[1] = "a", [2] = "b", ["key"] = "value"}))
    end)

    it("should handle nil values correctly", function()
        local t = {a = 1, b = nil, c = 3}
        assert.equals(2, pairsCount(t)) -- nil values aren't counted
    end)

    it("should reject non-table arguments", function()
        assert.has_error(function() pairsCount(nil) end, "Expected table t, got nil")
        assert.has_error(function() pairsCount(42) end, "Expected table t, got number")
        assert.has_error(function() pairsCount("string") end, "Expected table t, got string")
        assert.has_error(function() pairsCount(true) end, "Expected table t, got boolean")
      end)
    end)

  describe("module API", function()
    describe("getVersion", function()
      it("should return a version string", function()
        local version = table_utils.getVersion()
        assert.is_string(version)
        assert.matches("^%d+%.%d+%.%d+$", version)
      end)
    end)

    describe("callable API", function()
      it("should return version when called with 'version'", function()
        local version = table_utils("version")
        assert.is_not_nil(version)
        -- Version is a semver object
        assert.are.equal(table_utils.getVersion(), tostring(version))
      end)

      it("should call API functions when called with function name", function()
        local result = table_utils("keys", {a = 1, b = 2})
        assert.are.same({"a", "b"}, result)
      end)

      it("should error on unknown operation", function()
        assert.has_error(function()
          table_utils("nonexistent_operation")
        end, "Unknown operation: nonexistent_operation")
      end)
    end)

    describe("__tostring", function()
      it("should return module name and version", function()
        local str = tostring(table_utils)
        assert.is_string(str)
        assert.matches("^table_utils version %d+%.%d+%.%d+$", str)
      end)
    end)
  end)
end)
