-- eav_transcoder_spec.lua
-- Unit tests for the EAV <-> TSV content-pipeline transcoder.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each

local parsers = require("parsers")
local error_reporting = require("error_reporting")
local eav_transcoder = require("eav_transcoder")

describe("eav_transcoder", function()
  local badVal, msgs

  before_each(function()
    msgs = {}
    badVal = error_reporting.badValGen(function(_self, m) msgs[#msgs + 1] = m end)
    badVal.logger = error_reporting.nullLogger
    -- A distinctive type name avoids colliding with other specs' registrations.
    parsers.registerAlias(badVal, "EavItem", "{name:identifier,price:integer,tag:string|nil}")
  end)

  local function joined() return table.concat(msgs, " | ") end

  describe("eavToTSV (forward)", function()
    it("rebuilds a schema-typed wide table from triples", function()
      local eav = "sword\tprice\t100\nsword\tname\tsword\nsword\ttag\tsharp\n"
        .. "shield\tname\tshield\nshield\tprice\t50\n"
      local out = eav_transcoder.eavToTSV("I.eav", eav, {}, badVal, {typeName = "EavItem"})
      -- Typed header in schema field order; shield's missing tag is an empty cell.
      assert.equal(
        "name:identifier\tprice:integer\ttag:string|nil\nsword\t100\tsharp\nshield\t50\t\n",
        out)
      assert.equal(0, badVal.errors, joined())
    end)

    it("returns nil and reports when typeName is missing", function()
      local out = eav_transcoder.eavToTSV("I.eav", "a\tb\tc\n", {}, badVal, {})
      assert.is_nil(out)
      assert.matches("no typeName", joined())
    end)

    it("returns nil and reports for an unknown record type", function()
      local out = eav_transcoder.eavToTSV("I.eav", "a\tb\tc\n", {}, badVal, {typeName = "Nope"})
      assert.is_nil(out)
      assert.matches("not a known record type", joined())
    end)

    it("rejects an attribute that is not a schema field", function()
      local out = eav_transcoder.eavToTSV("I.eav", "sword\tweight\t5\n", {}, badVal,
        {typeName = "EavItem"})
      assert.is_nil(out)
      assert.matches("attribute 'weight' is not a field", joined())
    end)

    it("aborts on a malformed EAV row (wrong arity)", function()
      local out = eav_transcoder.eavToTSV("I.eav", "sword\tprice\n", {}, badVal,
        {typeName = "EavItem"})
      assert.is_nil(out)
      assert.matches("eav transcoder", joined())
    end)

    it("aborts on a duplicate (entity, attribute) pair", function()
      local out = eav_transcoder.eavToTSV("I.eav", "sword\tprice\t1\nsword\tprice\t2\n",
        {}, badVal, {typeName = "EavItem"})
      assert.is_nil(out)
      assert.matches("eav transcoder", joined())
    end)
  end)

  describe("tsvToEav (reverse)", function()
    it("de-types the header and compresses to sparse triples", function()
      local tsv = "name:identifier\tprice:integer\ttag:string|nil\nsword\t100\tsharp\nshield\t50\t\n"
      local out = eav_transcoder.tsvToEav(tsv)
      assert.equal("sword\tprice\t100\nsword\ttag\tsharp\nshield\tprice\t50\n", out)
    end)

    it("round-trips eavToTSV output to a stable wide table", function()
      local eav = "sword\tprice\t100\nsword\tname\tsword\nsword\ttag\tsharp\n"
        .. "shield\tname\tshield\nshield\tprice\t50\n"
      local wide = eav_transcoder.eavToTSV("I.eav", eav, {}, badVal, {typeName = "EavItem"})
      local back = eav_transcoder.tsvToEav(wide)
      -- Reloading the reverse output reproduces the same wide table (value-preserving;
      -- the PK 'name' triples fold into the entity column).
      local wide2 = eav_transcoder.eavToTSV("I.eav", back, {}, badVal, {typeName = "EavItem"})
      assert.equal(wide, wide2)
    end)
  end)
end)
