-- exporter_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

local lfs = require("lfs")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local pending = busted.pending
local before_each = busted.before_each
local after_each = busted.after_each

local exporter = require("serde.exporter")
local file_util = require("infra.file_util")

-- lsqlite3 lets us check that an exported .sql actually RUNS in a real engine,
-- not merely that our own parser reads it back. It is absent in the dev
-- environments (only the LuaJIT Docker image installs it), so the SQL-execution
-- tests below become `pending` there rather than failing.
local HAS_SQLITE, sqlite3 = pcall(require, "lsqlite3")
local it_sqlite = HAS_SQLITE and it or pending

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

    describe("sqlColumnName", function()
        it("should keep a plain or exploded-array name unchanged", function()
            assert.equals("name", exporter.sqlColumnName("name"))
            -- Dots and brackets become underscores, trailing ones stripped
            assert.equals("stats_attack", exporter.sqlColumnName("stats.attack"))
            -- A lone array element has no '=' sibling, so no _k/_v suffix
            local set = exporter.sqlColumnNameSet({"materials[1]"})
            assert.equals("materials_1",
                exporter.sqlColumnName("materials[1]", set))
        end)

        it("should suffix an exploded map's key/value pair _k/_v", function()
            -- prices[iron] (key) and prices[iron]= (value) both sanitize to
            -- prices_iron -- SQLite rejects the duplicate. Both sides are
            -- suffixed so neither reads like a bare or typo'd name.
            local set = exporter.sqlColumnNameSet({"prices[iron]", "prices[iron]="})
            assert.equals("prices_iron_k",
                exporter.sqlColumnName("prices[iron]", set))
            assert.equals("prices_iron_v",
                exporter.sqlColumnName("prices[iron]=", set))
            -- The pair is now distinct...
            assert.are_not.equal(
                exporter.sqlColumnName("prices[iron]", set),
                exporter.sqlColumnName("prices[iron]=", set))
            -- ...and a value column is _v even if its own set is not supplied,
            -- because the trailing '=' is intrinsic to it
            assert.equals("prices_iron_v",
                exporter.sqlColumnName("prices[iron]="))
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

        it("should wrap int64 only in an untyped table/raw column", function()
            -- The wrapper decision is per COLUMN. A declared int64 column keeps
            -- its plain quoted digits, because the column type already restores
            -- the box on re-read; an untyped raw/table column has nothing else
            -- to say the value was an int64, so it gets the tag.
            local int64 = require("util.int64")
            local box = int64.of("9007199254740993")
            local header = {
                {name = "id", type = "int64", idx = 1, parsed = "id"},
                {name = "bag", type = "raw", idx = 2, parsed = "bag"},
            }
            header.__source = path_join(temp_dir, "wrap.tsv")
            local row = {{parsed = box}, {parsed = {box, k = box}}}
            local tsv = {header, row}
            header.__dataset = tsv
            for _, col in ipairs(header) do col.header = header end

            local success = exporter.exportLuaTSV({
                tsv_files = {["wrap.tsv"] = tsv},
                raw_files = {["wrap.tsv"] = "id:int64\tbag:raw"},
            }, {exportDir = temp_dir})
            assert.is_true(success)

            local content = file_util.readFile(path_join(temp_dir, "wrap.tsv"))
            local dataLine = content:match("\n([^\n]*9007199254740993[^\n]*)")
            assert.is_not_nil(dataLine)
            local declared, untyped = dataLine:match("^([^\t]*)\t(.*)$")
            assert.are.equal('"9007199254740993"', declared)
            assert.are.equal(
                '{{__int64="9007199254740993"},k={__int64="9007199254740993"}}',
                untyped)
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
            -- Typed JSON wraps integers as {"integer":"N"}
            assert.is_truthy(content:match('{"integer":"42"}'))
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
            -- Natural JSON has plain integers, not wrapped as {"integer":"N"}
            assert.is_truthy(content:match(',42,') or content:match('%[42,') or content:match(',42%]'))
            assert.is_falsy(content:match('{"integer":'))
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

        it("should emit a real INSERT when the header has no metadata",
            function()
            -- REGRESSION, and a silent one. A JOINED or TRANSFORMED header is
            -- built during export and carries neither __source nor __dataset,
            -- which is where the table name and the "has any rows?" test used
            -- to come from. Item and Files (the two tutorial files that are
            -- joined/transformed) therefore exported as CREATE TABLE "unknown"
            -- with the INSERT emitted as a COMMENT -- every data row following
            -- it as a bare "(...)" tuple. sqlite3 rejects that outright
            -- ("near \"(\": syntax error"), but our own round-trip PASSED,
            -- because parseSQLContent finds the "VALUES" text without noticing
            -- it sits inside a comment.
            local header = {
                {name = "id", type = "string", idx = 1, parsed = "id"},
                {name = "value", type = "integer", idx = 2, parsed = "value"},
            }
            -- Deliberately NO __source and NO __dataset, as a joined header
            for _, col in ipairs(header) do col.header = header end
            local tsv = {header, {{parsed = "item1"}, {parsed = 42}}}

            local success = exporter.exportSQL({
                tsv_files = {["joined.tsv"] = tsv},
                raw_files = {["joined.tsv"] = "id:string\tvalue:integer"},
            }, {exportDir = temp_dir})
            assert.is_true(success)

            local content = file_util.readFile(path_join(temp_dir, "joined.sql"))
            assert.is_truthy(content:match('CREATE TABLE "joined"'))
            assert.is_truthy(content:match('INSERT INTO "joined"'))
            -- The INSERT must not be commented out, and the DDL must be
            -- terminated -- the two halves of what made the file unrunnable
            assert.is_nil(content:match("\n%-%-%("))
            assert.is_truthy(content:match("%);\nINSERT INTO"))
        end)

        it_sqlite("should emit SQL a real engine can execute", function()
            -- The two bugs above BOTH round-tripped through our own
            -- parseSQLContent while being un-runnable in SQLite: a commented-out
            -- INSERT, and an exploded map's key/value columns colliding on one
            -- name. Only a real engine catches that class, which is why the
            -- LuaJIT image now carries lsqlite3.
            local header = {
                {name = "name", type = "string", idx = 1, parsed = "name"},
                -- an exploded map: key + value, the collision case
                {name = "prices[iron]", type = "string", idx = 2,
                 parsed = "prices[iron]"},
                {name = "prices[iron]=", type = "integer", idx = 3,
                 parsed = "prices[iron]="},
            }
            header.__source = path_join(temp_dir, "goods.tsv")
            for _, col in ipairs(header) do col.header = header end
            local tsv = {header,
                {{parsed = "sword"}, {parsed = "ore"}, {parsed = 12}}}
            header.__dataset = tsv

            assert.is_true(exporter.exportSQL({
                tsv_files = {["goods.tsv"] = tsv},
                raw_files = {["goods.tsv"] =
                    "name:string\tprices[iron]:string\tprices[iron]=:integer"},
            }, {exportDir = temp_dir}))

            local sql = file_util.readFile(path_join(temp_dir, "goods.sql"))
            local db = sqlite3.open_memory()
            local rc = db:exec(sql)
            local msg = db:errmsg()
            db:close()
            assert.equals(sqlite3.OK, rc,
                "sqlite rejected the export: " .. tostring(msg))
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
            -- Root carries the TabuLua table namespace (urn:tabulua:table:1).
            assert.is_truthy(content:match('<file xmlns="urn:tabulua:table:1">'))
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
            local mpk = require("serde.serialization").messagePack
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

        it("streams a passthrough binary descriptor byte-identically (never loaded)", function()
            -- A binary fixture with bytes that must survive untouched: CR, LF, NUL,
            -- high bytes. If the exporter mistook the descriptor for string content
            -- and wrote it in text mode, \n would become \r\n on Windows and the
            -- bytes would not match.
            local src = path_join(temp_dir, "asset.bin")
            local raw_bytes = "\137PNG\r\n\26\n\0\1\2\3 binary \255\254 data\r\n"
            do
                local f = assert(io.open(src, "wb"))
                f:write(raw_bytes)
                f:close()
            end
            local size = assert(file_util.getFileSize(src))

            local process_files = createProcessFiles(temp_dir)
            -- raw_files holds an O(1) descriptor TABLE, not a string: the bytes
            -- were never loaded into memory (§3.5).
            process_files.raw_files["asset.bin"] = {
                __passthrough = true,
                kind = "binary",
                sourcePath = src,
                size = size,
            }

            local out_dir = path_join(temp_dir, "out")
            local success = exporter.exportLuaTSV(process_files, {exportDir = out_dir})
            assert.is_true(success)

            local exported = path_join(out_dir, "asset.bin")
            local got = file_util.readFileBinary(exported)
            assert.equals(raw_bytes, got)
        end)

        it("strips COG scaffolding from a passthrough file when stripCog is set", function()
            local process_files = createProcessFiles(temp_dir)
            local cogged = "Title\n---[[[\n---return 'GEN'\n---]]]\nGEN\n---[[[end]]]\nEnd"
            process_files.raw_files["doc.md"] = cogged

            local out_dir = path_join(temp_dir, "stripped")
            assert.is_true(exporter.exportLuaTSV(process_files,
                {exportDir = out_dir, stripCog = true}))

            local exported = file_util.readFile(path_join(out_dir, "doc.md"))
            assert.equals("Title\nGEN\nEnd", exported)
            -- The in-memory source is not mutated.
            assert.equals(cogged, process_files.raw_files["doc.md"])
        end)

        it("leaves a passthrough file untouched when stripCog is off", function()
            local process_files = createProcessFiles(temp_dir)
            local cogged = "Title\n---[[[\n---return 'GEN'\n---]]]\nGEN\n---[[[end]]]\nEnd"
            process_files.raw_files["doc.md"] = cogged

            local out_dir = path_join(temp_dir, "kept")
            assert.is_true(exporter.exportLuaTSV(process_files, {exportDir = out_dir}))

            local exported = file_util.readFile(path_join(out_dir, "doc.md"))
            assert.equals(cogged, exported)
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

    describe("computeRelativePath via export (file2dir)", function()
        it("should return file_name as-is when directory is '.'", function()
            -- When the data directory is ".", file paths are already relative
            -- and should not have a prefix stripped.
            local test_file = "subdir/test.tsv"
            local tsv = createTestTSV(test_file)

            local process_files = {
                tsv_files = { [test_file] = tsv },
                raw_files = { [test_file] = "id\tvalue\nitem1\t42\nitem2\t100" },
                file2dir = { [test_file] = "." },
            }
            local exportParams = { exportDir = temp_dir }

            local success = exporter.exportLuaTSV(process_files, exportParams)
            assert.is_true(success)

            -- The file should be at exportDir/subdir/test.tsv (path preserved as-is)
            local exported_file = path_join(temp_dir, "subdir/test.tsv")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content, "File should be at subdir/test.tsv, not with chars stripped")
            assert.is_truthy(content:match('"item1"'))
        end)

        it("should namespace by package when directory is not '.'", function()
            -- The source prefix is stripped to get the PACKAGE-RELATIVE name,
            -- then the package's own namespace is prefixed back on. Exporting
            -- straight to the package-relative name made two packages collide
            -- (every package has a Files.tsv and a Manifest.transposed.tsv),
            -- and the last one written silently destroyed the other.
            local test_file = "mydata/test.tsv"
            local tsv = createTestTSV(test_file)

            local process_files = {
                tsv_files = { [test_file] = tsv },
                raw_files = { [test_file] = "id\tvalue\nitem1\t42\nitem2\t100" },
                file2dir = { [test_file] = "mydata" },
            }
            local exportParams = { exportDir = temp_dir }

            local success = exporter.exportLuaTSV(process_files, exportParams)
            assert.is_true(success)

            -- The file should be at exportDir/mydata/test.tsv: the package
            -- namespace ("mydata") plus the package-relative name
            local exported_file = path_join(temp_dir, "mydata", "test.tsv")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content,
                "File should be at mydata/test.tsv (package-namespaced)")
            assert.is_truthy(content:match('"item1"'))
        end)

        it("should REFUSE to export text containing a Windows line ending",
            function()
            -- Hard error by policy: CRLF in an export makes output differ with
            -- the OS that wrote it, and corrupts data across platforms -- a
            -- newline inside a value written as CRLF keeps its CR inside that
            -- value when the file is read on Linux, since only Windows
            -- translates it back.
            --
            -- SQL is the format that stores text RAW; Lua and JSON escape a CR
            -- (\13), so it never reaches the file there.
            local tsv = createTestTSV("Test.tsv")
            tsv[2][1].parsed = "line one\r\nline two"

            local process_files = {
                tsv_files = {["Test.tsv"] = tsv},
                raw_files = {["Test.tsv"] = "id\tvalue\nitem1\t42"},
            }
            local ok, err = pcall(exporter.exportSQL, process_files,
                {exportDir = temp_dir})
            assert.is_false(ok, "export accepted a Windows line ending")
            assert.matches("carriage return", tostring(err))
        end)

        it("should keep two packages' same-named files apart", function()
            -- The bug this namespacing exists to fix: both files are called
            -- Files.tsv, and before namespacing the second export overwrote
            -- the first, silently discarding one package's data.
            local core_file = "pkg/core/Files.tsv"
            local exp_file = "pkg/expansion/Files.tsv"
            -- Distinct first cells, so the assertions below prove each output
            -- holds its OWN package's data rather than merely existing
            local core_tsv = createTestTSV(core_file)
            core_tsv[2][1].parsed = "coreRow"
            local exp_tsv = createTestTSV(exp_file)
            exp_tsv[2][1].parsed = "expRow"
            local process_files = {
                tsv_files = {
                    [core_file] = core_tsv,
                    [exp_file] = exp_tsv,
                },
                raw_files = {
                    [core_file] = "id\tvalue\ncoreRow\t1",
                    [exp_file] = "id\tvalue\nexpRow\t2",
                },
                file2dir = {
                    [core_file] = "pkg/core",
                    [exp_file] = "pkg/expansion",
                },
            }
            local success = exporter.exportLuaTSV(process_files,
                { exportDir = temp_dir })
            assert.is_true(success)

            local core_out = file_util.readFile(
                path_join(temp_dir, "core", "Files.tsv"))
            local exp_out = file_util.readFile(
                path_join(temp_dir, "expansion", "Files.tsv"))
            assert.is_not_nil(core_out, "core package's file was lost")
            assert.is_not_nil(exp_out, "expansion package's file was lost")
            -- ...and each holds its OWN rows, not the other's
            assert.is_truthy(core_out:match('"coreRow"'))
            assert.is_truthy(exp_out:match('"expRow"'))
        end)

        it("should preserve subdirectory paths when directory is '.'", function()
            -- Regression test: with dir=".", a file like "Resource/Bulk/data.tsv"
            -- must NOT become "source/Bulk/data.tsv" (first 2 chars stripped).
            local test_file = "Resource/Bulk/data.tsv"
            local tsv = createTestTSV(test_file)

            local process_files = {
                tsv_files = { [test_file] = tsv },
                raw_files = { [test_file] = "id\tvalue\nitem1\t42\nitem2\t100" },
                file2dir = { [test_file] = "." },
            }
            local exportParams = { exportDir = temp_dir }

            local success = exporter.exportLuaTSV(process_files, exportParams)
            assert.is_true(success)

            -- Must be at the full original path, not the mangled one
            local exported_file = path_join(temp_dir, "Resource/Bulk/data.tsv")
            local content = file_util.readFile(exported_file)
            assert.is_not_nil(content, "File should be at Resource/Bulk/data.tsv, not source/Bulk/data.tsv")
            assert.is_truthy(content:match('"item1"'))

            -- Verify the mangled path does NOT exist
            local mangled_file = path_join(temp_dir, "source/Bulk/data.tsv")
            local mangled_content = file_util.readFile(mangled_file)
            assert.is_nil(mangled_content, "Mangled path source/Bulk/data.tsv should not exist")
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

    describe("shouldExport filtering", function()
        -- Helper to create process_files with a primary and secondary file for join testing
        local function createJoinProcessFiles(temp_dir)
            local primary_file = "Resource/Primary.tsv"
            local secondary_file = "Resource/Secondary.tsv"

            local primary_tsv = createTestTSV(path_join(temp_dir, primary_file))
            local secondary_tsv = createTestTSV(path_join(temp_dir, secondary_file))

            local joinMeta = {
                lcFn2JoinInto = {
                    ["resource/secondary.tsv"] = "resource/primary.tsv",
                },
                lcFn2Export = {},
                lcFn2JoinColumn = {
                    ["resource/secondary.tsv"] = "id",
                },
                lcFn2JoinedTypeName = {},
            }

            return {
                tsv_files = {
                    [primary_file] = primary_tsv,
                    [secondary_file] = secondary_tsv,
                },
                raw_files = {
                    [primary_file] = "id\tvalue\nitem1\t42\nitem2\t100",
                    [secondary_file] = "id\tvalue\nitem1\t42\nitem2\t100",
                },
                file2dir = {
                    [primary_file] = ".",
                    [secondary_file] = ".",
                },
                joinMeta = joinMeta,
            }
        end

        it("should skip secondary files in exportLuaTSV", function()
            local process_files = createJoinProcessFiles(temp_dir)
            local exportParams = { exportDir = temp_dir }

            local success = exporter.exportLuaTSV(process_files, exportParams)
            assert.is_true(success)

            -- Primary file should be exported
            local primary_exported = path_join(temp_dir, "Resource/Primary.tsv")
            local primary_content = file_util.readFile(primary_exported)
            assert.is_not_nil(primary_content, "Primary file should be exported")

            -- Secondary file should NOT be exported
            local secondary_exported = path_join(temp_dir, "Resource/Secondary.tsv")
            local secondary_content = file_util.readFile(secondary_exported)
            assert.is_nil(secondary_content, "Secondary file should not be exported")
        end)

        it("should skip secondary files in exportJSON", function()
            local process_files = createJoinProcessFiles(temp_dir)
            local exportParams = { exportDir = temp_dir }

            local success = exporter.exportJSON(process_files, exportParams)
            assert.is_true(success)

            -- Primary file should be exported (with .json extension)
            local primary_exported = path_join(temp_dir, "Resource/Primary.json")
            local primary_content = file_util.readFile(primary_exported)
            assert.is_not_nil(primary_content, "Primary file should be exported")

            -- Secondary file should NOT be exported
            local secondary_exported = path_join(temp_dir, "Resource/Secondary.json")
            local secondary_content = file_util.readFile(secondary_exported)
            assert.is_nil(secondary_content, "Secondary file should not be exported")
        end)

        it("should skip secondary files in exportMessagePack", function()
            local process_files = createJoinProcessFiles(temp_dir)
            local exportParams = { exportDir = temp_dir }

            local success = exporter.exportMessagePack(process_files, exportParams)
            assert.is_true(success)

            -- Primary file should be exported (with .mpk extension)
            local primary_exported = path_join(temp_dir, "Resource/Primary.mpk")
            local primary_content = file_util.readFile(primary_exported)
            assert.is_not_nil(primary_content, "Primary file should be exported")

            -- Secondary file should NOT be exported
            local secondary_exported = path_join(temp_dir, "Resource/Secondary.mpk")
            local secondary_content = file_util.readFile(secondary_exported)
            assert.is_nil(secondary_content, "Secondary file should not be exported")
        end)

        it("should export secondary file when lcFn2Export explicitly allows it", function()
            local process_files = createJoinProcessFiles(temp_dir)
            -- Explicitly set export=true for the secondary file
            process_files.joinMeta.lcFn2Export["resource/secondary.tsv"] = true
            local exportParams = { exportDir = temp_dir }

            local success = exporter.exportLuaTSV(process_files, exportParams)
            assert.is_true(success)

            -- Both files should be exported
            local primary_exported = path_join(temp_dir, "Resource/Primary.tsv")
            assert.is_not_nil(file_util.readFile(primary_exported), "Primary file should be exported")

            local secondary_exported = path_join(temp_dir, "Resource/Secondary.tsv")
            assert.is_not_nil(file_util.readFile(secondary_exported),
                "Secondary file with explicit export=true should be exported")
        end)

        it("should use relative path, not bare filename, for shouldExport lookup", function()
            -- Regression test: ensures the lookup key matches Files.tsv format
            -- (full relative path like "Resource/Secondary.tsv", not bare "Secondary.tsv")
            local process_files = createJoinProcessFiles(temp_dir)
            local exportParams = { exportDir = temp_dir }

            local success = exporter.exportLuaTSV(process_files, exportParams)
            assert.is_true(success)

            -- If the bug were present (bare filename lookup), the secondary file
            -- would be exported because "secondary.tsv" wouldn't match
            -- "resource/secondary.tsv" in lcFn2JoinInto
            local secondary_exported = path_join(temp_dir, "Resource/Secondary.tsv")
            local secondary_content = file_util.readFile(secondary_exported)
            assert.is_nil(secondary_content,
                "Secondary file must not be exported (relative path key must match)")
        end)
    end)
end)
