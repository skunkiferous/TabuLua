-- parsers/utils.lua
-- Low-level utility functions for the parsers module

local state = require("parsers.state")

local serialization = require("serialization")
local serializeTable = serialization.serializeTable
local unquotedStr = serialization.unquotedStr

local table_parsing = require("table_parsing")
local parseTableStr = table_parsing.parseTableStr

local error_reporting = require("error_reporting")

local M = {}

-- Returns the module version
function M.getVersion()
    return tostring(state.VERSION)
end

-- Serialize a table of basic types (number,string,boolean,nil) to a string, without the
-- enclosing {}
function M.serializeTableWithoutCB(t)
    return serializeTable(t):sub(2, -2)
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
        str = M.serializeTableWithoutCB(value)
        parsed = value
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
    return state.ALIASES[name] or name
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
