-- int64_containers_spec.lua
-- Phase 6 of boxed_int64.md: prove the int64 BOX works in every container
-- position end-to-end -- array element, map KEY, map value, record field,
-- tuple element -- and that `quantity` accepts an int64 number type.
--
-- This is verification, not construction: the per-value int64.is arm in the
-- serializers and the interned box were built in earlier phases. The point of
-- the KEY case in particular is interning -- the box compares by VALUE, so two
-- spellings of one key collapse to one key, which is what makes a table key
-- usable at all (see tables_as_keys.md, why a raw table key cannot).
--
-- The forms fed in below are the ones the reformatter/exporter EMIT: an int64
-- in a container cell is a QUOTED string, never a bare literal. Bare is refused
-- on purpose (ltcn lexes a number before any int64 code runs, rounding it on
-- LuaJIT) -- that refusal is asserted at the end.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it

local parsers = require("parsers")
local error_reporting = require("infra.error_reporting")
local int64 = require("util.int64")
local unwrap = require("util.read_only").unwrap
local ser = require("serde.serialization")
local deser = require("serde.deserialization")

local BIG = "9007199254740993"      -- 2^53 + 1: the first integer a double rounds
local BIG2 = "9007199254740994"

local function freshBadVal()
    local logs = {}
    local badVal = error_reporting.badValGen(function(_s, m)
        logs[#logs + 1] = m
    end)
    badVal.source_name = "test"
    badVal.line_no = 1
    badVal.logger = error_reporting.nullLogger
    return badVal, logs
end

-- Parses a container cell, then RE-parses the parser's own reformatted output
-- -- the export→import round trip the file actually goes through.
local function parseAndReparse(spec, cell)
    local b1, logs = freshBadVal()
    local p = parsers.parseType(b1, spec)
    assert.is_not_nil(p, "no parser for " .. spec)
    local parsed, reformatted = p(b1, cell)
    assert.is_not_nil(parsed, "parse failed for " .. spec .. ": " ..
        tostring(logs[#logs]))
    local b2 = freshBadVal()
    local reparsed = select(1, p(b2, reformatted))
    return unwrap(parsed), reformatted, unwrap(reparsed)
end

describe("int64 in containers", function()

  describe("parser round-trip in every position", function()
    it("should keep an array element an int64", function()
      local parsed, _, re = parseAndReparse("{int64}", '"' .. BIG .. '","42"')
      assert.is_true(int64.is(parsed[1]))
      assert.equals(BIG, int64.tostring(parsed[1]))
      assert.is_true(int64.is(re[1]))
      assert.equals(BIG, int64.tostring(re[1]))
    end)

    it("should keep a map VALUE an int64", function()
      local parsed, _, re = parseAndReparse("{string:int64}", 'gold="' .. BIG .. '"')
      assert.is_true(int64.is(parsed.gold))
      assert.equals(BIG, int64.tostring(parsed.gold))
      assert.is_true(int64.is(re.gold))
    end)

    it("should keep a map KEY an int64 -- the interning case", function()
      local parsed, _, re = parseAndReparse("{int64:string}",
          '["' .. BIG .. '"]="sword"')
      local k = next(parsed)
      assert.is_true(int64.is(k))
      assert.equals(BIG, int64.tostring(k))
      assert.equals("sword", parsed[k])
      -- and it survives its own reformatted output
      local rk = next(re)
      assert.is_true(int64.is(rk))
      assert.equals(BIG, int64.tostring(rk))
    end)

    it("should keep a record field an int64", function()
      local parsed, _, re = parseAndReparse("{id:int64,name:string}",
          'id="' .. BIG .. '",name="x"')
      assert.is_true(int64.is(parsed.id))
      assert.equals(BIG, int64.tostring(parsed.id))
      assert.equals("x", parsed.name)
      assert.is_true(int64.is(re.id))
    end)

    it("should keep a tuple element an int64", function()
      local parsed, _, re = parseAndReparse("{int64,string}",
          '"' .. BIG .. '","x"')
      assert.is_true(int64.is(parsed[1]))
      assert.equals(BIG, int64.tostring(parsed[1]))
      assert.equals("x", parsed[2])
      assert.is_true(int64.is(re[1]))
    end)

    it("should keep a NESTED int64 an int64", function()
      -- {{int64}} -- the per-value check has no depth limit
      local parsed = parseAndReparse("{{int64}}", '{"' .. BIG .. '"}')
      assert.is_true(int64.is(parsed[1][1]))
      assert.equals(BIG, int64.tostring(parsed[1][1]))
    end)
  end)

  describe("interning gives a map key value-semantics", function()
    it("should collapse two spellings of one key into one", function()
      -- 7 and 007 are the same value, so the same interned box, so the same
      -- map key -- a DUPLICATE, exactly as a repeated literal key would be.
      -- This is the property a raw table key can never have (identity, not
      -- value), and the reason int64 keys are allowed where table keys are not.
      local b, logs = freshBadVal()
      local p = parsers.parseType(b, "{int64:string}")
      local parsed = p(b, '[7]="a",["007"]="b"')
      assert.is_nil(parsed)
      assert.matches("Duplicate key", logs[#logs])
    end)
  end)

  describe("serializers tag an int64 in key position", function()
    -- The tag-carrying formats reconstruct the box; the untyped formats lower
    -- the key to text (a declared column's key type re-supplies the box, as
    -- for every other value). Assert the tag is present and the value exact.
    local box = int64.of(BIG)
    local mapKey = {[box] = "sword"}

    it("typed JSON keeps the int64 key as a box", function()
      local back = deser.deserializeJSON(ser.serializeJSON(mapKey))
      local k = next(unwrap(back))
      assert.is_true(int64.is(k))
      assert.equals(BIG, int64.tostring(k))
    end)

    it("XML keeps the int64 key as a box", function()
      local back = select(1, deser.deserializeXML(ser.serializeTableXML(mapKey)))
      local k = next(unwrap(back))
      assert.is_true(int64.is(k))
      assert.equals(BIG, int64.tostring(k))
    end)
  end)

  describe("quantity with an int64 number type", function()
    it("should parse to {type, box} and reformat exactly", function()
      local b, logs = freshBadVal()
      local p = parsers.parseType(b, "quantity")
      local parsed, reformatted = p(b, BIG .. "int64")
      assert.is_not_nil(parsed, tostring(logs[#logs]))
      assert.equals("int64", parsed[1])
      assert.is_true(int64.is(parsed[2]))
      assert.equals(BIG, int64.tostring(parsed[2]))
      assert.equals(BIG .. "int64", reformatted)
    end)

    it("should compare two int64 quantities through the box's own order",
        function()
      local b = freshBadVal()
      local p = parsers.parseType(b, "quantity")
      local small = select(1, p(b, BIG .. "int64"))
      local big = select(1, p(b, BIG2 .. "int64"))
      local cmp = parsers.getComparator("quantity")
      assert.is_not_nil(cmp)
      -- reaches the box's __lt: BIG < BIG2, and past 2^53 a double could not
      -- tell them apart -- the box can
      assert.is_true(cmp(small, big))
      assert.is_false(cmp(big, small))
    end)
  end)

  describe("a bare over-2^53 literal is refused in a container cell", function()
    it("should reject it and name the safe forms", function()
      -- ltcn lexes the number before the int64 element parser runs, so a bare
      -- literal would already be rounded. Refused with the quoted / __int64
      -- alternatives (Phase 5d). Only checked here for a CONTAINER, since a
      -- scalar int64 column receives raw cell text and never hits ltcn.
      local b, logs = freshBadVal()
      local p = parsers.parseType(b, "{int64}")
      assert.is_nil(p(b, BIG))
      assert.matches("cannot be represented exactly", logs[#logs])
    end)
  end)
end)
