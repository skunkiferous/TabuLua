-- error_reporting_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local exploded_columns = require("exploded_columns")
local read_only = require("read_only")
local unwrap = read_only.unwrap

describe("exploded_columns", function()
  describe("isTupleStructure", function()
    it("should return false for non-tables", function()
      assert.is_false(exploded_columns.isTupleStructure(nil))
      assert.is_false(exploded_columns.isTupleStructure(true))
      assert.is_false(exploded_columns.isTupleStructure(false))
      assert.is_false(exploded_columns.isTupleStructure(123))
      assert.is_false(exploded_columns.isTupleStructure(456.789))
      assert.is_false(exploded_columns.isTupleStructure("not a table"))
      assert.is_false(exploded_columns.isTupleStructure(function () end))
    end)
    it("should return false for non-tuple-structure tables", function()
      assert.is_false(exploded_columns.isTupleStructure({}))
      assert.is_false(exploded_columns.isTupleStructure({a=1, b=2}))
      assert.is_false(exploded_columns.isTupleStructure({[1]=1, b=2}))
      assert.is_false(exploded_columns.isTupleStructure({_1=1, b=2}))
      assert.is_false(exploded_columns.isTupleStructure({_1=1, _5=5}))
    end)
    it("should return false for tuple-structure tables", function()
      local is_tuple, indices = exploded_columns.isTupleStructure({_1=1, _2=2})
      assert.is_true(is_tuple)
      assert.same({1,2}, indices)
    end)
  end)

  describe("generateCollapsedColumnSpec", function()
    it("should return fail for bad arg types", function()
      local s = {type_spec = "string"}
      assert.has_error(function()
        exploded_columns.generateCollapsedColumnSpec(nil, s)
      end)
      assert.has_error(function()
        exploded_columns.generateCollapsedColumnSpec(true, s)
      end)
      assert.has_error(function()
        exploded_columns.generateCollapsedColumnSpec(false, s)
      end)
      assert.has_error(function()
        exploded_columns.generateCollapsedColumnSpec(123, s)
      end)
      assert.has_error(function()
        exploded_columns.generateCollapsedColumnSpec(456.789, s)
      end)
      assert.has_error(function()
        exploded_columns.generateCollapsedColumnSpec({}, s)
      end)
      assert.has_error(function()
        exploded_columns.generateCollapsedColumnSpec(function () end, s)
      end)
      assert.has_error(function()
        exploded_columns.generateCollapsedColumnSpec("my_field", {})
      end)
    end)
    it("should return column header spec for valid parameters", function()
      local combined = exploded_columns.generateCollapsedColumnSpec("my_field", {type_spec="string"})
      assert.equals("my_field:string", combined)
    end)
  end)

  describe("analyzeExplodedColumns", function()
    it("should return fail for bad arg types", function()
      assert.has_error(function()
        exploded_columns.analyzeExplodedColumns(nil)
      end)
      assert.has_error(function()
        exploded_columns.analyzeExplodedColumns(true)
      end)
      assert.has_error(function()
        exploded_columns.analyzeExplodedColumns(false)
      end)
      assert.has_error(function()
        exploded_columns.analyzeExplodedColumns(123)
      end)
      assert.has_error(function()
        exploded_columns.analyzeExplodedColumns(456.789)
      end)
      assert.has_error(function()
        exploded_columns.analyzeExplodedColumns(function () end)
      end)
      assert.has_error(function()
        exploded_columns.analyzeExplodedColumns("my_field")
      end)
    end)
    it("should return column header spec for valid parameters", function()
      local header = {
        [1] = { idx = 1, name = "id", type = "integer", is_exploded = false },
        [2] = { idx = 2, name = "location.level", type = "name", is_exploded = true, exploded_path = {"location", "level"} },
        [3] = { idx = 3, name = "location.position._1", type = "integer", is_exploded = true, exploded_path = {"location", "position", "_1"} },
        [4] = { idx = 4, name = "location.position._2", type = "integer", is_exploded = true, exploded_path = {"location", "position", "_2"} },
      }
      local expected = {
        location = {
            type = "record",
            type_spec = "{level:name,position:{integer,integer}}",
            fields = {
                level = { type = "leaf", col_idx = 2, type_spec = "name" },
                position = {
                    type = "tuple",
                    type_spec = "{integer,integer}",
                    fields = {
                        [1] = { type = "leaf", col_idx = 3, type_spec = "integer" },
                        [2] = { type = "leaf", col_idx = 4, type_spec = "integer" }
                    }
                }
            }
        }
      }
      local exploded = exploded_columns.analyzeExplodedColumns(header)
      assert.is_not_nil(exploded)
      assert.same(expected, exploded)
    end)
    it("should return empty structure for non-exploded columns", function()
      local header = {
        [1] = { idx = 1, name = "id", type = "integer", is_exploded = false },
        [2] = { idx = 2, name = "level", type = "name", is_exploded = false },
        [3] = { idx = 3, name = "position_1", type = "integer", is_exploded = false },
        [4] = { idx = 4, name = "position_2", type = "integer", is_exploded = false },
      }
      local exploded = exploded_columns.analyzeExplodedColumns(header)
      assert.is_not_nil(exploded)
      assert.same({}, exploded)
    end)
  end)

  describe("assembleExplodedValue", function()
    it("should return an assembled value", function()
      local row = {{parsed=1},{parsed="starter"}, {parsed=2}, {parsed=3}}
      local structure = {
        location = {
            type = "record",
            type_spec = "{level:name,position:{integer,integer}}",
            fields = {
                level = { type = "leaf", col_idx = 2, type_spec = "name" },
                position = {
                    type = "tuple",
                    type_spec = "{integer,integer}",
                    fields = {
                        [1] = { type = "leaf", col_idx = 3, type_spec = "integer" },
                        [2] = { type = "leaf", col_idx = 4, type_spec = "integer" }
                    }
                }
            }
        }
      }
      local assembled = exploded_columns.assembleExplodedValue(row, structure.location)
      local expected = {level="starter", position = {2, 3}}
      assert.is_not_nil(assembled)
      assert.is_not_nil(assembled.position)
      assembled = unwrap(assembled)
      assembled.position = unwrap(assembled.position)
      assert.same(expected, assembled)
    end)
  end)

  describe("module API", function()
    describe("getVersion", function()
      it("should return a version string", function()
        local version = exploded_columns.getVersion()
        assert.is_string(version)
        assert.matches("^%d+%.%d+%.%d+$", version)
      end)
    end)

    describe("callable API", function()
      it("should return version when called with 'version'", function()
        local version = exploded_columns("version")
        assert.is_not_nil(version)
        -- Version is a semver object
        assert.are.equal(exploded_columns.getVersion(), tostring(version))
      end)

      it("should call API functions when called with function name", function()
        local result = exploded_columns("isTupleStructure", "abc")
        assert.is_not_nil(result)
        assert.are.equal(false, result)
      end)

      it("should error on unknown operation", function()
        assert.has_error(function()
          exploded_columns("nonexistent_operation")
        end, "Unknown operation: nonexistent_operation")
      end)
    end)

    describe("__tostring", function()
      it("should return module name and version", function()
        local str = tostring(exploded_columns)
        assert.is_string(str)
        assert.matches("^exploded_columns version %d+%.%d+%.%d+$", str)
      end)
    end)
  end)
end)
