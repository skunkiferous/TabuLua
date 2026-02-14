-- parsers_type_tags_spec.lua
-- Tests for type tags (custom types with members field)

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local parsers = require("parsers")
local error_reporting = require("error_reporting")
local introspection = require("parsers.introspection")

-- Returns a "badVal" object that stores errors in the given table
local function mockBadVal(log_messages)
    local log = function(_self, msg) table.insert(log_messages, msg) end
    local badVal = error_reporting.badValGen(log)
    badVal.source_name = "test"
    badVal.line_no = 1
    return badVal
end

describe("parsers - type tags", function()

  describe("basic registration", function()
    it("should register a type tag and accept members as values", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- Register a type tag over number with integer and float as members
      local specs = {{ name = "ttNumGroup", parent = "number", members = {"integer", "float"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))
      assert.equals(0, #log_messages)

      -- Parser should accept members
      local parser = parsers.parseType(badVal, "ttNumGroup")
      assert.is_not_nil(parser)
      assert.equals("integer", parser(badVal, "integer", "tsv"))
      assert.equals("float", parser(badVal, "float", "tsv"))

      -- Parser should accept subtypes of members (ubyte extends integer)
      assert.equals("ubyte", parser(badVal, "ubyte", "tsv"))

      -- Parser should reject non-members that don't extend any member
      assert.is_nil(parser(badVal, "long", "tsv"))
    end)

    it("should work with {extends,TagName} accepting tag members", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- ttNumGroup was registered above
      local parser = parsers.parseType(badVal, "{extends,ttNumGroup}")
      assert.is_not_nil(parser)

      -- Should accept direct members
      assert.equals("integer", parser(badVal, "integer", "tsv"))
      assert.equals("float", parser(badVal, "float", "tsv"))

      -- Should reject non-members
      assert.is_nil(parser(badVal, "long", "tsv"))
      assert.is_nil(parser(badVal, "string", "tsv"))
    end)

    it("should work with parent={extends,number} explicit form", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local specs = {{ name = "ttExplicitParent", parent = "{extends,number}", members = {"integer"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))
      assert.equals(0, #log_messages)

      local parser = parsers.parseType(badVal, "ttExplicitParent")
      assert.is_not_nil(parser)
      assert.equals("integer", parser(badVal, "integer", "tsv"))
      assert.is_nil(parser(badVal, "float", "tsv"))
    end)
  end)

  describe("member validation", function()
    it("should reject member that does not extend ancestor", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local specs = {{ name = "ttBadMember", parent = "number", members = {"string"} }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)

    it("should reject member that is not a registered type", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local specs = {{ name = "ttUnknownMember", parent = "number", members = {"notAType"} }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)

    it("should reject empty members list", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local specs = {{ name = "ttEmptyMembers", parent = "number", members = {} }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)

    it("should reject non-existent ancestor", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local specs = {{ name = "ttBadAncestor", parent = "nonExistentType", members = {"integer"} }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)
  end)

  describe("subtype transitivity", function()
    it("should accept subtypes of tag members via {extends,TagName}", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- Register a tag with 'integer' as a member
      local specs = {{ name = "ttIntTag", parent = "number", members = {"integer"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      -- ubyte extends integer, which is a member of ttIntTag
      local parser = parsers.parseType(badVal, "{extends,ttIntTag}")
      assert.is_not_nil(parser)

      -- Direct member
      assert.equals("integer", parser(badVal, "integer", "tsv"))
      -- Subtype of member
      assert.equals("ubyte", parser(badVal, "ubyte", "tsv"))
      assert.equals("uint", parser(badVal, "uint", "tsv"))

      -- Non-member, non-subtype
      assert.is_nil(parser(badVal, "float", "tsv"))
    end)

    it("should accept subtypes of members via the tag's direct parser", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- ttIntTag was registered above
      local parser = parsers.parseType(badVal, "ttIntTag")
      assert.is_not_nil(parser)

      -- Direct member
      assert.equals("integer", parser(badVal, "integer", "tsv"))
      -- Subtype of member
      assert.equals("ubyte", parser(badVal, "ubyte", "tsv"))
      -- Non-member
      assert.is_nil(parser(badVal, "float", "tsv"))
    end)
  end)

  describe("cross-package merge", function()
    it("should merge members from a second declaration with same ancestor", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- First declaration
      local specs1 = {{ name = "ttMergeable", parent = "number", members = {"integer"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs1))

      -- Second declaration (merge)
      local specs2 = {{ name = "ttMergeable", parent = "number", members = {"float"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs2))
      assert.equals(0, #log_messages)

      -- Both members should work
      local parser = parsers.parseType(badVal, "ttMergeable")
      assert.is_not_nil(parser)
      assert.equals("integer", parser(badVal, "integer", "tsv"))
      assert.equals("float", parser(badVal, "float", "tsv"))

      -- Non-members still rejected
      assert.is_nil(parser(badVal, "long", "tsv"))
    end)

    it("should reject merge with mismatched ancestor", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- ttMergeable already registered with ancestor "number"
      local specs = {{ name = "ttMergeable", parent = "string", members = {"ascii"} }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)

    it("should silently handle duplicate members", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- Register tag
      local specs1 = {{ name = "ttDupMembers", parent = "number", members = {"integer", "integer"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs1))
      assert.equals(0, #log_messages)

      -- Merge with duplicate of existing member
      local specs2 = {{ name = "ttDupMembers", parent = "number", members = {"integer"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs2))
      assert.equals(0, #log_messages)
    end)
  end)

  describe("mutual exclusivity", function()
    it("should reject members combined with min/max", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local specs = {{ name = "ttMixNumeric", parent = "number", members = {"integer"}, min = 0 }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)

    it("should reject members combined with validate", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local specs = {{ name = "ttMixExpr", parent = "number", members = {"integer"}, validate = "true" }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)

    it("should reject members combined with values", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local specs = {{ name = "ttMixEnum", parent = "string", members = {"ascii"}, values = {"a"} }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
      assert.is_true(#log_messages > 0)
    end)
  end)

  describe("listMembersOfTag", function()
    it("should return sorted array of member names", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      local specs = {{ name = "ttListTest", parent = "number", members = {"float", "integer", "long"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local members = introspection.listMembersOfTag("ttListTest")
      assert.is_not_nil(members)
      assert.same({"float", "integer", "long"}, members)
    end)

    it("should return nil for non-existent tag", function()
      local members = introspection.listMembersOfTag("nonExistentTag")
      assert.is_nil(members)
    end)

    it("should return nil for a regular type (not a tag)", function()
      local members = introspection.listMembersOfTag("integer")
      assert.is_nil(members)
    end)

    it("should return merged members after cross-package merge", function()
      -- ttMergeable was registered with integer, then merged with float
      local members = introspection.listMembersOfTag("ttMergeable")
      assert.is_not_nil(members)
      assert.same({"float", "integer"}, members)
    end)
  end)

  describe("usage in type specs", function()
    it("should work as a field type in a record", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- Register a tag
      local specs = {{ name = "ttRecField", parent = "number", members = {"integer", "float"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      -- Use in a record type
      local parser = parsers.parseType(badVal, "{unit:ttRecField,value:float}")
      assert.is_not_nil(parser)
    end)
  end)

  describe("tag-of-tag (nested tags)", function()
    it("should accept members of a nested tag", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- Register inner tag with specific members
      local specs = {{ name = "ttInnerTag", parent = "number", members = {"integer", "float"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      -- Register outer tag whose member is the inner tag
      specs = {{ name = "ttOuterTag", parent = "number", members = {"ttInnerTag"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      -- Direct member of inner tag should be accepted by outer tag
      local parser = parsers.parseType(badVal, "ttOuterTag")
      assert.is_not_nil(parser)
      local parsed = parser(badVal, "integer")
      assert.equals("integer", parsed)
      parsed = parser(badVal, "float")
      assert.equals("float", parsed)
    end)

    it("should accept subtypes of nested tag members", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- ttInnerTag has member "integer"; ubyte extends integer
      local parser = parsers.parseType(badVal, "ttOuterTag")
      assert.is_not_nil(parser)
      local parsed = parser(badVal, "ubyte")
      assert.equals("ubyte", parsed)
    end)

    it("should reject non-members of nested tag", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- ttInnerTag has {integer, float}; long is not a member
      local parser = parsers.parseType(badVal, "ttOuterTag")
      assert.is_not_nil(parser)
      local parsed = parser(badVal, "long")
      assert.is_nil(parsed)
    end)

    it("should work with three levels of nesting", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- ttInnerTag has {integer, float}, ttOuterTag has {ttInnerTag}
      -- Now create a top-level tag containing ttOuterTag
      local specs = {{ name = "ttTopTag", parent = "number", members = {"ttOuterTag"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ttTopTag")
      assert.is_not_nil(parser)
      -- integer is a member of ttInnerTag, which is a member of ttOuterTag, which is a member of ttTopTag
      local parsed = parser(badVal, "integer")
      assert.equals("integer", parsed)
      -- long is not in any nested tag
      parsed = parser(badVal, "long")
      assert.is_nil(parsed)
    end)

    it("should reject tag member with incompatible ancestor", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- Register a tag with ancestor "string"
      local specs = {{ name = "ttStringTag", parent = "string", members = {"ascii"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      -- Try to add ttStringTag as a member of a tag with ancestor "number"
      specs = {{ name = "ttBadNest", parent = "number", members = {"ttStringTag"} }}
      assert.is_false(parsers.registerTypesFromSpec(badVal, specs))
    end)

    it("should allow tag member whose ancestor is a subtype of parent ancestor", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)

      -- Register a tag with ancestor "integer" (which extends "number")
      local specs = {{ name = "ttIntOnlyTag", parent = "integer", members = {"ubyte"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      -- Use it as a member of a tag with ancestor "number"
      specs = {{ name = "ttBroadTag", parent = "number", members = {"ttIntOnlyTag", "float"} }}
      assert.is_true(parsers.registerTypesFromSpec(badVal, specs))

      local parser = parsers.parseType(badVal, "ttBroadTag")
      assert.is_not_nil(parser)
      -- ubyte is a member of ttIntOnlyTag (ancestor integer extends number)
      local parsed = parser(badVal, "ubyte")
      assert.equals("ubyte", parsed)
      -- float is a direct member
      parsed = parser(badVal, "float")
      assert.equals("float", parsed)
      -- long is not in any nested tag or direct member
      parsed = parser(badVal, "long")
      assert.is_nil(parsed)
    end)

    it("listMembersOfTag should return direct members only (including tag names)", function()
      -- ttOuterTag has direct member ttInnerTag (not integer, float)
      local members = introspection.listMembersOfTag("ttOuterTag")
      assert.is_not_nil(members)
      assert.same({"ttInnerTag"}, members)
    end)
  end)

  describe("isMemberOfTag API", function()
    it("should return true for a direct member", function()
      -- ttNumGroup was registered with members {"integer", "float"}
      assert.is_true(introspection.isMemberOfTag("ttNumGroup", "integer"))
      assert.is_true(introspection.isMemberOfTag("ttNumGroup", "float"))
    end)

    it("should return true for a subtype of a member", function()
      -- ttNumGroup has member "integer"; ubyte extends integer
      assert.is_true(introspection.isMemberOfTag("ttNumGroup", "ubyte"))
    end)

    it("should return false for a non-member", function()
      -- ttNumGroup has members {"integer", "float"}; long is not a member
      assert.is_false(introspection.isMemberOfTag("ttNumGroup", "long"))
    end)

    it("should return false for a non-existent tag", function()
      assert.is_false(introspection.isMemberOfTag("nonExistentTag", "integer"))
    end)

    it("should return false for a regular type (not a tag)", function()
      assert.is_false(introspection.isMemberOfTag("integer", "ubyte"))
    end)

    it("should return false for non-string arguments", function()
      assert.is_false(introspection.isMemberOfTag(nil, "integer"))
      assert.is_false(introspection.isMemberOfTag("ttNumGroup", nil))
      assert.is_false(introspection.isMemberOfTag(42, "integer"))
      assert.is_false(introspection.isMemberOfTag("ttNumGroup", 42))
    end)

    it("should return true for transitive tag membership", function()
      -- ttOuterTag has member ttInnerTag; ttInnerTag has members {integer, float}
      assert.is_true(introspection.isMemberOfTag("ttOuterTag", "integer"))
      assert.is_true(introspection.isMemberOfTag("ttOuterTag", "float"))
    end)

    it("should return true for subtype via transitive tag", function()
      -- ttOuterTag -> ttInnerTag -> {integer, ...}; ubyte extends integer
      assert.is_true(introspection.isMemberOfTag("ttOuterTag", "ubyte"))
    end)

    it("should return false for non-member via transitive tag", function()
      -- ttOuterTag -> ttInnerTag -> {integer, float}; long is not in either
      assert.is_false(introspection.isMemberOfTag("ttOuterTag", "long"))
    end)

    it("should work through three levels of nesting", function()
      -- ttTopTag -> ttOuterTag -> ttInnerTag -> {integer, float}
      assert.is_true(introspection.isMemberOfTag("ttTopTag", "integer"))
      assert.is_false(introspection.isMemberOfTag("ttTopTag", "long"))
    end)
  end)

end)
