-- Module name
local NAME = "svg_render"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 32, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

--- Returns the module version as a string.
--- @return string
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- svg_render — turns a laid-out graph into a self-contained SVG string
-- (Phase 2 of TODO/graph_svg_export.md).
--
-- Input is exactly what wiring/graph_layout.lua produces:
--   { nodes = {name -> {x, y, layer, [label], [role]}},
--     edges = { {from, to, points = {{x,y},...}, [label], [directed]} },
--     width, height, crossings }
-- plus render options. The module knows nothing about graph families, TSV
-- rows, or the engine — the caller decides whether the graph is directed
-- (arrowheads) and tags each node's role. It builds the document by
-- string concatenation over element lists, the same technique exporter.lua
-- uses for XML, so there is no new dependency.
--
-- Output is deterministic: nodes are emitted in name order, edges in the
-- order given (already deterministic from the layout), and every coordinate
-- is rounded to an integer, so identical input yields a byte-identical SVG.
-- ============================================================

local DEFAULTS = {
    nodeWidth  = 100,  -- must match the layout's box size for boxes to fit
    nodeHeight = 40,
    cornerRadius = 6,
    fontSize   = 13,
    strokeWidth = 1,
    endGap     = 3,    -- px between an arrowhead and the target box border
    directed   = false,
}

-- The renderer's built-in default colours — one per drawable "type": the four
-- node-role fills, the node border and label, the two link kinds (directed vs
-- undirected), the edge label, and the canvas background. This is the only
-- palette the renderer knows: it is deliberately *scheme-agnostic* (mechanism,
-- not policy). A caller passes a table of overrides via `opts.colors`, keyed by
-- these field names, and they are merged over these defaults. Named palettes
-- ("dark", "mono", …) are the opinionated part and live in the application
-- wrapper (reformatter), which just resolves them into an override table.
--
-- `isolatedFill` is for a directed-graph node with no parents AND no children
-- (no edges at all), which would otherwise be an ambiguous root+leaf.
-- `background` is "none" (transparent — the diagram adapts to whatever it is
-- embedded in); a caller sets it to fill the canvas. Fills are light enough
-- that their dark labels read on any page background.
local DEFAULT_COLORS = {
    nodeFill = "#e8eef7", rootFill = "#d7f0d7", leafFill = "#f7e0d7",
    isolatedFill = "#f0e7d0", stroke = "#4a5a7a", text = "#1a1a2e",
    edgeDirected = "#888888", edgeUndirected = "#6a8caf",
    edgeText = "#555555", background = "none",
}

