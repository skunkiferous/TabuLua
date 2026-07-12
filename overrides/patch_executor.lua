-- Module name
local NAME = "patch_executor"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 31, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly
local unwrap = read_only.unwrap

-- Optional patch-lineage recording (for --explain-patch). The write
-- paths take an optional lineage object; when nil, nothing is recorded.
local patch_lineage = require("overrides.patch_lineage")
local lineageValueStr = patch_lineage.valueStr

local logger = require("infra.named_logger").getLogger(NAME)

local didYouMean = require("infra.error_reporting").didYouMean

local parsers = require("parsers")
local isNullable = parsers.isNullable
local unionTypes = parsers.unionTypes
local arrayElementType = parsers.arrayElementType
local mapKVType = parsers.mapKVType

local table_utils = require("util.table_utils")
local deepCopyUnwrapped = table_utils.deepCopyUnwrapped

local tsv_model = require("tsv.tsv_model")
local newDataCell = tsv_model.newDataCell
local newDataRow = tsv_model.newDataRow
local expressionEvaluatorGenerator = tsv_model.expressionEvaluatorGenerator
-- The same-row =expr recompute reuses the loader's dependency-ordering check.
local canProcessCell = tsv_model.internal.canProcessCell

local validator_executor = require("wiring.validator_executor")
local wrapRowsForValidation = validator_executor.wrapRowsForValidation
local evaluateInValidatorEnv = validator_executor.evaluateInValidatorEnv

-- Operation quota for a bulk-patch `where` / transform expression (per evaluation).
local BULK_QUOTA = 10000

-- ============================================================
-- Row patches.
--
-- A child package declares a patch file (`typeName=patch`, `patchOf=Target.tsv`)
-- whose rows carry a `patchOp` (add | remove | update | replace) and apply to a
-- parent file's rows by primary key. applyPatches runs after own-package
-- pre-processors and before validators, so validators see the patched state.
--
-- Mutation model: the parent dataset is read-only, but its UNDERLYING array can
-- be mutated via read_only.unwrap — append (add), table.remove (remove), and
-- in-place cell writes (update). Iteration-based consumers (validators, exporter)
-- rebuild their own PK index from the array, so they observe the patches. The
-- dataset's captured PK index goes stale for added/removed keys, so the executor
-- keeps its OWN pk→row map while applying. To avoid baking patches into parent
-- *source*, the reformatter skips patched targets (returned as `patchedTargets`);
-- update writes additionally leave each cell's `.value`/`.reformatted` untouched
-- (the same trick pre-processors use), so an update-only target round-trips even
-- if it weren't skipped.
-- ============================================================

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- Lowercased basename of a path/key.
local function basename(key)
    return (key:match("[/\\]([^/\\]+)$") or key):lower()
end

-- Lineage source display: the file's basename, prefixed with the owning
-- package id when known ("ModA:PricePatch.tsv") — so two mods shipping
-- same-named patch files stay distinguishable in lineage/conflict reports.
local function srcName(fn, opt_fn2pkg)
    local pkg = opt_fn2pkg and opt_fn2pkg[fn]
    local base = fn:match("[/\\]([^/\\]+)$") or fn
    return pkg and (pkg .. ":" .. base) or base
end

-- Reads a cell's parsed value (falling back to evaluated).
local function parsedOf(cell)
    if type(cell) ~= "table" then return nil end
    local v = cell.parsed
    if v == nil then v = cell.evaluated end
    return v
end

-- True iff a patch cell is "empty" — the author left it blank. Empty means
-- "leave unchanged" (update) or "use the parent default" (add). A cell holding
-- an =expression (e.g. `=nil`) has a non-empty `.value` and is NOT empty.
local function isEmptyCell(cell)
    if type(cell) ~= "table" then return true end
    local v = cell.value
    return v == nil or v == ""
end

-- ============================================================
-- List/map delta companion columns.
-- ============================================================

-- Classifies a column type as a collection (a `|nil` suffix is ignored): returns
-- "list", elemType  OR  "map", keyType, valType  OR  nil for a non-collection.
local function collectionInfo(type_spec)
    local candidates = unionTypes(type_spec)
    if not candidates then candidates = {type_spec} end
    for _, t in ipairs(candidates) do
        if t ~= "nil" then
            local elem = arrayElementType(t)
            if elem then return "list", elem end
            local k, v = mapKVType(t)
            if k then return "map", k, v end
        end
    end
    return nil
end

