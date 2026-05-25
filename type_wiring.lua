-- Module name
local NAME = "type_wiring"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 20, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local logger = require("named_logger").getLogger(NAME)

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- Type-wiring registry (Phase 1, see TODO/type_wiring.md)
--
-- Per-typeName contributions, keyed by lowercased typeName. Each entry
-- is a table of optional contribution slots.
--
-- Phase 1 supports a single slot:
--   onLoad: function(file, fileType, extends, badVal, loadEnv)
--     Called during the per-file load loop *before subsequent files
--     parse*, so the handler can register parsers/aliases/types that
--     later files refer to.
--
-- Later phases will add preProcessors / rowValidators / fileValidators
-- (per-typeName) and a separate registerModule API for engine-init slots
-- (descriptorColumns, sandboxHelpers, enginePostPasses).
-- ============================================================

local REGISTRY = {}

-- Snapshot for global_reset restore. Populated by snapshotState() once
-- the built-in wirings have been registered (see builtin_wiring.lua).
local SNAPSHOT = nil

-- The contribution keys recognised in Phase 1. Unknown keys produce a
-- registration-time error so a typo (e.g. `OnLoad`) isn't silently dropped.
local KNOWN_KEYS = {onLoad = true}

-- Registers a contribution bundle for `typeName`. A subsequent
-- applyWiring(file, fileType, extends, ...) walks the file's extends chain
-- and fires each registered ancestor's contributions.
--
-- Re-registering an identical onLoad for the same typeName is a silent
-- no-op (idempotent). Registering a *different* onLoad for a typeName
-- that already has one is a registration-time error so two modules can't
-- silently shadow each other.
local function register(typeName, contributions)
    if type(typeName) ~= "string" or typeName == "" then
        error("type_wiring.register: typeName must be a non-empty string", 2)
    end
    if type(contributions) ~= "table" then
        error("type_wiring.register: contributions must be a table for typeName '"
            .. typeName .. "'", 2)
    end
    for k in pairs(contributions) do
        if not KNOWN_KEYS[k] then
            error("type_wiring.register: unknown contribution key '" .. tostring(k)
                .. "' for typeName '" .. typeName .. "'", 2)
        end
    end
    local onLoad = contributions.onLoad
    if onLoad ~= nil and type(onLoad) ~= "function" then
        error("type_wiring.register: onLoad must be a function for typeName '"
            .. typeName .. "'", 2)
    end
    local key = typeName:lower()
    local entry = REGISTRY[key]
    if entry == nil then
        entry = {typeName = typeName}
        REGISTRY[key] = entry
    end
    if onLoad ~= nil then
        if entry.onLoad ~= nil and entry.onLoad ~= onLoad then
            error("type_wiring.register: onLoad for typeName '" .. typeName
                .. "' already registered with a different function", 2)
        end
        entry.onLoad = onLoad
        logger:info("Registered onLoad wiring for " .. typeName)
    end
end

-- Walks the extends chain starting at typeName, calling visit(entry, ancestorName)
-- for each ancestor that has a registry entry. Shallowest-first. A cycle in
-- `extends` terminates the walk silently (the Files.tsv parser reports cycles
-- separately).
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

-- Phase 1 dispatch: walks fileType's extends chain and fires each registered
-- ancestor's onLoad exactly once per call (shallowest first).
--
-- The onLoad receives (file, fileType, extends, badVal, loadEnv). It is
-- responsible for its own re-entry safety (e.g., parsers.registerAlias
-- already detects duplicate registrations) — the dispatcher does not
-- enforce idempotency at the callback level because it can't compare
-- side effects.
local function applyWiring(file, fileType, extends, badVal, loadEnv)
    if fileType == nil then return end
    if type(extends) ~= "table" then
        error("type_wiring.applyWiring: extends must be a table", 2)
    end
    local called = {}
    forEachWiredAncestor(fileType, extends, function(entry, ancestorName)
        if entry.onLoad then
            local key = ancestorName:lower()
            if not called[key] then
                called[key] = true
                entry.onLoad(file, fileType, extends, badVal, loadEnv)
            end
        end
    end)
end

-- True iff any ancestor of typeName (including itself) has a registered
-- onLoad. Used by files_desc.detectPostProcessingNeeded to decide whether
-- a file requires the second descriptor pass (so newly-registered types
-- become visible to siblings in the same package).
local function hasOnLoad(typeName, extends)
    if typeName == nil then return false end
    if type(extends) ~= "table" then return false end
    local found = false
    forEachWiredAncestor(typeName, extends, function(entry)
        if entry.onLoad then found = true end
    end)
    return found
end

-- True iff `ancestorTypeName` appears in typeName's extends chain AND there
-- is a registered onLoad for `ancestorTypeName`. Used by registerFileType
-- in manifest_loader to skip files whose record-type registration is owned
-- by a wired onLoad (Type / enum), so the loader doesn't double-register
-- the file's column-shape as an alias.
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

-- Snapshots the current registry. Called once by builtin_wiring after all
-- built-in registrations are in place. restoreState() reverts the registry
-- to this snapshot, which is what global_reset.reset() invokes between
-- test runs that mutate the registry.
local function snapshotState()
    local s = {}
    for k, v in pairs(REGISTRY) do
        s[k] = v
    end
    SNAPSHOT = s
end

-- Restores the registry to the most recent snapshot (cleared if no snapshot
-- has been taken yet). Wired via global_reset by builtin_wiring.
local function restoreState()
    for k in pairs(REGISTRY) do REGISTRY[k] = nil end
    if SNAPSHOT then
        for k, v in pairs(SNAPSHOT) do REGISTRY[k] = v end
    end
end

-- Test/debug accessor: list the typeNames that currently have a registry
-- entry, sorted alphabetically. Not part of the documented surface.
local function _getRegisteredTypes()
    local out = {}
    for _, entry in pairs(REGISTRY) do
        out[#out + 1] = entry.typeName
    end
    table.sort(out)
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
    applyWiring = applyWiring,
    hasOnLoad = hasOnLoad,
    hasOnLoadFor = hasOnLoadFor,
    snapshotState = snapshotState,
    restoreState = restoreState,
    _getRegisteredTypes = _getRegisteredTypes,
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
