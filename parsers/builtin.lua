-- parsers/builtin.lua
-- Built-in parser implementations

local state = require("parsers.state")
local utils = require("parsers.utils")
local lpeg_parser = require("parsers.lpeg_parser")
local generators = require("parsers.generators")

local lpeg = require("lpeg")
local semver = require("semver")

local string_utils = require("util.string_utils")
local escapeText = string_utils.escapeText
local unescapeText = string_utils.unescapeText
local parseVersion = string_utils.parseVersion

local predicates = require("util.predicates")
local isString = predicates.isString
local isName = predicates.isName
local isIdentifier = predicates.isIdentifier
local isPercent = predicates.isPercent
local isIntegerValue = predicates.isIntegerValue
local isValidASCII = predicates.isValidASCII
local isValidUTF8 = predicates.isValidUTF8
local isValidHttpUrl = predicates.isValidHttpUrl
local isPath = predicates.isPath
local isQualifiedPath = predicates.isQualifiedPath

local regex_utils = require("util.regex_utils")

local base64 = require("util.base64")

local error_reporting = require("infra.error_reporting")
local badValGen = error_reporting.badValGen
local nullBadVal = error_reporting.nullBadVal

local serialization = require("serde.serialization")
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
        utils.log(badVal, 'boolean', value,
            "expected 'true', 'false', 'yes', 'no', '1', or '0'")
        return nil, tostring(value)
    end
    local lc = value:lower()
    if lc == 'true' or lc == 'yes' or lc == '1' then
        return true, 'true'
    elseif lc == 'false' or lc == 'no' or lc == '0' then
        return false, 'false'
    else
        utils.log(badVal, 'boolean', value,
            "expected 'true', 'false', 'yes', 'no', '1', or '0'")
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
            utils.log(badVal, 'number', value, "value is missing or nil")
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
    return utils.serializeParsedTable(badVal, 'table', value)
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

    -- A file path (Unix-style, forward slashes, each component a valid file name)
    registration.restrictWithValidator(ownBadVal, 'ascii', 'filepath', isPath)

    -- A file path optionally prefixed with a "<package_id>:" qualifier — the
    -- opt-in declared type for the mod-override target columns (patchOf /
    -- bulkPatchOf / schemaOverlayOf), letting a target bind to one package's
    -- file when two packages ship the same file name. See
    -- TODO/mod_ecosystem.md §4; ':' can never appear in a plain filepath, so
    -- the two forms cannot be confused.
    registration.restrictWithValidator(ownBadVal, 'ascii', 'override_target', isQualifiedPath)

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
    -- Field 2's type is dynamically determined by the type name in field 1
    registration.registerAlias(ownBadVal, 'any', '{type,self._1}')

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
            utils.log(badVal, 'version', value,
                "expected format: X.Y.Z (e.g., 1.0.0)")
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
    --   members: {name}|nil - type tag members (type names that belong to this tag)
    --   min: number|nil - minimum value (for number types)
    --   minLen: integer|nil - minimum string length (for string types)
    --   name: name - the name of the custom type
    --   parent: type_spec|nil - the parent type to extend/restrict (required ancestor for tags)
    --   pattern: string|nil - regex pattern (for string types)
    --   shape: type_spec|nil - table type the value's TEXT must parse as (for string types);
    --                          the value stays a string, canonicalized to the shape's own form
    --   tags: name|{name}|nil - type tag(s) to add this type to as a member
    --   validate: string|nil - expression-based validator (mutually exclusive with other constraints)
    --   values: {string}|nil - allowed values (for enum types)
    registration.registerAlias(ownBadVal, 'custom_type_def',
        '{max:number|nil,maxLen:integer|nil,members:{name}|nil,min:number|nil,minLen:integer|nil,name:name,parent:type_spec|nil,pattern:string|nil,shape:type_spec|nil,tags:{name}|nil,validate:string|nil,values:{string}|nil}')

    -- ============================================================
    -- Validator Types for Row, File, and Package Validators
    -- ============================================================

    -- Expression type: A string containing a valid Lua expression.
    -- At parse time: validates syntax only (compiles successfully)
    -- At runtime: evaluated in sandboxed environment
    registration.extendParser(ownBadVal, 'string', 'expression',
    function (badVal, value, reformatted, _context)
        -- Validate that the expression is syntactically valid Lua. A leading '='
        -- (TabuLua's "evaluate-me" sigil) is tolerated and ignored for this check,
        -- so an `expression` column accepts `=foo` as readily as `foo` — both name
        -- the same expression. The original text is stored UNCHANGED, so callers
        -- that key off the '=' (e.g. bulk patches distinguishing an
        -- expression from a literal) still see it on the cell value.
        local toCheck = value
        if type(toCheck) == "string" and toCheck:sub(1, 1) == '=' then
            toCheck = toCheck:sub(2)
        end
        local code = "return (" .. toCheck .. ")"
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

    -- Processor specification: either a simple expression string (defaults to error level)
    -- or a structured record. Mirrors validator_spec, but adds processor-specific fields
    -- so that pre-processors can opt into priority-based ordering, re-runs after
    -- mod-override patches, and cross-package ordering. The `requires` field is only
    -- meaningful for package-scoped pre-processors: it names
    -- other packages whose pre-processors must run before this one. `name` is used
    -- (not `package_id`, an alias registered later in manifest_info) so the alias has no
    -- load-order dependency. See pre_processors documentation for full semantics.
    registration.registerAlias(ownBadVal, 'processor_spec',
        'expression|{expr:expression,level:error_level|nil,priority:number|nil,rerunAfterPatches:boolean|nil,requires:{name}|nil}')

    -- Helper type for creating "Files.tsv"
    registration.registerAlias(ownBadVal, 'super_type', 'type_spec|nil')

    -- A "type_spec" limited to "number" and types that extend number
    registration.registerAlias(ownBadVal, 'number_type', '{extends:number}')

    -- A type similar to "any" but that only accepts values of type "number"
    -- Field 2's type is dynamically determined by the number_type name in field 1
    registration.registerAlias(ownBadVal, 'tagged_number', '{number_type,self._1}')

    -- "quantity" is a string "<number><number_type>", e.g. "3.5kilogram", parsed to {type, number}
    -- Similar to "percent" (string input -> structured output), but produces a tagged_number tuple.
    -- Note that 'quantity' does NOT support 'percent' input, as it explicitly matches "normal numbers"
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

    -- ============================================================
    -- Graph types
    --
    -- See TODO/graph_types.md for the full design. Phase A1 lands the
    -- parser-side types only; auto-wiring, validators, and edge-file
    -- discovery come in later phases.
    -- ============================================================

    -- A composable_name is a name (identifier-chain ASCII string) with
    -- three additional restrictions, all aimed at keeping any compound
    -- "<a>__<b>" encoding that uses `__` as a separator unambiguous:
    --   * must not contain "__" (which is the separator)
    --   * must not start with "_" (would let "x" + "_y" and "x_" + "y"
    --     encode to the same key "x___y" and decode the wrong way)
    --   * must not end with "_" (symmetric to the previous case)
    -- Together these three rules guarantee that every "<a>__<b>" string
    -- has exactly one "__" separator and splits cleanly on the first
    -- match. Graph edge-key types are the first consumer, but the type
    -- is also useful for any future compound-key context — hence the
    -- general name and the `node_name` alias.
    registration.restrictWithValidator(ownBadVal, 'name', 'composable_name',
    function (str)
        if str:find('__', 1, true) then
            return "must not contain '__' (reserved as compound-key separator)"
        end
        if str:sub(1, 1) == '_' then
            return "must not start with '_' (reserved for compound-key encoding)"
        end
        if str:sub(-1, -1) == '_' then
            return "must not end with '_' (reserved for compound-key encoding)"
        end
        return true
    end)

    -- `node_name` is a backwards-compatible alias for use by the graph
    -- node families. Existing built-in record types and any user types
    -- that wrote `name:node_name` continue to resolve to the same
    -- parser (and produce the same canonical form on schema export).
    registration.registerAlias(ownBadVal, 'node_name', 'composable_name')

    -- Cached node_name parser used by the edge-key parsers below to
    -- validate each half of "<a>__<b>".
    local node_name_parser = parseType(nullBadVal, 'node_name')
    assert(node_name_parser, "node_name parser not registered")

    -- Splits an edge-key value of the form "<a>__<b>" into its two halves,
    -- validating each as a node_name. Returns a, b on success; on failure,
    -- logs to badVal and returns nil.
    local function splitEdgeKeyHalves(badVal, edge_type, value)
        local sep_start, sep_end = value:find('__', 1, true)
        if not sep_start then
            utils.log(badVal, edge_type, value,
                "expected format: <node_name>__<node_name>")
            return nil
        end
        if value:find('__', sep_end + 1, true) then
            utils.log(badVal, edge_type, value,
                "edge key has more than two halves")
            return nil
        end
        local a = value:sub(1, sep_start - 1)
        local b = value:sub(sep_end + 1)
        if a == '' or b == '' then
            utils.log(badVal, edge_type, value,
                "edge key has empty half")
            return nil
        end
        local parsed_a = generators.callParser(node_name_parser, badVal, a, 'tsv')
        if parsed_a == nil then return nil end
        local parsed_b = generators.callParser(node_name_parser, badVal, b, 'tsv')
        if parsed_b == nil then return nil end
        return parsed_a, parsed_b
    end

    -- An undirected edge key. Halves are sorted ascending lexicographically;
    -- if reordering was needed, emits a warning (the data is correct, but
    -- the file will be canonicalised on the next reformatter run).
    -- Self-loops (A__A) are valid for undirected graphs.
    registration.extendParser(ownBadVal, 'name', 'undirected_edge_key',
    function (badVal, value, _reformatted, _context)
        local a, b = splitEdgeKeyHalves(badVal, 'undirected_edge_key', value)
        if not a then return nil, value end
        if a > b then
            a, b = b, a
            local source = badVal.source_name or ""
            local line = badVal.line_no or 0
            local where = source ~= "" and
                (" in " .. source .. " on line " .. line) or ""
            local logger = badVal.logger or state.logger
            logger:warn("undirected_edge_key '" .. value
                .. "' reordered to canonical form '" .. a .. "__" .. b
                .. "'" .. where)
        end
        local canonical = a .. "__" .. b
        return canonical, canonical
    end)

    -- A directed edge key. Authored order is preserved (no reorder).
    -- Self-loops (A__A) parse fine here; the cycle validator on the node
    -- file flags them as cycles for DAG/tree contexts later.
    registration.extendParser(ownBadVal, 'name', 'directed_edge_key',
    function (badVal, value, _reformatted, _context)
        local a, b = splitEdgeKeyHalves(badVal, 'directed_edge_key', value)
        if not a then return nil, value end
        local result = a .. "__" .. b
        return result, result
    end)

    -- Graph node record types.
    registration.registerAlias(ownBadVal, 'basic_graph_node',
        '{graphLinks:{node_name}|nil,name:node_name}')
    registration.registerAlias(ownBadVal, 'graph_node',
        '{graphChildren:{node_name}|nil,graphParents:{node_name}|nil,name:node_name}')
    -- tree_node is a plain alias of graph_node. Same parser, same canonical
    -- form; the tree-vs-DAG distinction is keyed off the user-written
    -- `superType` string in Files.tsv at auto-wiring time, not parser
    -- identity. An earlier attempt used the redeclaration form
    -- `{extends:graph_node, name:node_name}`, which still aliased to the
    -- same parser but produced an `{extends,X,field:type}` spec string
    -- that the schema exporter can't round-trip.
    registration.registerAlias(ownBadVal, 'tree_node', 'graph_node')

    -- Edge record types parallel to the node types. Authors extending an
    -- edge type add their own columns (weight, kind, ...) using existing
    -- record-inheritance syntax. The `comment` column is included so the
    -- spec parses as a proper record (single-field {key:val} parses as a
    -- map per parsers/lpeg_parser.lua) and gives authors a free-text
    -- description column out of the box.
    registration.registerAlias(ownBadVal, 'basic_graph_edge',
        '{comment:comment|nil,name:undirected_edge_key}')
    registration.registerAlias(ownBadVal, 'graph_edge',
        '{comment:comment|nil,name:directed_edge_key}')
    -- tree_edge is a plain alias of graph_edge (same reasoning as tree_node
    -- above). Family-level distinction lives in Files.tsv superType, not
    -- in the parser identity.
    registration.registerAlias(ownBadVal, 'tree_edge', 'graph_edge')

    -- Migration-script record type and the IgnoredFile tag.
    --
    -- A migration script (see migration.lua) is a TSV of command rows:
    -- column 1 is the command name, p1..p5 are positional parameters whose
    -- meaning varies per command. Such a file is declared in Files.tsv but
    -- must NOT be loaded as data — its parameter columns carry no fixed
    -- per-row type, and the `command` primary key repeats across rows
    -- (violating primary-key uniqueness). So it is recognised and skipped
    -- before parsing.
    --
    -- IgnoredFile is the generic mechanism for that: a type tag whose
    -- members are file types the loader recognises but does not load. Its
    -- ancestor is `table` (the super-type of all tables), so any record
    -- (i.e. any file) type can join it via the `tags` field, independent of
    -- its own superType. MigrationScript is the one built-in member.
    registration.registerTypesFromSpec(ownBadVal, {
        {name = "MigrationScript",
         parent = "{command:string,p1:string|nil,p2:string|nil," ..
                  "p3:string|nil,p4:string|nil,p5:string|nil}"},
        {name = "IgnoredFile", parent = "table", members = {"MigrationScript"}},
    })

    -- Asset marker type and the AssetFile tag.
    --
    -- `asset_file` is the typeName that says "this file is NOT a table": do not
    -- parse it, keep it, copy it byte-for-byte to the export, and never rewrite
    -- it in place. Asset is not a new role — .md / .txt / .lua / .zip already get
    -- it implicitly, from their extension — it simply could not be *stated*
    -- before, so a .json asset was indistinguishable from a .json nobody had got
    -- round to declaring, and was dropped.
    --
    -- The declaration beats the extension for EVERY extension, so this is not a
    -- .json/.xml patch: a .tsv can be declared an asset too, and is then carried
    -- through the pipeline untouched (a hand-formatted lookup table, a fixture
    -- shipped for someone else's tool, a file whose exact bytes matter). The
    -- loader has no other way to express that: a .tsv it sees is otherwise either
    -- parsed — and reformatted in place — or dropped.
    --
    -- The mechanism mirrors IgnoredFile above: a tag whose ancestor is `table`,
    -- so any user record type can join it via its `tags` field. The type itself
    -- is aliased to the empty record because its shape is never used — the file
    -- is never parsed. The name is snake_case (the house style for engine-role
    -- typeNames: custom_type_def, type_wiring_def, patch, bulk_patch), which also
    -- leaves the plain name `Asset` free for a user's own table of asset METADATA.
    registration.registerTypesFromSpec(ownBadVal, {
        {name = "asset_file", parent = "{}"},
        {name = "AssetFile", parent = "table", members = {"asset_file"}},
    })
end

return M
