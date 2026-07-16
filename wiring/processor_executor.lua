-- Module name
local NAME = "processor_executor"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 32, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly
local unwrap = read_only.unwrap

-- Optional patch-lineage recording for package-scoped processor writes (for
-- --explain-patch).
local patch_lineage = require("overrides.patch_lineage")
local lineageValueStr = patch_lineage.valueStr

local sandbox = require("sandbox")
local sandbox_env = require("infra.sandbox_env")

local error_reporting = require("infra.error_reporting")
local nullBadVal = error_reporting.nullBadVal
local didYouMean = error_reporting.didYouMean

local table_utils = require("util.table_utils")
local deepCopyUnwrapped = table_utils.deepCopyUnwrapped
local validator_helpers = require("wiring.validator_helpers")
local validator_executor = require("wiring.validator_executor")
local normalizeValidatorSpec = validator_executor.normalizeValidatorSpec

local parsers = require("parsers")

-- Type-wiring registry: feature modules contribute extra sandbox helpers
-- via registerModule(...).sandboxHelpers.processor. We do NOT require
-- builtin_wiring here, because builtin_wiring requires processor_executor
-- (it references our graph completion functions in the registry slot
-- below) — pulling builtin_wiring in would create a circular dependency.
-- The registry is fine with partial loads: each module contributes
-- additively under the same moduleName as builtin_wiring does.
local type_wiring = require("wiring.type_wiring")

local logger = require("infra.named_logger").getLogger(NAME)

-- The processor read-side helper block (identical set to the validator
-- sandbox). Shared, never-mutated reference table merged into every processor
-- sandbox env alongside sandbox_env's safe builtins / utilities. Built-in
-- helpers go here; registry-contributed helpers (e.g. completeBasicGraph
-- and completeDirectedGraph) are merged in AFTER this module's local
-- functions are defined — see the registerModule + merge block lower
-- down. PROCESSOR_READ_HELPERS is forward-referenced from createProcessorEnv
-- so the merge must run before the first env is built.
local PROCESSOR_READ_HELPERS = {
    unique = validator_helpers.unique,
    sum = validator_helpers.sum,
    min = validator_helpers.min,
    max = validator_helpers.max,
    avg = validator_helpers.avg,
    count = validator_helpers.count,
    all = validator_helpers.all,
    any = validator_helpers.any,
    none = validator_helpers.none,
    filter = validator_helpers.filter,
    find = validator_helpers.find,
    lookup = validator_helpers.lookup,
    groupBy = validator_helpers.groupBy,
    listMembersOfTag = validator_helpers.listMembersOfTag,
    isMemberOfTag = validator_helpers.isMemberOfTag,
}

-- Quota for processor expressions; higher than file validator quota because
-- mutation work is more expensive than pure checking
local PROCESSOR_QUOTA = 50000

-- Extra quota granted per data row, so processors that legitimately touch
-- every row (e.g. the auto-wired graph completion pass) scale with file
-- size instead of failing on large files, while runaway expressions still
-- hit a bound proportional to the work they were given
local PROCESSOR_QUOTA_PER_ROW = 10000

-- Default processor priority (lower runs first; matches loadOrder convention)
local DEFAULT_PRIORITY = 100

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

