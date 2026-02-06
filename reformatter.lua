-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 5, 0)

-- Module name
local NAME = "reformatter"

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

local logger = require( "named_logger").getLogger(NAME)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local file_util = require("file_util")
local safeReplaceFile = file_util.safeReplaceFile
local normalizePath = file_util.normalizePath
local isDir = file_util.isDir
local emptyDir = file_util.emptyDir

local manifest_loader = require("manifest_loader")

local error_reporting = require("error_reporting")
local badValGen = error_reporting.badValGen

local exporter = require("exporter")

local serialization = require("serialization")
local serializeTableJSON = serialization.serializeTableJSON
local serializeTableNaturalJSON = serialization.serializeTableNaturalJSON
local serializeTableXML = serialization.serializeTableXML
local serializeMessagePackSQLBlob = serialization.serializeMessagePackSQLBlob

local isDir = file_util.isDir
local mkdir = file_util.mkdir

-- Default export directory
local DEFAULT_EXPORT_DIR = "exported"

-- ============================================================================
-- FORMAT CONFIGURATION
-- ============================================================================
-- This configuration table defines all supported file formats, data formats,
-- valid combinations, and defaults. To add a new format, simply extend this
-- configuration - no other code changes required.

-- Data format definitions
-- Each data format defines how Lua values are serialized
local DATA_FORMATS = {
    ["json-typed"] = {
        description = "JSON with Lua type preservation (integers as {\"int\":\"N\"})",
        tsvExporter = exporter.exportJSONTSV,
        jsonExporter = exporter.exportJSON,
        sqlTableSerializer = serializeTableJSON,
    },
    ["json-natural"] = {
        description = "Standard JSON format (compatible with any JSON parser)",
        tsvExporter = exporter.exportNaturalJSONTSV,
        jsonExporter = exporter.exportNaturalJSON,
        sqlTableSerializer = serializeTableNaturalJSON,
    },
    ["lua"] = {
        description = "Lua literal syntax",
        tsvExporter = exporter.exportLuaTSV,
        luaExporter = exporter.exportLua,
    },
    ["xml"] = {
        description = "XML with type-tagged elements",
        sqlTableSerializer = serializeTableXML,
        xmlExporter = exporter.exportXML,
    },
    ["mpk"] = {
        description = "MessagePack binary format",
        mpkExporter = exporter.exportMessagePack,
        sqlTableSerializer = serializeMessagePackSQLBlob,
    },
}

-- File format definitions
-- Each file format defines the output file type and valid data formats
local FILE_FORMATS = {
    ["tsv"] = {
        extension = ".tsv",
        description = "Tab-separated values",
        validData = {"lua", "json-typed", "json-natural"},
        defaultData = nil,  -- No default - user must specify
        getExporter = function(dataFormat)
            local df = DATA_FORMATS[dataFormat]
            return df and df.tsvExporter
        end,
    },
    ["json"] = {
        extension = ".json",
        description = "JSON array-of-arrays",
        validData = {"json-typed", "json-natural"},
        defaultData = "json-natural",
        getExporter = function(dataFormat)
            local df = DATA_FORMATS[dataFormat]
            return df and df.jsonExporter
        end,
    },
    ["lua"] = {
        extension = ".lua",
        description = "Lua table (sequence-of-sequences)",
        validData = {"lua"},
        defaultData = "lua",
        getExporter = function(dataFormat)
            local df = DATA_FORMATS[dataFormat]
            return df and df.luaExporter
        end,
    },
    ["xml"] = {
        extension = ".xml",
        description = "XML document",
        validData = {"xml"},
        defaultData = "xml",
        getExporter = function(dataFormat)
            local df = DATA_FORMATS[dataFormat]
            return df and df.xmlExporter
        end,
    },
    ["sql"] = {
        extension = ".sql",
        description = "SQL CREATE TABLE + INSERT statements",
        validData = {"json-typed", "json-natural", "xml", "mpk"},
        defaultData = nil,  -- No default - user must specify
        getExporter = function(dataFormat)
            return exporter.exportSQL
        end,
        getTableSerializer = function(dataFormat)
            local df = DATA_FORMATS[dataFormat]
            return df and df.sqlTableSerializer
        end,
    },
    ["mpk"] = {
        extension = ".mpk",
        description = "MessagePack binary",
        validData = {"mpk"},
        defaultData = "mpk",
        getExporter = function(dataFormat)
            local df = DATA_FORMATS[dataFormat]
            return df and df.mpkExporter
        end,
    },
}

