-- manifest_loader_spec.lua

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
local manifest_loader = require("manifest_loader")
local error_reporting = require("error_reporting")
local parsers = require("parsers")

-- Register the superType alias (normally defined in core manifest)
parsers.registerAlias(error_reporting.badValGen(), 'superType', 'type_spec|nil')

-- Simple path join function
local function path_join(...)
  return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- Returns a "badVal" object that store errors in the given table
local function mockBadVal(log_messages)
  local log = function(_self, msg) table.insert(log_messages, msg) end
  local badVal = error_reporting.badValGen(log)
  badVal.source_name = "test"
  badVal.line_no = 1
  return badVal
end

-- Manifest filename constant
local MANIFEST_FILENAME = "Manifest.transposed.tsv"

-- Sample manifest file content
local MANIFEST_TEST = [[package_id:package_id	Test
name:string	Test Package
version:version	0.1.0
description:markdown	A test package for manifest_loader tests
]]

-- Files descriptor content
local FILES_DESC = [[fileName:string	typeName:type_spec	superType:superType	baseType:boolean	publishContext:name|nil	publishColumn:name|nil	loadOrder:number	description:text
TestData.tsv	TestData		true			1	Test data file
]]

-- Sample TSV data file content
local TEST_DATA = [[name:identifier	value:number
item1	100
item2	200
]]

-- Sample enum file content
local ENUM_DATA = [[name:identifier	description:text
red	The color red
green	The color green
blue	The color blue
]]

-- Files descriptor with enum
local FILES_DESC_WITH_ENUM = [[fileName:string	typeName:type_spec	superType:superType	baseType:boolean	publishContext:name|nil	publishColumn:name|nil	loadOrder:number	description:text
ColorEnum.tsv	ColorEnum	enum	true			1	Color enumeration
]]

-- Files descriptor with constants (publishContext and publishColumn)
local FILES_DESC_WITH_CONSTANTS = [[fileName:string	typeName:type_spec	superType:superType	baseType:boolean	publishContext:name|nil	publishColumn:name|nil	loadOrder:number	description:text
Constants.tsv	ConstantDef		true	gameConstants	value	1	Game constants
]]

-- Constants data file
local CONSTANTS_DATA = [[name:identifier	value:number
MAX_HEALTH	100
MAX_MANA	50
]]

