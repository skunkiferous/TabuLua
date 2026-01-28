-- manifest_info_spec.lua

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
local parsers = require("parsers")
local manifest_info = require("manifest_info")
local error_reporting = require("error_reporting")

-- Simple path join function
local function path_join(...)
  return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- Returns a "badVal" object that store errors in the given table
local function mockBadVal(log_messages)
  local log = function(self, msg) table.insert(log_messages, msg) end
  local badVal = error_reporting.badValGen(log)
  badVal.source_name = "test"
  badVal.line_no = 1
  return badVal
end

-- The first package, "A", with no dependency
local PKG_A = [[package_id:package_id	A
name:string	The A package
version:version	0.1.0
description:markdown	The A package is the first test package, so it has no dependency
url:http|nil	http://example.com/packages/A
type_aliases:{{name,type_spec}}|nil	{'pkg_a_type','name'}
]]

-- The second package, "B", with no dependency, but loads after A, if present
local PKG_B = [[package_id:package_id	B
name:string	The B package
version:version	0.2.0
description:markdown	The B package is the second test package, and has no dependency
url:http|nil	http://example.com/packages/B
load_after:{package_id}|nil	'A'
]]

-- The third package, "C", depends on A and B
local PKG_C = [[package_id:package_id	C
name:string	The C package
version:version	0.3.0
description:markdown	The C package is the third test package, and depends on A and B
url:http|nil	http://example.com/packages/C
dependencies:{{package_id,cmp_version}}|nil	{'A','=0.1.0'},{'B','=0.2.0'}
]]

-- Package with missing required column (no name field)
local PKG_MISSING_COL = [[package_id:package_id	Missing
version:version	0.1.0
description:markdown	This package is missing the required 'name' column
]]

-- Package with multiple data rows (invalid)
local PKG_MULTI_ROW = [[package_id:package_id	Multi1	Multi2
name:string	First	Second
version:version	0.1.0	0.2.0
description:markdown	First desc	Second desc
]]

-- Package D depends on non-existent package X
local PKG_D_MISSING_DEP = [[package_id:package_id	D
name:string	The D package
version:version	0.1.0
description:markdown	The D package depends on non-existent package X
dependencies:{{package_id,cmp_version}}|nil	{'X','=1.0.0'}
]]

-- Package E depends on A but with wrong version
local PKG_E_VERSION_MISMATCH = [[package_id:package_id	E
name:string	The E package
version:version	0.1.0
description:markdown	The E package depends on A with wrong version
dependencies:{{package_id,cmp_version}}|nil	{'A','=9.9.9'}
]]

-- Package F depends on G (for circular dependency test)
local PKG_F_CIRCULAR = [[package_id:package_id	F
name:string	The F package
version:version	0.1.0
description:markdown	The F package depends on G
dependencies:{{package_id,cmp_version}}|nil	{'G','=0.1.0'}
]]

-- Package G depends on F (for circular dependency test)
local PKG_G_CIRCULAR = [[package_id:package_id	G
name:string	The G package
version:version	0.1.0
description:markdown	The G package depends on F
dependencies:{{package_id,cmp_version}}|nil	{'F','=0.1.0'}
]]

-- Manifest filename constant
local MANIFEST_FILENAME = "Manifest.transposed.tsv"

