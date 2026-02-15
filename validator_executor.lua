-- Module name
local NAME = "validator_executor"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 8, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local sandbox = require("sandbox")
local serialization = require("serialization")
local serializeInSandbox = serialization.serializeInSandbox

local predicates = require("predicates")
local string_utils = require("string_utils")
local table_utils = require("table_utils")
local comparators = require("comparators")
local validator_helpers = require("validator_helpers")

local logger = require("named_logger").getLogger(NAME)

-- ============================================================
-- Row Wrapping for Validators
-- ============================================================

--- Wraps a single row so that accessing a column returns the parsed value
--- directly, instead of the internal cell object. This makes validator code
--- consistent with cell expressions, where `self.colName` returns the parsed value.
--- @param row table The raw row (read-only, containing cell objects)
--- @return table A proxy that auto-unwraps cells to their parsed values
local function wrapRowForValidation(row)
    return setmetatable({}, {
        __index = function(_, k)
            local val = row[k]
            if type(val) == "table" and getmetatable(val) == "cell" then
                return val.parsed
            end
            return val
        end,
        __newindex = function()
            error("attempt to update a read-only row", 2)
        end,
    })
end

--- Wraps an array of rows eagerly (so that ipairs works).
--- @param rows table Array of raw rows
--- @return table Array of wrapped rows
local function wrapRowsForValidation(rows)
    local wrapped = {}
    for i, row in ipairs(rows) do
        wrapped[i] = wrapRowForValidation(row)
    end
    return wrapped
end

--- Wraps a files map (filename -> rows array) for package validators.
--- @param files table Map of file names to their row arrays
--- @return table Map with wrapped row arrays
local function wrapFilesForValidation(files)
    local wrapped = {}
    for name, rows in pairs(files) do
        wrapped[name] = wrapRowsForValidation(rows)
    end
    return wrapped
end

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- Default quotas for different validator types
local ROW_VALIDATOR_QUOTA = 1000
local FILE_VALIDATOR_QUOTA = 10000
local PACKAGE_VALIDATOR_QUOTA = 100000

--- Normalizes a validator_spec into a consistent record format.
--- @param spec string|table Either a simple expression string or {expr, level} record
--- @return table Normalized record {expr=string, level="error"|"warn"}
local function normalizeValidatorSpec(spec)
    if type(spec) == "string" then
        return {expr = spec, level = "error"}
    elseif type(spec) == "table" then
        return {
            expr = spec.expr or spec[1],
            level = spec.level or "error"
        }
    else
        return {expr = tostring(spec), level = "error"}
    end
end

--- Creates a sandboxed environment for validator execution.
--- @param context table The context to expose as 'self' and other variables
--- @param extraEnv table|nil Additional environment variables to include
--- @return table The sandboxed environment
local function createValidatorEnv(context, extraEnv)
    local env = {
        -- The context (self, row, rows, files, etc.)
        self = context.self,

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

        -- Safe utilities
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

        -- Validator helper functions
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
        -- Type introspection helpers
        listMembersOfTag = validator_helpers.listMembersOfTag,
        isMemberOfTag = validator_helpers.isMemberOfTag,
    }

    -- Add any extra context variables
    if extraEnv then
        for k, v in pairs(extraEnv) do
            env[k] = v
        end
    end

    -- Add context-specific aliases
    if context.row then env.row = context.row end
    if context.self then env.self = context.self end
    if context.rows then env.rows = context.rows end
    if context.file then env.file = context.file end
    if context.files then env.files = context.files end
    if context.package then env.package = context.package end
    if context.rowIndex then env.rowIndex = context.rowIndex end
    if context.fileName then env.fileName = context.fileName end
    if context.packageId then env.packageId = context.packageId end
    if context.ctx then env.ctx = context.ctx end

    return env
end

--- Interprets the result of a validator expression.
--- @param result any The result from evaluating the validator expression
--- @return boolean isValid True if validation passed
--- @return string|nil errorMessage Error/warning message if validation failed
local function interpretValidatorResult(result)
    if result == true or result == "" then
        -- Valid
        return true, nil
    elseif result == false or result == nil then
        -- Invalid with default message
        return false, "validation failed"
    elseif type(result) == "string" and result ~= "" then
        -- Invalid with custom message
        return false, result
    else
        -- Unexpected return type - serialize safely for error message
        return false, "validator returned unexpected value: " .. serializeInSandbox(result)
    end
end

--- Executes a single validator expression.
--- @param expr string The validator expression
--- @param context table Context for the validator (self, row, rows, etc.)
--- @param quota number Maximum operations allowed
--- @param extraEnv table|nil Additional environment variables
--- @return boolean isValid True if validation passed
--- @return string|nil errorMessage Error message if validation failed or errored
local function executeValidator(expr, context, quota, extraEnv)
    local code = "return (" .. expr .. ")"
    local env = createValidatorEnv(context, extraEnv)

    local opt = {quota = quota, env = env}
    local ok, protected = pcall(sandbox.protect, code, opt)
    if not ok then
        return false, "failed to compile validator: " .. tostring(protected)
    end

    local exec_ok, result = pcall(protected)
    if not exec_ok then
        return false, "validator execution error: " .. tostring(result)
    end

    return interpretValidatorResult(result)
end

