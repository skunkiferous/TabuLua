-- graph_layout_spec.lua
-- Tests for the graph_layout engine (Phase 1 of TODO/graph_svg_export.md).
--
-- The engine is pure numbers, so tests assert on layers, coordinates, and the
-- reported crossing count directly — no SVG or XML parsing involved.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it

local graph_layout = require("wiring.graph_layout")

-- ============================================================
-- Helpers
-- ============================================================

-- Serialize a layout result to a stable string so two runs can be compared
-- byte-for-byte (the determinism contract).
local function serialize(res)
    local parts = {}
    local names = {}
    for name in pairs(res.nodes) do names[#names + 1] = name end
    table.sort(names)
    parts[#parts + 1] = "W=" .. res.width .. " H=" .. res.height
        .. " X=" .. res.crossings
    for _, name in ipairs(names) do
        local n = res.nodes[name]
        parts[#parts + 1] = string.format("N %s l=%d x=%d y=%d",
            name, n.layer, n.x, n.y)
    end
    for _, e in ipairs(res.edges) do
        local pts = {}
        for _, p in ipairs(e.points) do
            pts[#pts + 1] = "(" .. p.x .. "," .. p.y .. ")"
        end
        parts[#parts + 1] = string.format("E %s->%s %s",
            e.from, e.to, table.concat(pts, " "))
    end
    return table.concat(parts, "\n")
end

local function findEdge(res, from, to)
    for _, e in ipairs(res.edges) do
        if e.from == from and e.to == to then return e end
    end
    return nil
end

-- ============================================================
-- Layer assignment
-- ============================================================

describe("graph_layout.layout — layer assignment", function()
    it("lays a chain out one node per layer with no crossings", function()
        local res = graph_layout.layout(
            {"A", "B", "C", "D"},
            {A = {"B"}, B = {"C"}, C = {"D"}})
        assert.equal(0, res.nodes.A.layer)
        assert.equal(1, res.nodes.B.layer)
        assert.equal(2, res.nodes.C.layer)
        assert.equal(3, res.nodes.D.layer)
        assert.equal(0, res.crossings)
    end)

    it("uses longest-path layering (a node sits below its deepest parent)",
    function()
        -- A -> B -> C and A -> C: C must land at layer 2, not 1.
        local res = graph_layout.layout(
            {"A", "B", "C"},
            {A = {"B", "C"}, B = {"C"}})
        assert.equal(0, res.nodes.A.layer)
        assert.equal(1, res.nodes.B.layer)
        assert.equal(2, res.nodes.C.layer)
    end)

    it("places every root at layer 0 for a multi-root DAG", function()
        local res = graph_layout.layout(
            {"R", "S", "A"},
            {R = {"A"}, S = {"A"}})
        assert.equal(0, res.nodes.R.layer)
        assert.equal(0, res.nodes.S.layer)
        assert.equal(1, res.nodes.A.layer)
        assert.equal(0, res.crossings)
    end)

    it("keeps an isolated node at layer 0", function()
        local res = graph_layout.layout({"A", "B", "Z"}, {A = {"B"}})
        assert.equal(0, res.nodes.Z.layer)
    end)
end)

-- ============================================================
-- Coordinate assignment
-- ============================================================

describe("graph_layout.layout — coordinates", function()
    it("centres a diamond symmetrically", function()
        -- A -> {B, C} -> D. With default spacing the top/bottom singletons
        -- sit centred between the two middle nodes.
        local res = graph_layout.layout(
            {"A", "B", "C", "D"},
            {A = {"B", "C"}, B = {"D"}, C = {"D"}})
        assert.equal(0, res.crossings)
        -- A and D share the centre x; B and C straddle it symmetrically.
        assert.equal(res.nodes.A.x, res.nodes.D.x)
        assert.is_true(res.nodes.B.x < res.nodes.A.x)
        assert.is_true(res.nodes.C.x > res.nodes.A.x)
        assert.equal(res.nodes.A.x - res.nodes.B.x,
                     res.nodes.C.x - res.nodes.A.x)
    end)

    it("returns integer coordinates and a canvas that bounds them", function()
        local res = graph_layout.layout(
            {"A", "B", "C", "D", "E"},
            {A = {"B", "C", "D", "E"}})
        for _, n in pairs(res.nodes) do
            assert.equal(n.x, math.floor(n.x))
            assert.equal(n.y, math.floor(n.y))
            assert.is_true(n.x >= 0 and n.x <= res.width)
            assert.is_true(n.y >= 0 and n.y <= res.height)
        end
    end)
end)

-- ============================================================
-- Long edges / dummy nodes
-- ============================================================

describe("graph_layout.layout — long edges", function()
    it("inserts a bend point for an edge spanning two layers", function()
        -- A -> B -> C plus A -> C (A at 0, C at 2): the A->C edge routes
        -- through one dummy, so its polyline has three points.
        local res = graph_layout.layout(
            {"A", "B", "C"},
            {A = {"B", "C"}, B = {"C"}})
        local short = findEdge(res, "A", "B")
        local long  = findEdge(res, "A", "C")
        assert.equal(2, #short.points)
        assert.equal(3, #long.points)
        -- Endpoints coincide with the node centres.
        assert.same({x = res.nodes.A.x, y = res.nodes.A.y}, long.points[1])
        assert.same({x = res.nodes.C.x, y = res.nodes.C.y}, long.points[3])
    end)
end)

-- ============================================================
-- Crossing reduction
-- ============================================================

describe("graph_layout.layout — crossing reduction", function()
    it("reports the single unavoidable crossing of a 2-layer K2,2", function()
        -- {A,B} each point to {C,D}. Any left-right ordering of a complete
        -- bipartite pair leaves exactly one crossing.
        local res = graph_layout.layout(
            {"A", "B", "C", "D"},
            {A = {"C", "D"}, B = {"C", "D"}})
        assert.equal(1, res.crossings)
    end)

    it("finds a crossing-free ordering for a separable two-layer graph",
    function()
        -- A->D and B->C with the name-order initial layout crosses; the
        -- median heuristic swaps the lower layer to remove the crossing.
        local res = graph_layout.layout(
            {"A", "B", "C", "D"},
            {A = {"D"}, B = {"C"}})
        assert.equal(0, res.crossings)
    end)
end)

-- ============================================================
-- Determinism
-- ============================================================

describe("graph_layout.layout — determinism", function()
    it("produces byte-identical output across runs", function()
        local nodes = {"gamma", "alpha", "delta", "beta", "epsilon"}
        local adj = {
            alpha = {"beta", "gamma"},
            beta = {"delta"},
            gamma = {"delta", "epsilon"},
            delta = {"epsilon"},
        }
        local a = serialize(graph_layout.layout(nodes, adj))
        local b = serialize(graph_layout.layout(nodes, adj))
        assert.equal(a, b)
    end)

    it("does not depend on the order nodes are listed in", function()
        local adj = {A = {"B", "C"}, B = {"D"}, C = {"D"}}
        local a = serialize(graph_layout.layout({"A", "B", "C", "D"}, adj))
        local b = serialize(graph_layout.layout({"D", "C", "B", "A"}, adj))
        assert.equal(a, b)
    end)
end)
