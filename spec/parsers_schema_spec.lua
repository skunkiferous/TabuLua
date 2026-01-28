-- parsers_schema_spec.lua
-- Tests for schema export functionality

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each

local parsers = require("parsers")
local registerEnumParser = parsers.registerEnumParser
local error_reporting = require("error_reporting")

-- Returns a "badVal" object that store errors in the given table
local function mockBadVal(log_messages)
    local log = function(_self, msg) table.insert(log_messages, msg) end
    local badVal = error_reporting.badValGen(log)
    badVal.source_name = "test"
    badVal.line_no = 1
    return badVal
end

describe("parsers - schema export", function()

    describe("getSchemaColumns", function()
        it("should return column definitions", function()
            local columns = parsers.getSchemaColumns()
            assert.is_table(columns)
            assert.is_true(#columns > 0)

            -- Check that required columns exist
            local columnNames = {}
            for _, col in ipairs(columns) do
                columnNames[col.name] = true
                -- Each column should have name, type, and description
                assert.is_string(col.name)
                assert.is_string(col.type)
                assert.is_string(col.description)
            end

            -- Verify expected columns are present
            assert.is_true(columnNames["name"], "name column should exist")
            assert.is_true(columnNames["definition"], "definition column should exist")
            assert.is_true(columnNames["kind"], "kind column should exist")
            assert.is_true(columnNames["parent"], "parent column should exist")
            assert.is_true(columnNames["is_builtin"], "is_builtin column should exist")
            assert.is_true(columnNames["min"], "min column should exist")
            assert.is_true(columnNames["max"], "max column should exist")
            assert.is_true(columnNames["regex"], "regex column should exist")
            assert.is_true(columnNames["enum_labels"], "enum_labels column should exist")
        end)
    end)

    describe("getSchemaColumnNames", function()
        it("should return column names in order", function()
            local names = parsers.getSchemaColumnNames()
            assert.is_table(names)
            assert.is_true(#names > 0)

            -- Check that all names are strings
            for _, name in ipairs(names) do
                assert.is_string(name)
            end

            -- Should match the columns from getSchemaColumns
            local columns = parsers.getSchemaColumns()
            assert.equals(#columns, #names)

            for i, col in ipairs(columns) do
                assert.equals(col.name, names[i])
            end
        end)
    end)

    describe("getSchemaModel", function()
        local log_messages
        local badVal

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
        end)

        it("should return an array of records", function()
            local model = parsers.getSchemaModel()
            assert.is_table(model)
            assert.is_true(#model > 0)

            -- Each record should have the expected fields
            for _, record in ipairs(model) do
                assert.is_string(record.name)
                assert.is_string(record.definition)
                assert.is_string(record.kind)
                assert.is_string(record.parent)  -- can be empty string
                assert.is_string(record.is_builtin)
                assert.is_string(record.min)  -- can be empty string
                assert.is_string(record.max)  -- can be empty string
                assert.is_string(record.regex)  -- can be empty string
                assert.is_string(record.enum_labels)  -- can be empty string
            end
        end)

        it("should include built-in types", function()
            local model = parsers.getSchemaModel()
            local typesByName = {}
            for _, record in ipairs(model) do
                typesByName[record.name] = record
            end

            -- Check that basic built-in types are present
            assert.is_not_nil(typesByName["string"])
            assert.is_not_nil(typesByName["number"])
            assert.is_not_nil(typesByName["boolean"])
            assert.is_not_nil(typesByName["integer"])
            assert.is_not_nil(typesByName["nil"])
            assert.is_not_nil(typesByName["table"])

            -- Check that built-in types are marked as such
            assert.equals("true", typesByName["string"].is_builtin)
            assert.equals("true", typesByName["number"].is_builtin)
            assert.equals("true", typesByName["boolean"].is_builtin)
        end)

        it("should include type kinds", function()
            local model = parsers.getSchemaModel()
            local typesByName = {}
            for _, record in ipairs(model) do
                typesByName[record.name] = record
            end

            -- Check kinds for basic types
            assert.equals("name", typesByName["string"].kind)
            assert.equals("name", typesByName["number"].kind)
            assert.equals("name", typesByName["boolean"].kind)
        end)

        it("should include array parsers when created via alias", function()
            -- Register a test alias - this creates/uses a {string} parser
            assert(parsers.registerAlias(badVal, "SchemaTestAlias", "{string}"))

            local model = parsers.getSchemaModel()
            local typesByName = {}
            for _, record in ipairs(model) do
                typesByName[record.name] = record
            end

            -- The schema exports parsers, not aliases directly
            -- So we should find the {string} parser
            assert.is_not_nil(typesByName["{string}"])
            assert.equals("{string}", typesByName["{string}"].definition)
            assert.equals("array", typesByName["{string}"].kind)
        end)

        it("should include registered enums with labels", function()
            -- Register a test enum
            assert(registerEnumParser(badVal, {"One", "Two", "Three"}, "SchemaTestEnumNew"))

            local model = parsers.getSchemaModel()

            -- Find the enum by looking for its internal spec pattern
            local enumRecord = nil
            for _, record in ipairs(model) do
                if record.kind == "enum" and record.enum_labels == "one|three|two" then
                    enumRecord = record
                    break
                end
            end

            -- Check that the enum is present with correct labels
            assert.is_not_nil(enumRecord, "Enum with labels 'one|three|two' should exist")
            assert.equals("enum", enumRecord.kind)
            assert.equals("one|three|two", enumRecord.enum_labels)
        end)

        it("should include number constraints", function()
            -- Register a restricted number type - this creates a parser with generated name
            local parser, parserName = parsers.restrictNumber(badVal, "integer", 0, 100)
            assert.is_not_nil(parser)
            assert.is_not_nil(parserName)

            local model = parsers.getSchemaModel()
            local typesByName = {}
            for _, record in ipairs(model) do
                typesByName[record.name] = record
            end

            -- Check that the restricted type has constraints using the generated name
            assert.is_not_nil(typesByName[parserName], "Parser " .. parserName .. " should exist")
            -- min=0 is omitted as default
            assert.equals("100", typesByName[parserName].max)
        end)

        it("should include string constraints", function()
            -- Register a restricted string type - this creates a parser with generated name
            local parser, parserName = parsers.restrictString(badVal, "string", 1, 50)
            assert.is_not_nil(parser)
            assert.is_not_nil(parserName)

            local model = parsers.getSchemaModel()
            local typesByName = {}
            for _, record in ipairs(model) do
                typesByName[record.name] = record
            end

            -- Check that the restricted type has constraints using the generated name
            assert.is_not_nil(typesByName[parserName], "Parser " .. parserName .. " should exist")
            assert.equals("1", typesByName[parserName].min)
            assert.equals("50", typesByName[parserName].max)
        end)

        it("should include parent types for extended types", function()
            -- Create a type that extends another
            parsers.restrictWithValidator(badVal, "string", "myString", function(_) return true end)

            local model = parsers.getSchemaModel()
            local typesByName = {}
            for _, record in ipairs(model) do
                typesByName[record.name] = record
            end

            -- Check that the extended type has a parent
            assert.is_not_nil(typesByName["myString"])
            assert.equals("string", typesByName["myString"].parent)
        end)

        it("should handle complex type definitions", function()
            -- Register some complex types - these create parsers with the type spec as name
            assert(parsers.registerAlias(badVal, "SchemaTestRecord", "{name:string,age:number}"))
            assert(parsers.registerAlias(badVal, "SchemaTestMap", "{string:number}"))
            assert(parsers.registerAlias(badVal, "SchemaTestTuple", "{string,number,boolean}"))

            local model = parsers.getSchemaModel()
            local typesByName = {}
            for _, record in ipairs(model) do
                typesByName[record.name] = record
            end

            -- Check record type - parser name is the normalized type spec
            local recordSpec = "{age:number,name:string}"  -- fields sorted alphabetically
            assert.is_not_nil(typesByName[recordSpec], "Record parser should exist")
            assert.equals("record", typesByName[recordSpec].kind)
            assert.equals(recordSpec, typesByName[recordSpec].definition)

            -- Check map type
            local mapSpec = "{string:number}"
            assert.is_not_nil(typesByName[mapSpec], "Map parser should exist")
            assert.equals("map", typesByName[mapSpec].kind)

            -- Check tuple type
            local tupleSpec = "{string,number,boolean}"
            assert.is_not_nil(typesByName[tupleSpec], "Tuple parser should exist")
            assert.equals("tuple", typesByName[tupleSpec].kind)
        end)

        it("should sort types by name", function()
            local model = parsers.getSchemaModel()

            -- Check that the model is sorted by name
            for i = 2, #model do
                assert.is_true(model[i-1].name <= model[i].name,
                    string.format("Types should be sorted: %s should come before %s",
                        model[i-1].name, model[i].name))
            end
        end)

        it("should include aliases with their names", function()
            -- Register a named type alias (like file types would be registered)
            assert(parsers.registerAlias(badVal, "SchemaTestFileType",
                "{name:string,value:number}"))

            local model = parsers.getSchemaModel()
            local typesByName = {}
            for _, record in ipairs(model) do
                typesByName[record.name] = record
            end

            -- The alias name should appear in the schema
            assert.is_not_nil(typesByName["SchemaTestFileType"],
                "Alias name 'SchemaTestFileType' should appear in schema")
            assert.equals("{name:string,value:number}",
                typesByName["SchemaTestFileType"].definition)
            assert.equals("record", typesByName["SchemaTestFileType"].kind)
            assert.equals("false", typesByName["SchemaTestFileType"].is_builtin)
        end)

        it("should include multiple aliases to different record types", function()
            -- Register multiple aliases like different file types
            assert(parsers.registerAlias(badVal, "SchemaTestType1",
                "{id:string,count:integer}"))
            assert(parsers.registerAlias(badVal, "SchemaTestType2",
                "{key:string,active:boolean}"))

            local model = parsers.getSchemaModel()
            local typesByName = {}
            for _, record in ipairs(model) do
                typesByName[record.name] = record
            end

            -- Both aliases should be in the schema
            assert.is_not_nil(typesByName["SchemaTestType1"])
            assert.is_not_nil(typesByName["SchemaTestType2"])

            -- Each should have the correct definition
            assert.equals("{count:integer,id:string}",
                typesByName["SchemaTestType1"].definition)
            assert.equals("{active:boolean,key:string}",
                typesByName["SchemaTestType2"].definition)
        end)

        it("should not duplicate types when alias resolves to existing parser", function()
            -- When an alias is registered, both the alias name and the resolved
            -- type spec may appear, but not duplicated
            -- Use a proper record type (with multiple fields to disambiguate from map)
            assert(parsers.registerAlias(badVal, "SchemaTestUnique",
                "{id:string,unique:boolean}"))

            local model = parsers.getSchemaModel()
            local countUnique = 0
            for _, record in ipairs(model) do
                if record.name == "SchemaTestUnique" then
                    countUnique = countUnique + 1
                end
            end

            -- The alias should appear exactly once
            assert.equals(1, countUnique)
        end)
    end)
end)