--- Validates that a data format is valid for a file format.
--- @param fileFormat string The file format name
--- @param dataFormat string The data format name
--- @return boolean True if valid combination, false otherwise
local function isValidCombination(fileFormat, dataFormat)
    local ff = FILE_FORMATS[fileFormat]
    if not ff then return false end
    for _, valid in ipairs(ff.validData) do
        if valid == dataFormat then
            return true
        end
    end
    return false
end

--- Creates an exporter configuration for a file/data format combination.
--- @param fileFormat string The file format name
--- @param dataFormat string The data format name
--- @return table|nil Exporter config {fn, subdir, tableSerializer} or nil if invalid
local function createExporter(fileFormat, dataFormat)
    local ff = FILE_FORMATS[fileFormat]
    if not ff then
        logger:error("Unknown file format: " .. tostring(fileFormat))
        return nil
    end

    -- Use default data format if not specified
    local actualDataFormat = dataFormat
    if not actualDataFormat then
        actualDataFormat = ff.defaultData
        if not actualDataFormat then
            logger:error("File format '" .. fileFormat .. "' requires --data option (no default)")
            return nil
        end
    end

    if not isValidCombination(fileFormat, actualDataFormat) then
        logger:error("Invalid combination: --file=" .. fileFormat .. " --data=" .. actualDataFormat)
        logger:error("Valid data formats for " .. fileFormat .. ": " .. table.concat(ff.validData, ", "))
        return nil
    end

    local exportFn = ff.getExporter(actualDataFormat)
    if not exportFn then
        logger:error("No exporter for combination: " .. fileFormat .. " + " .. actualDataFormat)
        return nil
    end

    local result = {
        fn = exportFn,
        subdir = fileFormat .. "-" .. actualDataFormat,
    }

    -- Add table serializer for SQL format
    if ff.getTableSerializer then
        result.tableSerializer = ff.getTableSerializer(actualDataFormat)
    end

    return result
end

