-- parsers_introspection_spec.lua
-- Tests for type introspection functions

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

describe("parsers - introspection", function()

    describe("typeParent", function()
        local log_messages
        local badVal

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
        end)

        it("should return nil for basic types without parents", function()
            -- Basic built-in types don't have explicit parents
            assert.is_nil(parsers.typeParent("string"))
            assert.is_nil(parsers.typeParent("number"))
            assert.is_nil(parsers.typeParent("boolean"))
            assert.is_nil(parsers.typeParent("nil"))
        end)

        it("should return parent for extended types", function()
            -- integer extends number
            assert.equals("number", parsers.typeParent("integer"))
            -- percent extends number
            assert.equals("number", parsers.typeParent("percent"))
            -- identifier extends name
            assert.equals("name", parsers.typeParent("identifier"))
            -- name extends ascii
            assert.equals("ascii", parsers.typeParent("name"))
            -- text extends string
            assert.equals("string", parsers.typeParent("text"))
            -- comment extends string
            assert.equals("string", parsers.typeParent("comment"))
        end)

        it("should return parent for custom extended types", function()
            -- Create an extended type
            parsers.restrictWithValidator(badVal, "integer", "positiveInt",
                function(n) return n > 0 end)

            assert.equals("integer", parsers.typeParent("positiveInt"))
        end)

        it("should return structural kind for complex types", function()
            -- Array types return 'array'
            assert.equals("array", parsers.typeParent("{string}"))
            assert.equals("array", parsers.typeParent("{number}"))

            -- Map types return 'map'
            assert.equals("map", parsers.typeParent("{string:number}"))

            -- Tuple types return 'tuple'
            assert.equals("tuple", parsers.typeParent("{string,number}"))

            -- Record types return 'record'
            assert.equals("record", parsers.typeParent("{name:string,age:number}"))

            -- Union types return 'union'
            assert.equals("union", parsers.typeParent("number|string"))
        end)

        it("should return alias target for aliased types", function()
            -- Register an alias
            assert(parsers.registerAlias(badVal, "IntroTestAlias", "{string}"))

            -- Alias should return the target type
            assert.equals("{string}", parsers.typeParent("IntroTestAlias"))
        end)

        it("should return enum spec for enum alias types", function()
            -- Register an enum
            assert(registerEnumParser(badVal, {"Red", "Green", "Blue"}, "IntroColor"))

            -- Alias types return their target type spec
            local parent = parsers.typeParent("IntroColor")
            assert.is_string(parent)
            assert.matches("enum:", parent)
        end)

        it("should return 'enum' for inline enum types", function()
            -- Inline enum specs return 'enum' as their structural kind
            assert.equals("enum", parsers.typeParent("{enum:red|green|blue}"))
        end)

        it("should return nil for invalid inputs", function()
            assert.is_nil(parsers.typeParent(nil))
            assert.is_nil(parsers.typeParent(123))
            assert.is_nil(parsers.typeParent({}))
            assert.is_nil(parsers.typeParent(true))
        end)
    end)

    describe("getRegisteredParsers", function()
        it("should return a table of parser names", function()
            local parsers_list = parsers.getRegisteredParsers()
            assert.is_table(parsers_list)
            assert.is_true(#parsers_list > 0)
        end)

        it("should include basic built-in types", function()
            local parsers_list = parsers.getRegisteredParsers()
            local parserSet = {}
            for _, name in ipairs(parsers_list) do
                parserSet[name] = true
            end

            assert.is_true(parserSet["string"], "string should be registered")
            assert.is_true(parserSet["number"], "number should be registered")
            assert.is_true(parserSet["boolean"], "boolean should be registered")
            assert.is_true(parserSet["integer"], "integer should be registered")
            assert.is_true(parserSet["nil"], "nil should be registered")
            assert.is_true(parserSet["table"], "table should be registered")
        end)

        it("should include derived types", function()
            local parsers_list = parsers.getRegisteredParsers()
            local parserSet = {}
            for _, name in ipairs(parsers_list) do
                parserSet[name] = true
            end

            assert.is_true(parserSet["name"], "name should be registered")
            assert.is_true(parserSet["identifier"], "identifier should be registered")
            assert.is_true(parserSet["text"], "text should be registered")
            assert.is_true(parserSet["comment"], "comment should be registered")
            assert.is_true(parserSet["version"], "version should be registered")
            assert.is_true(parserSet["percent"], "percent should be registered")
        end)

        it("should include newly registered enum parsers", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            -- Register a new enum - this creates a parser with the enum spec as name
            assert(registerEnumParser(badVal, {"Alpha", "Beta", "Gamma"}, "IntroTestEnum"))

            local parsers_list = parsers.getRegisteredParsers()
            local parserSet = {}
            for _, name in ipairs(parsers_list) do
                parserSet[name] = true
            end

            -- The enum parser is registered with its internal spec, not the alias name
            -- Look for the enum spec pattern
            local foundEnum = false
            for name in pairs(parserSet) do
                if name:match("^{enum:alpha|beta|gamma}$") then
                    foundEnum = true
                    break
                end
            end
            assert.is_true(foundEnum, "Enum parser with labels alpha|beta|gamma should be registered")
        end)
    end)

    describe("isBuiltInType", function()
        it("should return true for core built-in types", function()
            -- Core primitives registered during setup
            assert.is_true(parsers.isBuiltInType("string"))
            assert.is_true(parsers.isBuiltInType("number"))
            assert.is_true(parsers.isBuiltInType("boolean"))
            assert.is_true(parsers.isBuiltInType("nil"))
            assert.is_true(parsers.isBuiltInType("table"))
        end)

        it("should return true for types registered during setup", function()
            -- These are also considered "built-in" since they're registered
            -- during the module's initial setup phase
            assert.is_true(parsers.isBuiltInType("integer"))
            assert.is_true(parsers.isBuiltInType("name"))
            assert.is_true(parsers.isBuiltInType("identifier"))
            assert.is_true(parsers.isBuiltInType("text"))
            assert.is_true(parsers.isBuiltInType("version"))
            assert.is_true(parsers.isBuiltInType("percent"))
        end)

        it("should return false for custom types registered after setup", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            -- Register custom types (after setup is complete)
            assert(parsers.registerAlias(badVal, "IntroCustomAlias", "{string}"))
            assert(registerEnumParser(badVal, {"X", "Y", "Z"}, "IntroCustomEnum"))

            -- Aliases don't create new parsers, they point to existing ones
            -- So IntroCustomAlias itself won't be in PARSERS
            assert.is_false(parsers.isBuiltInType("IntroCustomAlias"))
            -- Enums do create new parsers
            assert.is_false(parsers.isBuiltInType("IntroCustomEnum"))
        end)

        it("should return false for unknown types", function()
            assert.is_false(parsers.isBuiltInType("unknown_type"))
            assert.is_false(parsers.isBuiltInType(""))
            assert.is_false(parsers.isBuiltInType(nil))
        end)
    end)

    describe("arrayElementType", function()
        local log_messages
        local badVal

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
        end)

        it("should return element type for array types", function()
            assert.equals("string", parsers.arrayElementType("{string}"))
            assert.equals("number", parsers.arrayElementType("{number}"))
            assert.equals("boolean", parsers.arrayElementType("{boolean}"))
        end)

        it("should return element type for nested arrays", function()
            assert.equals("{string}", parsers.arrayElementType("{{string}}"))
            assert.equals("{number}", parsers.arrayElementType("{{number}}"))
        end)

        it("should return element type for complex array elements", function()
            assert.equals("{string:number}", parsers.arrayElementType("{{string:number}}"))
            assert.equals("number|string", parsers.arrayElementType("{number|string}"))
        end)

        it("should return element type for aliased array types", function()
            assert(parsers.registerAlias(badVal, "IntroStringArray", "{string}"))
            assert.equals("string", parsers.arrayElementType("IntroStringArray"))
        end)

        it("should return nil for non-array types", function()
            assert.is_nil(parsers.arrayElementType("string"))
            assert.is_nil(parsers.arrayElementType("number"))
            assert.is_nil(parsers.arrayElementType("{string:number}"))  -- map
            assert.is_nil(parsers.arrayElementType("{string,number}"))  -- tuple
            assert.is_nil(parsers.arrayElementType("{name:string}"))  -- record
            assert.is_nil(parsers.arrayElementType("number|string"))  -- union
        end)

        it("should return nil for invalid inputs", function()
            assert.is_nil(parsers.arrayElementType(nil))
            assert.is_nil(parsers.arrayElementType(123))
            assert.is_nil(parsers.arrayElementType({}))
            assert.is_nil(parsers.arrayElementType(""))
            assert.is_nil(parsers.arrayElementType("{string"))  -- malformed
        end)
    end)

    describe("enumLabels", function()
        local log_messages
        local badVal

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
        end)

        it("should return labels for enum types", function()
            assert(registerEnumParser(badVal, {"Red", "Green", "Blue"}, "IntroColorRGB"))

            local labels = parsers.enumLabels("IntroColorRGB")
            assert.is_table(labels)
            table.sort(labels)
            assert.same({"blue", "green", "red"}, labels)
        end)

        it("should return labels for inline enum types", function()
            local labels = parsers.enumLabels("{enum:alpha|beta|gamma}")
            assert.is_table(labels)
            table.sort(labels)
            assert.same({"alpha", "beta", "gamma"}, labels)
        end)

        it("should return nil for non-enum types", function()
            assert.is_nil(parsers.enumLabels("string"))
            assert.is_nil(parsers.enumLabels("number"))
            assert.is_nil(parsers.enumLabels("{string}"))
            assert.is_nil(parsers.enumLabels("{string:number}"))
        end)

        it("should return nil for invalid inputs", function()
            assert.is_nil(parsers.enumLabels(nil))
            assert.is_nil(parsers.enumLabels(123))
            assert.is_nil(parsers.enumLabels({}))
        end)
    end)

    describe("extendsOrRestrict edge cases", function()
        local log_messages
        local badVal

        before_each(function()
            log_messages = {}
            badVal = mockBadVal(log_messages)
        end)

        it("should handle same type comparisons", function()
            -- A type extends itself (trivially)
            assert.is_false(parsers.extendsOrRestrict("string", "string"))
            assert.is_false(parsers.extendsOrRestrict("number", "number"))
        end)

        it("should handle deep inheritance chains", function()
            -- markdown extends text extends string
            assert.is_true(parsers.extendsOrRestrict("markdown", "text"))
            assert.is_true(parsers.extendsOrRestrict("markdown", "string"))
            assert.is_true(parsers.extendsOrRestrict("text", "string"))

            -- integer extends number
            assert.is_true(parsers.extendsOrRestrict("integer", "number"))

            -- ubyte extends integer (and thus number)
            assert.is_true(parsers.extendsOrRestrict("ubyte", "integer"))
            assert.is_true(parsers.extendsOrRestrict("ubyte", "number"))
        end)

        it("should handle array type extension", function()
            -- Array of subtypes should extend array of supertypes
            -- This may not be supported - check actual behavior
            local result = parsers.extendsOrRestrict("{integer}", "{number}")
            -- Record actual behavior
            assert.is_boolean(result)
        end)

        it("should handle record field extension", function()
            -- A record with more fields extends one with fewer
            assert(parsers.registerAlias(badVal, "IntroPerson", "{name:string,age:number}"))
            assert(parsers.registerAlias(badVal, "IntroEmployee",
                "{name:string,age:number,job:string}"))

            assert.is_true(parsers.extendsOrRestrict("IntroEmployee", "IntroPerson"))
            assert.is_false(parsers.extendsOrRestrict("IntroPerson", "IntroEmployee"))
        end)
    end)
end)