local function optOr(opts, key)
    local v = opts and opts[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

-- Round to the nearest integer, deterministically (ties toward +inf). Keeps
-- the output bit-stable even when box-edge clipping produces a fraction.
local function round(x)
    return math.floor(x + 0.5)
end

-- Escape text for inclusion in XML/SVG element content and attributes.
local function escape(s)
    s = tostring(s)
    return (s:gsub("&", "&amp;")
             :gsub("<", "&lt;")
             :gsub(">", "&gt;")
             :gsub('"', "&quot;")
             :gsub("'", "&apos;"))
end

-- Sorted node names, for deterministic emission order.
local function sortedNodeNames(nodes)
    local names = {}
    for name in pairs(nodes) do names[#names + 1] = name end
    table.sort(names)
    return names
end

-- The fill colour for a node given its optional role tag. Only directed
-- families set roles; undirected nodes fall through to the plain fill.
local function fillFor(scheme, role)
    if role == "isolated" then return scheme.isolatedFill end
    if role == "root" then return scheme.rootFill end
    if role == "leaf" then return scheme.leafFill end
    return scheme.nodeFill
end

-- Assigns each node a 1-based colour index into a palette of `paletteSize`
-- entries. Edges are coloured by their *source* node, so every edge leaving a
-- node shares one colour and the reader can trace a bundle back to where it
-- came from. Within a layer, nodes are indexed left-to-right (by x, ties by
-- name), so horizontally adjacent nodes always land on consecutive — hence
-- different — palette entries: neighbouring sources are never the same colour.
-- Purely a local wayfinding cue (no legend), so cycling the palette is fine.
-- Deterministic: the result depends only on each node's within-layer position.
local function assignEdgeColorIndex(nodes, paletteSize)
    local byLayer = {}
    for name, n in pairs(nodes) do
        local L = n.layer or 0
        byLayer[L] = byLayer[L] or {}
        byLayer[L][#byLayer[L] + 1] = name
    end
    local idx = {}
    for _, names in pairs(byLayer) do
        table.sort(names, function(a, b)
            local na, nb = nodes[a], nodes[b]
            if na.x ~= nb.x then return na.x < nb.x end
            return a < b
        end)
        for i, name in ipairs(names) do
            idx[name] = (i - 1) % paletteSize + 1
        end
    end
    return idx
end

--- Renders a laid-out graph to an SVG document string.
--- @param laidOut table Result of graph_layout.layout (plus optional per-node
---   `label`/`role` and per-edge `label`/`directed`).
--- @param opts table|nil Render options (see DEFAULTS); all optional. When
---   `opts.edgePalette` is a non-empty list of colours, edges are coloured by
---   source node cycling that palette (with a matching per-colour arrowhead);
---   otherwise the single edgeDirected/edgeUndirected colour is used.
--- @return string A complete, self-contained `<svg>` document.
-- Resolves the effective colours: the built-in DEFAULT_COLORS with any
-- per-field overrides from opts.colors merged over them. Override keys are the
-- colour-slot field names (nodeFill, edgeDirected, background, …); the caller
-- owns any friendlier vocabulary and named palettes.
local function resolveColors(opts)
    local merged = {}
    for k, v in pairs(DEFAULT_COLORS) do merged[k] = v end
    if opts.colors then
        for k, v in pairs(opts.colors) do
            if v ~= nil then merged[k] = v end
        end
    end
    return merged
end

local function render(laidOut, opts)
    opts = opts or {}
    local scheme = resolveColors(opts)
    local nodeWidth  = optOr(opts, "nodeWidth")
    local nodeHeight = optOr(opts, "nodeHeight")
    local halfW, halfH = nodeWidth / 2, nodeHeight / 2
    local rx = optOr(opts, "cornerRadius")
    local fontSize = optOr(opts, "fontSize")
    local strokeWidth = optOr(opts, "strokeWidth")
    local endGap = optOr(opts, "endGap")
    local directed = optOr(opts, "directed")

    -- Edge palette: colour edges by source node cycling this list, so bundles
    -- are traceable. Off (single colour) when no palette is supplied.
    local palette = opts.edgePalette
    local usePalette = type(palette) == "table" and #palette > 0
    local edgeColorIdx = usePalette
        and assignEdgeColorIndex(laidOut.nodes or {}, #palette) or nil

    local width  = laidOut.width or 0
    local height = laidOut.height or 0

    local out = {}
    local function emit(s) out[#out + 1] = s end

    emit('<?xml version="1.0" encoding="UTF-8"?>')
    emit(string.format(
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        .. 'viewBox="0 0 %d %d" font-family="sans-serif">',
        width, height, width, height))
    emit(string.format("<!-- crossings: %d -->",
        laidOut.crossings or 0))

    -- Canvas background: a full-viewBox rect drawn first (so everything sits on
    -- top). Skipped when "none"/empty, leaving the SVG transparent so it adapts
    -- to whatever it is embedded in.
    local bg = scheme.background
    if bg and bg ~= "" and bg ~= "none" then
        emit(string.format('<rect x="0" y="0" width="%d" height="%d" fill="%s"/>',
            width, height, bg))
    end

    -- Arrowhead marker(s), only when the graph is directed. With an edge
    -- palette, one marker per palette colour (arrow1..arrowN) so each
    -- arrowhead matches its edge; otherwise a single reusable "arrow".
    local function markerDef(id, fill)
        return string.format(
            '<marker id="%s" viewBox="0 0 10 10" refX="9" refY="5" '
            .. 'markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
            .. '<path d="M0,0 L10,5 L0,10 z" fill="%s"/></marker>', id, fill)
    end
    if directed then
        emit('<defs>')
        if usePalette then
            for i = 1, #palette do
                emit(markerDef("arrow" .. i, palette[i]))
            end
        else
            emit(markerDef("arrow", scheme.edgeDirected))
        end
        emit('</defs>')
    end

    -- Edges first, so nodes draw on top of them.
    for _, edge in ipairs(laidOut.edges or {}) do
        local pts = edge.points
        local n = #pts
        if n >= 2 then
            local source = laidOut.nodes[edge.from]
            local target = laidOut.nodes[edge.to]
            -- Route each edge through vertical *ports*: it leaves the source box
            -- through the border facing the target (the bottom when the target
            -- is below, the top when above) and enters the target box through
            -- the opposite border. Because both ends sit on a box edge — not the
            -- centre — every segment lives in the box-free gap between two layer
            -- bands and can no longer skim across the boxes of a row. That is the
            -- readability win over centre-to-centre edges: a near-horizontal edge
            -- between two distant nodes in adjacent layers now travels *inside*
            -- the gap instead of slicing through the text of everything between
            -- them.
            local sy = source and source.y or pts[1].y
            local ty = target and target.y or pts[n].y
            local down = ty >= sy
            local coords = {}
            local function push(x, y)
                coords[#coords + 1] = {x = round(x), y = round(y)}
            end
            -- Source port, on the source box border facing the target.
            if source then
                push(source.x, source.y + (down and halfH or -halfH))
            else
                push(pts[1].x, pts[1].y)
            end
            -- Interior points are dummy-node bend points, each sitting at a layer
            -- centre. Rather than aim the diagonal straight at that centre (which
            -- would re-enter the layer's box band), enter the dummy's own
            -- box-free column at the near border and leave at the far one: the
            -- diagonal approach then stays in the inter-layer gap and only a
            -- short vertical run passes through the band, in a slot with no box.
            for i = 2, n - 1 do
                local dx, dy = pts[i].x, pts[i].y
                if down then
                    push(dx, dy - halfH); push(dx, dy + halfH)
                else
                    push(dx, dy + halfH); push(dx, dy - halfH)
                end
            end
            -- Target port, on the target box border, minus the arrow gap so a
            -- directed arrowhead lands on the border instead of under the box.
            if target then
                push(target.x, target.y
                    + (down and -(halfH + endGap) or (halfH + endGap)))
            else
                push(pts[n].x, pts[n].y)
            end

            local m = #coords
            local parts = {}
            for i = 1, m do
                parts[i] = coords[i].x .. "," .. coords[i].y
            end
            local edgeIsDirected = directed
            if edge.directed ~= nil then edgeIsDirected = edge.directed end
            local cIdx = usePalette and (edgeColorIdx[edge.from] or 1) or nil
            local strokeColor
            if usePalette then
                strokeColor = palette[cIdx]
            else
                strokeColor = edgeIsDirected and scheme.edgeDirected
                    or scheme.edgeUndirected
            end
            local marker = ""
            if edgeIsDirected then
                marker = usePalette
                    and string.format(' marker-end="url(#arrow%d)"', cIdx)
                    or ' marker-end="url(#arrow)"'
            end
            emit(string.format(
                '<polyline points="%s" fill="none" stroke="%s" '
                .. 'stroke-width="%d"%s/>',
                table.concat(parts, " "), strokeColor, strokeWidth, marker))

            -- Optional edge label at the polyline midpoint (Phase 5 fills
            -- these in; Phase 2 supports them if present).
            if edge.label ~= nil and edge.label ~= "" then
                local midIdx = math.floor((m + 1) / 2)
                local a = coords[midIdx]
                local b = coords[math.min(midIdx + 1, m)]
                local mx, my = round((a.x + b.x) / 2), round((a.y + b.y) / 2)
                emit(string.format(
                    '<text x="%d" y="%d" text-anchor="middle" '
                    .. 'font-size="%d" fill="%s">%s</text>',
                    mx, my, fontSize - 2, scheme.edgeText,
                    escape(edge.label)))
            end
        end
    end

    -- Nodes, in name order.
    for _, name in ipairs(sortedNodeNames(laidOut.nodes or {})) do
        local node = laidOut.nodes[name]
        local x = round(node.x - halfW)
        local y = round(node.y - halfH)
        local label = node.label
        if label == nil then label = name end
        emit(string.format(
            '<rect x="%d" y="%d" width="%d" height="%d" rx="%d" ry="%d" '
            .. 'fill="%s" stroke="%s" stroke-width="%d"/>',
            x, y, nodeWidth, nodeHeight, rx, rx,
            fillFor(scheme, node.role), scheme.stroke, strokeWidth))
        emit(string.format(
            '<text x="%d" y="%d" text-anchor="middle" '
            .. 'dominant-baseline="central" font-size="%d" fill="%s">%s</text>',
            round(node.x), round(node.y), fontSize, scheme.text,
            escape(label)))
    end

    emit('</svg>')
    emit("")  -- trailing newline
    return table.concat(out, "\n")
end

-- ============================================================
-- Module API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    render = render,
    DEFAULTS = DEFAULTS,
    DEFAULT_COLORS = DEFAULT_COLORS,
}

local function apiCall(_, operation, ...)
    if operation == "version" then
        return VERSION
    elseif API[operation] then
        return API[operation](...)
    else
        error("Unknown operation: " .. tostring(operation), 2)
    end
end

return readOnly(API, {__tostring = apiToString, __call = apiCall, __type = NAME})
