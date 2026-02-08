-- exporter_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

local lfs = require("lfs")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local exporter = require("exporter")
local file_util = require("file_util")

-- Simple path join function
local function path_join(...)
  return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- Helper to create a minimal TSV structure for testing
local function createTestTSV(source_name)
    -- Create a header row with column metadata
    local header = {
        {name = "id", type = "string", idx = 1, parsed = "id"},
        {name = "value", type = "integer", idx = 2, parsed = "value"},
    }
    header.__source = source_name
    header.__dataset = {}  -- Reference to the full dataset

    -- Create a data row
    local row1 = {
        {parsed = "item1"},
        {parsed = 42},
    }

    local row2 = {
        {parsed = "item2"},
        {parsed = 100},
    }

    local tsv = {header, row1, row2}
    header.__dataset = tsv

    -- Set header reference on columns
    for _, col in ipairs(header) do
        col.header = header
    end

    return tsv
end

-- Helper to create a TSV structure with exploded columns for testing
local function createExplodedTestTSV(source_name)
    -- Create a header row with exploded column metadata
    -- Simulating: id:integer, location.level:string, location.position._1:integer, location.position._2:integer
    local header = {
        {name = "id", type = "integer", idx = 1, parsed = "id", is_exploded = false},
        {name = "location.level", type = "string", idx = 2, parsed = "location.level",
         is_exploded = true, exploded_path = {"location", "level"}},
        {name = "location.position._1", type = "integer", idx = 3, parsed = "location.position._1",
         is_exploded = true, exploded_path = {"location", "position", "_1"}},
        {name = "location.position._2", type = "integer", idx = 4, parsed = "location.position._2",
         is_exploded = true, exploded_path = {"location", "position", "_2"}},
    }
    header.__source = source_name
    header.__dataset = {}  -- Reference to the full dataset

    -- Create data rows
    local row1 = {
        {parsed = 1},
        {parsed = "starter"},
        {parsed = 10},
        {parsed = 20},
    }

    local row2 = {
        {parsed = 2},
        {parsed = "advanced"},
        {parsed = 30},
        {parsed = 40},
    }

    local tsv = {header, row1, row2}
    header.__dataset = tsv

    -- Set header reference on columns
    for _, col in ipairs(header) do
        col.header = header
    end

    -- Build exploded_map structure (mimicking what analyzeExplodedColumns produces)
    local exploded_map = {
        location = {
            type = "record",
            type_spec = "{level:string,position:{integer,integer}}",
            fields = {
                level = { type = "leaf", col_idx = 2, type_spec = "string" },
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

    -- Set metatable with __index to make __exploded_map accessible
    -- (mimicking how readOnly proxy makes opt_index keys accessible)
    setmetatable(header, {
        __index = function(t, k)
            if k == "__exploded_map" then
                return exploded_map
            end
            return rawget(t, k)
        end
    })

    return tsv
end

-- Helper to create process_files structure
local function createProcessFiles(temp_dir)
    local test_file = "test.tsv"
    local tsv = createTestTSV(path_join(temp_dir, test_file))

    return {
        tsv_files = {
            [test_file] = tsv,
        },
        raw_files = {
            [test_file] = "id\tvalue\nitem1\t42\nitem2\t100",
        },
    }
end

-- Helper to create process_files structure with exploded columns
local function createExplodedProcessFiles(temp_dir)
    local test_file = "exploded_test.tsv"
    local tsv = createExplodedTestTSV(path_join(temp_dir, test_file))

    return {
        tsv_files = {
            [test_file] = tsv,
        },
        raw_files = {
            [test_file] = "id:integer\tlocation.level:string\tlocation.position._1:integer\tlocation.position._2:integer\n1\tstarter\t10\t20\n2\tadvanced\t30\t40",
        },
    }
end

describe("exporter", function()
    local temp_dir

    -- Setup: Create a temporary directory for testing
    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
        local td = path_join(system_temp, "lua_exporter_test_" .. os.time())
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
            local version = exporter.getVersion()
            assert.is_string(version)
            assert.is_truthy(version:match("%d+%.%d+%.%d+"))
        end)
    end)

    describe("module API", function()
        it("should have a tostring representation", function()
            local str = tostring(exporter)
            assert.is_string(str)
            assert.is_truthy(str:match("exporter"))
            assert.is_truthy(str:match("version"))
        end)

        it("should support call syntax for version", function()
            local version = exporter("version")
            assert.is_not_nil(version)
        end)

        it("should error for unknown operations", function()
            assert.has_error(function()
                exporter("unknownOperation")
            end)
        end)
    end)

    describe("exportLuaTSV", function()
        it("should export files in Lua TSV format", function()
            local process_files = createProcessFiles(temp_dir)
            local exportParams = {
                exportDir = temp_dir,
            }

            local success = exporter.exportLuaTSV(process_files, exportParams)
            assert.is_true(success)

            -- Check the exported file exists
            local exported_file = path_join(temp_dir, "test.tsv")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content)
            -- Should contain Lua literals
            assert.is_truthy(content:match('"id"'))
            assert.is_truthy(content:match('"item1"'))
            assert.is_truthy(content:match("42"))
        end)
    end)

    describe("exportJSONTSV", function()
        it("should export files in JSON TSV format", function()
            local process_files = createProcessFiles(temp_dir)
            local exportParams = {
                exportDir = temp_dir,
            }

            local success = exporter.exportJSONTSV(process_files, exportParams)
            assert.is_true(success)

            local exported_file = path_join(temp_dir, "test.tsv")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content)
            -- Should contain JSON literals
            assert.is_truthy(content:match('"id"'))
            assert.is_truthy(content:match('"item1"'))
        end)
    end)

    describe("exportJSON", function()
        it("should export files in typed JSON format", function()
            local process_files = createProcessFiles(temp_dir)
            local exportParams = {
                exportDir = temp_dir,
            }

            local success = exporter.exportJSON(process_files, exportParams)
            assert.is_true(success)

            -- JSON export changes extension to .json
            local exported_file = path_join(temp_dir, "test.json")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content)
            -- Should be valid JSON array format
            assert.is_truthy(content:match("^%["))
            assert.is_truthy(content:match("%]$"))
            -- Typed JSON wraps integers as {"int":"N"}
            assert.is_truthy(content:match('{"int":"42"}'))
        end)
    end)

    describe("exportNaturalJSONTSV", function()
        it("should export files in Natural JSON TSV format", function()
            local process_files = createProcessFiles(temp_dir)
            local exportParams = {
                exportDir = temp_dir,
            }

            local success = exporter.exportNaturalJSONTSV(process_files, exportParams)
            assert.is_true(success)

            local exported_file = path_join(temp_dir, "test.tsv")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content)
            -- Should contain natural JSON literals (plain numbers, not wrapped)
            assert.is_truthy(content:match('"id"'))
            assert.is_truthy(content:match('"item1"'))
            -- Natural JSON has plain integers, not wrapped
            assert.is_truthy(content:match('\t42\t') or content:match('\t42\n') or content:match('\t42$'))
        end)
    end)

    describe("exportNaturalJSON", function()
        it("should export files in natural JSON format", function()
            local process_files = createProcessFiles(temp_dir)
            local exportParams = {
                exportDir = temp_dir,
            }

            local success = exporter.exportNaturalJSON(process_files, exportParams)
            assert.is_true(success)

            -- JSON export changes extension to .json
            local exported_file = path_join(temp_dir, "test.json")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content)
            -- Should be valid JSON array format
            assert.is_truthy(content:match("^%["))
            assert.is_truthy(content:match("%]$"))
            -- Natural JSON has plain integers, not wrapped as {"int":"N"}
            assert.is_truthy(content:match(',42,') or content:match('%[42,') or content:match(',42%]'))
            assert.is_falsy(content:match('{"int":'))
        end)
    end)

    describe("exportLua", function()
        it("should export files in Lua format", function()
            local process_files = createProcessFiles(temp_dir)
            local exportParams = {
                exportDir = temp_dir,
            }

            local success = exporter.exportLua(process_files, exportParams)
            assert.is_true(success)

            -- Lua export changes extension to .lua
            local exported_file = path_join(temp_dir, "test.lua")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content)
            -- Should be valid Lua table format
            assert.is_truthy(content:match("^return {"))
            assert.is_truthy(content:match("}$"))
        end)
    end)

    describe("exportSQL", function()
        it("should export files in SQL format", function()
            local process_files = createProcessFiles(temp_dir)
            local exportParams = {
                exportDir = temp_dir,
            }

            local success = exporter.exportSQL(process_files, exportParams)
            assert.is_true(success)

            -- SQL export changes extension to .sql
            local exported_file = path_join(temp_dir, "test.sql")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content)
            -- Should contain CREATE TABLE statement
            assert.is_truthy(content:match("CREATE TABLE"))
        end)

        it("should map union of basic types to TEXT column", function()
            -- Union of basic types (integer|string) should become TEXT
            local header = {
                {name = "id", type = "string", idx = 1, parsed = "id"},
                {name = "reward", type = "integer|string", idx = 2, parsed = "reward"},
            }
            header.__source = path_join(temp_dir, "union_test.tsv")
            header.__dataset = {}
            for _, col in ipairs(header) do col.header = header end

            local row1 = {{parsed = "quest1"}, {parsed = 100}}
            local row2 = {{parsed = "quest2"}, {parsed = "gold_ring"}}
            local tsv = {header, row1, row2}
            header.__dataset = tsv

            local process_files = {
                tsv_files = {["union_test.tsv"] = tsv},
                raw_files = {["union_test.tsv"] = "id:string\treward:integer|string\nquest1\t100\nquest2\tgold_ring"},
            }
            local exportParams = { exportDir = temp_dir }

            local success = exporter.exportSQL(process_files, exportParams)
            assert.is_true(success)

            local content = file_util.readFile(path_join(temp_dir, "union_test.sql"))
            assert.is_not_nil(content)
            -- reward column should be TEXT NOT NULL (union of basic types, not optional)
            assert.is_truthy(content:match('"reward" TEXT NOT NULL'))
        end)

        it("should map optional union of basic types to TEXT column without NOT NULL", function()
            -- Union with nil suffix (integer|string|nil) should become TEXT (nullable)
            local header = {
                {name = "id", type = "string", idx = 1, parsed = "id"},
                {name = "reward", type = "integer|string|nil", idx = 2, parsed = "reward"},
            }
            header.__source = path_join(temp_dir, "union_opt_test.tsv")
            header.__dataset = {}
            for _, col in ipairs(header) do col.header = header end

            local row1 = {{parsed = "quest1"}, {parsed = 100}}
            local row2 = {{parsed = "quest2"}, {parsed = nil}}
            local tsv = {header, row1, row2}
            header.__dataset = tsv

            local process_files = {
                tsv_files = {["union_opt_test.tsv"] = tsv},
                raw_files = {["union_opt_test.tsv"] = "id:string\treward:integer|string|nil\nquest1\t100\nquest2\t"},
            }
            local exportParams = { exportDir = temp_dir }

            local success = exporter.exportSQL(process_files, exportParams)
            assert.is_true(success)

            local content = file_util.readFile(path_join(temp_dir, "union_opt_test.sql"))
            assert.is_not_nil(content)
            -- reward column should be TEXT without NOT NULL (optional union)
            assert.is_truthy(content:match('"reward" TEXT[^%w]'))
            assert.is_falsy(content:match('"reward" TEXT NOT NULL'))
        end)

        it("should map union containing table type to TEXT column", function()
            -- Union with a table type (table|string) should use table's SQL type (TEXT)
            local header = {
                {name = "id", type = "string", idx = 1, parsed = "id"},
                {name = "data", type = "table|string", idx = 2, parsed = "data"},
            }
            header.__source = path_join(temp_dir, "union_table_test.tsv")
            header.__dataset = {}
            for _, col in ipairs(header) do col.header = header end

            local row1 = {{parsed = "item1"}, {parsed = "simple"}}
            local row2 = {{parsed = "item2"}, {parsed = {key = "value"}}}
            local tsv = {header, row1, row2}
            header.__dataset = tsv

            local process_files = {
                tsv_files = {["union_table_test.tsv"] = tsv},
                raw_files = {["union_table_test.tsv"] = "id:string\tdata:table|string\nitem1\tsimple\nitem2\t{key=\"value\"}"},
            }
            local exportParams = { exportDir = temp_dir }

            local success = exporter.exportSQL(process_files, exportParams)
            assert.is_true(success)

            local content = file_util.readFile(path_join(temp_dir, "union_table_test.sql"))
            assert.is_not_nil(content)
            -- data column should be TEXT NOT NULL (union containing table)
            assert.is_truthy(content:match('"data" TEXT NOT NULL'))
        end)

        it("should map optional union containing table type to TEXT without NOT NULL", function()
            -- Union with a table type and nil (table|nil) should be nullable TEXT
            local header = {
                {name = "id", type = "string", idx = 1, parsed = "id"},
                {name = "data", type = "table|nil", idx = 2, parsed = "data"},
            }
            header.__source = path_join(temp_dir, "union_table_nil_test.tsv")
            header.__dataset = {}
            for _, col in ipairs(header) do col.header = header end

            local row1 = {{parsed = "item1"}, {parsed = {key = "value"}}}
            local row2 = {{parsed = "item2"}, {parsed = nil}}
            local tsv = {header, row1, row2}
            header.__dataset = tsv

            local process_files = {
                tsv_files = {["union_table_nil_test.tsv"] = tsv},
                raw_files = {["union_table_nil_test.tsv"] = "id:string\tdata:table|nil\nitem1\t{key=\"value\"}\nitem2\t"},
            }
            local exportParams = { exportDir = temp_dir }

            local success = exporter.exportSQL(process_files, exportParams)
            assert.is_true(success)

            local content = file_util.readFile(path_join(temp_dir, "union_table_nil_test.sql"))
            assert.is_not_nil(content)
            -- data column should be TEXT without NOT NULL (optional union with table)
            assert.is_truthy(content:match('"data" TEXT[^%w]'))
            assert.is_falsy(content:match('"data" TEXT NOT NULL'))
        end)
    end)

    describe("exportXML", function()
        it("should export files in XML format", function()
            local process_files = createProcessFiles(temp_dir)
            local exportParams = {
                exportDir = temp_dir,
            }

            local success = exporter.exportXML(process_files, exportParams)
            assert.is_true(success)

            -- XML export changes extension to .xml
            local exported_file = path_join(temp_dir, "test.xml")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content)
            -- Should contain XML header and structure
            assert.is_truthy(content:match('<%?xml'))
            assert.is_truthy(content:match('<file>'))
            assert.is_truthy(content:match('</file>'))
        end)
    end)

    describe("exportMessagePack", function()
        it("should export files in MessagePack format", function()
            local process_files = createProcessFiles(temp_dir)
            local exportParams = {
                exportDir = temp_dir,
            }

            local success = exporter.exportMessagePack(process_files, exportParams)
            assert.is_true(success)

            -- MessagePack export changes extension to .mpk
            local exported_file = path_join(temp_dir, "test.mpk")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content)
            -- MessagePack is binary, just verify file was created
            assert.is_truthy(#content > 0)
        end)

        it("should be decodable by MessagePack library", function()
            local mpk = require("MessagePack")
            local process_files = createProcessFiles(temp_dir)
            local exportParams = {
                exportDir = temp_dir,
            }

            exporter.exportMessagePack(process_files, exportParams)

            local exported_file = path_join(temp_dir, "test.mpk")
            local content = file_util.readFile(exported_file)
            local decoded = mpk.unpack(content)

            assert.is_table(decoded)
            -- Should have 3 rows (header + 2 data rows)
            assert.equals(3, #decoded)
        end)
    end)

    describe("exportParams options", function()
        it("should respect formatSubdir option", function()
            local process_files = createProcessFiles(temp_dir)
            local exportParams = {
                exportDir = temp_dir,
                formatSubdir = "json_output",
            }

            local success = exporter.exportJSON(process_files, exportParams)
            assert.is_true(success)

            local exported_file = path_join(temp_dir, "json_output", "test.json")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content)
        end)

        it("should handle non-TSV files in raw_files", function()
            local process_files = createProcessFiles(temp_dir)
            -- Add a non-TSV file
            process_files.raw_files["readme.txt"] = "This is a readme file"

            local exportParams = {
                exportDir = temp_dir,
            }

            local success = exporter.exportLuaTSV(process_files, exportParams)
            assert.is_true(success)

            -- Non-TSV file should be copied as-is
            local txt_file = path_join(temp_dir, "readme.txt")
            local content = file_util.readFile(txt_file)
            assert.equals("This is a readme file", content)
        end)
    end)

    describe("edge cases", function()
        it("should handle empty process_files", function()
            local process_files = {
                tsv_files = {},
                raw_files = {},
            }
            local exportParams = {
                exportDir = temp_dir,
            }

            local success = exporter.exportLuaTSV(process_files, exportParams)
            assert.is_true(success)
        end)

        it("should create parent directories as needed", function()
            local process_files = createProcessFiles(temp_dir)
            -- Add a file in a nested path
            process_files.raw_files["subdir/nested/file.txt"] = "nested content"

            local exportParams = {
                exportDir = temp_dir,
            }

            local success = exporter.exportLuaTSV(process_files, exportParams)
            assert.is_true(success)

            local nested_file = path_join(temp_dir, "subdir/nested/file.txt")
            local content = file_util.readFile(nested_file)
            assert.equals("nested content", content)
        end)
    end)

    describe("exploded columns", function()
        it("should export exploded columns as separate flat columns when exportExploded is true", function()
            local process_files = createExplodedProcessFiles(temp_dir)
            local exportParams = {
                exportDir = temp_dir,
                exportExploded = true,
            }

            local success = exporter.exportLuaTSV(process_files, exportParams)
            assert.is_true(success)

            local exported_file = path_join(temp_dir, "exploded_test.tsv")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content)

            -- With exportExploded=true, columns should remain separate (flat)
            -- Header should contain all 4 column names
            assert.is_truthy(content:match('"id"'))
            assert.is_truthy(content:match('"location%.level"'))
            assert.is_truthy(content:match('"location%.position%._1"'))
            assert.is_truthy(content:match('"location%.position%._2"'))

            -- Data should be in separate columns
            assert.is_truthy(content:match('"starter"'))
            assert.is_truthy(content:match('"advanced"'))
            -- Should have individual integers, not composite structures
            assert.is_truthy(content:match('\t10\t') or content:match('\t10\n'))
            assert.is_truthy(content:match('\t20\t') or content:match('\t20\n'))
        end)

        it("should collapse exploded columns into composite columns when exportExploded is false", function()
            local process_files = createExplodedProcessFiles(temp_dir)
            local exportParams = {
                exportDir = temp_dir,
                exportExploded = false,
            }

            local success = exporter.exportLuaTSV(process_files, exportParams)
            assert.is_true(success)

            local exported_file = path_join(temp_dir, "exploded_test.tsv")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content)

            -- With exportExploded=false, exploded columns should be collapsed
            -- Header should have collapsed column spec instead of separate columns
            assert.is_truthy(content:match('"id"'))
            -- Should have collapsed "location" column with composite type spec
            assert.is_truthy(content:match('location:%{level:string,position:%{integer,integer%}%}'))

            -- Should NOT have the individual exploded column names
            assert.is_falsy(content:match('"location%.level"'))
            assert.is_falsy(content:match('"location%.position%._1"'))
            assert.is_falsy(content:match('"location%.position%._2"'))
        end)

        it("should export exploded columns as flat by default (exportExploded not specified)", function()
            local process_files = createExplodedProcessFiles(temp_dir)
            local exportParams = {
                exportDir = temp_dir,
                -- exportExploded not specified, should default to true
            }

            local success = exporter.exportLuaTSV(process_files, exportParams)
            assert.is_true(success)

            local exported_file = path_join(temp_dir, "exploded_test.tsv")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content)

            -- Default behavior should be same as exportExploded=true (flat columns)
            assert.is_truthy(content:match('"location%.level"'))
            assert.is_truthy(content:match('"location%.position%._1"'))
            assert.is_truthy(content:match('"location%.position%._2"'))
        end)
    end)
end)
