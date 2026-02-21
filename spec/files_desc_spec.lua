-- files_desc_spec.lua

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

-- Import busted functions
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local files_desc = require("files_desc")
local file_util = require("file_util")
local parsers = require("parsers")
local table_utils = require("table_utils")
local error_reporting = require("error_reporting")

local pairsCount = table_utils.pairsCount
local badValGen = error_reporting.badValGen
local nullLogger = error_reporting.nullLogger

-- Helper to join paths consistently
local function path_join(...)
  return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- Create test file content
local function create_files_desc_content(files)
  local lines = {
    "fileName:string\ttypeName:type_spec\tsuperType:super_type\tbaseType:boolean\tpublishContext:name|nil\tpublishColumn:name|nil\tloadOrder:number\tdescription:text\tjoinInto:name|nil\tjoinColumn:name|nil\texport:boolean|nil\tjoinedTypeName:type_spec|nil"
  }
  for _, file in ipairs(files) do
    table.insert(lines, table.concat(file, "\t"))
  end
  return table.concat(lines, "\n")
end

-- Returns a "badVal" object that store errors in the given table
local function mockBadVal(log_messages)
  local log = function(self, msg) table.insert(log_messages, msg) end
  local badVal = badValGen(log)
  badVal.source_name = "test"
  badVal.line_no = 1
  return badVal
end

