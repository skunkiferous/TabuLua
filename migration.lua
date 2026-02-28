-- migration.lua
-- Migration script executor for TabuLua DataSet operations.
-- Parses TSV migration scripts and executes them against a DataSet.

-- Module versioning
local semver = require("semver")
local VERSION = semver(0, 13, 0)
local NAME = "migration"

local named_logger = require("named_logger")

-- Map of log level name strings to level constants
local LOG_LEVELS = {
    ["debug"] = named_logger.DEBUG,
    ["info"]  = named_logger.INFO,
    ["warn"]  = named_logger.WARN,
    ["error"] = named_logger.ERROR,
    ["fatal"] = named_logger.FATAL,
}

-- Apply --log-level early, before other modules are loaded, so their
-- loggers are created at the correct level from the start.
if arg then
    for _, a in ipairs(arg) do
        local levelName = a:match("^%-%-log%-level=(.+)$")
        if levelName then
            local level = LOG_LEVELS[levelName:lower()]
            if level then
                named_logger.setGlobalLevel(level)
            else
                named_logger.setGlobalLevel(named_logger.ERROR)
            end
            break
        end
    end
end

local raw_tsv = require("raw_tsv")
local data_set = require("data_set")
local string_utils = require("string_utils")
local read_only = require("read_only")
local file_util = require("file_util")

local readOnly = read_only.readOnly
local split = string_utils.split
local normalizePath = file_util.normalizePath

--- Returns the module version as a string.
--- @return string
local function getVersion()
    return tostring(VERSION)
end

---------------------------------------------------------------------------
-- Command dispatch table
---------------------------------------------------------------------------

--- Resolve a TSV script position parameter (afterCol convention).
--- "*" means at the beginning; "" or nil means append; otherwise {after=name}.
--- @param afterCol string|nil The position parameter from the script
--- @param columns table|nil Column names for resolving "*" to {before=first}
--- @return table|nil Position table for DataSet API
local function resolveScriptColumnPosition(afterCol, columns)
    if afterCol == nil or afterCol == "" then
        return nil -- append
    end
    if afterCol == "*" then
        -- At the beginning: before the first column
        if columns and #columns > 0 then
            return {before = columns[1]}
        end
        return {index = 1}
    end
    return {after = afterCol}
end

--- Resolve a TSV script line position from posType/posValue pair.
--- @param posType string|nil Position type
--- @param posValue string|nil Position value
--- @return table|nil Position table for DataSet API
--- @return string|nil Error message
local function resolveScriptLinePosition(posType, posValue)
    if posType == nil or posType == "" then
        return {atEnd = true}, nil
    end
    if posType == "afterRow" then
        return {afterRow = posValue}, nil
    elseif posType == "beforeRow" then
        return {beforeRow = posValue}, nil
    elseif posType == "afterHeader" then
        return {afterHeader = true}, nil
    elseif posType == "beforeHeader" then
        return {beforeHeader = true}, nil
    elseif posType == "atEnd" then
        return {atEnd = true}, nil
    elseif posType == "rawIndex" then
        local n = tonumber(posValue)
        if not n then
            return nil, "rawIndex requires a numeric value, got: " .. tostring(posValue)
        end
        return {rawIndex = n}, nil
    else
        return nil, "unknown position type: " .. tostring(posType)
    end
end

--- Get a parameter from a script row, returning nil for empty strings.
--- @param row table The script row
--- @param index number 1-based column index
--- @return string|nil The parameter value, or nil if empty/missing
local function param(row, index)
    local v = row[index]
    if v == nil or v == "" then
        return nil
    end
    return v
end

--- Command handlers. Each receives (ds, row, options) and returns ok, err.
--- Row columns: [1]=command, [2]=p1, [3]=p2, [4]=p3, [5]=p4, [6]=p5
local COMMANDS = {}

-- File commands
COMMANDS.loadFile = function(ds, row)
    return ds:loadFile(row[2])
end

COMMANDS.loadTransposedFile = function(ds, row)
    return ds:loadTransposedFile(row[2])
end

COMMANDS.saveFile = function(ds, row, options)
    if options.dryRun then return true end
    return ds:saveFile(row[2])
end

COMMANDS.saveAll = function(ds, _, options)
    if options.dryRun then return true end
    return ds:saveAll()
end

COMMANDS.createFile = function(ds, row)
    local fileName = row[2]
    local colSpecs = param(row, 3)
    if not colSpecs then
        return nil, "createFile requires column specs in p2"
    end
    -- Column specs are pipe-delimited
    return ds:createFile(fileName, colSpecs)
end

COMMANDS.deleteFile = function(ds, row, options)
    if options.dryRun then return true end
    return ds:deleteFile(row[2])
end

COMMANDS.renameFile = function(ds, row)
    return ds:renameFile(row[2], row[3])
