-- Module name
local NAME = "graph_helpers"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 20, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

--- Returns the module version as a string.
--- @return string
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- Family detection (best-effort)
--
-- The helpers here read row data exposed by the validator / processor
-- row-wrappers. Those wrappers expose parsed column values via __index but
-- do NOT expose schema metadata, so a helper cannot ask "which graph family
-- is this row?" with full certainty: an isolated `basic_graph_node` with
-- no neighbours and a freshly-created `graph_node` with no parents/children
-- are structurally indistinguishable.
--
-- We therefore use *presence-of-the-wrong-family-field* as a fail-fast
-- signal: e.g. `isRoot(row)` errors when `row.graphLinks ~= nil` (a clear
-- "this is a basic_graph_node" signal), but degrades to "no parents = root"
-- when no signal is available. The error catches the common misuse case
-- (calling a directed helper on a populated undirected row) without
-- requiring schema-aware wrappers. When wrappers grow schema metadata
-- (future work), the checks here can be tightened in place.
-- ============================================================

local function familyMismatch(helperName, signal)
    error(NAME .. "." .. helperName
        .. ": not meaningful on this row (" .. signal .. ")", 3)
end

local function assertDirected(helperName, row)
    if rawequal(row, nil) then
        error(NAME .. "." .. helperName .. ": row is nil", 3)
    end
    if row.graphLinks ~= nil then
        familyMismatch(helperName,
            "row uses graphLinks; expected graph_node or tree_node")
    end
end

local function assertUndirected(helperName, row)
    if rawequal(row, nil) then
        error(NAME .. "." .. helperName .. ": row is nil", 3)
    end
    if row.graphParents ~= nil or row.graphChildren ~= nil then
        familyMismatch(helperName,
            "row uses graphParents/graphChildren; expected basic_graph_node")
    end
end

-- ============================================================
-- Accessors
-- ============================================================

--- True iff the row has no parents. graph_node / tree_node only.
local function isRoot(row)
    assertDirected("isRoot", row)
    local parents = row.graphParents
    return parents == nil or #parents == 0
end

--- True iff the row has no children. graph_node / tree_node only.
local function isLeaf(row)
    assertDirected("isLeaf", row)
    local children = row.graphChildren
    return children == nil or #children == 0
end

--- Row's graphParents as a list (never nil). graph_node / tree_node only.
local function parentsOf(row)
    assertDirected("parentsOf", row)
    return row.graphParents or {}
end

--- Row's graphChildren as a list (never nil). graph_node / tree_node only.
local function childrenOf(row)
    assertDirected("childrenOf", row)
    return row.graphChildren or {}
end

--- Row's graphLinks as a list (never nil). basic_graph_node only.
local function neighboursOf(row)
    assertUndirected("neighboursOf", row)
    return row.graphLinks or {}
end

-- ============================================================
-- Edge-key codec
-- ============================================================

--- Splits "<a>__<b>" into (a, b). Returns (nil, nil) on malformed input.
local function splitEdgeKey(key)
    if type(key) ~= "string" then return nil, nil end
    local sep_start, sep_end = key:find("__", 1, true)
    if not sep_start or not sep_end then return nil, nil end
    return key:sub(1, sep_start - 1), key:sub(sep_end + 1)
end

--- Builds a directed edge key "a__b".
local function makeEdgeKey(a, b)
    return a .. "__" .. b
end

--- Builds the canonical undirected edge key for {a, b}: lower__higher.
local function makeUndirectedEdgeKey(a, b)
    if a <= b then return a .. "__" .. b end
    return b .. "__" .. a
end

-- ============================================================
-- Name -> row index (internal)
--
-- Wrapped row arrays from validator_executor / processor_executor mirror
-- the dataset's PK index (`wrapped[pkValue] == wrapped[i]`), so a name
-- lookup is already O(1) on production data. The probe below detects
-- that fast path and reuses the array as the index, falling back to
-- building a map only for callers (notably test fixtures) that pass plain
-- Lua arrays without PK indexing.
-- ============================================================

