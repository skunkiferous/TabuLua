-- export_tester_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

local lfs = require("lfs")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local export_tester = require("export_tester")
local file_util = require("file_util")
local exporter = require("exporter")

-- Simple path join function
local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

describe("export_tester", function()
    local temp_dir
    local source_dir
    local export_dir

    -- Setup: Create temporary directories for testing
    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
        local base_dir = path_join(system_temp, "lua_export_tester_test_" .. os.time())
        assert(lfs.mkdir(base_dir))
        temp_dir = base_dir

        source_dir = path_join(base_dir, "source")
        assert(lfs.mkdir(source_dir))

        export_dir = path_join(base_dir, "exported")
        assert(lfs.mkdir(export_dir))
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
            local version = export_tester.getVersion()
            assert.is_string(version)
            assert.is_truthy(version:match("%d+%.%d+%.%d+"))
        end)
    end)

    describe("validateImport", function()
        it("should return true for matching data", function()
            local imported = {{"id", "value"}, {"item1", 42}}
            local expected = {{"id", "value"}, {"item1", 42}}
            local formatConfig = {tolerant = false}

            local valid, err = export_tester.validateImport(imported, expected, formatConfig, "test.json")
            assert.is_true(valid)
            assert.is_nil(err)
        end)

        it("should return false for nil imported data", function()
            local expected = {{"id", "value"}}
            local formatConfig = {tolerant = false}

            local valid, err = export_tester.validateImport(nil, expected, formatConfig, "test.json")
            assert.is_false(valid)
            assert.is_not_nil(err)
            assert.matches("Import returned nil", err)
        end)

        it("should return false for row count mismatch", function()
            local imported = {{"id", "value"}}
            local expected = {{"id", "value"}, {"item1", 42}}
            local formatConfig = {tolerant = false}

            local valid, err = export_tester.validateImport(imported, expected, formatConfig, "test.json")
            assert.is_false(valid)
            assert.is_not_nil(err)
            assert.matches("Row count mismatch", err)
        end)

        it("should return false for value mismatch", function()
            local imported = {{"id", "value"}, {"item1", 99}}
            local expected = {{"id", "value"}, {"item1", 42}}
            local formatConfig = {tolerant = false}

            local valid, err = export_tester.validateImport(imported, expected, formatConfig, "test.json")
            assert.is_false(valid)
            assert.is_not_nil(err)
        end)

        it("should use tolerant comparison when formatConfig.tolerant is true", function()
            -- In tolerant mode, integers and floats are considered equal
            local imported = {{"value"}, {42.0}}
            local expected = {{"value"}, {42}}
            local formatConfig = {tolerant = true}

            local valid, err = export_tester.validateImport(imported, expected, formatConfig, "test.json")
            assert.is_true(valid)
            assert.is_nil(err)
        end)
    end)

    describe("testExportedFile", function()
        it("should return true for valid exported file", function()
            -- Create a simple Lua export file
            local lua_dir = path_join(export_dir, "lua-lua")
            assert(lfs.mkdir(lua_dir))
            local file_path = path_join(lua_dir, "Test.lua")
            file_util.writeFile(file_path, 'return {\n{"id","value"},\n{"item1",42}\n}')

            local expected = {{"id", "value"}, {"item1", 42}}
            local formatConfig = {extension = ".lua", dataFormat = nil, tolerant = false}

            local success, err = export_tester.testExportedFile(file_path, expected, formatConfig, false)
            assert.is_true(success)
            assert.is_nil(err)
        end)

        it("should return false for import failure", function()
            local file_path = path_join(temp_dir, "nonexistent.lua")
            local expected = {{"id", "value"}}
            local formatConfig = {extension = ".lua", dataFormat = nil, tolerant = false}

            local success, err = export_tester.testExportedFile(file_path, expected, formatConfig, false)
            assert.is_false(success)
            assert.is_not_nil(err)
            assert.matches("Import failed", err)
        end)

        it("should return false for validation failure", function()
            local lua_dir = path_join(export_dir, "lua-lua")
            assert(lfs.mkdir(lua_dir))
            local file_path = path_join(lua_dir, "Test.lua")
            file_util.writeFile(file_path, 'return {\n{"id","value"},\n{"item1",99}\n}')

            local expected = {{"id", "value"}, {"item1", 42}}
            local formatConfig = {extension = ".lua", dataFormat = nil, tolerant = false}

            local success, err = export_tester.testExportedFile(file_path, expected, formatConfig, false)
            assert.is_false(success)
            assert.is_not_nil(err)
            assert.matches("Validation failed", err)
        end)
    end)

    describe("testFormatDirectory", function()
        it("should test all files in a format directory", function()
            -- Create a format directory with exported files
            local lua_dir = path_join(export_dir, "lua-lua")
            assert(lfs.mkdir(lua_dir))

            -- Create test files
            file_util.writeFile(
                path_join(lua_dir, "Test1.lua"),
                'return {\n{"id","value"},\n{"item1",42}\n}'
            )
            file_util.writeFile(
                path_join(lua_dir, "Test2.lua"),
                'return {\n{"name"},\n{"test"}\n}'
            )

            local sourceData = {
                Test1 = {{"id", "value"}, {"item1", 42}},
                Test2 = {{"name"}, {"test"}},
            }
            local formatConfig = {extension = ".lua", dataFormat = nil, tolerant = false}

            local tested, passed, errors = export_tester.testFormatDirectory(
                lua_dir, formatConfig, sourceData, false
            )
            assert.equals(2, tested)
            assert.equals(2, passed)
            assert.equals(0, #errors)
        end)

        it("should report failures for invalid files", function()
            local lua_dir = path_join(export_dir, "lua-lua")
            assert(lfs.mkdir(lua_dir))

            -- Create a file with wrong data
            file_util.writeFile(
                path_join(lua_dir, "Test1.lua"),
                'return {\n{"id","value"},\n{"item1",99}\n}'  -- Wrong value
            )

            local sourceData = {
                Test1 = {{"id", "value"}, {"item1", 42}},
            }
            local formatConfig = {extension = ".lua", dataFormat = nil, tolerant = false}

            local tested, passed, errors = export_tester.testFormatDirectory(
                lua_dir, formatConfig, sourceData, false
            )
            assert.equals(1, tested)
            assert.equals(0, passed)
            assert.equals(1, #errors)
        end)

        it("should skip files without source data", function()
            local lua_dir = path_join(export_dir, "lua-lua")
            assert(lfs.mkdir(lua_dir))

            file_util.writeFile(
                path_join(lua_dir, "Unknown.lua"),
                'return {{"id"},{"test"}}'
            )

            local sourceData = {}  -- No source data for Unknown
            local formatConfig = {extension = ".lua", dataFormat = nil, tolerant = false}

            local tested, passed, errors = export_tester.testFormatDirectory(
                lua_dir, formatConfig, sourceData, false
            )
            assert.equals(0, tested)  -- Skipped
            assert.equals(0, passed)
            assert.equals(0, #errors)
        end)
    end)

    describe("runTests", function()
        it("should return false for empty source directories", function()
            local success, _stats = export_tester.runTests({}, export_dir, nil, false)
            assert.is_false(success)
        end)

        it("should return false for non-existent export directory", function()
            -- Create a minimal source TSV
            file_util.writeFile(
                path_join(source_dir, "Test.tsv"),
                "id:string\tvalue:int\nitem1\t42"
            )

            local success, _stats = export_tester.runTests(
                {source_dir},
                path_join(temp_dir, "nonexistent"),
                nil,
                false
            )
            assert.is_false(success)
        end)

        it("should test exported files and return results", function()
            -- Create source TSV file
            file_util.writeFile(
                path_join(source_dir, "Test.tsv"),
                "id:string\tvalue:integer\nitem1\t42"
            )

            -- Create process_files structure with relative path (like exporter expects)
            -- This mimics what mod_loader produces but with a relative filename
            local header = {
                {name = "id", type = "string", idx = 1, parsed = "id:string"},
                {name = "value", type = "integer", idx = 2, parsed = "value:integer"},
            }
            header.__source = "Test.tsv"
            header.__dataset = {}

            local row1 = {
                {parsed = "item1"},
                {parsed = 42},
            }

            local tsv = {header, row1}
            header.__dataset = tsv

            for _, col in ipairs(header) do
                col.header = header
            end

            local process_files = {
                tsv_files = {
                    ["Test.tsv"] = tsv,
                },
                raw_files = {
                    ["Test.tsv"] = "id:string\tvalue:integer\nitem1\t42",
                },
            }

            -- Export to lua-lua format
            local exportParams = {
                exportDir = export_dir,
                formatSubdir = "lua-lua",
            }
            local export_success = exporter.exportLua(process_files, exportParams)
            assert.is_true(export_success)

            -- Run the tester
            local success, stats = export_tester.runTests(
                {source_dir},
                export_dir,
                {"lua-lua"},
                false
            )
            assert.is_true(success)
            assert.equals(0, stats.totalFailed)
        end)
    end)

    describe("module API", function()
        it("should have a tostring representation", function()
            local str = tostring(export_tester)
            assert.is_string(str)
            assert.matches("^export_tester version %d+%.%d+%.%d+$", str)
        end)

        it("should support callable API", function()
            local version = export_tester("version")
            assert.is_not_nil(version)
        end)

        it("should error on unknown operation", function()
            assert.has_error(function()
                export_tester("nonexistent")
            end, "Unknown operation: nonexistent")
        end)
    end)
end)
