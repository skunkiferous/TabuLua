-- Module name
local NAME = "type_wiring"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 31, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

local logger = require("infra.named_logger").getLogger(NAME)

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- Type-wiring registry (see TODO/type_wiring.md)
--
-- Two distinct registration APIs:
--
--   register(typeName, contributions)
--     Per-typeName "cascade" contributions, dispatched by walking a
--     file's `extends` chain at load time. Slots:
--       onLoad         function(file, fileType, extends, badVal, loadEnv)
--       preProcessors  array of processor_spec ({expr, priority?, ...})
--       rowValidators  array of validator_spec ({expr, level?, ...})
--       fileValidators array of validator_spec
--
--   registerModule(moduleName, declarations)
--     Module-level engine-init declarations, not tied to any typeName. Slots:
--       descriptorColumns  array of {name, type, fieldOnMeta, parse?}
--       sandboxHelpers     {processor = {[name]=fn,...}, validator = ...,
--                           both = ...}
--       enginePostPasses   array of function(tsv_files, joinMeta, badVal) → ok
--
-- The two APIs MUST NOT be mixed — passing a per-typeName slot to
-- registerModule (or vice versa) is a registration-time error.
-- ============================================================

local REGISTRY = {}             -- lowercased typeName -> per-typeName entry
local MODULES = {}              -- moduleName -> module-level entry (insertion-ordered list)
local MODULE_ORDER = {}         -- registration order of module names (for deterministic dispatch)

-- Aggregate caches built lazily from MODULES. Invalidated on any
-- registerModule call.
local CACHE = {
    descriptorColumns = nil,    -- list of column declarations
    descriptorColumnsByName = nil,
    sandboxAdditions = nil,     -- {processor = {...}, validator = {...}}
    enginePostPasses = nil,     -- ordered list of callbacks
}

-- Snapshots for global_reset restore. Populated by snapshotState() once
-- the built-in wirings have been registered (see builtin_wiring.lua).
local REGISTRY_SNAPSHOT = nil
local MODULES_SNAPSHOT = nil
local MODULE_ORDER_SNAPSHOT = nil

-- Allowed contribution keys per API. Unknown keys produce a
-- registration-time error so typos aren't silently dropped.
local PER_TYPE_KEYS = {
    onLoad = true,
    preProcessors = true,
    rowValidators = true,
    fileValidators = true,
    -- `role = true` marks a typeName as an ENGINE ROLE rather than a table type:
    -- a word a Files.tsv row uses to say what the engine should DO with the file
    -- (asset_file, patch, custom_type_def, MigrationScript, ...), not the name of
    -- the record type its rows are. See isRoleTypeName.
    role = true,
}
local MODULE_KEYS = {
    descriptorColumns = true,
    sandboxHelpers = true,
    enginePostPasses = true,
}

-- Default insertion position per per-typeName slot (L1):
-- completion processors must run *before* user processors (prepend);
-- structural validators must run *after* user validators (append).
local DEFAULT_POSITION = {
    preProcessors = "prepend",
    rowValidators = "append",
    fileValidators = "append",
}

local function invalidateCache()
    CACHE.descriptorColumns = nil
    CACHE.descriptorColumnsByName = nil
    CACHE.sandboxAdditions = nil
    CACHE.enginePostPasses = nil
end

-- ============================================================
-- Per-typeName API
-- ============================================================

-- Returns the entry's expression string, or nil if the entry doesn't have
-- one (some entries may be plain strings — `lcFn2PreProcessors` rows from
-- user-authored Files.tsv cells are stored as bare expression strings).
local function entryExpr(entry)
    if type(entry) == "string" then return entry end
    if type(entry) == "table" then return entry.expr end
    return nil
end

local function alreadyContainsExpr(list, expr)
    if list == nil or expr == nil then return false end
    for _, existing in ipairs(list) do
        if entryExpr(existing) == expr then return true end
    end
    return false
end

