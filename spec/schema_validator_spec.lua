-- schema_validator_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

local lfs = require("lfs")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local schema_validator = require("schema_validator")
local exporter = require("exporter")
local file_util = require("file_util")

-- Simple path join function
local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- Helper to create a minimal TSV structure for testing
local function createTestTSV(source_name)
    local header = {
        {name = "id", type = "string", idx = 1, parsed = "id:string"},
        {name = "count", type = "integer", idx = 2, parsed = "count:integer"},
        {name = "value", type = "number", idx = 3, parsed = "value:number"},
        {name = "active", type = "boolean", idx = 4, parsed = "active:boolean"},
    }
    header.__source = source_name
    header.__dataset = {}

    local row1 = {
        {parsed = "item1"},
        {parsed = 42},
        {parsed = 3.14},
        {parsed = true},
    }

    local row2 = {
        {parsed = "item2"},
        {parsed = 100},
        {parsed = 2.718},
        {parsed = false},
    }

    local tsv = {header, row1, row2}
    header.__dataset = tsv

    for _, col in ipairs(header) do
        col.header = header
    end

    return tsv
end

-- Helper to create a TSV with tables/nested structures
local function createComplexTSV(source_name)
    local header = {
        {name = "id", type = "string", idx = 1, parsed = "id:string"},
        {name = "data", type = "table", idx = 2, parsed = "data:table"},
    }
    header.__source = source_name
    header.__dataset = {}

    local row1 = {
        {parsed = "item1"},
        {parsed = {1, 2, 3}},  -- sequence
    }

    local row2 = {
        {parsed = "item2"},
        {parsed = {key1 = "value1", key2 = "value2"}},  -- map
    }

    local row3 = {
        {parsed = "item3"},
        {parsed = {1, 2, nested = {a = 1, b = 2}}},  -- mixed
    }

    local tsv = {header, row1, row2, row3}
    header.__dataset = tsv

    for _, col in ipairs(header) do
        col.header = header
    end

    return tsv
end

-- Helper to create process_files structure
local function createProcessFiles(temp_dir, complex)
    local test_file = "test.tsv"
    local tsv
    if complex then
        tsv = createComplexTSV(path_join(temp_dir, test_file))
    else
        tsv = createTestTSV(path_join(temp_dir, test_file))
    end

    return {
        tsv_files = {
            [test_file] = tsv,
        },
        raw_files = {
            [test_file] = "dummy content",
        },
    }
end

