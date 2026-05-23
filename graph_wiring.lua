-- Module name
local NAME = "graph_wiring"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 19, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local logger = require("named_logger").getLogger(NAME)

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

-- Map of graph-family superType name → family kind.
local FAMILY_OF = {
    basic_graph_node = "basic",
    graph_node       = "directed",
    tree_node        = "directed",
}

--- Walks the `extends` chain starting at `typeName` looking for a known
--- graph family. Stops at the first match. Returns the family kind
--- ("basic" or "directed") or nil if no ancestor is a graph family.
--- Bounded by `maxDepth` (default 32) to defend against malformed cycles
--- in the extends map.
local function detectFamily(typeName, extends, maxDepth)
    maxDepth = maxDepth or 32
    local seen = {}
    local current = typeName
    for _ = 1, maxDepth do
        if current == nil then return nil end
        if FAMILY_OF[current] then return FAMILY_OF[current] end
        if seen[current] then
            -- Cycle in extends — Files.tsv-level error, separately reported.
            return nil
        end
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

--- Auto-attaches the matching completion pre-processor to every file whose
--- type transitively extends `basic_graph_node` / `graph_node` / `tree_node`.
--- Mutates the lcFn2PreProcessors map in place, prepending the auto-wired
--- entry so it runs *before* any user-authored pre-processors on the same
--- file (priority sorting also enforces this, but we want a deterministic
--- ordering when priorities tie).
---
--- Arguments:
---   lcFn2PreProcessors: map lcfn -> list of processor_spec entries.
---   lcFn2Type:          map lcfn -> typeName (from manifest loader).
---   extendsMap:         map typeName -> superType (from manifest loader).
local function applyAutoWiring(lcFn2PreProcessors, lcFn2Type, extendsMap)
    if type(lcFn2PreProcessors) ~= "table"
        or type(lcFn2Type) ~= "table"
        or type(extendsMap) ~= "table" then
        error("graph_wiring.applyAutoWiring: arguments must be tables", 2)
    end
    for lcfn, typeName in pairs(lcFn2Type) do
        local family = detectFamily(typeName, extendsMap)
        if family then
            local entry = assert(COMPLETION_FOR[family],
                "graph_wiring: no completion entry for family " .. tostring(family))
            local existing = lcFn2PreProcessors[lcfn]
            if existing == nil then
                lcFn2PreProcessors[lcfn] = {entry}
            elseif not alreadyContainsExpr(existing, entry.expr) then
                -- Prepend: auto-wired completion runs before user processors.
                table.insert(existing, 1, entry)
            end
            logger:info(string.format(
                "Auto-wired %s graph completion for %s (typeName=%s)",
                family, lcfn, tostring(typeName)))
        end
    end
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
    -- Exposed for tests / debugging.
    FAMILY_OF = FAMILY_OF,
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
