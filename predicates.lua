-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 2, 0)

-- Module name
local NAME = "predicates"

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

local utf8 = require('utf8')

-- Custom shape builder
local custom_shape = require("tableshape").types.custom

-- Our utils
local string_utils = require("string_utils")
local split = string_utils.split
local trim = string_utils.trim
local read_only = require("read_only")
local readOnly = read_only.readOnly
local parseVersion = string_utils.parseVersion
local table_utils = require("table_utils")
local inverseMapping = table_utils.inverseMapping

--- Builds tableshape custom shapes from predicate functions.
--- @param predicates table A table of predicate functions (keys starting with "is")
--- @return table A table of custom shapes, keyed by predicate name (without "is" prefix, lowercase first char)
local function buildShapes(predicates)
    local result = {}
    for pn, p in pairs(predicates) do
        local name = pn:sub(3,3):lower() .. pn:sub(4)
        local err = "not a " .. name
        result[name] = custom_shape(function(v)
            if p(v) then
                return true
            end
            return nil, err
        end)
    end
    return result
end

--- Checks if a value is a valid "name" (identifier or dot-separated identifiers).
--- A name can be a single identifier like "foo" or dotted like "foo.bar.baz".
--- @param str any The value to check
--- @return boolean True if str is a valid name, false otherwise
local function isName(str)
    if type(str) ~= "string" then
        return false
    end
    if str:match("^[%a_][%w_]*$") or str:match("^[%a_][%w_]*%.[%a_][%w_]*$") then
        return true
    end
    local words = split(str, ".")
    for _, word in ipairs(words) do
        if not word:match("^[%a_][%w_]*$") then
            return false
        end
    end
    return true
end

--- Checks if a value is a valid Lua identifier (starts with letter/underscore, contains only alphanumerics/underscores).
--- @param s any The value to check
--- @return boolean True if s is a valid Lua identifier, false otherwise
local function isIdentifier(s)
    return type(s) == "string" and (string.match(s, "^[%a_][%w_]*$") and true or false)
end

--- Checks if a value is a basic Lua type (number, string, boolean, or nil).
--- @param v any The value to check
--- @return boolean True if v is number, string, boolean, or nil; false otherwise
local function isBasic(v)
    local t = type(v)
    return t == "number" or t == "string" or t == "boolean" or t == "nil"
end

-- Returns true if v is a "table"
local function isTable(v)
    return type(v) == "table"
end

-- Returns true if v is a non-empty "table"
local function isNonEmptyTable(v)
    if type(v) == "table" then
        for k in pairs(v) do
            return true
        end
    end
    return false
end

-- Returns true if v is a "string"
local function isString(v)
    return type(v) == "string"
end

-- Returns true if v is a non-empty "string"
local function isNonEmptyStr(v)
    return type(v) == "string" and #v > 0
end

-- Returns true if v is a non-blank "string"
local function isNonBlankStr(v)
    return type(v) == "string" and #(trim(v)) > 0
end

-- Returns true if v is a "boolean"
local function isBoolean(v)
    return v == true or v == false
end

-- Returns true if v is a "number"
local function isNumber(v)
    return type(v) == "number"
end

-- Returns true if v is a non-zero "number"
local function isNonZeroNumber(v)
    return type(v) == "number" and v ~= 0
end

-- Returns true if v is a strictly positive "number"
local function isPositiveNumber(v)
    return type(v) == "number" and v > 0
end

-- Returns true if v is an "integer"
local function isInteger(v)
    return type(v) == "number" and math.type(v) == "integer"
end

-- Returns true if v is an "integer"
local function isNonZeroInteger(v)
    return math.type(v) == "integer" and v ~= 0
end

-- Returns true if v is a strictly positive "integer"
local function isPositiveInteger(v)
    return math.type(v) == "integer" and v > 0
end

-- Returns true if v is an "integer" or a "number" with an integer value
local function isIntegerValue(v)
    return type(v) == "number" and (math.type(v) == "integer" or math.floor(v) == v)
end

-- Returns true if the value is a "default" (nil,false,0,0.0,"",{})
local function isDefault(v)
    if type(v) == "table" then
        for k in pairs(v) do
            return false
        end
        return true
    end
    if v == nil or v == false or v == 0 or v == 0.0 or v == "" then
        return true
    end
    return false
end

-- Returns true if the value is NOT a "default" (nil,false,0,0.0,"",{})
local function isNonDefault(v)
    if type(v) == "table" then
        for k in pairs(v) do
            return true
        end
        return false
    end
    if v ~= nil and v ~= false and v ~= 0 and v ~= 0.0 and v ~= "" then
        return true
    end
    return false
end

