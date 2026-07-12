-- Module name
local NAME = "string_utils"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 31, 0)

-- Dependencies
local read_only = require("util.read_only")
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

--- Computes the edit distance between two strings: the minimum number of
--- single-character insertions, deletions, substitutions, or transpositions
--- of two ADJACENT characters (Damerau-Levenshtein, optimal string alignment
--- variant) needed to turn `a` into `b`. Case-sensitive and byte-based (each
--- byte of a multi-byte UTF-8 character counts separately); intended for
--- identifiers and file names, not prose.
--- @param a string First string
--- @param b string Second string
--- @return number The edit distance (0 means equal)
--- @error Throws if a or b is not a string
local function editDistance(a, b)
    assert(type(a) == "string", "a must be a string, got " .. type(a))
    assert(type(b) == "string", "b must be a string, got " .. type(b))
    if a == b then
        return 0
    end
    local la, lb = #a, #b
    if la == 0 then
        return lb
    end
    if lb == 0 then
        return la
    end
    -- Rolling rows of the distance matrix; prev2 lags two rows behind so an
    -- adjacent transposition can be scored as a single edit.
    local prev2 = nil
    local prev = {}
    for j = 0, lb do
        prev[j] = j
    end
    for i = 1, la do
        local cur = {[0] = i}
        local ca = a:byte(i)
        for j = 1, lb do
            local cb = b:byte(j)
            local best = prev[j - 1] + (ca == cb and 0 or 1)
            local del = prev[j] + 1
            if del < best then best = del end
            local ins = cur[j - 1] + 1
            if ins < best then best = ins end
            if i > 1 and j > 1 and ca == b:byte(j - 1) and a:byte(i - 1) == cb then
                local swap = prev2[j - 2] + 1
                if swap < best then best = swap end
            end
            cur[j] = best
        end
        prev2 = prev
        prev = cur
    end
    return prev[lb]
end

--- Finds the candidate string closest to `value` by editDistance(), for
--- "did you mean ...?" suggestions. Candidates are scanned in order and the
--- FIRST one with the smallest distance wins, so pass a sorted list when
--- deterministic output matters. Case-sensitive — lowercase both sides first
--- for a case-insensitive match.
--- @param value string The string to find a near match for
--- @param candidates table Sequence of candidate strings
--- @param opt_maxDistance number|nil Reject candidates farther than this;
---   defaults to min(3, floor(#value / 4) + 1), i.e. stricter for short
---   strings so unrelated short names are not offered as suggestions
--- @return string|nil The closest candidate within the limit, or nil
--- @return number|nil Its edit distance, when a candidate was returned
--- @error Throws if value is not a string or candidates is not a table
local function closestMatch(value, candidates, opt_maxDistance)
    assert(type(value) == "string", "value must be a string, got " .. type(value))
    assert(type(candidates) == "table", "candidates must be a table, got " .. type(candidates))
    local maxDistance = opt_maxDistance or math.min(3, math.floor(#value / 4) + 1)
    local best = nil
    local bestDist = maxDistance + 1
    for _, candidate in ipairs(candidates) do
        local d = editDistance(value, candidate)
        if d < bestDist then
            best = candidate
            bestDist = d
            if d == 0 then
                break
            end
        end
    end
    if best then
        return best, bestDist
    end
    return nil
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    closestMatch=closestMatch,
    editDistance=editDistance,
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
