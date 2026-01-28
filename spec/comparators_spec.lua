-- comparators_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local comparators = require("comparators")

describe("comparators", function()
  describe("genTableComparator", function()
    -- Basic comparator for testing
    local function basic_compare(a, b)
      return tostring(a) < tostring(b)
    end

    -- Create comparator once for all tests
    local table_comparator = comparators.genTableComparator(basic_compare, basic_compare)

    it("should compare tables with same keys but different values", function()
      local t1 = {a = 1, b = 2}
      local t2 = {a = 1, b = 3}
      local t3 = {a = 2, b = 1}

      assert.is_true(table_comparator(t1, t2))   -- t1 < t2 because b:2 < b:3
      assert.is_false(table_comparator(t2, t1))  -- t2 > t1
      assert.is_false(table_comparator(t3, t1))  -- t3 > t1 because a:2 > a:1
    end)

    it("should compare tables with different keys", function()
      local t1 = {a = 1, b = 2}
      local t2 = {a = 1, c = 2}
      local t3 = {b = 1, c = 2}

      assert.is_true(table_comparator(t1, t2))   -- t1 < t2 because b < c
      assert.is_false(table_comparator(t2, t1))  -- t2 > t1
      assert.is_true(table_comparator(t1, t3))   -- t1 < t3 because a < b
    end)

    it("should handle tables with different numbers of keys", function()
      local t1 = {a = 1}
      local t2 = {a = 1, b = 2}
      local t3 = {a = 1, b = 2, c = 3}

      assert.is_true(table_comparator(t1, t2))    -- Less keys comes first
      assert.is_true(table_comparator(t2, t3))    -- Less keys comes first
      assert.is_false(table_comparator(t3, t1))   -- More keys comes last
    end)

    it("should handle empty tables", function()
      local empty1 = {}
      local empty2 = {}
      local nonempty = {a = 1}

      assert.is_false(table_comparator(empty1, empty2))  -- Equal tables
      assert.is_true(table_comparator(empty1, nonempty)) -- Empty comes first
      assert.is_false(table_comparator(nonempty, empty1))
    end)

    it("should handle different value types", function()
      -- Create comparator that sorts numbers normally but strings in reverse
      local mixed_comparator = comparators.genTableComparator(basic_compare,
        function(a, b)
          if type(a) == "number" and type(b) == "number" then
            return a < b
          elseif type(a) == "string" and type(b) == "string" then
            return a > b  -- Reverse string comparison
          else
            return tostring(a) < tostring(b)
          end
        end)

      local t1 = {a = 1, b = "x"}
      local t2 = {a = 2, b = "y"}
      local t3 = {a = 1, b = "z"}

      assert.is_true(mixed_comparator(t1, t2))   -- t1 < t2 because 1 < 2
      assert.is_true(mixed_comparator(t3, t1))   -- t3 < t1 because "z" > "x" (reverse string compare)
    end)

    it("should handle nested tables", function()
      local nested_comparator = comparators.genTableComparator(basic_compare,
        function(a, b)
          if type(a) == "table" and type(b) == "table" then
            return table_comparator(a, b)  -- Recursively compare nested tables
          else
            return tostring(a) < tostring(b)
          end
        end)

      local t1 = {a = {x = 1}, b = 2}
      local t2 = {a = {x = 2}, b = 2}
      local t3 = {a = {y = 1}, b = 2}

      assert.is_true(nested_comparator(t1, t2))   -- t1 < t2 because x:1 < x:2
      assert.is_true(nested_comparator(t1, t3))   -- t1 < t3 because x < y
    end)

    it("should be consistent with the strict weak ordering requirements", function()
      local t1 = {a = 1, b = 2}
      local t2 = {a = 1, b = 3}
      local t3 = {a = 1, b = 4}

      -- Irreflexivity: not (x < x)
      assert.is_false(table_comparator(t1, t1))

      -- Asymmetry: if x < y then not (y < x)
      assert.is_true(table_comparator(t1, t2))
      assert.is_false(table_comparator(t2, t1))

      -- Transitivity: if x < y and y < z then x < z
      assert.is_true(table_comparator(t1, t2))
      assert.is_true(table_comparator(t2, t3))
      assert.is_true(table_comparator(t1, t3))
    end)
  end)

  describe("genSeqComparator", function()
    -- Basic comparator for testing
    local function basic_compare(a, b)
      return tostring(a) < tostring(b)
    end

    -- Create comparator once for all tests
    local seq_comparator = comparators.genSeqComparator(basic_compare)

    it("should compare sequences of same length", function()
      local s1 = {1, 2, 3}
      local s2 = {1, 2, 4}
      local s3 = {1, 3, 2}

      assert.is_true(seq_comparator(s1, s2))   -- s1 < s2 because 3 < 4 at pos 3
      assert.is_false(seq_comparator(s2, s1))  -- s2 > s1
      assert.is_false(seq_comparator(s3, s1))  -- s3 > s1 because 3 > 2 at pos 2
    end)

    it("should compare sequences of different lengths", function()
      local s1 = {1, 2}
      local s2 = {1, 2, 3}
      local s3 = {1, 3}

      assert.is_true(seq_comparator(s1, s2))   -- s1 < s2 because s1 is shorter
      assert.is_false(seq_comparator(s2, s1))  -- s2 > s1
      assert.is_true(seq_comparator(s1, s3))   -- s1 < s3 because 2 < 3 at pos 2
    end)

    it("should handle empty sequences", function()
      local empty1 = {}
      local empty2 = {}
      local nonempty = {1}

      assert.is_false(seq_comparator(empty1, empty2))  -- Equal sequences
      assert.is_true(seq_comparator(empty1, nonempty)) -- Empty comes first
      assert.is_false(seq_comparator(nonempty, empty1))
    end)

    it("should handle different value types", function()
      -- Create comparator that sorts numbers normally but strings in reverse
      local mixed_comparator = comparators.genSeqComparator(
        function(a, b)
          if type(a) == "number" and type(b) == "number" then
            return a < b
          elseif type(a) == "string" and type(b) == "string" then
            return a > b  -- Reverse string comparison
          else
            return tostring(a) < tostring(b)
          end
        end)

      local s1 = {1, "x"}
      local s2 = {1, "y"}
      local s3 = {2, "x"}

      assert.is_true(mixed_comparator(s2, s1))   -- s2 < s1 because "y" > "x" (reverse string compare)
      assert.is_false(mixed_comparator(s3, s1))  -- s3 > s1 because 2 > 1
    end)

    it("should handle nested sequences", function()
      local nested_comparator = comparators.genSeqComparator(
        function(a, b)
          if type(a) == "table" and type(b) == "table" then
            return seq_comparator(a, b)  -- Recursively compare nested sequences
          else
            return tostring(a) < tostring(b)
          end
        end)

      local s1 = {{1, 2}, 3}
      local s2 = {{1, 3}, 3}
      local s3 = {{2, 1}, 3}

      assert.is_true(nested_comparator(s1, s2))   -- s1 < s2 because {1,2} < {1,3}
      assert.is_true(nested_comparator(s1, s3))   -- s1 < s3 because 1 < 2
    end)

    it("should be consistent with strict weak ordering requirements", function()
      local s1 = {1, 2, 3}
      local s2 = {1, 2, 4}
      local s3 = {1, 2, 5}

      -- Irreflexivity: not (x < x)
      assert.is_false(seq_comparator(s1, s1))

      -- Asymmetry: if x < y then not (y < x)
      assert.is_true(seq_comparator(s1, s2))
      assert.is_false(seq_comparator(s2, s1))

      -- Transitivity: if x < y and y < z then x < z
      assert.is_true(seq_comparator(s1, s2))
      assert.is_true(seq_comparator(s2, s3))
      assert.is_true(seq_comparator(s1, s3))
    end)
  end)

  describe("composeComparator", function()
    -- Basic comparators for different types
    local function number_compare(a, b)
      return a < b
    end

    local function string_compare(a, b)
      return a:lower() < b:lower()
    end

    local function bool_compare(a, b)
      return (not a) and b  -- false < true
    end

    it("should reject invalid inputs", function()
      -- Not a table
      assert.has_error(function()
      comparators.composeComparator("not a table")
      end, "comparators must be a list of functions")

      -- Contains non-function
      assert.has_error(function()
      comparators.composeComparator({number_compare, "not a function"})
      end, "comparators[x] must be a function")

      -- Valid comparator but invalid input
      local comparator = comparators.composeComparator({number_compare, string_compare})
      assert.has_error(function()
        comparator({[99] = "invalid"}, {1, "b"})  -- Not a sequence starting at 1
      end, "t1 is not a (sparse) sequence")
    end)

    it("should compare tuples with same types", function()
      local number_comparator = comparators.composeComparator({number_compare, number_compare})

      local t1 = {1, 2}
      local t2 = {1, 3}
      local t3 = {2, 1}

      assert.is_true(number_comparator(t1, t2))   -- t1 < t2 because 2 < 3
      assert.is_false(number_comparator(t2, t1))  -- t2 > t1
      assert.is_false(number_comparator(t3, t1))  -- t3 > t1 because 2 > 1
    end)

    it("should compare tuples with different types", function()
      local mixed_comparator = comparators.composeComparator({
        number_compare,
        string_compare,
        bool_compare
      })

      local t1 = {1, "abc", false}
      local t2 = {1, "abc", true}
      local t3 = {1, "def", false}
      local t4 = {2, "abc", false}

      assert.is_true(mixed_comparator(t1, t2))   -- t1 < t2 because false < true
      assert.is_true(mixed_comparator(t1, t3))   -- t1 < t3 because "abc" < "def"
      assert.is_true(mixed_comparator(t1, t4))   -- t1 < t4 because 1 < 2
    end)

    it("should handle nil values in tuples", function()
      local comparator = comparators.composeComparator({
        number_compare,
        string_compare
      })

      local t1 = {1, nil}
      local t2 = {1, "abc"}
      local t3 = {nil, "abc"}
      local t4 = {1, "def"}

      assert.is_true(comparator(t1, t2))    -- t1 < t2 because nil < "abc"
      assert.is_true(comparator(t3, t4))    -- t3 < t4 because nil < 1
      assert.is_false(comparator(t2, t1))   -- t2 > t1
    end)

    it("should handle sparse sequences", function()
      local comparator = comparators.composeComparator({
        number_compare,
        string_compare,
        number_compare
      })

      local t1 = {1, nil, 3}
      local t2 = {1, "abc", nil}

      assert.is_true(comparator(t1, t2))    -- t1 < t2 because nil < "abc"
      assert.is_false(comparator(t2, t1))   -- t2 > t1
    end)

    it("should be consistent with strict weak ordering requirements", function()
      local comparator = comparators.composeComparator({
        number_compare,
        string_compare
      })

      local t1 = {1, "abc"}
      local t2 = {1, "def"}
      local t3 = {1, "ghi"}

      -- Irreflexivity: not (x < x)
      assert.is_false(comparator(t1, t1))

      -- Asymmetry: if x < y then not (y < x)
      assert.is_true(comparator(t1, t2))
      assert.is_false(comparator(t2, t1))

      -- Transitivity: if x < y and y < z then x < z
      assert.is_true(comparator(t1, t2))
      assert.is_true(comparator(t2, t3))
      assert.is_true(comparator(t1, t3))
    end)

    it("should compare tuples of different lengths correctly", function()
      local long_comparator = comparators.composeComparator({
        number_compare,
        string_compare,
        bool_compare,
        number_compare
      })

      local short_tuple = {1, "abc", true}
      local long_tuple = {1, "abc", true, 5}

      -- Short tuple treated as having nil in position 4
      assert.is_true(long_comparator(short_tuple, long_tuple))
      assert.is_false(long_comparator(long_tuple, short_tuple))
    end)
  end)

  describe("equals", function()
    it("should handle non-table values", function()
        -- Basic equality
        assert.is_true(comparators.equals(nil, nil))
        assert.is_true(comparators.equals(42, 42))
        assert.is_true(comparators.equals("test", "test"))
        assert.is_true(comparators.equals(true, true))

        -- Basic inequality
        assert.is_false(comparators.equals(1, 2))
        assert.is_false(comparators.equals("a", "b"))
        assert.is_false(comparators.equals(true, false))
        assert.is_false(comparators.equals(42, "42"))
    end)

    it("should handle empty and simple tables", function()
        assert.is_true(comparators.equals({}, {}))
        assert.is_true(comparators.equals({1, 2, 3}, {1, 2, 3}))
        assert.is_true(comparators.equals({a = 1, b = 2}, {b = 2, a = 1}))

        assert.is_false(comparators.equals({}, {1}))
        assert.is_false(comparators.equals({1, 2}, {1, 2, 3}))
        assert.is_false(comparators.equals({a = 1}, {a = 2}))
    end)

    it("should handle nested tables", function()
        assert.is_true(comparators.equals(
            {a = {b = 1}},
            {a = {b = 1}}
        ))
        assert.is_true(comparators.equals(
            {a = {b = {c = 1}}},
            {a = {b = {c = 1}}}
        ))

        assert.is_false(comparators.equals(
            {a = {b = 1}},
            {a = {b = 2}}
        ))
        assert.is_false(comparators.equals(
            {a = {b = {c = 1}}},
            {a = {b = {c = 2}}}
        ))
    end)

    it("should detect direct recursion", function()
        local t1 = {}
        t1.a = t1
        local t2 = {}
        t2.a = t2

        local result, err = comparators.equals(t1, t2)
        assert.is_nil(result)
        assert.equals("recursive table detected", err)
    end)

    it("should detect indirect recursion", function()
        local t1 = {}
        local t2 = {t1}
        t1.a = t2

        local t3 = {}
        local t4 = {t3}
        t3.a = t4

        local result, err = comparators.equals(t1, t3)
        assert.is_nil(result)
        assert.equals("recursive table detected", err)
    end)

    it("should handle shared references without recursion", function()
        local shared1 = {x = 1}
        local t1 = {
            a = shared1,
            b = shared1
        }

        local shared2 = {x = 1}
        local t2 = {
            a = shared2,
            b = shared2
        }

        assert.is_true(comparators.equals(t1, t2))
    end)

    it("should enforce maximum depth", function()
        -- Create deeply nested tables
        local function make_deep_table(depth)
            local result = {}
            local current = result
            for i = 1, depth do
                current.next = {}
                current = current.next
            end
            return result
        end

        -- Tables within depth limit should work
        local t1 = make_deep_table(9)
        local t2 = make_deep_table(9)
        assert.is_true(comparators.equals(t1, t2))

        -- Tables exceeding depth limit should error
        t1 = make_deep_table(11)
        t2 = make_deep_table(11)
        local result, err = comparators.equals(t1, t2)
        assert.is_nil(result)
        assert.equals("maximum table depth exceeded", err)
    end)

    it("should handle mixed value types in tables", function()
        local t1 = {
            a = 1,
            b = "string",
            c = true,
            d = {
                x = 1,
                y = "nested"
            }
        }
        local t2 = {
            a = 1,
            b = "string",
            c = true,
            d = {
                x = 1,
                y = "nested"
            }
        }
        assert.is_true(comparators.equals(t1, t2))

        -- Change one deep value
        t2.d.y = "different"
        assert.is_false(comparators.equals(t1, t2))
    end)

    it("should handle tables as keys", function()
      -- Simple table keys
      local t1 = {}
      t1[{x = 1}] = "a"
      local t2 = {}
      t2[{x = 1}] = "a"
      assert.is_true(comparators.equals(t1, t2))

      -- Different table key content makes tables not equal
      local t3 = {}
      t3[{x = 2}] = "a"
      assert.is_false(comparators.equals(t1, t3))

      -- Nested table keys
      local t4 = {}
      t4[{x = {y = 1}}] = "a"
      local t5 = {}
      t5[{x = {y = 1}}] = "a"
      assert.is_true(comparators.equals(t4, t5))

      -- Multiple table keys
      local t6 = {}
      t6[{x = 1}] = "a"
      t6[{y = 2}] = "b"
      local t7 = {}
      t7[{y = 2}] = "b"
      t7[{x = 1}] = "a"
      assert.is_true(comparators.equals(t6, t7))

      -- Mixed regular and table keys
      local t8 = {}
      t8[1] = "a"
      t8[{x = 1}] = "b"
      t8["key"] = "c"
      local t9 = {}
      t9["key"] = "c"
      t9[{x = 1}] = "b"
      t9[1] = "a"
      assert.is_true(comparators.equals(t8, t9))
    end)
  end)

  describe("module API", function()
    describe("getVersion", function()
      it("should return a version string", function()
        local version = comparators.getVersion()
        assert.is_string(version)
        assert.matches("^%d+%.%d+%.%d+$", version)
      end)
    end)

    describe("callable API", function()
      it("should return version when called with 'version'", function()
        local version = comparators("version")
        assert.is_not_nil(version)
        -- Version is a semver object
        assert.are.equal(comparators.getVersion(), tostring(version))
      end)

      it("should call API functions when called with function name", function()
        local result = comparators("equals", 42, 42)
        assert.is_true(result)
      end)

      it("should error on unknown operation", function()
        assert.has_error(function()
          comparators("nonexistent_operation")
        end, "Unknown operation: nonexistent_operation")
      end)
    end)

    describe("__tostring", function()
      it("should return module name and version", function()
        local str = tostring(comparators)
        assert.is_string(str)
        assert.matches("^comparators version %d+%.%d+%.%d+$", str)
      end)
    end)
  end)
end)
