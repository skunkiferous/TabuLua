-- importer_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

local lfs = require("lfs")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local importer = require("serde.importer")
local file_util = require("infra.file_util")
local serialization = require("serde.serialization")

-- Simple path join function
local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

describe("importer", function()
    local temp_dir

    -- Setup: Create a temporary directory for testing
    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
        local td = path_join(system_temp, "lua_importer_test_" .. os.time())
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
            local version = importer.getVersion()
            assert.is_string(version)
            assert.is_truthy(version:match("%d+%.%d+%.%d+"))
        end)
    end)

    describe("importLuaFile", function()
        it("should import a Lua file returning a table", function()
            local file_path = path_join(temp_dir, "test.lua")
            file_util.writeFile(file_path, "return {\n{1,2,3},\n{4,5,6}\n}")

            local result, err = importer.importLuaFile(file_path)
            assert.is_nil(err)
            assert.are.same({{1, 2, 3}, {4, 5, 6}}, result)
        end)

        it("should import a Lua file with nested tables", function()
            local file_path = path_join(temp_dir, "test.lua")
            file_util.writeFile(file_path, 'return {{a=1,b="test"},{c={d=2}}}')

            local result, err = importer.importLuaFile(file_path)
            assert.is_nil(err)
            assert.equals(1, result[1].a)
            assert.equals("test", result[1].b)
            assert.equals(2, result[2].c.d)
        end)

        it("should return error for non-existent file", function()
            local result, err = importer.importLuaFile(path_join(temp_dir, "nonexistent.lua"))
            assert.is_nil(result)
            assert.is_not_nil(err)
        end)

        it("should return error for invalid Lua", function()
            local file_path = path_join(temp_dir, "invalid.lua")
            file_util.writeFile(file_path, "return {{{invalid")

            local result, err = importer.importLuaFile(file_path)
            assert.is_nil(result)
            assert.is_not_nil(err)
        end)
    end)

    describe("importTypedJSONFile", function()
        it("should import typed JSON array-of-arrays", function()
            local file_path = path_join(temp_dir, "test.json")
            file_util.writeFile(file_path, '[\n[3,"a","b","c"],\n[3,{"integer":"1"},{"integer":"2"},{"integer":"3"}]\n]')

            local result, err = importer.importTypedJSONFile(file_path)
            assert.is_nil(err)
            assert.are.same({"a", "b", "c"}, result[1])
            assert.are.same({1, 2, 3}, result[2])
        end)

        it("should handle maps with typed JSON", function()
            local file_path = path_join(temp_dir, "test.json")
            file_util.writeFile(file_path, '[[0,["name","test"],["value",{"integer":"42"}]]]')

            local result, err = importer.importTypedJSONFile(file_path)
            assert.is_nil(err)
            assert.equals("test", result[1].name)
            assert.equals(42, result[1].value)
        end)

        it("should return error for non-table at top level", function()
            local file_path = path_join(temp_dir, "test.json")
            -- A JSON string, not a table/array
            file_util.writeFile(file_path, '"just a string"')

            local result, err = importer.importTypedJSONFile(file_path)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Expected JSON array at top level", err)
        end)

        it("should import a row containing nulls", function()
            -- REGRESSION: an empty optional column decodes to a HOLE, and
            -- re-encoding a holed table yields a JSON OBJECT keyed by "1",
            -- "2", ... -- so every cell of such a row read back as missing.
            -- Patch files, whose rows are sparse by nature, hit this on
            -- nearly every row.
            local file_path = path_join(temp_dir, "test.json")
            file_util.writeFile(file_path,
                '[\n["a",null,"c",null,{"integer":"7"}]\n]')

            local result, err = importer.importTypedJSONFile(file_path)
            assert.is_nil(err)
            assert.equals("a", result[1][1])
            assert.is_nil(result[1][2])
            assert.equals("c", result[1][3])
            assert.is_nil(result[1][4])
            assert.equals(7, result[1][5])
        end)

        it("should handle JSON object at top level as empty result", function()
            -- Note: JSON objects are Lua tables, so they pass type check
            -- but ipairs over them yields nothing, resulting in empty result
            local file_path = path_join(temp_dir, "test.json")
            file_util.writeFile(file_path, '{"not": "an array"}')

            local result, err = importer.importTypedJSONFile(file_path)
            assert.is_nil(err)
            assert.are.same({}, result)
        end)

        it("should return error for invalid typed JSON in row", function()
            local file_path = path_join(temp_dir, "test.json")
            -- Row with invalid int wrapper
            file_util.writeFile(file_path, '[[1,{"integer":"not_a_number"}]]')

            local result, err = importer.importTypedJSONFile(file_path)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Failed to deserialize row", err)
        end)

        it("should return error for invalid JSON syntax", function()
            local file_path = path_join(temp_dir, "test.json")
            file_util.writeFile(file_path, '[[1,2,{invalid}]]')

            local result, err = importer.importTypedJSONFile(file_path)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Failed to parse JSON", err)
        end)
    end)

    describe("importNaturalJSONFile", function()
        it("should import natural JSON array-of-arrays", function()
            local file_path = path_join(temp_dir, "test.json")
            file_util.writeFile(file_path, '[\n["a","b","c"],\n[1,2,3]\n]')

            local result, err = importer.importNaturalJSONFile(file_path)
            assert.is_nil(err)
            assert.are.same({"a", "b", "c"}, result[1])
            assert.are.same({1, 2, 3}, result[2])
        end)

        it("should import a row containing nulls", function()
            -- Same regression as the typed path: a holed row must not come
            -- back keyed by "1", "2", ...
            local file_path = path_join(temp_dir, "test.json")
            file_util.writeFile(file_path, '[\n["a",null,"c",null,7]\n]')

            local result, err = importer.importNaturalJSONFile(file_path)
            assert.is_nil(err)
            assert.equals("a", result[1][1])
            assert.is_nil(result[1][2])
            assert.equals("c", result[1][3])
            assert.equals(7, result[1][5])
        end)

        it("should handle special float values", function()
            local file_path = path_join(temp_dir, "test.json")
            file_util.writeFile(file_path, '[["INF","NAN","-INF"]]')

            local result, err = importer.importNaturalJSONFile(file_path)
            assert.is_nil(err)
            assert.equals(math.huge, result[1][1])
            assert.is_true(result[1][2] ~= result[1][2])  -- NaN check
            assert.equals(-math.huge, result[1][3])
        end)

        it("should return error for non-array at top level", function()
            local file_path = path_join(temp_dir, "test.json")
            file_util.writeFile(file_path, '"just a string"')

            local result, err = importer.importNaturalJSONFile(file_path)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Expected JSON array at top level", err)
        end)

        it("should return error for invalid JSON syntax", function()
            local file_path = path_join(temp_dir, "test.json")
            file_util.writeFile(file_path, '[[1,2,{bad syntax}]]')

            local result, err = importer.importNaturalJSONFile(file_path)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Failed to parse JSON", err)
        end)
    end)

    describe("importLuaTSVFile", function()
        it("should import TSV with Lua literals", function()
            local file_path = path_join(temp_dir, "test.tsv")
            file_util.writeFile(file_path, '"id"\t"value"\n"item1"\t42\n"item2"\t100')

            local result, err = importer.importLuaTSVFile(file_path)
            assert.is_nil(err)
            assert.equals("id", result[1][1])
            assert.equals("value", result[1][2])
            assert.equals("item1", result[2][1])
            assert.equals(42, result[2][2])
        end)

        it("should handle nested tables in TSV cells", function()
            local file_path = path_join(temp_dir, "test.tsv")
            file_util.writeFile(file_path, '"name"\t"data"\n"test"\t{a=1,b=2}')

            local result, err = importer.importLuaTSVFile(file_path)
            assert.is_nil(err)
            assert.equals("test", result[2][1])
            assert.equals(1, result[2][2].a)
            assert.equals(2, result[2][2].b)
        end)

        it("should skip comments and blank lines", function()
            local file_path = path_join(temp_dir, "test.tsv")
            file_util.writeFile(file_path, '# Comment\n"header"\n\n"value"')

            local result, err = importer.importLuaTSVFile(file_path)
            assert.is_nil(err)
            assert.equals(2, #result)
            assert.equals("header", result[1][1])
            assert.equals("value", result[2][1])
        end)

        it("should return error for invalid Lua in cell", function()
            local file_path = path_join(temp_dir, "test.tsv")
            file_util.writeFile(file_path, '"header"\n{{{invalid lua')

            local result, err = importer.importLuaTSVFile(file_path)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Failed to parse cell", err)
        end)
    end)

    describe("importTypedJSONTSVFile", function()
        it("should import TSV with typed JSON values", function()
            local file_path = path_join(temp_dir, "test.tsv")
            file_util.writeFile(file_path, '"id"\t"value"\n"item1"\t{"integer":"42"}')

            local result, err = importer.importTypedJSONTSVFile(file_path)
            assert.is_nil(err)
            assert.equals("id", result[1][1])
            assert.equals("item1", result[2][1])
            assert.equals(42, result[2][2])
        end)

        it("should return error for invalid typed JSON in cell", function()
            local file_path = path_join(temp_dir, "test.tsv")
            file_util.writeFile(file_path, '"header"\n{"integer":"not_a_number"}')

            local result, err = importer.importTypedJSONTSVFile(file_path)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Failed to parse cell", err)
        end)
    end)

    describe("importNaturalJSONTSVFile", function()
        it("should import TSV with natural JSON values", function()
            local file_path = path_join(temp_dir, "test.tsv")
            file_util.writeFile(file_path, '"id"\t"value"\n"item1"\t42')

            local result, err = importer.importNaturalJSONTSVFile(file_path)
            assert.is_nil(err)
            assert.equals("id", result[1][1])
            assert.equals("item1", result[2][1])
            assert.equals(42, result[2][2])
        end)

        it("should return error for invalid JSON in cell", function()
            local file_path = path_join(temp_dir, "test.tsv")
            file_util.writeFile(file_path, '"header"\n{invalid json}')

            local result, err = importer.importNaturalJSONTSVFile(file_path)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Failed to parse cell", err)
        end)
    end)

    describe("importXMLFile", function()
        it("should import XML file", function()
            local file_path = path_join(temp_dir, "test.xml")
            local content = '<?xml version="1.0" encoding="UTF-8"?>\n<file>\n'
                .. '<header><string>id</string><string>value</string></header>\n'
                .. '<row><string>item1</string><integer>42</integer></row>\n'
                .. '</file>'
            file_util.writeFile(file_path, content)

            local result, err = importer.importXMLFile(file_path)
            assert.is_nil(err)
            assert.equals("id", result[1][1])
            assert.equals("value", result[1][2])
            assert.equals("item1", result[2][1])
            assert.equals(42, result[2][2])
        end)

        it("should return error for missing <file> tag", function()
            local file_path = path_join(temp_dir, "test.xml")
            file_util.writeFile(file_path, '<data><row>test</row></data>')

            local result, err = importer.importXMLFile(file_path)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Expected <file> tag", err)
        end)

        it("should return error for missing </file> tag", function()
            local file_path = path_join(temp_dir, "test.xml")
            file_util.writeFile(file_path, '<file><row><string>test</string></row>')

            local result, err = importer.importXMLFile(file_path)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Expected </file> tag", err)
        end)

        it("should return error for missing closing row tag", function()
            local file_path = path_join(temp_dir, "test.xml")
            local content = '<file><row><string>test</string></file>'
            file_util.writeFile(file_path, content)

            local result, err = importer.importXMLFile(file_path)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Missing closing", err)
        end)

        it("should return error for XML with missing closing tag in cell", function()
            -- Test with XML where the cell element is not properly closed
            local file_path = path_join(temp_dir, "test.xml")
            -- Missing </string> - the deserializeXML should fail
            local content = '<file><row><string>test</row></file>'
            file_util.writeFile(file_path, content)

            local result, err = importer.importXMLFile(file_path)
            -- Parser correctly returns error for malformed XML
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Failed to parse cell", err)
        end)

        it("should return error for completely malformed XML structure", function()
            local file_path = path_join(temp_dir, "test.xml")
            -- Malformed: no proper tags at all after <row>
            local content = '<file><row>not valid xml tags here</row></file>'
            file_util.writeFile(file_path, content)

            local result, err = importer.importXMLFile(file_path)
            -- Parser correctly returns error for content without valid XML tags
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Failed to parse cell", err)
        end)

        it("should return error for unknown type tags", function()
            local file_path = path_join(temp_dir, "test.xml")
            local content = '<file><row><unknown_type>test</unknown_type></row></file>'
            file_util.writeFile(file_path, content)

            local result, err = importer.importXMLFile(file_path)
            -- Parser correctly returns error for unknown XML type tags
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Failed to parse cell", err)
        end)
    end)

    describe("importMessagePackFile", function()
        it("should import MessagePack file", function()
            local file_path = path_join(temp_dir, "test.mpk")
            local data = {{1, 2, 3}, {4, 5, 6}}
            local content = serialization.serializeMessagePack(data)
            file_util.writeFile(file_path, content)

            local result, err = importer.importMessagePackFile(file_path)
            assert.is_nil(err)
            assert.are.same(data, result)
        end)

        it("should return error for invalid MessagePack data", function()
            local file_path = path_join(temp_dir, "test.mpk")
            file_util.writeFile(file_path, "\xFF\xFF\xFF\xFF")

            local result, err = importer.importMessagePackFile(file_path)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Failed to unpack MessagePack", err)
        end)
    end)

    describe("parseSQLContent", function()
        it("should parse SQL CREATE TABLE and INSERT", function()
            local sql = [[CREATE TABLE "test" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "value" BIGINT NOT NULL
);
INSERT INTO "test" ("id","value") VALUES --
('item1',42),
('item2',100)
;
]]
            local result, err = importer.parseSQLContent(sql)
            assert.is_nil(err)
            assert.equals("id", result[1][1])
            assert.equals("value", result[1][2])
            assert.equals("item1", result[2][1])
            assert.equals(42, result[2][2])
            assert.equals("item2", result[3][1])
            assert.equals(100, result[3][2])
        end)

        it("should handle NULL values", function()
            local sql = [[CREATE TABLE "test" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "value" BIGINT
);
INSERT INTO "test" ("id","value") VALUES --
('item1',NULL)
;
]]
            local result, err = importer.parseSQLContent(sql)
            assert.is_nil(err)
            assert.equals("item1", result[2][1])
            assert.is_nil(result[2][2])
        end)

        it("should read a bytes-column BLOB as its text, not MessagePack",
            function()
            -- REGRESSION, and the worst kind: an unquoted X'...' is a BYTES
            -- COLUMN (raw bytes), but it was decoded as MessagePack. X'18'
            -- came back as the NUMBER 24 and X'C3' as TRUE, with no error --
            -- silent corruption, not a visible failure.
            --
            -- Which text to rebuild depends on the declared type, which SQL
            -- alone cannot express (both are just "BLOB"), hence the
            -- tabulua-types line the exporter now writes.
            local sql = [[-- tabulua-types: {"name":"name","bitmap":"hexbytes","raw":"base64bytes"}
CREATE TABLE "test" (
  "name" TEXT NOT NULL PRIMARY KEY,
  "bitmap" BLOB NOT NULL,
  "raw" BLOB NOT NULL);
INSERT INTO "test" ("name","bitmap","raw") VALUES --
('sword',X'18',X'616263')
;
]]
            local result, err = importer.parseSQLContent(sql)
            assert.is_nil(err)
            assert.equals("sword", result[2][1])
            -- hexbytes: the hex digits, NOT the number 24
            assert.equals("18", result[2][2])
            -- base64bytes: "abc" re-encoded, not the raw bytes
            assert.equals("YWJj", result[2][3])
        end)

        it("should read a MessagePack cell, which is a QUOTED X'...' string",
            function()
            -- The other half of the same swap: an mpk cell is a STRING whose
            -- content is X'...', and it was being left as text -- which is
            -- where the "table vs string" round-trip failures came from.
            local ser = require("serde.serialization")
            local blob = ser.serializeMessagePackSQLBlob(
                {alpha = 1, beta = 2})
            local sql = table.concat({
                'CREATE TABLE "test" (',
                '  "name" TEXT NOT NULL PRIMARY KEY,',
                '  "data" TEXT NOT NULL);',
                'INSERT INTO "test" ("name","data") VALUES --',
                "('boss','" .. blob:gsub("'", "''") .. "')",
                ";",
            }, "\n")
            local result, err = importer.parseSQLContent(sql)
            assert.is_nil(err)
            assert.equals("boss", result[2][1])
            assert.are.same({alpha = 1, beta = 2}, result[2][2])
        end)

        it("should CAST int64 columns to TEXT in the SQLite query", function()
            -- lsqlite3 hands a BIGINT back as a Lua NUMBER, which on LuaJIT is
            -- a double: an id past 2^53 would be rounded on the way OUT of the
            -- database, after being stored exactly. Neither environment this
            -- project is developed in has lsqlite3, so the query builder is
            -- the part of that path that can still be tested here.
            local columns = {"name", "catalogId", "price"}
            local types = {name = "name", catalogId = "int64", price = "gold"}
            assert.equals(
                'SELECT "name", CAST("catalogId" AS TEXT) AS "catalogId", '
                    .. '"price" FROM "Item"',
                importer.buildInt64SafeSelect("Item", columns, types))
            -- An optional int64 is still an int64
            assert.equals(
                'SELECT CAST("catalogId" AS TEXT) AS "catalogId" FROM "Item"',
                importer.buildInt64SafeSelect("Item", {"catalogId"},
                    {catalogId = "int64|nil"}))
            -- A file with no type line (an older export) keeps the plain query
            assert.equals('SELECT * FROM "Item"',
                importer.buildInt64SafeSelect("Item", columns, nil))
        end)

        it("should read a BIGINT column from its digits, not tonumber",
            function()
            -- tonumber("9007199254740993") is ALREADY rounded on LuaJIT, where
            -- every number is a double, so the box would be built from a value
            -- the file never contained. The digits are read as text instead,
            -- which is exact on every runtime.
            local int64 = require("util.int64")
            local sql = table.concat({
                '-- tabulua-types: {"name":"name","catalogId":"int64"}',
                'CREATE TABLE "test" (',
                '  "name" TEXT NOT NULL PRIMARY KEY,',
                '  "catalogId" BIGINT NOT NULL);',
                'INSERT INTO "test" ("name","catalogId") VALUES --',
                "('ironSword',9007199254740993),",
                "('oakShield',-9223372036854775808)",
                ";",
            }, "\n")
            local result, err = importer.parseSQLContent(sql)
            assert.is_nil(err)
            assert.is_true(int64.is(result[2][2]))
            assert.equals("9007199254740993", int64.tostring(result[2][2]))
            assert.equals("-9223372036854775808", int64.tostring(result[3][2]))
        end)

        it("should leave a plain integer column a number", function()
            -- Only a column the type line CALLS an int64 is boxed. Without
            -- that, a BIGINT-looking literal is just a number, as before.
            local int64 = require("util.int64")
            local sql = table.concat({
                '-- tabulua-types: {"name":"name","price":"gold"}',
                'CREATE TABLE "test" (',
                '  "name" TEXT NOT NULL PRIMARY KEY,',
                '  "price" INTEGER NOT NULL);',
                'INSERT INTO "test" ("name","price") VALUES --',
                "('ironSword',150)",
                ";",
            }, "\n")
            local result, err = importer.parseSQLContent(sql)
            assert.is_nil(err)
            assert.is_false(int64.is(result[2][2]))
            assert.equals(150, result[2][2])
        end)

        it("should decode an XML table cell, not leave it as text", function()
            -- REGRESSION: deserializeXML used to return (value, POSITION, err),
            -- so passed straight in as the table deserializer the position was
            -- read as an error and the cell fell back to its undecoded text --
            -- EVERY XML table cell in a sql-xml export imported as a string.
            -- It now returns (value, err, position) like every other
            -- deserializer, so it can be used directly.
            local xmlDeserializer = require("serde.deserialization").deserializeXML
            local sql = [[CREATE TABLE "test" (
  "name" TEXT NOT NULL PRIMARY KEY,
  "tags" TEXT NOT NULL);
INSERT INTO "test" ("name","tags") VALUES --
('sword','<table><string>weapon</string><string>melee</string></table>')
;
]]
            local result, err = importer.parseSQLContent(sql, xmlDeserializer)
            assert.is_nil(err)
            assert.equals("sword", result[2][1])
            assert.are.same({"weapon", "melee"}, result[2][2])
        end)

        it("should handle escaped quotes in strings", function()
            local sql = [[CREATE TABLE "test" (
  "name" TEXT NOT NULL PRIMARY KEY
);
INSERT INTO "test" ("name") VALUES --
('Hero''s Shield')
;
]]
            local result, err = importer.parseSQLContent(sql)
            assert.is_nil(err)
            assert.equals("Hero's Shield", result[2][1])
        end)

        it("should handle empty tables", function()
            local sql = [[CREATE TABLE "test" (
  "id" TEXT NOT NULL PRIMARY KEY
)
--]]
            local result, err = importer.parseSQLContent(sql)
            assert.is_nil(err)
            assert.equals(1, #result)  -- Only header row
            assert.equals("id", result[1][1])
        end)

        it("should return error for missing CREATE TABLE", function()
            local sql = [[INSERT INTO "test" VALUES ('a',1);]]
            local result, err = importer.parseSQLContent(sql)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Could not find CREATE TABLE", err)
        end)

        it("should return error for CREATE TABLE without columns", function()
            local sql = [[CREATE TABLE "test" ()]]
            local result, err = importer.parseSQLContent(sql)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Could not extract column names", err)
        end)

        it("should return error for unmatched parenthesis in VALUES", function()
            local sql = [[CREATE TABLE "test" (
  "id" TEXT NOT NULL PRIMARY KEY
);
INSERT INTO "test" ("id") VALUES --
('unclosed
;
]]
            local result, err = importer.parseSQLContent(sql)
            assert.is_nil(result)
            assert.is_not_nil(err)
            assert.matches("Unmatched parenthesis", err)
        end)

        it("should return error for unterminated BLOB literal", function()
            -- Note: An unterminated BLOB X'... without closing quote causes the
            -- string parsing to continue until it finds a quote or hits unmatched
            -- parenthesis. The "Unmatched parenthesis" error is triggered first
            -- because the parser counts parens while looking for value boundaries.
            local sql = [[CREATE TABLE "test" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "data" BLOB
);
INSERT INTO "test" ("id","data") VALUES --
('item1',X'48656C6C6F)
;
]]
            local result, err = importer.parseSQLContent(sql)
            assert.is_nil(result)
            assert.is_not_nil(err)
            -- The parser encounters unmatched parenthesis before detecting BLOB issue
            assert.matches("Unmatched parenthesis", err)
        end)
    end)

    describe("importFile (auto-detect)", function()
        it("should detect and import .lua files", function()
            local file_path = path_join(temp_dir, "test.lua")
            file_util.writeFile(file_path, "return {{1,2,3}}")

            local result, err = importer.importFile(file_path)
            assert.is_nil(err)
            assert.are.same({{1, 2, 3}}, result)
        end)

        it("should detect and import .json files", function()
            local file_path = path_join(temp_dir, "test.json")
            file_util.writeFile(file_path, '[[1,2,3]]')

            local result, err = importer.importFile(file_path)
            assert.is_nil(err)
            assert.are.same({{1, 2, 3}}, result)
        end)

        it("should detect and import .mpk files", function()
            local file_path = path_join(temp_dir, "test.mpk")
            local data = {{1, 2, 3}}
            file_util.writeFile(file_path, serialization.serializeMessagePack(data))

            local result, err = importer.importFile(file_path)
            assert.is_nil(err)
            assert.are.same(data, result)
        end)

        it("should use data format hint for TSV files", function()
            local file_path = path_join(temp_dir, "test.tsv")
            file_util.writeFile(file_path, '"header"\n{"integer":"42"}')

            local result, err = importer.importFile(file_path, "json-typed")
            assert.is_nil(err)
            assert.equals(42, result[2][1])
        end)

        it("should return error for unknown extension", function()
            local file_path = path_join(temp_dir, "test.unknown")
            file_util.writeFile(file_path, "data")

            local result, err = importer.importFile(file_path)
            assert.is_nil(result)
            assert.is_not_nil(err)
        end)
    end)

    describe("module API", function()
        it("should have a tostring representation", function()
            local str = tostring(importer)
            assert.is_string(str)
            assert.matches("^importer version %d+%.%d+%.%d+$", str)
        end)

        it("should support callable API", function()
            local version = importer("version")
            assert.is_not_nil(version)
        end)

        it("should error on unknown operation", function()
            assert.has_error(function()
                importer("nonexistent")
            end, "Unknown operation: nonexistent")
        end)
    end)
end)
