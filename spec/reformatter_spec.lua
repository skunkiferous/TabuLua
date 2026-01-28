-- reformatter_spec.lua

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
local reformatter = require("reformatter")
local error_reporting = require("error_reporting")
local parsers = require("parsers")

-- Register the superType alias (normally defined in core manifest)
parsers.registerAlias(error_reporting.badValGen(), 'superType', 'type_spec|nil')

-- Simple path join function
local function path_join(...)
  return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- Manifest filename constant
local MANIFEST_FILENAME = "Manifest.transposed.tsv"

-- Sample manifest file content
local MANIFEST_TEST = [[package_id:package_id	Test
name:string	Test Package
version:version	0.1.0
description:markdown	A test package for reformatter tests
]]

-- Files descriptor content
local FILES_DESC = [[fileName:string	typeName:type_spec	superType:superType	baseType:boolean	publishContext:name|nil	publishColumn:name|nil	loadOrder:number	description:text
TestData.tsv	TestData		true			1	Test data file
]]

-- Sample TSV data file content (with inconsistent spacing that could be reformatted)
local TEST_DATA = [[name:identifier	value:number
item1	100
item2	200
]]

describe("reformatter", function()
  local temp_dir

  -- Setup: Create a temporary directory for testing
  before_each(function()
    local system_temp = file_util.getSystemTempDir()
    assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
    local td = path_join(system_temp, "reformatter_test_" .. os.time())
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

  describe("getVersion", function()
    it("should return a version string", function()
      local version = reformatter.getVersion()
      assert.is_string(version)
      assert.is_truthy(version:match("%d+%.%d+%.%d+"))
    end)
  end)

  describe("module API", function()
    it("should have a tostring representation", function()
      local str = tostring(reformatter)
      assert.is_string(str)
      assert.is_truthy(str:match("reformatter"))
      assert.is_truthy(str:match("version"))
    end)

    it("should support call syntax for version", function()
      local version = reformatter("version")
      assert.is_not_nil(version)
    end)

    it("should error for unknown operations", function()
      assert.has_error(function()
        reformatter("unknownOperation")
      end)
    end)
  end)

  describe("processFiles", function()
    it("should handle nil directories gracefully", function()
      -- Should not crash, just log an error
      reformatter.processFiles(nil, nil, nil)
      -- If we get here without error, test passes
    end)

    it("should handle empty directories list gracefully", function()
      -- Should not crash, just log an error
      reformatter.processFiles({}, nil, nil)
      -- If we get here without error, test passes
    end)

    it("should error for non-table directories", function()
      assert.has_error(function()
        reformatter.processFiles("not_a_table", nil, nil)
      end)
    end)

    it("should error for non-string directory entries", function()
      assert.has_error(function()
        reformatter.processFiles({123}, nil, nil)
      end)
    end)

    it("should handle non-existent directory gracefully", function()
      -- Should not crash, just log an error and return
      reformatter.processFiles({"/nonexistent/path/that/does/not/exist"}, nil, nil)
      -- If we get here without error, test passes
    end)

    it("should process a simple module without exporters", function()
      local mod_dir = path_join(temp_dir, "testmod")
      assert(lfs.mkdir(mod_dir))

      -- Create mod file
      local mod_file = path_join(mod_dir, MANIFEST_FILENAME)
      assert.is_true(file_util.writeFile(mod_file, MANIFEST_TEST))

      -- Create files descriptor
      local files_file = path_join(mod_dir, "files.tsv")
      assert.is_true(file_util.writeFile(files_file, FILES_DESC))

      -- Create data file
      local data_file = path_join(mod_dir, "TestData.tsv")
      assert.is_true(file_util.writeFile(data_file, TEST_DATA))

      -- Process without exporters
      reformatter.processFiles({mod_dir}, nil, nil)

      -- Verify the file still exists and is readable
      local content = file_util.readFile(data_file)
      assert.is_not_nil(content)
    end)

    it("should process a module with exporters", function()
      local mod_dir = path_join(temp_dir, "exportmod")
      assert(lfs.mkdir(mod_dir))

      -- Create mod file
      local mod_file = path_join(mod_dir, MANIFEST_FILENAME)
      assert.is_true(file_util.writeFile(mod_file, MANIFEST_TEST))

      -- Create files descriptor
      local files_file = path_join(mod_dir, "files.tsv")
      assert.is_true(file_util.writeFile(files_file, FILES_DESC))

      -- Create data file
      local data_file = path_join(mod_dir, "TestData.tsv")
      assert.is_true(file_util.writeFile(data_file, TEST_DATA))

      -- Create export directory
      local export_dir = path_join(temp_dir, "exported")

      -- Track if exporter was called
      local exporter_called = false
      local mock_exporter = function(_result, _exportParams)
        exporter_called = true
        return true
      end

      -- Process with a mock exporter
      reformatter.processFiles({mod_dir}, {mock_exporter}, {exportDir = export_dir})

      assert.is_true(exporter_called, "Exporter should have been called")
    end)

    it("should process a module with exporter table format", function()
      local mod_dir = path_join(temp_dir, "tableexport")
      assert(lfs.mkdir(mod_dir))

      -- Create mod file
      local mod_file = path_join(mod_dir, MANIFEST_FILENAME)
      assert.is_true(file_util.writeFile(mod_file, MANIFEST_TEST))

      -- Create files descriptor
      local files_file = path_join(mod_dir, "files.tsv")
      assert.is_true(file_util.writeFile(files_file, FILES_DESC))

      -- Create data file
      local data_file = path_join(mod_dir, "TestData.tsv")
      assert.is_true(file_util.writeFile(data_file, TEST_DATA))

      -- Create export directory
      local export_dir = path_join(temp_dir, "exported")

      -- Track if exporter was called and with correct params
      local exporter_called = false
      local received_subdir = nil
      local mock_exporter = {
        fn = function(_result, exportParams)
          exporter_called = true
          received_subdir = exportParams.formatSubdir
          return true
        end,
        subdir = "testformat"
      }

      -- Process with exporter in table format
      reformatter.processFiles({mod_dir}, {mock_exporter}, {exportDir = export_dir})

      assert.is_true(exporter_called, "Exporter should have been called")
      assert.equals("testformat", received_subdir, "formatSubdir should be set")
    end)

    it("should create export directory if it does not exist", function()
      local mod_dir = path_join(temp_dir, "mkdirmod")
      assert(lfs.mkdir(mod_dir))

      -- Create mod file
      local mod_file = path_join(mod_dir, MANIFEST_FILENAME)
      assert.is_true(file_util.writeFile(mod_file, MANIFEST_TEST))

      -- Create files descriptor
      local files_file = path_join(mod_dir, "files.tsv")
      assert.is_true(file_util.writeFile(files_file, FILES_DESC))

      -- Create data file
      local data_file = path_join(mod_dir, "TestData.tsv")
      assert.is_true(file_util.writeFile(data_file, TEST_DATA))

      -- Use a non-existent export directory
      local export_dir = path_join(temp_dir, "new_export_dir")

      -- Verify it doesn't exist yet
      assert.is_nil(lfs.attributes(export_dir))

      -- Mock exporter
      local mock_exporter = function(_result, _exportParams)
        return true
      end

      -- Process - should create the export directory
      reformatter.processFiles({mod_dir}, {mock_exporter}, {exportDir = export_dir})

      -- Verify directory was created
      local attr = lfs.attributes(export_dir)
      assert.is_not_nil(attr)
      assert.equals("directory", attr.mode)
    end)

    it("should use provided exportDir from exportParams", function()
      local mod_dir = path_join(temp_dir, "defaultmod")
      assert(lfs.mkdir(mod_dir))

      -- Create mod file
      local mod_file = path_join(mod_dir, MANIFEST_FILENAME)
      assert.is_true(file_util.writeFile(mod_file, MANIFEST_TEST))

      -- Create files descriptor
      local files_file = path_join(mod_dir, "files.tsv")
      assert.is_true(file_util.writeFile(files_file, FILES_DESC))

      -- Create data file
      local data_file = path_join(mod_dir, "TestData.tsv")
      assert.is_true(file_util.writeFile(data_file, TEST_DATA))

      -- Track the exportDir received
      local received_export_dir = nil
      local mock_exporter = function(_result, exportParams)
        received_export_dir = exportParams.exportDir
        return true
      end

      local export_dir = path_join(temp_dir, "custom_export")

      -- Process with custom exportDir
      reformatter.processFiles({mod_dir}, {mock_exporter}, {exportDir = export_dir})

      assert.equals(export_dir, received_export_dir, "Should use provided exportDir")
    end)

    it("should stop processing if exporter fails", function()
      local mod_dir = path_join(temp_dir, "failmod")
      assert(lfs.mkdir(mod_dir))

      -- Create mod file
      local mod_file = path_join(mod_dir, MANIFEST_FILENAME)
      assert.is_true(file_util.writeFile(mod_file, MANIFEST_TEST))

      -- Create files descriptor
      local files_file = path_join(mod_dir, "files.tsv")
      assert.is_true(file_util.writeFile(files_file, FILES_DESC))

      -- Create data file
      local data_file = path_join(mod_dir, "TestData.tsv")
      assert.is_true(file_util.writeFile(data_file, TEST_DATA))

      -- Create export directory
      local export_dir = path_join(temp_dir, "exported")

      -- Track which exporters were called
      local first_called = false
      local second_called = false

      local failing_exporter = {
        fn = function(_result, _exportParams)
          first_called = true
          return false  -- Signal failure
        end,
        subdir = "first"
      }

      local second_exporter = {
        fn = function(_result, _exportParams)
          second_called = true
          return true
        end,
        subdir = "second"
      }

      -- Process with failing exporter first
      reformatter.processFiles({mod_dir}, {failing_exporter, second_exporter}, {exportDir = export_dir})

      assert.is_true(first_called, "First exporter should have been called")
      assert.is_false(second_called, "Second exporter should not be called after failure")
    end)

    it("should pass tableSerializer to exporter when specified", function()
      local mod_dir = path_join(temp_dir, "sermod")
      assert(lfs.mkdir(mod_dir))

      -- Create mod file
      local mod_file = path_join(mod_dir, MANIFEST_FILENAME)
      assert.is_true(file_util.writeFile(mod_file, MANIFEST_TEST))

      -- Create files descriptor
      local files_file = path_join(mod_dir, "files.tsv")
      assert.is_true(file_util.writeFile(files_file, FILES_DESC))

      -- Create data file
      local data_file = path_join(mod_dir, "TestData.tsv")
      assert.is_true(file_util.writeFile(data_file, TEST_DATA))

      -- Create export directory
      local export_dir = path_join(temp_dir, "exported")

      -- Track the tableSerializer received
      local received_serializer = nil
      local custom_serializer = function(_t) return "custom" end

      local mock_exporter = {
        fn = function(_result, exportParams)
          received_serializer = exportParams.tableSerializer
          return true
        end,
        subdir = "custom",
        tableSerializer = custom_serializer
      }

      -- Process with custom tableSerializer
      reformatter.processFiles({mod_dir}, {mock_exporter}, {exportDir = export_dir})

      assert.equals(custom_serializer, received_serializer, "tableSerializer should be passed to exporter")
    end)

    it("should handle multiple directories", function()
      -- Create first package directory
      local pkg_dir1 = path_join(temp_dir, "pkg1")
      assert(lfs.mkdir(pkg_dir1))

      local PKG1 = [[package_id:package_id	Pkg1
name:string	Package 1
version:version	0.1.0
description:markdown	First package
]]
      assert.is_true(file_util.writeFile(path_join(pkg_dir1, MANIFEST_FILENAME), PKG1))
      assert.is_true(file_util.writeFile(path_join(pkg_dir1, "files.tsv"), FILES_DESC))
      assert.is_true(file_util.writeFile(path_join(pkg_dir1, "TestData.tsv"), TEST_DATA))

      -- Create second package directory
      local pkg_dir2 = path_join(temp_dir, "pkg2")
      assert(lfs.mkdir(pkg_dir2))

      local PKG2 = [[package_id:package_id	Pkg2
name:string	Package 2
version:version	0.2.0
description:markdown	Second package
]]
      local FILES_DESC2 = [[fileName:string	typeName:type_spec	superType:superType	baseType:boolean	publishContext:name|nil	publishColumn:name|nil	loadOrder:number	description:text
OtherData.tsv	OtherData		true			1	Other data file
]]
      local OTHER_DATA = [[name:identifier	count:integer
thing1	10
thing2	20
]]
      assert.is_true(file_util.writeFile(path_join(pkg_dir2, MANIFEST_FILENAME), PKG2))
      assert.is_true(file_util.writeFile(path_join(pkg_dir2, "files.tsv"), FILES_DESC2))
      assert.is_true(file_util.writeFile(path_join(pkg_dir2, "OtherData.tsv"), OTHER_DATA))

      -- Track results received by exporter
      local received_result = nil
      local mock_exporter = function(result, _exportParams)
        received_result = result
        return true
      end

      local export_dir = path_join(temp_dir, "exported")

      -- Process both directories
      reformatter.processFiles({pkg_dir1, pkg_dir2}, {mock_exporter}, {exportDir = export_dir})

      -- Verify both packages were processed
      assert.is_not_nil(received_result)
      assert.is_not_nil(received_result.packages)
      assert.is_not_nil(received_result.packages["Pkg1"])
      assert.is_not_nil(received_result.packages["Pkg2"])
    end)
  end)
end)