end

-- Column commands
COMMANDS.addColumn = function(ds, row)
    local fileName = row[2]
    local columnSpec = row[3]
    local afterCol = param(row, 4)
    local columns = ds:getColumnNames(fileName)
    if not columns then
        return nil, "file not loaded: " .. tostring(fileName)
    end
    local position = resolveScriptColumnPosition(afterCol, columns)
    return ds:addColumn(fileName, columnSpec, position)
end

COMMANDS.removeColumn = function(ds, row)
    return ds:removeColumn(row[2], row[3])
end

COMMANDS.renameColumn = function(ds, row)
    return ds:renameColumn(row[2], row[3], row[4])
end

COMMANDS.moveColumn = function(ds, row)
    local fileName = row[2]
    local columnName = row[3]
    local afterCol = param(row, 4)
    local columns = ds:getColumnNames(fileName)
    if not columns then
        return nil, "file not loaded: " .. tostring(fileName)
    end
    local position = resolveScriptColumnPosition(afterCol, columns)
    return ds:moveColumn(fileName, columnName, position)
end

COMMANDS.setColumnType = function(ds, row)
    return ds:setColumnType(row[2], row[3], row[4])
end

-- Row commands
COMMANDS.addRow = function(ds, row)
    local fileName = row[2]
    local valuesStr = param(row, 3)
    if not valuesStr then
        return nil, "addRow requires pipe-delimited values in p2"
    end
    local values = split(valuesStr, "|")
    return ds:addRow(fileName, values)
end

COMMANDS.removeRow = function(ds, row)
    return ds:removeRow(row[2], row[3])
end

-- Cell commands
COMMANDS.setCell = function(ds, row)
    return ds:setCell(row[2], row[3], row[4], row[5] or "")
end

COMMANDS.setCells = function(ds, row)
    return ds:setCells(row[2], row[3], row[4] or "")
end

COMMANDS.setCellsWhere = function(ds, row)
    return ds:setCellsWhere(row[2], row[3], row[4] or "", row[5], row[6])
end

COMMANDS.transformCells = function(ds, row)
    return ds:transformCells(row[2], row[3], row[4])
end

-- Comment/blank line commands
COMMANDS.addComment = function(ds, row)
    local fileName = row[2]
    local text = row[3] or ""
    local posType = param(row, 4)
    local posValue = param(row, 5)
    local position, err = resolveScriptLinePosition(posType, posValue)
    if not position then return nil, err end
    return ds:addComment(fileName, text, position)
end

COMMANDS.addBlankLine = function(ds, row)
    local fileName = row[2]
    local posType = param(row, 3)
    local posValue = param(row, 4)
    local position, err = resolveScriptLinePosition(posType, posValue)
    if not position then return nil, err end
    return ds:addBlankLine(fileName, position)
end

-- Files.tsv helper commands
COMMANDS.filesUpdatePath = function(ds, row)
    local fh, err = ds:filesHelper()
    if not fh then return nil, err end
    return fh:updatePath(row[2], row[3])
end

COMMANDS.filesUpdateSuperType = function(ds, row)
    local fh, err = ds:filesHelper()
    if not fh then return nil, err end
    return fh:updateSuperType(row[2], row[3])
end

COMMANDS.filesUpdateLoadOrder = function(ds, row)
    local fh, err = ds:filesHelper()
    if not fh then return nil, err end
    return fh:updateLoadOrder(row[2], row[3])
end

COMMANDS.filesUpdateTypeName = function(ds, row)
    local fh, err = ds:filesHelper()
    if not fh then return nil, err end
    return fh:updateTypeName(row[2], row[3])
end

-- Control commands
COMMANDS.echo = function(_, row, options)
    local message = row[2] or ""
    if options.verbose or options.logger then
        if options.logger then
            options.logger:info(message)
        else
            print(message)
        end
    end
    return true
end

COMMANDS.assert = function(ds, row)
    if not ds:hasFile(row[2]) then
        return nil, "assertion failed: file not loaded: " .. tostring(row[2])
    end
    return true
end

COMMANDS.assertColumn = function(ds, row)
    if not ds:hasColumn(row[2], row[3]) then
        return nil, "assertion failed: column " .. tostring(row[3]) ..
            " not found in " .. tostring(row[2])
    end
    return true
end

---------------------------------------------------------------------------
-- Script executor
---------------------------------------------------------------------------

