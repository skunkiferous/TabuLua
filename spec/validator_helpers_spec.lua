-- validator_helpers_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local validator_helpers = require("validator_helpers")

-- Cell metatable mimicking tsv_model's cell_mt
local cell_mt = {
    __index = function(t, k)
        if k == "value" then return t[1]
        elseif k == "evaluated" then return t[2]
        elseif k == "parsed" then return t[3]
        elseif k == "reformatted" then return t[4]
        end
        return nil
    end,
    __tostring = function(t) return tostring(t[4]) end,
    __type = "cell"
}

--- Creates a mock cell with the given parsed value.
local function makeCell(parsed)
    local s = tostring(parsed)
    return setmetatable({s, s, parsed, s}, cell_mt)
end

--- Creates a mock row from a table of {column_name = parsed_value, ...}.
local function makeRow(map)
    local row = {}
    for k, v in pairs(map) do
        row[k] = makeCell(v)
    end
    return row
end

describe("validator_helpers", function()

  -- ============================================================
  -- Collection Predicates
  -- ============================================================

  describe("unique", function()
    it("should return true for unique values", function()
      local rows = {
        makeRow({name = "Alice"}),
        makeRow({name = "Bob"}),
        makeRow({name = "Charlie"}),
      }
      assert.is_true(validator_helpers.unique(rows, "name"))
    end)

    it("should return false for duplicate values", function()
      local rows = {
        makeRow({name = "Alice"}),
        makeRow({name = "Bob"}),
        makeRow({name = "Alice"}),
      }
      assert.is_false(validator_helpers.unique(rows, "name"))
    end)

    it("should skip nil cells", function()
      local rows = {
        makeRow({name = "Alice"}),
        makeRow({}),  -- no "name" column
        makeRow({name = "Bob"}),
      }
      assert.is_true(validator_helpers.unique(rows, "name"))
    end)

    it("should return true for empty rows", function()
      assert.is_true(validator_helpers.unique({}, "name"))
    end)

    it("should work with numeric values", function()
      local rows = {
        makeRow({id = 1}),
        makeRow({id = 2}),
        makeRow({id = 1}),
      }
      assert.is_false(validator_helpers.unique(rows, "id"))
    end)

    it("should work with boolean values", function()
      local rows = {
        makeRow({flag = true}),
        makeRow({flag = false}),
      }
      assert.is_true(validator_helpers.unique(rows, "flag"))
    end)
  end)

  describe("sum", function()
    it("should sum numeric values", function()
      local rows = {
        makeRow({price = 10}),
        makeRow({price = 20}),
        makeRow({price = 30}),
      }
      assert.are.equal(60, validator_helpers.sum(rows, "price"))
    end)

    it("should skip non-numeric values", function()
      local rows = {
        makeRow({price = 10}),
        makeRow({price = "not a number"}),
        makeRow({price = 30}),
      }
      assert.are.equal(40, validator_helpers.sum(rows, "price"))
    end)

    it("should return 0 for empty rows", function()
      assert.are.equal(0, validator_helpers.sum({}, "price"))
    end)

    it("should skip nil cells", function()
      local rows = {
        makeRow({price = 10}),
        makeRow({}),
        makeRow({price = 20}),
      }
      assert.are.equal(30, validator_helpers.sum(rows, "price"))
    end)

    it("should handle floating point values", function()
      local rows = {
        makeRow({val = 1.5}),
        makeRow({val = 2.5}),
      }
      assert.are.equal(4.0, validator_helpers.sum(rows, "val"))
    end)
  end)

  describe("min", function()
    it("should find the minimum value", function()
      local rows = {
        makeRow({val = 30}),
        makeRow({val = 10}),
        makeRow({val = 20}),
      }
      assert.are.equal(10, validator_helpers.min(rows, "val"))
    end)

    it("should return nil for empty rows", function()
      assert.is_nil(validator_helpers.min({}, "val"))
    end)

    it("should return nil for non-numeric values only", function()
      local rows = {
        makeRow({val = "abc"}),
        makeRow({val = "def"}),
      }
      assert.is_nil(validator_helpers.min(rows, "val"))
    end)

    it("should skip non-numeric values", function()
      local rows = {
        makeRow({val = 50}),
        makeRow({val = "abc"}),
        makeRow({val = 10}),
      }
      assert.are.equal(10, validator_helpers.min(rows, "val"))
    end)

    it("should handle negative values", function()
      local rows = {
        makeRow({val = -5}),
        makeRow({val = 3}),
        makeRow({val = -10}),
      }
      assert.are.equal(-10, validator_helpers.min(rows, "val"))
    end)
  end)

  describe("max", function()
    it("should find the maximum value", function()
      local rows = {
        makeRow({val = 10}),
        makeRow({val = 30}),
        makeRow({val = 20}),
      }
      assert.are.equal(30, validator_helpers.max(rows, "val"))
    end)

    it("should return nil for empty rows", function()
      assert.is_nil(validator_helpers.max({}, "val"))
    end)

    it("should return nil for non-numeric values only", function()
      local rows = {
        makeRow({val = "abc"}),
      }
      assert.is_nil(validator_helpers.max(rows, "val"))
    end)

    it("should skip non-numeric values", function()
      local rows = {
        makeRow({val = 10}),
        makeRow({val = "abc"}),
        makeRow({val = 50}),
      }
      assert.are.equal(50, validator_helpers.max(rows, "val"))
    end)

    it("should handle negative values", function()
      local rows = {
        makeRow({val = -5}),
        makeRow({val = -3}),
        makeRow({val = -10}),
      }
      assert.are.equal(-3, validator_helpers.max(rows, "val"))
    end)
  end)

  describe("avg", function()
    it("should compute the average", function()
      local rows = {
        makeRow({val = 10}),
        makeRow({val = 20}),
        makeRow({val = 30}),
      }
      assert.are.equal(20, validator_helpers.avg(rows, "val"))
    end)

    it("should return nil for empty rows", function()
      assert.is_nil(validator_helpers.avg({}, "val"))
    end)

    it("should return nil for non-numeric values only", function()
      local rows = {
        makeRow({val = "abc"}),
      }
      assert.is_nil(validator_helpers.avg(rows, "val"))
    end)

    it("should skip non-numeric values in average", function()
      local rows = {
        makeRow({val = 10}),
        makeRow({val = "skip"}),
        makeRow({val = 30}),
      }
      assert.are.equal(20, validator_helpers.avg(rows, "val"))
    end)

    it("should handle single value", function()
      local rows = {
        makeRow({val = 42}),
      }
      assert.are.equal(42, validator_helpers.avg(rows, "val"))
    end)
  end)

  describe("count", function()
    it("should count all rows without predicate", function()
      local rows = {
        makeRow({a = 1}),
        makeRow({a = 2}),
        makeRow({a = 3}),
      }
      assert.are.equal(3, validator_helpers.count(rows))
    end)

    it("should return 0 for empty rows without predicate", function()
      assert.are.equal(0, validator_helpers.count({}))
    end)

    it("should count matching rows with predicate", function()
      local rows = {
        makeRow({val = 10}),
        makeRow({val = 20}),
        makeRow({val = 30}),
      }
      local pred = function(row) return row.val.parsed > 15 end
      assert.are.equal(2, validator_helpers.count(rows, pred))
    end)

    it("should return 0 when no rows match predicate", function()
      local rows = {
        makeRow({val = 1}),
        makeRow({val = 2}),
      }
      local pred = function(row) return row.val.parsed > 100 end
      assert.are.equal(0, validator_helpers.count(rows, pred))
    end)

    it("should count entries in dictionary-style tables", function()
      local dict = {
        ["items.tsv"] = {makeRow({val = 1})},
        ["config.tsv"] = {makeRow({val = 2})},
        ["data.tsv"] = {makeRow({val = 3})},
      }
      assert.are.equal(3, validator_helpers.count(dict))
    end)

    it("should return 0 for empty dictionary", function()
      assert.are.equal(0, validator_helpers.count({}))
    end)
  end)

  -- ============================================================
  -- Iteration Helpers
  -- ============================================================

  describe("all", function()
    it("should return true when all rows match", function()
      local rows = {
        makeRow({val = 10}),
        makeRow({val = 20}),
      }
      assert.is_true(validator_helpers.all(rows, function(row)
        return row.val.parsed > 0
      end))
    end)

    it("should return false when any row does not match", function()
      local rows = {
        makeRow({val = 10}),
        makeRow({val = -1}),
        makeRow({val = 20}),
      }
      assert.is_false(validator_helpers.all(rows, function(row)
        return row.val.parsed > 0
      end))
    end)

    it("should return true for empty rows", function()
      assert.is_true(validator_helpers.all({}, function() return false end))
    end)
  end)

  describe("any", function()
    it("should return true when any row matches", function()
      local rows = {
        makeRow({val = -1}),
        makeRow({val = 10}),
      }
      assert.is_true(validator_helpers.any(rows, function(row)
        return row.val.parsed > 0
      end))
    end)

    it("should return false when no row matches", function()
      local rows = {
        makeRow({val = -1}),
        makeRow({val = -2}),
      }
      assert.is_false(validator_helpers.any(rows, function(row)
        return row.val.parsed > 0
      end))
    end)

    it("should return false for empty rows", function()
      assert.is_false(validator_helpers.any({}, function() return true end))
    end)
  end)

  describe("none", function()
    it("should return true when no rows match", function()
      local rows = {
        makeRow({val = -1}),
        makeRow({val = -2}),
      }
      assert.is_true(validator_helpers.none(rows, function(row)
        return row.val.parsed > 0
      end))
    end)

    it("should return false when any row matches", function()
      local rows = {
        makeRow({val = -1}),
        makeRow({val = 10}),
      }
      assert.is_false(validator_helpers.none(rows, function(row)
        return row.val.parsed > 0
      end))
    end)

    it("should return true for empty rows", function()
      assert.is_true(validator_helpers.none({}, function() return true end))
    end)
  end)

  describe("filter", function()
    it("should return matching rows", function()
      local rows = {
        makeRow({val = 10}),
        makeRow({val = 5}),
        makeRow({val = 20}),
      }
      local result = validator_helpers.filter(rows, function(row)
        return row.val.parsed > 8
      end)
      assert.are.equal(2, #result)
      assert.are.equal(10, result[1].val.parsed)
      assert.are.equal(20, result[2].val.parsed)
    end)

    it("should return empty table when no rows match", function()
      local rows = {
        makeRow({val = 1}),
        makeRow({val = 2}),
      }
      local result = validator_helpers.filter(rows, function(row)
        return row.val.parsed > 100
      end)
      assert.are.equal(0, #result)
    end)

    it("should return empty table for empty input", function()
      local result = validator_helpers.filter({}, function() return true end)
      assert.are.equal(0, #result)
    end)
  end)

  describe("find", function()
    it("should return the first matching row", function()
      local rows = {
        makeRow({val = 1}),
        makeRow({val = 10}),
        makeRow({val = 20}),
      }
      local result = validator_helpers.find(rows, function(row)
        return row.val.parsed > 5
      end)
      assert.is_not_nil(result)
      assert.are.equal(10, result.val.parsed)
    end)

    it("should return nil when no row matches", function()
      local rows = {
        makeRow({val = 1}),
        makeRow({val = 2}),
      }
      local result = validator_helpers.find(rows, function(row)
        return row.val.parsed > 100
      end)
      assert.is_nil(result)
    end)

    it("should return nil for empty rows", function()
      local result = validator_helpers.find({}, function() return true end)
      assert.is_nil(result)
    end)
  end)

  -- ============================================================
  -- Lookup Helpers
  -- ============================================================

  describe("lookup", function()
    it("should find a row by column value", function()
      local rows = {
        makeRow({name = "Alice", age = 30}),
        makeRow({name = "Bob", age = 25}),
        makeRow({name = "Charlie", age = 35}),
      }
      local result = validator_helpers.lookup(rows, "name", "Bob")
      assert.is_not_nil(result)
      assert.are.equal(25, result.age.parsed)
    end)

    it("should return nil when value not found", function()
      local rows = {
        makeRow({name = "Alice"}),
        makeRow({name = "Bob"}),
      }
      local result = validator_helpers.lookup(rows, "name", "Eve")
      assert.is_nil(result)
    end)

    it("should return nil for empty rows", function()
      local result = validator_helpers.lookup({}, "name", "Alice")
      assert.is_nil(result)
    end)

    it("should match numeric values", function()
      local rows = {
        makeRow({id = 1, name = "first"}),
        makeRow({id = 2, name = "second"}),
      }
      local result = validator_helpers.lookup(rows, "id", 2)
      assert.is_not_nil(result)
      assert.are.equal("second", result.name.parsed)
    end)

    it("should skip nil cells", function()
      local rows = {
        makeRow({}),
        makeRow({name = "found"}),
      }
      local result = validator_helpers.lookup(rows, "name", "found")
      assert.is_not_nil(result)
      assert.are.equal("found", result.name.parsed)
    end)
  end)

  describe("groupBy", function()
    it("should group rows by column value", function()
      local rows = {
        makeRow({category = "A", val = 1}),
        makeRow({category = "B", val = 2}),
        makeRow({category = "A", val = 3}),
      }
      local groups = validator_helpers.groupBy(rows, "category")
      -- Keys are serialized, so strings get quoted
      assert.is_not_nil(groups['"A"'])
      assert.is_not_nil(groups['"B"'])
      assert.are.equal(2, #groups['"A"'])
      assert.are.equal(1, #groups['"B"'])
    end)

    it("should handle numeric keys", function()
      local rows = {
        makeRow({level = 1, name = "a"}),
        makeRow({level = 2, name = "b"}),
        makeRow({level = 1, name = "c"}),
      }
      local groups = validator_helpers.groupBy(rows, "level")
      assert.is_not_nil(groups["1"])
      assert.is_not_nil(groups["2"])
      assert.are.equal(2, #groups["1"])
      assert.are.equal(1, #groups["2"])
    end)

    it("should skip nil cells", function()
      local rows = {
        makeRow({category = "A"}),
        makeRow({}),
        makeRow({category = "A"}),
      }
      local groups = validator_helpers.groupBy(rows, "category")
      assert.are.equal(2, #groups['"A"'])
    end)

    it("should return empty table for empty rows", function()
      local groups = validator_helpers.groupBy({}, "category")
      assert.are.same({}, groups)
    end)
  end)

  -- ============================================================
  -- Module API
  -- ============================================================

  describe("module API", function()
    it("should have a version", function()
      local version = validator_helpers.getVersion()
      assert.is_not_nil(version)
      assert.is.truthy(version:match("%d+%.%d+%.%d+"))
    end)

    it("should support callable interface for version", function()
      local version = validator_helpers("version")
      assert.is_not_nil(version)
    end)

    it("should support callable interface for operations", function()
      local rows = {
        makeRow({val = 10}),
        makeRow({val = 20}),
      }
      local result = validator_helpers("sum", rows, "val")
      assert.are.equal(30, result)
    end)

    it("should error on unknown operation", function()
      assert.has_error(function()
        validator_helpers("nonexistent")
      end)
    end)

    it("should have a tostring representation", function()
      local str = tostring(validator_helpers)
      assert.is.truthy(str:match("validator_helpers"))
    end)
  end)
end)
