-- parsers/builtin.lua
-- Built-in parser implementations

local state = require("parsers.state")
local utils = require("parsers.utils")
local lpeg_parser = require("parsers.lpeg_parser")
local generators = require("parsers.generators")

local lpeg = require("lpeg")
local semver = require("semver")

local string_utils = require("string_utils")
local escapeText = string_utils.escapeText
local unescapeText = string_utils.unescapeText
local parseVersion = string_utils.parseVersion

local predicates = require("predicates")
local isString = predicates.isString
local isName = predicates.isName
local isIdentifier = predicates.isIdentifier
local isPercent = predicates.isPercent
local isIntegerValue = predicates.isIntegerValue
local isValidASCII = predicates.isValidASCII
local isValidUTF8 = predicates.isValidUTF8
local isValidHttpUrl = predicates.isValidHttpUrl

local regex_utils = require("regex_utils")

local base64 = require("base64")

local error_reporting = require("error_reporting")
local badValGen = error_reporting.badValGen
local nullBadVal = error_reporting.nullBadVal

local serialization = require("serialization")
local serializeTable = serialization.serializeTable

local M = {}

-- Safe integer range constants (IEEE 754 double precision)
-- Values within this range can be exactly represented as doubles
local SAFE_INTEGER_MIN = -9007199254740992  -- -(2^53)
local SAFE_INTEGER_MAX = 9007199254740992   -- 2^53

-- Detect if we have native 64-bit integers (Lua 5.3+)
local HAS_NATIVE_INTEGERS = (math.type ~= nil and math.type(1) == "integer")

-- badVal used during registration of "default parsers" within this module
local ownBadVal = badValGen()
ownBadVal.logger = state.logger

-- Forward declarations (set by init.lua)
local parseType
local registration

-- Set references (called by init.lua)
function M.setReferences(pT, reg)
    parseType = pT
    registration = reg
end

-- ============================================================
-- Primitive Parsers
-- ============================================================

-- A boolean value
-- We are purposefully "lenient" and accept user-input that "means" true or false
state.PARSERS.boolean = function (badVal, value, context)
    local t = type(value)
    if utils.expectTSV(context) then
        if t == "boolean" then
            utils.log(badVal, 'boolean', value,
                "context was 'tsv', was expecting a string")
            return nil, tostring(value)
        end
    end
    -- Even if we are NOT in tsv context, it could still be a string ('yes', 'no', ...)
    if t == "boolean" then
        return value, tostring(value)
    end
    if t ~= "string" then
        utils.log(badVal, 'boolean', value)
        return nil, tostring(value)
    end
    local lc = value:lower()
    if lc == 'true' or lc == 'yes' or lc == '1' then
        return true, 'true'
    elseif lc == 'false' or lc == 'no' or lc == '0' then
        return false, 'false'
    else
        utils.log(badVal, 'boolean', value)
        return nil, value
    end
end
state.COMPARATORS.boolean = function (a, b)
    -- false comes before true
    return a == false and b == true
end

-- A string value (must be valid UTF-8)
state.PARSERS.string = function (badVal, value, context)
    utils.expectTSV(context) -- Just for side-effects
    if type(value) ~= "string" then
        utils.log(badVal, 'string', value)
        return nil, tostring(value)
    end
    if not isValidUTF8(value) then
        utils.log(badVal, 'string', value, "invalid UTF-8 encoding")
        return nil, value
    end
    return value, value
end
state.COMPARATORS.string = function (a, b)
    return string.lower(a) < string.lower(b)
end

-- Any number, float or integer
state.PARSERS.number = function (badVal, value, context)
    local t = type(value)
    if utils.expectTSV(context) then
        if t ~= "string" then
            utils.log(badVal, 'number', value,
                "context was 'tsv', was expecting a string")
            return nil, tostring(value)
        end
        local num = tonumber(value)
        if num == nil then
            utils.log(badVal, 'number', value)
            return nil, tostring(value)
        else
            -- Note: Do NOT use (num+0.0) here, as that would convert 64-bit integers
            -- to floats, losing precision for values outside the safe integer range
            return num, tostring(num)
        end
    else
        if t ~= "number" then
            utils.log(badVal, 'number', value,
                "context was 'parsed', was expecting a number")
            return nil, tostring(value)
        end
        -- Note: Do NOT use (value+0.0) here, as that would convert 64-bit integers
        -- to floats, losing precision for values outside the safe integer range
        return value, tostring(value)
    end