local function nameIndex(rows)
    local first = rows[1]
    if first ~= nil and first.name ~= nil and rows[first.name] == first then
        return rows
    end
    local idx = {}
    for _, r in ipairs(rows) do
        if r.name ~= nil then idx[r.name] = r end
    end
    return idx
end

--- Finds the edge row connecting `a` and `b`, or nil if none.
--- Checks both orderings to remain robust against non-canonical undirected
--- edge data (which the parser canonicalises on read, but mutation paths
--- might not).
local function edgeForLink(edgeRows, a, b)
    local idx = nameIndex(edgeRows)
    local r = idx[makeEdgeKey(a, b)]
    if r then return r end
    if a ~= b then
        r = idx[makeEdgeKey(b, a)]
        if r then return r end
    end
    return nil
end

-- Resolves a direction argument to the row-field name to follow.
-- Returns the field name; errors on invalid combinations.
local function resolveDirection(helperName, row, direction)
    if direction == nil then
        if row.graphLinks ~= nil then return "graphLinks" end
        -- Directed default. If neither field is set, we still default to
        -- graphChildren — the traversal will yield only the starting row
        -- since the row has no outgoing links.
        return "graphChildren"
    elseif direction == "neighbours" then
        if row.graphParents ~= nil or row.graphChildren ~= nil then
            familyMismatch(helperName,
                "direction='neighbours' but row uses graphParents/graphChildren")
        end
        return "graphLinks"
    elseif direction == "children" then
        if row.graphLinks ~= nil then
            familyMismatch(helperName,
                "direction='children' but row uses graphLinks")
        end
        return "graphChildren"
    elseif direction == "parents" then
        if row.graphLinks ~= nil then
            familyMismatch(helperName,
                "direction='parents' but row uses graphLinks")
        end
        return "graphParents"
    else
        error(NAME .. "." .. helperName .. ": invalid direction '"
            .. tostring(direction)
            .. "', expected 'neighbours' | 'children' | 'parents'", 3)
    end
end

-- ============================================================
-- Cycle detection
-- ============================================================

