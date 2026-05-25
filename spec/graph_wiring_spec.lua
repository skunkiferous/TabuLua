-- graph_wiring_spec.lua
-- Tests for graph_wiring module (Phase A3 of TODO/graph_types.md).

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it

local graph_wiring = require("graph_wiring")

describe("graph_wiring", function()

  describe("detectFamily", function()
    it("recognises the three direct family names", function()
      assert.equals("basic",    graph_wiring.detectFamily("basic_graph_node", {}))
      assert.equals("directed", graph_wiring.detectFamily("graph_node",       {}))
      assert.equals("directed", graph_wiring.detectFamily("tree_node",        {}))
    end)

    it("returns nil for unknown / nil typeNames", function()
      assert.is_nil(graph_wiring.detectFamily("not_a_graph_type", {}))
      assert.is_nil(graph_wiring.detectFamily(nil, {}))
      assert.is_nil(graph_wiring.detectFamily("", {}))
    end)

    it("walks the extends chain transitively", function()
      local extends = {Quest = "graph_node"}
      assert.equals("directed", graph_wiring.detectFamily("Quest", extends))
    end)

    it("walks deep extends chains", function()
      local extends = {A = "B", B = "C", C = "tree_node"}
      assert.equals("directed", graph_wiring.detectFamily("A", extends))
    end)

    it("returns nil when no ancestor is a graph family", function()
      local extends = {A = "B", B = "Custom"}
      assert.is_nil(graph_wiring.detectFamily("A", extends))
    end)

    it("is safe against cycles in the extends map", function()
      local extends = {A = "B", B = "A"}
      assert.is_nil(graph_wiring.detectFamily("A", extends))
    end)

    it("is safe against a self-loop in extends", function()
      assert.is_nil(graph_wiring.detectFamily("A", {A = "A"}))
    end)

    it("honours maxDepth", function()
      -- Without bound, this chain still terminates because graph_node has
      -- no extends entry. The bound is a defensive guard.
      local extends = {}
      for i = 1, 100 do extends["T" .. i] = "T" .. (i + 1) end
      extends.T101 = "graph_node"
      assert.equals("directed",
        graph_wiring.detectFamily("T1", extends, 200))
      -- With a short bound, the search bails out before reaching graph_node.
      assert.is_nil(graph_wiring.detectFamily("T1", extends, 5))
    end)
  end)

  describe("detectEdgeFamily", function()
    it("recognises the three direct edge family names", function()
      assert.equals("basic",    graph_wiring.detectEdgeFamily("basic_graph_edge", {}))
      assert.equals("directed", graph_wiring.detectEdgeFamily("graph_edge",       {}))
      assert.equals("directed", graph_wiring.detectEdgeFamily("tree_edge",        {}))
    end)

    it("returns nil for unknown / nil typeNames", function()
      assert.is_nil(graph_wiring.detectEdgeFamily("not_an_edge_type", {}))
      assert.is_nil(graph_wiring.detectEdgeFamily(nil, {}))
    end)

    it("walks the extends chain transitively", function()
      local extends = {QuestEdge = "graph_edge"}
      assert.equals("directed", graph_wiring.detectEdgeFamily("QuestEdge", extends))
    end)

    it("is safe against cycles in extends", function()
      assert.is_nil(graph_wiring.detectEdgeFamily("A", {A = "B", B = "A"}))
    end)
  end)

  -- Note: tests for applyAutoWiring and validateEdgeFiles were removed in
  -- Phase 2b of TODO/type_wiring.md — those dispatch entry points moved
  -- into the type-wiring registry (builtin_wiring.lua) and are no longer
  -- part of graph_wiring's public surface. Equivalent end-to-end coverage
  -- now lives in spec/graph_wiring_integration_spec.lua, which exercises
  -- the wired path through manifest_loader.processFiles.
end)
