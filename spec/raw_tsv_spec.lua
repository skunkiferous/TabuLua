-- raw_tsv_spec.lua

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
local raw_tsv = require("raw_tsv")

-- Simple path join function
local function path_join(...)
  return (table.concat({...}, "/"):gsub("//+", "/"))
end

describe("raw_tsv", function()
  local temp_dir

  -- Setup: Create a temporary directory for testing
  before_each(function()
    local system_temp = file_util.getSystemTempDir()
    assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
    local td = path_join(system_temp, "lua_raw_tsv_test_" .. os.time())
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

  describe("stringToRawTSV", function()
    it("should handle empty string", function()
      local result = raw_tsv.stringToRawTSV("")
      assert.same({}, result)
    end)

    it("should parse simple TSV data", function()
      local input = "a\tb\tc\nd\te\tf"
      local result = raw_tsv.stringToRawTSV(input)
      assert.same({
        {"a", "b", "c"},
        {"d", "e", "f"}
      }, result)
    end)

    it("should preserve comment lines", function()
      local input = "a\tb\tc\n# This is a comment\nd\te\tf"
      local result = raw_tsv.stringToRawTSV(input)
      assert.same({
        {"a", "b", "c"},
        "# This is a comment",
        {"d", "e", "f"}
      }, result)
    end)

    it("should preserve blank lines", function()
      local input = "a\tb\tc\n\nd\te\tf"
      local result = raw_tsv.stringToRawTSV(input)
      assert.same({
        {"a", "b", "c"},
        "",
        {"d", "e", "f"}
      }, result)
    end)

    it("should handle various line endings", function()
      local input = "a\tb\tc\r\nd\te\tf\rd\te\tf"
      local result = raw_tsv.stringToRawTSV(input)
      assert.same({
        {"a", "b", "c"},
        {"d", "e", "f"},
        {"d", "e", "f"}
      }, result)
    end)

    it("should handle rows with different numbers of columns", function()
      local input = "a\tb\tc\nd\te\nd\te\tf\tg"
      local result = raw_tsv.stringToRawTSV(input)
      assert.same({
        {"a", "b", "c"},
        {"d", "e"},
        {"d", "e", "f", "g"}
      }, result)
    end)
  end)

  describe("rawTSVToString", function()
    it("should handle empty input", function()
      local result = raw_tsv.rawTSVToString({})
      assert.equal("", result)
    end)

    it("should convert TSV structure to string", function()
      local input = {
        {"a", "b", "c"},
        {"d", "e", "f"}
      }
      local result = raw_tsv.rawTSVToString(input)
      assert.equal("a\tb\tc\nd\te\tf\n", result)
    end)

    it("should preserve comment lines", function()
      local input = {
        {"a", "b", "c"},
        "# This is a comment",
        {"d", "e", "f"}
      }
      local result = raw_tsv.rawTSVToString(input)
      assert.equal("a\tb\tc\n# This is a comment\nd\te\tf\n", result)
    end)

    it("should preserve blank lines", function()
      local input = {
        {"a", "b", "c"},
        "",
        {"d", "e", "f"}
      }
      local result = raw_tsv.rawTSVToString(input)
      assert.equal("a\tb\tc\n\nd\te\tf\n", result)
    end)

    it("should handle non-string values by using tostring", function()
      local input = {
        {1, true, "c"},
        {nil, false, 3.14}
      }
      local result = raw_tsv.rawTSVToString(input)
      assert.equal("1\ttrue\tc\nnil\tfalse\t3.14\n", result)
    end)

    it("should reject cells containing tab characters", function()
      local input = {
        {"a", "b\tc", "d"}
      }
      assert.has_error(function()
        raw_tsv.rawTSVToString(input)
      end, "Cell at row 1, column 2 contains invalid characters (tab, CR, or LF)")
    end)

    it("should reject cells containing newline characters", function()
      local input = {
        {"a", "b"},
        {"c", "d\ne"}
      }
      assert.has_error(function()
        raw_tsv.rawTSVToString(input)
      end, "Cell at row 2, column 2 contains invalid characters (tab, CR, or LF)")
    end)

    it("should reject cells containing carriage return characters", function()
      local input = {
        {"a\rb", "c"}
      }
      assert.has_error(function()
        raw_tsv.rawTSVToString(input)
      end, "Cell at row 1, column 1 contains invalid characters (tab, CR, or LF)")
    end)

    it("should reject cells containing invalid UTF-8", function()
      local input = {
        {"a", "\xFF\xFE", "c"}  -- Invalid UTF-8 sequence
      }
      assert.has_error(function()
        raw_tsv.rawTSVToString(input)
      end, "Cell at row 1, column 2 contains invalid UTF-8")
    end)
  end)

  describe("fileToRawTSV", function()
    it("should read TSV from file", function()
      local file_path = path_join(temp_dir, "test.tsv")
      local content = "a\tb\tc\nd\te\tf"
      assert(file_util.writeFile(file_path, content))
      
      local result = raw_tsv.fileToRawTSV(file_path)
      assert.same({
        {"a", "b", "c"},
        {"d", "e", "f"}
      }, result)
    end)

    it("should handle files with comments and blank lines", function()
      local file_path = path_join(temp_dir, "test.tsv")
      local content = "a\tb\tc\n# Comment\n\nd\te\tf"
      assert(file_util.writeFile(file_path, content))
      
      local result = raw_tsv.fileToRawTSV(file_path)
      assert.same({
        {"a", "b", "c"},
        "# Comment",
        "",
        {"d", "e", "f"}
      }, result)
    end)

    it("should return error for non-existent file", function()
      local file_path = path_join(temp_dir, "nonexistent.tsv")
      local result, err = raw_tsv.fileToRawTSV(file_path)
      assert.is_nil(result)
      assert.is_not_nil(err)
    end)

    it("should handle empty files", function()
      local file_path = path_join(temp_dir, "empty.tsv")
      assert(file_util.writeFile(file_path, ""))
      
      local result = raw_tsv.fileToRawTSV(file_path)
      assert.same({}, result)
    end)
  end)

  describe("isRawTSV", function()
    it("should validate correct raw TSV structure", function()
      assert.is_true(raw_tsv.isRawTSV({
        {"a", "b", "c"},
        "# Comment",
        "",
        {"d", "e", "f"}
      }))
    end)

    it("should reject non-sequence tables", function()
      assert.is_false(raw_tsv.isRawTSV({
        x = {"a", "b", "c"},
        y = {"d", "e", "f"}
      }))
    end)

    it("should reject invalid line types", function()
      assert.is_false(raw_tsv.isRawTSV({
        {"a", "b", "c"},
        123,  -- Not a string or table
        {"d", "e", "f"}
      }))
    end)

    it("should reject invalid cell types", function()
      assert.is_false(raw_tsv.isRawTSV({
        {"a", "b", "c"},
        {"d", {}, "f"}  -- Contains non-string value
      }))
    end)

    it("should handle empty structure", function()
      assert.is_true(raw_tsv.isRawTSV({}))
    end)

    it("should reject non-table input", function()
      assert.is_false(raw_tsv.isRawTSV("not a table"))
      assert.is_false(raw_tsv.isRawTSV(123))
      assert.is_false(raw_tsv.isRawTSV(nil))
    end)

    it("should accept non-string basic types in cells", function()
      assert.is_true(raw_tsv.isRawTSV({
        {1, true, "c"},
        {nil, false, 3.14}
      }))
    end)
  end)

  describe("transposeRawTSV", function()
    it("should properly transpose a rectangular table", function()
      local input = {
        {"a", "b", "c"},
        {"d", "e", "f"},
        {"g", "h", "i"}
      }
      local result = raw_tsv.transposeRawTSV(input)
      assert.same({
        {"a", "d", "g"},
        {"b", "e", "h"},
        {"c", "f", "i"}
      }, result)
    end)

    it("should handle tables with comments and blank lines", function()
      local input = {
        {"a", "b", "c"},
        "# Comment line",
        "",
        {"d", "e", "f"}
      }
      local result = raw_tsv.transposeRawTSV(input)
      assert.same({
        {"a", "dummy0:comment", "dummy1:comment", "d"},
        {"b", "# Comment line", "", "e"},
        {"c", "", "", "f"}
      }, result)

      local input2 = {
        {"a", "b", "c"},
        "",
        "# Comment line",
        {"d", "e", "f"}
      }
      local result2 = raw_tsv.transposeRawTSV(input2)
      assert.same({
        {"a", "dummy0:comment", "dummy1:comment", "d"},
        {"b", "", "# Comment line", "e"},
        {"c", "", "", "f"}
      }, result2)
    end)

    it("should handle ragged tables", function()
      local input = {
        {"a", "b", "c"},
        {"d", "e"},
        {"f", "g", "h", "i"}
      }
      local result = raw_tsv.transposeRawTSV(input)
      assert.same({
        {"a", "d", "f"},
        {"b", "e", "g"},
        {"c", "", "h"},
        {"", "", "i"}
      }, result)
    end)

    it("should handle empty input", function()
      local result = raw_tsv.transposeRawTSV({})
      assert.same({}, result)
    end)

    it("should reject invalid input", function()
      assert.has_error(function()
        raw_tsv.transposeRawTSV({
          {"a", "b"},
          123,  -- Invalid row type
          {"d", "e"}
        })
      end, "Invalid raw TSV structure")
    end)
  end)

  describe("module API", function()
    describe("getVersion", function()
      it("should return a version string", function()
        local version = raw_tsv.getVersion()
        assert.is_string(version)
        assert.matches("^%d+%.%d+%.%d+$", version)
      end)
    end)

    describe("callable API", function()
      it("should return version when called with 'version'", function()
        local version = raw_tsv("version")
        assert.is_not_nil(version)
        -- Version is a semver object
        assert.are.equal(raw_tsv.getVersion(), tostring(version))
      end)

      it("should call API functions when called with function name", function()
        local result = raw_tsv("isRawTSV", {{"a", "b"}, {"c", "d"}})
        assert.is_true(result)
      end)

      it("should error on unknown operation", function()
        assert.has_error(function()
          raw_tsv("nonexistent_operation")
        end, "Unknown operation: nonexistent_operation")
      end)
    end)

    describe("__tostring", function()
      it("should return module name and version", function()
        local str = tostring(raw_tsv)
        assert.is_string(str)
        assert.matches("^raw_tsv version %d+%.%d+%.%d+$", str)
      end)
    end)
  end)

end)
