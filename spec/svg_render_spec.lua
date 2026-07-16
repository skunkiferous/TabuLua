-- svg_render_spec.lua
-- Tests for the svg_render renderer (Phase 2 of TODO/graph_svg_export.md).
--
-- The renderer emits plain text, so tests assert on substrings and element
-- counts (no XML library needed) plus a byte-stable golden string.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it

local svg_render = require("serde.svg_render")

-- ============================================================
-- Fixtures & helpers
-- ============================================================

-- A small directed layout: A (root) -> B (leaf).
local function directedLayout()
    return {
        nodes = {
            A = {x = 100, y = 40,  layer = 0, role = "root"},
            B = {x = 100, y = 130, layer = 1, role = "leaf"},
        },
        edges = {
            {from = "A", to = "B", points = {{x = 100, y = 40}, {x = 100, y = 130}}},
        },
        width = 200, height = 190, crossings = 0,
    }
end

-- A 3-node undirected-style layout (no roles, no arrowheads).
local function plainLayout()
    return {
        nodes = {
            X = {x = 60,  y = 40, layer = 0},
            Y = {x = 200, y = 40, layer = 0},
            Z = {x = 130, y = 130, layer = 1},
        },
        edges = {
            {from = "X", to = "Z", points = {{x = 60, y = 40}, {x = 130, y = 130}}},
            {from = "Y", to = "Z", points = {{x = 200, y = 40}, {x = 130, y = 130}}},
        },
        width = 260, height = 190, crossings = 0,
    }
end

local function countOccur(haystack, needle)
    local count, pos = 0, 1
    while true do
        local s = haystack:find(needle, pos, true)
        if not s then break end
        count = count + 1
        pos = s + 1
    end
    return count
end

-- ============================================================
-- Structure
-- ============================================================

describe("svg_render.render — structure", function()
    it("emits one rect and one label per node", function()
        local svg = svg_render.render(directedLayout(), {directed = true})
        assert.equal(2, countOccur(svg, "<rect "))
        assert.equal(2, countOccur(svg, "<text "))
    end)

    it("emits one polyline per edge", function()
        local svg = svg_render.render(plainLayout())
        assert.equal(2, countOccur(svg, "<polyline "))
    end)

    it("matches viewBox and width/height to the reported size", function()
        local svg = svg_render.render(directedLayout(), {directed = true})
        assert.is_truthy(svg:find('width="200" height="190"', 1, true))
        assert.is_truthy(svg:find('viewBox="0 0 200 190"', 1, true))
    end)

    it("surfaces the crossing count as a comment", function()
        local laid = directedLayout()
        laid.crossings = 7
        local svg = svg_render.render(laid, {directed = true})
        assert.is_truthy(svg:find("<!-- crossings: 7 -->", 1, true))
    end)
end)

-- ============================================================
-- Directed vs undirected
-- ============================================================

describe("svg_render.render — arrowheads", function()
    it("defines and uses an arrow marker for directed graphs", function()
        local svg = svg_render.render(directedLayout(), {directed = true})
        assert.is_truthy(svg:find("<marker ", 1, true))
        assert.is_truthy(svg:find('marker-end="url(#arrow)"', 1, true))
    end)

    it("omits the marker entirely for undirected graphs", function()
        local svg = svg_render.render(plainLayout())
        assert.is_nil(svg:find("<marker ", 1, true))
        assert.is_nil(svg:find("marker-end", 1, true))
    end)

    it("routes a directed edge between the two box borders", function()
        -- The vertical A->B edge (centres 100,40 -> 100,130) leaves A's bottom
        -- border (40 + halfHeight = 60) and lands on B's top border, minus the
        -- arrow gap (130 - halfHeight - gap = 107) — never running through a
        -- box centre.
        local svg = svg_render.render(directedLayout(), {directed = true})
        assert.is_truthy(svg:find('points="100,60 100,107"', 1, true))
    end)
end)

-- ============================================================
-- Edge palette (colour edges by source node)
-- ============================================================

-- Two sources (A left, B right) in layer 0 both pointing at C in layer 1.
local function twoSourceLayout()
    return {
        nodes = {
            A = {x = 60,  y = 40,  layer = 0},
            B = {x = 200, y = 40,  layer = 0},
            C = {x = 130, y = 130, layer = 1},
        },
        edges = {
            {from = "A", to = "C", points = {{x = 60,  y = 40}, {x = 130, y = 130}}},
            {from = "B", to = "C", points = {{x = 200, y = 40}, {x = 130, y = 130}}},
        },
        width = 260, height = 190, crossings = 0,
    }