--- Finds a cycle in `rows` by following `parentField` (typically
--- "graphChildren" for forward / "graphParents" for back). Returns a
--- list of rows forming the cycle (with the start node repeated at the
--- end of the path) or nil if the graph is acyclic. Standard DFS with
--- WHITE/GREY/BLACK colouring.
local function findCycle(rows, parentField)
    local idx = nameIndex(rows)
    local WHITE, GREY, BLACK = 1, 2, 3
    local color = {}
    for _, r in ipairs(rows) do
        if r.name ~= nil then color[r.name] = WHITE end
    end

    local function visit(node, path)
        color[node.name] = GREY
        path[#path + 1] = node
        local links = node[parentField]
        if links then
            for _, next_name in ipairs(links) do
                local c = color[next_name]
                if c == GREY then
                    -- Cycle: collect path from where next_name appears
                    -- back to the end, then close it with next_name again.
                    local cycle = {}
                    local start_at
                    for i, r in ipairs(path) do
                        if r.name == next_name then
                            start_at = i
                            break
                        end
                    end
                    if start_at then
                        for i = start_at, #path do
                            cycle[#cycle + 1] = path[i]
                        end
                        cycle[#cycle + 1] = path[start_at]
                    else
                        -- Defensive: next_name is grey but not on path
                        -- (shouldn't happen with single DFS root).
                        cycle[#cycle + 1] = idx[next_name] or {name = next_name}
                    end
                    return cycle
                elseif c == WHITE then
                    local next_node = idx[next_name]
                    if next_node then
                        local found = visit(next_node, path)
                        if found then return found end
                    end
                    -- If next_name doesn't resolve in idx, refs-exist
                    -- validation (Phase A4) will flag it separately.
                end
            end
        end
        path[#path] = nil
        color[node.name] = BLACK
        return nil
    end

    for _, r in ipairs(rows) do
        if r.name ~= nil and color[r.name] == WHITE then
            local found = visit(r, {})
            if found then return found end
        end
    end
    return nil
end

-- ============================================================
-- Traversal
-- ============================================================

--- Returns an iterator yielding rows in BFS order starting at `row`
--- (which is yielded first). `direction` is "neighbours" (basic),
--- "children" (directed forward, default) or "parents" (directed back).
local function bfs(row, rows, direction)
    local linkField = resolveDirection("bfs", row, direction)
    local idx = nameIndex(rows)
    local visited = {}
    if row.name ~= nil then visited[row.name] = true end
    local queue = {row}
    local head = 1

    return function()
        if head > #queue then return nil end
        local current = queue[head]
        head = head + 1
        local links = current[linkField]
        if links then
            for _, nbr_name in ipairs(links) do
                if not visited[nbr_name] then
                    visited[nbr_name] = true
                    local nbr_row = idx[nbr_name]
                    if nbr_row then queue[#queue + 1] = nbr_row end
                end
            end
        end
        return current
    end
end

--- Returns an iterator yielding rows in DFS order starting at `row`
--- (which is yielded first). Same direction semantics as bfs.
local function dfs(row, rows, direction)
    local linkField = resolveDirection("dfs", row, direction)
    local idx = nameIndex(rows)
    local visited = {}
    local stack = {row}

    return function()
        while #stack > 0 do
            local current = stack[#stack]
            stack[#stack] = nil
            if current.name == nil or not visited[current.name] then
                if current.name ~= nil then visited[current.name] = true end
                local links = current[linkField]
                if links then
                    -- Push in reverse so the first link is visited next.
                    for i = #links, 1, -1 do
                        local nbr_name = links[i]
                        if not visited[nbr_name] then
                            local nbr_row = idx[nbr_name]
                            if nbr_row then stack[#stack + 1] = nbr_row end
                        end
                    end
                end
                return current
            end
        end
        return nil
    end
end

--- List of every node reachable by following `graphParents` from `row`
--- (excluding `row` itself). graph_node / tree_node only.
local function ancestorsOf(row, rows)
    assertDirected("ancestorsOf", row)
    local result = {}
    local first = true
    for r in bfs(row, rows, "parents") do
        if first then first = false
        else result[#result + 1] = r end
    end
    return result
end

--- List of every node reachable by following `graphChildren` from `row`
--- (excluding `row` itself). graph_node / tree_node only.
local function descendantsOf(row, rows)
    assertDirected("descendantsOf", row)
    local result = {}
    local first = true
    for r in bfs(row, rows, "children") do
        if first then first = false
        else result[#result + 1] = r end
    end
    return result
end

--- Unweighted shortest path from `a` to `b` (inclusive), or nil if
--- disconnected. Direction is auto-detected from the starting row.
local function shortestPath(a, b, rows)
    if a.name == b.name then return {a} end
    local linkField = resolveDirection("shortestPath", a, nil)
    local idx = nameIndex(rows)
    local visited = {[a.name] = true}
    local predecessor = {}
    local queue = {a}
    local head = 1
    while head <= #queue do
        local current = queue[head]
        head = head + 1
        local links = current[linkField]
        if links then
            for _, nbr_name in ipairs(links) do
                if not visited[nbr_name] then
                    visited[nbr_name] = true
                    predecessor[nbr_name] = current
                    if nbr_name == b.name then
                        local path = {b}
                        local cur = current
                        while cur and cur.name ~= a.name do
                            path[#path + 1] = cur
                            cur = predecessor[cur.name]
                        end
                        path[#path + 1] = a
                        -- Reverse
                        local reversed = {}
                        for i = #path, 1, -1 do
                            reversed[#reversed + 1] = path[i]
                        end
                        return reversed
                    end
                    local nbr_row = idx[nbr_name]
                    if nbr_row then queue[#queue + 1] = nbr_row end
                end
            end
        end
    end
    return nil
end

-- ============================================================
-- Auto-wired validators
--
-- Each returns `true` on success, or a string error message on failure.
-- They follow the validator-expression return convention so they can be
-- dropped directly into a `validator_spec` expression:
--   "graphRefsExist(rows, 'directed')"
--   "graphAcyclic(rows)"
--   "graphTreeShape(rows)"
-- ============================================================

local REFS_FIELDS = {
    basic    = {"graphLinks"},
    directed = {"graphChildren", "graphParents"},
}

--- Validates that every name appearing in a row's link fields refers to a
--- row in the same file. `family` is "basic" or "directed".
local function graphRefsExist(rows, family)
    local fields = REFS_FIELDS[family]
    if not fields then
        return "graphRefsExist: invalid family '" .. tostring(family)
            .. "' (expected 'basic' or 'directed')"
    end
    local idx = nameIndex(rows)
    for _, r in ipairs(rows) do
        local rName = tostring(r.name)
        for _, fld in ipairs(fields) do
            local links = r[fld]
            if links then
                for _, refName in ipairs(links) do
                    if idx[refName] == nil then
                        return string.format(
                            "%s: row '%s' %s references unknown node '%s'",
                            family, rName, fld, tostring(refName))
                    end
                end
            end
        end
    end
    return true
end

--- Validates that the directed graph has no cycle along graphChildren.
--- Self-loops (A in A.graphChildren) count as cycles for DAG/tree
--- contexts (auto-wired only for the directed family).
local function graphAcyclic(rows)
    local cycle = findCycle(rows, "graphChildren")
    if not cycle then return true end
    local pathNames = {}
    for _, r in ipairs(cycle) do
        pathNames[#pathNames + 1] = tostring(r.name)
    end
    return "graph has a cycle via graphChildren: " .. table.concat(pathNames, " -> ")
end

--- Validates the tree-shape invariants for `tree_node` files (run AFTER
--- the completion pre-processor, so graphParents is fully populated):
---   * every node has at most one parent
---   * there is exactly one root (a node with zero parents)
local function graphTreeShape(rows)
    local roots = {}
    local firstMultiParent
    for _, r in ipairs(rows) do
        local parents = r.graphParents
        local nParents = parents and #parents or 0
        if nParents > 1 and not firstMultiParent then
            local parentNames = {}
            for _, p in ipairs(parents) do
                parentNames[#parentNames + 1] = tostring(p)
            end
            firstMultiParent = string.format(
                "tree node '%s' has %d parents (max 1): %s",
                tostring(r.name), nParents, table.concat(parentNames, ", "))
        end
        if nParents == 0 then
            roots[#roots + 1] = tostring(r.name)
        end
    end
    if firstMultiParent then return firstMultiParent end
    if #roots == 0 then
        -- A tree with at least one node must have a root. Zero roots
        -- means every node has a parent — i.e. there is a cycle. The
        -- acyclic validator catches it more precisely; report a helpful
        -- pointer here too.
        return "tree has no root (every node has a parent — likely a cycle)"
    end
    if #roots > 1 then
        table.sort(roots)
        return string.format(
            "tree has %d roots: %s (expected exactly one)",
            #roots, table.concat(roots, ", "))
    end
    return true
end

-- ============================================================
-- Module API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    -- Accessors
    isRoot = isRoot,
    isLeaf = isLeaf,
    parentsOf = parentsOf,
    childrenOf = childrenOf,
    neighboursOf = neighboursOf,
    -- Edge-key codec
    splitEdgeKey = splitEdgeKey,
    makeEdgeKey = makeEdgeKey,
    makeUndirectedEdgeKey = makeUndirectedEdgeKey,
    edgeForLink = edgeForLink,
    -- Cycle detection
    findCycle = findCycle,
    -- Traversal
    bfs = bfs,
    dfs = dfs,
    ancestorsOf = ancestorsOf,
    descendantsOf = descendantsOf,
    shortestPath = shortestPath,
    -- Auto-wired validators
    graphRefsExist = graphRefsExist,
    graphAcyclic = graphAcyclic,
    graphTreeShape = graphTreeShape,
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