describe("files_desc", function()
  local temp_dir

  describe("getVersion", function()
    it("should return the module version as a string", function()
      local version = files_desc.getVersion()
      assert.is_string(version)
      assert.matches("^%d+%.%d+%.%d+", version)
    end)
  end)

  describe("module metadata", function()
    it("should have a tostring representation", function()
      local str = tostring(files_desc)
      assert.is_string(str)
      assert.matches("files_desc", str)
      assert.matches("version", str)
    end)

    it("should be callable with 'version' operation", function()
      local version = files_desc("version")
      assert.is_not_nil(version)
    end)

    it("should be callable with API operations", function()
      local result = files_desc("isFilesDescriptor", "files.tsv")
      assert.is_true(result)
    end)

    it("should error on unknown operation", function()
      assert.has_error(function()
        files_desc("unknownOperation")
      end)
    end)
  end)

  -- Setup: Create a temporary directory for testing
  before_each(function()
    local system_temp = file_util.getSystemTempDir()
    assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
    local td = path_join(system_temp, "files_desc_test_" .. os.time())
    assert(lfs.mkdir(td))
    temp_dir = td
  end)

  -- Cleanup: Remove temporary directory after tests
  after_each(function()
    if temp_dir then
      local td = temp_dir
      temp_dir = nil
      file_util.deleteTempDir(td)
    end
  end)

  describe("isFilesDescriptor", function()
    it("should identify files.tsv files", function()
      assert.is_true(files_desc.isFilesDescriptor("files.tsv"))
      assert.is_true(files_desc.isFilesDescriptor("path/to/files.tsv"))
      assert.is_true(files_desc.isFilesDescriptor("FILES.TSV"))
    end)

    it("should reject non-files.tsv files", function()
      assert.is_false(files_desc.isFilesDescriptor("file.tsv"))
      assert.is_false(files_desc.isFilesDescriptor("files.txt"))
      assert.is_false(files_desc.isFilesDescriptor("files_desc.tsv"))
    end)
  end)

  describe("extractFilesDescriptors", function()
    it("should extract files.tsv files from a list", function()
      local files = {
        "path/to/files.tsv",
        "path/to/data.tsv",
        "other/files.tsv",
        "test.txt"
      }
      local descriptors = files_desc.extractFilesDescriptors(files)
      assert.equals(2, #descriptors)
      assert.same({"path/to/files.tsv", "other/files.tsv"}, descriptors)
      assert.same({"path/to/data.tsv", "test.txt"}, files)
    end)
  end)

  describe("matchDescriptorFiles", function()
    it("should match descriptors to their modules", function()
      local modules = {
        mod1 = {path = "/modules/mod1/mod1.mod"},
        mod2 = {path = "/modules/mod2/mod2.mod"}
      }
      local descriptors = {
        "/modules/mod1/files.tsv",
        "/modules/mod2/subdir/files.tsv"
      }
      local matches = files_desc.matchDescriptorFiles(modules, descriptors)
      assert.is_not_nil(matches)
      assert.equals("mod1", matches["/modules/mod1/files.tsv"])
      assert.equals("mod2", matches["/modules/mod2/subdir/files.tsv"])
    end)

    it("should handle subdirectories", function()
      local modules = {
        mod1 = {path = "/modules/mod1/mod1.mod"}
      }
      local descriptors = {
        "/modules/mod1/subdir1/files.tsv",
        "/modules/mod1/subdir2/files.tsv"
      }
      local matches = files_desc.matchDescriptorFiles(modules, descriptors)
      assert.is_not_nil(matches)
      assert.equals("mod1", matches["/modules/mod1/subdir1/files.tsv"])
      assert.equals("mod1", matches["/modules/mod1/subdir2/files.tsv"])
    end)

    it("should return nil when descriptor doesn't belong to any module", function()
      local modules = {
        mod1 = {path = "/modules/mod1/mod1.mod"}
      }
      local descriptors = {
        "/other/path/files.tsv"
      }
      local matches = files_desc.matchDescriptorFiles(modules, descriptors, nullLogger)
      assert.is_nil(matches)
    end)

    it("should handle packages whose manifest sits at the scanned root (dot-prefixed path)", function()
      -- Regression test: when the manifest file is found as "./Manifest.transposed.tsv",
      -- normalizePath strips the leading "./" leaving a bare filename with no "/" in it.
      -- getParentPath then returns nil (no parent component), which previously caused a
      -- crash ("attempt to index a nil value") at the :lower() call.
      local modules = {
        core = {path = "./Manifest.transposed.tsv"}
      }
      local descriptors = {
        "./files.tsv"
      }
      local matches = files_desc.matchDescriptorFiles(modules, descriptors)
      assert.is_not_nil(matches)
      assert.equals("core", matches["./files.tsv"])
    end)
  end)

  describe("loadDescriptorFile", function()
    it("should load and parse a valid descriptor file", function()
      local file_path = path_join(temp_dir, "files.tsv")
      local content = create_files_desc_content({
        {"test1.tsv", "Test", "", "true", "", "", "1", "Test file"},
        {"data.tsv", "Data", "Test", "false", "", "", "2", "Data file"}
      })
      assert.is_true(file_util.writeFile(file_path, content))

      local log_messages = {}
      local raw_files = {}
      local badVal = mockBadVal(log_messages)
      local result = files_desc.loadDescriptorFile(file_path, raw_files, {}, badVal)
      
      assert.is_not_nil(result)
      assert.same({}, log_messages)
      -- The "header" also counts as one row
      assert.equals(3, #result)
      assert.equals(1, pairsCount(raw_files))
    end)

    it("should validate type names", function()
      local file_path = path_join(temp_dir, "files.tsv")
      local content = create_files_desc_content({
        {"test2.tsv", "Test", "", "true", "", "", "1", "Test file"},
        {"test2.tsv", "Invalid Type!", "", "true", "", "", "2", "Invalid type name"}
      })
      assert.is_true(file_util.writeFile(file_path, content))

      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local raw_files = {}
      local result = files_desc.loadDescriptorFile(file_path, raw_files, {}, badVal)
      
      assert.is_not_nil(result)
      assert.is_true(badVal.errors > 0)
    end)

    it("should validate base type values", function()
      local file_path = path_join(temp_dir, "files.tsv")
      local content = create_files_desc_content({
        {"test3.tsv", "Test", "", "NotABoolean", "", "", "1", "Invalid base type"}
      })
      assert.is_true(file_util.writeFile(file_path, content))

      local log_messages = {}
      local raw_files = {}
      local badVal = mockBadVal(log_messages)
      local result = files_desc.loadDescriptorFile(file_path, raw_files, {}, badVal)

      assert.is_not_nil(result)
      assert.is_true(badVal.errors > 0)
    end)

    it("should return nil when file does not exist", function()
      local file_path = path_join(temp_dir, "nonexistent_files.tsv")
      local log_messages = {}
      local raw_files = {}
      local badVal = mockBadVal(log_messages)
      local result = files_desc.loadDescriptorFile(file_path, raw_files, {}, badVal)

      assert.is_nil(result)
      assert.is_true(badVal.errors > 0)
    end)
  end)

  describe("loadDescriptorFiles", function()
    it("should load multiple descriptor files in order", function()
      local mod_dir1 = path_join(temp_dir, "mod1")
      local mod_dir2 = path_join(temp_dir, "mod2")
      assert(lfs.mkdir(mod_dir1))
      assert(lfs.mkdir(mod_dir2))

      -- Create descriptor files
      local file1 = path_join(mod_dir1, "files.tsv")
      local file2 = path_join(mod_dir2, "files.tsv")
      
      local content1 = create_files_desc_content({
        {"testA.tsv", "TestA", "", "true", "", "", "1", "Test file A"}
      })
      local content2 = create_files_desc_content({
        {"testB.tsv", "TestB", "TestA", "false", "", "", "2", "Test file B"}
      })

      assert.is_true(file_util.writeFile(file1, content1))
      assert.is_true(file_util.writeFile(file2, content2))

      local desc_files_order = {file1, file2}
      local prios = {}
      local desc_file2mod_id = {
        [file1] = "mod1",
        [file2] = "mod2"
      }
      local post_proc_files = {}
      local extends = {}
      local lcFn2Type = {}
      local lcFn2Ctx = {}
      local lcFn2Col = {}
      local log_messages = {}
      local raw_files = {}
      local badVal = mockBadVal(log_messages)

      local lcFn2JoinInto = {}
      local lcFn2JoinColumn = {}
      local lcFn2Export = {}
      local lcFn2JoinedTypeName = {}
      local result = files_desc.loadDescriptorFiles(desc_files_order, prios,
        desc_file2mod_id, post_proc_files, extends, lcFn2Type, lcFn2Ctx, lcFn2Col,
        lcFn2JoinInto, lcFn2JoinColumn, lcFn2Export, lcFn2JoinedTypeName,
        {}, {}, {},
        raw_files, {}, badVal)

      assert.same({}, log_messages)
      assert.is_not_nil(result)
      assert.equals(2, #result)
      assert.equals("TestA", extends["TestB"])
      assert.equals(2, pairsCount(raw_files))
    end)

    it("should handle enum type definitions", function()
      local file_path = path_join(temp_dir, "files.tsv")
      local content = create_files_desc_content({
        {"MyEnum.tsv", "MyEnum", "enum", "true", "", "", "1", "Enum definition"}
      })
      assert.is_true(file_util.writeFile(file_path, content))

      local desc_files_order = {file_path}
      local prios = {}
      local desc_file2mod_id = {[file_path] = "mod1"}
      local post_proc_files = {}
      local extends = {}
      local lcFn2Type = {}
      local lcFn2Ctx = {}
      local lcFn2Col = {}
      local log_messages = {}
      local raw_files = {}
      local badVal = mockBadVal(log_messages)
      badVal.logger = nullLogger

      local lcFn2JoinInto = {}
      local lcFn2JoinColumn = {}
      local lcFn2Export = {}
      local lcFn2JoinedTypeName = {}
      local result = files_desc.loadDescriptorFiles(desc_files_order, prios,
        desc_file2mod_id, post_proc_files, extends, lcFn2Type, lcFn2Ctx, lcFn2Col,
        lcFn2JoinInto, lcFn2JoinColumn, lcFn2Export, lcFn2JoinedTypeName,
        {}, {}, {},
        raw_files, {}, badVal)

      assert.same({}, log_messages)
      assert.is_not_nil(result)
      assert.is_not_nil(post_proc_files["MyEnum.tsv"])
      assert.equals("MyEnum", lcFn2Type["myenum.tsv"])
      assert.equals(1, pairsCount(raw_files))
    end)

    it("should validate unique file and type names", function()
      local file_path = path_join(temp_dir, "files.tsv")
      local content = create_files_desc_content({
        {"test4.tsv", "Test", "", "true", "", "", "1", "Test file"},
        {"test4.tsv", "Test", "", "true", "", "", "2", "Duplicate file/type"}
      })
      assert.is_true(file_util.writeFile(file_path, content))

      local desc_files_order = {file_path}
      local prios = {}
      local desc_file2mod_id = {[file_path] = "mod1"}
      local post_proc_files = {}
      local extends = {}
      local lcFn2Type = {}
      local lcFn2Ctx = {}
      local lcFn2Col = {}
      local log_messages = {}
      local raw_files = {}
      local badVal = mockBadVal(log_messages)
      badVal.logger = nullLogger

      local lcFn2JoinInto = {}
      local lcFn2JoinColumn = {}
      local lcFn2Export = {}
      local lcFn2JoinedTypeName = {}
      local result = files_desc.loadDescriptorFiles(desc_files_order, prios,
        desc_file2mod_id, post_proc_files, extends, lcFn2Type, lcFn2Ctx, lcFn2Col,
        lcFn2JoinInto, lcFn2JoinColumn, lcFn2Export, lcFn2JoinedTypeName,
        {}, {}, {},
        raw_files, {}, badVal)

      assert.is_not_nil(result)
      assert.is_true(badVal.errors > 0)
      assert.equals(1, pairsCount(raw_files))
    end)

    it("should handle publishContext and publishColumn values", function()
      local file_path = path_join(temp_dir, "files.tsv")
      local content = create_files_desc_content({
        {"test5.tsv", "Test5", "", "true", "myContext", "myColumn", "1", "With publish info"}
      })
      assert.is_true(file_util.writeFile(file_path, content))

      local desc_files_order = {file_path}
      local prios = {}
      local desc_file2mod_id = {[file_path] = "mod1"}
      local post_proc_files = {}
      local extends = {}
      local lcFn2Type = {}
      local lcFn2Ctx = {}
      local lcFn2Col = {}
      local log_messages = {}
      local raw_files = {}
      local badVal = mockBadVal(log_messages)
      badVal.logger = nullLogger

      local lcFn2JoinInto = {}
      local lcFn2JoinColumn = {}
      local lcFn2Export = {}
      local lcFn2JoinedTypeName = {}
      local result = files_desc.loadDescriptorFiles(desc_files_order, prios,
        desc_file2mod_id, post_proc_files, extends, lcFn2Type, lcFn2Ctx, lcFn2Col,
        lcFn2JoinInto, lcFn2JoinColumn, lcFn2Export, lcFn2JoinedTypeName,
        {}, {}, {},
        raw_files, {}, badVal)

      assert.is_not_nil(result)
      assert.equals("myContext", lcFn2Ctx["test5.tsv"])
      assert.equals("myColumn", lcFn2Col["test5.tsv"])
    end)

    it("should handle file joining columns", function()
      local file_path = path_join(temp_dir, "files.tsv")
      -- Primary file with joinedTypeName, secondary file with joinInto and joinColumn
      local content = create_files_desc_content({
        {"Primary.tsv", "Primary", "", "true", "", "", "1", "Primary file", "", "", "", "PrimaryWithJoined"},
        {"Secondary.tsv", "Secondary", "", "false", "", "", "2", "Secondary file", "Primary.tsv", "id", "false", ""}
      })
      assert.is_true(file_util.writeFile(file_path, content))

      local desc_files_order = {file_path}
      local prios = {}
      local desc_file2mod_id = {[file_path] = "mod1"}
      local post_proc_files = {}
      local extends = {}
      local lcFn2Type = {}
      local lcFn2Ctx = {}
      local lcFn2Col = {}
      local log_messages = {}
      local raw_files = {}
      local badVal = mockBadVal(log_messages)
      badVal.logger = nullLogger

      local lcFn2JoinInto = {}
      local lcFn2JoinColumn = {}
      local lcFn2Export = {}
      local lcFn2JoinedTypeName = {}
      local result = files_desc.loadDescriptorFiles(desc_files_order, prios,
        desc_file2mod_id, post_proc_files, extends, lcFn2Type, lcFn2Ctx, lcFn2Col,
        lcFn2JoinInto, lcFn2JoinColumn, lcFn2Export, lcFn2JoinedTypeName,
        {}, {}, {},
        raw_files, {}, badVal)

      assert.is_not_nil(result)
      -- Verify join configuration for secondary file
      assert.equals("primary.tsv", lcFn2JoinInto["secondary.tsv"])
      assert.equals("id", lcFn2JoinColumn["secondary.tsv"])
      assert.equals(false, lcFn2Export["secondary.tsv"])
      -- Verify joinedTypeName for primary file
      assert.equals("PrimaryWithJoined", lcFn2JoinedTypeName["primary.tsv"])
      -- Primary file should not have joinInto
      assert.is_nil(lcFn2JoinInto["primary.tsv"])
    end)

    it("should handle Type parent for post-processing detection", function()
      local file_path = path_join(temp_dir, "files.tsv")
      local content = create_files_desc_content({
        {"MyType.tsv", "MyType", "Type", "false", "", "", "1", "Type definition"}
      })
      assert.is_true(file_util.writeFile(file_path, content))

      local desc_files_order = {file_path}
      local prios = {}
      local desc_file2mod_id = {[file_path] = "mod1"}
      local post_proc_files = {}
      local extends = {}
      local lcFn2Type = {}
      local lcFn2Ctx = {}
      local lcFn2Col = {}
      local log_messages = {}
      local raw_files = {}
      local badVal = mockBadVal(log_messages)
      badVal.logger = nullLogger

      local lcFn2JoinInto = {}
      local lcFn2JoinColumn = {}
      local lcFn2Export = {}
      local lcFn2JoinedTypeName = {}
      local result = files_desc.loadDescriptorFiles(desc_files_order, prios,
        desc_file2mod_id, post_proc_files, extends, lcFn2Type, lcFn2Ctx, lcFn2Col,
        lcFn2JoinInto, lcFn2JoinColumn, lcFn2Export, lcFn2JoinedTypeName,
        {}, {}, {},
        raw_files, {}, badVal)

      assert.is_not_nil(result)
      assert.is_not_nil(post_proc_files["MyType.tsv"])
      assert.equals("MyType", post_proc_files["MyType.tsv"])
    end)

    it("should track priority offsets across modules", function()
      local mod_dir1 = path_join(temp_dir, "mod1")
      local mod_dir2 = path_join(temp_dir, "mod2")
      assert(lfs.mkdir(mod_dir1))
      assert(lfs.mkdir(mod_dir2))

      local file1 = path_join(mod_dir1, "files.tsv")
      local file2 = path_join(mod_dir2, "files.tsv")

      -- mod1 has priorities 1, 2
      local content1 = create_files_desc_content({
        {"a.tsv", "A", "", "true", "", "", "1", "File A"},
        {"b.tsv", "B", "", "true", "", "", "2", "File B"}
      })
      -- mod2 has priorities 1, 2 (should be offset by mod1's max priority)
      local content2 = create_files_desc_content({
        {"c.tsv", "C", "", "true", "", "", "1", "File C"},
        {"d.tsv", "D", "", "true", "", "", "2", "File D"}
      })

      assert.is_true(file_util.writeFile(file1, content1))
      assert.is_true(file_util.writeFile(file2, content2))

      local desc_files_order = {file1, file2}
      local prios = {}
      local desc_file2mod_id = {
        [file1] = "mod1",
        [file2] = "mod2"
      }
      local post_proc_files = {}
      local extends = {}
      local lcFn2Type = {}
      local lcFn2Ctx = {}
      local lcFn2Col = {}
      local log_messages = {}
      local raw_files = {}
      local badVal = mockBadVal(log_messages)
      badVal.logger = nullLogger

      local lcFn2JoinInto = {}
      local lcFn2JoinColumn = {}
      local lcFn2Export = {}
      local lcFn2JoinedTypeName = {}
      local result = files_desc.loadDescriptorFiles(desc_files_order, prios,
        desc_file2mod_id, post_proc_files, extends, lcFn2Type, lcFn2Ctx, lcFn2Col,
        lcFn2JoinInto, lcFn2JoinColumn, lcFn2Export, lcFn2JoinedTypeName,
        {}, {}, {},
        raw_files, {}, badVal)

      assert.is_not_nil(result)
      -- mod1 priorities: 1, 2
      assert.equals(1, prios["a.tsv"])
      assert.equals(2, prios["b.tsv"])
      -- mod2 priorities should be offset (max of mod1 is 2, so offset is 3)
      assert.equals(4, prios["c.tsv"])  -- 1 + 3 = 4
      assert.equals(5, prios["d.tsv"])  -- 2 + 3 = 5
    end)

    it("should validate consistent field types across sibling sub-types", function()
      -- Register type aliases first
      local bv = badValGen()
      -- TestAnimal is a record with 'kind' and 'age' fields (records need at least 2 fields)
      parsers.registerAlias(bv, 'TestAnimal', '{kind:string,age:int}')
      -- TestDog extends TestAnimal with breed and weight:int
      parsers.registerAlias(bv, 'TestDog', '{extends:TestAnimal,breed:string,weight:int}')
      -- TestCat extends TestAnimal with color and weight:string (conflict with TestDog!)
      parsers.registerAlias(bv, 'TestCat', '{extends:TestAnimal,color:string,weight:string}')

      -- Create files.tsv referencing these types
      local file_path = path_join(temp_dir, "files.tsv")
      local content = create_files_desc_content({
        {"animal.tsv", "TestAnimal", "", "true", "", "", "1", "Base animal type"},
        {"dog.tsv", "TestDog", "TestAnimal", "false", "", "", "2", "Dog type"},
        {"cat.tsv", "TestCat", "TestAnimal", "false", "", "", "3", "Cat type"}
      })
      assert.is_true(file_util.writeFile(file_path, content))

      local desc_files_order = {file_path}
      local prios = {}
      local desc_file2mod_id = {[file_path] = "mod1"}
      local post_proc_files = {}
      local extends = {}
      local lcFn2Type = {}
      local lcFn2Ctx = {}
      local lcFn2Col = {}
      local log_messages = {}
      local raw_files = {}
      local badVal = mockBadVal(log_messages)
      badVal.logger = nullLogger

      local lcFn2JoinInto = {}
      local lcFn2JoinColumn = {}
      local lcFn2Export = {}
      local lcFn2JoinedTypeName = {}
      local result = files_desc.loadDescriptorFiles(desc_files_order, prios,
        desc_file2mod_id, post_proc_files, extends, lcFn2Type, lcFn2Ctx, lcFn2Col,
        lcFn2JoinInto, lcFn2JoinColumn, lcFn2Export, lcFn2JoinedTypeName,
        {}, {}, {},
        raw_files, {}, badVal)

      -- The validation should catch that TestDog and TestCat have 'weight' with different types
      -- Both types extend TestAnimal, so they are siblings in the type hierarchy
      assert.is_not_nil(result)  -- File loading succeeds
      assert.is_true(badVal.errors > 0)  -- But validation should report the field type conflict
    end)

    it("should return nil when a descriptor file fails to load", function()
      local mod_dir1 = path_join(temp_dir, "mod1")
      assert(lfs.mkdir(mod_dir1))

      -- Create a valid file reference but don't actually create file2
      local file1 = path_join(mod_dir1, "files.tsv")
      local file2 = path_join(mod_dir1, "missing_files.tsv")

      local content1 = create_files_desc_content({
        {"test.tsv", "Test", "", "true", "", "", "1", "Test file"}
      })
      assert.is_true(file_util.writeFile(file1, content1))

      local desc_files_order = {file1, file2}
      local prios = {}
      local desc_file2mod_id = {
        [file1] = "mod1",
        [file2] = "mod1"
      }
      local post_proc_files = {}
      local extends = {}
      local lcFn2Type = {}
      local lcFn2Ctx = {}
      local lcFn2Col = {}
      local log_messages = {}
      local raw_files = {}
      local badVal = mockBadVal(log_messages)
      badVal.logger = nullLogger

      local lcFn2JoinInto = {}
      local lcFn2JoinColumn = {}
      local lcFn2Export = {}
      local lcFn2JoinedTypeName = {}
      local result = files_desc.loadDescriptorFiles(desc_files_order, prios,
        desc_file2mod_id, post_proc_files, extends, lcFn2Type, lcFn2Ctx, lcFn2Col,
        lcFn2JoinInto, lcFn2JoinColumn, lcFn2Export, lcFn2JoinedTypeName,
        {}, {}, {},
        raw_files, {}, badVal)

      assert.is_nil(result)
    end)
  end)

  describe("orderFilesDescByPackageOrder", function()
    it("should order files based on package dependencies", function()
      local package_order = {"pkg1", "pkg2"}
      local desc_file2package_id = {
        ["pkg2/files.tsv"] = "pkg2",
        ["pkg1/files.tsv"] = "pkg1",
        ["pkg1/subdir/files.tsv"] = "pkg1"
      }

      local result = files_desc.orderFilesDescByPackageOrder(package_order, desc_file2package_id)

      assert.equals(3, #result)
      -- Files from pkg1 should come before files from pkg2
      assert.equals("pkg1", desc_file2package_id[result[1]])
      assert.equals("pkg1", desc_file2package_id[result[2]])
      assert.equals("pkg2", desc_file2package_id[result[3]])
    end)
  end)

  describe("duplicate file/type name warnings", function()
    it("should warn about duplicate file names from different descriptors", function()
      local file_path1 = path_join(temp_dir, "pkg1")
      local file_path2 = path_join(temp_dir, "pkg2")
      assert(lfs.mkdir(file_path1))
      assert(lfs.mkdir(file_path2))

      local desc1_path = path_join(file_path1, "files.tsv")
      local desc2_path = path_join(file_path2, "files.tsv")

      -- Both descriptors list "data.tsv" - should warn
      local content1 = create_files_desc_content({
        {"data.tsv", "Data", "", "true", "", "", "1", "Data file"}
      })
      local content2 = create_files_desc_content({
        {"data.tsv", "Data", "", "true", "", "", "1", "Data file"}
      })
      assert.is_true(file_util.writeFile(desc1_path, content1))
      assert.is_true(file_util.writeFile(desc2_path, content2))

      local warnings = {}
      local mockLog = {
        warn = function(self, msg) table.insert(warnings, msg) end,
        error = function() end,
        info = function() end
      }
      local badVal = badValGen()
      badVal.logger = mockLog

      local prios = {}
      local desc_files_order = {desc1_path, desc2_path}
      local desc_file2mod_id = {
        [desc1_path] = "pkg1",
        [desc2_path] = "pkg2"
      }

      local raw_files = {}
      files_desc.loadDescriptorFiles(desc_files_order, prios, desc_file2mod_id,
        {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, raw_files, {}, badVal)

      -- Should have warnings about duplicate data.tsv and Data type
      assert.is_true(#warnings >= 1)
      local found_data_warning = false
      for _, w in ipairs(warnings) do
        if w:match("Multiple files with name 'data.tsv'") or
           w:match("Multiple types with name 'data'") then
          found_data_warning = true
          break
        end
      end
      assert.is_true(found_data_warning, "Expected warning about duplicate data.tsv")
    end)

    it("should NOT warn about duplicate Files.tsv across packages", function()
      local file_path1 = path_join(temp_dir, "pkg1")
      local file_path2 = path_join(temp_dir, "pkg2")
      assert(lfs.mkdir(file_path1))
      assert(lfs.mkdir(file_path2))

      local desc1_path = path_join(file_path1, "files.tsv")
      local desc2_path = path_join(file_path2, "files.tsv")

      -- Both descriptors list themselves as "Files.tsv" - should NOT warn
      local content1 = create_files_desc_content({
        {"Files.tsv", "Files", "", "true", "", "", "0", "Descriptor file"}
      })
      local content2 = create_files_desc_content({
        {"Files.tsv", "Files", "", "true", "", "", "0", "Descriptor file"}
      })
      assert.is_true(file_util.writeFile(desc1_path, content1))
      assert.is_true(file_util.writeFile(desc2_path, content2))

      local warnings = {}
      local mockLog = {
        warn = function(self, msg) table.insert(warnings, msg) end,
        error = function() end,
        info = function() end
      }
      local badVal = badValGen()
      badVal.logger = mockLog

      local prios = {}
      local desc_files_order = {desc1_path, desc2_path}
      local desc_file2mod_id = {
        [desc1_path] = "pkg1",
        [desc2_path] = "pkg2"
      }

      local raw_files = {}
      files_desc.loadDescriptorFiles(desc_files_order, prios, desc_file2mod_id,
        {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, raw_files, {}, badVal)

      -- Should NOT have warnings about Files.tsv or Files type
      for _, w in ipairs(warnings) do
        assert.is_false(w:match("Multiple files with name 'files.tsv'"),
          "Should not warn about duplicate Files.tsv: " .. w)
        assert.is_false(w:match("Multiple types with name 'files'"),
          "Should not warn about duplicate Files type: " .. w)
      end
    end)
  end)
end)
