-- Module name
local NAME = "regex_utils"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 8, 0)

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- Our utils
local sparse_sequence = require("sparse_sequence")
local insertRemoveNils = sparse_sequence.insertRemoveNils
local read_only = require("read_only")
local readOnly = read_only.readOnly

local predicates = require("predicates")
local isValidRegex = predicates.isValidRegex

local lua_to_pcre = {
    -- Character classes
    ['%a'] = '[[:alpha:]]',   -- letters
    ['%A'] = '[^[:alpha:]]',  -- not letters
    ['%l'] = '[[:lower:]]',   -- lower case letters
    ['%L'] = '[^[:lower:]]',  -- not lower case letters
    ['%u'] = '[[:upper:]]',   -- upper case letters
    ['%U'] = '[^[:upper:]]',  -- not upper case letters
    ['%d'] = '\\d',           -- digits
    ['%D'] = '\\D',           -- not digits
    -- Lua %w is NOT the same as PCRE \\w ; %w is [a-zA-Z0-9] while \\w also contains _
    ['%w'] = '[a-zA-Z0-9]',   -- alphanumeric WITHOUT _
    ['%W'] = '[^a-zA-Z0-9]',  -- not alphanumeric WITHOUT _
    ['%s'] = '\\s',           -- whitespace
    ['%S'] = '\\S',           -- not whitespace
    ['%p'] = '[[:punct:]]',   -- punctuation
    ['%P'] = '[^[:punct:]]',  -- not punctuation
    ['%c'] = '[[:cntrl:]]',   -- control characters
    ['%C'] = '[^[:cntrl:]]',  -- not control characters
    ['%x'] = '[[:xdigit:]]',  -- hex digits
    ['%X'] = '[^[:xdigit:]]', -- not hex digits
    --['%z'] = '\\0',           -- NOT SUPPORTED
    --['%Z'] = '[^\\0]',        -- NOT SUPPORTED

    -- Magic characters that need escaping
    ['%('] = '\\(',
    ['%)'] = '\\)',
    ['%.'] = '\\.',
    ['%%'] = '%',
    ['%+'] = '\\+',
    ['%-'] = '\\-',
    ['%*'] = '\\*',
    ['%?'] = '\\?',
    ['%['] = '\\[',
    ['%]'] = '\\]',
    ['%^'] = '\\^',
    ['%$'] = '\\$'
}

