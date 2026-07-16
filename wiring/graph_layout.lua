-- Module name
local NAME = "graph_layout"

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
-- graph_layout — a family-agnostic layered (Sugiyama-style) graph layout
-- engine (Phase 1 of TODO/graph_svg_export.md).
--
-- Input is a *directed* adjacency: a flat list of node names plus, for each
-- node, the list of nodes it points to. The engine is pure — it knows
-- nothing about graph families, TSV rows, SVG, or the engine's runtime — so
-- it can lay out any directed graph, whatever the source (a graph-data file,
-- a package-dependency graph, …). It returns integer coordinates only, so
-- identical input produces byte-identical output on every run and platform.
--
-- Pipeline (the classic four Sugiyama stages):
--   1. Layer assignment  — longest-path layering from the roots.
--   2. Virtual nodes     — split edges that span >1 layer with dummy chains.
--   3. Crossing reduction — median heuristic, multiple sweeps, best-of kept.
--   4. Coordinate assignment — integer x/y with a light per-layer centering.
--
-- Determinism discipline (same bar as package_order_determinism.md): every
-- ordering tie breaks on the node's name, never on table/hash iteration
-- order. `pairs()` is never used where output order matters.
-- ============================================================

-- Default layout options. All distances are in SVG user units (px). The
-- renderer is told the same nominal box size so the boxes it draws around
-- these centre points fit the spacing computed here.
local DEFAULTS = {
    sweeps       = 8,    -- crossing-reduction passes (exportParams.svgSweeps)
    nodeSpacing  = 140,  -- horizontal gap between node centres in a layer
    -- Vertical gap between layer centre-lines. Kept generous (well above the
    -- node height) so the box-free strip between two rows is tall enough for
    -- edges to route through without crowding — a flat layout (small gap)
    -- forces near-horizontal edges that skim across boxes. Overridable via
    -- exportParams.svgLayerSpacing.
    layerSpacing = 140,
    nodeWidth    = 100,  -- nominal node box width  (for canvas sizing)
    nodeHeight   = 40,   -- nominal node box height (for canvas sizing)
    margin       = 20,   -- blank border around the whole drawing
}

