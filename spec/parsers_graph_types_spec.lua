-- parsers_graph_types_spec.lua
-- Tests for graph type parsers (Phase A1 of TODO/graph_types.md):
--   node_name, undirected_edge_key, directed_edge_key,
--   basic_graph_node, graph_node, tree_node,
--   basic_graph_edge, graph_edge, tree_edge.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it

local parsers = require("parsers")
local error_reporting = require("error_reporting")
local named_logger = require("named_logger")

local function mockBadVal(log_messages, warn_messages)
    local log = function(_self, msg) table.insert(log_messages, msg) end
    local badVal = error_reporting.badValGen(log)
    badVal.source_name = "test"
    badVal.line_no = 1
    if warn_messages then
        badVal.logger = named_logger.new(function(_self, level, message)
            if level == "WARN" then
                table.insert(warn_messages, message)
            end
            return true
        end)
    end
    return badVal
end

describe("parsers - graph types", function()

  describe("node_name", function()
    it("accepts identifier-shape names without '__'", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local p = parsers.parseType(badVal, "node_name")
      assert.is_not_nil(p, "node_name parser is nil")
      assert.same({"abc", "abc"}, {p(badVal, "abc")})
      assert.same({"a_b", "a_b"}, {p(badVal, "a_b")})
      assert.same({"_abc", "_abc"}, {p(badVal, "_abc")})
      assert.same({"abc.def", "abc.def"}, {p(badVal, "abc.def")})
      assert.same({"_a._b", "_a._b"}, {p(badVal, "_a._b")})
      assert.same({}, log_messages)
    end)

    it("rejects names containing '__'", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local p = parsers.parseType(badVal, "node_name")
      assert.is_nil((p(badVal, "a__b")))
      assert.is_nil((p(badVal, "__a")))
      assert.is_nil((p(badVal, "a__")))
      assert.is_nil((p(badVal, "a.b__c")))
      assert.same({
        "Bad node_name  in test on line 1: 'a__b'"
          .. " (must not contain '__' (reserved as edge-key separator))",
        "Bad node_name  in test on line 1: '__a'"
          .. " (must not contain '__' (reserved as edge-key separator))",
        "Bad node_name  in test on line 1: 'a__'"
          .. " (must not contain '__' (reserved as edge-key separator))",
        "Bad node_name  in test on line 1: 'a.b__c'"
          .. " (must not contain '__' (reserved as edge-key separator))",
      }, log_messages)
    end)

    it("rejects invalid name shapes inherited from 'name'", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local p = parsers.parseType(badVal, "node_name")
      assert.is_nil((p(badVal, "123abc")))
      assert.is_nil((p(badVal, "abc-def")))
      assert.is_nil((p(badVal, "")))
    end)
  end)

  describe("undirected_edge_key", function()
    it("accepts canonical 'a__b' (a < b lexicographically)", function()
      local log_messages = {}
      local warn_messages = {}
      local badVal = mockBadVal(log_messages, warn_messages)
      local p = parsers.parseType(badVal, "undirected_edge_key")
      assert.is_not_nil(p, "undirected_edge_key parser is nil")
      assert.same({"A__B", "A__B"}, {p(badVal, "A__B")})
      assert.same({"alpha__beta", "alpha__beta"}, {p(badVal, "alpha__beta")})
      assert.same({}, log_messages)
      assert.same({}, warn_messages)
    end)

    it("reorders non-canonical input and emits a warning", function()
      local log_messages = {}
      local warn_messages = {}
      local badVal = mockBadVal(log_messages, warn_messages)
      local p = parsers.parseType(badVal, "undirected_edge_key")
      assert.same({"A__B", "A__B"}, {p(badVal, "B__A")})
      assert.same({"alpha__beta", "alpha__beta"}, {p(badVal, "beta__alpha")})
      assert.same({}, log_messages)
      assert.equals(2, #warn_messages)
      assert.is_truthy(warn_messages[1]:find("'B__A'", 1, true),
        "warn must mention original value: " .. warn_messages[1])
      assert.is_truthy(warn_messages[1]:find("'A__B'", 1, true),
        "warn must mention canonical value: " .. warn_messages[1])
      assert.is_truthy(warn_messages[1]:find("test", 1, true),
        "warn must include source: " .. warn_messages[1])
    end)

    it("accepts self-loops (A__A)", function()
      local log_messages = {}
      local warn_messages = {}
      local badVal = mockBadVal(log_messages, warn_messages)
      local p = parsers.parseType(badVal, "undirected_edge_key")
      assert.same({"A__A", "A__A"}, {p(badVal, "A__A")})
      assert.same({}, log_messages)
      assert.same({}, warn_messages)
    end)

    it("rejects missing separator", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local p = parsers.parseType(badVal, "undirected_edge_key")
      assert.is_nil((p(badVal, "AB")))
      assert.same({
        "Bad undirected_edge_key  in test on line 1: 'AB'"
          .. " (expected format: <node_name>__<node_name>)",
      }, log_messages)
    end)

    it("rejects empty halves", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local p = parsers.parseType(badVal, "undirected_edge_key")
      assert.is_nil((p(badVal, "__B")))
      assert.is_nil((p(badVal, "A__")))
      assert.same({
        "Bad undirected_edge_key  in test on line 1: '__B'"
          .. " (edge key has empty half)",
        "Bad undirected_edge_key  in test on line 1: 'A__'"
          .. " (edge key has empty half)",
      }, log_messages)
    end)

    it("rejects more than two halves", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local p = parsers.parseType(badVal, "undirected_edge_key")
      assert.is_nil((p(badVal, "A__B__C")))
      assert.same({
        "Bad undirected_edge_key  in test on line 1: 'A__B__C'"
          .. " (edge key has more than two halves)",
      }, log_messages)
    end)
  end)

  describe("directed_edge_key", function()
    it("preserves authored order", function()
      local log_messages = {}
      local warn_messages = {}
      local badVal = mockBadVal(log_messages, warn_messages)
      local p = parsers.parseType(badVal, "directed_edge_key")
      assert.is_not_nil(p, "directed_edge_key parser is nil")
      assert.same({"A__B", "A__B"}, {p(badVal, "A__B")})
      assert.same({"B__A", "B__A"}, {p(badVal, "B__A")})
      assert.same({}, log_messages)
      assert.same({}, warn_messages, "directed must not emit reorder warning")
    end)

    it("accepts self-loops (cycle validator's job to flag for DAG/tree)", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local p = parsers.parseType(badVal, "directed_edge_key")
      assert.same({"A__A", "A__A"}, {p(badVal, "A__A")})
      assert.same({}, log_messages)
    end)

    it("rejects same error cases as undirected", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local p = parsers.parseType(badVal, "directed_edge_key")
      assert.is_nil((p(badVal, "AB")))
      assert.is_nil((p(badVal, "__B")))
      assert.is_nil((p(badVal, "A__")))
      assert.is_nil((p(badVal, "A__B__C")))
      assert.equals(4, #log_messages)
      for _, msg in ipairs(log_messages) do
        assert.is_truthy(msg:find("directed_edge_key", 1, true),
          "log message should mention directed_edge_key: " .. msg)
      end
    end)

    it("rejects halves that are not valid node_names", function()
      -- '__' inside a half is impossible by split-on-'__', but each half
      -- must still pass the node_name parser (which restricts the 'name' shape).
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local p = parsers.parseType(badVal, "directed_edge_key")
      assert.is_nil((p(badVal, "123__B")))
      assert.is_nil((p(badVal, "A__abc-def")))
      assert.equals(2, #log_messages)
    end)
  end)

  describe("record type aliases", function()
    it("registers basic_graph_node, graph_node, tree_node", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      assert.is_not_nil(parsers.parseType(badVal, "basic_graph_node"))
      assert.is_not_nil(parsers.parseType(badVal, "graph_node"))
      assert.is_not_nil(parsers.parseType(badVal, "tree_node"))
      assert.same({}, log_messages)
    end)

    it("registers basic_graph_edge, graph_edge, tree_edge", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      assert.is_not_nil(parsers.parseType(badVal, "basic_graph_edge"))
      assert.is_not_nil(parsers.parseType(badVal, "graph_edge"))
      assert.is_not_nil(parsers.parseType(badVal, "tree_edge"))
      assert.same({}, log_messages)
    end)

    it("introspects basic_graph_node fields", function()
      local fields = parsers.recordFieldNames("basic_graph_node")
      assert.is_not_nil(fields)
      local fieldSet = {}
      for _, name in ipairs(fields) do fieldSet[name] = true end
      assert.is_true(fieldSet.name == true, "missing 'name' field")
      assert.is_true(fieldSet.graphLinks == true, "missing 'graphLinks' field")
    end)

    it("introspects graph_node fields", function()
      local fields = parsers.recordFieldNames("graph_node")
      assert.is_not_nil(fields)
      local fieldSet = {}
      for _, name in ipairs(fields) do fieldSet[name] = true end
      assert.is_true(fieldSet.name == true, "missing 'name' field")
      assert.is_true(fieldSet.graphParents == true, "missing 'graphParents' field")
      assert.is_true(fieldSet.graphChildren == true, "missing 'graphChildren' field")
    end)

    it("tree_node inherits graph_node fields via 'extends'", function()
      local fields = parsers.recordFieldNames("tree_node")
      assert.is_not_nil(fields)
      local fieldSet = {}
      for _, name in ipairs(fields) do fieldSet[name] = true end
      assert.is_true(fieldSet.name == true, "missing 'name' field")
      assert.is_true(fieldSet.graphParents == true, "missing inherited 'graphParents'")
      assert.is_true(fieldSet.graphChildren == true, "missing inherited 'graphChildren'")
    end)

    it("edge types include the engine-owned `comment` column", function()
      -- The `comment` field is what makes the edge spec parse as a record
      -- rather than a single-pair map. See parsers/lpeg_parser.lua:96.
      for _, edgeType in ipairs({"basic_graph_edge", "graph_edge", "tree_edge"}) do
        local fields = parsers.recordFieldNames(edgeType)
        assert.is_not_nil(fields, edgeType .. " is not a record type")
        local fieldSet = {}
        for _, name in ipairs(fields) do fieldSet[name] = true end
        assert.is_true(fieldSet.name == true,
          edgeType .. " missing 'name' field")
        assert.is_true(fieldSet.comment == true,
          edgeType .. " missing 'comment' field")
      end
    end)
  end)

  describe("primary-key canonicalisation (plan example)", function()
    it("undirected 'A__B' and 'B__A' both parse to 'A__B'", function()
      -- The plan relies on this so existing PK-uniqueness checks naturally
      -- catch duplicate undirected edges authored from either side.
      local log_messages = {}
      local warn_messages = {}
      local badVal = mockBadVal(log_messages, warn_messages)
      local p = parsers.parseType(badVal, "undirected_edge_key")
      local parsed_forward = (p(badVal, "A__B"))
      local parsed_reverse = (p(badVal, "B__A"))
      assert.equals("A__B", parsed_forward)
      assert.equals("A__B", parsed_reverse)
      assert.same({}, log_messages)
      assert.equals(1, #warn_messages, "exactly one reorder warning expected")
    end)
  end)
end)
