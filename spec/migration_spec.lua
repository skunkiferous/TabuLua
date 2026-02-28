-- migration_spec.lua

local busted = require("busted")
local assert = require("luassert")

local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local file_util = require("file_util")
local data_set = require("data_set")
local migration = require("migration")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local function writeTestFile(dir, fileName, content)
    local fullPath = path_join(dir, fileName)
    local parent = fullPath:match("^(.+)/")
    if parent then
        file_util.mkdir(parent)
    end
    assert(file_util.writeFile(fullPath, content))
end

local function readTestFile(dir, fileName)
    local fullPath = path_join(dir, fileName)
    return file_util.readFile(fullPath)
end

local function fileExists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

describe("migration", function()
    local temp_dir

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
        local td = path_join(system_temp, "lua_migration_test_" .. os.time())
        assert(lfs.mkdir(td))
        temp_dir = td
    end)

    after_each(function()
        if temp_dir then
            local td = temp_dir
            temp_dir = nil
            file_util.deleteTempDir(td)
        end
    end)

    ---------------------------------------------------------------------------
    -- Module API
    ---------------------------------------------------------------------------

    describe("module API", function()
        it("should return a version string", function()
            local version = migration.getVersion()
            assert.is_string(version)
            assert.matches("^%d+%.%d+%.%d+$", version)
        end)

        it("should have __tostring", function()
            local str = tostring(migration)
            assert.matches("^migration version", str)
        end)

        it("should be callable with 'version'", function()
            local version = migration("version")
            assert.is_not_nil(version)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Basic script execution
    ---------------------------------------------------------------------------

    describe("run", function()
        it("should execute a simple script", function()
            writeTestFile(temp_dir, "data/Items.tsv",
                "name:string\tvalue:number\nalpha\t1\nbeta\t2\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\tp3:string\tp4:string\tp5:string\n" ..
                "loadFile\tItems.tsv\n" ..
                "setCells\tItems.tsv\tvalue\t99\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_true(ok, err)
            -- Verify the file was modified
            local content = readTestFile(temp_dir, "data/Items.tsv")
            assert.matches("99", content)
        end)

        it("should handle comments and blank lines in scripts", function()
            writeTestFile(temp_dir, "data/Items.tsv",
                "name:string\tvalue:number\nalpha\t1\n")
            writeTestFile(temp_dir, "script.tsv",
                "# Migration script\n" ..
                "#\n" ..
                "command:string\tp1:string\tp2:string\tp3:string\n" ..
                "#\n" ..
                "# === Load ===\n" ..
                "#\n" ..
                "loadFile\tItems.tsv\n" ..
                "\n" ..
                "# === Modify ===\n" ..
                "setCell\tItems.tsv\talpha\tvalue\t42\n" ..
                "\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_true(ok, err)
            local content = readTestFile(temp_dir, "data/Items.tsv")
            assert.matches("42", content)
        end)

        it("should stop on first error", function()
            writeTestFile(temp_dir, "data/Items.tsv",
                "name:string\tvalue:number\nalpha\t1\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\tp3:string\n" ..
                "loadFile\tItems.tsv\n" ..
                "loadFile\tNonExistent.tsv\n" ..
                "setCells\tItems.tsv\tvalue\t99\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_nil(ok)
            assert.matches("step 2", err)
            assert.matches("NonExistent", err)
        end)

        it("should report step number in errors", function()
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\n" ..
                "loadFile\tMissing.tsv\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                temp_dir)
            assert.is_nil(ok)
            assert.matches("step 1", err)
        end)

        it("should error on unknown command", function()
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\n" ..
                "bogusCommand\ttest\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                temp_dir)
            assert.is_nil(ok)
            assert.matches("unknown command", err)
        end)

        it("should error on missing script file", function()
            local ok, err = migration.run(
                path_join(temp_dir, "nonexistent.tsv"),
                temp_dir)
            assert.is_nil(ok)
            assert.matches("failed to load", err)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Dry run
    ---------------------------------------------------------------------------

    describe("dryRun", function()
        it("should not modify files on disk", function()
            writeTestFile(temp_dir, "data/Items.tsv",
                "name:string\tvalue:number\nalpha\t1\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\tp3:string\n" ..
                "loadFile\tItems.tsv\n" ..
                "setCells\tItems.tsv\tvalue\t99\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"),
                {dryRun = true})
            assert.is_true(ok, err)
            -- File should NOT have been modified
            local content = readTestFile(temp_dir, "data/Items.tsv")
            assert.not_matches("99", content)
            assert.matches("1", content)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Verbose mode
    ---------------------------------------------------------------------------

    describe("verbose", function()
        it("should run with verbose option without error", function()
            writeTestFile(temp_dir, "data/Items.tsv",
                "name:string\nalpha\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\n" ..
                "loadFile\tItems.tsv\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"),
                {verbose = true})
            assert.is_true(ok, err)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Column operations via script
    ---------------------------------------------------------------------------

    describe("column commands", function()
        it("should add, rename, move, and change column type", function()
            writeTestFile(temp_dir, "data/Test.tsv",
                "name:string\tsuperType:type_spec\tformat:string\n" ..
                "alpha\tUnit\ttext\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\tp3:string\tp4:string\n" ..
                "loadFile\tTest.tsv\n" ..
                "renameColumn\tTest.tsv\tsuperType\tparent\n" ..
                "setColumnType\tTest.tsv\tparent\ttype_spec|nil\n" ..
                "moveColumn\tTest.tsv\tparent\tname\n" ..
                "addColumn\tTest.tsv\tdesc:text|nil\tparent\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_true(ok, err)
            -- Verify by reloading
            local ds = data_set.new(path_join(temp_dir, "data"))
            ds:loadFile("Test.tsv")
            local names = ds:getColumnNames("Test.tsv")
            assert.same({"name", "parent", "desc", "format"}, names)
            assert.are.equal("parent:type_spec|nil", ds:getColumnSpec("Test.tsv", "parent"))
        end)

        it("should remove a column", function()
            writeTestFile(temp_dir, "data/Test.tsv",
                "name:string\tobsolete:string\tvalue:number\nalpha\told\t1\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\n" ..
                "loadFile\tTest.tsv\n" ..
                "removeColumn\tTest.tsv\tobsolete\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_true(ok, err)
            local ds = data_set.new(path_join(temp_dir, "data"))
            ds:loadFile("Test.tsv")
            assert.is_false(ds:hasColumn("Test.tsv", "obsolete"))
        end)
    end)

    ---------------------------------------------------------------------------
    -- Cell commands via script
    ---------------------------------------------------------------------------

    describe("cell commands", function()
        it("should set individual cells", function()
            writeTestFile(temp_dir, "data/Test.tsv",
                "name:string\tvalue:number\nalpha\t1\nbeta\t2\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\tp3:string\tp4:string\n" ..
                "loadFile\tTest.tsv\n" ..
                "setCell\tTest.tsv\talpha\tvalue\t99\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_true(ok, err)
            local ds = data_set.new(path_join(temp_dir, "data"))
            ds:loadFile("Test.tsv")
            assert.are.equal("99", ds:getCell("Test.tsv", "alpha", "value"))
            assert.are.equal("2", ds:getCell("Test.tsv", "beta", "value"))
        end)

        it("should setCellsWhere conditionally", function()
            writeTestFile(temp_dir, "data/Test.tsv",
                "name:string\tsuperType:string\n" ..
                "alpha\tType\n" ..
                "beta\tCustom\n" ..
                "gamma\tType\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\tp3:string\tp4:string\tp5:string\n" ..
                "loadFile\tTest.tsv\n" ..
                "setCellsWhere\tTest.tsv\tsuperType\tCustomType\tsuperType\tType\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_true(ok, err)
            local ds = data_set.new(path_join(temp_dir, "data"))
            ds:loadFile("Test.tsv")
            assert.are.equal("CustomType", ds:getCell("Test.tsv", "alpha", "superType"))
            assert.are.equal("Custom", ds:getCell("Test.tsv", "beta", "superType"))
            assert.are.equal("CustomType", ds:getCell("Test.tsv", "gamma", "superType"))
        end)

        it("should transformCells with expression", function()
            writeTestFile(temp_dir, "data/Test.tsv",
                "name:string\tvalue:number\nalpha\t10\nbeta\t20\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\tp3:string\n" ..
                "loadFile\tTest.tsv\n" ..
                "transformCells\tTest.tsv\tvalue\ttostring(tonumber(value) * 2)\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_true(ok, err)
            local ds = data_set.new(path_join(temp_dir, "data"))
            ds:loadFile("Test.tsv")
            assert.are.equal("20", ds:getCell("Test.tsv", "alpha", "value"))
            assert.are.equal("40", ds:getCell("Test.tsv", "beta", "value"))
        end)
    end)

    ---------------------------------------------------------------------------
    -- Row commands via script
    ---------------------------------------------------------------------------

    describe("row commands", function()
        it("should add and remove rows", function()
            writeTestFile(temp_dir, "data/Test.tsv",
                "name:string\tvalue:number\nalpha\t1\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\n" ..
                "loadFile\tTest.tsv\n" ..
                "addRow\tTest.tsv\tbeta|2\n" ..
                "removeRow\tTest.tsv\talpha\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_true(ok, err)
            local ds = data_set.new(path_join(temp_dir, "data"))
            ds:loadFile("Test.tsv")
            assert.is_false(ds:hasRow("Test.tsv", "alpha"))
            assert.is_true(ds:hasRow("Test.tsv", "beta"))
            assert.are.equal("2", ds:getCell("Test.tsv", "beta", "value"))
        end)
    end)

    ---------------------------------------------------------------------------
    -- File commands via script
    ---------------------------------------------------------------------------

    describe("file commands", function()
        it("should rename files", function()
            writeTestFile(temp_dir, "data/Old.tsv",
                "name:string\nalpha\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\n" ..
                "loadFile\tOld.tsv\n" ..
                "renameFile\tOld.tsv\tNew.tsv\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_true(ok, err)
            assert.is_true(fileExists(path_join(temp_dir, "data/New.tsv")))
        end)

        it("should create files with pipe-delimited columns", function()
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\n" ..
                "createFile\tNew.tsv\tid:string|name:string|value:number\n" ..
                "addRow\tNew.tsv\ta1|Alice|100\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                temp_dir)
            assert.is_true(ok, err)
            local ds = data_set.new(temp_dir)
            ds:loadFile("New.tsv")
            assert.same({"id", "name", "value"}, ds:getColumnNames("New.tsv"))
            assert.are.equal("Alice", ds:getCell("New.tsv", "a1", "name"))
        end)
    end)

    ---------------------------------------------------------------------------
    -- Files.tsv helper commands via script
    ---------------------------------------------------------------------------

    describe("filesHelper commands", function()
        it("should update Files.tsv entries", function()
            writeTestFile(temp_dir, "data/Files.tsv",
                "fileName:string\ttypeName:type_spec\tsuperType:super_type\tloadOrder:number\n" ..
                "CustomType.tsv\tCustomType\ttype\t50\n" ..
                "Unit.tsv\tUnit\tCustomType\t100\n")
            writeTestFile(temp_dir, "data/CustomType.tsv",
                "name:string\nalpha\n")
            writeTestFile(temp_dir, "data/Unit.tsv",
                "name:string\nalpha\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\n" ..
                "loadFile\tFiles.tsv\n" ..
                "loadFile\tCustomType.tsv\n" ..
                "loadFile\tUnit.tsv\n" ..
                "filesUpdateSuperType\tCustomType.tsv\tcustom_type_def\n" ..
                "filesUpdateLoadOrder\tCustomType.tsv\t100\n" ..
                "filesUpdatePath\tUnit.tsv\tCustomType/Unit.tsv\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_true(ok, err)
            local ds = data_set.new(path_join(temp_dir, "data"))
            ds:loadFile("Files.tsv")
            assert.are.equal("custom_type_def",
                ds:getCell("Files.tsv", "CustomType.tsv", "superType"))
            assert.are.equal("100",
                ds:getCell("Files.tsv", "CustomType.tsv", "loadOrder"))
            -- After path update, the key changed
            assert.is_true(ds:hasRow("Files.tsv", "CustomType/Unit.tsv"))
        end)
    end)

    ---------------------------------------------------------------------------
    -- Control commands
    ---------------------------------------------------------------------------

    describe("control commands", function()
        it("should assert file is loaded", function()
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\n" ..
                "assert\tMissing.tsv\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                temp_dir)
            assert.is_nil(ok)
            assert.matches("assertion failed", err)
        end)

        it("should assert column exists", function()
            writeTestFile(temp_dir, "data/Test.tsv",
                "name:string\nalpha\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\n" ..
                "loadFile\tTest.tsv\n" ..
                "assertColumn\tTest.tsv\tmissing\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_nil(ok)
            assert.matches("assertion failed", err)
        end)

        it("should pass assert when file is loaded", function()
            writeTestFile(temp_dir, "data/Test.tsv",
                "name:string\nalpha\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\n" ..
                "loadFile\tTest.tsv\n" ..
                "assert\tTest.tsv\n" ..
                "assertColumn\tTest.tsv\tname\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_true(ok, err)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Comment/blank line commands
    ---------------------------------------------------------------------------

    describe("comment/blank commands", function()
        it("should add comments and blank lines", function()
            writeTestFile(temp_dir, "data/Test.tsv",
                "name:string\nalpha\nbeta\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\tp3:string\tp4:string\n" ..
                "loadFile\tTest.tsv\n" ..
                "addComment\tTest.tsv\tSection A\tafterHeader\n" ..
                "addBlankLine\tTest.tsv\tatEnd\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_true(ok, err)
            local content = readTestFile(temp_dir, "data/Test.tsv")
            assert.matches("# Section A", content)
        end)
    end)

    ---------------------------------------------------------------------------
    -- Command-line interface
    ---------------------------------------------------------------------------

    describe("CLI", function()
        -- Helper to run migration.lua as a subprocess
        local function runCLI(args)
            local cmd = "lua54 migration.lua " .. (args or "") .. " 2>&1"
            local h = io.popen(cmd, "r")
            local output = h:read("*a")
            local _, how, code = h:close()
            return output, (how == "exit") and code or -1
        end

        it("should show usage when called with no arguments", function()
            local output, code = runCLI("")
            assert.are.equal(1, code)
            assert.matches("Usage:", output)
            assert.matches("script%.tsv", output)
            assert.matches("rootDir", output)
            assert.matches("%-%-dry%-run", output)
        end)

        it("should error on unknown option", function()
            local output, code = runCLI("script.tsv /tmp --bogus")
            assert.are.equal(1, code)
            assert.matches("Unknown option", output)
        end)

        it("should error on missing rootDir", function()
            local output, code = runCLI("script.tsv")
            assert.are.equal(1, code)
            assert.matches("Missing", output)
        end)

        it("should error on missing script file", function()
            local output, code = runCLI("nonexistent.tsv " .. temp_dir)
            assert.are.equal(1, code)
            assert.matches("failed to load", output)
        end)

        it("should execute a migration script successfully", function()
            writeTestFile(temp_dir, "data/Items.tsv",
                "name:string\tvalue:number\nalpha\t1\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\tp3:string\n" ..
                "loadFile\tItems.tsv\n" ..
                "setCells\tItems.tsv\tvalue\t42\n" ..
                "saveAll\n")
            local scriptPath = path_join(temp_dir, "script.tsv")
            local dataDir = path_join(temp_dir, "data")
            local output, code = runCLI(scriptPath .. " " .. dataDir)
            assert.are.equal(0, code, "Expected exit 0, got: " .. tostring(code) .. "\n" .. output)
            assert.matches("completed successfully", output)
            -- Verify the file was actually modified
            local content = readTestFile(temp_dir, "data/Items.tsv")
            assert.matches("42", content)
        end)

        it("should support --dry-run flag", function()
            writeTestFile(temp_dir, "data/Items.tsv",
                "name:string\tvalue:number\nalpha\t1\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\tp2:string\tp3:string\n" ..
                "loadFile\tItems.tsv\n" ..
                "setCells\tItems.tsv\tvalue\t99\n" ..
                "saveAll\n")
            local scriptPath = path_join(temp_dir, "script.tsv")
            local dataDir = path_join(temp_dir, "data")
            local output, code = runCLI(scriptPath .. " " .. dataDir .. " --dry-run")
            assert.are.equal(0, code, "Expected exit 0, got: " .. tostring(code) .. "\n" .. output)
            -- File should NOT have been modified
            local content = readTestFile(temp_dir, "data/Items.tsv")
            assert.not_matches("99", content)
            assert.matches("1", content)
        end)

        it("should support --verbose flag", function()
            writeTestFile(temp_dir, "data/Items.tsv",
                "name:string\nalpha\n")
            writeTestFile(temp_dir, "script.tsv",
                "command:string\tp1:string\n" ..
                "loadFile\tItems.tsv\n" ..
                "saveAll\n")
            local scriptPath = path_join(temp_dir, "script.tsv")
            local dataDir = path_join(temp_dir, "data")
            local output, code = runCLI(scriptPath .. " " .. dataDir .. " --verbose")
            assert.are.equal(0, code, "Expected exit 0, got: " .. tostring(code) .. "\n" .. output)
            assert.matches("step 1", output)
            assert.matches("loadFile", output)
        end)
    end)

    ---------------------------------------------------------------------------
    -- End-to-end: multi-step migration
    ---------------------------------------------------------------------------

    describe("end-to-end", function()
        it("should handle a multi-step migration", function()
            -- Setup: two data files and a Files.tsv
            writeTestFile(temp_dir, "data/Files.tsv",
                "fileName:string\ttypeName:type_spec\tsuperType:super_type\tloadOrder:number\n" ..
                "CustomType.tsv\tCustomType\ttype\t50\n" ..
                "Unit.tsv\tUnit\tCustomType\t100\n")
            writeTestFile(temp_dir, "data/CustomType.tsv",
                "name:string\tsuperType:type_spec\tformat:string\tdescription:text\n" ..
                "number\t\tnumeric\tA numeric type\n" ..
                "text\t\tstring\tA text type\n")
            writeTestFile(temp_dir, "data/Unit.tsv",
                "name:string\tsymbol:string\n" ..
                "meter\tm\n" ..
                "kilogram\tkg\n")
            -- Migration script
            writeTestFile(temp_dir, "script.tsv",
                "# Multi-step migration test\n" ..
                "#\n" ..
                "command:string\tp1:string\tp2:string\tp3:string\tp4:string\tp5:string\n" ..
                "#\n" ..
                "# Load files\n" ..
                "loadFile\tCustomType.tsv\n" ..
                "loadFile\tUnit.tsv\n" ..
                "loadFile\tFiles.tsv\n" ..
                "#\n" ..
                "# Rename superType to parent in CustomType\n" ..
                "renameColumn\tCustomType.tsv\tsuperType\tparent\n" ..
                "setColumnType\tCustomType.tsv\tparent\ttype_spec|nil\n" ..
                "moveColumn\tCustomType.tsv\tparent\tname\n" ..
                "#\n" ..
                "# Add parent column to Unit\n" ..
                "addColumn\tUnit.tsv\tparent:type_spec|nil\tname\n" ..
                "setCells\tUnit.tsv\tparent\tnumber\n" ..
                "#\n" ..
                "# Rename Unit file\n" ..
                "renameFile\tUnit.tsv\tCustomType/Unit.tsv\n" ..
                "#\n" ..
                "# Update Files.tsv\n" ..
                "filesUpdateSuperType\tCustomType.tsv\tcustom_type_def\n" ..
                "filesUpdateLoadOrder\tCustomType.tsv\t100\n" ..
                "filesUpdatePath\tUnit.tsv\tCustomType/Unit.tsv\n" ..
                "#\n" ..
                "saveAll\n")
            local ok, err = migration.run(
                path_join(temp_dir, "script.tsv"),
                path_join(temp_dir, "data"))
            assert.is_true(ok, err)

            -- Verify CustomType.tsv
            local ds = data_set.new(path_join(temp_dir, "data"))
            ds:loadFile("CustomType.tsv")
            local ctCols = ds:getColumnNames("CustomType.tsv")
            assert.same({"name", "parent", "format", "description"}, ctCols)
            assert.are.equal("parent:type_spec|nil",
                ds:getColumnSpec("CustomType.tsv", "parent"))

            -- Verify Unit.tsv was moved
            assert.is_true(fileExists(path_join(temp_dir, "data/CustomType/Unit.tsv")))
            ds:loadFile("CustomType/Unit.tsv")
            assert.same({"name", "parent", "symbol"},
                ds:getColumnNames("CustomType/Unit.tsv"))
            assert.are.equal("number",
                ds:getCell("CustomType/Unit.tsv", "meter", "parent"))

            -- Verify Files.tsv
            ds:loadFile("Files.tsv")
            assert.are.equal("custom_type_def",
                ds:getCell("Files.tsv", "CustomType.tsv", "superType"))
            assert.are.equal("100",
                ds:getCell("Files.tsv", "CustomType.tsv", "loadOrder"))
            assert.is_true(ds:hasRow("Files.tsv", "CustomType/Unit.tsv"))
        end)
    end)
end)
