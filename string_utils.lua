-- Module name
local NAME = "string_utils"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 5, 2)

-- Dependencies
local read_only = require("read_only")
local readOnly = read_only.readOnly

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

--- Removes leading and trailing whitespace from a string.
--- @param s string The string to trim
--- @return string The trimmed string
--- @error Throws if s is not a string
local function trim(s)
    assert(type(s) == "string", "Input must be a string, got " .. type(s))
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

--- Splits a string into a sequence of substrings based on a delimiter.
--- @param source string The string to split
--- @param delimiter string|nil The delimiter string (default: '\t' tab character)
--- @return table A sequence of substrings; always contains at least one element
--- @error Throws if source is not a string or delimiter is not a string/nil
local function split(source, delimiter)
    assert(type(source) == "string", "source must be a string, got " .. type(source))
    assert(delimiter == nil or type(delimiter) == "string",
    "delimiter must be a string or nil, got " .. type(delimiter))
    local d = delimiter or '\t'
    local elements = {}
    local start = 1
    local d_len = #d

    while true do
        local pos = source:find(d, start, true)
        if pos then
            elements[#elements + 1] = source:sub(start, pos - 1)
            start = pos + d_len
        else
            elements[#elements + 1] = source:sub(start)
            break
        end
    end

    return elements
end

--- Escapes a string for use in TSV files.
--- Converts Windows/Mac line endings to Unix-style, then escapes tabs, newlines, and backslashes.
--- @param text string The text to escape
--- @return string The escaped string with \t, \n, and \\ escape sequences
--- @error Throws if text is not a string
--- @side_effect Normalizes line endings to Unix-style (\n)
local function escapeText(text)
    assert(type(text) == "string", "text must be a string, got " .. type(text))
    -- First, make sure we use Unix-style EOLs
    return text:gsub('\r\n?', '\n'):gsub("[\t\n\\]", {
        ["\t"] = "\\t",
        ["\n"] = "\\n",
        ["\\"] = "\\\\"
    })
end

--- Unescapes a TSV-escaped string back to original text.
--- Converts \t and \n escape sequences back to tab and newline characters.
--- Also normalizes any Windows/Mac line endings to Unix-style.
--- @param escaped string The escaped string to unescape
--- @return string The unescaped string
--- @error Throws if escaped is not a string
--- @side_effect Normalizes line endings to Unix-style (\n)
local function unescapeText(escaped)
    assert(type(escaped) == "string", "escaped must be a string, got " .. type(escaped))
    return escaped:gsub("\\(.)", function(c)
        if c == "t" then
            return "\t"
        elseif c == "n" then
            return "\n"
        else
            return c
        end
    end):gsub('\r\n?', '\n')
end

--- Converts any string to a valid Lua identifier string.
--- Valid identifier characters (a-z, A-Z, 0-9, _) are kept as-is.
--- Invalid characters are converted to hex format (0xXX for each byte).
--- Result always starts with underscore to ensure validity.
--- @param str string The string to convert
--- @return string A valid Lua identifier representing the input string
--- @error Throws if str is not a string
local function stringToIdentifier(str)
    assert(type(str) == "string", "str must be a string, got " .. type(str))

    -- Result starts with underscore
    local result = {"_"}

    -- Convert each character
    for _, cp in utf8.codes(str) do
        local c = utf8.char(cp)
        -- Check if character is valid for identifiers
        if c:match("^[%a%d_]$") then
            -- Valid character, append as-is
            result[#result + 1] = c
        else
            -- Invalid identifier character, convert to hex
            for i = 1, #c do
                result[#result + 1] = string.format("0x%02X", string.byte(c, i))
            end
        end
    end

    return table.concat(result)
end

--- Parses a semantic version string into a semver object.
--- @param version string A version string in "major.minor.patch" format (e.g., "1.2.3")
--- @return table|nil The semver object if valid, nil otherwise
--- @return string|nil Error message if parsing failed, nil on success
local function parseVersion(version)
    if type(version) ~= "string" then
        return nil, "version must be a string: " .. type(version)
    end
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
    if not major then
        return nil, "invalid version string: " .. version
    end
    return semver(tonumber(major), tonumber(minor), tonumber(patch))
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    escapeText=escapeText,
    getVersion=getVersion,
    parseVersion=parseVersion,
    split=split,
    stringToIdentifier=stringToIdentifier,
    trim=trim,
    unescapeText=unescapeText,
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
