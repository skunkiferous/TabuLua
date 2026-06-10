-- Module name
local NAME = "schema_overlay"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 27, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local logger = require("named_logger").getLogger(NAME)

local parsers = require("parsers")
local parseType = parsers.parseType
local unionTypes = parsers.unionTypes
local extendsOrRestrict = parsers.extendsOrRestrict

local tsv_model = require("tsv_model")
local processTSV = tsv_model.processTSV
local defaultOptionsExtractor = tsv_model.defaultOptionsExtractor

local raw_tsv = require("raw_tsv")
local stringToRawTSV = raw_tsv.stringToRawTSV

local content_pipeline = require("content_pipeline")

local validator_executor = require("validator_executor")
local normalizeValidatorSpec = validator_executor.normalizeValidatorSpec

-- ============================================================
-- Tier-A0 schema overlay (see TODO/mod_overrides.md §3, Phase 1).
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
-- across all overlays targeting one validator wins (§3.3). `none` removes
-- the validator entirely.
local SEVERITY = {none = 0, warn = 1, error = 2}

-- Lowercased basename of a path/key (strips any directory prefix).
local function basename(key)
    return (key:match("[/\\]([^/\\]+)$") or key):lower()
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
-- same column (§3.3): widening to `gold|int` and `gold|float` yields
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
                -- newDefault: later overlay (in load order) wins.
                if newDefault ~= nil and newDefault ~= "" then
                    entry.newDefault = newDefault
                end
                -- widenTo: order-independent union of every declared widening.
                if widenTo ~= nil and widenTo ~= "" then
                    entry.widenTo = mergeUnion(entry.widenTo, widenTo)
                end
            end

            -- Validator-targeting operation (suppressValidator + validatorLevel).
            -- Matched purely by the validator's expression text; the row's
            -- `column` cell is contextual only (§3.1).
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
    lcFn2SchemaOverlayOf, lcFn2Transcoder, raw_files, loadEnv, badVal)
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
            ingestOverlayFile(overlays, file_name, basename(target),
                lcFn2Transcoder[key], raw_files, loadEnv, expr_eval, badVal)
        end
    end
    return overlays
end

-- Returns the per-column override map for a target file (keyed by basename),
-- in the {colName = {widenTo=?, newDefault=?}} shape tsv_model expects, or
-- nil when the file has no overlay. `targetKey` is the file's relative key.
local function columnOverridesFor(overlays, targetKey)
    if not overlays then return nil end
    local tgt = overlays[basename(targetKey)]
    if not tgt or next(tgt.columns) == nil then
        return nil
    end
    return tgt.columns
end

-- Finds the validator-list map key (in lcFn2RowValidators / lcFn2FileValidators)
-- whose basename matches `wantBasename`. The descriptor maps are keyed by the
-- Files.tsv-listed name, which is usually the basename but may carry a
-- directory prefix; runtime validator lookup uses the basename, so we match
-- on that to mutate the exact list both sides agree on.
local function findListKey(map, wantBasename)
    for k in pairs(map) do
        if basename(k) == wantBasename then
            return k
        end
    end
    return nil
end

-- Applies the suppressValidator / validatorLevel overlays to the per-file
-- validator lists in joinMeta, in place, before validators run. A `none`
-- override drops the matched validator; `warn` / `error` rebinds its level.
-- Each list is rebuilt (rather than mutated) because the parsed validator
-- specs may be read-only. Unmatched suppressors warn (likely a typo, §3.5).
local function applyValidatorOverrides(overlays, joinMeta, badVal)
    if not overlays then return end
    local rowMap = joinMeta.lcFn2RowValidators or {}
    local fileMap = joinMeta.lcFn2FileValidators or {}

    for targetBasename, tgt in pairs(overlays) do
        if tgt.validators and next(tgt.validators) then
            local matched = {}
            local function rewrite(map)
                local k = findListKey(map, targetBasename)
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
            for expr in pairs(tgt.validators) do
                if not matched[expr] then
                    badVal.source_name = tgt.sources[1] or targetBasename
                    badVal.line_no = 0
                    logger:warn(NAME .. ": suppressValidator '" .. expr
                        .. "' did not match any validator on '" .. targetBasename
                        .. "' (nothing suppressed)")
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
