-- Module name
local NAME = "graph_wiring"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 20, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local logger = require("named_logger").getLogger(NAME)

local graph_helpers = require("graph_helpers")
local splitEdgeKey = graph_helpers.splitEdgeKey

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

-- Auto-wired completion processor entries. Both run early (priority 50,
-- which is below the DEFAULT_PRIORITY of 100 used for user processors)
-- and re-run after cross-package mod patches.
local BASIC_COMPLETION = readOnly({
    expr = "completeBasicGraph(rows)",
    priority = 50,
    rerunAfterPatches = true,
    level = "error",
})

local DIRECTED_COMPLETION = readOnly({
    expr = "completeDirectedGraph(rows)",
    priority = 50,
    rerunAfterPatches = true,
    level = "error",
})

local COMPLETION_FOR = {
    basic    = BASIC_COMPLETION,
    directed = DIRECTED_COMPLETION,
}

-- Auto-wired file validator entries. All level="error" so a violation
-- stops the load. Refs-exist comes first because it catches the cheapest
-- authoring mistake (a typo in a link name); the cycle / tree checks
-- only make sense once references resolve.
local REFS_BASIC = readOnly({
    expr = "graphRefsExist(rows, 'basic')",
    level = "error",
})

local REFS_DIRECTED = readOnly({
    expr = "graphRefsExist(rows, 'directed')",
    level = "error",
})

local ACYCLIC = readOnly({
    expr = "graphAcyclic(rows)",
    level = "error",
})

local TREE_SHAPE = readOnly({
    expr = "graphTreeShape(rows)",
    level = "error",
})

-- Per-role list of validator entries to attach.
local VALIDATORS_FOR_ROLE = {
    basic            = {REFS_BASIC},
    directed_graph   = {REFS_DIRECTED, ACYCLIC},
    directed_tree    = {REFS_DIRECTED, ACYCLIC, TREE_SHAPE},
}

local function roleKey(role)
    if role.family == "basic" then return "basic" end
    return role.tree and "directed_tree" or "directed_graph"
end

-- True if `processors` already contains an entry whose expression matches
-- `expr`. Used to keep applyAutoWiring idempotent across re-runs of the
-- manifest loader (which can happen in tests or future hot-reload paths).
local function alreadyContainsExpr(processors, expr)
    if processors == nil then return false end
    for _, p in ipairs(processors) do
        if type(p) == "string" then
            if p == expr then return true end
        elseif type(p) == "table" and p.expr == expr then
            return true
        end
    end
    return false
end