end
state.COMPARATORS.number = function (a, b)
    return a < b
end

-- (Almost) Any Lua table. Recursive tables, and extremely deep tables are not supported,
-- because serializeTable() and parseTableStr() would fail in those cases.
state.PARSERS.table = function (badVal, value, context)
    local t = type(value)
    if utils.expectTSV(context) then
        if t ~= "string" then
            utils.log(badVal, 'table', value,
                "context was 'tsv', was expecting a string")
            return nil, tostring(value)
        end
        return utils.table_parser(badVal, 'table', value)
    end
    if t ~= "table" then
        utils.log(badVal, 'table', value,
            "context was 'parsed', was expecting a table")
        return nil, tostring(value)
    end
    return value, utils.serializeTableWithoutCB(value)
end
state.COMPARATORS.table = function (a, b)
    return state.COMPARATORS.string(serializeTable(a), serializeTable(b))
end

-- Parser 'nil' only defined, to make it possible to specify "optional values".
-- It should never be used otherwise. Note: 'nil' is a keyword
state.PARSERS["nil"] = function (badVal, value, context)
    if utils.expectTSV(context) then
        -- In TSV context, nil (missing column) or empty string both represent nil
        if value == nil then
            return nil, ""
        end
        if type(value) ~= "string" then
            utils.log(badVal, 'nil', value,
                "context was 'tsv', was expecting a string")
            return nil, tostring(value)
        end
        if value ~= '' then
            utils.log(badVal, 'nil', value,
                "nil should be represented with ''")
            return nil, tostring(value)
        end
    else
        if value ~= nil and value ~= '' then
            utils.log(badVal, 'nil', value,
                "context was 'parsed', was expecting (nil)/''")
            return nil, tostring(value)
        end
    end
    return nil, ""
end
generators.registerComparator("nil", function (_a, _b)
    -- There is only one value, so a always equals b, and therefore a < b is always false
    return false
end)

