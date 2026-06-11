-- Module name
local NAME = "patch_executor"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 27, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly
local unwrap = read_only.unwrap

local logger = require("named_logger").getLogger(NAME)

local parsers = require("parsers")
local isNullable = parsers.isNullable

local tsv_model = require("tsv_model")
local newDataCell = tsv_model.newDataCell
local newDataRow = tsv_model.newDataRow
local expressionEvaluatorGenerator = tsv_model.expressionEvaluatorGenerator

local validator_executor = require("validator_executor")
local wrapRowsForValidation = validator_executor.wrapRowsForValidation
local evaluateInValidatorEnv = validator_executor.evaluateInValidatorEnv

-- Operation quota for a tier-B `where` / transform expression (per evaluation).
local BULK_QUOTA = 10000

-- ============================================================
-- Tier-A row patches (see TODO/mod_overrides.md §4, Phase 2).
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
-- already-typed value (a tier-A patch cell or a tier-B `=expr` result), "tsv" for
-- a raw literal string (a tier-B literal transform cell). A nil value clears the
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

-- Applies an `update` patch row's non-empty cells to an existing parent row,
-- in place. Empty patch cells leave the target unchanged; a non-empty cell with
-- a nil value (e.g. `=nil`) clears the column (requires a nullable parent type).
local function applyUpdate(rowProxy, patchRow, patchHeader, targetHeader,
    skipIdx, badVal)
    local rawRow = unwrap(rowProxy)
    local ok = true
    for _, patchCol in ipairs(patchHeader) do
        if not skipIdx[patchCol.idx] then
            local patchCell = patchRow[patchCol.idx]
            if not isEmptyCell(patchCell) then
                local targetCol = targetHeader[patchCol.name]
                badVal.col_name = patchCol.name
                if not targetCol then
                    logger:warn(badVal.source_name .. ": patch column '"
                        .. patchCol.name .. "' has no matching column in the target"
                        .. " file (ignored)")
                elseif not setCellRaw(rawRow, targetCol, parsedOf(patchCell),
                    "parsed", badVal, "update") then
                    ok = false
                end
            end
        end
    end
    return ok
end

-- Applies one patch file's rows to its target dataset (mutating the target's
-- underlying array). Returns true if all error-level ops succeeded.
local function applyOnePatch(patchFileName, patchTsv, targetName, targetTsv,
    expr_eval, badVal)
    local patchHeader = patchTsv[1]
    local targetHeader = targetTsv[1]
    badVal.source_name = patchFileName
    badVal.line_no = 0
    badVal.col_idx = 0

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
                    else
                        ok = false
                    end
                end
            elseif op == "remove" then
                if not byPk[pkStr] then
                    logger:warn(patchFileName .. " line " .. i .. ": patchOp=remove"
                        .. " key '" .. pkStr .. "' not found in target (no-op)")
                else
                    -- Tombstone the slot; compaction drops it after the loop.
                    removedIdx[idxByPk[pkStr]] = true
                    anyRemoved = true
                    byPk[pkStr] = nil
                    idxByPk[pkStr] = nil
                end
            elseif op == "update" then
                local existing = byPk[pkStr]
                if not existing then
                    badVal(pkStr, "patchOp=update: key '" .. pkStr
                        .. "' not found in target '" .. basename(targetName) .. "'")
                    ok = false
                else
                    if not applyUpdate(existing, patchRow, patchHeader,
                        targetHeader, skipIdx, badVal) then
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

-- Applies one tier-B bulk/filter patch file to its target (mod_overrides.md §5).
-- Each rule row carries a unique rule name (column 1), a `patchOp` (update |
-- remove), a `where` selector expression, and — for update rules — transform
-- cells. `where` is evaluated per parent row in the validator sandbox (truthy =
-- match, with `self`/`row`/`rows`/helpers/published contexts); matched rows are
-- removed (deferred + compaction, like tier A) or have each non-empty transform
-- cell applied. A transform cell starting with `=` is an expression evaluated
-- against the matched target row; otherwise it is a literal parsed by the parent
-- column. Returns true if all error-level rules/cells succeeded.
local function applyOneBulkPatch(bulkFileName, bulkTsv, targetName, targetTsv,
    loadEnv, badVal)
    local bulkHeader = bulkTsv[1]
    local targetHeader = targetTsv[1]
    badVal.source_name = bulkFileName
    badVal.line_no = 0
    badVal.col_idx = 0

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
                                            end
                                        elseif not setCellRaw(unwrap(dataRows[i]),
                                            parentCol, raw, "tsv", badVal, "bulk update") then
                                            ok = false
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

-- Applies every declared row patch to its target dataset, in package load order.
--
-- `patchPlan` is an array of {file=<full patch file name>, target=<lowercased
-- basename of the parent file>} in load order, prepared by the loader (so
-- last-writer-wins is deterministic). Returns (ok, patchedTargets) where
-- patchedTargets is a set of full target file names the reformatter must NOT
-- rewrite (so patches are never baked into parent source — §7.1).
local function applyPatches(tsv_files, patchPlan, loadEnv, badVal)
    local patchedTargets = {}
    if not patchPlan or #patchPlan == 0 then
        return true, patchedTargets
    end
    -- Precompute basename -> full tsv_files key once, so each patch entry resolves
    -- its target in O(1) instead of rescanning every loaded file per entry. On a
    -- basename collision the last file wins (arbitrary, as before).
    local basenameToFile = {}
    for fn in pairs(tsv_files) do
        basenameToFile[basename(fn)] = fn
    end
    local expr_eval = expressionEvaluatorGenerator(loadEnv)
    local ok = true
    for _, entry in ipairs(patchPlan) do
        local patchTsv = tsv_files[entry.file]
        if patchTsv then
            local targetName = basenameToFile[entry.target]
            if not targetName then
                badVal.source_name = entry.file
                badVal.line_no = 0
                badVal(entry.target, "patch target '" .. entry.target
                    .. "' not found (must match a loaded file by basename)")
                ok = false
            else
                local applied
                if entry.kind == "bulk" then
                    applied = applyOneBulkPatch(entry.file, patchTsv, targetName,
                        tsv_files[targetName], loadEnv, badVal)
                else
                    applied = applyOnePatch(entry.file, patchTsv, targetName,
                        tsv_files[targetName], expr_eval, badVal)
                end
                if not applied then
                    ok = false
                end
                patchedTargets[targetName] = true
            end
        end
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