-- Appends `entry` to `list[lcfn]` (or creates the list) unless an entry
-- with the same expression already exists. Used for both pre-processors
-- and validators to keep applyAutoWiring idempotent.
local function appendUnique(map, lcfn, entry, prepend)
    local existing = map[lcfn]
    if existing == nil then
        map[lcfn] = {entry}
    elseif not alreadyContainsExpr(existing, entry.expr) then
        if prepend then
            table.insert(existing, 1, entry)
        else
            existing[#existing + 1] = entry
        end
    end
end

--- Auto-attaches completion pre-processors AND validators to every file
--- whose type transitively extends `basic_graph_node` / `graph_node` /
--- `tree_node`. Mutates both maps in place.
---
--- Attached per family:
---   basic         → completeBasicGraph    + graphRefsExist
---   graph_node    → completeDirectedGraph + graphRefsExist + graphAcyclic
---   tree_node     → completeDirectedGraph + graphRefsExist + graphAcyclic
---                                         + graphTreeShape
---
--- Validators are appended (not prepended): user validators run first,
--- catching authoring-specific errors before the structural checks.
---
--- Arguments:
---   lcFn2PreProcessors:  map lcfn -> list of processor_spec entries.
---   lcFn2FileValidators: map lcfn -> list of validator_spec entries.
---   lcFn2Type:           map lcfn -> typeName (from manifest loader).
---   extendsMap:          map typeName -> superType (from manifest loader).
local function applyAutoWiring(lcFn2PreProcessors, lcFn2FileValidators,
                               lcFn2Type, extendsMap)
    if type(lcFn2PreProcessors) ~= "table"
        or type(lcFn2FileValidators) ~= "table"
        or type(lcFn2Type) ~= "table"
        or type(extendsMap) ~= "table" then
        error("graph_wiring.applyAutoWiring: arguments must be tables", 2)
    end
    for lcfn, typeName in pairs(lcFn2Type) do
        local role = detectRole(typeName, extendsMap)
        if role then
            local family = role.family
            -- Completion pre-processor (priority 50, prepended so it runs
            -- before user pre-processors).
            local completion = assert(COMPLETION_FOR[family],
                "graph_wiring: no completion entry for family " .. tostring(family))
            appendUnique(lcFn2PreProcessors, lcfn, completion, true)
            -- Validator stack (appended so user validators run first).
            local validators = VALIDATORS_FOR_ROLE[roleKey(role)]
            for _, v in ipairs(validators) do
                appendUnique(lcFn2FileValidators, lcfn, v, false)
            end
            logger:info(string.format(
                "Auto-wired %s graph wiring for %s (typeName=%s, tree=%s)",
                family, lcfn, tostring(typeName), tostring(role.tree == true)))
        end
    end
end

-- ============================================================
-- Edge-file consistency validator (Phase A5)
--
-- Run after pre-processors so node link fields are fully completed.
-- Checks:
--   * `edgesFor` target file exists.
--   * No two edge files target the same node file.
--   * Edge file's edge-family matches the node file's node-family
--     (basic ↔ basic, directed ↔ directed).
--   * Every edge row's endpoints exist as rows in the node file.
--   * Every edge row's endpoints match a declared link in the node file
--     (graphLinks for basic, graphChildren for directed).
--
-- Errors are reported via `badVal`. Returns true iff no errors.
-- ============================================================

-- Returns the parsed value of a row's cell by column name.
-- Falls back to evaluated/value if `parsed` is absent (older cells).
local function cellValue(row, header, colName)
    local col = header[colName]
    if not col then return nil end
    local cell = row[col.idx]
    if not cell then return nil end
    if cell.parsed ~= nil then return cell.parsed end
    return cell.evaluated
end

-- True if `list` contains `value`. Handles nil lists.
local function listContains(list, value)
    if list == nil then return false end
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

--- Validates the edge↔node consistency described in TODO/graph_types.md
--- Phase A5. Returns true on success, false on any error (errors are
--- accumulated via badVal).
local function validateEdgeFiles(tsv_files, lcFn2EdgesFor, lcFn2Type,
                                 extendsMap, badVal)
    if type(tsv_files) ~= "table"
        or type(lcFn2EdgesFor) ~= "table"
        or type(lcFn2Type) ~= "table"
        or type(extendsMap) ~= "table" then
        error("graph_wiring.validateEdgeFiles: arguments must be tables", 2)
    end
    if next(lcFn2EdgesFor) == nil then
        return true  -- no edge files declared
    end

    -- Build a reverse index from lcfn -> full file_name (the tsv_files key).
    -- tsv_files is keyed by full path; we matched edge declarations by
    -- lowercased filename earlier, so we need this to fetch the data.
    local lcfnToFileName = {}
    for file_name in pairs(tsv_files) do
        local lcfn = file_name:match("[/\\]([^/\\]+)$") or file_name
        lcfnToFileName[lcfn:lower()] = file_name
    end

    -- Detect collisions: at most one edge file per node file.
    local nodeToEdge = {}
    local ok = true
    for edgeLcfn, nodeLcfn in pairs(lcFn2EdgesFor) do
        local existing = nodeToEdge[nodeLcfn]
        if existing then
            badVal.source_name = lcfnToFileName[edgeLcfn] or edgeLcfn
            badVal(edgeLcfn, "node file '" .. nodeLcfn
                .. "' already has an edge file: '" .. existing
                .. "'. A node file may have at most one edge file.")
            ok = false
        else
            nodeToEdge[nodeLcfn] = edgeLcfn
        end
    end

    -- Per-edge-file checks.
    for edgeLcfn, nodeLcfn in pairs(lcFn2EdgesFor) do
        local edgeFileName = lcfnToFileName[edgeLcfn]
        local nodeFileName = lcfnToFileName[nodeLcfn]
        if not edgeFileName then
            -- Edge file declared in Files.tsv but not present on disk;
            -- the "file listed in Files.tsv does not exist on disk" error
            -- is already reported separately.
            ok = false
        elseif not nodeFileName then
            badVal.source_name = edgeFileName
            badVal(edgeLcfn, "edgesFor target '" .. nodeLcfn
                .. "' does not exist (must match an entry in fileName)")
            ok = false
        else
            local edgeRole = detectEdgeFamily(lcFn2Type[edgeLcfn], extendsMap)
            local nodeRole = detectFamily(lcFn2Type[nodeLcfn], extendsMap)
            if not edgeRole then
                badVal.source_name = edgeFileName
                badVal(edgeLcfn, "file declares 'edgesFor' but its typeName '"
                    .. tostring(lcFn2Type[edgeLcfn])
                    .. "' does not extend any edge family"
                    .. " (basic_graph_edge / graph_edge / tree_edge)")
                ok = false
            elseif not nodeRole then
                badVal.source_name = edgeFileName
                badVal(edgeLcfn, "edgesFor target '" .. nodeLcfn
                    .. "' has typeName '" .. tostring(lcFn2Type[nodeLcfn])
                    .. "' which does not extend any node family"
                    .. " (basic_graph_node / graph_node / tree_node)")
                ok = false
            elseif edgeRole ~= nodeRole then
                badVal.source_name = edgeFileName
                badVal(edgeLcfn, "edge family mismatch: edge file is '"
                    .. edgeRole .. "' but node file is '" .. nodeRole
                    .. "' (basic edges only pair with basic node files,"
                    .. " directed edges with directed node files)")
                ok = false
            else
                -- Endpoint and link-consistency checks. Walk every edge
                -- row, parse its name into (a, b), and check both halves
                -- against the node file. The dataset returned by
                -- processTSV is already PK-indexed (see tsv_model.lua
                -- opt_index), so nodeTsv[name] is an O(1) lookup — no
                -- name→row index needed here.
                local nodeTsv = tsv_files[nodeFileName]
                local nodeHeader = nodeTsv[1]
                local edgeTsv = tsv_files[edgeFileName]
                local edgeHeader = edgeTsv[1]
                local linkField = (nodeRole == "basic")
                    and "graphLinks" or "graphChildren"
                badVal.source_name = edgeFileName
                for i = 2, #edgeTsv do
                    local row = edgeTsv[i]
                    if type(row) == "table" then
                        local key = cellValue(row, edgeHeader, "name")
                        if type(key) == "string" then
                            local a, b = splitEdgeKey(key)
                            if not a or not b then
                                -- Malformed key — the edge-key parser
                                -- already rejected it; nothing extra to say.
                            else
                                local rowA = nodeTsv[a]
                                local rowB = nodeTsv[b]
                                if not rowA then
                                    badVal(key, "edge endpoint '" .. a
                                        .. "' is not a row in '"
                                        .. nodeLcfn .. "'")
                                    ok = false
                                end
                                if not rowB then
                                    badVal(key, "edge endpoint '" .. b
                                        .. "' is not a row in '"
                                        .. nodeLcfn .. "'")
                                    ok = false
                                end
                                if rowA and rowB then
                                    -- Edge must correspond to a declared
                                    -- link in the node file. Post-
                                    -- completion the symmetry guarantee
                                    -- means we only need to check one
                                    -- side of the link.
                                    local aLinks = cellValue(rowA, nodeHeader, linkField)
                                    if not listContains(aLinks, b) then
                                        badVal(key,
                                            "edge has no matching link in '"
                                            .. nodeLcfn .. "': '" .. a
                                            .. "." .. linkField
                                            .. "' does not contain '" .. b
                                            .. "'")
                                        ok = false
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return ok
end

-- ============================================================
-- Module API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    applyAutoWiring = applyAutoWiring,
    detectFamily = detectFamily,
    detectRole = detectRole,
    detectEdgeFamily = detectEdgeFamily,
    validateEdgeFiles = validateEdgeFiles,
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