local function optOr(opts, key)
    local v = opts and opts[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

-- Returns the keys of a set as an (unsorted) list.
local function keysOf(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    return out
end

-- Stable sort of a list of names (ascending). Lua's table.sort is not
-- guaranteed stable, but node names are unique (they are primary keys), so a
-- plain comparator is already total and therefore deterministic.
local function sortedNames(names)
    local out = {}
    for i = 1, #names do out[i] = names[i] end
    table.sort(out)
    return out
end

-- ============================================================
-- Stage 1 — Layer assignment (longest-path layering)
--
-- Every root (in-degree 0) sits at layer 0; every other node's layer is
-- 1 + the max layer of its parents. Computed by Kahn relaxation, whose
-- result (each node's longest distance from a source) is independent of the
-- order nodes are popped in — so it is deterministic without extra care.
-- ============================================================

local function assignLayers(nodeSet, children)
    local indeg = {}
    for name in pairs(nodeSet) do indeg[name] = 0 end
    -- Count in-edges (only edges between known nodes count).
    for _, from in ipairs(sortedNames(keysOf(nodeSet))) do
        for _, to in ipairs(children[from] or {}) do
            if nodeSet[to] then indeg[to] = indeg[to] + 1 end
        end
    end

    local layer = {}
    for name in pairs(nodeSet) do layer[name] = 0 end

    -- Process nodes in waves of in-degree 0, relaxing children. Names are
    -- pulled in sorted order purely for determinism of any side effects.
    local ready = {}
    for _, name in ipairs(sortedNames(keysOf(nodeSet))) do
        if indeg[name] == 0 then ready[#ready + 1] = name end
    end

    local processed = 0
    local head = 1
    while head <= #ready do
        local u = ready[head]; head = head + 1
        processed = processed + 1
        for _, v in ipairs(children[u] or {}) do
            if nodeSet[v] then
                if layer[u] + 1 > layer[v] then layer[v] = layer[u] + 1 end
                indeg[v] = indeg[v] - 1
                if indeg[v] == 0 then ready[#ready + 1] = v end
            end
        end
    end

    -- Defensive: nodes left unprocessed sit on a cycle (directed graph
    -- families are validated acyclic upstream, so this should not fire on
    -- production data). Keep them at layer 0 rather than crashing.
    return layer
end

-- ============================================================
-- Stage 2 — Virtual (dummy) nodes for long edges
--
-- An edge whose endpoints are more than one layer apart is split into a
-- chain of dummy nodes, one per intermediate layer, so every edge in the
-- layered structure connects *adjacent* layers. Dummies become bend points
-- for the edge's polyline in stage 4 and are then discarded.
--
-- We build, per layer, a list of "entries" (real or dummy) and the up/down
-- adjacency between adjacent layers used by crossing reduction.
-- ============================================================

-- An entry is: { key=<unique>, name=<sortKey>, dummy=<bool>, layer=<int>,
--                node=<realNodeName or nil> }.

local function buildLayers(nodeSet, layer, edgeList)
    local numLayers = 0
    for name in pairs(nodeSet) do
        if layer[name] + 1 > numLayers then numLayers = layer[name] + 1 end
    end
    if numLayers == 0 then numLayers = 1 end

    -- Per-layer entry lists; start with the real nodes (name-sorted).
    local layers = {}
    for i = 0, numLayers - 1 do layers[i] = {} end

    local entryOfNode = {}
    for _, name in ipairs(sortedNames(keysOf(nodeSet))) do
        local e = {key = name, name = name, dummy = false,
                   layer = layer[name], node = name}
        entryOfNode[name] = e
        local L = layers[layer[name]]
        L[#L + 1] = e
    end

    -- down[entry.key] / up[entry.key] = list of adjacent-layer entry keys.
    local down, up = {}, {}
    local entryByKey = {}
    for _, name in ipairs(keysOf(entryOfNode)) do
        entryByKey[name] = entryOfNode[name]
    end
    local function link(a, b)  -- a in layer L, b in layer L+1
        down[a.key] = down[a.key] or {}
        up[b.key]   = up[b.key] or {}
        down[a.key][#down[a.key] + 1] = b.key
        up[b.key][#up[b.key] + 1] = a.key
    end

    -- For each original edge, walk from source to target inserting dummies.
    -- `chain` records the ordered entry keys so stage 4 can read bend points.
    local dummyCount = 0
    for _, edge in ipairs(edgeList) do
        local from, to = edge.from, edge.to
        local lf, lt = layer[from], layer[to]
        edge.chain = {from}
        if lt <= lf then
            -- Non-forward edge (cycle remnant / self loop). Draw straight,
            -- and skip the layered adjacency (crossing reduction ignores it).
            edge.chain[#edge.chain + 1] = to
        else
            local prev = entryOfNode[from]
            for L = lf + 1, lt - 1 do
                dummyCount = dummyCount + 1
                -- Dummy sort key ties break deterministically on the edge's
                -- endpoints and the layer, never on creation order.
                local dname = "\1" .. from .. "\1" .. to .. "\1"
                    .. string.format("%04d", L)
                local d = {key = "d" .. dummyCount, name = dname,
                           dummy = true, layer = L, node = nil}
                entryByKey[d.key] = d
                local LL = layers[L]
                LL[#LL + 1] = d
                link(prev, d)
                prev = d
                edge.chain[#edge.chain + 1] = d.key
            end
            link(prev, entryOfNode[to])
            edge.chain[#edge.chain + 1] = to
        end
    end

    -- Initial within-layer order: by entry name (deterministic).
    for i = 0, numLayers - 1 do
        table.sort(layers[i], function(a, b) return a.name < b.name end)
    end

    return {
        layers = layers, numLayers = numLayers,
        down = down, up = up,
        entryByKey = entryByKey, entryOfNode = entryOfNode,
    }
end

-- ============================================================
-- Stage 3 — Crossing reduction (median heuristic, best-of retention)
-- ============================================================

-- pos[key] = 1-based index of the entry within its layer, from `layers`.
local function computePositions(layers, numLayers)
    local pos = {}
    for i = 0, numLayers - 1 do
        local L = layers[i]
        for j = 1, #L do pos[L[j].key] = j end
    end
    return pos
end

-- The weighted median of a node's neighbour positions (Gansner et al., the
-- "wmedian" used by Graphviz dot). Returns -1 when the node has no
-- neighbours on the reference side, marking it "fixed" for reorder().
local function medianValue(neighbourKeys, pos)
    local m = #neighbourKeys
    if m == 0 then return -1 end
    local ps = {}
    for i = 1, m do ps[i] = pos[neighbourKeys[i]] end
    table.sort(ps)
    local mid = math.floor((m + 1) / 2)  -- lower median index (1-based)
    if m % 2 == 1 then
        return ps[mid]
    elseif m == 2 then
        return (ps[1] + ps[2]) / 2
    else
        local left = ps[mid] - ps[1]
        local right = ps[m] - ps[mid + 1]
        if left + right == 0 then return (ps[mid] + ps[mid + 1]) / 2 end
        return (ps[mid] * right + ps[mid + 1] * left) / (left + right)
    end
end

-- Reorder one layer by median. Fixed nodes (no reference neighbours) keep
-- their slot; movable nodes are sorted by (median, name) and refilled into
-- the remaining slots — the standard wmedian transposition-free reorder.
local function reorderLayer(layerEntries, adj, pos)
    local movable = {}
    local fixedSlots = {}
    for idx, e in ipairs(layerEntries) do
        local med = medianValue(adj[e.key] or {}, pos)
        if med < 0 then
            fixedSlots[idx] = e
        else
            movable[#movable + 1] = {entry = e, med = med}
        end
    end
    table.sort(movable, function(a, b)
        if a.med ~= b.med then return a.med < b.med end
        return a.entry.name < b.entry.name  -- deterministic tie-break
    end)

    local result = {}
    local mi = 1
    for idx = 1, #layerEntries do
        if fixedSlots[idx] then
            result[idx] = fixedSlots[idx]
        else
            result[idx] = movable[mi].entry
            mi = mi + 1
        end
    end
    return result
end

-- Count edge crossings between two adjacent layers given the current order.
-- Standard method: collect (upperPos, lowerPos) for every edge, sort by
-- (upperPos, lowerPos), then count inversions in the lower-position sequence.
local function countBetween(upperLayer, _lowerLayer, down, pos)
    local pairs_ = {}
    for _, u in ipairs(upperLayer) do
        for _, lk in ipairs(down[u.key] or {}) do
            pairs_[#pairs_ + 1] = {pos[u.key], pos[lk]}
        end
    end
    table.sort(pairs_, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[2] < b[2]
    end)
    -- Count inversions in the sequence of lower positions (O(n^2); layer
    -- sizes in graph-data files are small).
    local crossings = 0
    for i = 1, #pairs_ do
        for j = i + 1, #pairs_ do
            if pairs_[i][2] > pairs_[j][2] then crossings = crossings + 1 end
        end
    end
    return crossings
end

local function totalCrossings(layers, numLayers, down, pos)
    local total = 0
    for i = 0, numLayers - 2 do
        total = total + countBetween(layers[i], layers[i + 1], down, pos)
    end
    return total
end

-- Snapshot the current per-layer ordering (entry lists) so the best sweep
-- can be restored at the end.
local function snapshotOrder(layers, numLayers)
    local snap = {}
    for i = 0, numLayers - 1 do
        local L, copy = layers[i], {}
        for j = 1, #L do copy[j] = L[j] end
        snap[i] = copy
    end
    return snap
end

local function reduceCrossings(built, sweeps)
    local layers, numLayers = built.layers, built.numLayers
    local down, up = built.down, built.up

    local pos = computePositions(layers, numLayers)
    local best = totalCrossings(layers, numLayers, down, pos)
    local bestOrder = snapshotOrder(layers, numLayers)

    for _ = 1, sweeps do
        -- Sweep down: order each layer by the median of its up-neighbours.
        for i = 1, numLayers - 1 do
            layers[i] = reorderLayer(layers[i], up, pos)
            for j = 1, #layers[i] do pos[layers[i][j].key] = j end
        end
        -- Sweep up: order each layer by the median of its down-neighbours.
        for i = numLayers - 2, 0, -1 do
            layers[i] = reorderLayer(layers[i], down, pos)
            for j = 1, #layers[i] do pos[layers[i][j].key] = j end
        end

        local c = totalCrossings(layers, numLayers, down, pos)
        if c < best then
            best = c
            bestOrder = snapshotOrder(layers, numLayers)
        end
    end

    -- Restore the best ordering seen (heuristic is not monotone).
    for i = 0, numLayers - 1 do built.layers[i] = bestOrder[i] end
    return best
end

-- ============================================================
-- Stage 4 — Coordinate assignment (integer, light per-layer centering)
--
-- Within a layer, entry k sits at x = k * nodeSpacing. Each layer is then
-- centred under the widest layer, which keeps chains and symmetric shapes
-- (diamonds, fans, balanced trees) straight without a quadratic solver.
-- All coordinates are integers, so output is bit-stable.
-- ============================================================

local function assignCoordinates(built, opts)
    local layers, numLayers = built.layers, built.numLayers
    local nodeSpacing  = optOr(opts, "nodeSpacing")
    local layerSpacing = optOr(opts, "layerSpacing")
    local nodeWidth    = optOr(opts, "nodeWidth")
    local nodeHeight   = optOr(opts, "nodeHeight")
    local margin       = optOr(opts, "margin")

    -- Width (in position units) of the widest layer.
    local maxSpan = 0
    for i = 0, numLayers - 1 do
        local span = (#layers[i] - 1) * nodeSpacing
        if span > maxSpan then maxSpan = span end
    end

    local coord = {}  -- entry.key -> {x, y}
    for i = 0, numLayers - 1 do
        local L = layers[i]
        local span = (#L - 1) * nodeSpacing
        local offset = math.floor((maxSpan - span) / 2)
        local y = margin + math.floor(nodeHeight / 2) + i * layerSpacing
        for j = 1, #L do
            local x = margin + math.floor(nodeWidth / 2)
                + offset + (j - 1) * nodeSpacing
            coord[L[j].key] = {x = x, y = y}
        end
    end

    local width  = margin * 2 + nodeWidth + maxSpan
    local height = margin * 2 + nodeHeight + (numLayers - 1) * layerSpacing
    return coord, width, height
end

-- ============================================================
-- Undirected → layered helper
--
-- An undirected graph has no inherent layering, so we synthesize one and
-- reuse the single engine: BFS from the lexicographically smallest node,
-- with each node's layer = its BFS distance. Disconnected components are
-- stacked below one another (the next component starts one layer below the
-- previous one's deepest), ordered by their smallest member — fully
-- deterministic. Each undirected edge is oriented lower-layer → higher-layer
-- (ties by name) so the engine can lay it out; the renderer draws it without
-- an arrowhead. Returns (layers = {name -> int}, adjacency = {name -> list}).
-- ============================================================

local function bfsLayering(nodes, neighbours)
    neighbours = neighbours or {}
    local nodeSet = {}
    for _, n in ipairs(nodes or {}) do nodeSet[n] = true end

    local order = sortedNames(keysOf(nodeSet))
    local layer, visited = {}, {}
    local baseLayer = 0  -- where the current component starts

    for _, start in ipairs(order) do
        if not visited[start] then
            -- BFS this component from `start` (the smallest unvisited name).
            visited[start] = true
            layer[start] = baseLayer
            local queue, head = {start}, 1
            local maxLayer = baseLayer
            while head <= #queue do
                local u = queue[head]; head = head + 1
                local nbrs = {}
                for _, v in ipairs(neighbours[u] or {}) do
                    if nodeSet[v] then nbrs[#nbrs + 1] = v end
                end
                table.sort(nbrs)
                for _, v in ipairs(nbrs) do
                    if not visited[v] then
                        visited[v] = true
                        layer[v] = layer[u] + 1
                        if layer[v] > maxLayer then maxLayer = layer[v] end
                        queue[#queue + 1] = v
                    end
                end
            end
            baseLayer = maxLayer + 1  -- stack the next component below
        end
    end

    -- Orient each undirected edge once, lower layer → higher (ties by name).
    local adjacency, seen = {}, {}
    for _, a in ipairs(order) do
        local nbrs = {}
        for _, b in ipairs(neighbours[a] or {}) do
            if nodeSet[b] and a ~= b then nbrs[#nbrs + 1] = b end
        end
        table.sort(nbrs)
        for _, b in ipairs(nbrs) do
            local lo, hi
            if layer[a] < layer[b] or (layer[a] == layer[b] and a < b) then
                lo, hi = a, b
            else
                lo, hi = b, a
            end
            local key = lo .. "\1" .. hi
            if not seen[key] then
                seen[key] = true
                adjacency[lo] = adjacency[lo] or {}
                adjacency[lo][#adjacency[lo] + 1] = hi
            end
        end
    end

    return layer, adjacency
end

-- ============================================================
-- Public entry point
-- ============================================================

--- Lays out a directed graph.
--- @param nodes table Array of node-name strings (the primary keys).
--- @param adjacency table Map name -> array of names it points to (children).
--- @param opts table|nil Layout options (see DEFAULTS); all optional.
--- @return table { nodes = {name -> {x, y, layer}},
---                 edges = { {from, to, points = {{x,y}, ...}} },
---                 width, height, crossings }
local function layout(nodes, adjacency, opts)
    opts = opts or {}
    adjacency = adjacency or {}

    -- Normalise inputs. nodeSet is the authoritative node universe; edges
    -- referencing unknown targets are ignored (upstream validation reports
    -- dangling references separately).
    local nodeSet = {}
    for _, n in ipairs(nodes or {}) do nodeSet[n] = true end

    -- children[name] = ordered list of known targets.
    local children = {}
    local edgeList = {}
    for _, from in ipairs(sortedNames(keysOf(nodeSet))) do
        local kids = adjacency[from] or {}
        local kept = {}
        for _, to in ipairs(kids) do
            if nodeSet[to] then
                kept[#kept + 1] = to
                edgeList[#edgeList + 1] = {from = from, to = to}
            end
        end
        children[from] = kept
    end

    -- Layer assignment. A caller may supply a precomputed layering via
    -- opts.layers (map name -> int), used by the undirected path where BFS
    -- distance — not longest-path — defines the bands. Missing nodes default
    -- to 0. Otherwise the standard longest-path layering runs.
    local layer
    if opts.layers then
        layer = {}
        for name in pairs(nodeSet) do
            local L = opts.layers[name]
            layer[name] = type(L) == "number" and L or 0
        end
    else
        layer = assignLayers(nodeSet, children)
    end
    local built = buildLayers(nodeSet, layer, edgeList)
    local crossings = reduceCrossings(built, optOr(opts, "sweeps"))
    local coord, width, height = assignCoordinates(built, opts)

    -- Assemble the public result. Node map keyed by real name only.
    local outNodes = {}
    for _, name in ipairs(sortedNames(keysOf(nodeSet))) do
        local c = coord[name]
        outNodes[name] = {x = c.x, y = c.y, layer = layer[name]}
    end

    -- Edges in (from, to) order for output stability; points read off the
    -- entry chain built in stage 2 (real endpoints + dummy bend points).
    table.sort(edgeList, function(a, b)
        if a.from ~= b.from then return a.from < b.from end
        return a.to < b.to
    end)
    local outEdges = {}
    for _, edge in ipairs(edgeList) do
        local points = {}
        for _, key in ipairs(edge.chain) do
            local c = coord[key]
            points[#points + 1] = {x = c.x, y = c.y}
        end
        outEdges[#outEdges + 1] =
            {from = edge.from, to = edge.to, points = points}
    end

    return {
        nodes = outNodes,
        edges = outEdges,
        width = width,
        height = height,
        crossings = crossings,
    }
end

-- ============================================================
-- Module API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    layout = layout,
    bfsLayering = bfsLayering,
    DEFAULTS = DEFAULTS,
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
