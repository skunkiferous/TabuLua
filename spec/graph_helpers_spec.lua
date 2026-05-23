-- graph_helpers_spec.lua
-- Tests for graph_helpers module (Phase A2 of TODO/graph_types.md).

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it

local graph_helpers = require("graph_helpers")

-- ============================================================
-- Test fixtures
--
-- We build rows as plain Lua tables; the helpers don't depend on the
-- engine's row wrappers (they just access fields via __index).
-- ============================================================

-- Basic graph:
--   A -- B
--   |    |
--   C -- D    (square)
local function basicRows()
    return {
        {name = "A", graphLinks = {"B", "C"}},
        {name = "B", graphLinks = {"A", "D"}},
        {name = "C", graphLinks = {"A", "D"}},
        {name = "D", graphLinks = {"B", "C"}},
    }
end

-- Directed DAG:
--   A -> B -> D
--   A -> C -> D
--   (D depends on B and C; B and C both depend on A)
local function dagRows()
    return {
        {name = "A", graphChildren = {"B", "C"}, graphParents = {}},
        {name = "B", graphChildren = {"D"},      graphParents = {"A"}},
        {name = "C", graphChildren = {"D"},      graphParents = {"A"}},
        {name = "D", graphChildren = {},         graphParents = {"B", "C"}},
    }
end

-- Cyclic directed:  A -> B -> C -> A
local function cyclicRows()
    return {
        {name = "A", graphChildren = {"B"}, graphParents = {"C"}},
        {name = "B", graphChildren = {"C"}, graphParents = {"A"}},
        {name = "C", graphChildren = {"A"}, graphParents = {"B"}},
    }
end

local function findByName(rows, n)
    for _, r in ipairs(rows) do
        if r.name == n then return r end
    end
    return nil
end