--- Checks if a table is a valid sequence (array) with no gaps.
--- A sequence has only consecutive integer keys starting from 1.
--- Empty tables are considered valid sequences.
--- @param t any The value to check
--- @return boolean True if t is a table that is a valid sequence, false otherwise
local function isFullSeq(t)
    if type(t) ~= "table" then
        return false
    end
    local count, min, max = 0, math.maxinteger, math.mininteger;
    for k, v in pairs(t) do
        if math.type(k) ~= "integer" then
            return false
        end
        count = count + 1;
        if k < min then
            min = k
        end
        if k > max then
            max = k
        end
    end
    if count == 0 then
        return true
    end
    if count ~= #t then
        return false
    end
    if min ~= 1 then
        return false
    end
    if max ~= #t then
        return false
    end
    return true
end

-- Returns true, if v is a version string, with a format of major.minor.patch
local function isVersion(v)
    if type(v) == "string" then
        return (parseVersion(v) ~= nil)
    end
    return false
end

-- Reserved file names (Windows-specific)
local reserved_file_names = {
    "CON", "PRN", "AUX", "NUL",
    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
}

--- Checks if a string is a valid file name (not a path).
--- Validates against Windows naming rules (most restrictive):
--- - No path separators (/ or \)
--- - No invalid characters (<>:"|?*)
--- - No reserved names (CON, PRN, AUX, NUL, COM1-9, LPT1-9)
--- - No triple dots or trailing periods/spaces
--- @param path any The value to check
--- @return boolean True if path is a valid file name, false otherwise
local function isFileName(path)
    -- Check if the path is a string
    if type(path) ~= "string" then
        return false
    end

    -- Check for empty path
    if path == "" then
        return false
    end

    -- Check for path separators
    if path:match('[/\\]') then
        return false
    end

    -- Check for invalid characters (assume Windows, the most restrictive rules)
    if path:match('[<>:"|%?%*]') then
        return false
    end

    -- Check for reserved names (Windows-specific)
    -- Reserved names are invalid even with extensions (e.g., "CON.txt" is invalid)
    local pu = path:upper()
    local base = pu:match("^([^%.]+)") or pu
    for _, name in ipairs(reserved_file_names) do
        if base == name then
            return false
        end
    end

    -- Check for double dots that aren't part of a parent directory reference
    if path:match("%.%.%.") then
        return false
    end

    -- Check for trailing periods or spaces (problematic on Windows)
    if path:match("[%. ]$") then
        return false
    end

    -- All checks passed
    return true
end

--- Checks if a string is a valid file path.
--- Assumes path uses Unix-style separators (/).
--- Each path component must be a valid file name per isFileName().
--- @param v any The value to check
--- @return boolean True if v is a valid path string, false otherwise
local function isPath(v)
    if type(v) ~= "string" then
        return false
    end
    if v:sub(-1) == "/" then
        v = v:sub(1, -2)
    end
    local parts = split(v, "/")
    if #parts == 0 then
        return false
    end
    for _, p in ipairs(parts) do
        if not isFileName(p) then
            return false
        end
    end
    return true
end

-- Returns true if the value is a blank string
local function isBlankStr(s)
    return type(s) == "string" and (s:gsub("^%s*(.-)%s*$", "%1") == "")
end

-- Returns true if the value is, literally, just the boolean 'true'
local function isTrue(v)
    return v == true
end

-- Returns true if the value is, literally, just the boolean 'false'
local function isFalse(v)
    return v == false
end

-- Returns true if the value is "comparable" (only string and number types)
local function isComparable(value)
    local t = type(value)
    return t == "string" or t == "number"
end

-- Returns true if the value is a string which is the name of a keyword in Lua
local function isValueKeyword(value)
    return value == "nil" or value == "false" or value == "true"
end

local function isPercent(value)
    if type(value) ~= "string" then
        return false
    end
    return (value:match("^-?%d+%%$") ~= nil) or (value:match("^-?%d+%.%d+%%$") ~= nil) or
        ((value:match("^-?%d+/%d+$") ~= nil) and not (value:match("^-?%d+/0+$") ~= nil))
end

-- Returns true, if the value is a table, with both a sequence and a map part
-- A "mixed table" without a value at "index 1" is not considered a mixed table
local function isMixedTable(t)
    if type(t) == "table" then
        local foundSeq = false
        local foundMap = false
        local idx = 1
        for k, _ in pairs(t) do
            -- Does the table has a "sequence/array part", and is k an index in that part?
            if k == idx then
                foundSeq = true
                idx = idx + 1
            else
                foundMap = true
            end
        end
        return foundSeq and foundMap
    end
    return false
end

--- Checks if a string is a valid HTTP or HTTPS URL.
--- Only validates typical URLs; does not support username, password, or other rare features.
--- @param url any The value to check
--- @return boolean True if url is a valid HTTP/HTTPS URL, false otherwise
local function isValidHttpUrl(url)
    if type(url) ~= "string" then return false end
    local pattern = "^(https?://[%w%-%._]+%.%w+(:?%d*)/?[%w%-%./%?%=%&_#]*)$"
    local u,p = url:match(pattern)
    if u ~= nil and (p == nil or p == '' or (p:match(":%d+") ~= nil)) then
        return true
    end
    return false
end

--- Checks if a value is callable (function or table with __call metamethod).
--- @param value any The value to check
--- @return boolean True if value can be called as a function, false otherwise
local function isCallable(value)
    local t = type(value)
    if t == "function" then
        return true
    end
    if t == "table" then
        local success, mt = pcall(getmetatable, value)
        if success and type(mt) == "table" and type(mt.__call) == "function" then
            return true
        end
    end
    return false
end

-- Simple UTF8 validation function
local function isValidUTF8(str)
    return (type(str) == "string") and (utf8.len(str) ~= nil)
end

-- Simple ASCII validation function (all bytes must be 0-127)
local function isValidASCII(str)
    if type(str) ~= "string" then
        return false
    end
    for i = 1, #str do
        if str:byte(i) > 127 then
            return false
        end
    end
    return true
end

-- Simple Lua Regex validation function
local function isValidRegex(pattern)
             -- Use pcall to catch any errors from invalid patterns
    local success = pcall(string.find, "", pattern)
    if success then
        return true
    end
    return false
end

--- Tests that a predicate function is safe and well-behaved.
--- Verifies the predicate never errors and always returns a boolean for various input types.
--- @param predicate function The predicate function to test
--- @param name string The name of the predicate (for error messages)
--- @error Throws if predicate is not a function or returns non-boolean for any test input
local function testPredicate(predicate, name)
    local err = name .. " must always return true or false"
    assert(type(predicate) == "function", "Not a function: "..name..":"..type(predicate))
    assert(type(predicate())== "boolean", err)
    assert(type(predicate(true))== "boolean", err)
    assert(type(predicate(false))== "boolean", err)
    assert(type(predicate(0))== "boolean", err)
    assert(type(predicate(1))== "boolean", err)
    assert(type(predicate(-1))== "boolean", err)
    assert(type(predicate(0.0))== "boolean", err)
    assert(type(predicate(1.0))== "boolean", err)
    assert(type(predicate(-1.0))== "boolean", err)
    assert(type(predicate(""))== "boolean", err)
    assert(type(predicate("a"))== "boolean", err)
    assert(type(predicate({}))== "boolean", err)
    assert(type(predicate({a=1}))== "boolean", err)
    assert(type(predicate(testPredicate))== "boolean", err)
end

-- Test all predicates of the API (only functions starting with "is")
local function testAllPredicates(api)
    for name, predicate in pairs(api) do
        if name:sub(1, 2) == "is" then
            testPredicate(predicate, name)
        end
    end
end

-- The public, versioned, API of this module
local API = {
    isBasic=isBasic,
    isBlankStr=isBlankStr,
    isBoolean=isBoolean,
    isCallable=isCallable,
    isComparable=isComparable,
    isDefault=isDefault,
    isFalse=isFalse,
    isFileName=isFileName,
    isFullSeq=isFullSeq,
    isIdentifier=isIdentifier,
    isInteger=isInteger,
    isIntegerValue=isIntegerValue,
    isValueKeyword=isValueKeyword,
    isMixedTable=isMixedTable,
    isName=isName,
    isNonBlankStr=isNonBlankStr,
    isNonDefault=isNonDefault,
    isNonEmptyStr=isNonEmptyStr,
    isNonEmptyTable=isNonEmptyTable,
    isNonZeroInteger=isNonZeroInteger,
    isNonZeroNumber=isNonZeroNumber,
    isNumber=isNumber,
    isPath=isPath,
    isPercent=isPercent,
    isPositiveInteger=isPositiveInteger,
    isPositiveNumber=isPositiveNumber,
    isString=isString,
    isTable=isTable,
    isTrue=isTrue,
    isValidASCII=isValidASCII,
    isValidHttpUrl=isValidHttpUrl,
    isValidRegex=isValidRegex,
    isValidUTF8=isValidUTF8,
    isVersion=isVersion,
    testPredicate=testPredicate,
}

-- Make sure all predicates are safe to use
testAllPredicates(API)

-- Maps predicate functions to their names
local PREDICATE_TO_NAME = inverseMapping(API)

-- All "shapes" for the predicates
API.SHAPES = buildShapes(API)

-- Returns the name of the predicate
API.getPredName = function(predicate)
    return PREDICATE_TO_NAME[predicate]
end

API.getVersion=getVersion

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

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
