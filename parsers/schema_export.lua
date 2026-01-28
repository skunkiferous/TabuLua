-- parsers/schema_export.lua
-- Exports all registered type definitions as a schema model
-- This enables external tools (in other languages) to understand the type system

local state = require("parsers.state")
local lpeg_parser = require("parsers.lpeg_parser")

local table_utils = require("table_utils")
local keys = table_utils.keys

local M = {}

-- Forward declarations (set by init/parsers.lua)
local introspection

-- Set references (called by parsers.lua after all modules load)
function M.setReferences(intro)
    introspection = intro
end

--[[
    Schema Model Column Definitions:

    name        - The type name or alias used to reference this type
    definition  - The full type specification string (parseable by TypeSpec.g4)
    kind        - One of: name, array, map, tuple, record, union, enum, table
    parent      - Parent type if this extends/restricts another type
    is_builtin  - "true" if this is a built-in type, "false" otherwise
    min         - For numbers: minimum value; for strings: minimum length
    max         - For numbers: maximum value; for strings: maximum length
    regex       - For strings: validation regex pattern (if any)
    enum_labels - For enums: pipe-separated list of valid labels

    The 'definition' column can be parsed using the TypeSpec.g4 ANTLR grammar
    to build a full AST representation of the type structure.
]]

-- Returns the kind of a type, handling special cases
local function getKind(type_spec)
    -- Handle obvious special cases first
    if type_spec == "{}" or type_spec == "table" then
        return "table"
    end

    local parsed = lpeg_parser.type_parser(type_spec)
    if not parsed then
        return nil
    end

    -- Check for enum (map with 'enum' key)
    if parsed.tag == "map" then
        for key_type in pairs(parsed.value) do
            local kt = lpeg_parser.parsedTypeSpecToStr(key_type)
            if kt == "enum" then
                return "enum"
            end
            break
        end
    end

    return parsed.tag
end

-- Extracts enum labels from a type specification
local function getEnumLabels(type_spec)
    if not introspection then
        return nil
    end
    local labels = introspection.enumLabels(type_spec)
    if labels then
        table.sort(labels)
        return table.concat(labels, "|")
    end
    return nil
end

-- Resolves the "canonical" definition for a type
local function getDefinition(name)
    -- Check if it's an alias
    local alias = state.ALIASES[name]
    if alias then
        return alias
    end
    -- For non-aliases, the name itself is the definition
    -- (for primitives, complex types like {string}, unions, etc.)
    return name
end

-- Structural kinds that are implicit from the 'kind' column
local STRUCTURAL_KINDS = {
    array = true, map = true, tuple = true,
    record = true, union = true, table = true, enum = true
}

-- Gets the parent type for inheritance/extension relationships
local function getParent(name)
    -- Check EXTENDS first (explicit inheritance)
    local parent = state.EXTENDS[name]
    if parent then
        return parent
    end

    -- Check if it's an alias (alias "parent" is the resolved type)
    local alias = state.ALIASES[name]
    if alias and alias ~= name then
        -- For aliases, we don't report a parent in the same way
        -- The definition already shows what it aliases to
        return nil
    end

    -- For complex types, check structural parent via introspection
    -- introspection is set via setReferences() before this is called
    local introParent = introspection and introspection.typeParent(name)
    if introParent and introParent ~= name and not STRUCTURAL_KINDS[introParent] then
        return introParent
    end

    return nil
end

-- Helper to convert constraint value to string, handling nil and infinity
local function constraintToString(value, isMin)
    if value == nil then
        return ""
    end
    if isMin and value == -math.huge then
        return ""
    end
    if not isMin and value == math.huge then
        return ""
    end
    if isMin and value == 0 then
        return ""  -- 0 is default minimum for strings
    end
    return tostring(value)
end

-- Collects all type information into a schema model
-- Returns an array of records, suitable for TSV export
function M.getSchemaModel()
    local model = {}

    -- Collect all type names: parsers + aliases
    local allNames = {}
    local seen = {}

    -- Add all parser names
    local allParsers = keys(state.PARSERS)
    if allParsers then
        for _, name in ipairs(allParsers) do
            if not seen[name] then
                allNames[#allNames + 1] = name
                seen[name] = true
            end
        end
    end

    -- Add all alias names (these are named types that resolve to type specs)
    local allAliases = keys(state.ALIASES)
    if allAliases then
        for _, name in ipairs(allAliases) do
            if not seen[name] then
                allNames[#allNames + 1] = name
                seen[name] = true
            end
        end
    end

    table.sort(allNames)

    for _, name in ipairs(allNames) do
        local definition = getDefinition(name)
        local kind = getKind(definition) or "name"
        local parent = getParent(name)
        local isBuiltin = state.BUILT_IN[name] or false

        -- Get constraints (numeric or string - mutually exclusive)
        local minVal, maxVal
        local regex = state.STR_REGEX[name]

        local numLimits = state.NUMBER_LIMITS[name]
        if numLimits then
            minVal = numLimits.min
            maxVal = numLimits.max
        else
            -- Check string constraints
            minVal = state.STR_MIN_LEN[name]
            maxVal = state.STR_MAX_LEN[name]
        end

        -- Get enum labels if applicable
        local enumLabels = (kind == "enum") and getEnumLabels(definition) or nil

        -- Build the record
        local record = {
            name = name,
            definition = definition,
            kind = kind,
            parent = parent or "",
            is_builtin = isBuiltin and "true" or "false",
            min = constraintToString(minVal, true),
            max = constraintToString(maxVal, false),
            regex = regex or "",
            enum_labels = enumLabels or "",
        }

        model[#model + 1] = record
    end

    return model
end

-- Returns the column definitions for the schema model
-- This is useful for generating headers and understanding the structure
function M.getSchemaColumns()
    return {
        { name = "name", type = "name", description = "Type name or alias" },
        { name = "definition", type = "type_spec", description = "Full type specification" },
        { name = "kind", type = "{enum:name|array|map|tuple|record|union|enum|table}",
            description = "Type category" },
        { name = "parent", type = "type_spec|nil", description = "Parent type if extends another" },
        { name = "is_builtin", type = "boolean", description = "Whether type is built-in" },
        { name = "min", type = "number|nil", description = "Minimum value/length constraint" },
        { name = "max", type = "number|nil", description = "Maximum value/length constraint" },
        { name = "regex", type = "string|nil", description = "Regex validation pattern" },
        { name = "enum_labels", type = "string|nil", description = "Pipe-separated enum labels" },
    }
end

-- Returns just the column names in order (for TSV header)
function M.getSchemaColumnNames()
    local columns = M.getSchemaColumns()
    local names = {}
    for i, col in ipairs(columns) do
        names[i] = col.name
    end
    return names
end

return M