--- Execute a migration script (TSV file).
--- @param scriptFile string Path to the migration script TSV file
--- @param rootDir string Root directory for the DataSet
--- @param options table|nil Options: {dryRun=bool, verbose=bool, logger=logger}
--- @return boolean|nil true on success, nil on error
--- @return string|nil error message
local function run(scriptFile, rootDir, options)
    options = options or {}
    -- Load script file
    local scriptData, loadErr = raw_tsv.fileToRawTSV(scriptFile)
    if not scriptData then
        return nil, "failed to load migration script: " .. tostring(loadErr)
    end
    -- Create dataset
    local ds = data_set.new(rootDir, {logger = options.logger})
    -- Process script rows
    local headerFound = false
    local stepNum = 0
    for _, line in ipairs(scriptData) do
        if type(line) == "table" then
            if not headerFound then
                -- First data row is the header, skip it
                headerFound = true
            else
                stepNum = stepNum + 1
                local command = line[1]
                if not command or command == "" then
                    -- Skip empty command rows
                else
                    local handler = COMMANDS[command]
                    if not handler then
                        return nil, string.format("step %d: unknown command: %s", stepNum, tostring(command))
                    end
                    if options.verbose then
                        local params = {}
                        for i = 2, #line do
                            if line[i] and line[i] ~= "" then
                                params[#params + 1] = line[i]
                            end
                        end
                        local msg = string.format("step %d: %s %s", stepNum, command, table.concat(params, " "))
                        if options.logger then
                            options.logger:info(msg)
                        else
                            print(msg)
                        end
                    end
                    local ok, err = handler(ds, line, options)
                    if not ok then
                        return nil, string.format("step %d (%s): %s", stepNum, command, tostring(err))
                    end
                end
            end
        end
        -- Skip comment and blank lines in script
    end
    return true
end

---------------------------------------------------------------------------
-- Command-line interface
---------------------------------------------------------------------------

--- Generate usage/help text for the CLI.
--- @return string
local function generateUsage()
    return [[
migration — TabuLua migration script executor (version ]] .. tostring(VERSION) .. [[)

Usage:
  lua54 migration.lua <script.tsv> <rootDir> [options]

Arguments:
  script.tsv    Path to the migration script (TSV file)
  rootDir       Root directory containing the data files

Options:
  --dry-run             Execute all operations but skip saving to disk
  --verbose             Log each step before execution
  --log-level=LEVEL     Set log level (debug, info, warn, error, fatal)

Script commands:
  File:     loadFile, loadTransposedFile, saveFile, saveAll,
            createFile, deleteFile, renameFile
  Column:   addColumn, removeColumn, renameColumn, moveColumn,
            setColumnType
  Row:      addRow, removeRow
  Cell:     setCell, setCells, setCellsWhere, transformCells
  Comment:  addComment, addBlankLine
  Files:    filesUpdatePath, filesUpdateSuperType,
            filesUpdateLoadOrder, filesUpdateTypeName
  Control:  echo, assert, assertColumn]]
end

local isMainScript = arg and arg[0] and arg[0]:match("migration")
if isMainScript then
    if #arg == 0 then
        print(generateUsage())
        os.exit(1)
    end

    -- Parse: <script.tsv> <rootDir> [--dry-run] [--verbose] [--log-level=LEVEL]
    local scriptFile, rootDir, options, hasError = nil, nil, {}, false
    local cliLogger = named_logger.getLogger(NAME)

    for i = 1, #arg do
        local arg_i = arg[i]
        if arg_i == "--dry-run" then
            options.dryRun = true
        elseif arg_i == "--verbose" then
            options.verbose = true
        elseif arg_i:match("^%-%-log%-level=") then
            -- Already handled early; validate here for error reporting
            local levelName = arg_i:match("^%-%-log%-level=(.+)$")
            if not LOG_LEVELS[levelName:lower()] then
                cliLogger:error("Unknown log level: " .. levelName)
                cliLogger:error("Valid levels: debug, info, warn, error, fatal")
                hasError = true
            end
        elseif arg_i:match("^%-%-") then
            cliLogger:error("Unknown option: " .. arg_i)
            hasError = true
        elseif not scriptFile then
            scriptFile = normalizePath(arg_i)
        elseif not rootDir then
            rootDir = normalizePath(arg_i)
        else
            cliLogger:error("Unexpected argument: " .. arg_i)
            hasError = true
        end
    end

    if not scriptFile then
        cliLogger:error("Missing required argument: <script.tsv>")
        hasError = true
    end
    if not rootDir then
        cliLogger:error("Missing required argument: <rootDir>")
        hasError = true
    end

    if hasError then
        print("\nUse 'lua54 migration.lua' without arguments to see usage.")
        os.exit(1)
    end

    options.logger = cliLogger
    local ok, err = run(scriptFile, rootDir, options)
    if not ok then
        cliLogger:error(err)
        os.exit(1)
    end
    cliLogger:info("Migration completed successfully.")
    os.exit(0)
end

---------------------------------------------------------------------------
-- Module API
---------------------------------------------------------------------------

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    run = run,
    getVersion = getVersion,
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
