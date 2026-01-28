-- parsers.lua
-- Main entry point for the new modular parsers implementation
-- Assembles the public API and initializes all submodules

local read_only = require("read_only")
local readOnly = read_only.readOnly
local readOnlyTuple = read_only.readOnlyTuple

-- Load all submodules
local state = require("parsers.state")
local utils = require("parsers.utils")
local lpeg_parser = require("parsers.lpeg_parser")
local generators = require("parsers.generators")
local type_parsing = require("parsers.type_parsing")
local introspection = require("parsers.introspection")
local registration = require("parsers.registration")
local builtin = require("parsers.builtin")
local schema_export = require("parsers.schema_export")

-- ============================================================
-- Wire up forward references
-- ============================================================

-- Set up state.refs
state.refs.extendsOrRestrict = introspection.extendsOrRestrict
state.refs.getTypeKind = introspection.getTypeKind
state.refs.tupleFieldTypes = introspection.tupleFieldTypes
state.refs.parse_type = type_parsing.parse_type
state.refs.parseType = type_parsing.parseType

-- Set up introspection references
introspection.setParseType(type_parsing.parse_type, type_parsing.parseType)

-- Set up registration references
registration.setReferences(type_parsing.parse_type, type_parsing.parseType, introspection)

-- Set up builtin references
builtin.setReferences(type_parsing.parseType, registration)

-- Set up schema_export references
schema_export.setReferences(introspection)

-- ============================================================
-- Initialize built-in parsers
-- ============================================================

-- Register all derived parsers (comment, name, identifier, etc.)
builtin.registerDerivedParsers()

-- We are now done with setup, so we cannot register types that are keywords anymore.
state.settingUp = false

state.logger:info('Registered core parsers: '..table.concat(introspection.getRegisteredParsers(), ', '))

-- Populate BUILT_IN with all parsers registered during setup
for name in pairs(state.PARSERS) do
    state.BUILT_IN[name] = true
end
state.BUILT_IN = readOnly(state.BUILT_IN)

-- ============================================================
-- Public API
-- ============================================================

-- Provides a tostring() function for the API
local function apiToString()
    return state.NAME .. " version " .. tostring(state.VERSION)
end

-- The public, versioned, API of this module
local API = {
    -- Type introspection
    arrayElementType = introspection.arrayElementType,
    enumLabels = introspection.enumLabels,
    extendsOrRestrict = introspection.extendsOrRestrict,
    getRegisteredParsers = introspection.getRegisteredParsers,
    getTypeKind = introspection.getTypeKind,
    isBuiltInType = introspection.isBuiltInType,
    isNeverTable = introspection.isNeverTable,
    mapKVType = introspection.mapKVType,
    recordFieldNames = introspection.recordFieldNames,
    recordFieldTypes = introspection.recordFieldTypes,
    recordOptionalFieldNames = introspection.recordOptionalFieldNames,
    tupleFieldTypes = introspection.tupleFieldTypes,
    typeParent = introspection.typeParent,
    unionTypes = introspection.unionTypes,

    -- Schema export (for external tooling)
    getSchemaModel = schema_export.getSchemaModel,
    getSchemaColumns = schema_export.getSchemaColumns,
    getSchemaColumnNames = schema_export.getSchemaColumnNames,

    -- Type parsing
    parseType = type_parsing.parseType,

    -- Type registration
    registerAlias = registration.registerAlias,
    registerEnumParser = registration.registerEnumParser,
    restrictEnum = registration.restrictEnum,
    restrictNumber = registration.restrictNumber,
    restrictString = registration.restrictString,
    restrictUnion = registration.restrictUnion,
    restrictWithValidator = registration.restrictWithValidator,

    -- Utilities
    createDefaultValue = registration.createDefaultValue,
    findParserSpec = generators.findParserSpec,
    getComparator = registration.getComparator,
    getVersion = utils.getVersion,
    readOnlyTuple = readOnlyTuple,

    -- "Internal" API, only exported so it can be tested
    -- Do not use directly; might change in the future
    internal = {
        markdownValidator = builtin.markdownValidator,
        type_parser = lpeg_parser.type_parser,
        parsedTypeSpecToStr = lpeg_parser.parsedTypeSpecToStr,
        parse_type = type_parsing.parse_type,
        type_parser_partial = lpeg_parser.type_parser_partial,
    },
}

-- Enables the module to be called as a function
local function apiCall(_, operation, ...)
    if operation == "version" then
        return state.VERSION
    elseif API[operation] then
        return API[operation](...)
    else
        error("Unknown operation: " .. tostring(operation), 2)
    end
end

return readOnly(API, {__tostring = apiToString, __call = apiCall, __type = state.NAME})