--- Generates the usage help text dynamically from the format configuration.
--- @return string The help text
local function generateUsage()
    local lines = {
        "Usage: lua reformatter.lua [OPTIONS] <dir1> [dir2] ...",
        "",
        "DESCRIPTION:",
        "  Processes TSV data files from the specified directories, reformats them",
        "  in-place if needed, and optionally exports them to various formats.",
        "",
        "ARGUMENTS:",
        "  <dir1> [dir2] ...     One or more directories containing TSV files to process",
        "",
        "OPTIONS:",
        "  --export-dir=<dir>    Set the base export directory (default: \"exported\")",
        "                        Output goes to subdirectories like exported/json-natural/",
        "",
        "  --file=<format>       Output file format (see FILE FORMATS below)",
        "",
        "  --data=<format>       Data serialization format (see DATA FORMATS below)",
        "                        Required for some file formats, optional for others",
        "",
        "  --collapse-exploded   Collapse exploded columns into single composite columns",
        "                        (e.g., location.level + location.x -> location:{level,x})",
        "                        Default: keep exploded columns as separate flat columns",
        "",
        "  --clean               Empty the export directory before exporting",
        "                        Removes all existing files and subdirectories",
        "",
        "FILE FORMATS:",
    }

    -- List file formats with their valid data formats
    local fileNames = {}
    for name in pairs(FILE_FORMATS) do
        table.insert(fileNames, name)
    end
    table.sort(fileNames)

    for _, name in ipairs(fileNames) do
        local ff = FILE_FORMATS[name]
        local defaultStr = ff.defaultData and (" (default: " .. ff.defaultData .. ")") or " (no default)"
        table.insert(lines, "  " .. name .. string.rep(" ", 8 - #name) .. ff.description)
        table.insert(lines, "            Valid data: " .. table.concat(ff.validData, ", ") .. defaultStr)
        table.insert(lines, "")
    end

    table.insert(lines, "DATA FORMATS:")

    -- List data formats
    local dataNames = {}
    for name in pairs(DATA_FORMATS) do
        table.insert(dataNames, name)
    end
    table.sort(dataNames)

    for _, name in ipairs(dataNames) do
        local df = DATA_FORMATS[name]
        table.insert(lines, "  " .. name .. string.rep(" ", 14 - #name) .. df.description)
    end

    table.insert(lines, "")
    table.insert(lines, "VALID COMBINATIONS:")
    table.insert(lines, "  File Format   Data Formats                          Default")
    table.insert(lines, "  -----------   ------------------------------------  -------")

    for _, name in ipairs(fileNames) do
        local ff = FILE_FORMATS[name]
        local validStr = table.concat(ff.validData, ", ")
        local defaultStr = ff.defaultData or "(none)"
        local padding1 = string.rep(" ", 14 - #name)
        local padding2 = string.rep(" ", 38 - #validStr)
        table.insert(lines, "  " .. name .. padding1 .. validStr .. padding2 .. defaultStr)
    end

    table.insert(lines, "")
    table.insert(lines, "EXAMPLES:")
    table.insert(lines, "  NOTE: Specify package directories directly (containing Manifest or Files.tsv)")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua tutorial/core/ tutorial/expansion/")
    table.insert(lines, "      Reformat files in package directories (no export)")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --file=json tutorial/core/ tutorial/expansion/")
    table.insert(lines, "      Export as JSON (natural format) to exported/json-json-natural/")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --file=json --data=json-typed tutorial/core/")
    table.insert(lines, "      Export as JSON (typed format) to exported/json-json-typed/")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --file=tsv --data=lua tutorial/core/")
    table.insert(lines, "      Export as TSV with Lua literals to exported/tsv-lua/")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --file=sql --data=json-natural --export-dir=db mypkg/")
    table.insert(lines, "      Export as SQL with JSON columns to db/sql-json-natural/")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --file=lua --file=json tutorial/core/ tutorial/expansion/")
    table.insert(lines, "      Export to multiple formats (uses defaults for each)")

    return table.concat(lines, "\n")
end

--- Re-formats TSV files in-place, updating files whose content has changed after parsing.
--- @param tsv_files table Map of file paths to parsed TSV data
--- @param raw_files table Map of file paths to original raw content
--- @param badVal table badVal instance for error reporting
--- @side_effect Modifies files on disk if content changed
local function reformat(tsv_files, raw_files, badVal)
    for file_name, tsv in pairs(tsv_files) do
        if raw_files[file_name] then
            -- Manifests are now reformatted too: user-defined fields are preserved
            -- in the tsv_model, and __comment placeholders restore comment lines
            local new_content = tostring(tsv)
            local old_content = raw_files[file_name]
            if new_content ~= old_content then
                if (new_content .. '\n') == old_content then
                    logger:info("Last EOL of " .. file_name .. " has changed")
                else
                    logger:warn("Content of " .. file_name .. " has changed")
                end
                if safeReplaceFile(file_name, new_content) then
                    logger:info("Updated: " .. file_name)
                else
                    badVal(file_name, "Failed to update")
                end
            end
        else
            logger:warn("Content of " .. file_name .. " missing in raw_files")
        end
    end
end

--- Main entry point: loads, reformats, and optionally exports files.
--- @param directories table Sequence of directory paths containing TSV files
--- @param exporters table|nil Optional sequence of exporters, each either a function or {fn, subdir, tableSerializer}
--- @param exportParams table|nil Optional export parameters: {exportDir, ...}
--- @side_effect Reformats files in-place; creates export files if exporters specified
--- @error Throws if directories is not a table or contains non-string values
local function processFiles(directories, exporters, exportParams)
    local td = type(directories)
    if td == "nil" or (td == "table" and #directories == 0) then
        logger:error("No input directories specified")
        return
    end
    if td ~= "table" then
        error("processFiles: directories not a table: "..td)
    end
    for _,d in pairs(directories) do
        if type(d) ~= "string" then
            error("processFiles: directory not a string: "..type(d))
        end
        if not isDir(d) then
            logger:error("processFiles: directory does not exist: "..d)
            return
        end
    end
    local badVal = badValGen()
    badVal.logger = logger

    local result = manifest_loader.processFiles(directories, badVal)
    if result then
        local tsv_files = result.tsv_files
        local raw_files = result.raw_files
        reformat(tsv_files, raw_files, badVal)
        local errors = badVal.errors
        if errors > 0 then
            logger:error("Reformatting errors: " .. errors)
        else
            if exporters and #exporters > 0 then
                local exportDir = (exportParams and exportParams.exportDir) or DEFAULT_EXPORT_DIR
                logger:info("Using export directory: " .. exportDir)
                if not isDir(exportDir) then
                    logger:warn("Export directory " .. exportDir .. " does not exist, creating it...")
                    local success, err = mkdir(exportDir)
                    if not success then
                        logger:error("Failed to create export directory " .. exportDir.." : " .. err)
                        return
                    end
                elseif exportParams and exportParams.cleanExportDir then
                    logger:info("Cleaning export directory: " .. exportDir)
                    local success, err = emptyDir(exportDir, logger)
                    if not success then
                        logger:error("Failed to clean export directory " .. exportDir .. " : " .. err)
                        return
                    end
                end
                local epCopy = {}
                if exportParams then
                    for k, v in pairs(exportParams) do
                        epCopy[k] = v
                    end
                end
                epCopy.exportDir = exportDir
                -- Register joined types before generating schema so they appear in it
                local joinedTypeCount = exporter.registerJoinedTypes(result)
                if joinedTypeCount > 0 then
                    logger:info("Pre-registered " .. joinedTypeCount .. " joined type(s) for schema")
                end
                exporter.exportSchema(exportDir, result, badVal)
                for _, exp in ipairs(exporters) do
                    -- Support both plain functions and {fn, subdir, tableSerializer} tables
                    if type(exp) == "function" then
                        exp(result, epCopy)
                    else
                        epCopy.formatSubdir = exp.subdir
                        if exp.tableSerializer then
                            epCopy.tableSerializer = exp.tableSerializer
                        end
                        local success = exp.fn(result, epCopy)
                        if not success then
                            logger:error("Failed to export to " .. exp.subdir)
                            return
                        end
                        epCopy.tableSerializer = nil
                    end
                end
            end
        end
    else
        logger:error("manifest_loader failed to process files in " .. table.concat(directories, ", "))
    end
end

local isMainScript = arg and arg[0] and arg[0]:match("reformatter")
if isMainScript then
    -- Main execution
    logger:info("reformatter version: " .. getVersion())
    if #arg == 0 then
        print(generateUsage())
        os.exit(1)
    else
        local directories = {}
        local exporters = {}
        local exportParams = {}
        local exportDir = DEFAULT_EXPORT_DIR
        local collapseExploded = false  -- --collapse-exploded flag
        local cleanExportDir = false    -- --clean flag
        local pendingFile = nil  -- Pending --file= waiting for optional --data=
        local pendingData = nil  -- Pending --data= waiting for --file=
        local hasError = false

        -- Helper to finalize a pending file format export
        local function finalizePending()
            if pendingFile then
                local exp = createExporter(pendingFile, pendingData)
                if exp then
                    table.insert(exporters, exp)
                else
                    hasError = true
                end
                pendingFile = nil
                pendingData = nil
            elseif pendingData then
                logger:error("--data=" .. pendingData .. " specified without --file=")
                hasError = true
                pendingData = nil
            end
        end

        for i = 1, #arg do
            local arg_i = arg[i]
            local fileMatch = arg_i:match("^%-%-file=(.+)$")
            local dataMatch = arg_i:match("^%-%-data=(.+)$")
            local exportDirMatch = arg_i:match("^%-%-export%-dir=(.*)$")

            if fileMatch then
                -- Finalize any previous pending export
                finalizePending()
                -- Validate file format
                if not FILE_FORMATS[fileMatch] then
                    logger:error("Unknown file format: " .. fileMatch)
                    logger:error("Valid formats: " .. table.concat((function()
                        local names = {}
                        for name in pairs(FILE_FORMATS) do table.insert(names, name) end
                        table.sort(names)
                        return names
                    end)(), ", "))
                    hasError = true
                else
                    pendingFile = fileMatch
                end
            elseif dataMatch then
                -- Validate data format
                if not DATA_FORMATS[dataMatch] then
                    logger:error("Unknown data format: " .. dataMatch)
                    logger:error("Valid formats: " .. table.concat((function()
                        local names = {}
                        for name in pairs(DATA_FORMATS) do table.insert(names, name) end
                        table.sort(names)
                        return names
                    end)(), ", "))
                    hasError = true
                elseif pendingData then
                    logger:error("Multiple --data= without --file= between them")
                    hasError = true
                else
                    pendingData = dataMatch
                end
            elseif exportDirMatch then
                exportDir = exportDirMatch
            elseif arg_i == "--collapse-exploded" then
                collapseExploded = true
            elseif arg_i == "--clean" then
                cleanExportDir = true
            elseif arg_i:match("^%-%-") then
                logger:error("Unknown option: " .. arg_i)
                hasError = true
            else
                -- Directory argument - finalize any pending export first
                finalizePending()
                arg_i = normalizePath(arg_i)
                table.insert(directories, arg_i)
            end
        end

        -- Finalize any remaining pending export
        finalizePending()

        if hasError then
            print("\nUse 'lua reformatter.lua' without arguments to see usage.")
            os.exit(1)
        end

        exportDir = normalizePath(exportDir)
        exportParams.exportDir = exportDir
        -- Set exportExploded=false when --collapse-exploded is specified
        if collapseExploded then
            exportParams.exportExploded = false
        end
        -- Set cleanExportDir=true when --clean is specified
        if cleanExportDir then
            exportParams.cleanExportDir = true
        end
        processFiles(directories, exporters, exportParams)
    end
else
    logger:info("reformatter loaded as a module")
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    processFiles = processFiles,
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