describe("schema_validator", function()
    local temp_dir

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
        local td = path_join(system_temp, "lua_schema_test_" .. os.time())
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

    describe("getVersion", function()
        it("should return a version string", function()
            local version = schema_validator.getVersion()
            assert.is_string(version)
            assert.is_truthy(version:match("%d+%.%d+%.%d+"))
        end)
    end)

    describe("validateTypedJSON", function()
        describe("valid structures", function()
            it("should accept empty array", function()
                local ok, err = schema_validator.validateTypedJSON("[]")
                assert.is_true(ok, err)
            end)

            it("should accept array with empty rows", function()
                local ok, err = schema_validator.validateTypedJSON("[[],[]]")
                assert.is_true(ok, err)
            end)

            it("should accept string values", function()
                local ok, err = schema_validator.validateTypedJSON('[["hello","world"]]')
                assert.is_true(ok, err)
            end)

            it("should accept boolean values", function()
                local ok, err = schema_validator.validateTypedJSON("[[true,false]]")
                assert.is_true(ok, err)
            end)

            it("should accept null values", function()
                local ok, err = schema_validator.validateTypedJSON("[[null]]")
                assert.is_true(ok, err)
            end)

            it("should accept plain number values (floats)", function()
                local ok, err = schema_validator.validateTypedJSON("[[3.14,2.718]]")
                assert.is_true(ok, err)
            end)

            it("should accept typed integers", function()
                local ok, err = schema_validator.validateTypedJSON('[[{"int":"42"},{"int":"-100"}]]')
                assert.is_true(ok, err)
            end)

            it("should accept typed special floats", function()
                local ok, err = schema_validator.validateTypedJSON('[[{"float":"nan"},{"float":"inf"},{"float":"-inf"}]]')
                assert.is_true(ok, err)
            end)

            it("should accept typed tables (sequences)", function()
                local ok, err = schema_validator.validateTypedJSON('[[[ 3, "a", "b", "c" ]]]')
                assert.is_true(ok, err)
            end)

            it("should accept typed tables (maps)", function()
                local ok, err = schema_validator.validateTypedJSON('[[[0,["key","value"]]]]')
                assert.is_true(ok, err)
            end)

            it("should accept typed tables (mixed)", function()
                local ok, err = schema_validator.validateTypedJSON('[[[2,"a","b",["key","value"]]]]')
                assert.is_true(ok, err)
            end)
        end)

        describe("invalid structures", function()
            it("should reject non-JSON", function()
                local ok, err = schema_validator.validateTypedJSON("not json")
                assert.is_false(ok)
                assert.is_truthy(err:match("JSON parse error"))
            end)

            it("should reject non-array root", function()
                local ok, err = schema_validator.validateTypedJSON('{"key":"value"}')
                assert.is_false(ok)
                assert.is_truthy(err:match("root must be array"))
            end)

            it("should reject invalid typed integer format", function()
                local ok, err = schema_validator.validateTypedJSON('[[{"int":42}]]')
                assert.is_false(ok)
                assert.is_truthy(err:match("must be string"))
            end)

            it("should reject invalid typed integer value", function()
                local ok, err = schema_validator.validateTypedJSON('[[{"int":"abc"}]]')
                assert.is_false(ok)
                assert.is_truthy(err:match("must be numeric string"))
            end)

            it("should reject invalid typed float value", function()
                local ok, err = schema_validator.validateTypedJSON('[[{"float":"invalid"}]]')
                assert.is_false(ok)
                -- Note: hyphen must be escaped in Lua patterns with %
                assert.is_truthy(err:match("must be 'nan', 'inf', or '%-inf'"))
            end)

            it("should reject typed integer with extra keys", function()
                local ok, err = schema_validator.validateTypedJSON('[[{"int":"42","extra":"bad"}]]')
                assert.is_false(ok)
                assert.is_truthy(err:match("unexpected key"))
            end)
        end)

        describe("exported file validation", function()
            it("should validate simple typed JSON export", function()
                local process_files = createProcessFiles(temp_dir, false)
                local exportParams = { exportDir = temp_dir }

                local success = exporter.exportJSON(process_files, exportParams)
                assert.is_true(success)

                local exported_file = path_join(temp_dir, "test.json")
                local content = file_util.readFile(exported_file)
                assert.is_not_nil(content)

                local ok, err = schema_validator.validateTypedJSON(content)
                assert.is_true(ok, "Validation failed: " .. tostring(err))
            end)

            it("should validate complex typed JSON export with tables", function()
                local process_files = createProcessFiles(temp_dir, true)
                local exportParams = { exportDir = temp_dir }

                local success = exporter.exportJSON(process_files, exportParams)
                assert.is_true(success)

                local exported_file = path_join(temp_dir, "test.json")
                local content = file_util.readFile(exported_file)
                assert.is_not_nil(content)

                local ok, err = schema_validator.validateTypedJSON(content)
                assert.is_true(ok, "Validation failed: " .. tostring(err))
            end)
        end)
    end)

    describe("validateExportXML", function()
        describe("valid structures", function()
            it("should accept minimal valid XML", function()
                local xml = [[<?xml version="1.0" encoding="UTF-8"?>
<file>
<header></header>
</file>]]
                local ok, err = schema_validator.validateExportXML(xml)
                assert.is_true(ok, err)
            end)

            it("should accept XML with string values", function()
                local xml = [[<?xml version="1.0" encoding="UTF-8"?>
<file>
<header><string>col1</string></header>
<row><string>value1</string></row>
</file>]]
                local ok, err = schema_validator.validateExportXML(xml)
                assert.is_true(ok, err)
            end)

            it("should accept XML with all primitive types", function()
                local xml = [[<?xml version="1.0" encoding="UTF-8"?>
<file>
<header><string>a</string><string>b</string><string>c</string><string>d</string></header>
<row><null/><true/><false/><integer>42</integer></row>
</file>]]
                local ok, err = schema_validator.validateExportXML(xml)
                assert.is_true(ok, err)
            end)

            it("should accept XML with number values including special floats", function()
                local xml = [[<?xml version="1.0" encoding="UTF-8"?>
<file>
<header><string>n</string></header>
<row><number>3.14</number></row>
<row><number>nan</number></row>
<row><number>inf</number></row>
<row><number>-inf</number></row>
</file>]]
                local ok, err = schema_validator.validateExportXML(xml)
                assert.is_true(ok, err)
            end)

            it("should accept XML with tables", function()
                local xml = [[<?xml version="1.0" encoding="UTF-8"?>
<file>
<header><string>t</string></header>
<row><table><integer>1</integer><integer>2</integer></table></row>
</file>]]
                local ok, err = schema_validator.validateExportXML(xml)
                assert.is_true(ok, err)
            end)

            it("should accept XML with key_value pairs", function()
                local xml = [[<?xml version="1.0" encoding="UTF-8"?>
<file>
<header><string>t</string></header>
<row><table><key_value><string>key</string><string>value</string></key_value></table></row>
</file>]]
                local ok, err = schema_validator.validateExportXML(xml)
                assert.is_true(ok, err)
            end)
        end)

        describe("invalid structures", function()
            it("should reject missing XML declaration", function()
                local xml = [[<file><header></header></file>]]
                local ok, err = schema_validator.validateExportXML(xml)
                assert.is_false(ok)
                assert.is_truthy(err:match("missing XML declaration"))
            end)

            it("should reject missing file element", function()
                local xml = [[<?xml version="1.0"?><root></root>]]
                local ok, err = schema_validator.validateExportXML(xml)
                assert.is_false(ok)
                assert.is_truthy(err:match("missing <file>"))
            end)

            it("should reject missing header element", function()
                local xml = [[<?xml version="1.0"?><file></file>]]
                local ok, err = schema_validator.validateExportXML(xml)
                assert.is_false(ok)
                assert.is_truthy(err:match("missing <header>"))
            end)

            it("should reject invalid element names", function()
                local xml = [[<?xml version="1.0"?>
<file>
<header><invalid>test</invalid></header>
</file>]]
                local ok, err = schema_validator.validateExportXML(xml)
                assert.is_false(ok)
                assert.is_truthy(err:match("invalid element"))
            end)

            it("should reject invalid integer content", function()
                local xml = [[<?xml version="1.0"?>
<file>
<header><string>n</string></header>
<row><integer>abc</integer></row>
</file>]]
                local ok, err = schema_validator.validateExportXML(xml)
                assert.is_false(ok)
                assert.is_truthy(err:match("invalid integer content"))
            end)
        end)

        describe("exported file validation", function()
            it("should validate simple XML export", function()
                local process_files = createProcessFiles(temp_dir, false)
                local exportParams = { exportDir = temp_dir }

                local success = exporter.exportXML(process_files, exportParams)
                assert.is_true(success)

                local exported_file = path_join(temp_dir, "test.xml")
                local content = file_util.readFile(exported_file)
                assert.is_not_nil(content)

                local ok, err = schema_validator.validateExportXML(content)
                assert.is_true(ok, "Validation failed: " .. tostring(err))
            end)

            it("should validate complex XML export with tables", function()
                local process_files = createProcessFiles(temp_dir, true)
                local exportParams = { exportDir = temp_dir }

                local success = exporter.exportXML(process_files, exportParams)
                assert.is_true(success)

                local exported_file = path_join(temp_dir, "test.xml")
                local content = file_util.readFile(exported_file)
                assert.is_not_nil(content)

                local ok, err = schema_validator.validateExportXML(content)
                assert.is_true(ok, "Validation failed: " .. tostring(err))
            end)
        end)
    end)

    describe("validateTypedValue", function()
        it("should validate nil", function()
            local ok, err = schema_validator.validateTypedValue(nil, "test")
            assert.is_true(ok, err)
        end)

        it("should validate strings", function()
            local ok, err = schema_validator.validateTypedValue("hello", "test")
            assert.is_true(ok, err)
        end)

        it("should validate booleans", function()
            local ok1, err1 = schema_validator.validateTypedValue(true, "test")
            assert.is_true(ok1, err1)
            local ok2, err2 = schema_validator.validateTypedValue(false, "test")
            assert.is_true(ok2, err2)
        end)

        it("should validate numbers", function()
            local ok, err = schema_validator.validateTypedValue(3.14, "test")
            assert.is_true(ok, err)
        end)

        it("should validate typed integers", function()
            local ok, err = schema_validator.validateTypedValue({int = "42"}, "test")
            assert.is_true(ok, err)
        end)

        it("should validate typed special floats", function()
            local ok1, _ = schema_validator.validateTypedValue({float = "nan"}, "test")
            assert.is_true(ok1)
            local ok2, _ = schema_validator.validateTypedValue({float = "inf"}, "test")
            assert.is_true(ok2)
            local ok3, _ = schema_validator.validateTypedValue({float = "-inf"}, "test")
            assert.is_true(ok3)
        end)
    end)
end)