-- Collects all rows from an iterator. Returns list of names.
local function collectNames(iter)
    local names = {}
    for r in iter do names[#names + 1] = r.name end
    return names
end

-- Set-equality on lists of strings.
local function sameSet(a, b)
    if #a ~= #b then return false end
    local seen = {}
    for _, v in ipairs(a) do seen[v] = (seen[v] or 0) + 1 end
    for _, v in ipairs(b) do
        if not seen[v] or seen[v] == 0 then return false end
        seen[v] = seen[v] - 1
    end
    return true
end

describe("graph_helpers", function()

  describe("accessors", function()
    it("isRoot returns true for a node with no parents", function()
      local rows = dagRows()
      local A = findByName(rows, "A")
      local D = findByName(rows, "D")
      assert.is_true(graph_helpers.isRoot(A))
      assert.is_false(graph_helpers.isRoot(D))
    end)

    it("isLeaf returns true for a node with no children", function()
      local rows = dagRows()
      assert.is_false(graph_helpers.isLeaf(findByName(rows, "A")))
      assert.is_true(graph_helpers.isLeaf(findByName(rows, "D")))
    end)

    it("parentsOf / childrenOf return lists (never nil)", function()
      local rows = dagRows()
      assert.same({}, graph_helpers.parentsOf(findByName(rows, "A")))
      assert.same({"A"}, graph_helpers.parentsOf(findByName(rows, "B")))
      assert.same({"D"}, graph_helpers.childrenOf(findByName(rows, "B")))
      assert.same({}, graph_helpers.childrenOf(findByName(rows, "D")))
    end)

    it("neighboursOf returns graphLinks (never nil)", function()
      local rows = basicRows()
      assert.same({"B", "C"}, graph_helpers.neighboursOf(findByName(rows, "A")))
    end)

    it("isRoot / parentsOf error on basic_graph_node rows", function()
      local A = {name = "A", graphLinks = {"B"}}
      assert.has_error(function() graph_helpers.isRoot(A) end)
      assert.has_error(function() graph_helpers.parentsOf(A) end)
      assert.has_error(function() graph_helpers.childrenOf(A) end)
      assert.has_error(function() graph_helpers.isLeaf(A) end)
    end)

    it("neighboursOf errors on graph_node rows", function()
      local A = {name = "A", graphChildren = {"B"}, graphParents = {}}
      assert.has_error(function() graph_helpers.neighboursOf(A) end)
    end)
  end)

  describe("edge-key codec", function()
    it("splitEdgeKey returns the two halves", function()
      assert.same({"A", "B"}, {graph_helpers.splitEdgeKey("A__B")})
      assert.same({"foo", "bar"}, {graph_helpers.splitEdgeKey("foo__bar")})
    end)

    it("splitEdgeKey returns (nil, nil) on malformed input", function()
      assert.same({}, {graph_helpers.splitEdgeKey("AB")})
      assert.same({}, {graph_helpers.splitEdgeKey(42)})
    end)

    it("makeEdgeKey joins with '__'", function()
      assert.equals("A__B", graph_helpers.makeEdgeKey("A", "B"))
      assert.equals("B__A", graph_helpers.makeEdgeKey("B", "A"))
    end)

    it("makeUndirectedEdgeKey produces canonical (lower__higher) form", function()
      assert.equals("A__B", graph_helpers.makeUndirectedEdgeKey("A", "B"))
      assert.equals("A__B", graph_helpers.makeUndirectedEdgeKey("B", "A"))
      assert.equals("A__A", graph_helpers.makeUndirectedEdgeKey("A", "A"))
    end)

    it("edgeForLink finds a directed edge row", function()
      local edges = {
        {name = "A__B", weight = 1},
        {name = "B__C", weight = 2},
      }
      local found = graph_helpers.edgeForLink(edges, "A", "B")
      assert.is_not_nil(found)
      assert.equals(1, found.weight)
      assert.is_nil(graph_helpers.edgeForLink(edges, "C", "A"))
    end)

    it("edgeForLink finds undirected edges in either ordering", function()
      local edges = {{name = "A__B"}}
      assert.is_not_nil(graph_helpers.edgeForLink(edges, "A", "B"))
      assert.is_not_nil(graph_helpers.edgeForLink(edges, "B", "A"))
    end)
  end)

  describe("findCycle", function()
    it("returns nil on an acyclic DAG", function()
      local rows = dagRows()
      assert.is_nil(graph_helpers.findCycle(rows, "graphChildren"))
      assert.is_nil(graph_helpers.findCycle(rows, "graphParents"))
    end)

    it("returns a cycle path on cyclic data", function()
      local rows = cyclicRows()
      local cycle = graph_helpers.findCycle(rows, "graphChildren")
      assert.is_not_nil(cycle)
      -- First and last element of the cycle are the same node (closed loop).
      assert.equals(cycle[1].name, cycle[#cycle].name)
      -- Cycle should mention all three nodes (A, B, C in some rotation).
      local names = {}
      for i = 1, #cycle - 1 do names[#names + 1] = cycle[i].name end
      assert.is_true(sameSet({"A", "B", "C"}, names))
    end)

    it("detects self-loops", function()
      local rows = {{name = "A", graphChildren = {"A"}, graphParents = {"A"}}}
      local cycle = graph_helpers.findCycle(rows, "graphChildren")
      assert.is_not_nil(cycle)
      assert.equals("A", cycle[1].name)
    end)
  end)

  describe("bfs / dfs", function()
    it("BFS visits rows in breadth-first order on a DAG (children direction)", function()
      local rows = dagRows()
      local names = collectNames(graph_helpers.bfs(findByName(rows, "A"), rows))
      -- Starts at A, visits B/C, then D.
      assert.equals("A", names[1])
      assert.equals("D", names[#names])
      assert.equals(4, #names)
      assert.is_true(sameSet({"A", "B", "C", "D"}, names))
    end)

    it("BFS with direction='parents' walks backwards", function()
      local rows = dagRows()
      local names = collectNames(
        graph_helpers.bfs(findByName(rows, "D"), rows, "parents"))
      assert.equals("D", names[1])
      assert.equals(4, #names)
      assert.is_true(sameSet({"A", "B", "C", "D"}, names))
    end)

    it("BFS on basic graph follows graphLinks", function()
      local rows = basicRows()
      local names = collectNames(graph_helpers.bfs(findByName(rows, "A"), rows))
      assert.equals(4, #names)
      assert.is_true(sameSet({"A", "B", "C", "D"}, names))
    end)

    it("BFS visits each row at most once (cycle safety)", function()
      local rows = cyclicRows()
      local names = collectNames(graph_helpers.bfs(findByName(rows, "A"), rows))
      assert.equals(3, #names)
      assert.is_true(sameSet({"A", "B", "C"}, names))
    end)

    it("DFS visits all reachable rows", function()
      local rows = dagRows()
      local names = collectNames(graph_helpers.dfs(findByName(rows, "A"), rows))
      assert.equals(4, #names)
      assert.is_true(sameSet({"A", "B", "C", "D"}, names))
      -- DFS starts at A
      assert.equals("A", names[1])
    end)

    it("BFS errors on direction='parents' for a basic_graph_node row", function()
      local rows = basicRows()
      assert.has_error(function()
        for _ in graph_helpers.bfs(findByName(rows, "A"), rows, "parents") do end
      end)
    end)

    it("BFS errors on direction='neighbours' for a graph_node row", function()
      local rows = dagRows()
      assert.has_error(function()
        for _ in graph_helpers.bfs(findByName(rows, "A"), rows, "neighbours") do end
      end)
    end)

    it("BFS errors on an unknown direction string", function()
      local rows = dagRows()
      assert.has_error(function()
        for _ in graph_helpers.bfs(findByName(rows, "A"), rows, "siblings") do end
      end)
    end)
  end)

  describe("ancestorsOf / descendantsOf", function()
    it("ancestorsOf returns nodes reachable by graphParents (excluding self)", function()
      local rows = dagRows()
      local ancestors = graph_helpers.ancestorsOf(findByName(rows, "D"), rows)
      local names = {}
      for _, r in ipairs(ancestors) do names[#names + 1] = r.name end
      assert.is_true(sameSet({"A", "B", "C"}, names))
    end)

    it("descendantsOf returns nodes reachable by graphChildren (excluding self)", function()
      local rows = dagRows()
      local descendants = graph_helpers.descendantsOf(findByName(rows, "A"), rows)
      local names = {}
      for _, r in ipairs(descendants) do names[#names + 1] = r.name end
      assert.is_true(sameSet({"B", "C", "D"}, names))
    end)

    it("ancestorsOf on a root returns empty list", function()
      local rows = dagRows()
      assert.same({}, graph_helpers.ancestorsOf(findByName(rows, "A"), rows))
    end)

    it("descendantsOf on a leaf returns empty list", function()
      local rows = dagRows()
      assert.same({}, graph_helpers.descendantsOf(findByName(rows, "D"), rows))
    end)

    it("ancestorsOf / descendantsOf error on basic_graph_node", function()
      local rows = basicRows()
      local A = findByName(rows, "A")
      assert.has_error(function() graph_helpers.ancestorsOf(A, rows) end)
      assert.has_error(function() graph_helpers.descendantsOf(A, rows) end)
    end)
  end)

  describe("shortestPath", function()
    it("returns {a} when a == b", function()
      local rows = dagRows()
      local A = findByName(rows, "A")
      local path = graph_helpers.shortestPath(A, A, rows)
      assert.equals(1, #path)
      assert.equals("A", path[1].name)
    end)

    it("finds a directed shortest path", function()
      local rows = dagRows()
      local path = graph_helpers.shortestPath(
        findByName(rows, "A"), findByName(rows, "D"), rows)
      assert.is_not_nil(path)
      assert.equals(3, #path)
      assert.equals("A", path[1].name)
      assert.equals("D", path[3].name)
      -- Middle is either B or C (both 2-hop paths exist).
      assert.is_true(path[2].name == "B" or path[2].name == "C")
    end)

    it("finds an undirected shortest path", function()
      local rows = basicRows()
      local path = graph_helpers.shortestPath(
        findByName(rows, "A"), findByName(rows, "D"), rows)
      assert.is_not_nil(path)
      assert.equals(3, #path)
      assert.equals("A", path[1].name)
      assert.equals("D", path[3].name)
    end)

    it("returns nil when target is unreachable (directed)", function()
      -- A -> B, C is disconnected
      local rows = {
        {name = "A", graphChildren = {"B"}, graphParents = {}},
        {name = "B", graphChildren = {},    graphParents = {"A"}},
        {name = "C", graphChildren = {},    graphParents = {}},
      }
      local path = graph_helpers.shortestPath(
        findByName(rows, "A"), findByName(rows, "C"), rows)
      assert.is_nil(path)
    end)
  end)
end)
