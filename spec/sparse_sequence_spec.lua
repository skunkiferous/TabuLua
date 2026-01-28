-- sparse_sequence_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local sparse_sequence = require("sparse_sequence")

-- Constants used to make the "test sparse sequences smaller"
local MAX_NIL_GAP = 2
local MAX_NIL_RATIO = 0.4
local function isSparseSequence(t)
  return sparse_sequence.isSparseSequence(t, MAX_NIL_GAP, MAX_NIL_RATIO)
end

describe("sparse_sequence", function()
  describe("regular sequences", function()
    it("should accept standard sequences", function()
        assert.is_true(isSparseSequence({1, 2, 3, 4, 5}))
    end)

    it("should accept empty sequences", function()
        assert.is_true(isSparseSequence({}))
    end)

    it("should accept single element sequences", function()
        assert.is_true(isSparseSequence({1}))
    end)
  end)

  describe("sequences with nil values", function()
    it("should accept sequences with a single nil", function()
        assert.is_true(isSparseSequence({1, 2, nil, 4, 5}))
    end)

    it("should accept sequences with two consecutive nils", function()
        assert.is_true(isSparseSequence({1, nil, nil, 4, 5}))
    end)

    it("should accept sequences with multiple separated nils", function()
        assert.is_true(isSparseSequence({1, 2, nil, 4, nil, 6, nil, 8}))
    end)

    it("should reject sequences with too many consecutive nils", function()
        assert.is_false(isSparseSequence({1, nil, nil, nil, 5}))
    end)

    it("should reject sequences with too high nil ratio", function()
        assert.is_false(isSparseSequence({1, nil, nil, 2, nil, nil, 7}))
    end)
  end)

  describe("invalid sequences", function()
    it("should reject non-table inputs", function()
        assert.is_false(isSparseSequence("not a table"))
        assert.is_false(isSparseSequence(42))
        assert.is_false(isSparseSequence(nil))
        assert.is_false(isSparseSequence(true))
    end)

    it("should reject sequences with non-numeric keys", function()
        assert.is_false(isSparseSequence({1, 2, 3, foo = "bar"}))
    end)

    it("should reject sequences with non-integer numeric keys", function()
        assert.is_false(isSparseSequence({1, 2, 3, [1.5] = 4}))
    end)

    it("should reject sequences with keys below minimum index", function()
        assert.is_false(isSparseSequence({[0] = 0, 1, 2, 3}))
        assert.is_false(isSparseSequence({[-1] = -1, 1, 2, 3}))
    end)

    it("should reject sequences with sparse keys beyond maximum gap", function()
        assert.is_false(isSparseSequence({1, 2, [10] = 10}))
    end)
  end)

  describe("edge cases", function()
    it("should accept sequences not starting at 1", function()
        assert.is_true(isSparseSequence({[2] = 2, [3] = 3, [4] = 4}))
    end)

    it("should handle sequences at the nil ratio threshold", function()
        -- With MAX_NIL_RATIO = 0.3, this sequence is exactly at the threshold
        assert.is_true(isSparseSequence({1, 2, nil, 4, nil, 6, nil}))
    end)

    it("should handle sequences at the consecutive nil threshold", function()
        -- With MAX_NIL_GAP = 2, this sequence has maximum allowed consecutive nils
        assert.is_true(isSparseSequence({1, nil, nil, 4, 7, 9}))
    end)

    it("should reject sequences just over the nil ratio threshold", function()
        -- This sequence has slightly too many nils
        assert.is_false(isSparseSequence({1, nil, nil, nil, 5, nil, nil, 8}))
    end)
  end)

  describe("getSparseSequenceSize", function()
    it("should handle valid sequences", function()
      -- Test empty table
      assert.equals(0, sparse_sequence.getSparseSequenceSize({}))

      -- Test perfect sequence
      assert.equals(3, sparse_sequence.getSparseSequenceSize({1, 2, 3}))

      -- Test sequence with valid gaps
      assert.equals(4, sparse_sequence.getSparseSequenceSize({[1] = "a", [3] = "c", [4] = "d"}))
    end)

    it("should handle invalid sequences", function()
      -- Test sequence starting before 1
      assert.is_nil(sparse_sequence.getSparseSequenceSize({[0] = "x", [1] = "a"}))

      -- Test sequence with non-numeric key
      assert.is_nil(sparse_sequence.getSparseSequenceSize({a = 1}))

      -- Test sequence with gap too large
      assert.is_nil(sparse_sequence.getSparseSequenceSize({[1] = "a", [5] = "e"}))
    end)

    it("should handle edge cases", function()
      -- Test single element
      assert.equals(1, sparse_sequence.getSparseSequenceSize({[1] = "a"}))

      -- Test non-table input
      assert.is_nil(sparse_sequence.getSparseSequenceSize("not a table"))
    end)
  end)

  describe("insertRemoveNils", function()
    it("should validate inputs correctly", function()
      -- Test invalid input types
      local result, err = sparse_sequence.insertRemoveNils("not a table", 1, 1)
      assert.is_nil(result)
      assert.matches("Expected table as first parameter", err)

      result, err = sparse_sequence.insertRemoveNils({}, "not a number", 1)
      assert.is_nil(result)
      assert.matches("Expected integer index as second parameter", err)

      result, err = sparse_sequence.insertRemoveNils({}, 1, "not a number")
      assert.is_nil(result)
      assert.matches("Expected integer count as third parameter", err)

      -- Test invalid index values
      result, err = sparse_sequence.insertRemoveNils({}, 0, 1)
      assert.is_nil(result)
      assert.matches("Index cannot be less than 1", err)

      result, err = sparse_sequence.insertRemoveNils({}, 1.5, 1)
      assert.is_nil(result)
      assert.matches("Expected integer index as second parameter", err)

      -- Test invalid count values
      result, err = sparse_sequence.insertRemoveNils({}, 1, 1.5)
      assert.is_nil(result)
      assert.matches("Expected integer count as third parameter", err)
    end)

    it("should handle count = 0", function()
      local t = {1, nil, 3, nil, 5}
      local result = sparse_sequence.insertRemoveNils(t, 2, 0)
      assert.is_true(result)
      assert.same({1, nil, 3, nil, 5}, t)
    end)

    it("should insert nils correctly", function()
      -- Insert in middle
      local t1 = {1, 2, 3, 4, 5}
      local result, err = sparse_sequence.insertRemoveNils(t1, 3, 2)
      assert.is_nil(err)
      assert.is_true(result)
      assert.same({1, 2, nil, nil, 3, 4, 5}, t1)

      -- Insert at start
      local t2 = {1, 2, 3}
      result, err = sparse_sequence.insertRemoveNils(t2, 1, 2)
      assert.is_nil(err)
      assert.is_true(result)
      assert.same({nil, nil, 1, 2, 3}, t2)

      -- Insert at end
      local t3 = {1, 2, 3}
      result, err = sparse_sequence.insertRemoveNils(t3, 4, 2)
      assert.is_nil(err)
      assert.is_true(result)
      assert.same({1, 2, 3, nil, nil}, t3)

      -- Insert in sparse sequence
      local t4 = {1, nil, 3, nil, 5}
      result, err = sparse_sequence.insertRemoveNils(t4, 2, 2)
      assert.is_nil(err)
      assert.is_true(result)
      assert.same({1, nil, nil, nil, 3, nil, 5}, t4)
    end)

    it("should remove nils correctly", function()
      -- Remove from middle
      local t1 = {1, nil, nil, 2, 3}
      local result, err = sparse_sequence.insertRemoveNils(t1, 2, -2)
      assert.is_nil(err)
      assert.is_true(result)
      assert.same({1, 2, 3}, t1)

      -- Remove from start
      local t2 = {nil, nil, 1, 2, 3}
      result, err = sparse_sequence.insertRemoveNils(t2, 1, -2)
      assert.is_nil(err)
      assert.is_true(result)
      assert.same({1, 2, 3}, t2)

      -- Remove from end
      local t3 = {1, 2, 3, nil, nil}
      result, err = sparse_sequence.insertRemoveNils(t3, 4, -2)
      assert.is_nil(err)
      assert.is_true(result)
      assert.same({1, 2, 3}, t3)

      -- Remove from sparse sequence
      local t4 = {1, nil, nil, nil, 2, nil, 3}
      result, err = sparse_sequence.insertRemoveNils(t4, 2, -2)
      assert.is_nil(err)
      assert.is_true(result)
      assert.same({1, nil, 2, nil, 3}, t4)
    end)

    it("should fail when trying to remove more nils than available", function()
      local t = {1, nil, 2, nil, 3}
      local result, err = sparse_sequence.insertRemoveNils(t, 2, -3)
      assert.is_nil(result)
      assert.matches("Not enough nils to remove", err)
      -- Verify table wasn't modified
      assert.same({1, nil, 2, nil, 3}, t)
    end)

    it("should fail when operation would create invalid sparse sequence", function()
      -- Create a sequence that would have too many consecutive nils
      local t = {1, nil, 3, 4, 5}
      local result, err = sparse_sequence.insertRemoveNils(t, 2, 200)
      assert.is_nil(result)
      assert.matches("Insert count exceeds maximum allowed gap", err)
    end)

    it("should handle non-sequence tables", function()
      local t = {a = 1, b = 2}
      local result, err = sparse_sequence.insertRemoveNils(t, 1, 1)
      assert.is_nil(result)
      assert.matches("Input is not a valid sparse sequence", err)
    end)

    it("should handle integer overflow check", function()
      local t = {1, 2, 3}
      local result, err = sparse_sequence.insertRemoveNils(t, math.maxinteger - 1, 3)
      assert.is_nil(result)
      assert.matches("Operation would exceed maximum integer value", err)
      -- Verify table wasn't modified
      assert.same({1, 2, 3}, t)
    end)

    it("should not support 'mixed' tables", function()
      -- Test with non-numeric keys alongside sequence
      local t = {1, 2, 3, extra = "value"}
      local result, err = sparse_sequence.insertRemoveNils(t, 2, 2)
      assert.is_nil(result)
      assert.matches("Input is not a valid sparse sequence", err)
    end)
  end)

  describe("custom maxNilGap and maxNilRatio parameters", function()
    describe("isSparseSequence with custom maxNilGap", function()
      it("should accept sequences with gaps up to custom maxNilGap", function()
        -- Sequence with 3 consecutive nils: passes with maxNilGap=3, fails with maxNilGap=2
        -- Use maxNilRatio=1 to isolate the gap check
        local t = {1, nil, nil, nil, 5}
        assert.is_true(sparse_sequence.isSparseSequence(t, 3, 1))
        assert.is_true(sparse_sequence.isSparseSequence(t, 4, 1))
        assert.is_false(sparse_sequence.isSparseSequence(t, 2, 1))
        assert.is_false(sparse_sequence.isSparseSequence(t, 1, 1))
      end)

      it("should handle maxNilGap=1 (single nil only)", function()
        -- Use maxNilRatio=1 to isolate the gap check
        assert.is_true(sparse_sequence.isSparseSequence({1, nil, 3}, 1, 1))
        assert.is_false(sparse_sequence.isSparseSequence({1, nil, nil, 4}, 1, 1))
      end)

      it("should handle maxNilGap=0 (no gaps allowed)", function()
        assert.is_true(sparse_sequence.isSparseSequence({1, 2, 3}, 0, 1))
        assert.is_false(sparse_sequence.isSparseSequence({1, nil, 3}, 0, 1))
        -- Starting gap should also be rejected
        assert.is_false(sparse_sequence.isSparseSequence({[2] = 2, [3] = 3}, 0, 1))
      end)
    end)

    describe("isSparseSequence with custom maxNilRatio", function()
      it("should accept sequences with nil ratio up to custom maxNilRatio", function()
        -- Sequence {1, nil, nil, 4} has ratio 2/4 = 0.5
        local t = {1, nil, nil, 4}
        assert.is_true(sparse_sequence.isSparseSequence(t, 10, 0.5))
        assert.is_true(sparse_sequence.isSparseSequence(t, 10, 0.6))
        assert.is_false(sparse_sequence.isSparseSequence(t, 10, 0.4))
      end)

      it("should handle maxNilRatio=0 (no nils allowed)", function()
        assert.is_true(sparse_sequence.isSparseSequence({1, 2, 3}, 10, 0))
        assert.is_false(sparse_sequence.isSparseSequence({1, nil, 3}, 10, 0))
      end)

      it("should handle maxNilRatio=1 (all nils allowed)", function()
        -- Even with maxNilRatio=1, maxNilGap still applies
        assert.is_true(sparse_sequence.isSparseSequence({[1] = 1, [3] = 3}, 10, 1))
        assert.is_true(sparse_sequence.isSparseSequence({1, nil, nil, nil, 5}, 10, 1))
      end)
    end)

    describe("isSparseSequence with both custom parameters", function()
      it("should require both constraints to pass", function()
        -- Sequence with 3 nils out of 5 = 60% nil ratio, max gap = 2
        local t = {1, nil, nil, 4, nil, 6}
        -- Passes gap check (2), passes ratio check (3/6 = 0.5)
        assert.is_true(sparse_sequence.isSparseSequence(t, 2, 0.5))
        -- Passes gap check (2), fails ratio check (0.4 < 0.5)
        assert.is_false(sparse_sequence.isSparseSequence(t, 2, 0.4))
        -- Fails gap check (1 < 2), passes ratio check
        assert.is_false(sparse_sequence.isSparseSequence(t, 1, 0.5))
      end)

      it("should handle edge case at exact thresholds", function()
        -- Sequence with exactly 2 consecutive nils and exactly 40% nil ratio
        local t = {1, nil, nil, 4, 5} -- 2 nils, 5 total = 40%
        assert.is_true(sparse_sequence.isSparseSequence(t, 2, 0.4))
        assert.is_false(sparse_sequence.isSparseSequence(t, 1, 0.4))
        assert.is_false(sparse_sequence.isSparseSequence(t, 2, 0.39))
      end)
    end)

    describe("getSparseSequenceSize with custom maxNilGap", function()
      it("should return size when gap is within custom maxNilGap", function()
        -- Use maxNilRatio=1 to isolate the gap check
        local t = {1, nil, nil, nil, 5}
        assert.equals(5, sparse_sequence.getSparseSequenceSize(t, 3, 1))
        assert.equals(5, sparse_sequence.getSparseSequenceSize(t, 4, 1))
        assert.is_nil(sparse_sequence.getSparseSequenceSize(t, 2, 1))
      end)

      it("should handle maxNilGap=0", function()
        assert.equals(3, sparse_sequence.getSparseSequenceSize({1, 2, 3}, 0, 1))
        assert.is_nil(sparse_sequence.getSparseSequenceSize({1, nil, 3}, 0, 1))
      end)
    end)

    describe("getSparseSequenceSize with custom maxNilRatio", function()
      it("should return size when ratio is within custom maxNilRatio", function()
        -- Sequence {1, nil, nil, 4} has ratio 2/4 = 0.5
        local t = {1, nil, nil, 4}
        assert.equals(4, sparse_sequence.getSparseSequenceSize(t, 10, 0.5))
        assert.equals(4, sparse_sequence.getSparseSequenceSize(t, 10, 0.6))
        assert.is_nil(sparse_sequence.getSparseSequenceSize(t, 10, 0.4))
      end)

      it("should handle maxNilRatio=0", function()
        assert.equals(3, sparse_sequence.getSparseSequenceSize({1, 2, 3}, 10, 0))
        assert.is_nil(sparse_sequence.getSparseSequenceSize({1, nil, 3}, 10, 0))
      end)
    end)

    describe("getSparseSequenceSize with both custom parameters", function()
      it("should require both constraints to pass", function()
        local t = {1, nil, nil, 4, nil, 6}
        assert.equals(6, sparse_sequence.getSparseSequenceSize(t, 2, 0.5))
        assert.is_nil(sparse_sequence.getSparseSequenceSize(t, 2, 0.4))
        assert.is_nil(sparse_sequence.getSparseSequenceSize(t, 1, 0.5))
      end)
    end)

    describe("default vs custom parameters comparison", function()
      it("should use module defaults when parameters not provided", function()
        -- Module defaults: MAX_NIL_GAP=10, MAX_NIL_RATIO=0.5
        -- Sequence with 5 consecutive nils
        local t = {1, nil, nil, nil, nil, nil, 7}
        -- Should fail with defaults (gap=5 < 10 OK, but ratio=5/7 ≈ 0.71 > 0.5)
        assert.is_false(sparse_sequence.isSparseSequence(t)) -- fails ratio
        -- But passes with higher ratio threshold
        assert.is_true(sparse_sequence.isSparseSequence(t, 10, 0.8))
      end)

      it("should allow overriding only maxNilGap with high ratio", function()
        -- Use maxNilRatio=1 to isolate the gap check when testing gap override
        -- Table with 11 consecutive nils (positions 2-12)
        local t = {1, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 13}
        -- With default ratio (0.5), this would fail anyway due to ratio
        -- So test with maxNilRatio=1 to show gap constraint matters
        assert.is_false(sparse_sequence.isSparseSequence(t, 10, 1)) -- gap=11 exceeds 10
        assert.is_true(sparse_sequence.isSparseSequence(t, 11, 1))  -- gap=11 equals 11, passes
      end)

      it("should allow overriding only maxNilRatio with default gap", function()
        -- Sequence with gap within default (10) but high nil ratio
        local t = {1, nil, nil, nil, nil, nil, 7, 8} -- 5 nils, 8 total = 62.5%
        assert.is_false(sparse_sequence.isSparseSequence(t))        -- fails ratio (0.625 > 0.5)
        assert.is_true(sparse_sequence.isSparseSequence(t, nil, 0.7)) -- custom ratio works
      end)
    end)
  end)

  describe("isSubSetSequence", function()
    it("should handle basic subset cases", function()
        assert.is_true(sparse_sequence.isSubSetSequence({1, 2, 3, 4}, {1, 2}))
        assert.is_true(sparse_sequence.isSubSetSequence({1, 2, 3, 4}, {3, 4}))
        assert.is_true(sparse_sequence.isSubSetSequence({1, 2, 3, 4}, {1, 4}))
        assert.is_true(sparse_sequence.isSubSetSequence({1, 2, 3, 4}, {}))  -- empty set is subset of all sets
    end)

    it("should handle check order if specified", function()
        assert.is_true(sparse_sequence.isSubSetSequence({1, 2, 3, 4}, {1, 2}, true))
        assert.is_true(sparse_sequence.isSubSetSequence({1, 2, 3, 4}, {3, 4}, true))
        assert.is_false(sparse_sequence.isSubSetSequence({1, 2, 3, 4}, {3, 2}, true))
    end)

    it("should handle equal sets", function()
        assert.is_true(sparse_sequence.isSubSetSequence({1, 2, 3}, {1, 2, 3}))
        assert.is_true(sparse_sequence.isSubSetSequence({}, {}))
    end)

    it("should handle non-subset cases", function()
        assert.is_false(sparse_sequence.isSubSetSequence({1, 2, 3}, {4}))
        assert.is_false(sparse_sequence.isSubSetSequence({1, 2, 3}, {1, 4}))
        assert.is_false(sparse_sequence.isSubSetSequence({1, 2}, {1, 2, 3}))  -- superset can't be smaller
    end)

    it("should handle duplicate values", function()
        assert.is_true(sparse_sequence.isSubSetSequence({1, 2, 2, 3}, {1, 2}))
        assert.is_true(sparse_sequence.isSubSetSequence({1, 2, 3}, {2, 2}))  -- duplicates in subset are allowed
        assert.is_true(sparse_sequence.isSubSetSequence({1, 1, 2}, {1, 1}))  -- same duplicates
    end)

    it("should handle different value types", function()
        assert.is_true(sparse_sequence.isSubSetSequence({1, "2", true}, {1, true}))
        assert.is_true(sparse_sequence.isSubSetSequence({1, "2", nil}, {1, nil}))
        local t = {a = 1}
        assert.is_true(sparse_sequence.isSubSetSequence({1, t, "3"}, {1, t}))
    end)

    it("should handle invalid inputs", function()
        assert.is_false(sparse_sequence.isSubSetSequence(nil, {1, 2}))
        assert.is_false(sparse_sequence.isSubSetSequence({1, 2}, nil))
        assert.is_false(sparse_sequence.isSubSetSequence("not a table", {1, 2}))
        assert.is_false(sparse_sequence.isSubSetSequence({1, 2}, "not a table"))
    end)

    it("should handle non-sequence tables", function()
        assert.is_false(sparse_sequence.isSubSetSequence({a = 1, b = 2}, {1, 2}))
        assert.is_false(sparse_sequence.isSubSetSequence({1, 2}, {a = 1, b = 2}))
        assert.is_false(sparse_sequence.isSubSetSequence({1, a = 2}, {1, 2}))
    end)
  end)

  describe("module API", function()
    describe("getVersion", function()
      it("should return a version string", function()
        local version = sparse_sequence.getVersion()
        assert.is_string(version)
        assert.matches("^%d+%.%d+%.%d+$", version)
      end)
    end)

    describe("callable API", function()
      it("should return version when called with 'version'", function()
        local version = sparse_sequence("version")
        assert.is_not_nil(version)
        -- Version is a semver object
        assert.are.equal(sparse_sequence.getVersion(), tostring(version))
      end)

      it("should call API functions when called with function name", function()
        local result = sparse_sequence("isSparseSequence", {1, 2, 3})
        assert.is_true(result)
      end)

      it("should error on unknown operation", function()
        assert.has_error(function()
          sparse_sequence("nonexistent_operation")
        end, "Unknown operation: nonexistent_operation")
      end)
    end)

    describe("__tostring", function()
      it("should return module name and version", function()
        local str = tostring(sparse_sequence)
        assert.is_string(str)
        assert.matches("^sparse_sequence version %d+%.%d+%.%d+$", str)
      end)
    end)
  end)
end)
