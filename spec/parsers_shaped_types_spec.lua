-- parsers_shaped_types_spec.lua
-- Tests for shaped string types: a string whose TEXT must parse as a table type,
-- and which is canonicalized to that type's own form. See TODO/string_shaped_types.md.

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local parsers = require("parsers")
local error_reporting = require("infra.error_reporting")

-- Returns a "badVal" object that stores errors in the given table
local function mockBadVal(log_messages)
    local log = function(_self, msg) table.insert(log_messages, msg) end
    local badVal = error_reporting.badValGen(log)
    badVal.source_name = "test"
    badVal.line_no = 1
    return badVal
end

-- Registers one shaped type and returns its parser (asserting a clean registration).
-- Type names are global and persist across specs, hence the unique-ish names.
local function shapedType(name, shape, parent)
    local log_messages = {}
    local badVal = mockBadVal(log_messages)
    local ok = parsers.registerTypesFromSpec(badVal,
        {{name = name, parent = parent or "string", shape = shape}})
    assert.is_true(ok, table.concat(log_messages, " | "))
    assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
    return parsers.parseType(badVal, name)
end

describe("parsers - shaped string types", function()

  describe("canonicalization", function()
    it("collapses formatting variants of the same value to one string", function()
      local badVal = mockBadVal({})
      local coord = shapedType("ShCoord", "{integer,integer}")
      -- All three spellings of the same point produce the SAME string. This is what
      -- gives a shaped key value-semantics: Lua interns strings by value.
      for _, text in ipairs({"1,2", "1, 2", "  1 ,  2 "}) do
        local parsed, reformatted = coord(badVal, text)
        assert.equals("1,2", parsed)
        assert.equals("string", type(parsed))
        assert.equals("1,2", reformatted)
      end
      assert.equals(0, badVal.errors)
    end)

    it("canonicalizes a record shape by sorting its fields", function()
      local badVal = mockBadVal({})
      local rect = shapedType("ShRect", "{h:integer,w:integer}")
      assert.equals("h=2,w=1", rect(badVal, "w=1, h=2"))
      assert.equals(0, badVal.errors)
    end)
  end)

  describe("validation", function()
    it("rejects text that does not parse as the shape", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local coord = shapedType("ShCoord2", "{integer,integer}")
      local parsed = coord(badVal, "1,x")
      assert.is_nil(parsed)
      assert.equals(1, badVal.errors)
      assert.matches("does not match shape", log_messages[1], 1, true)
    end)

    -- The containers themselves accept a cell that is missing a required element
    -- (a lax-arity hole that predates this). A shaped value is destined to be a KEY,
    -- and a partial key is poison, so a shape is checked strictly regardless.
    it("rejects a tuple shape with a missing element", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local coord = shapedType("ShCoord3", "{integer,integer}")
      assert.is_nil(coord(badVal, "1"))
      assert.equals(1, badVal.errors)
      assert.matches("missing element 2 of 2", log_messages[1], 1, true)
    end)

    it("rejects a tuple shape with too many elements (no crash)", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local coord = shapedType("ShCoord4", "{integer,integer}")
      assert.is_nil(coord(badVal, "1,2,3"))
      assert.equals(1, badVal.errors)
    end)

    it("rejects a record shape with a missing required field", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local rect = shapedType("ShRect2", "{x:integer,y:integer}")
      assert.is_nil(rect(badVal, "x=1"))
      assert.equals(1, badVal.errors)
      assert.matches("missing field 'y'", log_messages[1], 1, true)
    end)

    it("allows an optional field of a record shape to be absent", function()
      local badVal = mockBadVal({})
      local rect = shapedType("ShRect3", "{w:integer|nil,x:integer,y:integer}")
      assert.equals("x=1,y=2", rect(badVal, "x=1,y=2"))
      assert.equals("w=9,x=1,y=2", rect(badVal, "x=1,y=2,w=9"))
      assert.equals(0, badVal.errors)
    end)

    it("puts no arity constraint on an array shape", function()
      local badVal = mockBadVal({})
      local tags = shapedType("ShTags", "{string}")
      assert.equals('"a","b"', tags(badVal, '"a","b"'))
      assert.equals('"a"', tags(badVal, '"a"'))
      assert.equals(0, badVal.errors)
    end)
  end)

  describe("registration", function()
    it("refuses a non-string parent", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      assert.is_false(parsers.registerTypesFromSpec(badVal,
        {{name = "ShBadParent", parent = "integer", shape = "{integer,integer}"}}))
      assert.matches("extends string", log_messages[1], 1, true)
    end)

    it("refuses a scalar shape, which would constrain nothing", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      assert.is_false(parsers.registerTypesFromSpec(badVal,
        {{name = "ShScalar", parent = "string", shape = "integer"}}))
      assert.matches("must be a table type", log_messages[1], 1, true)
    end)

    it("refuses to mix shape with another constraint kind", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      assert.is_false(parsers.registerTypesFromSpec(badVal,
        {{name = "ShMixed", parent = "string", shape = "{integer,integer}", maxLen = 5}}))
      assert.matches("cannot mix constraint types", log_messages[1], 1, true)
    end)
  end)

  -- The reason the feature exists: a composite value that can be a map KEY, which a
  -- real table can never be (TODO/tables_as_keys.md).
  describe("as a map key", function()
    it("is a legal map key type", function()
      local badVal = mockBadVal({})
      shapedType("ShKey", "{integer,integer}")
      assert.is_true(parsers.isNeverTable("ShKey"))
      assert.is_not_nil(parsers.parseType(badVal, "{ShKey:string}"))
      assert.equals(0, badVal.errors)
    end)

    it("keys a map, and the key stays a string", function()
      local badVal = mockBadVal({})
      shapedType("ShKey2", "{integer,integer}")
      local mapParser = parsers.parseType(badVal, "{ShKey2:string}")
      local parsed = mapParser(badVal, '["1,2"]="a",["3,4"]="b"')
      assert.equals("a", parsed["1,2"])
      assert.equals("b", parsed["3,4"])
      assert.equals("string", type(next(parsed)))
      assert.equals(0, badVal.errors)
    end)

    -- Canonicalization is what makes a shaped key work: two spellings of the same
    -- point ARE the same key, which is the value-semantics a table key cannot have.
    -- In one cell that makes them a duplicate key, and silently keeping one would both
    -- lose data and let pairs() pick the winner.
    it("rejects two spellings of the same key in one cell as a duplicate", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      shapedType("ShKey3", "{integer,integer}")
      local mapParser = parsers.parseType(badVal, "{ShKey3:string}")
      assert.is_nil(mapParser(badVal, '["1,2"]="first",["1, 2"]="second"'))
      assert.equals(1, badVal.errors)
      assert.matches("Duplicate key: 1,2", log_messages[#log_messages], 1, true)
    end)

    -- ... while the same point written differently in DIFFERENT cells is the same key,
    -- which is the point of the whole exercise.
    it("is the same key across cells, however it was spelled", function()
      local badVal = mockBadVal({})
      shapedType("ShKey4", "{integer,integer}")
      local mapParser = parsers.parseType(badVal, "{ShKey4:string}")
      local a = mapParser(badVal, '["1,2"]="a"')
      local b = mapParser(badVal, '["  1 , 2 "]="b"')
      assert.equals("a", a["1,2"])
      assert.equals("b", b["1,2"])   -- same key object, from different text
      assert.equals(0, badVal.errors)
    end)
  end)

  describe("composition", function()
    it("can be further restricted by a second type", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local ok = parsers.registerTypesFromSpec(badVal, {
        {name = "ShBase", parent = "string", shape = "{integer,integer}"},
        {name = "ShShort", parent = "ShBase", maxLen = 3},
      })
      assert.is_true(ok, table.concat(log_messages, " | "))
      local short = parsers.parseType(badVal, "ShShort")
      assert.equals("1,2", short(badVal, "1, 2"))   -- canonical form fits in 3 chars
      assert.equals(0, badVal.errors)
      assert.is_nil(short(badVal, "10,20"))         -- canonical "10,20" is too long
      assert.equals(1, badVal.errors)
    end)
  end)
end)