describe("manifest_info", function()
  local temp_dir
  local log_messages
  local badVal

  -- Setup: Create a temporary directory for testing
  before_each(function()
    local system_temp = file_util.getSystemTempDir()
    assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
    local td = path_join(system_temp, "lua_raw_tsv_test_" .. os.time())
    assert(lfs.mkdir(td))
    temp_dir = td
    log_messages = {}
    badVal = mockBadVal(log_messages)
    badVal.logger = error_reporting.nullLogger
  end)

  describe("getVersion", function()
    it("should return a string", function()
      local version = manifest_info.getVersion()
      assert.is_string(version)
    end)

    it("should return a valid semver format", function()
      local version = manifest_info.getVersion()
      assert.is_truthy(version:match("^%d+%.%d+%.%d+"))
    end)
  end)

  describe("FILENAME constant", function()
    it("should be 'Manifest.transposed.tsv'", function()
      assert.equal("Manifest.transposed.tsv", manifest_info.FILENAME)
    end)
  end)

  describe("API metamethods", function()
    it("should be callable with 'version' operation", function()
      local version = manifest_info("version")
      assert.is_not_nil(version)
    end)

    it("should be callable with exported function names", function()
      local result = manifest_info("isManifestFile", "x/Manifest.transposed.tsv")
      assert.is_true(result)
    end)

    it("should error on unknown operations", function()
      assert.has_error(function()
        manifest_info("unknown_operation")
      end)
    end)

    it("should have a tostring representation", function()
      local str = tostring(manifest_info)
      assert.is_string(str)
      assert.is_truthy(str:find("manifest_info"))
      assert.is_truthy(str:find("version"))
    end)
  end)

  -- Teardown: Remove the temporary directory after tests
  after_each(function()
    if temp_dir then
      local td = temp_dir
      temp_dir = nil
      file_util.deleteTempDir(td)
    end
  end)

  describe("isManifestFile", function()
    it("should return true for a valid manifest file", function()
      assert.is_true(manifest_info.isManifestFile(path_join(temp_dir, MANIFEST_FILENAME)), MANIFEST_FILENAME)
    end)

    it("should return false for other files", function()
      assert.is_false(manifest_info.isManifestFile("player.tsv"), "player.tsv")
    end)

    it("should return false for nil input", function()
      assert.is_false(manifest_info.isManifestFile(nil))
    end)

    it("should return false for non-string input", function()
      assert.is_false(manifest_info.isManifestFile(123))
      assert.is_false(manifest_info.isManifestFile({}))
    end)

    it("should return false for files without correct name", function()
      assert.is_false(manifest_info.isManifestFile("player"))
      assert.is_false(manifest_info.isManifestFile("manifest.tsv"))
    end)

    it("should return false for files with similar but wrong name", function()
      assert.is_false(manifest_info.isManifestFile("Manifest.tsv"))
      assert.is_false(manifest_info.isManifestFile("manifest.transposed.tsv"))
    end)
  end)

  describe("loadManifestFile", function()
    it("should load our test files", function()
      local a_file = path_join(temp_dir, 'x', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'x'))
      assert.is_true(file_util.writeFile(a_file, PKG_A), MANIFEST_FILENAME)
      local raw_files = {}
      local a,tsv = manifest_info.loadManifestFile(badVal, raw_files, {}, a_file)
      assert.is_not_nil(a, MANIFEST_FILENAME)
      assert.is_not_nil(tsv, "a.tsv")
    end)

    it("should not load bad manifest files", function()
      local a_file = path_join(temp_dir, 'x', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'x'))
      assert.is_true(file_util.writeFile(a_file, "a\tb\tc\nd\te\tf"), MANIFEST_FILENAME)
      local raw_files = {}
      local a,tsv = manifest_info.loadManifestFile(badVal, raw_files, {}, a_file)
      assert.is_nil(a, MANIFEST_FILENAME)
      assert.is_nil(tsv, "a.tsv")
      assert.equals(1, #log_messages)
    end)

    it("should reject files with wrong name", function()
      local bad_file = path_join(temp_dir, 'x', "a.txt")
      lfs.mkdir(path_join(temp_dir, 'x'))
      assert.is_true(file_util.writeFile(bad_file, PKG_A), "a.txt")
      local raw_files = {}
      local a, tsv = manifest_info.loadManifestFile(badVal, raw_files, {}, bad_file)
      assert.is_nil(a)
      assert.is_nil(tsv)
      assert.is_true(#log_messages > 0)
    end)

    it("should reject non-existent files", function()
      local missing_file = path_join(temp_dir, 'x', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'x'))
      local raw_files = {}
      local a, tsv = manifest_info.loadManifestFile(badVal, raw_files, {}, missing_file)
      assert.is_nil(a)
      assert.is_nil(tsv)
      assert.is_true(#log_messages > 0)
    end)

    it("should reject manifest files with missing required columns", function()
      local missing_col_file = path_join(temp_dir, 'x', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'x'))
      assert.is_true(file_util.writeFile(missing_col_file, PKG_MISSING_COL))
      local raw_files = {}
      local a, tsv = manifest_info.loadManifestFile(badVal, raw_files, {}, missing_col_file)
      assert.is_nil(a)
      assert.is_nil(tsv)
      assert.is_true(#log_messages > 0)
    end)

    it("should reject manifest files with multiple data rows", function()
      local multi_row_file = path_join(temp_dir, 'x', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'x'))
      assert.is_true(file_util.writeFile(multi_row_file, PKG_MULTI_ROW))
      local raw_files = {}
      local a, tsv = manifest_info.loadManifestFile(badVal, raw_files, {}, multi_row_file)
      assert.is_nil(a)
      assert.is_nil(tsv)
      assert.is_true(#log_messages > 0)
    end)

    it("should parse dependencies correctly", function()
      local c_file = path_join(temp_dir, 'c', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'c'))
      assert.is_true(file_util.writeFile(c_file, PKG_C))
      local raw_files = {}
      local c = manifest_info.loadManifestFile(badVal, raw_files, {}, c_file)
      assert.is_not_nil(c)
      assert.is_not_nil(c.dependencies)
      assert.equals(2, #c.dependencies)
      -- Check first dependency
      assert.equals("A", c.dependencies[1].package_id)
      assert.equals("=", c.dependencies[1].req_op)
      assert.equals("0.1.0", c.dependencies[1].req_version)
      -- Check second dependency
      assert.equals("B", c.dependencies[2].package_id)
      assert.equals("=", c.dependencies[2].req_op)
      assert.equals("0.2.0", c.dependencies[2].req_version)
    end)

    it("should parse load_after correctly", function()
      local b_file = path_join(temp_dir, 'b', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'b'))
      assert.is_true(file_util.writeFile(b_file, PKG_B))
      local raw_files = {}
      local b = manifest_info.loadManifestFile(badVal, raw_files, {}, b_file)
      assert.is_not_nil(b)
      assert.is_not_nil(b.load_after)
      assert.equals(1, #b.load_after)
      assert.equals("A", b.load_after[1])
    end)

  end)

  describe("resolveDependencies", function()
    it("should resolve our test files", function()
      local a_file = path_join(temp_dir, 'a', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'a'))
      assert.is_true(file_util.writeFile(a_file, PKG_A), "a manifest")
      local b_file = path_join(temp_dir, 'b', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'b'))
      assert.is_true(file_util.writeFile(b_file, PKG_B), "b manifest")
      local c_file = path_join(temp_dir, 'c', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'c'))
      assert.is_true(file_util.writeFile(c_file, PKG_C), "c manifest")

      local raw_files = {}
      local manifest_tsv_files = {}
      local load_order, packages = manifest_info.resolveDependencies(badVal, raw_files, manifest_tsv_files, {}, { a_file, b_file, c_file })
      assert.same({}, log_messages)

      assert.is_not_nil(load_order, "load_order")
      assert.is_not_nil(packages, "packages")
      assert.same({"A", "B", "C"}, load_order)
      assert.is_not_nil(packages["A"], "A")
      assert.is_not_nil(packages["B"], "B")
      assert.is_not_nil(packages["C"], "C")
    end)

    it("should fail when a dependency is missing", function()
      local a_file = path_join(temp_dir, 'a', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'a'))
      assert.is_true(file_util.writeFile(a_file, PKG_A))
      local d_file = path_join(temp_dir, 'd', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'd'))
      assert.is_true(file_util.writeFile(d_file, PKG_D_MISSING_DEP))

      local raw_files = {}
      local manifest_tsv_files = {}
      local load_order = manifest_info.resolveDependencies(badVal, raw_files, manifest_tsv_files, {}, { a_file, d_file })
      assert.is_nil(load_order)
    end)

    it("should fail when version requirement is not satisfied", function()
      local a_file = path_join(temp_dir, 'a', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'a'))
      assert.is_true(file_util.writeFile(a_file, PKG_A))
      local e_file = path_join(temp_dir, 'e', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'e'))
      assert.is_true(file_util.writeFile(e_file, PKG_E_VERSION_MISMATCH))

      local raw_files = {}
      local manifest_tsv_files = {}
      local load_order = manifest_info.resolveDependencies(badVal, raw_files, manifest_tsv_files, {}, { a_file, e_file })
      assert.is_nil(load_order)
    end)

    it("should fail on circular dependencies", function()
      local f_file = path_join(temp_dir, 'f', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'f'))
      assert.is_true(file_util.writeFile(f_file, PKG_F_CIRCULAR))
      local g_file = path_join(temp_dir, 'g', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'g'))
      assert.is_true(file_util.writeFile(g_file, PKG_G_CIRCULAR))

      local raw_files = {}
      local manifest_tsv_files = {}
      local load_order = manifest_info.resolveDependencies(badVal, raw_files, manifest_tsv_files, {}, { f_file, g_file })
      assert.is_nil(load_order)
    end)

    it("should fail when packages reside in the same directory", function()
      -- Create two packages in the same directory
      local dir = path_join(temp_dir, 'same')
      lfs.mkdir(dir)
      local a_file = path_join(dir, MANIFEST_FILENAME)
      local subdir = path_join(dir, 'sub')
      lfs.mkdir(subdir)
      local b_file = path_join(subdir, MANIFEST_FILENAME)
      -- Use PKG_A but change the id for the second one
      local PKG_A2 = PKG_A:gsub("package_id:package_id\tA", "package_id:package_id\tA2")
                         :gsub("name:string\tThe A package", "name:string\tThe A2 package")
      assert.is_true(file_util.writeFile(a_file, PKG_A))
      assert.is_true(file_util.writeFile(b_file, PKG_A2))

      local raw_files = {}
      local manifest_tsv_files = {}
      local load_order = manifest_info.resolveDependencies(badVal, raw_files, manifest_tsv_files, {}, { a_file, b_file })
      assert.is_nil(load_order)
    end)

    it("should handle load_after with missing package gracefully", function()
      -- Package B has load_after A, but if A is not present, it should still work
      local b_file = path_join(temp_dir, 'b', MANIFEST_FILENAME)
      lfs.mkdir(path_join(temp_dir, 'b'))
      assert.is_true(file_util.writeFile(b_file, PKG_B))

      local raw_files = {}
      local manifest_tsv_files = {}
      local load_order, packages = manifest_info.resolveDependencies(badVal, raw_files, manifest_tsv_files, {}, { b_file })
      -- load_after is optional - should still resolve
      assert.is_not_nil(load_order)
      assert.is_not_nil(packages)
      assert.same({"B"}, load_order)
    end)

    it("should resolve an empty list of packages", function()
      local raw_files = {}
      local manifest_tsv_files = {}
      local load_order, packages = manifest_info.resolveDependencies(badVal, raw_files, manifest_tsv_files, {}, {})
      assert.is_not_nil(load_order)
      assert.is_not_nil(packages)
      assert.same({}, load_order)
    end)
  end)

  describe("versionSatisfies", function()
      -- Helper function to avoid repeating the same call structure
      local function check(op, req, installed)
          return manifest_info.versionSatisfies(op, req, installed)
      end

      describe("exact version match (= or ==)", function()
          it("should return true for identical versions", function()
              assert.is_true(check("=", "1.0.0", "1.0.0"))
              assert.is_true(check("==", "1.0.0", "1.0.0"))
          end)

          it("should return false for different versions", function()
              assert.is_false(check("=", "1.0.0", "1.0.1"))
              assert.is_false(check("==", "1.0.0", "1.1.0"))
          end)
      end)

      describe("greater than comparison (>)", function()
          it("should return true when installed version is higher", function()
              assert.is_true(check(">", "1.0.0", "1.0.1"))
              assert.is_true(check(">", "1.0.0", "1.1.0"))
              assert.is_true(check(">", "1.0.0", "2.0.0"))
          end)

          it("should return false when installed version is equal or lower", function()
              assert.is_false(check(">", "1.0.0", "1.0.0"))
              assert.is_false(check(">", "1.0.1", "1.0.0"))
              assert.is_false(check(">", "2.0.0", "1.9.9"))
          end)
      end)

      describe("greater than or equal comparison (>=)", function()
          it("should return true when installed version is higher or equal", function()
              assert.is_true(check(">=", "1.0.0", "1.0.0"))
              assert.is_true(check(">=", "1.0.0", "1.0.1"))
              assert.is_true(check(">=", "1.0.0", "2.0.0"))
          end)

          it("should return false when installed version is lower", function()
              assert.is_false(check(">=", "1.0.1", "1.0.0"))
              assert.is_false(check(">=", "2.0.0", "1.9.9"))
          end)
      end)

      describe("less than comparison (<)", function()
          it("should return true when installed version is lower", function()
              assert.is_true(check("<", "1.0.1", "1.0.0"))
              assert.is_true(check("<", "1.1.0", "1.0.9"))
              assert.is_true(check("<", "2.0.0", "1.9.9"))
          end)

          it("should return false when installed version is equal or higher", function()
              assert.is_false(check("<", "1.0.0", "1.0.0"))
              assert.is_false(check("<", "1.0.0", "1.0.1"))
              assert.is_false(check("<", "1.0.0", "2.0.0"))
          end)
      end)

      describe("less than or equal comparison (<=)", function()
          it("should return true when installed version is lower or equal", function()
              assert.is_true(check("<=", "1.0.0", "1.0.0"))
              assert.is_true(check("<=", "1.0.1", "1.0.0"))
              assert.is_true(check("<=", "2.0.0", "1.9.9"))
          end)

          it("should return false when installed version is higher", function()
              assert.is_false(check("<=", "1.0.0", "1.0.1"))
              assert.is_false(check("<=", "1.0.0", "2.0.0"))
          end)
      end)

      describe("tilde compatibility (~)", function()
          it("should allow patch-level changes", function()
              assert.is_true(check("~", "1.2.0", "1.2.3"))
              assert.is_true(check("~", "1.2.3", "1.2.4"))
              assert.is_true(check("~", "1.2.0", "1.2.0"))
          end)

          it("should not allow minor or major version changes", function()
              assert.is_false(check("~", "1.2.0", "1.3.0"))
              assert.is_false(check("~", "1.2.0", "2.2.0"))
              assert.is_false(check("~", "1.2.3", "1.3.0"))
          end)
      end)

      describe("caret compatibility (^)", function()
        it("should allow minor version increases when major > 0", function()
            -- Major versions match (1), and minor version of installed (3) >= required (2)
            assert.is_true(check("^", "1.2.3", "1.3.0"))
            -- Major versions match (1), and minor version of installed (2) = required (2)
            assert.is_true(check("^", "1.2.3", "1.2.3"))
        end)

        it("should not allow any changes when major version is 0", function()
            -- Only exact matches allowed for major version 0
            assert.is_true(check("^", "0.2.3", "0.2.3"))
            -- Even patch changes not allowed
            assert.is_false(check("^", "0.2.3", "0.2.4"))
            -- Minor changes not allowed
            assert.is_false(check("^", "0.2.3", "0.3.0"))
        end)

        it("should not allow major version changes", function()
            assert.is_false(check("^", "1.2.3", "2.0.0"))
            assert.is_false(check("^", "2.3.0", "3.0.0"))
        end)
      end)

      describe("error handling", function()
          it("should error on invalid operators", function()
              assert.has_error(function()
                  check("?", "1.0.0", "1.0.0")
              end, "Unsupported version comparison operator: ?")
          end)

          it("should handle semver objects as well as strings", function()
              local semver = require("semver")
              assert.is_true(check("=", semver("1.0.0"), "1.0.0"))
              assert.is_true(check("=", "1.0.0", semver("1.0.0")))
              assert.is_true(check("=", semver("1.0.0"), semver("1.0.0")))
          end)
      end)
    end)

    describe("type_aliases", function()
        it("should be supported", function()
            local a_file = path_join(temp_dir, 'x', MANIFEST_FILENAME)
            lfs.mkdir(path_join(temp_dir, 'x'))
            assert.is_true(file_util.writeFile(a_file, PKG_A), MANIFEST_FILENAME)
            local raw_files = {}
            local a = manifest_info.loadManifestFile(badVal, raw_files, {}, a_file)
            assert.is_not_nil(a, MANIFEST_FILENAME)
            assert.is_not_nil(a.type_aliases, "a.type_aliases")
            assert.is_not_nil(parsers.parseType(error_reporting.nullBadVal, 'pkg_a_type'), "pkg_a_type")
        end)
    end)

end)