-- Verb-prefix companion-column grammar. Longest prefixes are matched first so e.g.
-- `replace_oldvalue_<col>` wins over `replace_<col>`, and `remove_last_<col>` over
-- `remove_<col>`. Returns {verb, target, role, last} or nil. `verb` is one of
-- append | prepend | remove | replace_whole | inplace; `role` (old|new) and `last`
-- apply to the in-place replace pair / the find-based `_last_` variants.
local MERGE_PREFIXES = {
    {p = "replace_last_oldvalue_", verb = "inplace",       role = "old", last = true},
    {p = "replace_last_newvalue_", verb = "inplace",       role = "new", last = true},
    {p = "replace_oldvalue_",      verb = "inplace",       role = "old", last = false},
    {p = "replace_newvalue_",      verb = "inplace",       role = "new", last = false},
    {p = "remove_last_",           verb = "remove",                      last = true},
    {p = "append_",                verb = "append",                      last = false},
    {p = "prepend_",               verb = "prepend",                     last = false},
    {p = "remove_",                verb = "remove",                      last = false},
    {p = "replace_",               verb = "replace_whole",               last = false},
}
local function parseMergeColumn(name)
    for _, m in ipairs(MERGE_PREFIXES) do
        if #name > #m.p and name:sub(1, #m.p) == m.p then
            return {verb = m.verb, target = name:sub(#m.p + 1),
                role = m.role, last = m.last}
        end
    end
    return nil
end

-- Builds, in one pass, the pk(string) -> row proxy map AND the pk(string) ->
-- array-index map over a dataset's data rows (index >= 2). The index map lets the
-- apply loop locate a row's slot in O(1) for replace/remove instead of rescanning
-- the array. It stays valid for the whole loop because removals are DEFERRED to a
-- single compaction pass (see applyOnePatch) — no in-loop op shifts existing
-- indices (add/replace-new append at the end; replace-in-place keeps the slot).
local function indexByPk(targetArray)
    local byPk, idxByPk = {}, {}
    for i = 2, #targetArray do
        local row = targetArray[i]
        if type(row) == "table" then
            local pk = parsedOf(row[1])
            if pk ~= nil and type(pk) ~= "table" then
                local key = tostring(pk)
                byPk[key] = row
                idxByPk[key] = i
            end
        end
    end
    return byPk, idxByPk
end

-- Compacts a dataset array in place, dropping the tombstoned (removed) physical
-- indices while preserving order and the header at [1]. One O(M) pass, run once
-- per patch file after all its ops — the deferred-removal counterpart to the O(1)
-- tombstone marking in the apply loop. Non-data rows (comments) are not in
-- `removedIdx`, so they survive in place.
local function compactRemoved(targetArray, removedIdx)
    local w = 2
    local n = #targetArray
    for r = 2, n do
        if not removedIdx[r] then
            if w ~= r then targetArray[w] = targetArray[r] end
            w = w + 1
        end
    end
    for r = w, n do
        targetArray[r] = nil
    end
end

-- Constructs a new parent row from a patch row's provided cells, filling empty
-- cells with the parent column's default (exactly as a normal data row would).
-- `evalRow` accumulates parsed values by column name so an =expr default can
-- reference earlier columns (header order), matching processTSV's common case.
-- Returns the row proxy, or nil + reports an error via badVal on a required
-- missing value / invalid value.
local function buildRow(targetHeader, patchRow, patchHeader, expr_eval,
    badVal, opt_idx)
    local cells = {}
    local evalRow = {}
    local ok = true
    for ci = 1, #targetHeader do
        local col = targetHeader[ci]
        local patchCol = patchHeader[col.name]
        local patchCell = patchCol and patchRow[patchCol.idx]
        badVal.col_name = col.name
        badVal.col_idx = ci
        if patchCol and not isEmptyCell(patchCell) then
            -- Provided: re-validate the patch value against the PARENT parser.
            local value = parsedOf(patchCell)
            if value == nil then
                if isNullable(col.type_spec) then
                    cells[ci] = newDataCell("=nil", nil, nil, "")
                    evalRow[col.name] = nil
                else
                    badVal(col.name, "patchOp=add/replace: column '" .. col.name
                        .. "' set to nil but type '" .. col.type_spec
                        .. "' is not nullable")
                    ok = false
                    cells[ci] = newDataCell("", nil, nil, "")
                end
            elseif col.parser then
                local parsed, reformatted = col.parser(badVal, value, "parsed")
                if parsed == nil then
                    badVal(col.name, "patchOp=add/replace: value for column '"
                        .. col.name .. "' is not a valid '" .. col.type_spec .. "'")
                    ok = false
                    cells[ci] = newDataCell("", nil, nil, "")
                else
                    cells[ci] = newDataCell(reformatted, parsed, parsed, reformatted)
                    evalRow[col.name] = parsed
                end
            else
                cells[ci] = newDataCell(tostring(value), value, value, tostring(value))
                evalRow[col.name] = value
            end
        else
            -- Empty: use the parent column default (effective overlay default first).
            local default = col.effective_default_expr or col.default_expr
            if default ~= nil and default ~= "" then
                local raw = default
                if type(default) == "string" and default:sub(1, 1) == '=' then
                    local v, problem = expr_eval(evalRow, default)
                    if problem ~= nil then
                        badVal(col.name, "patchOp=add/replace: default for column '"
                            .. col.name .. "' failed to evaluate: " .. problem)
                        ok = false
                        v = nil
                    end
                    raw = v
                end
                local parsed = raw
                if col.parser then
                    local ctx = (type(default) == "string" and default:sub(1, 1) ~= '=')
                        and "tsv" or "parsed"
                    parsed = col.parser(badVal, raw, ctx)
                end
                -- Empty reformatted: the default is not written to disk, exactly
                -- like a normal empty cell that resolves to its default.
                cells[ci] = newDataCell("", parsed, parsed, "")
                evalRow[col.name] = parsed
            elseif isNullable(col.type_spec) then
                cells[ci] = newDataCell("", nil, nil, "")
                evalRow[col.name] = nil
            else
                badVal(col.name, "patchOp=add/replace: column '" .. col.name
                    .. "' has no value and no default (required)")
                ok = false
                cells[ci] = newDataCell("", nil, nil, "")
            end
        end
    end
    if not ok then
        return nil
    end
    return newDataRow(targetHeader, cells, opt_idx)
end

-- Writes a value into a parent row's cell, in place, re-validating it against
-- the parent column's parser. `parseCtx` is the parser context: "parsed" for an
-- already-typed value (a patch cell or a bulk `=expr` result), "tsv" for
-- a raw literal string (a bulk literal transform cell). A nil value clears the
-- cell (requires a nullable parent type). `.value` / `.reformatted` are left
-- untouched so the parent file round-trips to its original source text. Returns
-- true on success.
local function setCellRaw(rawRow, parentCol, value, parseCtx, badVal, label)
    local rawCell = unwrap(rawRow[parentCol.idx])
    if type(rawCell) ~= "table" then
        badVal(parentCol.name, label .. ": target cell missing for column '"
            .. parentCol.name .. "'")
        return false
    end
    if value == nil then
        if not isNullable(parentCol.type_spec) then
            badVal(parentCol.name, label .. ": cannot set column '" .. parentCol.name
                .. "' to nil (type '" .. parentCol.type_spec .. "' is not nullable)")
            return false
        end
        rawCell[2] = nil
        rawCell[3] = nil
        return true
    end
    if parentCol.parser then
        local parsed = parentCol.parser(badVal, value, parseCtx)
        if parsed == nil then
            badVal(parentCol.name, label .. ": value for column '" .. parentCol.name
                .. "' is not a valid '" .. parentCol.type_spec .. "'")
            return false
        end
        rawCell[2] = parsed
        rawCell[3] = parsed
    else
        rawCell[2] = value
        rawCell[3] = value
    end
    return true
end

-- Returns a fresh, mutable (unwrapped) copy of a parent row's collection cell, or
-- nil if the cell is empty/absent. Mutate the copy, then write it back via setCellRaw.
local function currentCollection(rawRow, col)
    local cell = rawRow[col.idx]
    return deepCopyUnwrapped(cell and cell.parsed)
end

-- Removes the first (or last) occurrence of `value` from a list, in place.
local function removeOccurrence(list, value, last)
    if last then
        for i = #list, 1, -1 do
            if list[i] == value then table.remove(list, i); return true end
        end
    else
        for i = 1, #list do
            if list[i] == value then table.remove(list, i); return true end
        end
    end
    return false
end

-- Applies a list-merge op (append / prepend / remove / replace_whole) to a parent
-- list column, in place. `items` is the companion cell's parsed value: a list of
-- elements for append/prepend/remove, or the whole new list for replace_whole.
local function applyListMerge(rawRow, m, items, badVal, opt_ifMissing)
    if type(items) ~= "table" then items = {items} end
    if m.verb == "replace_whole" then
        return setCellRaw(rawRow, m.targetCol, items, "parsed", badVal, "replace_")
    end
    local current = currentCollection(rawRow, m.targetCol) or {}
    if m.verb == "append" then
        for _, v in ipairs(items) do current[#current + 1] = v end
    elseif m.verb == "prepend" then
        -- Insert at the head preserving the listed order: prepend {a,b} on {c,d}
        -- yields {a,b,c,d}.
        for i = #items, 1, -1 do table.insert(current, 1, items[i]) end
    elseif m.verb == "remove" then
        for _, v in ipairs(items) do
            if not removeOccurrence(current, v, m.last) then
                -- Always a no-op; ifMissing=silent just quiets the warning.
                if opt_ifMissing ~= "silent" then
                    logger:warn(badVal.source_name .. ": remove_" .. m.targetCol.name
                        .. ": value '" .. tostring(v) .. "' not present (no-op)")
                end
            end
        end
    end
    return setCellRaw(rawRow, m.targetCol, current, "parsed", badVal,
        m.verb .. "_" .. m.targetCol.name)
end

-- Applies a map-merge op (append / remove / replace_whole) to a parent map column.
-- For append, `value` is a map merged into the parent; for remove, a list of keys
-- to drop; for replace_whole, the whole new map.
local function applyMapMerge(rawRow, m, value, badVal)
    if m.verb == "replace_whole" then
        return setCellRaw(rawRow, m.targetCol, value, "parsed", badVal, "replace_")
    end
    local current = currentCollection(rawRow, m.targetCol) or {}
    if m.verb == "append" then
        if type(value) == "table" then
            for k, v in pairs(value) do current[k] = v end
        end
    elseif m.verb == "remove" then
        if type(value) == "table" then
            for _, k in ipairs(value) do current[k] = nil end
        end
    end
    return setCellRaw(rawRow, m.targetCol, current, "parsed", badVal,
        m.verb .. "_" .. m.targetCol.name)
end

-- Replaces, in place and by value, the first (or last) occurrence of `oldVal` with
-- `newVal` in a parent list column, preserving its position (op 8). `oldVal` not
-- found is an error — or, under ifMissing=warn/silent, a tolerated no-op; multiple
-- matches warn; old == new is a no-op warning. Returns (ok, changed): `changed`
-- is false only for the tolerated not-found no-op, so the caller can skip
-- recording a lineage event for a write that never happened.
local function applyInplaceReplace(rawRow, pair, oldVal, newVal, badVal, opt_ifMissing)
    local current = currentCollection(rawRow, pair.targetCol) or {}
    local positions = {}
    for i = 1, #current do
        if current[i] == oldVal then positions[#positions + 1] = i end
    end
    if #positions == 0 then
        if opt_ifMissing == "warn" or opt_ifMissing == "silent" then
            if opt_ifMissing == "warn" then
                logger:warn(badVal.source_name .. ": replace_oldvalue_"
                    .. pair.targetCol.name .. ": value '" .. tostring(oldVal)
                    .. "' not found (no-op, ifMissing=warn)")
            end
            return true, false
        end
        badVal(pair.targetCol.name, "replace_oldvalue_" .. pair.targetCol.name
            .. ": value '" .. tostring(oldVal) .. "' not found in the list")
        return false
    end
    if oldVal == newVal then
        logger:warn(badVal.source_name .. ": replace on '" .. pair.targetCol.name
            .. "': old value equals new value (no-op)")
        return true, true
    end
    if #positions > 1 then
        logger:warn(badVal.source_name .. ": replace on '" .. pair.targetCol.name
            .. "': value '" .. tostring(oldVal) .. "' occurs " .. #positions
            .. " times; replacing the " .. (pair.last and "last" or "first"))
    end
    local pos = pair.last and positions[#positions] or positions[1]
    current[pos] = newVal
    return setCellRaw(rawRow, pair.targetCol, current, "parsed", badVal,
        "replace_" .. pair.targetCol.name), true
end

-- Analyses a patch file's header ONCE: classifies each non-key/op column as a
-- direct cell set or a list/map delta companion. Returns a plan
-- { direct = {{patchIdx, targetCol}}, simple = {{patchIdx, verb, targetCol, kind}},
--   inplace = {{targetCol, last, oldIdx, newIdx}} } plus reports header errors.
local function analyzePatchPlan(patchHeader, targetHeader, skipIdx, badVal)
    local plan = {direct = {}, simple = {}, inplace = {}}
    local inplaceByKey = {}
    for _, pc in ipairs(patchHeader) do
        if not skipIdx[pc.idx] then
            local tc = targetHeader[pc.name]
            local merge = parseMergeColumn(pc.name)
            local mtc = merge and targetHeader[merge.target]
            local kind = mtc and collectionInfo(mtc.type_spec)
            if tc then
                -- Prefix-collision precedence: a literal column-name match always
                -- wins; the merge interpretation is only a fall-back.
                plan.direct[#plan.direct + 1] = {patchIdx = pc.idx, targetCol = tc}
                if merge and mtc and kind then
                    logger:warn(badVal.source_name .. ": patch column '" .. pc.name
                        .. "' matches both a target column and a merge-prefix form;"
                        .. " using the column (rename to disambiguate)")
                end
            elseif merge and mtc and kind then
                local listOnly = (merge.verb == "prepend" or merge.verb == "inplace")
                if kind == "map" and listOnly then
                    logger:warn(badVal.source_name .. ": '" .. pc.name
                        .. "': " .. merge.verb .. " is not valid on the map column '"
                        .. merge.target .. "' (ignored)")
                elseif merge.verb == "inplace" then
                    local key = merge.target .. "|" .. tostring(merge.last)
                    local pair = inplaceByKey[key]
                    if not pair then
                        pair = {targetCol = mtc, last = merge.last}
                        inplaceByKey[key] = pair
                        plan.inplace[#plan.inplace + 1] = pair
                    end
                    pair[merge.role .. "Idx"] = pc.idx
                else
                    plan.simple[#plan.simple + 1] = {patchIdx = pc.idx,
                        verb = merge.verb, targetCol = mtc, kind = kind, last = merge.last}
                end
            elseif merge and mtc and not kind then
                logger:warn(badVal.source_name .. ": '" .. pc.name
                    .. "': target column '" .. merge.target
                    .. "' is not a list/map (merge-prefix ignored)")
            else
                logger:warn(badVal.source_name .. ": patch column '" .. pc.name
                    .. "' has no matching column in the target file (ignored)")
            end
        end
    end
    -- An in-place replace needs BOTH halves of the pair as columns.
    local complete = {}
    for _, pair in ipairs(plan.inplace) do
        if pair.oldIdx and pair.newIdx then
            complete[#complete + 1] = pair
        else
            badVal(pair.targetCol.name, "replace-in-place on '" .. pair.targetCol.name
                .. "' needs both replace_" .. (pair.last and "last_" or "")
                .. "oldvalue_ and replace_" .. (pair.last and "last_" or "")
                .. "newvalue_ columns")
        end
    end
    plan.inplace = complete
    return plan
end

-- Applies an `update` patch row to an existing parent row, in place, using a
-- precomputed plan: direct cell sets (empty = leave unchanged, `=nil` = clear) plus
-- list/map delta companion columns.
local function applyUpdate(rowProxy, patchRow, plan, badVal, linCtx, opt_ifMissing)
    local rawRow = unwrap(rowProxy)
    local ok = true
    -- Records one cell change to the lineage (no-op when tracking is off).
    local function rec(col, action)
        if linCtx then
            linCtx.lineage:cell(linCtx.target, linCtx.pk, col, action, linCtx.source)
        end
    end
    -- Direct cell sets.
    for _, d in ipairs(plan.direct) do
        local patchCell = patchRow[d.patchIdx]
        if not isEmptyCell(patchCell) then
            badVal.col_name = d.targetCol.name
            local value = parsedOf(patchCell)
            if not setCellRaw(rawRow, d.targetCol, value, "parsed", badVal, "update") then
                ok = false
            else
                rec(d.targetCol.name, "= " .. lineageValueStr(value))
            end
        end
    end
    -- List/map delta merges (append / prepend / remove / replace_whole).
    for _, m in ipairs(plan.simple) do
        local patchCell = patchRow[m.patchIdx]
        if not isEmptyCell(patchCell) then
            badVal.col_name = m.targetCol.name
            local items = parsedOf(patchCell)
            local applied
            if m.kind == "list" then
                applied = applyListMerge(rawRow, m, items, badVal, opt_ifMissing)
            else
                applied = applyMapMerge(rawRow, m, items, badVal)
            end
            if not applied then
                ok = false
            else
                rec(m.targetCol.name, m.verb .. " " .. lineageValueStr(items))
            end
        end
    end
    -- In-place replace-by-value (paired oldvalue/newvalue columns).
    for _, pair in ipairs(plan.inplace) do
        local oldCell = patchRow[pair.oldIdx]
        local newCell = patchRow[pair.newIdx]
        local oldEmpty, newEmpty = isEmptyCell(oldCell), isEmptyCell(newCell)
        if not (oldEmpty and newEmpty) then
            badVal.col_name = pair.targetCol.name
            if oldEmpty ~= newEmpty then
                badVal(pair.targetCol.name, "replace-in-place on '"
                    .. pair.targetCol.name .. "': both replace_oldvalue and"
                    .. " replace_newvalue cells must be set (or both empty)")
                ok = false
            else
                local oldVal, newVal = parsedOf(oldCell), parsedOf(newCell)
                local applied, changed = applyInplaceReplace(rawRow, pair, oldVal,
                    newVal, badVal, opt_ifMissing)
                if not applied then
                    ok = false
                elseif changed then
                    rec(pair.targetCol.name, "replace " .. lineageValueStr(oldVal)
                        .. " -> " .. lineageValueStr(newVal))
                end
            end
        end
    end
    return ok
end

-- Applies one patch file's rows to its target dataset (mutating the target's
-- underlying array). Returns true if all error-level ops succeeded.
local function applyOnePatch(patchFileName, patchTsv, targetName, targetTsv,
    expr_eval, badVal, opt_lineage, opt_fn2pkg, opt_ifMissing)
    local patchHeader = patchTsv[1]
    local targetHeader = targetTsv[1]
    badVal.source_name = patchFileName
    badVal.line_no = 0
    badVal.col_idx = 0
    -- Lineage keys for `--explain-patch`: the target is keyed by lowercased
    -- basename (so patch + overlay events for one file group together); the
    -- source keeps its original case for readability, qualified with the
    -- owning package when known.
    local linTarget = basename(targetName)
    local linSource = srcName(patchFileName, opt_fn2pkg)

    local patchOpCol = patchHeader["patchOp"]
    if not patchOpCol then
        badVal("patchOp", "patch file '" .. patchFileName
            .. "' has no 'patchOp' column")
        return false
    end
    -- Column 1 of both files is the primary key; require matching names.
    local pkName = patchHeader[1].name
    if pkName ~= targetHeader[1].name then
        badVal(pkName, "patch file column 1 ('" .. pkName
            .. "') must be the target's primary-key column ('"
            .. targetHeader[1].name .. "')")
        return false
    end

    local skipIdx = {[1] = true, [patchOpCol.idx] = true}
    -- Classify the patch columns once (direct cell sets vs list/map deltas),
    -- shared by every `update` row in this file.
    local updatePlan = analyzePatchPlan(patchHeader, targetHeader, skipIdx, badVal)
    local targetArray = unwrap(targetTsv)
    local byPk, idxByPk = indexByPk(targetArray)
    -- Removals are deferred: a removed row is tombstoned (its index recorded) and
    -- physically dropped in one compaction pass after the loop. This keeps idxByPk
    -- valid throughout (no in-loop index shifts), so replace/remove stay O(1).
    local removedIdx = {}
    local anyRemoved = false
    local ok = true

    for i = 2, #patchTsv do
        local patchRow = patchTsv[i]
        if type(patchRow) == "table" then
            badVal.line_no = i
            local op = parsedOf(patchRow[patchOpCol.idx])
            local pk = parsedOf(patchRow[1])
            local pkStr = (pk ~= nil) and tostring(pk) or nil
            badVal.row_key = pkStr or ""
            if pkStr == nil then
                badVal("", "patch row has no primary key")
                ok = false
            elseif op == "add" then
                if byPk[pkStr] then
                    badVal(pkStr, "patchOp=add: primary key '" .. pkStr
                        .. "' already exists in target '" .. basename(targetName) .. "'")
                    ok = false
                else
                    local pos = #targetArray + 1
                    local row = buildRow(targetHeader, patchRow, patchHeader,
                        expr_eval, badVal, pos)
                    if row then
                        targetArray[pos] = row
                        byPk[pkStr] = row
                        idxByPk[pkStr] = pos
                        if opt_lineage then
                            opt_lineage:row(linTarget, pkStr, "add", linSource)
                        end
                    else
                        ok = false
                    end
                end
            elseif op == "remove" then
                if not byPk[pkStr] then
                    -- Always a no-op (idempotent delete); ifMissing=silent just
                    -- quiets the warning.
                    if opt_ifMissing ~= "silent" then
                        logger:warn(patchFileName .. " line " .. i .. ": patchOp=remove"
                            .. " key '" .. pkStr .. "' not found in target (no-op)")
                    end
                else
                    -- Tombstone the slot; compaction drops it after the loop.
                    removedIdx[idxByPk[pkStr]] = true
                    anyRemoved = true
                    byPk[pkStr] = nil
                    idxByPk[pkStr] = nil
                    if opt_lineage then
                        opt_lineage:row(linTarget, pkStr, "remove", linSource)
                    end
                end
            elseif op == "update" then
                local existing = byPk[pkStr]
                if not existing then
                    -- ifMissing tolerance (mod_ecosystem §6): a compat patch
                    -- spanning several target versions may update a key that
                    -- only some versions have.
                    if opt_ifMissing == "warn" then
                        logger:warn(patchFileName .. " line " .. i .. ": patchOp=update"
                            .. " key '" .. pkStr
                            .. "' not found in target (no-op, ifMissing=warn)")
                    elseif opt_ifMissing ~= "silent" then
                        -- Error policy only (warn/silent above are expected
                        -- version drift, not typos) — suggest a real PK.
                        badVal(pkStr, "patchOp=update: key '" .. pkStr
                            .. "' not found in target '" .. basename(targetName) .. "'"
                            .. didYouMean(pkStr, byPk))
                        ok = false
                    end
                else
                    local linCtx = opt_lineage and
                        {lineage = opt_lineage, target = linTarget, pk = pkStr, source = linSource}
                    if not applyUpdate(existing, patchRow, updatePlan, badVal, linCtx,
                        opt_ifMissing) then
                        ok = false
                    end
                end
            elseif op == "replace" then
                -- Existing key replaces in place (same slot, no shift); a new key
                -- appends. Both are O(1) via idxByPk.
                local pos = byPk[pkStr] and idxByPk[pkStr] or (#targetArray + 1)
                local row = buildRow(targetHeader, patchRow, patchHeader,
                    expr_eval, badVal, pos)
                if row then
                    targetArray[pos] = row
                    byPk[pkStr] = row
                    idxByPk[pkStr] = pos
                    if opt_lineage then
                        opt_lineage:row(linTarget, pkStr, "replace", linSource)
                    end
                else
                    ok = false
                end
            else
                badVal(tostring(op), "unknown patchOp '" .. tostring(op)
                    .. "' (expected add | remove | update | replace)")
                ok = false
            end
        end
    end
    if anyRemoved then
        compactRemoved(targetArray, removedIdx)
    end
    return ok
end

-- Applies one bulk/filter patch file to its target. Each rule row carries a unique
-- rule name (column 1), a `patchOp` (update | remove), a `where` selector
-- expression, and — for update rules — transform cells. `where` is evaluated per
-- parent row in the validator sandbox (truthy = match, with
-- `self`/`row`/`rows`/helpers/published contexts); matched rows are removed
-- (deferred + compaction, like a row patch) or have each non-empty transform
-- cell applied. A transform cell starting with `=` is an expression evaluated
-- against the matched target row; otherwise it is a literal parsed by the parent
-- column. Returns true if all error-level rules/cells succeeded.
local function applyOneBulkPatch(bulkFileName, bulkTsv, targetName, targetTsv,
    loadEnv, badVal, opt_lineage, opt_fn2pkg)
    local bulkHeader = bulkTsv[1]
    local targetHeader = targetTsv[1]
    badVal.source_name = bulkFileName
    badVal.line_no = 0
    badVal.col_idx = 0
    -- Lineage keys for `--explain-patch` (target lowercased, source
    -- case-preserved and package-qualified when known).
    local linTarget = basename(targetName)
    local linSource = srcName(bulkFileName, opt_fn2pkg)

    local whereCol = bulkHeader["where"]
    if not whereCol then
        badVal("where", "bulk_patch file '" .. bulkFileName
            .. "' has no 'where' column")
        return false
    end
    local opCol = bulkHeader["patchOp"]
    if not opCol then
        badVal("patchOp", "bulk_patch file '" .. bulkFileName
            .. "' has no 'patchOp' column")
        return false
    end

    -- Transform columns = every bulk column except the rule name (1), where, patchOp.
    local transformCols = {}
    for ci = 1, #bulkHeader do
        local c = bulkHeader[ci]
        if ci ~= 1 and c ~= whereCol and c ~= opCol then
            transformCols[#transformCols + 1] = c
        end
    end

    -- Snapshot the target's data rows (raw) + a parallel wrapped (parsed-value)
    -- view for the selector/transform sandbox, plus each raw row's array index.
    local targetArray = unwrap(targetTsv)
    local dataRows, idxOf = {}, {}
    for i = 2, #targetArray do
        local r = targetArray[i]
        if type(r) == "table" then
            dataRows[#dataRows + 1] = r
            idxOf[r] = i
        end
    end
    local wrapped = wrapRowsForValidation(dataRows)
    local removedIdx, anyRemoved = {}, false
    local ok = true

    local function ctxFor(i)
        local w = wrapped[i]
        return {self = w, row = w, rows = wrapped, file = wrapped,
            count = #dataRows, fileName = targetName}
    end

    for ri = 2, #bulkTsv do
        local ruleRow = bulkTsv[ri]
        if type(ruleRow) == "table" then
            badVal.line_no = ri
            local ruleName = parsedOf(ruleRow[1])
            badVal.row_key = (ruleName ~= nil) and tostring(ruleName) or ""
            local op = parsedOf(ruleRow[opCol.idx])
            local whereRaw = parsedOf(ruleRow[whereCol.idx])
            if whereRaw == nil or whereRaw == "" then
                badVal(tostring(ruleName), "bulk_patch rule has an empty 'where' selector")
                ok = false
            elseif op ~= "update" and op ~= "remove" then
                badVal(tostring(op), "bulk_patch patchOp must be 'update' or 'remove'"
                    .. " (got '" .. tostring(op) .. "')")
                ok = false
            else
                -- `where` is always an expression; tolerate an optional leading '='.
                local whereExpr = (type(whereRaw) == "string")
                    and whereRaw:gsub("^=", "") or tostring(whereRaw)
                local matchedCount, broke = 0, false
                for i = 1, #dataRows do
                    local matchOk, matched = evaluateInValidatorEnv(
                        whereExpr, ctxFor(i), BULK_QUOTA, loadEnv)
                    if not matchOk then
                        badVal(tostring(ruleName), "bulk_patch 'where' failed: "
                            .. tostring(matched))
                        ok = false
                        broke = true
                        break -- selector is broken; skip the rest of this rule
                    elseif matched ~= nil and matched ~= false then
                        matchedCount = matchedCount + 1
                        if op == "remove" then
                            removedIdx[idxOf[dataRows[i]]] = true
                            anyRemoved = true
                        else
                            for _, tcol in ipairs(transformCols) do
                                local cell = ruleRow[tcol.idx]
                                if not isEmptyCell(cell) then
                                    local parentCol = targetHeader[tcol.name]
                                    badVal.col_name = tcol.name
                                    if not parentCol then
                                        logger:warn(bulkFileName .. ": transform column '"
                                            .. tcol.name .. "' has no matching column in"
                                            .. " the target (ignored)")
                                    else
                                        local raw = cell.value
                                        if type(raw) == "string" and raw:sub(1, 1) == '=' then
                                            local exprOk, v = evaluateInValidatorEnv(
                                                raw:sub(2), ctxFor(i), BULK_QUOTA, loadEnv)
                                            if not exprOk then
                                                badVal(tcol.name, "bulk_patch transform '"
                                                    .. tcol.name .. "' failed: " .. tostring(v))
                                                ok = false
                                            elseif not setCellRaw(unwrap(dataRows[i]),
                                                parentCol, v, "parsed", badVal, "bulk update") then
                                                ok = false
                                            elseif opt_lineage then
                                                opt_lineage:cell(linTarget,
                                                    tostring(parsedOf(dataRows[i][1])), parentCol.name,
                                                    "= " .. lineageValueStr(v) .. " (bulk '"
                                                    .. tostring(ruleName) .. "')", linSource)
                                            end
                                        elseif not setCellRaw(unwrap(dataRows[i]),
                                            parentCol, raw, "tsv", badVal, "bulk update") then
                                            ok = false
                                        elseif opt_lineage then
                                            opt_lineage:cell(linTarget,
                                                tostring(parsedOf(dataRows[i][1])), parentCol.name,
                                                "= " .. lineageValueStr(raw) .. " (bulk '"
                                                .. tostring(ruleName) .. "')", linSource)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                if not broke and matchedCount == 0 then
                    logger:warn(bulkFileName .. " line " .. ri .. ": bulk_patch rule '"
                        .. tostring(ruleName) .. "' matched zero rows in target '"
                        .. basename(targetName) .. "' (no-op; check the 'where' selector)")
                end
            end
        end
    end
    if anyRemoved then
        compactRemoved(targetArray, removedIdx)
    end
    return ok
end

-- ============================================================
-- Recompute downstream `=expr` cells after patches.
--
-- An override changes some cells; other `=expr` cells in the SAME row that read
-- those cells (via `self.x`) were evaluated at load time and are now stale. This
-- pass re-evaluates them — explicit `=expr` cells AND columns with a default
-- `=expr` applied to an empty cell — in dependency order, so e.g. patching
-- baseDamage updates `totalDamage = self.baseDamage * …`. Cross-row / published-
-- constant dependencies are out of scope (deferred).
-- ============================================================

-- Returns the expression to (re)evaluate for a cell, or nil when the cell is not
-- a recomputable `=expr` (explicit) or default-`=expr` (empty cell + the column
-- carries a default expression). `expression`-typed columns (skip_cell_eval) are
-- never re-evaluated here.
local function recomputableExpr(col, cell)
    if col.skip_cell_eval then return nil end
    local v = cell.value
    if type(v) == "string" and v:sub(1, 1) == "=" then
        return v
    end
    if v == nil or v == "" then
        local d = col.effective_default_expr or col.default_expr
        if type(d) == "string" and d:sub(1, 1) == "=" then
            return d
        end
    end
    return nil
end

-- Recomputes one row's `=expr` cells against its current (patched) values, in
-- dependency order. `dirtyCols` is the set of column names an override wrote
-- DIRECTLY in this row — those are left untouched (the explicit value wins, and
-- is treated as a settled input the others may depend on). Returns true on success.
local function recomputeRow(header, rawRow, dirtyCols, expr_eval, badVal)
    -- eval_row mirrors the loader's `self`: parsed values keyed by index AND name.
    local eval_row = {__idx = rawRow.__idx}
    local exprByIdx = {}
    local done_idx = {}
    local pending = 0
    for ci = 1, #header do
        local col = header[ci]
        local cell = rawRow[ci]
        local parsed = (type(cell) == "table") and cell.parsed or nil
        eval_row[ci] = parsed
        eval_row[col.name] = parsed
        local expr = (type(cell) == "table") and recomputableExpr(col, cell) or nil
        if expr and not (dirtyCols and dirtyCols[col.name]) then
            exprByIdx[ci] = expr
            pending = pending + 1
        else
            done_idx[ci] = true   -- literal, directly-set, or expression-typed: settled
        end
    end
    if pending == 0 then return true end

    local ok = true
    while pending > 0 do
        local progress = false
        for ci = 1, #header do
            if exprByIdx[ci] and not done_idx[ci]
                and canProcessCell(header, done_idx, exprByIdx[ci]) then
                local col = header[ci]
                badVal.col_name = col.name
                badVal.col_idx = ci
                local v, err = expr_eval(eval_row, exprByIdx[ci])
                if err ~= nil then
                    badVal(exprByIdx[ci], "recompute after patch: failed to evaluate '"
                        .. col.name .. "': " .. tostring(err))
                    ok = false
                else
                    local parsed = v
                    if col.parser then
                        local p = col.parser(badVal, v, "parsed")
                        if p ~= nil then parsed = p end
                    end
                    local raw = unwrap(rawRow[ci])
                    if type(raw) == "table" then
                        raw[2] = v        -- evaluated
                        raw[3] = parsed   -- parsed; .value/.reformatted untouched (no-bake)
                    end
                    eval_row[ci] = parsed
                    eval_row[col.name] = parsed
                end
                done_idx[ci] = true
                pending = pending - 1
                progress = true
            end
        end
        -- No progress with cells remaining => a self-referential cycle the loader
        -- would already have rejected; leave the rest untouched rather than spin.
        if not progress then break end
    end
    return ok
end

-- Splits a possibly package-qualified target ("some.pkg:Item.tsv") into its
-- lowercased package qualifier (nil when unqualified) and the lowercased
-- basename of the file part. The qualifier is everything before the first ':'
-- provided it contains no path separator (a plain relative path never does;
-- ':' cannot appear in a package_id-adjacent file name, and target values are
-- package-relative so drive letters cannot occur). See TODO/mod_ecosystem.md §4.
local function splitQualifiedTarget(target)
    local pkg, rest = target:match("^([^:/\\]+):(.+)$")
    if pkg then
        return pkg:lower(), basename(rest)
    end
    return nil, basename(target)
end

-- Returns a resolver closure over the loaded datasets for patch/bulk targets.
-- resolve(target) -> fullName|nil, info:
--   * fullName is the resolved tsv_files key; on a multi-candidate match it is
--     the alphabetically-first full name (deterministic), and info.ambiguous
--     carries the sorted candidate list so the caller can warn.
--   * nil fullName: info.reason is "not_found" (no loaded file has that
--     basename), "not_in_package" (qualified, but the named package owns no
--     such file; info.pkg names it), or "missing_fn2pkg" (qualified target but
--     the caller supplied no ownership map). On "not_found"/"not_in_package"
--     info also carries `base` (the basename the caller typed) and
--     `candidates` (the sorted basenames worth suggesting: all known ones for
--     "not_found", the named package's for "not_in_package") so callers can
--     append a did-you-mean via error_reporting.didYouMean.
-- `opt_fn2pkg` maps each tsv_files key to its owning package id (see
-- manifest_loader.buildFileToPackage); package ids match case-insensitively.
local function newTargetResolver(tsv_files, opt_fn2pkg)
    local candidates = {}
    for fn in pairs(tsv_files) do
        local base = basename(fn)
        local list = candidates[base]
        if not list then
            list = {}
            candidates[base] = list
        end
        list[#list + 1] = fn
    end
    for _, list in pairs(candidates) do
        table.sort(list)
    end
    -- Sorted list of every known basename (did-you-mean fodder, error path).
    local function allBases()
        local bases = {}
        for base in pairs(candidates) do bases[#bases + 1] = base end
        table.sort(bases)
        return bases
    end
    -- Sorted basenames owned by a given (lowercased) package id.
    local function basesInPackage(pkg)
        local bases = {}
        for base, list in pairs(candidates) do
            for _, fn in ipairs(list) do
                local pid = opt_fn2pkg and opt_fn2pkg[fn]
                if pid and pid:lower() == pkg then
                    bases[#bases + 1] = base
                    break
                end
            end
        end
        table.sort(bases)
        return bases
    end
    return function(target)
        local wantPkg, wantBase = splitQualifiedTarget(target)
        local list = candidates[wantBase]
        if not list then
            return nil, {reason = "not_found", base = wantBase,
                candidates = allBases()}
        end
        if wantPkg then
            if not opt_fn2pkg then
                return nil, {reason = "missing_fn2pkg", pkg = wantPkg}
            end
            local filtered = {}
            for _, fn in ipairs(list) do
                local pid = opt_fn2pkg[fn]
                if pid and pid:lower() == wantPkg then
                    filtered[#filtered + 1] = fn
                end
            end
            if #filtered == 0 then
                return nil, {reason = "not_in_package", pkg = wantPkg,
                    base = wantBase, candidates = basesInPackage(wantPkg)}
            end
            list = filtered
        end
        if #list > 1 then
            return list[1], {ambiguous = list}
        end
        return list[1], nil
    end
end

-- Recomputes downstream `=expr` cells for every row an override touched. `dirtyMap`
-- is the patch lineage's directly-set-cell set (`target -> pk -> col -> true`).
-- Only rows that actually changed are revisited, and only their non-directly-set
-- `=expr` cells are re-evaluated. Returns true if every recompute succeeded.
local function recomputeAfterPatches(tsv_files, dirtyMap, loadEnv, badVal)
    if not dirtyMap or next(dirtyMap) == nil then
        return true
    end
    -- dirtyMap targets are lineage keys (lowercased basenames of the resolved
    -- target files); resolve them back with the same deterministic
    -- alphabetically-first rule applyPatches uses, so a basename collision
    -- recomputes the same file the patches actually wrote.
    local resolve = newTargetResolver(tsv_files)
    local expr_eval = expressionEvaluatorGenerator(loadEnv)
    local ok = true
    for target, rows in pairs(dirtyMap) do
        local fn = resolve(target)
        local tsv = fn and tsv_files[fn]
        if tsv then
            badVal.source_name = fn
            local header = tsv[1]
            local byPk = {}
            for i = 2, #tsv do
                local r = tsv[i]
                if type(r) == "table" then
                    local pk = parsedOf(r[1])
                    if pk ~= nil then byPk[tostring(pk)] = r end
                end
            end
            for pk, dirtyCols in pairs(rows) do
                local row = byPk[pk]
                if row then
                    badVal.row_key = pk
                    if not recomputeRow(header, unwrap(row), dirtyCols, expr_eval, badVal) then
                        ok = false
                    end
                end
            end
        end
    end
    return ok
end

-- Applies every declared row patch to its target dataset, in package load order.
--
-- `patchPlan` is an array of {file=<full patch file name>, target=<lowercased
-- basename of the parent file, optionally 'package.id:'-qualified>,
-- kind="patch"|"bulk", ifMissing=<missing_policy or nil>} in load
-- order, prepared by the loader (so last-writer-wins is deterministic).
-- `opt_fn2pkg` (tsv_files key -> owning package id) enables the qualified form
-- and the ambiguity diagnostics; an unqualified target matching several loaded
-- files resolves to the alphabetically-first full name with a warning naming
-- every candidate. Returns (ok, patchedTargets) where patchedTargets is a set
-- of full target file names the reformatter must NOT rewrite (so patches are
-- never baked into parent source).
local function applyPatches(tsv_files, patchPlan, loadEnv, badVal, opt_lineage, opt_fn2pkg)
    local patchedTargets = {}
    if not patchPlan or #patchPlan == 0 then
        return true, patchedTargets
    end
    local resolve = newTargetResolver(tsv_files, opt_fn2pkg)
    local expr_eval = expressionEvaluatorGenerator(loadEnv)
    local ok = true
    for _, entry in ipairs(patchPlan) do
        local patchTsv = tsv_files[entry.file]
        if patchTsv then
            local targetName, info = resolve(entry.target)
            if not targetName then
                local reason = info and info.reason
                -- ifMissing tolerance (mod_ecosystem §6): under warn/silent a
                -- missing target file makes this patch file a logged no-op
                -- instead of a load error (multi-version compat patches).
                -- missing_fn2pkg stays a hard error — that is caller misuse,
                -- not a version gap.
                local policy = entry.ifMissing
                if (policy == "warn" or policy == "silent")
                    and reason ~= "missing_fn2pkg" then
                    local msg = entry.file .. ": patch target '" .. entry.target
                        .. "' not found; skipping this patch file (ifMissing="
                        .. policy .. ")"
                    if policy == "warn" then logger:warn(msg) else logger:info(msg) end
                    goto continue
                end
                badVal.source_name = entry.file
                badVal.line_no = 0
                if reason == "not_in_package" then
                    -- info.candidates is the basenames that package owns (empty
                    -- when it is not loaded at all — then no suggestion).
                    badVal(entry.target, "patch target '" .. entry.target
                        .. "': package '" .. info.pkg
                        .. "' is not loaded or owns no such file"
                        .. didYouMean(info.base, info.candidates))
                elseif reason == "missing_fn2pkg" then
                    badVal(entry.target, "patch target '" .. entry.target
                        .. "' is package-qualified, but no file-ownership map"
                        .. " was provided to applyPatches")
                else
                    local knownBases = {}
                    for fn in pairs(tsv_files) do knownBases[basename(fn)] = true end
                    local _, wantBase = splitQualifiedTarget(entry.target)
                    badVal(entry.target, "patch target '" .. entry.target
                        .. "' not found (must match a loaded file by basename,"
                        .. " optionally qualified as 'package.id:Name.tsv')"
                        .. didYouMean(wantBase, knownBases))
                end
                ok = false
            else
                if info and info.ambiguous then
                    local _, targetBase = splitQualifiedTarget(entry.target)
                    logger:warn(entry.file .. ": patch target '" .. entry.target
                        .. "' is ambiguous — candidates: "
                        .. table.concat(info.ambiguous, ", ")
                        .. "; using '" .. targetName
                        .. "' (qualify the target as 'package.id:" .. targetBase
                        .. "' to disambiguate)")
                end
                local applied
                if entry.kind == "bulk" then
                    applied = applyOneBulkPatch(entry.file, patchTsv, targetName,
                        tsv_files[targetName], loadEnv, badVal, opt_lineage, opt_fn2pkg)
                else
                    applied = applyOnePatch(entry.file, patchTsv, targetName,
                        tsv_files[targetName], expr_eval, badVal, opt_lineage, opt_fn2pkg,
                        entry.ifMissing)
                end
                if not applied then
                    ok = false
                end
                patchedTargets[targetName] = true
            end
        end
        ::continue::
    end
    return ok, patchedTargets
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    applyPatches = applyPatches,
    recomputeAfterPatches = recomputeAfterPatches,
    -- Target-resolution helpers, shared with the loader (write-scope
    -- resolution for package processors) and the schema-overlay collector.
    splitQualifiedTarget = splitQualifiedTarget,
    newTargetResolver = newTargetResolver,
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