describe("manifest_loader", function()
  local temp_dir
  local log_messages
  local badVal

  -- Setup: Create a temporary directory for testing
  before_each(function()
    local system_temp = file_util.getSystemTempDir()
    assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
    local td = path_join(system_temp, "manifest_loader_test_" .. os.time())
    assert(lfs.mkdir(td))
    temp_dir = td
    log_messages = {}
    badVal = mockBadVal(log_messages)
    badVal.logger = error_reporting.nullLogger
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
    it("should return a string", function()
      local version = manifest_loader.getVersion()
      assert.is_string(version)
    end)

    it("should return a valid semver format", function()
      local version = manifest_loader.getVersion()
      assert.is_truthy(version:match("^%d+%.%d+%.%d+"))
    end)
  end)

  describe("API metamethods", function()
    it("should be callable with 'version' operation", function()
      local version = manifest_loader("version")
      assert.is_not_nil(version)
    end)

    it("should be callable with exported function names", function()
      -- processFiles is the main exported function
      -- We can't call it without args easily, but we can verify the API exists
      assert.is_function(manifest_loader.processFiles)
    end)

    it("should error on unknown operations", function()
      assert.has_error(function()
        manifest_loader("unknown_operation")
      end)
    end)

    it("should have a tostring representation", function()
      local str = tostring(manifest_loader)
      assert.is_string(str)
      assert.is_truthy(str:find("manifest_loader"))
      assert.is_truthy(str:find("version"))
    end)
  end)

  describe("processFiles", function()
    it("should handle an empty directory list gracefully", function()
      local result = manifest_loader.processFiles({}, badVal)
      -- With no directories, there are no packages, but it should not crash
      -- It returns an empty result table
      assert.is_not_nil(result)
      assert.same({}, result.package_order)
      assert.same({}, result.packages)
    end)

    it("should handle directories with no manifest files", function()
      -- Create a directory with no manifest file
      local pkg_dir = path_join(temp_dir, "nomanifest")
      assert(lfs.mkdir(pkg_dir))

      local result = manifest_loader.processFiles({pkg_dir}, badVal)
      -- Returns an empty result since no packages were found
      assert.is_not_nil(result)
      assert.same({}, result.package_order)
    end)

    it("should process a simple package with one data file", function()
      local pkg_dir = path_join(temp_dir, "testpkg")
      assert(lfs.mkdir(pkg_dir))

      -- Create manifest file
      local manifest_file = path_join(pkg_dir, MANIFEST_FILENAME)
      assert.is_true(file_util.writeFile(manifest_file, MANIFEST_TEST))

      -- Create files descriptor
      local files_file = path_join(pkg_dir, "files.tsv")
      assert.is_true(file_util.writeFile(files_file, FILES_DESC))

      -- Create data file
      local data_file = path_join(pkg_dir, "TestData.tsv")
      assert.is_true(file_util.writeFile(data_file, TEST_DATA))

      local result = manifest_loader.processFiles({pkg_dir}, badVal)

      assert.is_not_nil(result)
      assert.is_not_nil(result.raw_files)
      assert.is_not_nil(result.tsv_files)
      assert.is_not_nil(result.package_order)
      assert.is_not_nil(result.packages)

      -- Check package was loaded
      assert.equals(1, #result.package_order)
      assert.equals("Test", result.package_order[1])
      assert.is_not_nil(result.packages["Test"])
    end)

    it("should process multiple packages with dependencies", function()
      -- Create first package (A)
      local pkg_a_dir = path_join(temp_dir, "pkg_a")
      assert(lfs.mkdir(pkg_a_dir))

      local PKG_A = [[package_id:package_id	PkgA
name:string	Package A
version:version	1.0.0
description:markdown	First package
]]
      local FILES_A = [[fileName:string	typeName:type_spec	superType:superType	baseType:boolean	publishContext:name|nil	publishColumn:name|nil	loadOrder:number	description:text
DataA.tsv	DataA		true			1	Data file A
]]
      local DATA_A = [[name:identifier	val:number
a1	1
]]

      assert.is_true(file_util.writeFile(path_join(pkg_a_dir, MANIFEST_FILENAME), PKG_A))
      assert.is_true(file_util.writeFile(path_join(pkg_a_dir, "files.tsv"), FILES_A))
      assert.is_true(file_util.writeFile(path_join(pkg_a_dir, "DataA.tsv"), DATA_A))

      -- Create second package (B) that depends on A
      local pkg_b_dir = path_join(temp_dir, "pkg_b")
      assert(lfs.mkdir(pkg_b_dir))

      local PKG_B = [[package_id:package_id	PkgB
name:string	Package B
version:version	1.0.0
description:markdown	Second package
dependencies:{{package_id,cmp_version}}|nil	{'PkgA','>=1.0.0'}
]]
      local FILES_B = [[fileName:string	typeName:type_spec	superType:superType	baseType:boolean	publishContext:name|nil	publishColumn:name|nil	loadOrder:number	description:text
DataB.tsv	DataB		true			1	Data file B
]]
      local DATA_B = [[name:identifier	val:number
b1	2
]]

      assert.is_true(file_util.writeFile(path_join(pkg_b_dir, MANIFEST_FILENAME), PKG_B))
      assert.is_true(file_util.writeFile(path_join(pkg_b_dir, "files.tsv"), FILES_B))
      assert.is_true(file_util.writeFile(path_join(pkg_b_dir, "DataB.tsv"), DATA_B))

      local result = manifest_loader.processFiles({pkg_a_dir, pkg_b_dir}, badVal)

      assert.is_not_nil(result)
      assert.equals(2, #result.package_order)
      -- PkgA should come before PkgB due to dependency
      assert.equals("PkgA", result.package_order[1])
      assert.equals("PkgB", result.package_order[2])
    end)

    it("should handle enum files correctly", function()
      local pkg_dir = path_join(temp_dir, "enumpkg")
      assert(lfs.mkdir(pkg_dir))

      local MANIFEST_ENUM = [[package_id:package_id	EnumPkg
name:string	Enum Package
version:version	0.1.0
description:markdown	Package with enum
]]

      assert.is_true(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME), MANIFEST_ENUM))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "files.tsv"), FILES_DESC_WITH_ENUM))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "ColorEnum.tsv"), ENUM_DATA))

      local result = manifest_loader.processFiles({pkg_dir}, badVal)

      assert.is_not_nil(result)
      assert.is_not_nil(result.tsv_files)
    end)

    it("should handle publishContext and publishColumn (constants)", function()
      local pkg_dir = path_join(temp_dir, "constpkg")
      assert(lfs.mkdir(pkg_dir))

      local MANIFEST_CONST = [[package_id:package_id	ConstPkg
name:string	Constants Package
version:version	0.1.0
description:markdown	Package with constants
]]

      assert.is_true(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME), MANIFEST_CONST))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "files.tsv"), FILES_DESC_WITH_CONSTANTS))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "Constants.tsv"), CONSTANTS_DATA))

      local result = manifest_loader.processFiles({pkg_dir}, badVal)

      assert.is_not_nil(result)
      assert.is_not_nil(result.tsv_files)

      -- Find the Constants.tsv file and verify it was processed correctly
      local constants_file = nil
      for file_name, tsv_data in pairs(result.tsv_files) do
        if file_name:match("Constants%.tsv$") then
          constants_file = tsv_data
          break
        end
      end
      assert.is_not_nil(constants_file, "Constants.tsv should be in tsv_files")

      -- The constants file should have parsed rows with correct values
      -- Row 1 is the header, rows 2+ are data
      assert.is_true(#constants_file >= 3, "Should have header + 2 data rows")

      -- Verify the constant values were parsed correctly
      local found_max_health = false
      local found_max_mana = false
      for i = 2, #constants_file do
        local row = constants_file[i]
        if type(row) == "table" then
          local name_cell = row[1] or row['name']
          local value_cell = row[2] or row['value']
          if name_cell and value_cell then
            local name = name_cell.parsed or name_cell.reformatted
            local value = value_cell.parsed
            if name == "MAX_HEALTH" then
              assert.equals(100, value)
              found_max_health = true
            elseif name == "MAX_MANA" then
              assert.equals(50, value)
              found_max_mana = true
            end
          end
        end
      end
      assert.is_true(found_max_health, "MAX_HEALTH constant should be found with value 100")
      assert.is_true(found_max_mana, "MAX_MANA constant should be found with value 50")
    end)

    it("should fail when dependency is missing", function()
      local pkg_dir = path_join(temp_dir, "missingdep")
      assert(lfs.mkdir(pkg_dir))

      local MANIFEST_MISSING_DEP = [[package_id:package_id	MissingDep
name:string	Package with missing dependency
version:version	0.1.0
description:markdown	This package depends on a non-existent package
dependencies:{{package_id,cmp_version}}|nil	{'NonExistent','>=1.0.0'}
]]

      assert.is_true(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME), MANIFEST_MISSING_DEP))

      local result = manifest_loader.processFiles({pkg_dir}, badVal)

      assert.is_nil(result)
    end)

    it("should fail on circular dependencies", function()
      -- Create package X that depends on Y
      local pkg_x_dir = path_join(temp_dir, "pkg_x")
      assert(lfs.mkdir(pkg_x_dir))

      local PKG_X = [[package_id:package_id	PkgX
name:string	Package X
version:version	1.0.0
description:markdown	Package X depends on Y
dependencies:{{package_id,cmp_version}}|nil	{'PkgY','>=1.0.0'}
]]
      assert.is_true(file_util.writeFile(path_join(pkg_x_dir, MANIFEST_FILENAME), PKG_X))

      -- Create package Y that depends on X (circular)
      local pkg_y_dir = path_join(temp_dir, "pkg_y")
      assert(lfs.mkdir(pkg_y_dir))

      local PKG_Y = [[package_id:package_id	PkgY
name:string	Package Y
version:version	1.0.0
description:markdown	Package Y depends on X
dependencies:{{package_id,cmp_version}}|nil	{'PkgX','>=1.0.0'}
]]
      assert.is_true(file_util.writeFile(path_join(pkg_y_dir, MANIFEST_FILENAME), PKG_Y))

      local result = manifest_loader.processFiles({pkg_x_dir, pkg_y_dir}, badVal)

      assert.is_nil(result)
    end)

    it("should handle non-TSV files gracefully", function()
      local pkg_dir = path_join(temp_dir, "mixedpkg")
      assert(lfs.mkdir(pkg_dir))

      local MANIFEST_MIXED = [[package_id:package_id	MixedPkg
name:string	Mixed Package
version:version	0.1.0
description:markdown	Package with mixed file types
]]
      local FILES_MIXED = [[fileName:string	typeName:type_spec	superType:superType	baseType:boolean	publishContext:name|nil	publishColumn:name|nil	loadOrder:number	description:text
Data.tsv	MixedData		true			1	TSV data file
]]
      local DATA_MIXED = [[name:identifier	val:number
x1	1
]]

      assert.is_true(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME), MANIFEST_MIXED))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "files.tsv"), FILES_MIXED))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "Data.tsv"), DATA_MIXED))
      -- Add a non-TSV file (should be read but not processed as TSV)
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "readme.txt"), "This is a readme file"))

      local result = manifest_loader.processFiles({pkg_dir}, badVal)

      assert.is_not_nil(result)
      assert.is_not_nil(result.raw_files)
      -- The txt file should be in raw_files
      local found_txt = false
      for file_name, _ in pairs(result.raw_files) do
        if file_name:match("readme%.txt$") then
          found_txt = true
          break
        end
      end
      assert.is_true(found_txt, "readme.txt should be in raw_files")
    end)

    it("should collect all raw file contents", function()
      local pkg_dir = path_join(temp_dir, "rawpkg")
      assert(lfs.mkdir(pkg_dir))

      assert.is_true(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME), MANIFEST_TEST))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "files.tsv"), FILES_DESC))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "TestData.tsv"), TEST_DATA))

      local result = manifest_loader.processFiles({pkg_dir}, badVal)

      assert.is_not_nil(result)
      assert.is_not_nil(result.raw_files)

      -- Count files in raw_files
      local count = 0
      for _, _ in pairs(result.raw_files) do
        count = count + 1
      end
      -- Should have at least the manifest, files.tsv, and TestData.tsv
      assert.is_true(count >= 3)
    end)

    it("should process files in priority order", function()
      local pkg_dir = path_join(temp_dir, "priopkg")
      assert(lfs.mkdir(pkg_dir))

      local MANIFEST_PRIO = [[package_id:package_id	PrioPkg
name:string	Priority Package
version:version	0.1.0
description:markdown	Package testing priority order
]]
      -- Define files with different priorities. Low (priority 1) defines BASE_VALUE.
      -- Medium (priority 5) uses BASE_VALUE in an expression.
      -- High (priority 10) uses the result from Medium in an expression.
      -- If priority order is wrong, the expressions will fail or produce wrong values.
      local FILES_PRIO = [[fileName:string	typeName:type_spec	superType:superType	baseType:boolean	publishContext:name|nil	publishColumn:name|nil	loadOrder:number	description:text
Low.tsv	LowPrio		true		value	1	Low priority - defines BASE_VALUE
Medium.tsv	MediumPrio		true		value	5	Medium priority - uses BASE_VALUE
High.tsv	HighPrio		true			10	High priority - uses MEDIUM_VALUE
]]
      -- Low priority file defines BASE_VALUE = 10
      local DATA_LOW = [[name:identifier	value:number
BASE_VALUE	10
]]
      -- Medium priority uses BASE_VALUE (should be 10), computes MEDIUM_VALUE = 20
      local DATA_MEDIUM = [[name:identifier	value:number
MEDIUM_VALUE	=BASE_VALUE * 2
]]
      -- High priority uses MEDIUM_VALUE (should be 20), computes result = 40
      local DATA_HIGH = [[name:identifier	result:number
high	=MEDIUM_VALUE * 2
]]

      assert.is_true(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME), MANIFEST_PRIO))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "files.tsv"), FILES_PRIO))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "High.tsv"), DATA_HIGH))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "Low.tsv"), DATA_LOW))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "Medium.tsv"), DATA_MEDIUM))

      local result = manifest_loader.processFiles({pkg_dir}, badVal)

      assert.is_not_nil(result)
      assert.is_not_nil(result.tsv_files)

      -- Verify the expression chain worked correctly, proving priority order
      -- Find High.tsv and check that the expression evaluated correctly
      local high_file = nil
      for file_name, tsv_data in pairs(result.tsv_files) do
        if file_name:match("High%.tsv$") then
          high_file = tsv_data
          break
        end
      end
      assert.is_not_nil(high_file, "High.tsv should be in tsv_files")

      -- Check that the expression =MEDIUM_VALUE * 2 evaluated to 40
      -- This proves: Low was processed first (BASE_VALUE=10),
      -- then Medium (MEDIUM_VALUE=10*2=20), then High (result=20*2=40)
      local found_result = false
      for i = 2, #high_file do
        local row = high_file[i]
        if type(row) == "table" then
          local result_cell = row[2] or row['result']
          if result_cell and result_cell.parsed then
            assert.equals(40, result_cell.parsed, "Expression chain should evaluate to 40")
            found_result = true
            break
          end
        end
      end
      assert.is_true(found_result, "Should find the computed result proving priority order")
    end)

    it("should handle load_after ordering", function()
      -- Create package P with no dependencies
      local pkg_p_dir = path_join(temp_dir, "pkg_p")
      assert(lfs.mkdir(pkg_p_dir))

      local PKG_P = [[package_id:package_id	PkgP
name:string	Package P
version:version	1.0.0
description:markdown	First package (no deps)
]]
      local FILES_P = [[fileName:string	typeName:type_spec	superType:superType	baseType:boolean	publishContext:name|nil	publishColumn:name|nil	loadOrder:number	description:text
DataP.tsv	DataP		true			1	Data file P
]]
      local DATA_P = [[name:identifier	val:number
p1	1
]]

      assert.is_true(file_util.writeFile(path_join(pkg_p_dir, MANIFEST_FILENAME), PKG_P))
      assert.is_true(file_util.writeFile(path_join(pkg_p_dir, "files.tsv"), FILES_P))
      assert.is_true(file_util.writeFile(path_join(pkg_p_dir, "DataP.tsv"), DATA_P))

      -- Create package Q with load_after P
      local pkg_q_dir = path_join(temp_dir, "pkg_q")
      assert(lfs.mkdir(pkg_q_dir))

      local PKG_Q = [[package_id:package_id	PkgQ
name:string	Package Q
version:version	1.0.0
description:markdown	Second package (load after P)
load_after:{package_id}|nil	'PkgP'
]]
      local FILES_Q = [[fileName:string	typeName:type_spec	superType:superType	baseType:boolean	publishContext:name|nil	publishColumn:name|nil	loadOrder:number	description:text
DataQ.tsv	DataQ		true			1	Data file Q
]]
      local DATA_Q = [[name:identifier	val:number
q1	2
]]

      assert.is_true(file_util.writeFile(path_join(pkg_q_dir, MANIFEST_FILENAME), PKG_Q))
      assert.is_true(file_util.writeFile(path_join(pkg_q_dir, "files.tsv"), FILES_Q))
      assert.is_true(file_util.writeFile(path_join(pkg_q_dir, "DataQ.tsv"), DATA_Q))

      local result = manifest_loader.processFiles({pkg_p_dir, pkg_q_dir}, badVal)

      assert.is_not_nil(result)
      assert.equals(2, #result.package_order)
      -- PkgP should come before PkgQ due to load_after
      assert.equals("PkgP", result.package_order[1])
      assert.equals("PkgQ", result.package_order[2])
    end)

    it("should return valid package information", function()
      local pkg_dir = path_join(temp_dir, "infopkg")
      assert(lfs.mkdir(pkg_dir))

      local MANIFEST_INFO = [[package_id:package_id	InfoPkg
name:string	Info Package
version:version	2.3.4
description:markdown	Package with detailed info
url:http|nil	http://example.com/infopkg
]]
      local FILES_INFO = [[fileName:string	typeName:type_spec	superType:superType	baseType:boolean	publishContext:name|nil	publishColumn:name|nil	loadOrder:number	description:text
Info.tsv	InfoData		true			1	Info data
]]
      local DATA_INFO = [[name:identifier	val:number
info1	42
]]

      assert.is_true(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME), MANIFEST_INFO))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "files.tsv"), FILES_INFO))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "Info.tsv"), DATA_INFO))

      local result = manifest_loader.processFiles({pkg_dir}, badVal)

      assert.is_not_nil(result)
      assert.is_not_nil(result.packages)
      assert.is_not_nil(result.packages["InfoPkg"])

      local pkg = result.packages["InfoPkg"]
      assert.equals("Info Package", pkg.name)
      assert.equals("2.3.4", tostring(pkg.version))
    end)
  end)

  describe("processFiles with badVal", function()
    it("should create its own badVal if none provided", function()
      local pkg_dir = path_join(temp_dir, "nobadval")
      assert(lfs.mkdir(pkg_dir))

      assert.is_true(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME), MANIFEST_TEST))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "files.tsv"), FILES_DESC))
      assert.is_true(file_util.writeFile(path_join(pkg_dir, "TestData.tsv"), TEST_DATA))

      -- Call without badVal parameter
      local result = manifest_loader.processFiles({pkg_dir})

      assert.is_not_nil(result)
    end)

    it("should report errors through provided badVal", function()
      local pkg_dir = path_join(temp_dir, "errorpkg")
      assert(lfs.mkdir(pkg_dir))

      -- Create a manifest file with invalid content
      local BAD_MANIFEST = [[package_id:package_id	BadPkg
name:string	Bad Package
version:version	not_a_version
description:markdown	Package with bad version
]]

      assert.is_true(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME), BAD_MANIFEST))

      -- Reset error count and log messages before the test
      local initial_errors = badVal.errors or 0
      local initial_log_count = #log_messages

      local result = manifest_loader.processFiles({pkg_dir}, badVal)

      -- Should fail due to bad version format
      assert.is_nil(result)

      -- Verify that the provided badVal was used to report errors
      -- Either the error count increased or log messages were added
      local errors_increased = (badVal.errors or 0) > initial_errors
      local logs_added = #log_messages > initial_log_count

      assert.is_true(errors_increased or logs_added,
        "badVal should have been used to report errors (errors: " ..
        tostring(badVal.errors) .. ", logs: " .. #log_messages .. ")")
    end)
  end)
end)