--- Runs row validators on a single row.
--- @param validators table Array of validator_spec
--- @param row table The row data (parsed values accessible by column name)
--- @param rowIndex number 1-based row index
--- @param fileName string Name of the file being validated
--- @param badVal table Error reporting object
--- @param extraEnv table|nil Additional environment variables (contexts, libraries)
--- @param ctx table|nil Writable context table shared across rows (created by caller)
--- @return boolean True if all error-level validators passed
--- @return table Array of warning messages
local function runRowValidators(validators, row, rowIndex, fileName, badVal, extraEnv, ctx)
    if not validators or #validators == 0 then
        return true, {}
    end

    local warnings = {}
    local wrappedRow = wrapRowForValidation(row)
    local context = {
        self = wrappedRow,
        row = wrappedRow,
        rowIndex = rowIndex,
        fileName = fileName,
        ctx = ctx or {},
    }

    for _, spec in ipairs(validators) do
        local normalized = normalizeValidatorSpec(spec)
        local isValid, errorMsg = executeValidator(
            normalized.expr, context, ROW_VALIDATOR_QUOTA, extraEnv)

        if not isValid then
            if normalized.level == "warn" then
                -- Collect warning and continue
                warnings[#warnings + 1] = {
                    validator = normalized.expr,
                    message = errorMsg,
                    rowIndex = rowIndex,
                }
                logger:warn(string.format(
                    "[WARN] Row validation warning in %s row %d: %s",
                    fileName, rowIndex, errorMsg))
            else
                -- Error level - stop and report
                badVal.line_no = rowIndex
                badVal(errorMsg, "validator: " .. normalized.expr)
                logger:error(string.format(
                    "[ERROR] Row validation failed in %s row %d: %s",
                    fileName, rowIndex, errorMsg))
                return false, warnings
            end
        end
    end

    return true, warnings
end

--- Runs file validators on all rows of a file.
--- @param validators table Array of validator_spec
--- @param rows table Array of all parsed rows in the file
--- @param fileName string Name of the file being validated
--- @param badVal table Error reporting object
--- @param extraEnv table|nil Additional environment variables (contexts, libraries)
--- @return boolean True if all error-level validators passed
--- @return table Array of warning messages
local function runFileValidators(validators, rows, fileName, badVal, extraEnv)
    if not validators or #validators == 0 then
        return true, {}
    end

    local warnings = {}
    local ctx = {}
    local wrappedRows = wrapRowsForValidation(rows)
    local context = {
        rows = wrappedRows,
        file = wrappedRows,
        fileName = fileName,
        count = #rows,
        ctx = ctx,
    }

    for _, spec in ipairs(validators) do
        local normalized = normalizeValidatorSpec(spec)
        local isValid, errorMsg = executeValidator(
            normalized.expr, context, FILE_VALIDATOR_QUOTA, extraEnv)

        if not isValid then
            if normalized.level == "warn" then
                -- Collect warning and continue
                warnings[#warnings + 1] = {
                    validator = normalized.expr,
                    message = errorMsg,
                    fileName = fileName,
                }
                logger:warn(string.format(
                    "[WARN] File validation warning in %s: %s",
                    fileName, errorMsg))
            else
                -- Error level - stop and report
                badVal.source_name = fileName
                badVal(normalized.expr, errorMsg)
                logger:error(string.format(
                    "[ERROR] File validation failed in %s: %s",
                    fileName, errorMsg))
                return false, warnings
            end
        end
    end

    return true, warnings
end

--- Runs package validators on all files in a package.
--- @param validators table Array of validator_spec
--- @param files table Map of file names to their row arrays
--- @param packageId string The package identifier
--- @param badVal table Error reporting object
--- @param extraEnv table|nil Additional environment variables (contexts, libraries)
--- @return boolean True if all error-level validators passed
--- @return table Array of warning messages
local function runPackageValidators(validators, files, packageId, badVal, extraEnv)
    if not validators or #validators == 0 then
        return true, {}
    end

    local warnings = {}
    local ctx = {}
    local wrappedFiles = wrapFilesForValidation(files)
    local context = {
        files = wrappedFiles,
        package = wrappedFiles,
        packageId = packageId,
        ctx = ctx,
    }

    for _, spec in ipairs(validators) do
        local normalized = normalizeValidatorSpec(spec)
        local isValid, errorMsg = executeValidator(
            normalized.expr, context, PACKAGE_VALIDATOR_QUOTA, extraEnv)

        if not isValid then
            if normalized.level == "warn" then
                -- Collect warning and continue
                warnings[#warnings + 1] = {
                    validator = normalized.expr,
                    message = errorMsg,
                    packageId = packageId,
                }
                logger:warn(string.format(
                    "[WARN] Package validation warning in %s: %s",
                    packageId, errorMsg))
            else
                -- Error level - stop and report
                badVal.source_name = "package:" .. packageId
                badVal(normalized.expr, errorMsg)
                logger:error(string.format(
                    "[ERROR] Package validation failed in %s: %s",
                    packageId, errorMsg))
                return false, warnings
            end
        end
    end

    return true, warnings
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    normalizeValidatorSpec = normalizeValidatorSpec,
    executeValidator = executeValidator,
    runRowValidators = runRowValidators,
    runFileValidators = runFileValidators,
    runPackageValidators = runPackageValidators,
    -- Quotas exposed for testing/customization
    ROW_VALIDATOR_QUOTA = ROW_VALIDATOR_QUOTA,
    FILE_VALIDATOR_QUOTA = FILE_VALIDATOR_QUOTA,
    PACKAGE_VALIDATOR_QUOTA = PACKAGE_VALIDATOR_QUOTA,
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