--- Translates a Lua pattern to an equivalent PCRE pattern.
--- Supports most Lua pattern features except: balanced patterns (%b), frontier patterns (%f),
--- and capture references (%1, %2, etc.).
--- @param pattern string The Lua pattern to translate
--- @return string|nil The equivalent PCRE pattern, or nil on error
--- @return string|nil Error message if translation failed, nil on success
--- @see https://www.pcre.org/original/doc/html/pcrepattern.html
--- @see https://www.lua.org/pil/20.2.html
local function translateLuaPatternToPCRE(pattern)
    -- Check for nil or empty pattern
    if type(pattern) ~= "string" or pattern == "" then
        return nil, "Pattern must be a non-empty string"
    end
    if not isValidRegex(pattern) then
        return nil, "Invalid pattern: "..pattern
    end

    -- First preserve %% as \0 (temporary)
    if pattern:find('\0') then
        return nil, "\\0 not allowed, as it's used internally"
    end
    -- We use two \0's to preserve the *length* of %%
    local result = pattern:gsub('%%%%', '\0\0')

    -- First catch unsupported features
    local pos = 1
    while pos <= #result do
        -- Find next % sequence
        local seq_start = result:find('%', pos, true)
        if not seq_start then break end

        if seq_start == #result then
            return nil, "Trailing % at end of pattern"
        end

        local seq = result:sub(seq_start, seq_start + 1)
        if seq == "%b" then
            return nil, "Balanced pattern match is not supported"
        elseif seq == "%f" then
            return nil, "Frontier pattern is not supported"
        elseif result:sub(seq_start + 1, seq_start + 1):match("%d") then
            return nil, "Capture references are not supported"
        end

        pos = seq_start + 2
    end

    -- Check for unmatched brackets
    local bracket_stack = 0
    local in_class = {}
    local char_class_start = {}
    local char_class_end = {}
    local char_class_neg = {}
    for i = 1, #result do
        local c = result:sub(i, i)
        local unescaped = i == 1 or result:sub(i-1, i-1) ~= '%'
        if c == '[' and unescaped then
            bracket_stack = bracket_stack + 1
            if bracket_stack > 1 then
                return nil, string.format("Nested [] at position %d", i)
            end
            char_class_start[i] = true
            if i < #result then
                local next_c = result:sub(i+1, i+1)
                if next_c == '^' then
                    char_class_neg[i] = true
                end
            end
        elseif c == ']' and unescaped then
            bracket_stack = bracket_stack - 1
            if bracket_stack < 0 then
                return nil, string.format("Unmatched ] at position %d", i)
            end
            char_class_end[i] = true
        end
        in_class[i] = (bracket_stack > 0) or char_class_end[i] or false
    end
    if bracket_stack > 0 then
        return nil, "Unclosed character class"
    end

    -- Then handle character classes and escaped chars
    pos = 1
    while true do
        local s, e = result:find('%%[%w%p]', pos)
        if not s then break end
        
        local sequence = result:sub(s, e)
        local replacement = lua_to_pcre[sequence]
        if not replacement then
            return nil, string.format("Invalid or unsupported character class '%s'",
                sequence)
        end
        -- Find a way to handle the special case of [%w_] or [_%w] to \\w
        -- Note that [%W_] is NOT the same as \\W ; [^%w_] is the same as \\W
        if in_class[s] then
            if result:sub(e+1, e+1) == "_" then
                if sequence == "%w" then
                    sequence = "%w_"
                    replacement = "\\w"
                    e = e + 1
                end
            elseif result:sub(s-1, s-1) == "_" then
                -- If in_class[s] and the previous character is _ then _ is also "in_class"
                -- Also, s can never be 1, because if we are in_class[s] ans result[s] == '%'
                -- then there must still be a [ somewhere before s
                if sequence == "%w" then
                    sequence = "%w_" -- Really, "_%w"
                    replacement = "\\w"
                    s = s - 1
                end
            end
        end
        if in_class[s] then
            local c = sequence:sub(2, 2)
            -- Did we find a "character class" (%x) inside a character class([...])?
            local c_lower = (c >= 'a' and c <= 'z')
            local c_upper = (c >= 'A' and c <= 'Z')
            if c_lower or c_upper then
                local repl_bracket = (replacement:sub(1,1) == '[')
                -- Only characters classes that are replaced with "brackets" can cause problems
                if repl_bracket then
                    -- If the sequence is "negative" (uppercase) AND the replacement starts with [
                    -- Then we know that the replacement character class is negative ([^...)
                    if c_upper then
                        return nil, string.format("'Negative' character classes '%s' not "..
                            "currently supported inside brackets at position %d",
                            sequence, s)
                    end
                    -- We are already inside brackets, and the replacement is also inside brackets
                    -- so we need to remove the brackets in the replacement sequence
                    replacement = replacement:sub(2,-2)
                end
            end
        end
        result = result:sub(1, s-1) .. replacement .. result:sub(e+1)
        pos = s + #replacement
        for i = s, s + #sequence - 1 do
            in_class[i] = true
        end
        -- If replacement is longer than sequence, the result got bigger, and we need to *insert*
        -- instead of replacing in in_class
        local added_chars = #replacement - #sequence
        if added_chars > 0 then
            for i = s, s + added_chars - 1 do
                table.insert(in_class, i, true)
            end
        elseif added_chars < 0 then
            -- Only possible if replacing [%w_] to \\w or [%W_] to \\W
            for i = 0, -added_chars do
                table.remove(in_class, pos)
            end
        end
        insertRemoveNils(char_class_start, s, added_chars)
        insertRemoveNils(char_class_end, s, added_chars)
        insertRemoveNils(char_class_neg, s, added_chars)
        -- Note: if in_class[s] then, char_class_start/char_class_end will overlap the [] start/end
        char_class_start[s] = true
        char_class_end[pos-1] = true
    end

    -- Restore %% as %
    result = result:gsub('\0\0', '%%')

    -- Look for unescaped magic characters outside character classes
    pos = 1
    while pos <= #result do
        local c = result:sub(pos, pos)
        local unescaped = (pos == 1 or result:sub(pos-1, pos-1) ~= '\\')
        if (not in_class[pos]) and unescaped and ((c == '-') or (pos > 1 and c == '^')
            or (pos < #result and c == '$')) then
            -- The un-escaped - character has special meaning outside character classes in Lua
            -- And could cause trouble if allowed outside character classes
            return nil, string.format("Unescaped magic character '%s' at position %d",
                c, pos)
        end
        pos = pos + 1
    end

    -- Finally handle anchors, but only if they weren't escaped
    if result:sub(1,1) == '^' then
        result = '\\A' .. result:sub(2)
    end
    if result:sub(-1) == '$' and result:sub(-2,-2) ~= '\\' then
        result = result:sub(1,-2) .. '\\Z'
    end

    -- | is a special character in PCRE
    result = result:gsub('|', '\\|')

    return result, nil
end

--- Splits a multi-pattern string into individual patterns.
--- Patterns are separated by '|'. Use '%|' to match a literal '|'.
--- @param pattern string The multi-pattern string to split
--- @return table|nil A sequence of individual patterns, or nil on error
--- @return string|nil Error message if invalid, nil on success
local function splitPatterns(pattern)
    -- Check for nil or empty pattern
    if type(pattern) ~= "string" or pattern == "" then
        return nil, "Pattern must be a non-empty string"
    end
    local orig = pattern

    -- First preserve %| and %% as \0 (temporary marker) and \1 respectively
    if pattern:find('[\0\1]') then
        return nil, "\\0 and \\1 not allowed in pattern, as they're used internally"
    end
    pattern = pattern:gsub('%%%%', '\1')  -- First preserve %% as \1
    pattern = pattern:gsub('%%|', '\0')   -- Then preserve %| as \0

    -- Now we can safely split on unescaped |
    local patterns = {}
    local current = ""
    local i = 1
    while i <= #pattern do
        local c = pattern:sub(i, i)
        if c == '|' then
            if current == "" then
                return nil, "Empty pattern found at position " .. i
            end
            patterns[#patterns + 1] = current
            current = ""
        else
            current = current .. c
        end
        i = i + 1
    end

    -- Don't forget the last pattern
    if current == "" then
        return nil, "Empty pattern found at end of string"
    end
    patterns[#patterns + 1] = current

    -- Now restore %| and %% in each pattern
    for i = 1, #patterns do
        patterns[i] = patterns[i]:gsub('\0', '|')
        patterns[i] = patterns[i]:gsub('\1', '%%%%')
        if not isValidRegex(patterns[i]) then
            return nil, "Invalid pattern: "..orig
        end
    end

    for _, p in ipairs(patterns) do
            -- Use pcall to catch any errors from invalid patterns
        local success, err = pcall(string.find, "", p)
        if not success then
            return nil, "Bad split pattern for " .. pattern .. ": " .. tostring(err)
        end
    end

    return patterns
end

-- Cache for multiMatcher()
local multiMatcher_cache = {}
local multiMatcher_cache_size = 0

--- Creates a matcher function from a multi-pattern string.
--- The matcher returns true if any of the patterns match the input.
--- Results are cached for performance.
--- @param pattern string Multi-pattern string with '|' separators (use '%|' for literal '|')
--- @return function|nil A matcher function(input) -> boolean, or nil on error
--- @return string|nil Error message if pattern is invalid, nil on success
local function multiMatcher(pattern)
    -- Check for nil or empty pattern
    if type(pattern) ~= "string" or pattern == "" then
        return nil, "Pattern must be a non-empty string"
    end
    local tmp = multiMatcher_cache[pattern]
    if tmp ~= nil then
        if type(tmp) == "string" then
            return nil, tmp
        end
        return tmp
    end
    local patterns, err = splitPatterns(pattern)
    if not patterns then
        multiMatcher_cache[pattern] = err
        multiMatcher_cache_size = multiMatcher_cache_size + 1
        return nil, err
    end
    local result = function(input)
        for _, pattern in ipairs(patterns) do
            if string.find(input, pattern) then
                return true
            end
        end
        return false
    end
    multiMatcher_cache[pattern] = result
    multiMatcher_cache_size = multiMatcher_cache_size + 1
    return result
end

--- Clears the multi-matcher cache.
--- @side_effect Resets the cache to empty
local function clearMultiMatcherCache()
    multiMatcher_cache = {}
    multiMatcher_cache_size = 0
end

--- Returns the number of entries in the multi-matcher cache.
--- @return number The cache size
local function multiMatcherCacheSize()
    return multiMatcher_cache_size
end

--- Translates a multi-pattern string to a single PCRE alternation pattern.
--- Each pattern is wrapped in a non-capturing group and joined with '|'.
--- @param pattern string Multi-pattern string with '|' separators
--- @return string|nil The combined PCRE pattern, or nil on error
--- @return string|nil Error message if invalid, nil on success
local function translateMultiPatternToPCRE(pattern)
    -- Split the pattern into individual Lua patterns
    local patterns, err = splitPatterns(pattern)
    if not patterns then
        return nil, err
    end

    -- Translate each pattern to PCRE
    local pcre_patterns = {}
    for i, p in ipairs(patterns) do
        local pcre, err = translateLuaPatternToPCRE(p)
        if not pcre then
            return nil, string.format("Pattern #%d: %s", i, err)
        end
        pcre_patterns[i] = "(?:" .. pcre .. ")"  -- Wrap each pattern in non-capturing group
    end

    -- Join all patterns with | to create alternation
    return table.concat(pcre_patterns, "|")
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    clearMultiMatcherCache = clearMultiMatcherCache,
    multiMatcher = multiMatcher,
    multiMatcherCacheSize = multiMatcherCacheSize,
    splitPatterns = splitPatterns,
    translateLuaPatternToPCRE = translateLuaPatternToPCRE,
    translateMultiPatternToPCRE = translateMultiPatternToPCRE,
    getVersion = getVersion
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
