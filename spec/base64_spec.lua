-- base64_spec.lua
-- Tests for the base64 module and hexbytes/base64bytes type parsers

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it

local parsers = require("parsers")
local error_reporting = require("error_reporting")
local base64 = require("base64")

-- Returns a "badVal" object that stores errors in the given table
local function mockBadVal(log_messages)
    local log = function(self, msg) table.insert(log_messages, msg) end
    local badVal = error_reporting.badValGen(log)
    badVal.source_name = "test"
    badVal.line_no = 1
    return badVal
end

local function assert_equals_2(a1, b1, a2, b2)
    local success = true
    local error_message = ""

    if type(a1) == "number" and type(a2) == "number" then
        if math.abs(a1 - a2) >= 0.00000001 then
            success = false
            error_message = string.format("First pair numeric values differ: %s ~= %s",
                                          tostring(a1), tostring(a2))
        end
    else
        local same_a = pcall(function() assert.same(a1, a2) end)
        if not same_a then
            success = false
            error_message = string.format("First pair values differ: %s ~= %s",
                                         tostring(a1), tostring(a2))
        end
    end

    local same_b = pcall(function() assert.same(b1, b2) end)
    if not same_b then
        if success then
            success = false
            error_message = string.format("Second pair values differ: %s ~= %s",
                                         tostring(b1), tostring(b2))
        else
            error_message = error_message .. " AND " ..
                           string.format("Second pair values differ: %s ~= %s",
                                        tostring(b1), tostring(b2))
        end
    end

    assert(success, error_message)
end