end

describe("svg_render.render — edge palette", function()
    local PAL = {"#111111", "#222222"}

    it("colours edges by their source node", function()
        local svg = svg_render.render(twoSourceLayout(),
            {directed = true, edgePalette = PAL})
        -- A is the left node in layer 0 (slot 1), B the right (slot 2).
        assert.is_truthy(svg:find('stroke="#111111"', 1, true))  -- A's edge
        assert.is_truthy(svg:find('stroke="#222222"', 1, true))  -- B's edge
    end)

    it("gives adjacent sources different colours", function()
        local svg = svg_render.render(twoSourceLayout(),
            {directed = true, edgePalette = PAL})
        -- Neither of the two single-colour link defaults is used.
        assert.is_nil(svg:find('stroke="#888888"', 1, true))
    end)

    it("defines one arrow marker per palette colour and matches edges to it",
    function()
        local svg = svg_render.render(twoSourceLayout(),
            {directed = true, edgePalette = PAL})
        assert.is_truthy(svg:find('id="arrow1"', 1, true))
        assert.is_truthy(svg:find('id="arrow2"', 1, true))
        assert.is_nil(svg:find('id="arrow"', 1, true))  -- no single generic marker
        assert.is_truthy(svg:find('marker-end="url(#arrow1)"', 1, true))
        assert.is_truthy(svg:find('marker-end="url(#arrow2)"', 1, true))
    end)

    it("cycles the palette when a layer has more sources than colours", function()
        local laid = {
            nodes = {
                A = {x = 60,  y = 40, layer = 0},
                B = {x = 200, y = 40, layer = 0},
                D = {x = 340, y = 40, layer = 0},  -- third source, wraps to slot 1
                C = {x = 200, y = 130, layer = 1},
            },
            edges = {
                {from = "A", to = "C", points = {{x = 60,  y = 40}, {x = 200, y = 130}}},
                {from = "B", to = "C", points = {{x = 200, y = 40}, {x = 200, y = 130}}},
                {from = "D", to = "C", points = {{x = 340, y = 40}, {x = 200, y = 130}}},
            },
            width = 400, height = 190, crossings = 0,
        }
        local svg = svg_render.render(laid, {directed = true, edgePalette = PAL})
        -- A and D both land on slot 1 (#111111); B on slot 2 (#222222).
        assert.equal(2, countOccur(svg, 'stroke="#111111"'))
        assert.equal(1, countOccur(svg, 'stroke="#222222"'))
    end)

    it("colours undirected edges by source but adds no markers", function()
        local svg = svg_render.render(twoSourceLayout(), {edgePalette = PAL})
        assert.is_truthy(svg:find('stroke="#111111"', 1, true))
        assert.is_truthy(svg:find('stroke="#222222"', 1, true))
        assert.is_nil(svg:find("<marker ", 1, true))
        assert.is_nil(svg:find("marker-end", 1, true))
    end)

    it("falls back to the single link colour with no palette", function()
        local svg = svg_render.render(twoSourceLayout(), {directed = true})
        assert.is_truthy(svg:find('stroke="#888888"', 1, true))
        assert.is_truthy(svg:find('id="arrow"', 1, true))
    end)

    it("is byte-identical across runs with a palette", function()
        local a = svg_render.render(twoSourceLayout(),
            {directed = true, edgePalette = PAL})
        local b = svg_render.render(twoSourceLayout(),
            {directed = true, edgePalette = PAL})
        assert.equal(a, b)
    end)
end)

-- ============================================================
-- Role tinting & escaping
-- ============================================================

describe("svg_render.render — fills and escaping", function()
    it("tints root and leaf nodes with distinct fills", function()
        local svg = svg_render.render(directedLayout(), {directed = true})
        assert.is_truthy(svg:find('fill="#d7f0d7"', 1, true))  -- root
        assert.is_truthy(svg:find('fill="#f7e0d7"', 1, true))  -- leaf
    end)

    it("escapes XML-special characters in labels", function()
        local laid = {
            nodes = {["a<b&c"] = {x = 50, y = 20, layer = 0}},
            edges = {}, width = 100, height = 40, crossings = 0,
        }
        local svg = svg_render.render(laid)
        assert.is_truthy(svg:find("a&lt;b&amp;c", 1, true))
        assert.is_nil(svg:find("a<b&c", 1, true))
    end)
end)

-- ============================================================
-- Colours: built-in defaults + per-field overrides
--
-- The renderer is scheme-agnostic: it draws with DEFAULT_COLORS and merges any
-- opts.colors over them. (Named palettes live in the reformatter.)
-- ============================================================

describe("svg_render.render — colours", function()
    it("uses the built-in default colours with no overrides", function()
        local svg = svg_render.render(directedLayout(), {directed = true})
        assert.is_truthy(svg:find('fill="#d7f0d7"', 1, true))  -- default root
        assert.is_truthy(svg:find('fill="#f7e0d7"', 1, true))  -- default leaf
    end)

    it("merges per-field overrides over the defaults", function()
        local svg = svg_render.render(directedLayout(), {
            directed = true,
            colors = {rootFill = "#123456", edgeDirected = "#abcdef"},
        })
        assert.is_truthy(svg:find('fill="#123456"', 1, true))    -- overridden root
        assert.is_truthy(svg:find('stroke="#abcdef"', 1, true))  -- overridden edge
        -- Un-overridden leaf keeps the default fill.
        assert.is_truthy(svg:find('fill="#f7e0d7"', 1, true))
    end)

    it("colours directed and undirected links differently", function()
        local dir = svg_render.render(directedLayout(), {directed = true})
        local undir = svg_render.render(plainLayout())
        assert.is_truthy(dir:find('stroke="#888888"', 1, true))    -- edgeDirected
        assert.is_truthy(undir:find('stroke="#6a8caf"', 1, true))  -- edgeUndirected
        assert.is_nil(undir:find("#888888", 1, true))
    end)

    it("tints an isolated node with the isolated fill", function()
        local laid = {
            nodes = {["solo"] = {x = 60, y = 20, layer = 0, role = "isolated"}},
            edges = {}, width = 120, height = 40, crossings = 0,
        }
        local svg = svg_render.render(laid)
        assert.is_truthy(svg:find('fill="#f0e7d0"', 1, true))  -- default isolatedFill
    end)

    it("draws no background rect by default (transparent canvas)", function()
        local svg = svg_render.render(directedLayout(), {directed = true})
        assert.is_nil(svg:find("<rect x=\"0\" y=\"0\"", 1, true))
    end)

    it("fills the canvas when a background colour is given", function()
        local svg = svg_render.render(directedLayout(),
            {directed = true, colors = {background = "#1e1e2a"}})
        assert.is_truthy(svg:find(
            '<rect x="0" y="0" width="200" height="190" fill="#1e1e2a"/>', 1, true))
    end)

    it("treats a 'none' background override as transparent", function()
        local svg = svg_render.render(directedLayout(),
            {directed = true, colors = {background = "none"}})
        assert.is_nil(svg:find("<rect x=\"0\" y=\"0\"", 1, true))
    end)
end)

-- ============================================================
-- Determinism / golden string
-- ============================================================

describe("svg_render.render — determinism", function()
    it("is byte-identical across runs", function()
        local a = svg_render.render(directedLayout(), {directed = true})
        local b = svg_render.render(directedLayout(), {directed = true})
        assert.equal(a, b)
    end)

    it("matches the golden output for a known layout", function()
        local golden = table.concat({
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="190" viewBox="0 0 200 190" font-family="sans-serif">',
            '<!-- crossings: 0 -->',
            '<defs>',
            '<marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#888888"/></marker>',
            '</defs>',
            '<polyline points="100,60 100,107" fill="none" stroke="#888888" stroke-width="1" marker-end="url(#arrow)"/>',
            '<rect x="50" y="20" width="100" height="40" rx="6" ry="6" fill="#d7f0d7" stroke="#4a5a7a" stroke-width="1"/>',
            '<text x="100" y="40" text-anchor="middle" dominant-baseline="central" font-size="13" fill="#1a1a2e">A</text>',
            '<rect x="50" y="110" width="100" height="40" rx="6" ry="6" fill="#f7e0d7" stroke="#4a5a7a" stroke-width="1"/>',
            '<text x="100" y="130" text-anchor="middle" dominant-baseline="central" font-size="13" fill="#1a1a2e">B</text>',
            '</svg>',
            '',
        }, "\n")
        assert.equal(golden, svg_render.render(directedLayout(), {directed = true}))
    end)
end)