--- Normalises a processor_spec into a consistent record.
--- Mirrors validator_executor.normalizeValidatorSpec but additionally extracts
--- processor-specific fields (priority, rerunAfterPatches, requires).
--- @param spec string|table Either a simple expression string or a record
--- @return table {expr=string, level=string, priority=number, rerunAfterPatches=boolean, requires=table}
local function normalizeProcessorSpec(spec)
    local base = normalizeValidatorSpec(spec)
    local priority = DEFAULT_PRIORITY
    local rerun = false
    local requires = {}
    if type(spec) == "table" then
        if type(spec.priority) == "number" then
            priority = spec.priority
        end
        if spec.rerunAfterPatches == true then
            rerun = true
        end
        -- `requires` is a list of package ids that must have run their
        -- package-scoped processors before this one. Only meaningful at
        -- package scope; ignored (but harmless) on file-level processors.
        if type(spec.requires) == "table" then
            for _, pid in ipairs(spec.requires) do
                requires[#requires + 1] = pid
            end
        end
    end
    return {
        expr = base.expr,
        level = base.level,
        priority = priority,
        rerunAfterPatches = rerun,
        requires = requires,
    }
end

-- ============================================================
-- Writable Row Wrapper
-- ============================================================

-- Hidden association from wrapped row -> {rawRow, header, fileName}
-- Weak keys so wrappers can be GCed once the processor run finishes.
local row_context = setmetatable({}, {__mode = "k"})

--- Wraps a single parsed row for processor access.
--- Reading `wrapped.col` returns the parsed value READ-ONLY, exactly like a
--- validator row — collection-valued cells cannot be mutated in place. The
--- only way to change a cell is `setCell(row, column, value)`, which re-parses
--- the value through the column's type and so keeps every data write both
--- type-validated and traceable. To change a collection, deep-copy it with the
--- `copy` helper, mutate the copy, then install it via `setCell`.
--- Direct assignment (`wrapped.col = v`) errors for the same reason.
--- @param row table Read-only row proxy from the parsed dataset
--- @param header table The file header (for column lookup in setCell)
--- @param fileName string Name of the file (for diagnostics)
--- @param writable boolean|nil Whether setCell is permitted on this row. nil
---   means writable (the per-file processor case); package-scoped processors pass
---   false for files outside the package's write scope.
--- @return table A processor-row proxy
local function wrapRowForProcessor(row, header, fileName, writable)
    local proxy = setmetatable({}, {
        __index = function(_, k)
            local val = row[k]
            if type(val) == "table" and getmetatable(val) == "cell" then
                return val.parsed
            end
            return val
        end,
        __newindex = function()
            error("attempt to assign to a processor row directly; use setCell(row, column, value)", 2)
        end,
        __metatable = "processor_row",
    })
    row_context[proxy] = {
        row = row,
        rawRow = unwrap(row),
        header = header,
        fileName = fileName,
        writable = writable ~= false,
    }
    return proxy
end

--- Wraps an array of rows. Each entry is a processor-row proxy.
---
--- The result is a plain Lua array that also mirrors the dataset's PK
--- index: `wrapped[pkValue]` returns the wrapped row for that PK in O(1),
--- so `rowByKey` and graph helpers do not need to rebuild a name→row map.
--- PK is taken from column 1 (per the tsv_model convention; see
--- [tsv_model.lua](tsv_model.lua) opt_index) and tostring-normalised so a
--- numeric-typed PK does not collide with positional indexing.
--- @param rows table Array of read-only row proxies
--- @param header table The file header
--- @param fileName string Name of the file
--- @return table Array of processor-row proxies (a plain Lua table)
local function wrapRowsForProcessor(rows, header, fileName, writable)
    local wrapped = {}
    for i, r in ipairs(rows) do
        local wrappedRow = wrapRowForProcessor(r, header, fileName, writable)
        wrapped[i] = wrappedRow
        local pkCell = r[1]
        if type(pkCell) == "table" and getmetatable(pkCell) == "cell" then
            local pk = pkCell.parsed
            if pk == nil then pk = pkCell.evaluated end
            if pk ~= nil and type(pk) ~= "table" then
                pk = tostring(pk)
                if wrapped[pk] == nil then wrapped[pk] = wrappedRow end
            end
        end
    end
    return wrapped
end

-- ============================================================
-- Mutation Helpers
-- ============================================================

--- Sets a parsed value on a cell of a wrapped row.
--- The value is run through the column's parser in "parsed" context for type
--- validation. Errors (unknown column, type rejection, non-nullable clear) are
--- raised as plain Lua errors so they propagate up to the per-processor pcall
--- in executeProcessor, which converts them into a clean diagnostic via badVal
--- AFTER the sandbox has exited (avoids the sandbox's `string.rep`-nilling
--- breaking the logging path).
--- The cell's `.parsed` and `.evaluated` are updated; the cell's `.value` and
--- `.reformatted` are intentionally left untouched so that the reformatter
--- preserves the original on-disk text.
--- @param wrappedRow table Processor-row proxy
--- @param column string|number Column name or index
--- @param value any New parsed value (or nil for clearCell)
--- @param opt_linCtx table|nil {lineage, source} — when set (package-scoped
---   package-scoped runs only), record the write for `--explain-patch`.
local function setCellImpl(wrappedRow, column, value, opt_linCtx)
    local ctx = row_context[wrappedRow]
    if not ctx then
        error("setCell: first argument is not a processor row", 2)
    end
    -- Write scoping: a package-scoped processor may only
    -- mutate files the package owns or has declared patches for. Rows of other
    -- files are wrapped read-only and rejected here.
    if ctx.writable == false then
        error("setCell: file '" .. tostring(ctx.fileName)
            .. "' is outside this package's write scope (not owned and not patched by it)", 2)
    end
    local header = ctx.header
    -- Header is keyed both by numeric idx and by column name, so the lookup
    -- transparently accepts either form.
    local col = header[column]
    if not col then
        -- Header is keyed by both idx and name; suggest from the name keys.
        local names = {}
        for k in pairs(header) do
            if type(k) == "string" then names[#names + 1] = k end
        end
        error("setCell: column '" .. tostring(column)
            .. "' does not exist in header" .. didYouMean(column, names), 2)
    end

    local rawRow = ctx.rawRow
    local rawCell = unwrap(rawRow[col.idx])
    if type(rawCell) ~= "table" then
        error("setCell: cell is missing for column '" .. col.name .. "'", 2)
    end

    -- Records the write to the patch lineage (package-scoped runs only).
    local function rec(written)
        if opt_linCtx then
            local pk = wrappedRow[1]
            opt_linCtx.lineage:cell(
                (ctx.fileName:match("[/\\]([^/\\]+)$") or ctx.fileName):lower(),
                tostring(pk), col.name, "= " .. lineageValueStr(written), opt_linCtx.source)
        end
    end

    if value == nil then
        local ts = col.type_spec
        if not parsers.isNullable(ts) then
            error("setCell: cannot clear column '" .. col.name
                .. "' (type '" .. ts .. "' is not nullable)", 2)
        end
        rawCell[2] = nil
        rawCell[3] = nil
        rec(nil)
        return
    end

    if col.parser then
        local parsed, _reformatted = col.parser(nullBadVal, value, "parsed")
        if parsed == nil then
            error("setCell: value for column '" .. col.name
                .. "' is not a valid '" .. col.type_spec .. "'", 2)
        end
        rawCell[2] = parsed
        rawCell[3] = parsed
        rec(parsed)
    else
        rawCell[2] = value
        rawCell[3] = value
        rec(value)
    end
end

--- Returns an O(1) row-by-primary-key lookup closure for a wrapped row set.
--- The wrapped row array is itself PK-indexed by `wrapRowsForProcessor`
--- (see above), so this is just a typed lookup over it. Keys are converted
--- via tostring to match the indexing convention.
local function buildRowByKey(wrappedRows)
    return function(key)
        if key == nil then
            return nil
        end
        return wrappedRows[type(key) == "string" and key or tostring(key)]
    end
end

--- Returns the 1-based data-row position of a wrapped row (excludes header).
local function dataIndexOf(wrappedRow)
    local ctx = row_context[wrappedRow]
    if not ctx then
        return nil
    end
    local idx = ctx.rawRow.__idx
    if type(idx) ~= "number" then
        return nil
    end
    -- __idx is the 1-based raw TSV line index including header; subtract one
    -- to get the 1-based data-row index expected by processor authors.
    return idx - 1
end

-- ============================================================
-- Graph completion (auto-wired pre-processors)
--
-- These are invoked from the auto-wired pre-processor entries that
-- graph_wiring attaches to graph-family files. They symmetrise the
-- link fields:
--   basic:    A.graphLinks ⊇ {B}  ⇒  B.graphLinks ⊇ {A}
--   directed: A.graphChildren ⊇ {B}  ⇒  B.graphParents ⊇ {A}, and vice versa.
-- Dangling references (link to a name not in the file) are skipped
-- silently — the refs-exist validator (Phase A4) flags them separately.
-- ============================================================

-- Returns true if list contains value (linear scan; lists are typically
-- small in graph data — single-digit neighbours).
local function listContains(list, value)
    if list == nil then return false end
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

-- Builds a name -> wrapped-row index from the underlying PK column.
-- Reuses the same convention as buildRowByKey.
local function ensureBackLink(targetRow, columnName, valueToAdd)
    local existing = targetRow[columnName]
    if listContains(existing, valueToAdd) then return end
    local updated = deepCopyUnwrapped(existing) or {}
    updated[#updated + 1] = valueToAdd
    setCellImpl(targetRow, columnName, updated)
end

--- Completes a basic (undirected) graph: for every (r, n) link, ensures
--- n has r back in its graphLinks. Self-loops (A ↔ A) are left untouched
--- since they are already symmetric.
local function completeBasicGraph(wrappedRows)
    if not wrappedRows or #wrappedRows == 0 then return end
    local rowByKey = buildRowByKey(wrappedRows)
    for _, r in ipairs(wrappedRows) do
        local links = r.graphLinks
        if links then
            local rName = r.name
            for _, nbrName in ipairs(links) do
                if nbrName ~= rName then
                    local nbr = rowByKey(nbrName)
                    if nbr then
                        ensureBackLink(nbr, "graphLinks", rName)
                    end
                end
            end
        end
    end
end

--- Completes a directed graph: for every parent→child edge, ensures the
--- back-reference exists on both ends. Iterates children-first then
--- parents-first so authors can declare an edge from either side.
local function completeDirectedGraph(wrappedRows)
    if not wrappedRows or #wrappedRows == 0 then return end
    local rowByKey = buildRowByKey(wrappedRows)
    -- Pass 1: graphChildren -> graphParents back-references.
    for _, r in ipairs(wrappedRows) do
        local children = r.graphChildren
        if children then
            local rName = r.name
            for _, childName in ipairs(children) do
                local child = rowByKey(childName)
                if child then
                    ensureBackLink(child, "graphParents", rName)
                end
            end
        end
    end
    -- Pass 2: graphParents -> graphChildren back-references. We re-read
    -- graphParents here so we pick up the additions from pass 1 (otherwise
    -- a parent declared only via the child side wouldn't gain its child
    -- back-reference).
    for _, r in ipairs(wrappedRows) do
        local parents = r.graphParents
        if parents then
            local rName = r.name
            for _, parentName in ipairs(parents) do
                local parent = rowByKey(parentName)
                if parent then
                    ensureBackLink(parent, "graphChildren", rName)
                end
            end
        end
    end
end

-- Register the graph completion helpers under the "graph_wiring" module
-- so wired processor expressions like "completeBasicGraph(rows)" resolve
-- at expression-eval time. We register here (not in builtin_wiring)
-- because builtin_wiring requires processor_executor for these refs;
-- doing it in builtin_wiring would create a circular dependency.
type_wiring.registerModule("graph_wiring", {
    sandboxHelpers = {
        processor = {
            completeBasicGraph    = completeBasicGraph,
            completeDirectedGraph = completeDirectedGraph,
        },
    },
})

-- Merge registry-contributed processor helpers (graph completion helpers
-- registered above, plus any future feature-module additions) into
-- PROCESSOR_READ_HELPERS. Name collisions with the built-in block are a
-- registration error.
for name, fn in pairs(type_wiring.sandboxAdditions().processor) do
    if PROCESSOR_READ_HELPERS[name] ~= nil and PROCESSOR_READ_HELPERS[name] ~= fn then
        error("processor_executor: type-wiring registry helper '" .. name
            .. "' conflicts with a built-in processor helper of the same name", 0)
    end
    PROCESSOR_READ_HELPERS[name] = fn
end

-- ============================================================
-- Sandboxed Execution
-- ============================================================

--- Creates the sandbox environment for a processor expression.
--- The safe builtins, `math`, the curated `string`/`table` subsets and the
--- TabuLua helper block come from `sandbox_env`; this function adds the
--- validator read-side helpers, the mutation helpers `setCell`, `clearCell`,
--- `rowByKey`, `dataIndex`, the `copy` deep-clone helper, and the per-run
--- context (`rows`, `file`, `fileName`, `ctx`).
--- @param wrappedRows table Array of processor-row proxies (passed as `rows`)
--- @param fileName string Name of the file being processed
--- @param ctx table Writable context shared across processor invocations in this run
--- @param extraEnv table|nil Additional environment variables (contexts, libraries)
--- @return table The sandboxed environment
local function createProcessorEnv(wrappedRows, fileName, ctx, extraEnv)
    local rowByKey = buildRowByKey(wrappedRows)
    local env = sandbox_env.new(PROCESSOR_READ_HELPERS)

    -- Write-side helpers
    env.setCell = function(row, column, value)
        return setCellImpl(row, column, value)
    end
    env.clearCell = function(row, column)
        return setCellImpl(row, column, nil)
    end
    env.rowByKey = rowByKey
    env.dataIndex = dataIndexOf
    -- Returns a fresh, fully-mutable deep copy of a (read-only) value, so a
    -- processor can build a changed collection and install it via setCell --
    -- the single audited, type-validated write path.
    env.copy = function(v)
        return deepCopyUnwrapped(v)
    end
    -- Graph-family completion entry points (auto-wired through the
    -- type-wiring registry — see the registerModule call above). User
    -- expressions that want to re-complete can call them too, but must
    -- pass `rows` explicitly (the registry doesn't inject a default).

    -- Context (writable, shared across processors in this file run)
    env.ctx = ctx
    env.rows = wrappedRows
    env.file = wrappedRows
    env.fileName = fileName

    if extraEnv then
        for k, v in pairs(extraEnv) do
            if env[k] == nil then
                env[k] = v
            end
        end
    end

    return env
end

-- Cleans up Lua sandbox error messages by removing internal file paths and
-- [string "..."] notation so failures look the same on every machine.
-- Same approach as tsv_model.sanitizeSandboxError.
local function sanitizeSandboxError(err)
    if type(err) ~= "string" then
        return tostring(err)
    end
    local cleaned = err:gsub("[%a]?:?[^%s]*sandbox%.lua:%d+:%s*", "")
    cleaned = cleaned:gsub('%[string "[^"]*"%]:%d+:%s*', "")
    cleaned = cleaned:match("^%s*(.-)%s*$")
    if cleaned == "" then
        return err
    end
    return cleaned
end

--- Executes a single processor expression in a sandbox.
--- A processor's return value is generally ignored, but to match the validator
--- contract, an explicit `false` or string return is treated as a failure for
--- diagnostics (logged at the configured level). Mutations performed before the
--- failure are kept (matches validator state-not-rolled-back behaviour).
--- @return boolean isOk True if the processor executed without raising
--- @return string|nil errorMessage Error/warning message if reported, else nil
local function executeProcessor(expr, env, quota)
    local code = "return (" .. expr .. ")"
    local opt = {quota = quota, env = env}
    local ok, protected = pcall(sandbox.protect, code, opt)
    if not ok then
        return false, "failed to compile processor: " .. sanitizeSandboxError(protected)
    end

    local exec_ok, result = pcall(protected)
    if not exec_ok then
        return false, "processor execution error: " .. sanitizeSandboxError(result)
    end

    -- Same convention as validators: false / non-empty string => failure
    if result == false then
        return false, "processor failed"
    elseif type(result) == "string" and result ~= "" then
        return false, result
    end
    return true, nil
end

--- Runs all pre-processors on a file's data rows in priority order.
--- Mutations are applied directly to the underlying cells (`cell.parsed`),
--- so later processors see earlier processors' writes, and so do subsequent
--- validators after `runFilePreProcessors` returns.
--- @param processors table Array of processor_spec records
--- @param rows table Array of read-only data rows (no header)
--- @param header table The file header (column descriptors)
--- @param fileName string Name of the file being processed
--- @param badVal table Error reporting object
--- @param extraEnv table|nil Additional environment variables (contexts, libraries)
--- @return boolean ok True if all error-level processors completed without failure
--- @return table Array of warning messages
local function runFilePreProcessors(processors, rows, header, fileName, badVal, extraEnv)
    if not processors or #processors == 0 then
        return true, {}
    end

    local normalized = {}
    for i, spec in ipairs(processors) do
        normalized[i] = {spec = normalizeProcessorSpec(spec), originalIdx = i}
    end
    table.sort(normalized, function(a, b)
        if a.spec.priority == b.spec.priority then
            return a.originalIdx < b.originalIdx
        end
        return a.spec.priority < b.spec.priority
    end)

    local wrappedRows = wrapRowsForProcessor(rows, header, fileName)
    local procCtx = {}
    local warnings = {}
    local allOk = true
    local quota = PROCESSOR_QUOTA + PROCESSOR_QUOTA_PER_ROW * #rows

    for _, entry in ipairs(normalized) do
        local spec = entry.spec
        local env = createProcessorEnv(wrappedRows, fileName, procCtx, extraEnv)
        local ok, msg = executeProcessor(spec.expr, env, quota)
        if not ok then
            if spec.level == "warn" then
                warnings[#warnings + 1] = {
                    processor = spec.expr,
                    message = msg,
                    fileName = fileName,
                }
                logger:warn(string.format(
                    "Pre-processor warning in %s: %s", fileName, msg))
            else
                badVal.source_name = fileName
                badVal(spec.expr, msg)
                logger:error(string.format(
                    "Pre-processor failed in %s: %s", fileName, msg))
                allOk = false
                -- Continue running remaining processors so all errors surface;
                -- matches validator behaviour of "log and proceed" across specs.
            end
        end
    end

    return allOk, warnings
end

-- ============================================================
-- Package-scoped pre-processors (mod overrides)
-- ============================================================

--- Returns the subset of `processors` whose normalized spec has
--- `rerunAfterPatches = true`. Used by the cross-package phase to re-run the
--- parent's own idempotent file processors against the patched data. Preserves
--- textual order; the caller (or runFilePreProcessors) re-applies priority sorting.
--- @param processors table|nil Array of processor_spec records
--- @return table Array of the rerun-flagged specs (possibly empty)
local function selectRerunProcessors(processors)
    local result = {}
    if not processors then
        return result
    end
    for _, spec in ipairs(processors) do
        if normalizeProcessorSpec(spec).rerunAfterPatches then
            result[#result + 1] = spec
        end
    end
    return result
end

--- Builds the per-package wrapped-file map. Each entry of `fileEntries` is
--- `{rows, header, fileName, writable}`; the result maps the same key to a
--- PK-indexed array of processor-row proxies. Rows of non-writable files are
--- wrapped read-only so setCell on them is rejected by setCellImpl (write scoping).
--- @param fileEntries table Map of fileKey -> {rows, header, fileName, writable}
--- @return table Map of fileKey -> wrapped (PK-indexed) row array
local function wrapPackageFiles(fileEntries)
    local wrappedFiles = {}
    for key, entry in pairs(fileEntries) do
        wrappedFiles[key] = wrapRowsForProcessor(
            entry.rows, entry.header, entry.fileName, entry.writable)
    end
    return wrappedFiles
end

--- Creates the sandbox environment for a package-scoped processor expression.
--- Unlike the per-file env this exposes `files` (the whole loaded set, keyed the
--- same way package validators key it) rather than a single `rows`, plus the
--- scoped write helpers and `rowByKey(file, key)`.
--- @param wrappedFiles table Map of fileKey -> wrapped row array
--- @param packageId string The owning package id (for diagnostics / `packageId`)
--- @param ctx table Writable context shared across this package's processors
--- @param extraEnv table|nil Additional environment variables (contexts, libraries)
--- @param opt_linCtx table|nil {lineage, source} for `--explain-patch` recording
--- @return table The sandboxed environment
local function createPackageProcessorEnv(wrappedFiles, packageId, ctx, extraEnv, opt_linCtx)
    local env = sandbox_env.new(PROCESSOR_READ_HELPERS)

    env.setCell = function(row, column, value)
        return setCellImpl(row, column, value, opt_linCtx)
    end
    env.clearCell = function(row, column)
        return setCellImpl(row, column, nil, opt_linCtx)
    end
    env.copy = function(v)
        return deepCopyUnwrapped(v)
    end
    -- O(1) primary-key lookup into any visible file. `file` is either the file
    -- key (string) or a wrapped-file array; the wrapped arrays are themselves
    -- PK-indexed by wrapRowsForProcessor, so this is just a typed lookup.
    env.rowByKey = function(file, key)
        local arr = file
        if type(file) == "string" then
            arr = wrappedFiles[file]
        end
        if type(arr) ~= "table" or key == nil then
            return nil
        end
        return arr[type(key) == "string" and key or tostring(key)]
    end
    env.dataIndex = dataIndexOf

    env.ctx = ctx
    env.files = wrappedFiles
    env.package = wrappedFiles
    env.packageId = packageId

    if extraEnv then
        for k, v in pairs(extraEnv) do
            if env[k] == nil then
                env[k] = v
            end
        end
    end

    return env
end

--- Runs a single package's package-scoped pre-processors, in priority order, against
--- the already-loaded-and-patched file set. Mutations go through the scoped
--- setCell, so a processor can only write files the package owns or patched.
--- Cross-package ordering (load order + `requires`) is the caller's concern;
--- this function only orders one package's own processors by priority.
--- @param processors table Array of processor_spec records (this package's)
--- @param fileEntries table Map of fileKey -> {rows, header, fileName, writable}
--- @param packageId string The owning package id
--- @param badVal table Error reporting object
--- @param extraEnv table|nil Additional environment variables
--- @return boolean ok True if every error-level processor succeeded
--- @return table Array of warning messages
local function runPackagePreProcessors(processors, fileEntries, packageId, badVal, extraEnv, opt_lineage)
    if not processors or #processors == 0 then
        return true, {}
    end

    local normalized = {}
    for i, spec in ipairs(processors) do
        normalized[i] = {spec = normalizeProcessorSpec(spec), originalIdx = i}
    end
    table.sort(normalized, function(a, b)
        if a.spec.priority == b.spec.priority then
            return a.originalIdx < b.originalIdx
        end
        return a.spec.priority < b.spec.priority
    end)

    local wrappedFiles = wrapPackageFiles(fileEntries)
    local procCtx = {}
    local warnings = {}
    local allOk = true
    local totalRows = 0
    for _, entry in pairs(fileEntries) do
        totalRows = totalRows + #entry.rows
    end
    local quota = PROCESSOR_QUOTA + PROCESSOR_QUOTA_PER_ROW * totalRows
    local label = "package:" .. tostring(packageId)
    -- A package-scoped processor's writes are attributed to its package in the lineage.
    local linCtx = opt_lineage and {lineage = opt_lineage, source = label}

    for _, entry in ipairs(normalized) do
        local spec = entry.spec
        local env = createPackageProcessorEnv(wrappedFiles, packageId, procCtx, extraEnv, linCtx)
        local ok, msg = executeProcessor(spec.expr, env, quota)
        if not ok then
            if spec.level == "warn" then
                warnings[#warnings + 1] = {
                    processor = spec.expr,
                    message = msg,
                    packageId = packageId,
                }
                logger:warn(string.format(
                    "Package pre-processor warning in %s: %s", label, msg))
            else
                badVal.source_name = label
                badVal(spec.expr, msg)
                logger:error(string.format(
                    "Package pre-processor failed in %s: %s", label, msg))
                allOk = false
            end
        end
    end

    return allOk, warnings
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    normalizeProcessorSpec = normalizeProcessorSpec,
    runFilePreProcessors = runFilePreProcessors,
    runPackagePreProcessors = runPackagePreProcessors,
    selectRerunProcessors = selectRerunProcessors,
    -- Quota exposed for testing/customization
    PROCESSOR_QUOTA = PROCESSOR_QUOTA,
    DEFAULT_PRIORITY = DEFAULT_PRIORITY,
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
