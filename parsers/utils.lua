-- parsers/utils.lua
-- Low-level utility functions for the parsers module

local state = require("parsers.state")

local serialization = require("serde.serialization")
local serializeTable = serialization.serializeTable
local unquotedStr = serialization.unquotedStr

local table_parsing = require("util.table_parsing")
local parseTableStr = table_parsing.parseTableStr

local error_reporting = require("infra.error_reporting")
local didYouMean = error_reporting.didYouMean

local M = {}

-- Sorted list of the simple, user-typeable type NAMES currently registered
-- (built-ins, custom types, aliases). Generated registry keys — composite
-- specs like {T} or {{K,V}}, unions (T|nil), and restriction parsers
-- (integer._R_GE_0) — are excluded by keeping only bare identifiers, so an
-- unknown-type diagnostic can suggest a real name a user could have meant
-- rather than internal machinery. NOT a complete list of valid type specs.
function M.namedTypeCandidates()
    local seen = {}
    local function collect(tbl)
        for name in pairs(tbl) do
            if type(name) == "string" and name:match("^[%a_][%w_]*$") then
                seen[name] = true
            end
        end
    end
    collect(state.PARSERS)
    collect(state.ALIASES)
    local result = {}
    for name in pairs(seen) do result[#result + 1] = name end
    table.sort(result)
    return result
end

-- Returns " (did you mean 'X'?)" for an unknown type NAME, matched against the
-- registered simple type names, or "" when nothing is close. Error path only
-- (it enumerates the parser registry).
function M.unknownTypeSuffix(typeName)
    return didYouMean(typeName, M.namedTypeCandidates())
end

-- Returns the module version
function M.getVersion()
    return tostring(state.VERSION)
end

-- Serialize a table of basic types (number,string,boolean,nil) to a string, without the
-- enclosing {}
function M.serializeTableWithoutCB(t)
    return serializeTable(t):sub(2, -2)
end

-- Serializes an already-parsed table to its cell text, REPORTING (rather than
-- raising) the values the serializer legitimately refuses: a table used as a map
-- key, a recursive table, one nested deeper than MAX_TABLE_DEPTH. None of those can
-- be read back (see TODO/tables_as_keys.md), so the cell is bad — but a bad cell is
-- what badVal is for, and a raised error would abort the whole load without naming
-- the file, row or column the value came from. Such a value can only arrive from an
-- '=expr' cell, a pre-processor or a transcoder, never from parsed file text.
-- Returns (value, cell_text) on success and (nil, text) on refusal, like a parser.
function M.serializeParsedTable(badVal, table_type, value)
    local ok, str = pcall(M.serializeTableWithoutCB, value)
    if not ok then
        -- badVal renders the value with the reason, so it needs no error argument.
        M.log(badVal, table_type, value)
        return nil, tostring(value)
    end
    return value, str
end

-- Log a bad value, with its type, and an optional error message.
function M.log(badVal, badType, value, error)
    assert(type(badVal) == 'table', "wrong badVal: " .. type(badVal))
    return error_reporting.withColType(badVal, badType, function()
        badVal(value, error)
    end)
end

-- Parse any kind of Lua table from a string, which does not include the enclosing {}.
-- In other words, "1,2,3" is assumed to mean "{1,2,3}", and is returned as a {1,2,3} table
-- If value is already a table, it is returned as is.
-- Returns nil on failure.
-- After the table, a string with the original value is returned
function M.table_parser(badVal, table_type, value)
    local parsed, str
    local vt = type(value)
    if vt == 'table' then
        return M.serializeParsedTable(badVal, table_type, value)
    elseif vt == 'string' then
        str = value
        -- Users skip the surrounding {}, as part of the specification
        parsed = parseTableStr(badVal, table_type, "{" .. value .. "}")
    else
        str = tostring(value)
    end
    return parsed, str
end

-- Resolves the name of "type aliases" to the name / type specification of real types, if it exists
function M.resolve(name)
    local alias = state.ALIASES[name]
    if alias then return alias end
    -- Normalize {extends:X} colon form to {extends,X} comma form on demand
    local ancestor = name:match("^{extends:([^{}]+)}$")
    if ancestor then
        local normalized = "{extends," .. ancestor .. "}"
        state.ALIASES[name] = normalized
        return normalized
    end
    return name
end

-- Checks context and returns true if TSV context is expected
function M.expectTSV(context)
    if context == nil or context == "tsv" then
        return true
    end
    if context == "parsed" then
        return false
    end
    error("parser context must be nil, 'tsv' or 'parsed': " .. tostring(context))
end

-- Add quotes or {} to reformatted values if needed, based on type of parsed
function M.quoteIfNeeded(parsed, reformatted, pretendString)
    local parsed_type = type(parsed)
    if (parsed_type == "string" or parsed_type == "nil") or pretendString then
        return reformatted
    elseif parsed_type == "table" then
        return unquotedStr('{'..reformatted..'}')
    else
        return unquotedStr(reformatted)
    end
end

-- Assert that a parser is not the nil parser
function M.notNilParser(p, name)
    assert(p ~= state.PARSERS['nil'], name.." cannot be of type 'nil'")
end

-- Returns the string-representation of a parsed type specification
-- (Forward declaration - actual implementation in lpeg_parser)
function M.serializeType(type_spec)
    -- This will be replaced by lpeg_parser.serializeType after that module loads
    if type(type_spec) == 'string' then
        return type_spec
    end
    error("serializeType not yet initialized - lpeg_parser module not loaded")
end

-- Set the actual serializeType implementation (called by lpeg_parser)
function M.setSerializeType(fn)
    M.serializeType = fn
end

return M
