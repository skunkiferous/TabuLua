-- Module name
local NAME = "processor_executor"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 19, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly
local unwrap = read_only.unwrap

local sandbox = require("sandbox")

local error_reporting = require("error_reporting")
local nullBadVal = error_reporting.nullBadVal

local predicates = require("predicates")
local string_utils = require("string_utils")
local table_utils = require("table_utils")
local comparators = require("comparators")
local validator_helpers = require("validator_helpers")
local validator_executor = require("validator_executor")
local normalizeValidatorSpec = validator_executor.normalizeValidatorSpec

local parsers = require("parsers")

local logger = require("named_logger").getLogger(NAME)

-- Quota for processor expressions; higher than file validator quota because
-- mutation work is more expensive than pure checking
local PROCESSOR_QUOTA = 50000

-- Default processor priority (lower runs first; matches loadOrder convention)
local DEFAULT_PRIORITY = 100

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

--- Normalises a processor_spec into a consistent record.
--- Mirrors validator_executor.normalizeValidatorSpec but additionally extracts
--- processor-specific fields (priority, rerunAfterPatches).
--- @param spec string|table Either a simple expression string or a record
--- @return table {expr=string, level=string, priority=number, rerunAfterPatches=boolean}
local function normalizeProcessorSpec(spec)
    local base = normalizeValidatorSpec(spec)
    local priority = DEFAULT_PRIORITY
    local rerun = false
    if type(spec) == "table" then
        if type(spec.priority) == "number" then
            priority = spec.priority
        end
        if spec.rerunAfterPatches == true then
            rerun = true
        end
    end
    return {
        expr = base.expr,
        level = base.level,
        priority = priority,
        rerunAfterPatches = rerun,
    }
end

-- ============================================================
-- Writable Row Wrapper
-- ============================================================

-- Hidden association from wrapped row -> {rawRow, header, fileName}
-- Weak keys so wrappers can be GCed once the processor run finishes.
local row_context = setmetatable({}, {__mode = "k"})

