-- Module name
local NAME = "schema_overlay"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 32, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

local logger = require("infra.named_logger").getLogger(NAME)

local parsers = require("parsers")
local parseType = parsers.parseType
local unionTypes = parsers.unionTypes
local extendsOrRestrict = parsers.extendsOrRestrict

local tsv_model = require("tsv.tsv_model")
local processTSV = tsv_model.processTSV
local defaultOptionsExtractor = tsv_model.defaultOptionsExtractor

local raw_tsv = require("tsv.raw_tsv")
local stringToRawTSV = raw_tsv.stringToRawTSV

local content_pipeline = require("content.content_pipeline")

local validator_executor = require("wiring.validator_executor")
local normalizeValidatorSpec = validator_executor.normalizeValidatorSpec

-- ============================================================
-- Schema overlay.
--
-- A child package may declare a SchemaOverlay file targeting a parent file
-- (by basename, via the schemaOverlayOf descriptor column). Each overlay row
-- loosens — never tightens — the target file's column metadata:
--
--   newDefault         override a column's default value (literal or =expr)
--   widenTo            replace a column's type with a strictly wider one
--   suppressValidator  match a parent validator by its expression text and
--   validatorLevel     downgrade its severity (warn) or remove it (none)
--
-- The newDefault / widenTo changes must take effect *before* the target
-- file's cells are parsed, so collectOverlays runs as a pre-parse pass and
-- the resulting per-column overrides are threaded into tsv_model.processTSV.
-- The validator-severity changes operate on the per-file validator lists,
-- which only exist after the load loop, so applyValidatorOverrides runs just
-- before validation.
-- ============================================================

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- Severity ordering for suppressValidator composition: the lowest severity
-- across all overlays targeting one validator wins. `none` removes
-- the validator entirely.
local SEVERITY = {none = 0, warn = 1, error = 2}

-- Lowercased basename of a path/key (strips any directory prefix).
local function basename(key)
    return (key:match("[/\\]([^/\\]+)$") or key):lower()
end

-- Case-preserving basename, for lineage source display.
local function dispName(key)
    return key and (key:match("[/\\]([^/\\]+)$") or key) or ""
end

-- Lineage source display: the overlay file's basename, prefixed with the
-- owning package id when known ("ModA:PricePolicy.tsv") — so two mods
-- shipping same-named overlay files stay distinguishable in reports.
local function srcName(fn, opt_fn2pkg)
    local pkg = fn and opt_fn2pkg and opt_fn2pkg[fn]
    local base = dispName(fn)
    return pkg and (pkg .. ":" .. base) or base
end

-- Reads a cell's parsed value (falling back to evaluated) by column name.
-- Returns nil when the column is absent from this overlay file's header
-- (overlay headers may be any subset of the SchemaOverlay columns).
local function cellValue(row, colName)
    local cell = row[colName]
    if type(cell) ~= "table" then return nil end
    local v = cell.parsed
    if v == nil then v = cell.evaluated end
    return v
end

