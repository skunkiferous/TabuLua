-- int64_cross_runtime_spec.lua
-- Phase 8 of boxed_int64.md: prove an int64 written on one Lua runtime reads
-- back correctly on the other -- the whole reason the box exists.
--
-- HOW THIS IS CROSS-RUNTIME WITHOUT TWO PROCESSES. The GOLDEN bytes below were
-- generated on Lua 5.4 AND on LuaJIT and confirmed BYTE-IDENTICAL (see the
-- generator in the Phase 8 notes). This spec runs on both runtimes in CI and,
-- for every value and format, asserts:
--   (1) serialize(box) == GOLDEN   -- this runtime WRITES the canonical bytes
--   (2) deserialize(GOLDEN)        -- this runtime READS the canonical bytes
-- If both runtimes pass the same golden literals, then runtime A's output (==
-- golden) is exactly what runtime B reads (== golden), and vice versa. That is
-- cross-runtime round-trip, proven without shipping fragile binary fixtures.
--
-- The range is the one that actually separates a real int64 from a double:
-- MIN, MAX, and 2^53-1 / 2^53 / 2^53+1 -- the boundary a double cannot cross.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it

local int64 = require("util.int64")
local ser = require("serde.serialization")
local deser = require("serde.deserialization")
local round_trip = require("serde.round_trip")

-- Decodes the pinned MessagePack golden (hex) into raw bytes.
local function fromHex(hex)
    return (hex:gsub("%x%x", function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- Each row: a value's canonical digits, and its pinned MessagePack wire bytes
-- (0xD3 + 8 big-endian). The lua / json / xml golden forms are the digits in a
-- fixed wrapper, derived below; mpk is the one non-obvious encoding, so it is
-- pinned literally. `boxOnMpkRead` is false for the values a double holds
-- exactly (|v| <= 2^53): the reader returns a plain number for those by design
-- (0xD3 is also emitted for ordinary negatives, so only past 2^53 is it ours).
local VALUES = {
    {name = "MIN",     digits = "-9223372036854775808", mpk = "D38000000000000000", boxOnMpkRead = true},
    {name = "MAX",     digits = "9223372036854775807",  mpk = "D37FFFFFFFFFFFFFFF", boxOnMpkRead = true},
    {name = "neg1",    digits = "-1",                   mpk = "D3FFFFFFFFFFFFFFFF", boxOnMpkRead = false},
    {name = "zero",    digits = "0",                    mpk = "D30000000000000000", boxOnMpkRead = false},
    {name = "one",     digits = "1",                    mpk = "D30000000000000001", boxOnMpkRead = false},
    {name = "e53m1",   digits = "9007199254740991",     mpk = "D3001FFFFFFFFFFFFF", boxOnMpkRead = false},
    {name = "e53",     digits = "9007199254740992",     mpk = "D30020000000000000", boxOnMpkRead = false},
    {name = "e53p1",   digits = "9007199254740993",     mpk = "D30020000000000001", boxOnMpkRead = true},
    {name = "ne53p1",  digits = "-9007199254740993",    mpk = "D3FFDFFFFFFFFFFFFF", boxOnMpkRead = true},
}

describe("int64 cross-runtime golden bytes", function()

  for _, v in ipairs(VALUES) do
    describe(v.name .. " (" .. v.digits .. ")", function()
      local box = int64.of(v.digits)
      -- The golden forms. lua and natural JSON carry the box as quoted digits;
      -- typed JSON and XML carry their tag; mpk is the pinned wire bytes.
      local goldLua = '"' .. v.digits .. '"'
      local goldJsonTyped = '{"int64":"' .. v.digits .. '"}'
      local goldJsonNat = '"' .. v.digits .. '"'
      local goldXml = "<int64>" .. v.digits .. "</int64>"
      local goldMpk = fromHex(v.mpk)

      it("writes the canonical bytes for every format", function()
        assert.equals(goldLua, ser.serialize(box))
        assert.equals(goldJsonTyped, ser.serializeJSON(box))
        assert.equals(goldJsonNat, ser.serializeNaturalJSON(box))
        assert.equals(goldXml, ser.serializeXML(box))
        assert.equals(goldMpk, ser.serializeMessagePack(box))
      end)

      it("reads the canonical bytes back to the same value", function()
        -- Text formats (lua, natural JSON) lower the box to its digits, which
        -- deepEquals treats as equal to the box (the exact int64-vs-text
        -- equivalence) -- a declared column re-supplies the box on load.
        local luaBack = deser.deserialize(goldLua)
        assert.is_true((round_trip.deepEquals(box, luaBack)))

        local natBack = deser.deserializeNaturalJSON(goldJsonNat)
        assert.is_true((round_trip.deepEquals(box, natBack)))

        -- Tag-carrying formats reconstruct the box itself.
        local typedBack = deser.deserializeJSON(goldJsonTyped)
        assert.is_true(int64.is(typedBack))
        assert.equals(v.digits, int64.tostring(typedBack))

        local xmlBack = select(1, deser.deserializeXML(goldXml))
        assert.is_true(int64.is(xmlBack))
        assert.equals(v.digits, int64.tostring(xmlBack))

        -- MessagePack: a box past +/-2^53, a plain (exact) number within it.
        local mpkBack = deser.deserializeMessagePack(goldMpk)
        assert.is_true((round_trip.deepEquals(box, mpkBack)))
        if v.boxOnMpkRead then
          assert.is_true(int64.is(mpkBack))
          assert.equals(v.digits, int64.tostring(mpkBack))
        else
          assert.is_false(int64.is(mpkBack))
        end
      end)
    end)
  end

  it("normalizes -0 to 0 through the parser", function()
    -- -0 is listed as a Phase 8 case. of() is strict and rejects the string
    -- "-0", but the number -0 and the CELL parser both canonicalize to 0.
    local parsers = require("parsers")
    local er = require("infra.error_reporting")
    local b = er.badValGen(function() end)
    b.source_name = "t"; b.line_no = 1; b.logger = er.nullLogger
    local p = parsers.parseType(b, "int64")
    assert.is_true(rawequal(p(b, "-0"), int64.of("0")))
    assert.is_true(rawequal(int64.of(-0), int64.of("0")))
  end)
end)