--- Wraps a single parsed row for processor access.
--- Reading `wrapped.col` returns the parsed value (like validators), with
--- table values UNWRAPPED so processors can mutate them in place (e.g.
--- `table.insert(target.unlocks, x)` followed by `setCell(target,'unlocks',...)`).
--- Direct assignment (`wrapped.col = v`) errors — `setCell` must be used so
--- the new value passes through the column's parser for type validation.
--- @param row table Read-only row proxy from the parsed dataset
--- @param header table The file header (for column lookup in setCell)
--- @param fileName string Name of the file (for diagnostics)
--- @return table A processor-row proxy
local function wrapRowForProcessor(row, header, fileName)
    local proxy = setmetatable({}, {
        __index = function(_, k)
            local val = row[k]
            if type(val) == "table" and getmetatable(val) == "cell" then
                return unwrap(val.parsed)
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
    }
    return proxy
end

--- Wraps an array of rows. Each entry is a processor-row proxy.
--- @param rows table Array of read-only row proxies
--- @param header table The file header
--- @param fileName string Name of the file
--- @return table Array of processor-row proxies (a plain Lua table)
local function wrapRowsForProcessor(rows, header, fileName)
    local wrapped = {}
    for i, r in ipairs(rows) do
        wrapped[i] = wrapRowForProcessor(r, header, fileName)
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
local function setCellImpl(wrappedRow, column, value)
    local ctx = row_context[wrappedRow]
    if not ctx then
        error("setCell: first argument is not a processor row", 2)
    end
    local header = ctx.header
    -- Header is keyed both by numeric idx and by column name, so the lookup
    -- transparently accepts either form.
    local col = header[column]
    if not col then
        error("setCell: column '" .. tostring(column) .. "' does not exist in header", 2)
    end

    local rawRow = ctx.rawRow
    local rawCell = unwrap(rawRow[col.idx])
    if type(rawCell) ~= "table" then
        error("setCell: cell is missing for column '" .. col.name .. "'", 2)
    end

    if value == nil then
        local ts = col.type_spec
        if not parsers.isNullable(ts) then
            error("setCell: cannot clear column '" .. col.name
                .. "' (type '" .. ts .. "' is not nullable)", 2)
        end
        rawCell[2] = nil
        rawCell[3] = nil
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
    else
        rawCell[2] = value
        rawCell[3] = value
    end
end

--- Builds an O(1) row-by-primary-key lookup for a wrapped row set.
--- The primary key is the first column of each row (the dataset's `__idx`-keyed
--- model uses the same convention). Returns nil for unknown keys.
local function buildRowByKey(wrappedRows)
    local index = {}
    for _, wrapped in ipairs(wrappedRows) do
        local ctx = row_context[wrapped]
        if ctx then
            local cell = ctx.rawRow[1]
            if type(cell) == "table" then
                local key = unwrap(cell.parsed)
                if key == nil then
                    key = unwrap(cell.evaluated)
                end
                if key ~= nil then
                    index[key] = wrapped
                end
            end
        end
    end
    return function(key)
        if key == nil then
            return nil
        end
        return index[key]
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
-- Sandboxed Execution
-- ============================================================

--- Creates the sandbox environment for a processor expression.
--- Reuses the validator's read-only helpers and adds the mutation helpers
--- `setCell`, `clearCell`, `rowByKey`, and `dataIndex`.
--- @param wrappedRows table Array of processor-row proxies (passed as `rows`)
--- @param fileName string Name of the file being processed
--- @param ctx table Writable context shared across processor invocations in this run
--- @param extraEnv table|nil Additional environment variables (contexts, libraries)
--- @return table The sandboxed environment
local function createProcessorEnv(wrappedRows, fileName, ctx, extraEnv)
    local rowByKey = buildRowByKey(wrappedRows)
    local env = {
        -- Lua built-ins
        math = math,
        string = string,
        table = table,
        pairs = pairs,
        ipairs = ipairs,
        type = type,
        tostring = tostring,
        tonumber = tonumber,
        select = select,
        unpack = unpack or table.unpack,
        next = next,
        pcall = pcall,

        -- Safe utilities (mirrors validator env)
        predicates = predicates,
        stringUtils = {
            trim = string_utils.trim,
            split = string_utils.split,
            parseVersion = string_utils.parseVersion,
        },
        tableUtils = {
            keys = table_utils.keys,
            values = table_utils.values,
            pairsCount = table_utils.pairsCount,
        },
        equals = comparators.equals,

        -- Read-side helpers from validator_helpers
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

        -- Write-side helpers
        setCell = function(row, column, value)
            return setCellImpl(row, column, value)
        end,
        clearCell = function(row, column)
            return setCellImpl(row, column, nil)
        end,
        rowByKey = rowByKey,
        dataIndex = dataIndexOf,

        -- Context (writable, shared across processors in this file run)
        ctx = ctx,
        rows = wrappedRows,
        file = wrappedRows,
        fileName = fileName,
    }

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

    for _, entry in ipairs(normalized) do
        local spec = entry.spec
        local env = createProcessorEnv(wrappedRows, fileName, procCtx, extraEnv)
        local ok, msg = executeProcessor(spec.expr, env, PROCESSOR_QUOTA)
        if not ok then
            if spec.level == "warn" then
                warnings[#warnings + 1] = {
                    processor = spec.expr,
                    message = msg,
                    fileName = fileName,
                }
                logger:warn(string.format(
                    "[WARN] Pre-processor warning in %s: %s", fileName, msg))
            else
                badVal.source_name = fileName
                badVal(spec.expr, msg)
                logger:error(string.format(
                    "[ERROR] Pre-processor failed in %s: %s", fileName, msg))
                allOk = false
                -- Continue running remaining processors so all errors surface;
                -- matches validator behaviour of "log and proceed" across specs.
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
