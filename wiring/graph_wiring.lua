-- Module name
local NAME = "graph_wiring"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 28, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

--- Returns the module version as a string.
--- @return string
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- Graph family detection
--
-- Family detection keys off the *literal* `superType=` string the author
-- wrote in Files.tsv, walking the `extends` chain transitively so that
-- a user type like `Quest = {extends:graph_node, ...}` is recognised by
-- a downstream file that does `superType=Quest`.
--
-- Detection cannot rely on parser identity because `tree_node` and
-- `graph_node` alias to the same canonical parser (see TODO/graph_types.md
-- "Open Question 6"). The user-written string is the only source of truth.
-- ============================================================

-- Map of graph-family superType name → role descriptor.
--   family: "basic" | "directed"
--   tree:   true if this is the tree_node family (subset of directed)
local ROLE_OF = {
    basic_graph_node = {family = "basic"},
    graph_node       = {family = "directed", tree = false},
    tree_node        = {family = "directed", tree = true},
}

-- Map of edge-family superType name → family kind. Mirrors ROLE_OF for
-- the edge side: `basic_graph_edge` pairs with `basic_graph_node`,
-- `graph_edge` and `tree_edge` both pair with the directed families.
local EDGE_FAMILY_OF = {
    basic_graph_edge = "basic",
    graph_edge       = "directed",
    tree_edge        = "directed",
}

--- Walks the extends chain starting at `typeName` looking for a known
--- graph family. Stops at the first match. Returns a role descriptor
--- (table with `family` and optional `tree` fields) or nil if no
--- ancestor is a graph family. Bounded by `maxDepth` (default 32) to
--- defend against malformed cycles in the extends map.
local function detectRole(typeName, extends, maxDepth)
    maxDepth = maxDepth or 32
    local seen = {}
    local current = typeName
    for _ = 1, maxDepth do
        if current == nil then return nil end
        if ROLE_OF[current] then return ROLE_OF[current] end
        if seen[current] then
            -- Cycle in extends — Files.tsv-level error, separately reported.
            return nil
        end
        seen[current] = true
        current = extends[current]
    end
    return nil
end

--- Convenience: returns just the family kind ("basic" or "directed") or
--- nil. Kept for backwards compat with callers (and tests) that just
--- want the family.
local function detectFamily(typeName, extends, maxDepth)
    local role = detectRole(typeName, extends, maxDepth)
    return role and role.family or nil
end

--- Walks the extends chain to find the edge family ("basic" or "directed")
--- of an edge file's typeName. Same shape as detectFamily but for the
--- edge side of the relationship.
local function detectEdgeFamily(typeName, extends, maxDepth)
    maxDepth = maxDepth or 32
    local seen = {}
    local current = typeName
    for _ = 1, maxDepth do
        if current == nil then return nil end
        if EDGE_FAMILY_OF[current] then return EDGE_FAMILY_OF[current] end
        if seen[current] then return nil end
        seen[current] = true
        current = extends[current]
    end
    return nil
end

-- ============================================================
-- Module API
--
-- After Phase 2b of TODO/type_wiring.md, the dispatch entry points
-- (applyAutoWiring, validateEdgeFiles) and their helper plumbing
-- (BASIC/DIRECTED_COMPLETION, REFS_*, ACYCLIC, TREE_SHAPE, the
-- COMPLETION_FOR / VALIDATORS_FOR_ROLE / appendUnique helpers, and
-- cellValue / listContains) have moved into builtin_wiring.lua as
-- registry registrations. graph_wiring.lua is now just the family
-- detection helpers used by callers (and by the registered
-- edge-consistency post-pass).
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The applyAutoWiring and validateEdgeFiles dispatch entry points are gone
-- in Phase 2b: the engine reaches them through the type-wiring registry
-- (builtin_wiring.lua's register / registerModule calls). What stays here
-- are the leaf detection helpers used by the registered post-pass and by
-- callers that just want to ask "what family is this typeName?".
local API = {
    getVersion = getVersion,
    detectFamily = detectFamily,
    detectRole = detectRole,
    detectEdgeFamily = detectEdgeFamily,
    -- Exposed for tests / debugging.
    ROLE_OF = ROLE_OF,
    EDGE_FAMILY_OF = EDGE_FAMILY_OF,
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
