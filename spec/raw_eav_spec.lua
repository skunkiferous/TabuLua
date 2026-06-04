-- raw_eav_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

local lfs = require("lfs")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local file_util = require("file_util")
local raw_eav = require("raw_eav")

-- Simple path join function
local function path_join(...)
  return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- The canonical example from the spec.
local function canonicalEav()
  return {
    {"item1", "title",   "Sword"},
    {"item1", "damage",  "10"},
    {"item2", "title",   "Shield"},
    {"item2", "defense", "5"},
  }
end

describe("raw_eav", function()
  local temp_dir

  -- Setup: Create a temporary directory for testing
  before_each(function()
    local system_temp = file_util.getSystemTempDir()
    assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
    local td = path_join(system_temp, "lua_raw_eav_test_" .. os.time())
    assert(lfs.mkdir(td))
    temp_dir = td
  end)

  -- Teardown: Remove the temporary directory after tests
  after_each(function()
    if temp_dir then
      local td = temp_dir
      temp_dir = nil
      file_util.deleteTempDir(td)
    end
  end)

  describe("eavToTable", function()
    it("should rebuild the canonical wide table", function()
      local result = raw_eav.eavToTable(canonicalEav())
      assert.same({
        {"name",  "title",  "damage", "defense"},
        {"item1", "Sword",  "10",     ""},
        {"item2", "Shield", "",       "5"},
      }, result)
    end)

    it("should preserve first-seen column order (not alphabetical)", function()
      local result = raw_eav.eavToTable({
        {"e1", "zeta",  "1"},
        {"e1", "alpha", "2"},
        {"e1", "mu",    "3"},
      })
      assert.same({"name", "zeta", "alpha", "mu"}, result[1])
    end)

    it("should preserve first-seen row order", function()
      local result = raw_eav.eavToTable({
        {"zzz", "a", "1"},
        {"aaa", "a", "2"},
        {"mmm", "a", "3"},
      })
      assert.same("zzz", result[2][1])
      assert.same("aaa", result[3][1])
      assert.same("mmm", result[4][1])
    end)

    it("should fill missing pairs with empty cells (sparsity)", function()
      local result = raw_eav.eavToTable({
        {"e1", "a", "1"},
        {"e2", "b", "2"},
      })
      assert.same({
        {"name", "a",  "b"},
        {"e1",   "1",  ""},
        {"e2",   "",   "2"},
      }, result)
    end)

    it("should honour the keyColumn option", function()
      local result = raw_eav.eavToTable(canonicalEav(), {keyColumn = "id"})
      assert.same("id", result[1][1])
    end)

    it("should ignore comment and blank lines", function()
      local result = raw_eav.eavToTable({
        "# a comment",
        {"item1", "title", "Sword"},
        "",
        {"item2", "title", "Shield"},
      })
      assert.same({
        {"name",  "title"},
        {"item1", "Sword"},
        {"item2", "Shield"},
      }, result)
    end)

    it("should handle a single triple", function()
      local result = raw_eav.eavToTable({{"e1", "a", "1"}})
      assert.same({
        {"name", "a"},
        {"e1",   "1"},
      }, result)
    end)

    it("should return {} for empty input", function()
      assert.same({}, raw_eav.eavToTable({}))
    end)

    describe("conflicts", function()
      it("should error on a duplicate pair by default", function()
        assert.has_error(function()
          raw_eav.eavToTable({
            {"e1", "a", "1"},
            {"e1", "a", "2"},
          })
        end, "Duplicate (entity, attribute) pair (e1, a) at rows 1 and 2")
      end)

      it("should keep the earliest value with onConflict='first'", function()
        local result = raw_eav.eavToTable({
          {"e1", "a", "1"},
          {"e1", "a", "2"},
        }, {onConflict = "first"})
        assert.same("1", result[2][2])
      end)

      it("should keep the latest value with onConflict='last'", function()
        local result = raw_eav.eavToTable({
          {"e1", "a", "1"},
          {"e1", "a", "2"},
        }, {onConflict = "last"})
        assert.same("2", result[2][2])
      end)
    end)

    describe("errors", function()
      it("should reject non-table input", function()
        assert.has_error(function()
          raw_eav.eavToTable("nope")
        end, "Argument must be a table: string")
      end)

      it("should reject a row with too few cells", function()
        assert.has_error(function()
          raw_eav.eavToTable({{"e1", "a"}})
        end, "Row 1 must have exactly 3 cells, found 2")
      end)

      it("should reject a row with too many cells", function()
        assert.has_error(function()
          raw_eav.eavToTable({{"e1", "a", "1", "extra"}})
        end, "Row 1 must have exactly 3 cells, found 4")
      end)

      it("should reject an empty entity cell", function()
        assert.has_error(function()
          raw_eav.eavToTable({{"", "a", "1"}})
        end, "Row 1 has an empty entity cell")
      end)

      it("should reject an empty attribute cell", function()
        assert.has_error(function()
          raw_eav.eavToTable({{"e1", "", "1"}})
        end, "Row 1 has an empty attribute cell")
      end)
    end)
  end)

  describe("tableToEav", function()
    it("should compress a wide table to triples", function()
      local wide = {
        {"name",  "title",  "damage", "defense"},
        {"item1", "Sword",  "10",     ""},
        {"item2", "Shield", "",       "5"},
      }
      assert.same({
        {"item1", "title",   "Sword"},
        {"item1", "damage",  "10"},
        {"item2", "title",   "Shield"},
        {"item2", "defense", "5"},
      }, raw_eav.tableToEav(wide))
    end)

    it("should round-trip the canonical triples (modulo order)", function()
      local wide = raw_eav.eavToTable(canonicalEav())
      local triples = raw_eav.tableToEav(wide)
      assert.same(canonicalEav(), triples)
    end)

    it("should drop empty cells with skipEmpty=true (default)", function()
      local wide = {
        {"name", "a", "b"},
        {"e1",   "1", ""},
      }
      assert.same({{"e1", "a", "1"}}, raw_eav.tableToEav(wide))
    end)

    it("should emit every cell with skipEmpty=false", function()
      local wide = {
        {"name", "a", "b"},
        {"e1",   "1", ""},
      }
      assert.same({
        {"e1", "a", "1"},
        {"e1", "b", ""},
      }, raw_eav.tableToEav(wide, {skipEmpty = false}))
    end)

    it("should tolerate rows shorter than the header", function()
      local wide = {
        {"name", "a", "b"},
        {"e1",   "1"},
      }
      assert.same({{"e1", "a", "1"}}, raw_eav.tableToEav(wide))
    end)

    it("should skip leading comment/blank rows to find the header", function()
      local wide = {
        "# header below",
        "",
        {"name", "a"},
        {"e1",   "1"},
      }
      assert.same({{"e1", "a", "1"}}, raw_eav.tableToEav(wide))
    end)

    describe("errors", function()
      it("should reject non-table input", function()
        assert.has_error(function()
          raw_eav.tableToEav(42)
        end, "Argument must be a table: number")
      end)

      it("should reject a table with no header row", function()
        assert.has_error(function()
          raw_eav.tableToEav({"# only comments"})
        end, "Table has no header row")
      end)

      it("should reject a duplicate attribute name in the header", function()
        assert.has_error(function()
          raw_eav.tableToEav({
            {"name", "a", "a"},
            {"e1",   "1", "2"},
          })
        end, "Header has a duplicate attribute name \"a\" at column 3")
      end)

      it("should reject an empty attribute name in the header", function()
        assert.has_error(function()
          raw_eav.tableToEav({
            {"name", "a", ""},
            {"e1",   "1", "2"},
          })
        end, "Header has an empty attribute name at column 3")
      end)

      it("should reject a data row with an empty entity cell", function()
        assert.has_error(function()
          raw_eav.tableToEav({
            {"name", "a"},
            {"",     "1"},
          })
        end, "Row 2 has an empty entity cell")
      end)
    end)
  end)

  describe("stringToTable", function()
    it("should parse a tab-separated EAV string", function()
      local s = "item1\ttitle\tSword\nitem1\tdamage\t10\nitem2\ttitle\tShield\nitem2\tdefense\t5"
      assert.same(raw_eav.eavToTable(canonicalEav()), raw_eav.stringToTable(s))
    end)

    it("should accept CRLF and CR line endings", function()
      local s = "e1\ta\t1\r\ne1\tb\t2\re2\ta\t3"
      assert.same({
        {"name", "a",  "b"},
        {"e1",   "1",  "2"},
        {"e2",   "3",  ""},
      }, raw_eav.stringToTable(s))
    end)
  end)

  describe("tableToString", function()
    it("should produce header-less, tab-separated, newline-terminated triples", function()
      local wide = {
        {"name", "a", "b"},
        {"e1",   "1", "2"},
      }
      assert.equal("e1\ta\t1\ne1\tb\t2\n", raw_eav.tableToString(wide))
    end)

    it("should stringify Lua-number cells via the rawTSVToString path", function()
      local wide = {
        {"name", "a"},
        {"e1",   42},
      }
      assert.equal("e1\ta\t42\n", raw_eav.tableToString(wide))
    end)

    it("should round-trip values through stringToTable", function()
      local wide = raw_eav.eavToTable(canonicalEav())
      local s = raw_eav.tableToString(wide)
      assert.same(wide, raw_eav.stringToTable(s))
    end)
  end)

  describe("fileToTable", function()
    it("should read an EAV file", function()
      local file_path = path_join(temp_dir, "test.eav")
      assert(file_util.writeFile(file_path, "item1\ttitle\tSword\nitem2\ttitle\tShield"))
      assert.same({
        {"name",  "title"},
        {"item1", "Sword"},
        {"item2", "Shield"},
      }, raw_eav.fileToTable(file_path))
    end)

    it("should return nil, err for a missing file", function()
      local file_path = path_join(temp_dir, "nonexistent.eav")
      local result, err = raw_eav.fileToTable(file_path)
      assert.is_nil(result)
      assert.is_not_nil(err)
    end)
  end)

  describe("isEav", function()
    it("should accept a well-formed 3-cell-row structure", function()
      assert.is_true(raw_eav.isEav(canonicalEav()))
    end)

    it("should accept a structure with comment rows", function()
      assert.is_true(raw_eav.isEav({
        "# comment",
        {"e1", "a", "1"},
        "",
      }))
    end)

    it("should reject a non-table", function()
      assert.is_false(raw_eav.isEav("nope"))
      assert.is_false(raw_eav.isEav(nil))
    end)

    it("should reject a row of the wrong arity", function()
      assert.is_false(raw_eav.isEav({{"e1", "a"}}))
      assert.is_false(raw_eav.isEav({{"e1", "a", "1", "x"}}))
    end)

    it("should reject an empty entity cell", function()
      assert.is_false(raw_eav.isEav({{"", "a", "1"}}))
    end)

    it("should reject an empty attribute cell", function()
      assert.is_false(raw_eav.isEav({{"e1", "", "1"}}))
    end)
  end)

  describe("module API", function()
    describe("getVersion", function()
      it("should return a version string", function()
        local version = raw_eav.getVersion()
        assert.is_string(version)
        assert.matches("^%d+%.%d+%.%d+$", version)
      end)
    end)

    describe("callable API", function()
      it("should return version when called with 'version'", function()
        local version = raw_eav("version")
        assert.is_not_nil(version)
        assert.are.equal(raw_eav.getVersion(), tostring(version))
      end)

      it("should call API functions when called with function name", function()
        assert.is_true(raw_eav("isEav", canonicalEav()))
        local result = raw_eav("eavToTable", {{"e1", "a", "1"}})
        assert.same({{"name", "a"}, {"e1", "1"}}, result)
      end)

      it("should error on unknown operation", function()
        assert.has_error(function()
          raw_eav("nonexistent_operation")
        end, "Unknown operation: nonexistent_operation")
      end)
    end)

    describe("__tostring", function()
      it("should return module name and version", function()
        local str = tostring(raw_eav)
        assert.is_string(str)
        assert.matches("^raw_eav version %d+%.%d+%.%d+$", str)
      end)
    end)
  end)

end)
