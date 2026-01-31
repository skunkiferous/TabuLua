-- file_joining_spec.lua
-- Tests for file joining functionality

local busted = require("busted")
local assert = require("luassert")

-- Import busted functions
local describe = busted.describe
local it = busted.it

local file_joining = require("file_joining")
local error_reporting = require("error_reporting")

local badValGen = error_reporting.badValGen

-- Helper to create mock TSV row cell
local function cell(value)
    return { parsed = value, value = tostring(value), reformatted = tostring(value) }
end

-- Helper to create mock TSV data
local function createTsv(columns, rows)
    local header = {}
    for i, col in ipairs(columns) do
        header[i] = { name = col.name, type = col.type or "string", idx = i }
    end
    header.__source = "test.tsv"

    local result = { header }
    for _, row in ipairs(rows) do
        local dataRow = {}
        for i, val in ipairs(row) do
            dataRow[i] = cell(val)
        end
        result[#result + 1] = dataRow
    end
    return result
end

describe("file_joining", function()

    describe("getVersion", function()
        it("should return the module version as a string", function()
            local version = file_joining.getVersion()
            assert.is_string(version)
            assert.matches("^%d+%.%d+%.%d+", version)
        end)
    end)

    describe("module metadata", function()
        it("should have a tostring representation", function()
            local str = tostring(file_joining)
            assert.is_string(str)
            assert.matches("file_joining", str)
            assert.matches("version", str)
        end)

        it("should be callable with 'version' operation", function()
            local version = file_joining("version")
            assert.is_not_nil(version)
        end)

        it("should error on unknown operation", function()
            assert.has_error(function()
                file_joining("unknownOperation")
            end)
        end)
    end)

    describe("getDefaultJoinColumn", function()
        it("should return the first column name", function()
            local tsv = createTsv(
                { { name = "id" }, { name = "value" } },
                { { "row1", 100 } }
            )
            local result = file_joining.getDefaultJoinColumn(tsv)
            assert.equals("id", result)
        end)

        it("should return nil for empty TSV", function()
            local tsv = { {} }
            local result = file_joining.getDefaultJoinColumn(tsv)
            assert.is_nil(result)
        end)
    end)

    describe("buildJoinIndex", function()
        it("should build an index by the specified column", function()
            local tsv = createTsv(
                { { name = "id" }, { name = "name" }, { name = "value" } },
                {
                    { "item1", "First", 100 },
                    { "item2", "Second", 200 },
                    { "item3", "Third", 300 },
                }
            )

            local index, err = file_joining.buildJoinIndex(tsv, "id")
            assert.is_nil(err)
            assert.is_not_nil(index)
            assert.equals("First", index["item1"][2].parsed)
            assert.equals("Second", index["item2"][2].parsed)
            assert.equals("Third", index["item3"][2].parsed)
        end)

        it("should return error if column not found", function()
            local tsv = createTsv(
                { { name = "id" }, { name = "value" } },
                { { "row1", 100 } }
            )

            local index, err = file_joining.buildJoinIndex(tsv, "nonexistent")
            assert.is_nil(index)
            assert.is_not_nil(err)
            assert.matches("not found", err)
        end)
    end)

    describe("detectColumnConflicts", function()
        it("should return nil when no conflicts exist", function()
            local primary = {
                { name = "id" },
                { name = "name" },
            }
            local secondary = {
                { name = "id" },
                { name = "description" },
            }

            local conflicts = file_joining.detectColumnConflicts(primary, secondary, "id")
            assert.is_nil(conflicts)
        end)

        it("should detect column conflicts", function()
            local primary = {
                { name = "id" },
                { name = "name" },
                { name = "value" },
            }
            local secondary = {
                { name = "id" },
                { name = "name" },  -- Conflict!
                { name = "description" },
            }

            local conflicts = file_joining.detectColumnConflicts(primary, secondary, "id")
            assert.is_not_nil(conflicts)
            assert.equals(1, #conflicts)
            assert.equals("name", conflicts[1])
        end)
    end)

    describe("shouldExport", function()
        it("should return true for files without joinInto", function()
            local joinMeta = {
                lcFn2JoinInto = {},
                lcFn2Export = {},
            }
            assert.is_true(file_joining.shouldExport("items.tsv", joinMeta))
        end)

        it("should return false for files with joinInto (default)", function()
            local joinMeta = {
                lcFn2JoinInto = { ["items.en.tsv"] = "items.tsv" },
                lcFn2Export = {},
            }
            assert.is_false(file_joining.shouldExport("items.en.tsv", joinMeta))
        end)

        it("should respect explicit export=true for secondary files", function()
            local joinMeta = {
                lcFn2JoinInto = { ["items.en.tsv"] = "items.tsv" },
                lcFn2Export = { ["items.en.tsv"] = true },
            }
            assert.is_true(file_joining.shouldExport("items.en.tsv", joinMeta))
        end)

        it("should respect explicit export=false for primary files", function()
            local joinMeta = {
                lcFn2JoinInto = {},
                lcFn2Export = { ["debug.tsv"] = false },
            }
            assert.is_false(file_joining.shouldExport("debug.tsv", joinMeta))
        end)
    end)

    describe("groupSecondaryFiles", function()
        it("should group secondary files by primary target", function()
            local joinMeta = {
                lcFn2JoinInto = {
                    ["items.en.tsv"] = "items.tsv",
                    ["items.de.tsv"] = "items.tsv",
                    ["enemies.drops.tsv"] = "enemies.tsv",
                },
            }

            local groups = file_joining.groupSecondaryFiles(joinMeta)
            assert.is_not_nil(groups["items.tsv"])
            assert.equals(2, #groups["items.tsv"])
            assert.is_not_nil(groups["enemies.tsv"])
            assert.equals(1, #groups["enemies.tsv"])
        end)

        it("should return empty table when no joins exist", function()
            local joinMeta = {
                lcFn2JoinInto = {},
            }

            local groups = file_joining.groupSecondaryFiles(joinMeta)
            assert.same({}, groups)
        end)
    end)

    describe("joinFiles", function()
        it("should perform a basic join", function()
            local primary = createTsv(
                { { name = "id" }, { name = "value" } },
                {
                    { "item1", 100 },
                    { "item2", 200 },
                }
            )

            local secondary = createTsv(
                { { name = "id" }, { name = "description" } },
                {
                    { "item1", "First item" },
                    { "item2", "Second item" },
                }
            )
            secondary[1].__source = "secondary.tsv"

            local badVal = badValGen()
            local joinedRows, joinedHeader = file_joining.joinFiles(
                primary,
                {
                    { tsv = secondary, joinColumn = "id", sourceName = "secondary.tsv" }
                },
                badVal
            )

            assert.equals(0, badVal.errors)
            assert.is_not_nil(joinedRows)
            assert.is_not_nil(joinedHeader)
            assert.equals(2, #joinedRows)
            assert.equals(3, #joinedHeader)  -- id, value, description

            -- Check merged data
            assert.equals("item1", joinedRows[1][1].parsed)
            assert.equals(100, joinedRows[1][2].parsed)
            assert.equals("First item", joinedRows[1][3].parsed)
        end)

        it("should handle missing rows in secondary file", function()
            local primary = createTsv(
                { { name = "id" }, { name = "value" } },
                {
                    { "item1", 100 },
                    { "item2", 200 },
                    { "item3", 300 },  -- No match in secondary
                }
            )

            local secondary = createTsv(
                { { name = "id" }, { name = "description" } },
                {
                    { "item1", "First item" },
                    { "item2", "Second item" },
                    -- item3 is missing
                }
            )
            secondary[1].__source = "secondary.tsv"

            local badVal = badValGen()
            local joinedRows, joinedHeader = file_joining.joinFiles(
                primary,
                {
                    { tsv = secondary, joinColumn = "id", sourceName = "secondary.tsv" }
                },
                badVal
            )

            assert.equals(0, badVal.errors)
            assert.is_not_nil(joinedRows)
            assert.equals(3, #joinedRows)

            -- item3 should have nil for description
            assert.equals("item3", joinedRows[3][1].parsed)
            assert.is_nil(joinedRows[3][3].parsed)
        end)

        it("should report unmatched rows in secondary file as errors", function()
            local primary = createTsv(
                { { name = "id" }, { name = "value" } },
                {
                    { "item1", 100 },
                }
            )

            local secondary = createTsv(
                { { name = "id" }, { name = "description" } },
                {
                    { "item1", "First item" },
                    { "item_orphan", "Orphan item" },  -- No match in primary
                }
            )
            secondary[1].__source = "secondary.tsv"

            local badVal = badValGen()
            file_joining.joinFiles(
                primary,
                {
                    { tsv = secondary, joinColumn = "id", sourceName = "secondary.tsv" }
                },
                badVal
            )

            assert.is_true(badVal.errors > 0)
        end)

        it("should detect column conflicts", function()
            local primary = createTsv(
                { { name = "id" }, { name = "name" } },
                {
                    { "item1", "Primary Name" },
                }
            )

            local secondary = createTsv(
                { { name = "id" }, { name = "name" } },  -- Conflict with primary
                {
                    { "item1", "Secondary Name" },
                }
            )
            secondary[1].__source = "secondary.tsv"

            local badVal = badValGen()
            local joinedRows, joinedHeader = file_joining.joinFiles(
                primary,
                {
                    { tsv = secondary, joinColumn = "id", sourceName = "secondary.tsv" }
                },
                badVal
            )

            assert.is_nil(joinedRows)
            assert.is_nil(joinedHeader)
            assert.is_true(badVal.errors > 0)
        end)

        it("should join multiple secondary files", function()
            local primary = createTsv(
                { { name = "id" }, { name = "value" } },
                {
                    { "item1", 100 },
                }
            )

            local secondary1 = createTsv(
                { { name = "id" }, { name = "desc_en" } },
                {
                    { "item1", "English description" },
                }
            )
            secondary1[1].__source = "secondary1.tsv"

            local secondary2 = createTsv(
                { { name = "id" }, { name = "desc_de" } },
                {
                    { "item1", "German description" },
                }
            )
            secondary2[1].__source = "secondary2.tsv"

            local badVal = badValGen()
            local joinedRows, joinedHeader = file_joining.joinFiles(
                primary,
                {
                    { tsv = secondary1, joinColumn = "id", sourceName = "secondary1.tsv" },
                    { tsv = secondary2, joinColumn = "id", sourceName = "secondary2.tsv" },
                },
                badVal
            )

            assert.equals(0, badVal.errors)
            assert.is_not_nil(joinedRows)
            assert.equals(4, #joinedHeader)  -- id, value, desc_en, desc_de
            assert.equals("English description", joinedRows[1][3].parsed)
            assert.equals("German description", joinedRows[1][4].parsed)
        end)

        it("should require same join column for all secondary files", function()
            local primary = createTsv(
                { { name = "id" }, { name = "value" } },
                {
                    { "item1", 100 },
                }
            )

            local secondary1 = createTsv(
                { { name = "id" }, { name = "desc" } },
                {
                    { "item1", "Desc" },
                }
            )
            secondary1[1].__source = "secondary1.tsv"

            local secondary2 = createTsv(
                { { name = "name" }, { name = "other" } },  -- Different join column
                {
                    { "item1", "Other" },
                }
            )
            secondary2[1].__source = "secondary2.tsv"

            local badVal = badValGen()
            local joinedRows, joinedHeader = file_joining.joinFiles(
                primary,
                {
                    { tsv = secondary1, joinColumn = "id", sourceName = "secondary1.tsv" },
                    { tsv = secondary2, joinColumn = "name", sourceName = "secondary2.tsv" },
                },
                badVal
            )

            assert.is_nil(joinedRows)
            assert.is_nil(joinedHeader)
            assert.is_true(badVal.errors > 0)
        end)
    end)

    describe("findFilePath", function()
        it("should find file path by lowercase filename", function()
            local tsv_files = {
                ["c:/data/Items.tsv"] = {},
                ["c:/data/Enemies.tsv"] = {},
            }

            local path = file_joining.findFilePath("items.tsv", tsv_files)
            assert.equals("c:/data/Items.tsv", path)
        end)

        it("should return nil if file not found", function()
            local tsv_files = {
                ["c:/data/Items.tsv"] = {},
            }

            local path = file_joining.findFilePath("notfound.tsv", tsv_files)
            assert.is_nil(path)
        end)
    end)
end)