-- Inserts a wired entry into a target list using the entry's `position`
-- field if present, else the slot's default position. Skips entries
-- whose `expr` is already in the list (idempotency, L6). Mirrors
-- graph_wiring.appendUnique pre-refactor.
local function insertContribution(target, entry, defaultPosition)
    if target == nil then return end
    local expr = entryExpr(entry)
    if expr ~= nil and alreadyContainsExpr(target, expr) then return end
    local pos = (type(entry) == "table" and entry.position) or defaultPosition
    if pos == "prepend" then
        table.insert(target, 1, entry)
    else
        target[#target + 1] = entry
    end
end

-- Validates a {expr, ...} array contribution before storing it.
local function validateSpecList(typeName, slotName, list)
    if type(list) ~= "table" then
        error("type_wiring.register: " .. slotName
            .. " must be an array of specs for typeName '"
            .. typeName .. "'", 3)
    end
    for i, entry in ipairs(list) do
        if type(entry) == "table" then
            if entry.expr ~= nil and type(entry.expr) ~= "string" then
                error("type_wiring.register: " .. slotName .. "[" .. i
                    .. "].expr must be a string for typeName '"
                    .. typeName .. "'", 3)
            end
            if entry.position ~= nil and entry.position ~= "prepend"
                and entry.position ~= "append" then
                error("type_wiring.register: " .. slotName .. "[" .. i
                    .. "].position must be 'prepend' or 'append' for typeName '"
                    .. typeName .. "'", 3)
            end
        elseif type(entry) ~= "string" then
            error("type_wiring.register: " .. slotName .. "[" .. i
                .. "] must be a table or string for typeName '"
                .. typeName .. "'", 3)
        end
    end
end

local function register(typeName, contributions)
    if type(typeName) ~= "string" or typeName == "" then
        error("type_wiring.register: typeName must be a non-empty string", 2)
    end
    if type(contributions) ~= "table" then
        error("type_wiring.register: contributions must be a table for typeName '"
            .. typeName .. "'", 2)
    end
    for k in pairs(contributions) do
        if MODULE_KEYS[k] then
            error("type_wiring.register: '" .. k
                .. "' is a module-level slot — use registerModule instead (typeName '"
                .. typeName .. "')", 2)
        end
        if not PER_TYPE_KEYS[k] then
            error("type_wiring.register: unknown contribution key '" .. tostring(k)
                .. "' for typeName '" .. typeName .. "'", 2)
        end
    end

    if contributions.onLoad ~= nil and type(contributions.onLoad) ~= "function" then
        error("type_wiring.register: onLoad must be a function for typeName '"
            .. typeName .. "'", 2)
    end
    if contributions.preProcessors ~= nil then
        validateSpecList(typeName, "preProcessors", contributions.preProcessors)
    end
    if contributions.rowValidators ~= nil then
        validateSpecList(typeName, "rowValidators", contributions.rowValidators)
    end
    if contributions.fileValidators ~= nil then
        validateSpecList(typeName, "fileValidators", contributions.fileValidators)
    end

    local key = typeName:lower()
    local entry = REGISTRY[key]
    if entry == nil then
        entry = {typeName = typeName}
        REGISTRY[key] = entry
    end

    if contributions.role ~= nil then
        entry.role = contributions.role == true
    end

    local onLoad = contributions.onLoad
    if onLoad ~= nil then
        if entry.onLoad ~= nil and entry.onLoad ~= onLoad then
            error("type_wiring.register: onLoad for typeName '" .. typeName
                .. "' already registered with a different function", 2)
        end
        entry.onLoad = onLoad
        logger:info("Registered onLoad wiring for " .. typeName)
    end

    -- For spec lists: each registration *appends* to the entry's list with
    -- the same idempotency rule applied at dispatch time. Re-registering
    -- the same expression is a silent no-op (deduplicated at dispatch).
    local function appendSpecs(slot, source)
        if source == nil then return end
        entry[slot] = entry[slot] or {}
        for _, e in ipairs(source) do
            if not alreadyContainsExpr(entry[slot], entryExpr(e)) then
                entry[slot][#entry[slot] + 1] = e
            end
        end
    end
    appendSpecs("preProcessors",  contributions.preProcessors)
    appendSpecs("rowValidators",  contributions.rowValidators)
    appendSpecs("fileValidators", contributions.fileValidators)
end

-- Walks the extends chain starting at typeName, calling visit(entry, ancestorName)
-- for each ancestor that has a registry entry. Shallowest-first. A cycle in
-- `extends` terminates the walk silently.
local function forEachWiredAncestor(typeName, extends, visit)
    if typeName == nil then return end
    local current = typeName
    local seen = {}
    while current do
        if seen[current] then return end
        seen[current] = true
        local entry = REGISTRY[current:lower()]
        if entry then
            visit(entry, current)
        end
        current = extends[current]
    end
end

-- Walks `fileType`'s extends chain and dispatches contributions.
--
-- ctx is a table whose fields determine what work to do:
--   ctx.file / ctx.badVal / ctx.loadEnv → fire onLoad slots
--   ctx.preProcessors / ctx.rowValidators / ctx.fileValidators →
--     insert wired entries into these target arrays (per-file lists).
--
-- Each ancestor fires at most once per call (shallowest first). onLoad
-- is responsible for its own re-entry safety (e.g. parsers.registerAlias
-- already detects duplicates). Spec-list inserts are idempotent by
-- expression string.
local function applyWiring(fileType, extends, ctx)
    if fileType == nil then return end
    if type(extends) ~= "table" then
        error("type_wiring.applyWiring: extends must be a table", 2)
    end
    if type(ctx) ~= "table" then
        error("type_wiring.applyWiring: ctx must be a table", 2)
    end
    local fireOnLoad = (ctx.file ~= nil) or (ctx.badVal ~= nil) or (ctx.loadEnv ~= nil)
    local called = {}
    forEachWiredAncestor(fileType, extends, function(entry, ancestorName)
        local key = ancestorName:lower()
        if called[key] then return end
        called[key] = true
        if fireOnLoad and entry.onLoad then
            entry.onLoad(ctx.file, fileType, extends, ctx.badVal, ctx.loadEnv)
        end
        if entry.preProcessors and ctx.preProcessors then
            for _, e in ipairs(entry.preProcessors) do
                insertContribution(ctx.preProcessors, e, DEFAULT_POSITION.preProcessors)
            end
        end
        if entry.rowValidators and ctx.rowValidators then
            for _, e in ipairs(entry.rowValidators) do
                insertContribution(ctx.rowValidators, e, DEFAULT_POSITION.rowValidators)
            end
        end
        if entry.fileValidators and ctx.fileValidators then
            for _, e in ipairs(entry.fileValidators) do
                insertContribution(ctx.fileValidators, e, DEFAULT_POSITION.fileValidators)
            end
        end
    end)
end

-- True iff any ancestor of typeName (including itself) has a registered
-- onLoad. Used by files_desc.detectPostProcessingNeeded.
local function hasOnLoad(typeName, extends)
    if typeName == nil then return false end
    if type(extends) ~= "table" then return false end
    local found = false
    forEachWiredAncestor(typeName, extends, function(entry)
        if entry.onLoad then found = true end
    end)
    return found
end

--- True iff `typeName` is an engine ROLE, not a table type — a word a Files.tsv row
--- uses to say what the engine should DO with a file (`asset_file`, `patch`,
--- `bulk_patch`, `custom_type_def`, `type_wiring_def`, `SchemaOverlay`,
--- `MigrationScript`, `Type`, `enum`, `files`), as opposed to the name of the record
--- type its rows are.
---
--- The distinction matters because two checks in files_desc are about TABLE types
--- and are category errors when applied to a role: "typeName 'X' should match
--- fileName 'Y'" (a role is not named after the file — three files can all be
--- `asset_file`), and "Multiple types with name 'X'" (several files legitimately
--- share a role). Registering the role here fixes both at once, for the whole class,
--- rather than hard-coding a list of exempt names inside files_desc.
--- @param typeName string|nil
--- @return boolean
local function isRoleTypeName(typeName)
    if type(typeName) ~= "string" then return false end
    local entry = REGISTRY[typeName:lower()]
    return entry ~= nil and entry.role == true
end

-- True iff `ancestorTypeName` appears in typeName's extends chain AND there
-- is a registered onLoad for `ancestorTypeName`.
local function hasOnLoadFor(typeName, extends, ancestorTypeName)
    if typeName == nil or ancestorTypeName == nil then return false end
    if type(extends) ~= "table" then return false end
    local targetKey = ancestorTypeName:lower()
    local entry = REGISTRY[targetKey]
    if entry == nil or entry.onLoad == nil then return false end
    local current = typeName
    local seen = {}
    while current do
        if seen[current] then return false end
        seen[current] = true
        if current:lower() == targetKey then return true end
        current = extends[current]
    end
    return false
end

-- ============================================================
-- Module-level API
-- ============================================================

local function specsEqual(a, b)
    -- Equality predicate used to detect identical re-declarations of the
    -- same descriptor column. Compares name, type, fieldOnMeta, since, and
    -- relativePath; the `parse` field is opaque (function-identity equality).
    return a.name == b.name
        and a.type == b.type
        and a.fieldOnMeta == b.fieldOnMeta
        and a.parse == b.parse
        and (a.since or false) == (b.since or false)
        and (a.relativePath or false) == (b.relativePath or false)
end

local function validateColumnDecl(moduleName, decl, index)
    if type(decl) ~= "table" then
        error("type_wiring.registerModule: descriptorColumns[" .. index
            .. "] must be a table for moduleName '" .. moduleName .. "'", 3)
    end
    if type(decl.name) ~= "string" or decl.name == "" then
        error("type_wiring.registerModule: descriptorColumns[" .. index
            .. "].name must be a non-empty string for moduleName '"
            .. moduleName .. "'", 3)
    end
    if type(decl.type) ~= "string" or decl.type == "" then
        error("type_wiring.registerModule: descriptorColumns[" .. index
            .. "].type must be a non-empty string for moduleName '"
            .. moduleName .. "'", 3)
    end
    if type(decl.fieldOnMeta) ~= "string" or decl.fieldOnMeta == "" then
        error("type_wiring.registerModule: descriptorColumns[" .. index
            .. "].fieldOnMeta must be a non-empty string for moduleName '"
            .. moduleName .. "'", 3)
    end
    if decl.parse ~= nil and type(decl.parse) ~= "function" then
        error("type_wiring.registerModule: descriptorColumns[" .. index
            .. "].parse must be a function for moduleName '"
            .. moduleName .. "'", 3)
    end
    -- `relativePath` marks a column whose value is a file path matched EXACTLY
    -- against the loaded-file keys (e.g. joinInto, edgesFor). Such a value is
    -- resolved against the directory of the Files.tsv it appears in, like
    -- `fileName` — see files_desc.resolveDescriptorPath. Do NOT set it on a
    -- column resolved by basename (the override targets), which is already
    -- location-independent.
    if decl.relativePath ~= nil and type(decl.relativePath) ~= "boolean" then
        error("type_wiring.registerModule: descriptorColumns[" .. index
            .. "].relativePath must be a boolean for moduleName '"
            .. moduleName .. "'", 3)
    end
    -- `since` is the engine version that first accepted this column, and exists
    -- for ONE reason: an optional column is invisible until you already know it
    -- is there. Nothing warns about a column you have not written — that would
    -- mean a warning per unused feature per Files.tsv on every load — so a user
    -- who last touched their Files.tsv three releases ago has no way, short of
    -- reading the CHANGELOG, to learn what they could now be declaring.
    -- `--list-columns` is that way, and `since` is what lets it say WHEN each
    -- column appeared, so "what is new since I last looked?" has an answer.
    -- Omit it for a column that predates the tracking; the report simply does
    -- not annotate those.
    if decl.since ~= nil and (type(decl.since) ~= "string" or decl.since == "") then
        error("type_wiring.registerModule: descriptorColumns[" .. index
            .. "].since must be a non-empty version string for moduleName '"
            .. moduleName .. "'", 3)
    end
end

local function mergeColumnDecls(moduleName, decls, target, contributorByName)
    for i, decl in ipairs(decls) do
        validateColumnDecl(moduleName, decl, i)
        local existing = target[decl.name]
        if existing == nil then
            target[decl.name] = decl
            contributorByName[decl.name] = moduleName
        elseif specsEqual(existing, decl) then
            -- Identical re-declaration: silent merge.
        else
            error("type_wiring.registerModule: descriptorColumn '" .. decl.name
                .. "' redeclared with incompatible spec by modules '"
                .. contributorByName[decl.name] .. "' and '" .. moduleName
                .. "'", 3)
        end
    end
end

local function mergeSandboxHelpers(moduleName, helpers, target, contributorByName)
    local function mergeBucket(bucketName, source)
        if source == nil then return end
        if type(source) ~= "table" then
            error("type_wiring.registerModule: sandboxHelpers."
                .. bucketName .. " must be a table for moduleName '"
                .. moduleName .. "'", 4)
        end
        target[bucketName] = target[bucketName] or {}
        for name, fn in pairs(source) do
            if type(name) ~= "string" or name == "" then
                error("type_wiring.registerModule: sandboxHelpers."
                    .. bucketName .. " keys must be non-empty strings for moduleName '"
                    .. moduleName .. "'", 4)
            end
            if type(fn) ~= "function" then
                error("type_wiring.registerModule: sandboxHelpers."
                    .. bucketName .. "." .. name
                    .. " must be a function for moduleName '"
                    .. moduleName .. "'", 4)
            end
            local key = bucketName .. ":" .. name
            local existingFn = target[bucketName][name]
            if existingFn == nil then
                target[bucketName][name] = fn
                contributorByName[key] = moduleName
            elseif existingFn ~= fn then
                error("type_wiring.registerModule: sandboxHelper '"
                    .. bucketName .. "." .. name
                    .. "' redeclared with a different function by modules '"
                    .. contributorByName[key] .. "' and '" .. moduleName .. "'", 4)
            end
        end
    end
    mergeBucket("processor", helpers.processor)
    mergeBucket("validator", helpers.validator)
    -- "both" is sugar: helpers in both processor and validator envs.
    if helpers.both then
        mergeBucket("processor", helpers.both)
        mergeBucket("validator", helpers.both)
    end
end

local function registerModule(moduleName, declarations)
    if type(moduleName) ~= "string" or moduleName == "" then
        error("type_wiring.registerModule: moduleName must be a non-empty string", 2)
    end
    if type(declarations) ~= "table" then
        error("type_wiring.registerModule: declarations must be a table for moduleName '"
            .. moduleName .. "'", 2)
    end
    for k in pairs(declarations) do
        if PER_TYPE_KEYS[k] then
            error("type_wiring.registerModule: '" .. k
                .. "' is a per-typeName slot — use register instead (moduleName '"
                .. moduleName .. "')", 2)
        end
        if not MODULE_KEYS[k] then
            error("type_wiring.registerModule: unknown declaration key '" .. tostring(k)
                .. "' for moduleName '" .. moduleName .. "'", 2)
        end
    end

    local mod = MODULES[moduleName]
    if mod == nil then
        mod = {
            moduleName = moduleName,
            descriptorColumns = {},
            sandboxHelpers = {},
            enginePostPasses = {},
        }
        MODULES[moduleName] = mod
        MODULE_ORDER[#MODULE_ORDER + 1] = moduleName
    end

    if declarations.descriptorColumns ~= nil then
        if type(declarations.descriptorColumns) ~= "table" then
            error("type_wiring.registerModule: descriptorColumns must be a list for moduleName '"
                .. moduleName .. "'", 2)
        end
        for i, decl in ipairs(declarations.descriptorColumns) do
            validateColumnDecl(moduleName, decl, i)
            mod.descriptorColumns[#mod.descriptorColumns + 1] = decl
        end
        logger:info(moduleName .. ": registered " .. #declarations.descriptorColumns
            .. " descriptor column(s)")
    end

    if declarations.sandboxHelpers ~= nil then
        if type(declarations.sandboxHelpers) ~= "table" then
            error("type_wiring.registerModule: sandboxHelpers must be a table for moduleName '"
                .. moduleName .. "'", 2)
        end
        -- Stash a reference (we re-validate at aggregate time so collision
        -- errors name both contributors via the aggregate path).
        mod.sandboxHelpers[#mod.sandboxHelpers + 1] = declarations.sandboxHelpers
    end

    if declarations.enginePostPasses ~= nil then
        if type(declarations.enginePostPasses) ~= "table" then
            error("type_wiring.registerModule: enginePostPasses must be a list for moduleName '"
                .. moduleName .. "'", 2)
        end
        for i, fn in ipairs(declarations.enginePostPasses) do
            if type(fn) ~= "function" then
                error("type_wiring.registerModule: enginePostPasses[" .. i
                    .. "] must be a function for moduleName '"
                    .. moduleName .. "'", 2)
            end
            mod.enginePostPasses[#mod.enginePostPasses + 1] = fn
        end
    end

    invalidateCache()
end

-- Stable list of keys (used by buildDescriptorColumnsCache for
-- determinism — natural pairs() iteration order isn't guaranteed).
local function sortedKeys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

local function buildDescriptorColumnsCache()
    local target = {}
    local contributorByName = {}
    -- Iterate in registration order (deterministic).
    for _, moduleName in ipairs(MODULE_ORDER) do
        local mod = MODULES[moduleName]
        if mod and #mod.descriptorColumns > 0 then
            mergeColumnDecls(moduleName, mod.descriptorColumns, target, contributorByName)
        end
    end
    -- Stable ordered list for callers that want array iteration.
    local ordered = {}
    for _, name in ipairs(sortedKeys(target)) do
        ordered[#ordered + 1] = target[name]
    end
    CACHE.descriptorColumns = ordered
    CACHE.descriptorColumnsByName = target
end

-- Returns the merged descriptor-column declarations as an array.
-- Identical re-declarations across modules are silently merged; conflicting
-- re-declarations raise an error at this point (deferred from registerModule
-- so the error message can name both contributors).
local function descriptorColumns()
    if CACHE.descriptorColumns == nil then
        buildDescriptorColumnsCache()
    end
    return CACHE.descriptorColumns
end

-- Returns a map name → declaration, for O(1) lookups by column name.
local function descriptorColumnsByName()
    if CACHE.descriptorColumnsByName == nil then
        buildDescriptorColumnsCache()
    end
    return CACHE.descriptorColumnsByName
end

local function buildSandboxAdditionsCache()
    local target = {processor = {}, validator = {}}
    local contributorByName = {}
    for _, moduleName in ipairs(MODULE_ORDER) do
        local mod = MODULES[moduleName]
        if mod then
            for _, helpers in ipairs(mod.sandboxHelpers) do
                mergeSandboxHelpers(moduleName, helpers, target, contributorByName)
            end
        end
    end
    CACHE.sandboxAdditions = target
end

-- Returns the merged sandbox helper additions:
--   { processor = {[name]=fn, ...}, validator = {[name]=fn, ...} }
-- processor_executor / validator_executor merge these into their helper
-- blocks at engine init. Name collisions across modules are an error;
-- the merged result is cached.
local function sandboxAdditions()
    if CACHE.sandboxAdditions == nil then
        buildSandboxAdditionsCache()
    end
    return CACHE.sandboxAdditions
end

local function buildEnginePostPassesCache()
    local ordered = {}
    local seen = {}
    -- Walk modules in registration order; within a module, append in the
    -- order callbacks were registered. Function-identity dedup so a
    -- callback registered under more than one moduleName runs once.
    for _, moduleName in ipairs(MODULE_ORDER) do
        local mod = MODULES[moduleName]
        if mod then
            for _, fn in ipairs(mod.enginePostPasses) do
                if not seen[fn] then
                    seen[fn] = true
                    ordered[#ordered + 1] = fn
                end
            end
        end
    end
    CACHE.enginePostPasses = ordered
end

-- Runs every registered engine post-pass against (tsv_files, joinMeta, badVal).
-- Each callback returns true on success, false on any reported error
-- (errors via badVal, not raised). Returns the aggregate result — true
-- iff every pass returned truthy.
local function runEnginePostPasses(tsv_files, joinMeta, badVal)
    if CACHE.enginePostPasses == nil then
        buildEnginePostPassesCache()
    end
    local ok = true
    for _, fn in ipairs(CACHE.enginePostPasses) do
        local result = fn(tsv_files, joinMeta, badVal)
        if not result then ok = false end
    end
    return ok
end

-- ============================================================
-- Bootstrap API (Phase 3 — user packages reach the registry)
-- ============================================================

-- Returns (api, seal) — a frozen api table whose `register` /
-- `registerModule` entries proxy onto the registry, plus a `seal()`
-- closure that flips a shared `sealed` flag. The proxies check the flag
-- at call time, not lookup time, so a bootstrap that captures
-- `api.register` into library state and calls it later errors at the
-- delayed call rather than silently no-op'ing.
--
-- Used by manifest_loader to dispatch the `bootstrap` manifest field
-- and to drive `TypeWiring.tsv` row registration. The engine creates
-- ONE (api, seal) pair per processFiles call and invokes seal() after
-- the bootstrap phase finishes (after every bootstrap returns AND
-- every TypeWiring.tsv row has been processed).
local function makeBootstrapAPI()
    local sealed = false

    local function checkSealed(opName)
        if sealed then
            error("type_wiring." .. opName
                .. ": bootstrap phase has ended; the api can no longer be used", 2)
        end
    end

    local api = readOnly({
        register = function(typeName, contributions)
            checkSealed("register")
            return register(typeName, contributions)
        end,
        registerModule = function(moduleName, declarations)
            checkSealed("registerModule")
            return registerModule(moduleName, declarations)
        end,
    })

    local function seal()
        sealed = true
    end

    return api, seal
end

-- ============================================================
-- Snapshot / restore (for global_reset)
-- ============================================================

local function snapshotState()
    local r = {}
    for k, v in pairs(REGISTRY) do r[k] = v end
    REGISTRY_SNAPSHOT = r

    local m = {}
    for k, v in pairs(MODULES) do m[k] = v end
    MODULES_SNAPSHOT = m

    local o = {}
    for i, name in ipairs(MODULE_ORDER) do o[i] = name end
    MODULE_ORDER_SNAPSHOT = o
end

local function restoreState()
    for k in pairs(REGISTRY) do REGISTRY[k] = nil end
    if REGISTRY_SNAPSHOT then
        for k, v in pairs(REGISTRY_SNAPSHOT) do REGISTRY[k] = v end
    end
    for k in pairs(MODULES) do MODULES[k] = nil end
    if MODULES_SNAPSHOT then
        for k, v in pairs(MODULES_SNAPSHOT) do MODULES[k] = v end
    end
    for i in ipairs(MODULE_ORDER) do MODULE_ORDER[i] = nil end
    if MODULE_ORDER_SNAPSHOT then
        for i, name in ipairs(MODULE_ORDER_SNAPSHOT) do MODULE_ORDER[i] = name end
    end
    invalidateCache()
end

-- Test/debug accessors (not part of the documented surface).
local function _getRegisteredTypes()
    local out = {}
    for _, entry in pairs(REGISTRY) do
        out[#out + 1] = entry.typeName
    end
    table.sort(out)
    return out
end

local function _getRegisteredModules()
    local out = {}
    for _, name in ipairs(MODULE_ORDER) do out[#out + 1] = name end
    return out
end

-- ============================================================
-- Public API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    register = register,
    registerModule = registerModule,
    applyWiring = applyWiring,
    hasOnLoad = hasOnLoad,
    hasOnLoadFor = hasOnLoadFor,
    isRoleTypeName = isRoleTypeName,
    descriptorColumns = descriptorColumns,
    descriptorColumnsByName = descriptorColumnsByName,
    sandboxAdditions = sandboxAdditions,
    runEnginePostPasses = runEnginePostPasses,
    makeBootstrapAPI = makeBootstrapAPI,
    snapshotState = snapshotState,
    restoreState = restoreState,
    _getRegisteredTypes = _getRegisteredTypes,
    _getRegisteredModules = _getRegisteredModules,
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