describe("parsers - bytes types", function()

    describe("hexbytes", function()
        it("should parse valid uppercase hex", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "hexbytes")
            assert.is.not_nil(parser, "hexbytes parser is nil")
            assert_equals_2("AB01FF", "AB01FF", parser(badVal, "AB01FF"))
            assert.same({}, log_messages)
        end)

        it("should uppercase lowercase hex input", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "hexbytes")
            assert_equals_2("AB01FF", "AB01FF", parser(badVal, "ab01ff"))
            assert.same({}, log_messages)
        end)

        it("should uppercase mixed case hex input", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "hexbytes")
            assert_equals_2("AB01FF", "AB01FF", parser(badVal, "aB01Ff"))
            assert.same({}, log_messages)
        end)

        it("should accept empty string (zero bytes)", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "hexbytes")
            assert_equals_2("", "", parser(badVal, ""))
            assert.same({}, log_messages)
        end)

        it("should accept single byte hex", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "hexbytes")
            assert_equals_2("00", "00", parser(badVal, "00"))
            assert_equals_2("FF", "FF", parser(badVal, "ff"))
            assert.same({}, log_messages)
        end)

        it("should reject odd-length hex string", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "hexbytes")
            assert_equals_2(nil, "ABC", parser(badVal, "ABC"))
            assert.equals(1, #log_messages)
            assert.truthy(log_messages[1]:find("even length"))
        end)

        it("should reject invalid hex characters", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "hexbytes")
            assert_equals_2(nil, "GHIJ", parser(badVal, "GHIJ"))
            assert.equals(1, #log_messages)
            assert.truthy(log_messages[1]:find("invalid hex character"))
        end)

        it("should reject non-string input in parsed context", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "hexbytes")
            assert_equals_2(nil, "123", parser(badVal, 123, "parsed"))
            assert.truthy(#log_messages > 0)
        end)

        it("should reject hex with spaces", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "hexbytes")
            assert_equals_2(nil, "AB 01", parser(badVal, "AB 01"))
            assert.truthy(#log_messages > 0)
        end)

        it("should parse long hex strings", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "hexbytes")
            local hex = "181818187E181818"
            assert_equals_2(hex, hex, parser(badVal, hex))
            assert.same({}, log_messages)
        end)
    end)

    describe("base64bytes", function()
        it("should parse valid base64 with padding", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "base64bytes")
            assert.is.not_nil(parser, "base64bytes parser is nil")
            -- "Hello" = SGVsbG8=
            assert_equals_2("SGVsbG8=", "SGVsbG8=", parser(badVal, "SGVsbG8="))
            assert.same({}, log_messages)
        end)

        it("should accept base64 without padding (multiple of 3 bytes)", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "base64bytes")
            -- "ABC" (3 bytes) = QUJD (no padding needed)
            assert_equals_2("QUJD", "QUJD", parser(badVal, "QUJD"))
            assert.same({}, log_messages)
        end)

        it("should accept base64 with double padding", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "base64bytes")
            -- single byte 0x00 = AA==
            assert_equals_2("AA==", "AA==", parser(badVal, "AA=="))
            assert.same({}, log_messages)
        end)

        it("should accept base64 with single padding", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "base64bytes")
            -- two bytes 0x00 0x00 = AAA=
            assert_equals_2("AAA=", "AAA=", parser(badVal, "AAA="))
            assert.same({}, log_messages)
        end)

        it("should accept empty string (zero bytes)", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "base64bytes")
            assert_equals_2("", "", parser(badVal, ""))
            assert.same({}, log_messages)
        end)

        it("should reject invalid base64 characters", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "base64bytes")
            assert_equals_2(nil, "!!!!", parser(badVal, "!!!!"))
            assert.equals(1, #log_messages)
            assert.truthy(log_messages[1]:find("invalid base64"))
        end)

        it("should reject base64 with wrong length", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "base64bytes")
            -- Length not multiple of 4
            assert_equals_2(nil, "ABC", parser(badVal, "ABC"))
            assert.equals(1, #log_messages)
            assert.truthy(log_messages[1]:find("invalid base64"))
        end)

        it("should reject non-string input in parsed context", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "base64bytes")
            assert_equals_2(nil, "123", parser(badVal, 123, "parsed"))
            assert.truthy(#log_messages > 0)
        end)

        it("should normalize base64 via round-trip", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "base64bytes")
            -- Encode some known bytes
            local original = base64.encode("\x01\x02\x03")
            local parsed, reformatted = parser(badVal, original)
            assert.equals(original, parsed)
            assert.equals(original, reformatted)
            assert.same({}, log_messages)
        end)

        it("should handle base64 with + and / characters", function()
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local parser = parsers.parseType(badVal, "base64bytes")
            -- Bytes that produce + and / in base64: 0xFB, 0xEF, 0xBE
            local encoded = base64.encode("\xFB\xEF\xBE")
            local parsed, reformatted = parser(badVal, encoded)
            assert.equals(encoded, parsed)
            assert.equals(encoded, reformatted)
            assert.same({}, log_messages)
        end)
    end)

    describe("type hierarchy", function()
        it("hexbytes should extend ascii", function()
            assert.is_true(parsers.extendsOrRestrict("hexbytes", "ascii"))
        end)

        it("hexbytes should extend string", function()
            assert.is_true(parsers.extendsOrRestrict("hexbytes", "string"))
        end)

        it("base64bytes should extend ascii", function()
            assert.is_true(parsers.extendsOrRestrict("base64bytes", "ascii"))
        end)

        it("base64bytes should extend string", function()
            assert.is_true(parsers.extendsOrRestrict("base64bytes", "string"))
        end)
    end)

    describe("base64 module", function()
        it("should have a version", function()
            assert.is_string(base64.getVersion())
            assert.truthy(base64.getVersion():match("^%d+%.%d+%.%d+$"))
        end)

        it("should support callable API", function()
            local ver = base64("version")
            assert.is_not_nil(ver)
            assert.equals(base64("encode", "foo"), "Zm9v")
            assert.equals(base64("decode", "Zm9v"), "foo")
            assert.is_true(base64("isValid", "Zm9v"))
        end)

        it("should encode and decode round-trip", function()
            local original = "Hello, World!"
            local encoded = base64.encode(original)
            local decoded = base64.decode(encoded)
            assert.equals(original, decoded)
        end)

        it("should encode empty string", function()
            assert.equals("", base64.encode(""))
        end)

        it("should decode empty string", function()
            assert.equals("", base64.decode(""))
        end)

        it("should encode known values", function()
            assert.equals("", base64.encode(""))
            assert.equals("Zg==", base64.encode("f"))
            assert.equals("Zm8=", base64.encode("fo"))
            assert.equals("Zm9v", base64.encode("foo"))
            assert.equals("Zm9vYg==", base64.encode("foob"))
            assert.equals("Zm9vYmE=", base64.encode("fooba"))
            assert.equals("Zm9vYmFy", base64.encode("foobar"))
        end)

        it("should decode known values", function()
            assert.equals("f", base64.decode("Zg=="))
            assert.equals("fo", base64.decode("Zm8="))
            assert.equals("foo", base64.decode("Zm9v"))
            assert.equals("foobar", base64.decode("Zm9vYmFy"))
        end)

        it("should validate base64 strings", function()
            assert.is_true(base64.isValid(""))
            assert.is_true(base64.isValid("AAAA"))
            assert.is_true(base64.isValid("AA=="))
            assert.is_true(base64.isValid("AAA="))
            assert.is_true(base64.isValid("SGVsbG8="))
            assert.is_false(base64.isValid("!!!"))
            assert.is_false(base64.isValid("ABC"))  -- length not multiple of 4
            assert.is_false(base64.isValid("A==="))  -- too much padding
            assert.is_false(base64.isValid(123))     -- not a string
        end)

        it("should handle binary data with all byte values", function()
            local bytes = {}
            for i = 0, 255 do
                bytes[#bytes + 1] = string.char(i)
            end
            local binary = table.concat(bytes)
            local encoded = base64.encode(binary)
            local decoded = base64.decode(encoded)
            assert.equals(binary, decoded)
        end)
    end)
end)