-- Merges two type specs into their union, deduplicating members. Used for
-- the order-independent widenTo composition when multiple overlays widen the
-- same column: widening to `gold|int` and `gold|float` yields
-- `gold|int|float`.
local function mergeUnion(a, b)
    if not a or a == "" then return b end
    if not b or b == "" then return a end
    if a == b then return a end
    local seen, out = {}, {}
    local function add(spec)
        local members = unionTypes(spec)
        if not members then members = {spec} end
        for _, m in ipairs(members) do
            if not seen[m] then
                seen[m] = true
                out[#out + 1] = m
            end
        end
    end
    add(a)
    add(b)
    return table.concat(out, "|")
end

-- Parses one overlay file and folds its rows into `overlays`. The file is
-- read through the content pipeline (so a .gz / transcoded overlay decodes
-- like any data file) and parsed as a generic typed TSV — the SchemaOverlay
-- record alias only marks the typeName as known; the per-column types come
-- from the file's own header.
local function ingestOverlayFile(overlays, file_name, targetBasename, transcoder,
    raw_files, loadEnv, expr_eval, badVal)
    local ctx = {transcoder = transcoder, typeName = "SchemaOverlay"}
    local content = content_pipeline.readAndRun(file_name, loadEnv, badVal, raw_files, ctx)
    if not content then
        return
    end
    local rawtsv = stringToRawTSV(content)
    local file = processTSV(defaultOptionsExtractor, expr_eval, parseType,
        file_name, rawtsv, badVal, nil, false)
    if not file then
        return
    end

    local tgt = overlays[targetBasename]
    if tgt == nil then
        tgt = {columns = {}, validators = {}, sources = {}}
        overlays[targetBasename] = tgt
    end
    tgt.sources[#tgt.sources + 1] = file_name

    for i, row in ipairs(file) do
        if i > 1 and type(row) == "table" then
            local column = cellValue(row, "column")
            local newDefault = cellValue(row, "newDefault")
            local widenTo = cellValue(row, "widenTo")
            local suppress = cellValue(row, "suppressValidator")
            local level = cellValue(row, "validatorLevel")

            -- Column-targeting operations (newDefault / widenTo).
            if column and column ~= "" and
                ((newDefault ~= nil and newDefault ~= "")
                    or (widenTo ~= nil and widenTo ~= "")) then
                local entry = tgt.columns[column]
                if entry == nil then
                    entry = {}
                    tgt.columns[column] = entry
                end
                -- newDefault: later overlay (in load order) wins. The full
                -- per-source history is kept so lineage shows the overwritten
                -- defaults too (--check-conflicts flags multi-source defaults).
                if newDefault ~= nil and newDefault ~= "" then
                    entry.newDefault = newDefault
                    entry.newDefaultSrc = file_name   -- for --explain-patch lineage
                    local hist = entry.newDefaultHist
                    if not hist then hist = {}; entry.newDefaultHist = hist end
                    hist[#hist + 1] = {value = newDefault, src = file_name}
                end
                -- widenTo: order-independent union of every declared widening.
                if widenTo ~= nil and widenTo ~= "" then
                    entry.widenTo = mergeUnion(entry.widenTo, widenTo)
                    entry.widenToSrc = file_name      -- last widener (lineage display)
                end
            end

            -- Validator-targeting operation (suppressValidator + validatorLevel).
            -- Matched purely by the validator's expression text; the row's
            -- `column` cell is contextual only.
            if suppress ~= nil and suppress ~= "" then
                local lvl = level
                if lvl == nil or lvl == "" then
                    lvl = "warn"
                    logger:info(NAME .. ": suppressValidator with no validatorLevel in "
                        .. file_name .. "; defaulting to 'warn'")
                end
                local existing = tgt.validators[suppress]
                if existing == nil or SEVERITY[lvl] < SEVERITY[existing] then
                    tgt.validators[suppress] = lvl
                end
            end
        end
    end
end

-- Collects every schema overlay declared across the loaded files into a map
-- keyed by the lowercased basename of the *target* parent file:
--
--   overlays[targetBasename] = {
--     columns    = { [colName] = {newDefault=?, widenTo=?} },
--     validators = { [suppressExpr] = "error"|"warn"|"none" },
--     sources    = { overlayFileName, ... },
--   }
--
-- `overlayFiles` must already be ordered by package load order (so the
-- last-writer-wins rule for newDefault is correct). `computeKey` maps a
-- collected file_name to its lowercased relative key, matching how the
-- descriptor maps are keyed.
local function collectOverlays(overlayFiles, file2dir, computeKey,
    lcFn2SchemaOverlayOf, lcFn2Transcoder, raw_files, loadEnv, badVal,
    opt_resolveTarget)
    local overlays = {}
    if not overlayFiles or #overlayFiles == 0 then
        return overlays
    end
    lcFn2Transcoder = lcFn2Transcoder or {}
    local expr_eval = tsv_model.expressionEvaluatorGenerator(loadEnv)
    for _, file_name in ipairs(overlayFiles) do
        local key = computeKey(file_name, file2dir)
        local target = lcFn2SchemaOverlayOf[key]
        if target then
            badVal.source = file_name
            -- With a resolver (the engine path), the target — optionally
            -- 'package.id:'-qualified — resolves to the ONE relative file key
            -- it applies to, so same-basename files in two packages are no
            -- longer both overlaid; nil means the resolver already reported
            -- an error and this overlay file is skipped. Without a resolver
            -- (direct API use), fall back to keying by bare basename, the
            -- pre-qualification behaviour.
            local resolvedKey
            if opt_resolveTarget then
                resolvedKey = opt_resolveTarget(target, file_name)
            else
                resolvedKey = basename(target)
            end
            if resolvedKey then
                ingestOverlayFile(overlays, file_name, resolvedKey,
                    lcFn2Transcoder[key], raw_files, loadEnv, expr_eval, badVal)
            end
        end
    end
    return overlays
end

-- Returns the per-column override map for a target file, in the
-- {colName = {widenTo=?, newDefault=?}} shape tsv_model expects, or nil when
-- the file has no overlay. `targetKey` is the file's relative key; overlays
-- are keyed by resolved relative key (engine path) or bare basename
-- (resolver-less direct API use), so both are tried.
local function columnOverridesFor(overlays, targetKey)
    if not overlays then return nil end
    local tgt = overlays[targetKey] or overlays[basename(targetKey)]
    if not tgt or next(tgt.columns) == nil then
        return nil
    end
    return tgt.columns
end

-- Finds the validator-list map key (in lcFn2RowValidators / lcFn2FileValidators)
-- matching an overlay's target key. The descriptor maps are keyed by the
-- Files.tsv-listed (package-relative) name, while the overlay key is the
-- resolved input-relative key (or a bare basename on the resolver-less API
-- path), so the match is by basename. When several listed names share the
-- basename (same-named files in different packages), a listed name that is a
-- path suffix of the overlay key wins; otherwise the alphabetically-first
-- match is used (deterministic — and the ambiguity was already warned about
-- when the overlay target resolved).
local function findListKey(map, targetKey)
    local wantBasename = basename(targetKey)
    local matches = {}
    for k in pairs(map) do
        if basename(k) == wantBasename then
            matches[#matches + 1] = k
        end
    end
    if #matches == 0 then return nil end
    if #matches == 1 then return matches[1] end
    table.sort(matches)
    for _, k in ipairs(matches) do
        if targetKey == k
            or targetKey:sub(-#k - 1) == "/" .. k
            or targetKey:sub(-#k - 1) == "\\" .. k then
            return k
        end
    end
    return matches[1]
end

-- Applies the suppressValidator / validatorLevel overlays to the per-file
-- validator lists in joinMeta, in place, before validators run. A `none`
-- override drops the matched validator; `warn` / `error` rebinds its level.
-- Each list is rebuilt (rather than mutated) because the parsed validator
-- specs may be read-only. Unmatched suppressors warn (likely a typo).
local function applyValidatorOverrides(overlays, joinMeta, badVal, opt_lineage, opt_fn2pkg)
    if not overlays then return end
    local rowMap = joinMeta.lcFn2RowValidators or {}
    local fileMap = joinMeta.lcFn2FileValidators or {}

    for targetKey, tgt in pairs(overlays) do
        -- Lineage and warnings key by basename, so overlay events group with
        -- the patch events for the same file (patch lineage keys by basename).
        local targetBasename = basename(targetKey)
        if tgt.validators and next(tgt.validators) then
            local matched = {}
            local function rewrite(map)
                local k = findListKey(map, targetKey)
                if not k then return end
                local list = map[k]
                if type(list) ~= "table" then return end
                local newList = {}
                for _, spec in ipairs(list) do
                    local n = normalizeValidatorSpec(spec)
                    local override = tgt.validators[n.expr]
                    if override ~= nil then
                        matched[n.expr] = true
                        if override ~= "none" then
                            newList[#newList + 1] = {expr = n.expr, level = override}
                        end
                        -- override == "none": drop the validator entirely.
                    else
                        newList[#newList + 1] = spec
                    end
                end
                map[k] = newList
            end
            rewrite(rowMap)
            rewrite(fileMap)
            local linSource = srcName(tgt.sources[1], opt_fn2pkg)
            for expr in pairs(tgt.validators) do
                if not matched[expr] then
                    badVal.source_name = tgt.sources[1] or targetBasename
                    badVal.line_no = 0
                    logger:warn(NAME .. ": suppressValidator '" .. expr
                        .. "' did not match any validator on '" .. targetBasename
                        .. "' (nothing suppressed)")
                elseif opt_lineage then
                    opt_lineage:schema(targetBasename, "validator",
                        "suppress -> " .. tostring(tgt.validators[expr]) .. ": " .. expr,
                        linSource)
                end
            end
        end
    end
end

-- Records the column-level overlay effects (widenTo / newDefault) into a patch
-- lineage object for `--explain-patch`. Validator suppressions are
-- recorded separately, in applyValidatorOverrides (where match info is known).
-- No-op when `lineage` is nil. Call after collectOverlays.
local function recordLineage(overlays, lineage, opt_fn2pkg)
    if not overlays or not lineage then return end
    -- Sorted iteration so the event (and thus report) order is deterministic.
    local targetKeys = {}
    for targetKey in pairs(overlays) do targetKeys[#targetKeys + 1] = targetKey end
    table.sort(targetKeys)
    for _, targetKey in ipairs(targetKeys) do
        local tgt = overlays[targetKey]
        -- Keyed by basename so overlay events group with patch events for the
        -- same file (patch lineage keys by basename of the resolved target).
        local targetBasename = basename(targetKey)
        local cols = {}
        for col in pairs(tgt.columns) do cols[#cols + 1] = col end
        table.sort(cols)
        for _, col in ipairs(cols) do
            local entry = tgt.columns[col]
            if entry.widenTo then
                lineage:schema(targetBasename, col, "widenTo " .. entry.widenTo,
                    srcName(entry.widenToSrc or tgt.sources[1], opt_fn2pkg))
            end
            if entry.newDefault ~= nil then
                -- One event per declaring source, apply order, winner last —
                -- the same chain shape cell events use.
                local hist = entry.newDefaultHist
                    or {{value = entry.newDefault, src = entry.newDefaultSrc or tgt.sources[1]}}
                for _, h in ipairs(hist) do
                    lineage:schema(targetBasename, col,
                        "newDefault " .. tostring(h.value), srcName(h.src, opt_fn2pkg))
                end
            end
        end
    end
end

-- True iff `widenTo` is a strictly wider type than `current` — every value
-- valid under `current` is valid under `widenTo`. Used by tsv_model when an
-- overlay widens a column. Identical specs are not "wider" (caller warns).
local function isWidening(current, widenTo)
    if widenTo == current then return false end
    return extendsOrRestrict(current, widenTo)
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    collectOverlays = collectOverlays,
    columnOverridesFor = columnOverridesFor,
    applyValidatorOverrides = applyValidatorOverrides,
    recordLineage = recordLineage,
    isWidening = isWidening,
    -- Exposed for testing.
    mergeUnion = mergeUnion,
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
