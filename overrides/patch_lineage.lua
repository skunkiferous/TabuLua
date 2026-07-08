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
-- `--explain-patch` can answer "why does sword.price equal 150?" and
-- `--check-conflicts` can answer "where do my mods fight?". The collector is
-- dumb: each override write path (schema overlays, row patches incl. list/map
-- deltas, bulk patches, package-scoped pre-processors) calls one of `cell` / `row`
-- / `schema` with a preformatted `action` string and the responsible `source`
-- (the patch/overlay file basename, or `package:<id>`). Events are stored in apply
-- order, so a cell written by two mods keeps both entries — the chain,
-- last-writer-last.
--
-- A lineage object is threaded through the override write paths only when there is
-- override work (the after-patch `=expr` recompute reads its directly-set cells)
-- or when `--explain-patch` / `--check-conflicts` is requested; otherwise the
-- write paths skip recording
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

-- True iff `action` rewrites the whole slot: a later such write from a
-- different source silently discards that source's work (last-writer-wins).
-- Delta actions (append / prepend / remove / replace old -> new) compose in
-- load order and are never flagged as conflicts.
local function isWholeWrite(action)
    return action:sub(1, 2) == "= " or action:sub(1, 14) == "replace_whole "
end

--- Scans the recorded events for override conflicts — slots where one mod's
--- write discards another's — and renders them as apply-order chains (the same
--- chain format as `report`, filtered to the fights). Flagged:
---   * a cell whose whole value is rewritten (`= v` / `replace_whole`) after a
---     DIFFERENT source already wrote that cell;
---   * a row removed or replaced while another source also wrote to it (in
---     either order — a later remove discards the writes, a later write
---     resurrects/reshapes what the remover deleted);
---   * a column default set by two or more overlay sources (`newDefault` is
---     last-writer-wins).
--- Deliberately NOT flagged (benign composition): list/map deltas from several
--- mods, `widenTo` (order-independent union), validator suppressions
--- (order-independent minimum), and a mod patching cells of a row another mod
--- ADDED (that is mod-on-mod layering, not a fight). A row whose remove/replace
--- tension is reported is not additionally reported cell-by-cell.
--- Conflicts are legal by design — load order decides — so this is a
--- diagnostic, not a gate.
--- @return string The report text
--- @return number The number of conflicting slots found
function Lineage:conflictReport()
    -- Group events by target -> (schema slots by column, pk groups with
    -- per-column cell slots), preserving first-seen order throughout so the
    -- output is deterministic and follows apply order.
    local targets, tOrder = {}, {}
    for _, e in ipairs(self.events) do
        local t = targets[e.target]
        if not t then
            t = {schema = {}, schemaOrder = {}, pks = {}, pkOrder = {}}
            targets[e.target] = t
            tOrder[#tOrder + 1] = e.target
        end
        if e.kind == "schema" then
            local s = t.schema[e.col]
            if not s then s = {}; t.schema[e.col] = s; t.schemaOrder[#t.schemaOrder + 1] = e.col end
            s[#s + 1] = e
        else
            local p = t.pks[e.pk]
            if not p then
                p = {events = {}, cells = {}, cellOrder = {}}
                t.pks[e.pk] = p
                t.pkOrder[#t.pkOrder + 1] = e.pk
            end
            p.events[#p.events + 1] = e
            if e.kind == "cell" then
                local c = p.cells[e.col]
                if not c then c = {}; p.cells[e.col] = c; p.cellOrder[#p.cellOrder + 1] = e.col end
                c[#c + 1] = e
            end
        end
    end

    -- A cell slot fights when a whole-value write lands after an event from a
    -- different source (that source's work is silently discarded).
    local function cellConflict(evs)
        local seen, n = {}, 0
        for _, e in ipairs(evs) do
            if isWholeWrite(e.action) and (n > 1 or (n == 1 and not seen[e.source])) then
                return true
            end
            if not seen[e.source] then seen[e.source] = true; n = n + 1 end
        end
        return false
    end

    -- A schema slot fights only on multi-source newDefault (last-writer-wins);
    -- widenTo unions and suppressions compose. Returns the newDefault chain
    -- when conflicting, nil otherwise.
    local function schemaConflict(evs)
        local chain, seen, n = {}, {}, 0
        for _, e in ipairs(evs) do
            if e.action:sub(1, 11) == "newDefault " then
                chain[#chain + 1] = e
                if not seen[e.source] then seen[e.source] = true; n = n + 1 end
            end
        end
        if n >= 2 then return chain end
        return nil
    end

    -- Row-level tension: the row was removed or replaced, and 2+ distinct
    -- sources touched the row at all.
    local function rowTension(p)
        local kill = false
        local seen, n = {}, 0
        for _, e in ipairs(p.events) do
            if e.kind == "row" and (e.action == "remove" or e.action == "replace") then
                kill = true
            end
            if not seen[e.source] then seen[e.source] = true; n = n + 1 end
        end
        return kill and n >= 2
    end

    local out = {}
    local function emit(s) out[#out + 1] = s end
    emit("=== Override conflicts ===")
    local count = 0
    for _, target in ipairs(tOrder) do
        local t = targets[target]
        local lines = {}
        for _, col in ipairs(t.schemaOrder) do
            local chain = schemaConflict(t.schema[col])
            if chain then
                count = count + 1
                lines[#lines + 1] = "  [schema] " .. col .. "  -- multiple defaults, last wins"
                for _, e in ipairs(chain) do
                    lines[#lines + 1] = string.format("    %s   <- %s", e.action, e.source)
                end
            end
        end
        for _, pk in ipairs(t.pkOrder) do
            local p = t.pks[pk]
            if rowTension(p) then
                -- Print the row's full chain (row + cell events, apply order);
                -- its cell slots are subsumed and not reported again below.
                count = count + 1
                lines[#lines + 1] = "  " .. pk .. "  -- row remove/replace vs. other writes"
                for _, e in ipairs(p.events) do
                    if e.kind == "row" then
                        lines[#lines + 1] = string.format("    [%s]   <- %s", e.action, e.source)
                    else
                        lines[#lines + 1] = string.format("    %s %s   <- %s", e.col, e.action, e.source)
                    end
                end
            else
                for _, col in ipairs(p.cellOrder) do
                    local evs = p.cells[col]
                    if cellConflict(evs) then
                        count = count + 1
                        lines[#lines + 1] = "  " .. pk .. " : " .. col .. "  -- multiple writers, last wins"
                        for _, e in ipairs(evs) do
                            lines[#lines + 1] = string.format("    %s   <- %s", e.action, e.source)
                        end
                    end
                end
            end
        end
        if #lines > 0 then
            emit("")
            emit(target)
            for _, l in ipairs(lines) do emit(l) end
        end
    end
    if count == 0 then
        emit("")
        emit("(no conflicts detected)")
    else
        emit("")
        emit(count .. " conflicting slot(s). Conflicts are legal; load order decides"
            .. " the winner (input-root order, dependencies, load_after).")
    end
    return table.concat(out, "\n"), count
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
