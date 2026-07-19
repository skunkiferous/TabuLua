-- Module name
local NAME = "serialization"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 32, 0)

-- Dependencies
local sparse_seq = require("util.sparse_sequence")
local getSparseSequenceSize = sparse_seq.getSparseSequenceSize
local read_only = require("util.read_only")
local readOnly = read_only.readOnly
local dkjson = require("dkjson")

-- lua-MessagePack
local mpk = require("MessagePack")
-- Modify MessagePack global configuration. We do this since we would like to support
-- sparse arrays. We assume that no other module should use MessagePack directly,
-- and therefore, the side-effect will not be a problem.
mpk.set_array('with_hole')

-- Predicates module (no circular dependency - predicates doesn't depend on serialization)
local predicates = require("util.predicates")
local isBasic = predicates.isBasic

local logger = require( "infra.named_logger").getLogger(NAME)

local sandbox = require("sandbox")
local sandbox_env = require("infra.sandbox_env")

local formatInteger = require("util.string_utils").formatInteger

-- int64 values are BOXES: empty tables carrying a metatable. Every serializer
-- below therefore needs an explicit arm, because otherwise each one would fall
-- through to its table branch and emit an empty container instead of the value.
-- The check is per VALUE (int64.is), not per column, which is exactly why it
-- works at any depth -- nested, inside untyped containers, and in key position.
local int64 = require("util.int64")
local int64Digits = int64.tostring

--- Renders a number for serialized output. tostring, EXCEPT for an
--- integer-valued number that tostring would render in scientific notation:
--- on LuaJIT tostring(9007199254740991) is "9.007199254741e+15" — rounded! —
--- which corrupts the value in every text format on the way back in.
--- (Non-finite values never reach here: every caller handles them first.)
--- @param v number The number to render
--- @return string The exact text representation
local function numberToText(v)
    if v == math.floor(v) and tostring(v):find("[eE]") then
        return formatInteger(v)
    end
    return tostring(v)
end

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- Special metatable used to wrap a string in a table, such that serialize will output it
-- unquoted.
local UNQUOTED_MT = {
    __tostring = function(self)
        -- Table should have exactly one string as content
        return self[1]
    end
}

--- Wraps a string so serialize() outputs it unquoted (as raw Lua code).
--- Use for embedding Lua expressions or references in serialized output.
--- @param s string The string to wrap
--- @return table A wrapper table with UNQUOTED_MT metatable
--- @error Throws if s is not a string
local function unquotedStr(s)
    if type(s) ~= "string" then
        error("not a string: " .. type(s))
    end
    return setmetatable({s}, UNQUOTED_MT)
end

-- Maximum table depth for serializeTable
local MAX_TABLE_DEPTH = 10

-- A table in the KEY position is refused by every serializer below, because
-- nothing in the pipeline can read one back: ltcn's grammar makes a table a legal
-- value but never a legal key, JSON object keys are always strings, and the typed
-- JSON / XML forms lower back to native cell text, so they hit ltcn too. On top of
-- that, Lua compares table keys by identity, so a freshly parsed key could never
-- match the original anyway. Writing one produces a file we cannot re-parse, so we
-- fail here (loudly, at write time) instead of emitting it. Mirrors the read-side
-- contract in util/table_parsing.lua. See TODO/tables_as_keys.md.
--
-- An UNQUOTED_MT value is exempt: it is raw Lua *text* in a wrapper, not a table
-- value (serialize() already treats it as a string). The map parser wraps every
-- non-string key that way to carry its reformatted text — `[3]`, `[true]` — so
-- every integer- or boolean-keyed map has such "table" keys in its reference copy.
-- It can never carry a genuine table key: a table is not a legal map KEY type
-- (parsers/type_parsing.lua rejects it via NEVER_TABLE), so the wrapped key is
-- always a scalar's text.
-- An int64 box is exempt for the same reason an UNQUOTED_MT value is, but on
-- stronger grounds: boxes are INTERNED, so they compare by value and a freshly
-- parsed key is the very same object as the original. That is precisely the
-- property whose absence this refusal exists to catch.
local function rejectTableKey(k, reason)
    if type(k) == "table" and getmetatable(k) ~= UNQUOTED_MT
        and not int64.is(k) then
        error("table used as a map key: nothing can read that back (" .. reason
            .. "). See TODO/tables_as_keys.md", 0)
    end
end

-- The two reasons, shared by the four serializers below. The typed-JSON and XML
-- forms can encode a table key, but both lower back to native cell text on import,
-- so they end up at ltcn all the same.
local NO_TABLE_KEY_NATIVE = "ltcn, our cell reader, allows a table as a value but never as a key"
local NO_TABLE_KEY_LOWERED = "it is re-imported through a native Lua cell, and " .. NO_TABLE_KEY_NATIVE
local NO_TABLE_KEY_JSON = "a JSON object key is always a string, so the table could not be rebuilt"

-- True if k is an integer sequence index in 1..maxLen. Used to tell a table's
-- "sequence prefix" keys from its "map" keys without relying on pairs() order.
local function isSeqIndex(k, maxLen)
    return type(k) == "number" and k >= 1 and k <= maxLen
        and (math.type and math.type(k) == "integer" or math.floor(k) == k)
end

-- Length of the leading contiguous non-nil run t[1], t[2], … — the part that is
-- emitted inline as a sequence when the table is NOT a (sparse) sequence.
local function contiguousPrefixLen(t)
    local m = 0
    while t[m + 1] ~= nil do
        m = m + 1
    end
    return m
end

-- Forward declaration of serializeTable
local serializeTableRef

--- Serializes a value to a Lua-readable string representation.
--- Supports basic types (number, string, boolean, nil) and tables.
--- Tables referenced multiple times are serialized multiple times (no reference sharing).
--- @param v any The value to serialize
--- @param nil_as_empty_str boolean|nil If true, nil values become empty string "" (default: false)
--- @param in_process table|nil Internal: tracks tables being processed to detect recursion
--- @param depth number|nil Internal: current recursion depth
--- @return string Lua source code that evaluates to the original value
--- @error Throws on recursive tables or depth exceeding MAX_TABLE_DEPTH
local function serialize(v, nil_as_empty_str, in_process, depth)
    if v == nil and nil_as_empty_str then
        return ""
    end
    -- Handle special float values before isBasic check
    -- Lua 5.3's %q produces "inf"/"-inf"/"nan" which are not valid Lua syntax
    -- Lua 5.4's %q produces "1e9999"/"-1e9999"/"(0/0)" which are valid
    -- Use mathematical expressions that work in all Lua versions
    if type(v) == "number" then
        if v ~= v then  -- NaN check
            return "(0/0)"
        elseif v == math.huge then
            return "(1/0)"
        elseif v == -math.huge then
            return "(-1/0)"
        end
    end
    if isBasic(v) then
        -- Output basic Lua values such that they can be read again as valid Lua literals
        local t = type(v)
        if t == "string" then
            -- Use %q for strings to properly escape special characters
            return string.format("%q", v)
        elseif t == "number" then
            -- Note: LuaJIT's %q quotes numbers which breaks round-trip
            -- serialization, and its tostring rounds big integral values
            return numberToText(v)
        else
            -- For booleans and nil, use tostring()
            return tostring(v)
        end
    end
     -- Unquoted string (from UNQUOTED_MT)
    local t = type(v)
    if t == "table" and getmetatable(v) == UNQUOTED_MT then
        return v[1]
    end
    -- int64: a QUOTED string of canonical digits, unchanged from when the value
    -- itself was a string. A bare literal would be lexed straight into a double
    -- by LuaJIT on re-import, and the Lua format has no tag to rescue it.
    if int64.is(v) then
        return string.format("%q", int64Digits(v))
    end
    if t == "function" then
        -- Not very useful, but better than crashing
        return "<function>"
    end
    return serializeTableRef(v, nil_as_empty_str, in_process, depth)
end

--- Serializes a table to a Lua-readable string representation.
--- Handles sequences, sparse sequences, and maps with mixed key types.
--- @param t table The table to serialize
--- @param nil_as_empty_str boolean|nil If true, nil values become empty string "" (default: false)
--- @param in_process table|nil Internal: tracks tables being processed to detect recursion
--- @param depth number|nil Internal: current recursion depth (default: 0)
--- @return string Lua source code that evaluates to the original table
--- @error Throws if t is not a table, on recursive tables, or depth exceeds MAX_TABLE_DEPTH
local function serializeTable(t, nil_as_empty_str, in_process, depth)
    if type(t) ~= "table" then
        error("not a table: " .. type(t))
    end
    depth = depth or 0
    nil_as_empty_str = nil_as_empty_str or false
    if depth >= MAX_TABLE_DEPTH then
        error("Maximal depth reached!")
    end
    depth = depth + 1
    in_process = in_process or {}
    assert(not in_process[t], "recursive table")
    in_process[t] = true
    local sep = ""
    local r = { "{" }
    local keyed = {}
    local tmp = {}

    -- Emit the "sequence prefix" by explicit index so output does NOT depend on
    -- pairs() order (a sequence stored in Lua's hash part iterates arbitrarily).
    -- A (sparse) sequence emits all of 1..sparseSize (gaps as nil); any other
    -- table emits its leading contiguous non-nil run, the rest become map keys.
    local sparseSize = getSparseSequenceSize(t)
    local seqLen = sparseSize or contiguousPrefixLen(t)
    for i = 1, seqLen do
        r[#r + 1] = sep
        sep = ","
        local v = t[i]
        if v == nil then
            r[#r + 1] = nil_as_empty_str and "''" or "nil"
        else
            r[#r + 1] = serialize(v, nil_as_empty_str, in_process, depth)
        end
    end

    -- Remaining keys (not in the sequence prefix) become explicit table keys.
    -- A non-nil sparseSize means every key is a sequence index, so skip this.
    if sparseSize == nil then
        for k, v in pairs(t) do
            if not isSeqIndex(k, seqLen) then
                rejectTableKey(k, NO_TABLE_KEY_NATIVE)
                -- Identifier keys use syntactic sugar (k=v); the rest use [k]=v.
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    tmp[1] = k
                    tmp[2] = '='
                    tmp[3] = serialize(v, nil_as_empty_str, in_process, depth)
                    tmp[4] = nil
                else
                    tmp[1] = '['
                    tmp[2] = serialize(k, nil_as_empty_str, in_process, depth)
                    tmp[3] = ']='
                    tmp[4] = serialize(v, nil_as_empty_str, in_process, depth)
                end
                keyed[#keyed + 1] = table.concat(tmp)
            end
        end
    end
    in_process[t] = nil
    -- We output the non-sequence part first, then the rest is output sorted
    -- Note that '[' keys will be sorted before identifiers
    table.sort(keyed)
    for _, value in ipairs(keyed) do
        r[#r + 1] = sep
        sep = ","
        r[#r + 1] = value
    end
    r[#r + 1] = "}"
    return table.concat(r)
end
serializeTableRef = serializeTable

--- Debugging helper: prints a serialized value to console.
--- @param v any The value to dump
--- @param opt_val_name string|nil Optional name to prefix the output (e.g., "myVar = {...}")
--- @side_effect Prints to stdout
local function dump(v, opt_val_name)
    if opt_val_name then
        print(opt_val_name .. " = " .. serialize(v))
    else
        print(serialize(v))
    end
end

--- Debugging helper: logs a serialized value as a warning.
--- @param v any The value to dump
--- @param opt_val_name string|nil Optional name to prefix the output
--- @param opt_logger table|nil Optional logger instance (default: module's logger)
--- @side_effect Logs warning message
local function warnDump(v, opt_val_name, opt_logger)
    local log = opt_logger or logger
    if opt_val_name then
        log:warn(opt_val_name .. " = " .. serialize(v, false, nil, 0))
    else
        log:warn(serialize(v, false, nil, 0))
    end
end

--- Converts a number to a plain string without scientific notation.
--- Handles special float values (inf, -inf, nan) as literal strings.
--- @param num number|nil The number to convert
--- @return string|nil Plain number string, or nil if input is nil
--- @error Throws if num is not a number or nil
local function toPlainNumber(num)
    if num == nil then
        return nil
    end
    if type(num) ~= "number" then
        error("toPlainNumber: num not a number: "..type(num))
    end
    
    -- Handle special float values
    if num ~= num then
        return "nan"
    end
    if num == math.huge then
        return "inf"
    end
    if num == -math.huge then
        return "-inf"
    end
    
    -- Integer: no decimal places needed
    if num == math.floor(num) then
        return string.format("%.0f", num)
    end
    
    -- Float: use sufficient precision, strip trailing zeros
    local s = string.format("%.14f", num)
    return (s:gsub("0+$", ""):gsub("%.$", ""))
end

-- Forward declaration of serializeTableJSON
local serializeTableJSONRef

--- Serializes a value to a JSON-compatible string with Lua type preservation.
--- Integers are encoded as {"int":"123"} to prevent float conversion.
--- Special floats are encoded as {"float":"nan"/"inf"/"-inf"}.
--- @param v any The value to serialize
--- @param nil_as_empty_str boolean|nil If true, nil values become empty string "" (default: false)
--- @param in_process table|nil Internal: tracks tables being processed to detect recursion
--- @param depth number|nil Internal: current recursion depth
--- @return string JSON string representation
--- @error Throws on recursive tables or depth exceeding MAX_TABLE_DEPTH
local function serializeJSON(v, nil_as_empty_str, in_process, depth)
    if v == nil and nil_as_empty_str then
        return ""
    end
    local t = type(v)
    if t == "number" then
        if math.type(v) == "integer" then
            -- Stoopid JSON doesn't support integers (well, it does, but most decoders do not, bc JavaScript does not)
            -- formatInteger, not tostring: LuaJIT's tostring rounds big integral values
            return '{"int":"' .. formatInteger(v) .. '"}'
        end
        -- Handle special float values
        if v ~= v then
            return '{"float":"nan"}'
        end
        if v == math.huge then
            return '{"float":"inf"}'
        end
        if v == -math.huge then
            return '{"float":"-inf"}'
        end
        return dkjson.encode(v)
    end
    if t == "string" or t == "boolean" or t == "nil" then
        return dkjson.encode(v)
    end
    -- int64: emitted as the digit string, exactly as when the value WAS a
    -- string. The {"int":"..."} tagged form is Phase 7 of TODO/boxed_int64.md;
    -- this phase only makes the box recognizable, so the bytes must not move.
    if int64.is(v) then
        return dkjson.encode(int64Digits(v))
    end
    if t == "function" then
        -- Not very useful, but better than crashing
        return '"<function>"'
    end
    return serializeTableJSONRef(v, nil_as_empty_str, in_process, depth)
end

-- Serialize a table to a "JSON string". All tables are serialized as follows:
-- [<N(sequence-size)>,<elem1>,...,<elemN>,[<key1>,<value1>],...,[<keyM>,<valueM>]]
-- In other words, an array of 3 elements would be:
-- [3,"elem1","elem2","elem3"]
-- Note that, Lua arrays start at index 1, and the value at index 1 in a Lua array, will also be at index 1 in the JSON array
-- And, a map of 2 elements would be:
-- [0,["key1","value1"],["key2","value2"]]
-- Tables as keys or values, which are referenced multiple times, are serialized multiple times.
-- This could lead to large output.
-- Recursive tables are not supported.
local function serializeTableJSON(t, nil_as_empty_str, in_process, depth)
    if type(t) ~= "table" then
        error("not a table: " .. type(t))
    end
    depth = depth or 0
    nil_as_empty_str = nil_as_empty_str or false
    if depth >= MAX_TABLE_DEPTH then
        error("Maximal depth reached!")
    end
    depth = depth + 1
    in_process = in_process or {}
    assert(not in_process[t], "recursive table")
    in_process[t] = true
    local keyed = {}
    local tmp = {}

    -- Sequence prefix emitted by explicit index (order-independent — see
    -- serializeTable). "seqLen" is the leading element count and is the value at
    -- "index 0" of the JSON array, so it always matches the inline elements.
    local sparseSize = getSparseSequenceSize(t)
    local seqLen = sparseSize or contiguousPrefixLen(t)
    local r = { "[", tostring(seqLen) }
    for i = 1, seqLen do
        r[#r + 1] = ","
        local v = t[i]
        if v == nil then
            r[#r + 1] = nil_as_empty_str and '""' or 'null'
        else
            r[#r + 1] = serializeJSON(v, nil_as_empty_str, in_process, depth)
        end
    end

    -- Remaining (map) keys. Stoopid JSON only supports string map keys, and I
    -- refuse to accept this limitation, so we use [key,value] pairs, not objects.
    -- A non-nil sparseSize means every key is a sequence index, so skip this.
    if sparseSize == nil then
        for k, v in pairs(t) do
            if not isSeqIndex(k, seqLen) then
                rejectTableKey(k, NO_TABLE_KEY_LOWERED)
                tmp[1] = '['
                tmp[2] = serializeJSON(k, nil_as_empty_str, in_process, depth)
                tmp[3] = ','
                tmp[4] = serializeJSON(v, nil_as_empty_str, in_process, depth)
                tmp[5] = ']'
                keyed[#keyed + 1] = table.concat(tmp)
            end
        end
    end
    in_process[t] = nil
    -- We output the non-sequence part first, then the rest is output sorted
    -- Note that '[' keys will be sorted before identifiers
    table.sort(keyed)
    for _, value in ipairs(keyed) do
        r[#r + 1] = ","
        r[#r + 1] = value
    end
    r[#r + 1] = "]"
    return table.concat(r)
end
serializeTableJSONRef = serializeTableJSON

-- Forward declaration of serializeTableNaturalJSON
local serializeTableNaturalJSONRef

--- Serializes a value to standard/natural JSON format.
--- Unlike serializeJSON, this produces conventional JSON:
--- - Numbers (both integers and floats) are plain JSON numbers
--- - Special floats (nan/inf/-inf) become strings: "NAN", "INF", "-INF"
--- - Functions become "<FUNCTION>"
--- - Sequences/sparse-sequences become JSON arrays
--- - Other tables become JSON objects (non-string keys are stringified)
--- @param v any The value to serialize
--- @param nil_as_empty_str boolean|nil If true, nil values become empty string "" (default: false)
--- @param in_process table|nil Internal: tracks tables being processed to detect recursion
--- @param depth number|nil Internal: current recursion depth
--- @return string JSON string representation
--- @error Throws on recursive tables or depth exceeding MAX_TABLE_DEPTH
local function serializeNaturalJSON(v, nil_as_empty_str, in_process, depth)
    if v == nil and nil_as_empty_str then
        return ""
    end
    local t = type(v)
    if t == "number" then
        -- Handle special float values as uppercase strings
        if v ~= v then
            return '"NAN"'
        end
        if v == math.huge then
            return '"INF"'
        end
        if v == -math.huge then
            return '"-INF"'
        end
        -- Both integers and floats are plain JSON numbers
        return dkjson.encode(v)
    end
    if t == "string" or t == "boolean" or t == "nil" then
        return dkjson.encode(v)
    end
    -- int64: a QUOTED string, and it stays one. A bare JSON number is exact on
    -- Lua 5.3+ but ROUNDS when LuaJIT re-reads it, which would reintroduce the
    -- version-dependence int64 exists to remove.
    if int64.is(v) then
        return dkjson.encode(int64Digits(v))
    end
    if t == "function" then
        return '"<FUNCTION>"'
    end
    return serializeTableNaturalJSONRef(v, nil_as_empty_str, in_process, depth)
end

--- Converts a non-string key to a string for use as a JSON object key.
--- @param k any The key to stringify
--- @return string The stringified key
--- @error Throws if k is a table (see rejectTableKey)
local function keyToString(k)
    -- Stringifying a table key would be irreversible: on read we only ever see a
    -- string, with nothing left to rebuild the table from.
    rejectTableKey(k, NO_TABLE_KEY_JSON)
    -- An int64 key stringifies to its digits, which re-parse to the very same
    -- interned box -- the round-trip a generic table key cannot offer
    if int64.is(k) then
        return int64Digits(k)
    end
    local t = type(k)
    if t == "string" then
        return k
    elseif t == "number" then
        -- Handle special float values
        if k ~= k then
            return "NAN"
        end
        if k == math.huge then
            return "INF"
        end
        if k == -math.huge then
            return "-INF"
        end
        return tostring(k)
    elseif t == "boolean" then
        return tostring(k)
    elseif t == "nil" then
        return "null"
    elseif t == "function" then
        return "<FUNCTION>"
    else
        return "<" .. t:upper() .. ">"
    end
end

--- Serializes a table to standard/natural JSON format.
--- Sequences and sparse sequences become JSON arrays.
--- Other tables become JSON objects (with non-string keys stringified).
--- @param t table The table to serialize
--- @param nil_as_empty_str boolean|nil If true, nil values become empty string "" (default: false)
--- @param in_process table|nil Internal: tracks tables being processed to detect recursion
--- @param depth number|nil Internal: current recursion depth (default: 0)
--- @return string JSON string representation
--- @error Throws if t is not a table, on recursive tables, or depth exceeds MAX_TABLE_DEPTH
local function serializeTableNaturalJSON(t, nil_as_empty_str, in_process, depth)
    if type(t) ~= "table" then
        error("not a table: " .. type(t))
    end
    depth = depth or 0
    nil_as_empty_str = nil_as_empty_str or false
    if depth >= MAX_TABLE_DEPTH then
        error("Maximal depth reached!")
    end
    depth = depth + 1
    in_process = in_process or {}
    assert(not in_process[t], "recursive table")
    in_process[t] = true

    local sparseSize = getSparseSequenceSize(t)
    -- Treat as sequence if sparseSize is not nil AND either:
    -- - sparseSize > 0 (has sequence elements), OR
    -- - table is empty (next(t) is nil)
    local isSeq = sparseSize ~= nil and (sparseSize > 0 or next(t) == nil)

    if isSeq then
        -- Serialize as JSON array
        local r = { "[" }
        local sep = ""
        for i = 1, sparseSize do
            r[#r + 1] = sep
            sep = ","
            local v = t[i]
            if v == nil then
                if nil_as_empty_str then
                    r[#r + 1] = '""'
                else
                    r[#r + 1] = "null"
                end
            else
                r[#r + 1] = serializeNaturalJSON(v, nil_as_empty_str, in_process, depth)
            end
        end
        r[#r + 1] = "]"
        in_process[t] = nil
        return table.concat(r)
    else
        -- Serialize as JSON object
        local r = { "{" }
        local sep = ""
        local keyed = {}
        local tmp = {}
        for k, v in pairs(t) do
            local keyStr = keyToString(k)
            tmp[1] = dkjson.encode(keyStr)
            tmp[2] = ":"
            tmp[3] = serializeNaturalJSON(v, nil_as_empty_str, in_process, depth)
            tmp[4] = nil
            keyed[#keyed + 1] = table.concat(tmp)
        end
        -- Sort for consistent output
        table.sort(keyed)
        for _, value in ipairs(keyed) do
            r[#r + 1] = sep
            sep = ","
            r[#r + 1] = value
        end
        r[#r + 1] = "}"
        in_process[t] = nil
        return table.concat(r)
    end
end
serializeTableNaturalJSONRef = serializeTableNaturalJSON

--- Escapes a string for use as an SQL string literal.
--- Removes null bytes, escapes backslashes and single quotes.
--- @param s string The string to escape
--- @return string SQL-safe string literal with surrounding single quotes
--- @warning Parameterized queries are preferred over string escaping for SQL injection prevention
local function escapeSQLString(s)
    return "'" .. s:gsub("\0", "")      -- Remove null bytes (can truncate in some DBs)
                  :gsub("\\", "\\\\")   -- Escape backslashes (MySQL compatibility)
                  :gsub("'", "''")      -- Standard SQL single-quote escaping
           .. "'"
end

--- Serializes a value for use in SQL statements.
--- Tables are serialized to strings using the provided serializer (default: JSON).
--- @param v any The value to serialize
--- @param tableSerializer function|nil Custom table serializer (default: serializeTableJSON)
--- @return string SQL-safe representation: NULL, quoted string, number, 1/0 for boolean, or serialized table
--- @error Throws if tableSerializer is not nil or a function, or for unsupported types
local function serializeSQL(v, tableSerializer)
    assert(tableSerializer == nil or type(tableSerializer) == "function", "tableSerializer must be a function")
    local ser = tableSerializer or serializeTableJSON
    local t = type(v)
    if v == nil then
        return "NULL"
    elseif t == "string" then
        return escapeSQLString(v)
    elseif t == "number" then
        return numberToText(v)
    elseif t == "boolean" then
        return v and "1" or "0"
    elseif int64.is(v) then
        -- int64: a quoted SQL string literal, unchanged. The BIGINT column plus
        -- bare literal is Phase 7 of TODO/boxed_int64.md, and the two halves
        -- must land together -- sql_types maps int64 to TEXT today, so a bare
        -- literal here would be a type mismatch against its own column.
        return escapeSQLString(int64Digits(v))
    elseif t == "table" then
        -- Encode table as JSON/XML/... string
        local encoded = ser(v, false)
        return escapeSQLString(encoded)
    elseif t == "function" then
        -- Not very useful, but better than crashing
        return "'<function>'"
    else
        error("unsupported type: " .. t)
    end
end

-- Forward declaration of serializeTableXML
local serializeTableXMLRef

-- Serialize a table or basic type (number,integer,string,boolean,nil) to a "XML string"
-- Special Lua floats are encoded as:
--   <number>nan</number> / <number>inf</number> / <number>-inf</number>
-- Tables as keys or values, which are referenced multiple times, are serialized multiple times.
-- Recursive tables are not supported.
local function serializeXML(v, nil_as_empty_str, in_process, depth)
    if v == nil and nil_as_empty_str then
        return ""
    end
    if v == nil then
        return "<null/>"
    end
    if v == true then
        return "<true/>"
    end
    if v == false then
        return "<false/>"
    end
    if v == "" then
        return "<string/>"
    end
    local t = type(v)
    if t == "number" then
        if math.type(v) == "integer" then
            -- formatInteger, not tostring: LuaJIT's tostring rounds big integral values
            return "<integer>" .. formatInteger(v) .. "</integer>"
        end
        -- Handle special float values
        if v ~= v then
            return "<number>nan</number>"
        end
        if v == math.huge then
            return "<number>inf</number>"
        end
        if v == -math.huge then
            return "<number>-inf</number>"
        end
        return "<number>" .. tostring(v) .. "</number>"
    end
    -- int64: the <string> form, unchanged. The <integer> form is Phase 7 of
    -- TODO/boxed_int64.md and requires the read-side fix first, or the value
    -- rounds through tonumber() on re-read.
    if int64.is(v) then
        return "<string>" .. int64Digits(v) .. "</string>"
    end
    if t == "string" then
        return "<string>" .. (v:gsub("&", "&amp;")
             :gsub("<", "&lt;")
             :gsub(">", "&gt;")
             :gsub('"', "&quot;")
             :gsub("'", "&apos;")) .. "</string>"
    end
    if t == "function" then
        -- Not very useful, but better than crashing
        return "<function/>"
    end
    return serializeTableXMLRef(v, nil_as_empty_str, in_process, depth)
end

-- Serialize a table to a "XML string". All tables are serialized as follows:
-- <table><elem1/>...<elemN/><key_value><key1/><value1/></key_value>...</table>
-- In other words, an array of 3 elements would be:
-- <table><elem1/><elem2/><elem3/></table>
-- And, a map of 2 elements would be:
-- <table><key_value><key1/><value1/></key_value><key_value><key2/><value2/></key_value></table>
-- Tables as keys or values, which are referenced multiple times, are serialized multiple times.
-- This could lead to large output.
-- Recursive tables are not supported.
local function serializeTableXML(t, nil_as_empty_str, in_process, depth)
    if type(t) ~= "table" then
        error("not a table: " .. type(t))
    end
    depth = depth or 0
    nil_as_empty_str = nil_as_empty_str or false
    if depth >= MAX_TABLE_DEPTH then
        error("Maximal depth reached!")
    end
    depth = depth + 1
    in_process = in_process or {}
    assert(not in_process[t], "recursive table")
    in_process[t] = true
    local keyed = {}
    local tmp = {}

    -- Sequence prefix emitted by explicit index (order-independent — see
    -- serializeTable); a (sparse) sequence emits 1..sparseSize with gaps as
    -- <null/>, any other table emits its leading contiguous non-nil run.
    local sparseSize = getSparseSequenceSize(t)
    local seqLen = sparseSize or contiguousPrefixLen(t)
    local r = { "<table>" }
    for i = 1, seqLen do
        local v = t[i]
        if v == nil then
            r[#r + 1] = nil_as_empty_str and "<string/>" or "<null/>"
        else
            r[#r + 1] = serializeXML(v, nil_as_empty_str, in_process, depth)
        end
    end

    -- Remaining (map) keys become <key_value> pairs. A non-nil sparseSize means
    -- every key is a sequence index, so skip this.
    if sparseSize == nil then
        for k, v in pairs(t) do
            if not isSeqIndex(k, seqLen) then
                rejectTableKey(k, NO_TABLE_KEY_LOWERED)
                tmp[1] = '<key_value>'
                tmp[2] = serializeXML(k, nil_as_empty_str, in_process, depth)
                tmp[3] = serializeXML(v, nil_as_empty_str, in_process, depth)
                tmp[4] = '</key_value>'
                keyed[#keyed + 1] = table.concat(tmp)
            end
        end
    end
    in_process[t] = nil
    -- We output the non-sequence part first, then the rest is output sorted
    table.sort(keyed)
    for _, value in ipairs(keyed) do
        r[#r + 1] = value
    end
    r[#r + 1] = "</table>"
    return table.concat(r)
end
serializeTableXMLRef = serializeTableXML

-- MANDATORY GUARD: a box is an EMPTY table, so lua-MessagePack -- which
-- dispatches on the Lua type -- would pack it as an empty map/array (a single
-- 0xC0-class byte, MEASURED: 0x90), losing the value completely and SILENTLY.
-- Silent loss is the one outcome that is not acceptable, so until the real
-- int64 encoding lands (standard 0xD3, Phase 7 of TODO/boxed_int64.md) a box
-- reaching the packer must fail loudly instead.
--
-- Hooking packers.table rather than pre-walking the value is what makes the
-- guard total: lua-MessagePack recurses through this same dispatch table, so
-- a box nested at any depth is caught, at no per-call walking cost.
if type(mpk.packers) ~= "table" or type(mpk.packers.table) ~= "function" then
    error("lua-MessagePack does not expose packers.table, so an int64 could be "
        .. "silently packed as an empty container; refusing to continue")
end
local mpk_pack_table = mpk.packers.table
mpk.packers.table = function(buffer, v, ...)
    if int64.is(v) then
        error("int64 values cannot be MessagePack-encoded yet (int64 "
            .. int64Digits(v) .. "); see TODO/boxed_int64.md Phase 7", 0)
    end
    return mpk_pack_table(buffer, v, ...)
end

--- Serializes a value using MessagePack binary format.
--- Configured to support sparse arrays via mpk.set_array('with_hole').
--- @param v any The value to serialize
--- @param nil_as_empty_str boolean|nil Ignored (MessagePack API is not configurable)
--- @return string Binary MessagePack data
--- @error Throws if the value contains an int64 (see the guard above)
local function serializeMessagePack(v, nil_as_empty_str)
    return mpk.pack(v)
end

--- Encodes a binary string as an SQL BLOB literal (hex format).
--- @param binary_string string The binary data to encode
--- @return string SQL BLOB literal in X'...' format
local function serializeSQLBlob(binary_string)
    local hex = binary_string:gsub(".", function(c)
        return string.format("%02X", string.byte(c))
    end)
    return "X'" .. hex .. "'"
end

--- Serializes a value to MessagePack and encodes as an SQL BLOB literal.
--- Combines serializeMessagePack() and serializeSQLBlob().
--- @param v any The value to serialize
--- @param nil_as_empty_str boolean|nil Passed to serializeMessagePack (currently ignored)
--- @return string SQL BLOB literal containing MessagePack data
local function serializeMessagePackSQLBlob(v, nil_as_empty_str)
    return serializeSQLBlob(serializeMessagePack(v, nil_as_empty_str))
end

-- Maximum operations allowed when serializing in sandbox
local SERIALIZE_SANDBOX_QUOTA = 1000

--- Safely serialize any value, running table serialization in a sandbox.
--- Prevents infinite loops, excessive memory usage, or malicious __tostring metamethods.
--- @param value any The value to serialize
--- @return string The serialized representation
local function serializeInSandbox(value)
    local t = type(value)
    if t == "nil" then
        return ""
    elseif t == "boolean" then
        return tostring(value)
    elseif t == "number" then
        -- Handle special float values
        if value ~= value then  -- NaN check
            return "nan"
        elseif value == math.huge then
            return "inf"
        elseif value == -math.huge then
            return "-inf"
        end
        return tostring(value)
    elseif t == "string" then
        return value
    elseif t == "function" then
        return "<function>"
    elseif t == "userdata" then
        return "<userdata>"
    elseif t == "thread" then
        return "<thread>"
    elseif int64.is(value) then
        -- Before the table branch: a box has no fields to walk, and the
        -- sandbox must never see one as a container
        return int64Digits(value)
    elseif t == "table" then
        -- Run serializeTable() in a sandbox to prevent infinite loops,
        -- excessive memory usage, or malicious __tostring metamethods
        local opt = sandbox_env.protectOptions(SERIALIZE_SANDBOX_QUOTA, nil)
        local code = [[
            local serialize = ...
            return function(tbl)
                return serialize(tbl)
            end
        ]]
        local ok, protected = pcall(sandbox.protect, code, opt)
        if not ok then
            return "<table: sandbox error>"
        end
        -- Pass serialize function and execute
        local exec_ok, serializer = pcall(protected, serialize)
        if not exec_ok then
            return "<table: init error>"
        end
        local result_ok, result = pcall(serializer, value)
        if not result_ok then
            -- Serialization failed (quota exceeded, recursive table, etc.)
            return "<table: " .. tostring(result) .. ">"
        end
        return result
    else
        return "<" .. t .. ">"
    end
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    dump=dump,
    getVersion=getVersion,
    messagePack=mpk,
    serialize=serialize,
    serializeInSandbox=serializeInSandbox,
    serializeJSON=serializeJSON,
    serializeMessagePack=serializeMessagePack,
    serializeMessagePackSQLBlob=serializeMessagePackSQLBlob,
    serializeNaturalJSON=serializeNaturalJSON,
    serializeSQL=serializeSQL,
    serializeSQLBlob=serializeSQLBlob,
    serializeTable=serializeTable,
    serializeTableJSON=serializeTableJSON,
    serializeTableNaturalJSON=serializeTableNaturalJSON,
    serializeTableXML=serializeTableXML,
    serializeXML=serializeXML,
    toPlainNumber=toPlainNumber,
    unquotedStr=unquotedStr,
    warnDump=warnDump,
    MAX_TABLE_DEPTH=MAX_TABLE_DEPTH,
    SERIALIZE_SANDBOX_QUOTA=SERIALIZE_SANDBOX_QUOTA,
}

-- Enables the module to be called as a function
local function apiCall(_, operation, ...)
    if operation == "version" then
        return VERSION
    elseif API[operation] then
        return API[operation](...)
    else
        error("Unknown operation: " .. tostring(operation), 2)
    end
end

return readOnly(API, {__tostring = apiToString, __call = apiCall, __type = NAME})
