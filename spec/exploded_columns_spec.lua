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

  describe("validateExplodedCollections", function()
    it("should return true for headers without collections", function()
      local header = {
        [1] = { idx = 1, name = "id", is_collection = false },
        [2] = { idx = 2, name = "name", is_collection = false },
      }
      local valid, err = exploded_columns.validateExplodedCollections(header)
      assert.is_true(valid)
      assert.is_nil(err)
    end)

    it("should return true for valid consecutive array indices", function()
      local header = {
        [1] = { idx = 1, name = "id", is_collection = false },
        [2] = { idx = 2, name = "items[1]", type = "string", is_collection = true,
                collection_info = { base_path = "items", index = 1, is_map_value = false } },
        [3] = { idx = 3, name = "items[2]", type = "string", is_collection = true,
                collection_info = { base_path = "items", index = 2, is_map_value = false } },
      }
      local valid, err = exploded_columns.validateExplodedCollections(header)
      assert.is_true(valid)
      assert.is_nil(err)
    end)

    it("should reject gaps in array indices", function()
      local header = {
        [1] = { idx = 1, name = "items[1]", type = "string", is_collection = true,
                collection_info = { base_path = "items", index = 1, is_map_value = false } },
        [2] = { idx = 2, name = "items[3]", type = "string", is_collection = true,
                collection_info = { base_path = "items", index = 3, is_map_value = false } },
      }
      local valid, err = exploded_columns.validateExplodedCollections(header)
      assert.is_false(valid)
      assert.matches("missing index 2", err)
    end)

    it("should return true for valid map columns", function()
      local header = {
        [1] = { idx = 1, name = "stats[1]", type = "name", is_collection = true,
                collection_info = { base_path = "stats", index = 1, is_map_value = false } },
        [2] = { idx = 2, name = "stats[1]=", type = "integer", is_collection = true,
                collection_info = { base_path = "stats", index = 1, is_map_value = true } },
        [3] = { idx = 3, name = "stats[2]", type = "name", is_collection = true,
                collection_info = { base_path = "stats", index = 2, is_map_value = false } },
        [4] = { idx = 4, name = "stats[2]=", type = "integer", is_collection = true,
                collection_info = { base_path = "stats", index = 2, is_map_value = true } },
      }
      local valid, err = exploded_columns.validateExplodedCollections(header)
      assert.is_true(valid)
      assert.is_nil(err)
    end)

    it("should reject maps with missing value columns", function()
      local header = {
        [1] = { idx = 1, name = "stats[1]", type = "name", is_collection = true,
                collection_info = { base_path = "stats", index = 1, is_map_value = false } },
        [2] = { idx = 2, name = "stats[1]=", type = "integer", is_collection = true,
                collection_info = { base_path = "stats", index = 1, is_map_value = true } },
        [3] = { idx = 3, name = "stats[2]", type = "name", is_collection = true,
                collection_info = { base_path = "stats", index = 2, is_map_value = false } },
        -- Missing stats[2]=
      }
      local valid, err = exploded_columns.validateExplodedCollections(header)
      assert.is_false(valid)
      assert.matches("missing value column", err)
    end)

    it("should reject maps with missing key columns", function()
      local header = {
        [1] = { idx = 1, name = "stats[1]=", type = "integer", is_collection = true,
                collection_info = { base_path = "stats", index = 1, is_map_value = true } },
      }
      local valid, err = exploded_columns.validateExplodedCollections(header)
      assert.is_false(valid)
      assert.matches("missing key column", err)
    end)
  end)

  describe("analyzeExplodedColumns for arrays", function()
    it("should analyze simple array columns", function()
      local header = {
        [1] = { idx = 1, name = "id", type = "integer", is_exploded = false },
        [2] = { idx = 2, name = "tags[1]", type = "string", is_exploded = true,
                exploded_path = {"tags"}, is_collection = true,
                collection_info = { base_path = "tags", index = 1, is_map_value = false } },
        [3] = { idx = 3, name = "tags[2]", type = "string", is_exploded = true,
                exploded_path = {"tags"}, is_collection = true,
                collection_info = { base_path = "tags", index = 2, is_map_value = false } },
      }
      local exploded = exploded_columns.analyzeExplodedColumns(header)
      assert.is_not_nil(exploded)
      assert.is_not_nil(exploded.tags)
      assert.equals("array", exploded.tags.type)
      assert.equals("{string}", exploded.tags.type_spec)
      assert.equals(2, exploded.tags.max_index)
      assert.equals(2, exploded.tags.element_columns[1])
      assert.equals(3, exploded.tags.element_columns[2])
    end)
  end)

  describe("analyzeExplodedColumns for maps", function()
    it("should analyze simple map columns", function()
      local header = {
        [1] = { idx = 1, name = "id", type = "integer", is_exploded = false },
        [2] = { idx = 2, name = "stats[1]", type = "name", is_exploded = true,
                exploded_path = {"stats"}, is_collection = true,
                collection_info = { base_path = "stats", index = 1, is_map_value = false } },
        [3] = { idx = 3, name = "stats[1]=", type = "integer", is_exploded = true,
                exploded_path = {"stats"}, is_collection = true,
                collection_info = { base_path = "stats", index = 1, is_map_value = true } },
        [4] = { idx = 4, name = "stats[2]", type = "name", is_exploded = true,
                exploded_path = {"stats"}, is_collection = true,
                collection_info = { base_path = "stats", index = 2, is_map_value = false } },
        [5] = { idx = 5, name = "stats[2]=", type = "integer", is_exploded = true,
                exploded_path = {"stats"}, is_collection = true,
                collection_info = { base_path = "stats", index = 2, is_map_value = true } },
      }
      local exploded = exploded_columns.analyzeExplodedColumns(header)
      assert.is_not_nil(exploded)
      assert.is_not_nil(exploded.stats)
      assert.equals("map", exploded.stats.type)
      assert.equals("{name:integer}", exploded.stats.type_spec)
      assert.equals(2, exploded.stats.max_index)
    end)
  end)

  describe("assembleExplodedValue for arrays", function()
    it("should assemble array from element columns", function()
      local row = {{parsed=1}, {parsed="fire"}, {parsed="rare"}, {parsed="weapon"}}
      local structure = {
        type = "array",
        element_type = "string",
        max_index = 3,
        element_columns = {[1]=2, [2]=3, [3]=4}
      }
      local result = exploded_columns.assembleExplodedValue(row, structure)
      assert.is_not_nil(result)
      result = unwrap(result)
      assert.same({"fire", "rare", "weapon"}, result)
    end)

    it("should preserve nil elements in arrays", function()
      local row = {{parsed="a"}, nil, {parsed="c"}}
      local structure = {
        type = "array",
        max_index = 3,
        element_columns = {[1]=1, [2]=2, [3]=3}
      }
      local result = exploded_columns.assembleExplodedValue(row, structure)
      result = unwrap(result)
      assert.same({"a", nil, "c"}, result)
    end)
  end)

  describe("assembleExplodedValue for maps", function()
    it("should assemble map from key/value columns", function()
      local row = {{parsed=1}, {parsed="attack"}, {parsed=50}, {parsed="defense"}, {parsed=30}}
      local structure = {
        type = "map",
        key_type = "name",
        value_type = "integer",
        max_index = 2,
        key_columns = {[1]=2, [2]=4},
        value_columns = {[1]=3, [2]=5}
      }
      local result = exploded_columns.assembleExplodedValue(row, structure)
      assert.is_not_nil(result)
      result = unwrap(result)
      assert.same({attack=50, defense=30}, result)
    end)

    it("should skip entries with nil keys", function()
      local row = {{parsed="attack"}, {parsed=50}, nil, {parsed=30}}
      local structure = {
        type = "map",
        max_index = 2,
        key_columns = {[1]=1, [2]=3},
        value_columns = {[1]=2, [2]=4}
      }
      local result = exploded_columns.assembleExplodedValue(row, structure)
      result = unwrap(result)
      assert.same({attack=50}, result)
    end)
  end)

  describe("isExplodedCollectionName", function()
    it("returns true for valid array column names", function()
      assert.is_true(exploded_columns.isExplodedCollectionName("items[1]"))
      assert.is_true(exploded_columns.isExplodedCollectionName("items[2]"))
      assert.is_true(exploded_columns.isExplodedCollectionName("items[123]"))
    end)

    it("returns true for valid map value column names", function()
      assert.is_true(exploded_columns.isExplodedCollectionName("stats[1]="))
      assert.is_true(exploded_columns.isExplodedCollectionName("stats[2]="))
    end)

    it("returns true for nested collection names", function()
      assert.is_true(exploded_columns.isExplodedCollectionName("player.inventory[1]"))
      assert.is_true(exploded_columns.isExplodedCollectionName("player.stats[1]="))
    end)

    it("returns false for invalid indices", function()
      assert.is_false(exploded_columns.isExplodedCollectionName("items[0]"))
      assert.is_false(exploded_columns.isExplodedCollectionName("items[-1]"))
      assert.is_false(exploded_columns.isExplodedCollectionName("items[abc]"))
      assert.is_false(exploded_columns.isExplodedCollectionName("items[]"))
    end)

    it("returns false for invalid base paths", function()
      assert.is_false(exploded_columns.isExplodedCollectionName("[1]"))
      assert.is_false(exploded_columns.isExplodedCollectionName("123[1]"))
    end)

    it("returns false for non-strings", function()
      assert.is_false(exploded_columns.isExplodedCollectionName(nil))
      assert.is_false(exploded_columns.isExplodedCollectionName(123))
      assert.is_false(exploded_columns.isExplodedCollectionName({}))
    end)
  end)

  describe("parseExplodedCollectionName", function()
    it("parses valid array column names", function()
      local info = exploded_columns.parseExplodedCollectionName("items[1]")
      assert.is_not_nil(info)
      assert.equals("items", info.base_path)
      assert.equals(1, info.index)
      assert.is_false(info.is_map_value)
    end)

    it("parses valid map value column names", function()
      local info = exploded_columns.parseExplodedCollectionName("stats[2]=")
      assert.is_not_nil(info)
      assert.equals("stats", info.base_path)
      assert.equals(2, info.index)
      assert.is_true(info.is_map_value)
    end)

    it("parses nested collection names", function()
      local info = exploded_columns.parseExplodedCollectionName("player.inventory[3]")
      assert.is_not_nil(info)
      assert.equals("player.inventory", info.base_path)
      assert.equals(3, info.index)
      assert.is_false(info.is_map_value)
    end)

    it("returns nil for invalid collection names", function()
      assert.is_nil(exploded_columns.parseExplodedCollectionName("items[0]"))
      assert.is_nil(exploded_columns.parseExplodedCollectionName("[1]"))
      assert.is_nil(exploded_columns.parseExplodedCollectionName("items"))
      assert.is_nil(exploded_columns.parseExplodedCollectionName(nil))
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