-- "percent" is a string; either a number followed by a "%", or a fraction.
-- The valid percent values are defined by the isPercent() predicate.
-- If used in calculations, either the number followed by a % is divided by 100,
-- or the fraction is computed.
state.PARSERS.percent = function (badVal, value, context)
    utils.expectTSV(context) -- Just for side-effects
    -- Will also handle the case where the value is not even a string
    if not isPercent(value) then
        local t = type(value)
        if t == 'number' or (t == 'string' and tonumber(value) ~= nil) then
            utils.log(badVal, 'percent', value,
                'percent must be a string ending with % or be a fraction')
            local num = tonumber(value)
            if isIntegerValue(num) then
                num = math.floor(num)
            end
            local p = num/100.0
            return p, tostring(num)..'%'
        else
            utils.log(badVal, 'percent', value)
            return nil, tostring(value)
        end
    end
    if value:sub(-1) == "%" then
        local num = tonumber(value:sub(1, #value-1))
        if num then
            if isIntegerValue(num) then
                num = math.floor(num)
            end
            local p = num/100.0
            return p, tostring(num)..'%'
        end
    else
        local idx = value:find("/")
        if idx and idx > 1 and idx < #value then
            local nom = tonumber(value:sub(1, idx-1))
            if nom then
                local denom = tonumber(value:sub(idx+1))
                if denom then
                    return nom/denom, value
                end
            end
        end
    end
    -- Theoretically impossible, if isPercent(value) works correctly
    utils.log(badVal, 'percent', value)
    return nil, value
end
-- "percent" only logically extends "number", because it produces a number as a parsed value,
-- but the "input" format does not match the number format
generators.extendsOrRestrictsType('percent', 'number')
state.COMPARATORS.percent = state.COMPARATORS.number

-- A true value, useful only to create "sets" Note: 'true' is a keyword
state.PARSERS["true"] = function (badVal, value, context)
    if utils.expectTSV(context) then
        if type(value) ~= "string" then
            utils.log(badVal, 'true', value,
                "context was 'tsv', was expecting a string")
            return nil, tostring(value)
        end
        if value ~= 'true' then
            utils.log(badVal, 'true', value)
            return nil, tostring(value)
        end
    else
        if value ~= true then
            utils.log(badVal, 'true', value)
            return nil, tostring(value)
        end
    end
    return true, "true"
end
-- "true" only logically extends "boolean", because "boolean" accepts things like "yes", and even
-- "true" (string) in "parsed" context
generators.extendsOrRestrictsType('true', 'boolean')
generators.registerComparator('true', state.COMPARATORS.boolean)

-- Most "default parsers" do NOT parse a value to a table
for name, _ in pairs(state.PARSERS) do
    state.NEVER_TABLE[name] = true
end
state.NEVER_TABLE.table = nil

-- ============================================================
-- Markdown Validator
-- ============================================================

-- Creates and returns a function that validates markdown strings
local function createMarkdownValidator()
    local P, R, S, V = lpeg.P, lpeg.R, lpeg.S, lpeg.V

    -- Basic character sets
    local alpha = R("AZ", "az")
    local whitespace = S(" \t")
    local newline = P("\n")
    local space = whitespace^0

    -- Inline elements
    local escape = P("\\") * S([[`*_{}[]()#+-.!]])
    local inline_text = (1 - S("*_`\n\\[]#"))^1
    local asterisk = P("*")
    local underscore = P("_")
    local backtick = P("`")

    -- Emphasis patterns
    local em_content = (1 - S("*_\n"))^1
    local strong_content = (1 - S("*_\n"))^1
    local emphasis = (asterisk * em_content * asterisk) + (underscore * em_content * underscore)
    local strong = (asterisk * asterisk * strong_content * asterisk * asterisk) +
                (underscore * underscore * strong_content * underscore * underscore)

    -- Code patterns
    local inline_code = backtick * (1 - backtick)^1 * backtick
    local code_fence = P("```")
    local code_lang = (alpha^1 * newline) + newline
    local code_content = ((1 - code_fence) + (code_fence * #(1 - newline)))^0 * (newline^-1)
    local code_block = code_fence * code_lang * code_content * code_fence * newline

    -- Headers
    local header_marker = P("#")^1 * whitespace^1
    local header_content = (1 - newline)^0
    local header = header_marker * header_content * newline

    -- Lists
    local list_marker = (P("-") + P("*") + P("+")) * whitespace^1
    local list_content = (1 - newline)^0
    local list_item = list_marker * list_content * newline
    local list = list_item^1

    -- Links
    local no_brackets = (1 - S("[]()"))^1
    local link_text = P("[") * no_brackets * P("]")
    local link_url = P("(") * no_brackets * P(")")
    local link = link_text * link_url

    -- Blockquotes
    local blockquote_marker = P(">") * whitespace^1
    local blockquote_content = (1 - newline)^0
    local blockquote = blockquote_marker * blockquote_content * newline

    -- Invalid patterns that should not be treated as paragraphs
    local invalid_marker = P("#") + P(">") + P("-") + P("*") + P("+")

    -- Looking ahead that we're not inside an unmatched bracket or code block
    local not_in_brackets = P(function(s, i)
        local count = 0
        local j = 1
        while j < i do
            if s:sub(j,j) == '[' then
                count = count + 1
            elseif s:sub(j,j) == ']' then
                count = count - 1
            end
            j = j + 1
        end
        return count <= 0 and i
    end)

    -- Block-level grammar
    local markdown = P{
        "Document",
        Document = (V("Block")^1 + P("")) * -1,
        Block = V("BlankLine") + V("Header") + V("CodeBlock") + V("List") +
            V("Blockquote") + V("Paragraph"),
        BlankLine = newline,
        Header = header,
        CodeBlock = code_block,
        List = list,
        Blockquote = blockquote,
        Inline = emphasis + strong + inline_code + link + escape + inline_text,
        ParagraphStart = (1 - (newline + invalid_marker))^1 * not_in_brackets,
        InlineContent = V("ParagraphStart") * V("Inline")^0 *
                    (newline - (P("```") + P("#") + P(">") + P("-") + P("*") + P("+"))),
        Paragraph = V("InlineContent")^1 * newline^0
    }

    -- The main validation function
    local function isValidMarkdown(text)
        if type(text) ~= "string" then
            return false
        end

        -- Empty string is invalid
        if text == "" then
            return false
        end

        -- Ensure consistent line endings (in theory this is not possible anyway)
        text = text:gsub("\r\n", "\n")
        -- Add trailing newline if missing
        if text:sub(-1) ~= "\n" then
            text = text .. "\n"
        end

        -- Simple check for unclosed code blocks (has opening fence but no closing fence)
        if text:match("```") and not text:match("```.*```") then
            return false
        end

        return markdown:match(text) ~= nil
    end

    return isValidMarkdown
end

-- The markdown validator instance
M.markdownValidator = createMarkdownValidator()

-- ============================================================
-- Register Extended/Restricted Parsers
-- This function is called by init.lua after all modules are loaded
-- ============================================================

function M.registerDerivedParsers()
    -- Comments are just "strings" with a special meaning. They are only used by the user
    -- and are not processed as data. Comments are purged at the end of the data processing.
    registration.restrictWithValidator(ownBadVal, 'string', 'comment', isString)

    -- ASCII-only string (all bytes must be 0-127)
    -- Must be registered before types that extend it (name, type, type_spec, version, cmp_version)
    registration.restrictWithValidator(ownBadVal, 'string', 'ascii', isValidASCII)

    -- Hex-encoded binary data (uppercase, even length)
    -- E.g. "48656C6C6F" represents the bytes for "Hello"
    registration.extendParser(ownBadVal, 'ascii', 'hexbytes',
    function (badVal, value, _reformatted, _context)
        if #value % 2 ~= 0 then
            utils.log(badVal, 'hexbytes', value,
                "hex string must have even length")
            return nil, value
        end
        if value:find("[^0-9A-Fa-f]") then
            utils.log(badVal, 'hexbytes', value,
                "invalid hex character (expected 0-9, A-F)")
            return nil, value
        end
        local upper = value:upper()
        return upper, upper
    end)

    -- Base64-encoded binary data (RFC 4648 standard alphabet with '=' padding)
    -- E.g. "SGVsbG8=" represents the bytes for "Hello"
    registration.extendParser(ownBadVal, 'ascii', 'base64bytes',
    function (badVal, value, _reformatted, _context)
        if not base64.isValid(value) then
            utils.log(badVal, 'base64bytes', value,
                "invalid base64 encoding")
            return nil, value
        end
        -- Round-trip to canonical form
        local decoded = base64.decode(value)
        if not decoded then
            utils.log(badVal, 'base64bytes', value,
                "failed to decode base64")
            return nil, value
        end
        local canonical = base64.encode(decoded)
        return canonical, canonical
    end)

    -- A name is a "chain" of identifiers
    -- E.g. "a.b.c"
    registration.restrictWithValidator(ownBadVal, 'ascii', 'name', isName)

    -- An individual identifier
    registration.restrictWithValidator(ownBadVal, 'name', 'identifier', isIdentifier)

    -- An HTTP(S) URL
    registration.restrictWithValidator(ownBadVal, 'string', 'http', isValidHttpUrl)

    -- "type" (specification) is a type that can be validated, INCLUDING validating referenced types.
    registration.extendParser(ownBadVal, 'ascii', 'type',
    function (badVal, value, _reformatted, _context)
        local parsed = lpeg_parser.type_parser(value)
        -- Check the format
        if not parsed then
            utils.log(badVal, 'type', value, "Cannot parse type specification")
            return nil, value
        end
        -- Check the type is actually valid/known
        local parser, type_spec = state.refs.parse_type(badVal, parsed)
        if parser then
            -- Since we don't support spaces in the spec, it should always be "optimally formatted"
            return type_spec, type_spec
        end
        -- parse_type already logged any errors
        return nil, type_spec
    end)

    -- type specification is a type that can be validated, EXCLUDING validating referenced types.
    registration.extendParser(ownBadVal, 'ascii', 'type_spec',
    function (badVal, value, _reformatted, _context)
        local parsed = lpeg_parser.type_parser(value)
        -- Check the format
        if not parsed then
            utils.log(badVal, 'type', value, "Cannot parse type specification")
            return nil, value
        end
        -- We do NOT check the type is actually valid/known
        local type_spec = lpeg_parser.parsedTypeSpecToStr(parsed)
        return type_spec, type_spec
    end)

    -- Register the "raw" union type ("table" is the super-type of all tables)
    -- Must be registered BEFORE 'any' which uses {type,raw}
    registration.registerAlias(ownBadVal, 'raw', 'boolean|number|table|string|nil')

    -- The "any" type is a "tagged union" of all types
    registration.restrictWithValidator(ownBadVal, '{type,raw}', 'any',
        function(parsed)
            local expected_type = parsed[1]
            local parsed_value = parsed[2]
            local parser = parseType(nullBadVal, expected_type)
            if not parser then
                return 'Bad type: ' .. expected_type
            end
            local validated, _ = generators.callParser(parser, nullBadVal, parsed_value, "parsed")
            if validated == nil then
                return 'Value does not match expected type ' .. expected_type
            end
            return true
        end)

    -- Text is a string that can contain escaped tabs and newlines.
    -- Tab is encoded as \t and newline as \n
    registration.extendParser(ownBadVal, 'string', 'text',
    function (_badVal, value, reformatted, context)
        if utils.expectTSV(context) then
            return unescapeText(value), value
        else
            return value, escapeText(value)
        end
    end)

    -- The markdown parser
    registration.extendParser(ownBadVal, 'text', 'markdown',
    function (_badVal, parsed, reformatted, _context)
        -- Accepts only valid markdown strings
        if M.markdownValidator(parsed) then
            return parsed, reformatted
        else
            return nil, reformatted
        end
    end)

    -- ASCII text is like text but restricted to ASCII characters.
    -- It can contain escaped tabs and newlines, like text.
    registration.extendParser(ownBadVal, 'ascii', 'asciitext',
    function (_badVal, value, reformatted, context)
        if utils.expectTSV(context) then
            local unescaped = unescapeText(value)
            -- Validate that the unescaped result is still ASCII
            if not isValidASCII(unescaped) then
                return nil, value
            end
            return unescaped, value
        else
            local escaped = escapeText(value)
            -- Validate that the escaped result is still ASCII
            if not isValidASCII(escaped) then
                return nil, escaped
            end
            return value, escaped
        end
    end)

    -- ASCII markdown is like markdown but restricted to ASCII characters.
    registration.extendParser(ownBadVal, 'asciitext', 'asciimarkdown',
    function (_badVal, parsed, reformatted, _context)
        -- Accepts only valid markdown strings
        if M.markdownValidator(parsed) then
            return parsed, reformatted
        else
            return nil, reformatted
        end
    end)

    -- Any integer within the safe integer range (±2^53)
    -- This range ensures values can be exactly represented as IEEE 754 doubles,
    -- making them compatible with JSON and LuaJIT
    registration.extendParser(ownBadVal, 'number', 'integer',
    function (badVal, num, _reformatted, _context)
        if not isIntegerValue(num) then
            utils.log(badVal, 'integer', num)
            return nil, tostring(num)
        end
        -- Validate within safe integer range
        if num < SAFE_INTEGER_MIN or num > SAFE_INTEGER_MAX then
            utils.log(badVal, 'integer', num,
                "value outside safe integer range (±2^53)")
            return nil, tostring(num)
        end
        -- Ensure we return an integer on Lua 5.3+
        if math.type and math.type(num) ~= 'integer' then
            num = math.floor(num)
        end
        return num, tostring(num)
    end)

    -- Helper to format a float with a decimal point (e.g., 5 -> "5.0")
    local function formatFloat(num)
        local s = tostring(num)
        -- If tostring produced scientific notation or already has a decimal, use as-is
        if s:find('[%.eE]') then
            return s
        end
        -- Otherwise add .0 to make it clear this is a float
        return s .. '.0'
    end

    -- A floating-point number (always formatted with decimal point)
    registration.extendParser(ownBadVal, 'number', 'float',
    function (_badVal, num, _reformatted, _context)
        -- Convert to float (this is safe since floats don't need 64-bit precision)
        num = num + 0.0
        return num, formatFloat(num)
    end)

    -- A version string
    registration.extendParser(ownBadVal, 'ascii', 'version',
    function (badVal, value, _reformatted, _context)
        -- parseVersion does not throw errors
        local v = parseVersion(value)
        if not v then
            utils.log(badVal, 'version', value)
            return nil, value
        end
        return v, tostring(v)
    end)

    -- A version comparison string.
    registration.extendParser(ownBadVal, 'ascii', 'cmp_version',
    function (badVal, value, _reformatted, _context)
        local req_op, req_version = value:match(state.VERSION_CMP_PATTERN)
        if req_op == nil or req_version == nil or not state.VALID_VERSION_COMPARATORS[req_op] then
            utils.log(badVal, 'cmp_version', value)
            return nil, value
        end
        if req_op == '==' then
            req_op = '='
        end
        local v = semver(req_version)
        local result = req_op..tostring(v)
        return result, result
    end)
    state.FORCE_REFORMATTED_AS_STRING.cmp_version = true
    -- cmp_version is designed to compare to raw version, not other cmp_versions
    -- Therefore we don't need a special comparator

    -- A regex string
    registration.extendParser(ownBadVal, 'string', 'regex',
    function (badVal, value, _reformatted, _context)
        -- translateMultiPatternToPCRE does not throw errors
        local v, err = regex_utils.translateMultiPatternToPCRE(value)
        if not v then
            utils.log(badVal, 'regex', value, err)
            return nil, value
        end
        -- No "reformating" for the input; it's either valid or not
        return v, value
    end)

    -- Update NEVER_TABLE for all derived parsers registered so far
    -- This must happen BEFORE parsing {name:percent}
    for name, _ in pairs(state.PARSERS) do
        if state.NEVER_TABLE[name] == nil then
            state.NEVER_TABLE[name] = true
        end
    end
    state.NEVER_TABLE.table = nil
    state.NEVER_TABLE.ratio = nil

    -- This will cause the required comparator to be defined
    parseType(ownBadVal, '{name:percent}')

    -- Get percent parser reference
    local percent_parser = parseType(nullBadVal, "percent")
    assert(percent_parser)
    state.refs.percent = percent_parser

    -- ratio is a table with the format {name:percent}
    -- It cannot extend {name:percent} directly, because the input are strings, and not numbers.
    -- The total of all values must add up to 100 (percent)
    registration.extendParser(ownBadVal, 'table', 'ratio',
    function (badVal, parsed, str, _context)
        --{name:percent} (Data Format: a=50,b=50)
        local total = 0.0
        local reformatted = {}
        local vs
        for k, v in pairs(parsed) do
            if not isName(k) then
                utils.log(badVal, 'name', k)
                return nil, str
            end
            local p
            p, vs = percent_parser(badVal, v, 'parsed')
            if not p then
                return nil, str
            end
            reformatted[k] = vs
            if p > 100.01 then
                utils.log(badVal, 'percent', v, "Cannot be > 100")
                return nil, str
            end
            if p < 0 then
                utils.log(badVal, 'percent', v, "Cannot be negative")
                return nil, str
            end
            total = total + p
        end
        if total < 0.9999 or total > 1.0001 then
            utils.log(badVal, 'ratio', str, 'Does not add up to ~100%')
            return nil, str
        end
        return parsed, utils.serializeTableWithoutCB(reformatted)
    end)
    state.COMPARATORS.ratio = state.COMPARATORS['{name:percent}']
    state.NEVER_TABLE.ratio = nil

    -- Define standard integer types
    registration.restrictNumber(ownBadVal, 'integer', 0, 255, 'ubyte')
    registration.restrictNumber(ownBadVal, 'integer', 0, 65535, 'ushort')
    registration.restrictNumber(ownBadVal, 'integer', 0, 4294967295, 'uint')

    registration.restrictNumber(ownBadVal, 'integer', -128, 127, 'byte')
    registration.restrictNumber(ownBadVal, 'integer', -32768, 32767, 'short')
    registration.restrictNumber(ownBadVal, 'integer', -2147483648, 2147483647, 'int')

    -- "long" type: full 64-bit signed integer range
    -- Note: Extends "number" directly, NOT "integer", since its range is larger than safe integers
    if HAS_NATIVE_INTEGERS then
        -- Lua 5.3+: Support full 64-bit range
        local LONG_MIN = math.mininteger  -- -9223372036854775808
        local LONG_MAX = math.maxinteger  -- 9223372036854775807

        registration.extendParser(ownBadVal, 'number', 'long',
        function (badVal, num, _reformatted, _context)
            if not isIntegerValue(num) then
                utils.log(badVal, 'long', num)
                return nil, tostring(num)
            end
            if num < LONG_MIN or num > LONG_MAX then
                utils.log(badVal, 'long', num, "value outside 64-bit range")
                return nil, tostring(num)
            end
            if math.type(num) ~= 'integer' then
                num = math.floor(num)
            end
            return num, tostring(num)
        end)
    else
        -- LuaJIT: "long" is limited to safe integer range
        -- Full 64-bit support would require FFI int64_t, which is out of scope
        registration.extendParser(ownBadVal, 'number', 'long',
        function (badVal, num, _reformatted, _context)
            if not isIntegerValue(num) then
                utils.log(badVal, 'long', num)
                return nil, tostring(num)
            end
            if num < SAFE_INTEGER_MIN or num > SAFE_INTEGER_MAX then
                utils.log(badVal, 'long', num,
                    "LuaJIT cannot precisely represent 64-bit integers outside ±2^53")
                return nil, tostring(num)
            end
            return math.floor(num), tostring(math.floor(num))
        end)
    end

    -- Define the custom type definition record type used in manifest custom_types field.
    -- Fields (alphabetically ordered for normalization):
    --   max: number|nil - maximum value (for number types)
    --   maxLen: integer|nil - maximum string length (for string types)
    --   min: number|nil - minimum value (for number types)
    --   minLen: integer|nil - minimum string length (for string types)
    --   name: name - the name of the custom type
    --   parent: type_spec|nil - the parent type to extend/restrict
    --   pattern: string|nil - regex pattern (for string types)
    --   validate: string|nil - expression-based validator (mutually exclusive with other constraints)
    --   values: {string}|nil - allowed values (for enum types)
    registration.registerAlias(ownBadVal, 'custom_type_def',
        '{max:number|nil,maxLen:integer|nil,min:number|nil,minLen:integer|nil,name:name,parent:type_spec|nil,pattern:string|nil,validate:string|nil,values:{string}|nil}')

    -- ============================================================
    -- Validator Types for Row, File, and Package Validators
    -- ============================================================

    -- Expression type: A string containing a valid Lua expression.
    -- At parse time: validates syntax only (compiles successfully)
    -- At runtime: evaluated in sandboxed environment
    registration.extendParser(ownBadVal, 'string', 'expression',
    function (badVal, value, reformatted, _context)
        -- Validate that the expression is syntactically valid Lua
        local code = "return (" .. value .. ")"
        local compiled, err = load(code)
        if not compiled then
            -- Try loadstring for Lua 5.1/LuaJIT compatibility
            if loadstring then
                compiled, err = loadstring(code)
            end
        end
        if not compiled then
            utils.log(badVal, 'expression', value,
                "invalid Lua expression: " .. tostring(err))
            return nil, reformatted
        end
        return value, reformatted
    end)

    -- Log level enum: "error" or "warn"
    -- "error" level validators stop on first failure
    -- "warn" level validators continue execution and collect all warnings
    registration.registerEnumParser(ownBadVal, {"error", "warn"}, "error_level")

    -- Validator specification: either a simple expression string (defaults to error level)
    -- or a structured record with explicit level
    -- Simple string form: "self.x > 0 or 'x must be positive'" (defaults to error)
    -- Structured form: {expr="self.x > 0 or 'x must be positive'", level="warn"}
    registration.registerAlias(ownBadVal, 'validator_spec',
        'expression|{expr:expression,level:error_level|nil}')
    
    -- Helper type for creating "Files.tsv"
    registration.registerAlias(ownBadVal, 'super_type', 'type_spec|nil')

    -- A "type_spec" limited to "number" and types that extend number
    registration.registerAlias(ownBadVal, 'number_type', '{extends:number}')

    -- A type similar to "any" but that only accept values of type "number"
    registration.restrictWithValidator(ownBadVal, '{number_type,number}', 'tagged_number',
    function(parsed)
        local expected_type = parsed[1]
        local parsed_value = parsed[2]
        local parser = parseType(nullBadVal, expected_type)
        if not parser then
            return 'Bad number type: ' .. expected_type
        end
        local validated, _ = generators.callParser(parser, nullBadVal, parsed_value, "parsed")
        if validated == nil then
            return 'Value does not match expected type ' .. expected_type
        end
        return true
    end)

    -- "quantity" is a string "<number><number_type>", e.g. "3.5kilogram", parsed to {type, number}
    -- Similar to "percent" (string input -> structured output), but produces a tagged_number tuple.
    local nt_parser = parseType(nullBadVal, 'number_type')
    assert(nt_parser)
    state.PARSERS.quantity = function(badVal, value, context)
        if utils.expectTSV(context) then
            -- TSV: parse "<number><type_name>" string
            local num_str, type_name = string.match(tostring(value),
                "^(%-?%d+%.?%d*)(%a[%a%d_.]*)$")
            if not num_str or not type_name then
                utils.log(badVal, 'quantity', value,
                    "expected format: <number><type_name> (e.g. '3.5kilogram')")
                return nil, tostring(value)
            end
            -- Validate type_name is a valid number_type
            local parsed_type = generators.callParser(nt_parser, badVal, type_name, "tsv")
            if not parsed_type then
                return nil, tostring(value)
            end
            -- Parse the number using the declared type's parser
            local type_parser = parseType(nullBadVal, parsed_type)
            if not type_parser then
                utils.log(badVal, 'quantity', value,
                    'Bad number type: ' .. parsed_type)
                return nil, tostring(value)
            end
            local parsed_num, reformatted_num = generators.callParser(
                type_parser, nullBadVal, num_str, "tsv")
            if parsed_num == nil then
                utils.log(badVal, 'quantity', value,
                    'Value does not match expected type ' .. parsed_type)
                return nil, tostring(value)
            end
            return {parsed_type, parsed_num}, reformatted_num .. parsed_type
        else
            -- Parsed context: value should be a table {type_name, number}
            -- Delegate to tagged_number parser for validation
            local tn_parser = parseType(nullBadVal, 'tagged_number')
            local parsed, _ = generators.callParser(tn_parser, badVal, value, "parsed")
            if parsed == nil then
                return nil, tostring(value)
            end
            return parsed, tostring(parsed[2]) .. parsed[1]
        end
    end
    generators.extendsOrRestrictsType('quantity', 'tagged_number')
    generators.registerComparator('quantity', generators.getCompInternal('tagged_number'))
end

return M
