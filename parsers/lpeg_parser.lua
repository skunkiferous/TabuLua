-- parsers/lpeg_parser.lua
-- LPEG-based type specification parser

local lpeg = require("lpeg")

local string_utils = require("string_utils")
local split = string_utils.split

local table_utils = require("table_utils")
local keys = table_utils.keys

local serialization = require("serialization")
local serialize = serialization.serialize

local utils = require("parsers.utils")

local M = {}

-- Returns a function that parses out a type specification (partial parsing).
-- Returns (parsed_result, rest_of_input) or (nil, nil) if parsing fails.
local function create_type_parser_partial()
    -- Basic building blocks
    local P, S, V, R = lpeg.P, lpeg.S, lpeg.V, lpeg.R
    local C, Ct, Cp = lpeg.C, lpeg.Ct, lpeg.Cp

    -- Comment and whitespace handling
    local eol = P"\n" + P"\r\n" + P"\r"
    local comment = P"#" * (1 - eol)^0 * (eol + P(-1))
    local blank = S(" \t")^0
    local space = (blank * (comment + eol + S(" \t\n\r")))^0 * blank

    -- Basic character classes
    local letter = R("az", "AZ")
    local digit = R("09")
    local id_start = letter + P"_"
    local id_part = letter + digit + P"_"

    -- Identifier and name construction
    local identifier = C(id_start * id_part^0)
    local name = (identifier * (P"." * identifier)^0) / function(...)
        local parts = {...}
        return {tag = "name", value = table.concat(parts, ".")}
    end

    -- Grammar definition (partial - does not require consuming all input)
    local grammar = P{
        "partial", -- Initial rule for partial parsing

        -- Partial match: parse type and capture position after trailing space
        partial = space * V"union" * space * Cp(),

        -- Union type is one or more base_types separated by vertical bars
        union = V"base_type" * (space * P"|" * space * V"base_type")^0 /
            function(first, ...)
                if not ... then
                    return first -- If no additional types, return the single type
                end
                local types = {first, ...}
                return {tag = "union", value = types}
            end,

        -- Base type is a name, array/tuple type, map/record type, or empty_table
        base_type = space * (V"name" + V"empty_table" + V"array_or_tuple" + V"map_or_record") * space,

        -- Name is just our previously defined name pattern
        name = name,

        -- Empty table is just {} with no content
        empty_table = P"{" * space * P"}" / function()
            return {tag = "table", value = nil}
        end,

        -- Array/tuple type is a comma-separated list of types in braces
        array_or_tuple = P"{" * space * V"type_list" * space * P"}" /
            function(list)
                if #list == 1 then
                    return {tag = "array", value = list[1]}
                else
                    return {tag = "tuple", value = list}
                end
            end,

        -- A key-value pair for maps and records
        key_value_pair = V"union" * space * P":" * space * V"union" /
            function(key_type, value_type)
                return {key = key_type, value = value_type}
            end,

        -- List of key-value pairs
        key_value_list = Ct(V"key_value_pair" * (space * P"," * space * V"key_value_pair")^0),

        -- Map or record type based on number of key-value pairs
        map_or_record = P"{" * space * V"key_value_list" * space * P"}" /
            function(pairs)
                if #pairs == 1 then
                    -- Single pair = map type
                    local pair = pairs[1]
                    return {tag = "map", value = {[pair.key] = pair.value}}
                else
                    -- Multiple pairs = record type
                    return {tag = "record", value = pairs}
                end
            end,

        -- List of types is one or more types separated by commas
        type_list = Ct(V"union" * (space * P"," * space * V"union")^0)
    }

    -- Create the partial matcher function
    local function matcher(input)
        local parsed, pos = grammar:match(input)
        if parsed == nil then
            return nil, nil
        end
        local rest = input:sub(pos)
        return parsed, rest
    end

    return matcher
end

-- The partial type parser instance (returns parsed_result, rest_of_input)
M.type_parser_partial = create_type_parser_partial()

-- The type parser instance (only succeeds if entire input is consumed)
M.type_parser = function(input)
    local parsed, rest = M.type_parser_partial(input)
    if parsed and rest == "" then
        return parsed
    end
    return nil
end

-- Reformat the enum labels
local function reformatEnumLabels(value_type)
    if type(value_type) == "string" then
        local set = {}
        for _, v in ipairs(split(value_type:lower(), "|")) do
            set[v] = true
        end
        return table.concat(keys(set), "|")
    end
    return value_type
end

-- Helper function for parsedTypeSpecToStr()
local function inner_convert(node, reformat_enum_labels)
    if not node.tag then
        error("Invalid node structure: missing tag: " .. serialize(node))
    end

    if node.tag == "name" then
        return node.value

    elseif node.tag == "table" then
        return "{}"

    elseif node.tag == "array" then
        return "{" .. inner_convert(node.value) .. "}"

    elseif node.tag == "tuple" then
        local parts = {}
        for _, v in ipairs(node.value) do
            table.insert(parts, inner_convert(v))
        end
        return "{" .. table.concat(parts, ",") .. "}"

    elseif node.tag == "map" then
        local key_type, value_type
        for k, v in pairs(node.value) do
            key_type = inner_convert(k)
            value_type = inner_convert(v)
            break
        end
        if key_type == "enum" and reformat_enum_labels then
            value_type = reformatEnumLabels(value_type)
        end
        return "{" .. key_type .. ":" .. value_type .. "}"

    elseif node.tag == "record" then
        local kv = {}
        for _, pair in ipairs(node.value) do
            kv[inner_convert(pair.key)] = inner_convert(pair.value)
        end
        local parts = {}
        for _, key in ipairs(keys(kv)) do
            table.insert(parts, key .. ":" .. kv[key])
        end
        return "{" .. table.concat(parts, ",") .. "}"

    elseif node.tag == "union" then
        local parts = {}
        for _, v in ipairs(node.value) do
            table.insert(parts, inner_convert(v))
        end
        return table.concat(parts, "|")

    else
        error("Unknown node type: " .. node.tag)
    end
end

-- Converts a parsed type specification back to its string representation
function M.parsedTypeSpecToStr(parsed, reformat_enum_labels)
    if type(parsed) ~= "table" then
        error("Expected table, got " .. type(parsed))
    end
    return inner_convert(parsed, reformat_enum_labels or false)
end

-- Returns the string-representation of a parsed type specification
function M.serializeType(type_spec)
    if type(type_spec) == 'string' then
        return type_spec
    end
    return M.parsedTypeSpecToStr(type_spec)
end

-- Wire up utils.serializeType to use our implementation
utils.setSerializeType(M.serializeType)

return M
