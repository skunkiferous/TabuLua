-- Module name
local NAME = "patch_lineage"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 1, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

-- ============================================================
-- Patch lineage.
--
-- A record of which mod override touched which cell / row / column, so
-- `--explain-patch` can answer "why does sword.price equal 150?". The collector is
-- dumb: each override write path (schema overlays, row patches incl. list/map
-- deltas, bulk patches, package-scoped pre-processors) calls one of `cell` / `row`
-- / `schema` with a preformatted `action` string and the responsible `source`
-- (the patch/overlay file basename, or `package:<id>`). Events are stored in apply
-- order, so a cell written by two mods keeps both entries — the chain,
-- last-writer-last.
--
-- A lineage object is threaded through the override write paths only when there is
-- override work (the after-patch `=expr` recompute reads its directly-set cells)
-- or when `--explain-patch` is requested; otherwise the write paths skip recording
-- entirely, so a plain non-mod load pays nothing.
-- ============================================================

--- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- Renders a parsed value compactly for a lineage line (lists as `{a,b}`, maps as
-- `{k=v}`, scalars as themselves). Used by callers to build `action` strings.
local function valueStr(v)
    local t = type(v)
    if v == nil then
        return "nil"
    elseif t == "string" then
        return v
    elseif t ~= "table" then
        return tostring(v)
    end
    -- table: array vs map
    local parts = {}
    local isArray = true
    for k in pairs(v) do
        if type(k) ~= "number" then isArray = false break end
    end
    if isArray then
        for _, e in ipairs(v) do parts[#parts + 1] = valueStr(e) end
    else
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = tostring(k) .. "=" .. valueStr(v[k])
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local Lineage = {}
Lineage.__index = Lineage

--- Records an override of one cell.
--- @param target string Target file basename (e.g. "item.tsv")
--- @param pk string Primary key of the affected row (tostring'd)
--- @param col string Column name
--- @param action string Human-readable change (e.g. "= -5", "append {clearance}")
--- @param source string Who made the change (patch/overlay file, or package:<id>)
function Lineage:cell(target, pk, col, action, source)
    self.events[#self.events + 1] =
        {kind = "cell", target = target, pk = pk, col = col, action = action, source = source}
end

--- Records a row-level override (add / remove / replace).
function Lineage:row(target, pk, action, source)
    self.events[#self.events + 1] =
        {kind = "row", target = target, pk = pk, action = action, source = source}
end

--- Records a schema-overlay effect on a column (widenTo / newDefault / suppressValidator).
function Lineage:schema(target, col, action, source)
    self.events[#self.events + 1] =
        {kind = "schema", target = target, col = col, action = action, source = source}
end

--- True if nothing was recorded.
function Lineage:isEmpty()
    return #self.events == 0
end

--- Returns the set of cells a patch / processor wrote DIRECTLY, as a nested map
--- `target -> pk -> column -> true`, built from the recorded `cell` events. Used
--- by the after-patch `=expr` recompute to (a) find which rows changed
--- and (b) avoid clobbering a cell an override set explicitly. Row add/remove/
--- replace and schema events are excluded — an added/replaced row is built whole
--- (already consistent) and schema effects are column metadata, not cell writes.
--- @return table target -> pk -> column -> true
function Lineage:dirtyCells()
    local m = {}
    for _, e in ipairs(self.events) do
        if e.kind == "cell" then
            local t = m[e.target]; if not t then t = {}; m[e.target] = t end
            local r = t[e.pk]; if not r then r = {}; t[e.pk] = r end
            r[e.col] = true
        end
    end
    return m
end

--- Renders the recorded lineage as a human-readable report, optionally filtered.
--- @param filter table|nil {file=<basename, lowercased>, pk=<str>, col=<str>} —
---   any field nil means "no filter on that axis".
--- @return string The report text
function Lineage:report(filter)
    filter = filter or {}
    local out = {}
    local function emit(s) out[#out + 1] = s end

    -- Targets in first-seen order.
    local seen, targets = {}, {}
    for _, e in ipairs(self.events) do
        if not seen[e.target] then seen[e.target] = true; targets[#targets + 1] = e.target end
    end

    emit("=== Patch lineage ===")
    local any = false
    for _, target in ipairs(targets) do
        if not filter.file or filter.file == target then
            local schema, pkOrder, byPk = {}, {}, {}
            for _, e in ipairs(self.events) do
                if e.target == target then
                    if e.kind == "schema" then
                        if not filter.pk and (not filter.col or filter.col == e.col) then
                            schema[#schema + 1] = e
                        end
                    elseif (not filter.pk or filter.pk == e.pk)
                        and (not filter.col or e.kind == "row" or filter.col == e.col) then
                        if not byPk[e.pk] then byPk[e.pk] = {}; pkOrder[#pkOrder + 1] = e.pk end
                        byPk[e.pk][#byPk[e.pk] + 1] = e
                    end
                end
            end
            if #schema > 0 or #pkOrder > 0 then
                any = true
                emit("")
                emit(target)
                for _, e in ipairs(schema) do
                    emit(string.format("  [schema] %s  %s   <- %s", e.col, e.action, e.source))
                end
                for _, pk in ipairs(pkOrder) do
                    emit("  " .. pk)
                    for _, e in ipairs(byPk[pk]) do
                        if e.kind == "row" then
                            emit(string.format("    [%s]   <- %s", e.action, e.source))
                        else
                            emit(string.format("    %s %s   <- %s", e.col, e.action, e.source))
                        end
                    end
                end
            end
        end
    end
    if not any then
        local what = filter.file or ""
        if filter.file and filter.pk then what = what .. ":" .. filter.pk end
        if filter.file and filter.col then what = what .. ":" .. filter.col end
        emit("")
        emit("(no overrides recorded" .. (what ~= "" and (" for " .. what) or "") .. ")")
    end
    return table.concat(out, "\n")
end

--- Creates a fresh, empty lineage collector.
local function new()
    return setmetatable({events = {}}, Lineage)
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    new = new,
    valueStr = valueStr,
}

-- Enables the module to be called as a function
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
