-- Module name
local NAME = "export_tester"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 5, 0)

-- Dependencies
local read_only = require("read_only")
local readOnly = read_only.readOnly

local file_util = require("file_util")
local normalizePath = file_util.normalizePath
local isDir = file_util.isDir
local hasExtension = file_util.hasExtension

local lfs = require("lfs")

local importer = require("importer")
local round_trip = require("round_trip")
local deepEquals = round_trip.deepEquals
local compareWithTolerance = round_trip.compareWithTolerance

local manifest_loader = require("manifest_loader")

local error_reporting = require("error_reporting")
local badValGen = error_reporting.badValGen

local logger = require("named_logger").getLogger(NAME)

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- Default export directory
local DEFAULT_EXPORT_DIR = "exported"

-- ============================================================================
-- FORMAT CONFIGURATION
-- ============================================================================
-- Maps format subdirectories to their import configurations

local FORMAT_CONFIGS = {
    -- TSV formats
    ["tsv-lua"] = {
        extension = ".tsv",
        dataFormat = "lua",
        tolerant = false,
    },
    ["tsv-json-typed"] = {
        extension = ".tsv",
        dataFormat = "json-typed",
        tolerant = false,
    },
    ["tsv-json-natural"] = {
        extension = ".tsv",
        dataFormat = "json-natural",
        tolerant = true,  -- Can't distinguish int/float
    },
    -- JSON formats
    ["json-json-typed"] = {
        extension = ".json",
        dataFormat = "json-typed",
        tolerant = false,
    },
    ["json-json-natural"] = {
        extension = ".json",
        dataFormat = "json-natural",
        tolerant = true,
    },
    -- Lua format
    ["lua-lua"] = {
        extension = ".lua",
        dataFormat = nil,  -- Auto-detected
        tolerant = false,
    },
    -- XML format
    ["xml-xml"] = {
        extension = ".xml",
        dataFormat = nil,
        tolerant = true,  -- Float precision may vary
    },
    -- MessagePack format
    ["mpk-mpk"] = {
        extension = ".mpk",
        dataFormat = nil,
        tolerant = true,  -- Float precision may vary
    },
    -- SQL formats
    ["sql-json-typed"] = {
        extension = ".sql",
        dataFormat = "json-typed",
        tolerant = false,
    },
    ["sql-json-natural"] = {
        extension = ".sql",
        dataFormat = "json-natural",
        tolerant = true,
    },
    ["sql-xml"] = {
        extension = ".sql",
        dataFormat = "xml",
        tolerant = false,
    },
    ["sql-mpk"] = {
        extension = ".sql",
        dataFormat = "mpk",
        tolerant = false,
    },
}

-- ============================================================================
-- DIRECTORY UTILITIES
-- ============================================================================

--- Lists subdirectories in a directory.
--- @param path string The directory path
--- @return table Sequence of subdirectory names
local function listSubdirs(path)
    local subdirs = {}
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local fullPath = path .. "/" .. entry
            if isDir(fullPath) then
                subdirs[#subdirs + 1] = entry
            end
        end
    end
    table.sort(subdirs)
    return subdirs
end

--- Recursively lists files in a directory with a specific extension.
--- @param path string The directory path
--- @param extension string The file extension (e.g., ".json")
--- @return table Sequence of file paths
local function listFilesRecursive(path, extension)
    local files = {}

    local function recurse(dir)
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." then
                local fullPath = dir .. "/" .. entry
                if isDir(fullPath) then
                    recurse(fullPath)
                elseif hasExtension(fullPath, extension:sub(2)) then
                    files[#files + 1] = fullPath
                end
            end
        end
    end

    recurse(path)
    table.sort(files)
    return files
end

-- ============================================================================
-- DATA EXTRACTION
-- ============================================================================

--- Extracts the base name from a file path (without extension).
--- @param path string The file path
--- @return string The base name
local function getBaseName(path)
    local name = path:match("([^/\\]+)$") or path
    return name:match("^(.+)%.[^.]+$") or name
end

--- Converts parsed TSV data to the sequence-of-sequences format used by exports.
--- @param tsvData table The parsed TSV data from mod_loader
--- @return table Sequence of sequences (header row + data rows)
local function tsvToSequences(tsvData)
    local result = {}

    -- Header row (uses .parsed which returns name:type_spec via metamethod)
    local headerRow = {}
    if tsvData[1] then
        for i, col in ipairs(tsvData[1]) do
            -- Column objects have a __index metamethod that returns
            -- name..':'..type_spec for 'parsed', 'reformatted', etc.
            headerRow[i] = col.parsed
        end
    end
    result[1] = headerRow

    -- Data rows (skip comments/blank lines which are stored as strings)
    for rowIdx = 2, #tsvData do
        local row = tsvData[rowIdx]
        if type(row) == "table" then
            local dataRow = {}
            for colIdx, cell in ipairs(row) do
                dataRow[colIdx] = cell.parsed
            end
            result[#result + 1] = dataRow
        end
    end

    return result
end

-- ============================================================================
-- VALIDATION
-- ============================================================================

--- Validates an imported file against expected data.
--- @param imported table The imported data (sequence of sequences)
--- @param expected table The expected data (sequence of sequences)
--- @param formatConfig table The format configuration
--- @param _filePath string The file path (for error messages, currently unused)
--- @return boolean True if valid
--- @return string|nil Error message if invalid
local function validateImport(imported, expected, formatConfig, _filePath)
    if not imported then
        return false, "Import returned nil"
    end

    if #imported ~= #expected then
        return false, string.format(
            "Row count mismatch: imported %d, expected %d",
            #imported, #expected
        )
    end

    -- Compare each row
    for rowIdx = 1, #expected do
        local importedRow = imported[rowIdx]
        local expectedRow = expected[rowIdx]

        if not importedRow then
            return false, "Missing row " .. rowIdx
        end

        -- Use tolerant comparison for formats with known limitations
        local eq, diff
        if formatConfig.tolerant then
            eq, diff = compareWithTolerance(
                expectedRow, importedRow, "json-natural",
                "row[" .. rowIdx .. "]"
            )
        else
            eq, diff = deepEquals(expectedRow, importedRow, "row[" .. rowIdx .. "]")
        end

        if not eq then
            return false, diff
        end
    end

    return true, nil
end

-- ============================================================================
-- MAIN TESTING LOGIC
-- ============================================================================

--- Tests a single exported file.
--- @param filePath string Path to the exported file
--- @param expectedData table The expected data
--- @param formatConfig table The format configuration
--- @param verbose boolean Whether to print detailed output
--- @return boolean True if test passed
--- @return string|nil Error message if failed
local function testExportedFile(filePath, expectedData, formatConfig, verbose)
    if verbose then
        logger:info("  Testing: " .. filePath)
    end

    local imported, err = importer.importFile(filePath, formatConfig.dataFormat)
    if err then
        return false, "Import failed: " .. err
    end

    local valid, validErr = validateImport(imported, expectedData, formatConfig, filePath)
    if not valid then
        return false, "Validation failed: " .. validErr
    end

    return true, nil
end

--- Tests all exported files in a format subdirectory.
--- @param formatDir string Path to the format subdirectory
--- @param formatConfig table The format configuration
--- @param sourceData table Map of base names to expected data
--- @param verbose boolean Whether to print detailed output
--- @return number Number of files tested
--- @return number Number of files that passed
--- @return table Sequence of error messages
local function testFormatDirectory(formatDir, formatConfig, sourceData, verbose)
    local tested = 0
    local passed = 0
    local errors = {}

    local files = listFilesRecursive(formatDir, formatConfig.extension)

    for _, filePath in ipairs(files) do
        local baseName = getBaseName(filePath)
        local expected = sourceData[baseName]

        if expected then
            tested = tested + 1
            local success, err = testExportedFile(filePath, expected, formatConfig, verbose)
            if success then
                passed = passed + 1
                if verbose then
                    logger:info("    PASS")
                end
            else
                errors[#errors + 1] = filePath .. ": " .. err
                if verbose then
                    logger:error("    FAIL: " .. err)
                end
            end
        elseif verbose then
            logger:warn("  Skipping (no source data): " .. filePath)
        end
    end

    return tested, passed, errors
end

--- Generates usage help text.
--- @return string The help text
local function generateUsage()
    local lines = {
        "Usage: lua export_tester.lua [OPTIONS] <source_dir1> [source_dir2] ...",
        "",
        "DESCRIPTION:",
        "  Tests exported files by re-importing them and comparing against the",
        "  original source TSV data. Validates that the export/import round-trip",
        "  preserves data correctly.",
        "",
        "ARGUMENTS:",
        "  <source_dir1> ...     One or more directories containing original TSV files",
        "",
        "OPTIONS:",
        "  --export-dir=<dir>    Directory containing exported files (default: \"exported\")",
        "",
        "  --format=<fmt>        Test only this format subdirectory (can be repeated)",
        "                        Example: --format=json-json-natural --format=lua-lua",
        "",
        "  --verbose             Print detailed test progress",
        "",
        "SUPPORTED FORMATS:",
    }

    local formatNames = {}
    for name in pairs(FORMAT_CONFIGS) do
        formatNames[#formatNames + 1] = name
    end
    table.sort(formatNames)

    for _, name in ipairs(formatNames) do
        local config = FORMAT_CONFIGS[name]
        local tolerantStr = config.tolerant and " (tolerant)" or ""
        lines[#lines + 1] = "  " .. name .. tolerantStr
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "EXAMPLES:"
    lines[#lines + 1] = "  lua export_tester.lua data/"
    lines[#lines + 1] = "      Test all formats in exported/ against data/"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  lua export_tester.lua --format=json-json-natural data/"
    lines[#lines + 1] = "      Test only json-json-natural format"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  lua export_tester.lua --export-dir=my_exports --verbose data/"
    lines[#lines + 1] = "      Test with custom export directory and verbose output"

    return table.concat(lines, "\n")
end

--- Main testing function.
--- @param sourceDirectories table Sequence of source directory paths
--- @param exportDir string Path to the export directory
--- @param formats table|nil Sequence of format names to test (nil = all)
--- @param verbose boolean Whether to print detailed output
--- @return boolean True if all tests passed
--- @return table Summary statistics
local function runTests(sourceDirectories, exportDir, formats, verbose)
    -- Validate inputs
    if not sourceDirectories or #sourceDirectories == 0 then
        logger:error("No source directories specified")
        return false, {}
    end

    if not isDir(exportDir) then
        logger:error("Export directory does not exist: " .. exportDir)
        return false, {}
    end

    -- Load source data
    logger:info("Loading source data from: " .. table.concat(sourceDirectories, ", "))
    local badVal = badValGen()
    badVal.logger = logger

    local result = manifest_loader.processFiles(sourceDirectories, badVal)
    if not result then
        logger:error("Failed to load source data")
        return false, {}
    end

    -- Convert source TSV data to expected format
    local sourceData = {}
    for filePath, tsvData in pairs(result.tsv_files) do
        local baseName = getBaseName(filePath)
        sourceData[baseName] = tsvToSequences(tsvData)
    end

    local sourceCount = 0
    for _ in pairs(sourceData) do sourceCount = sourceCount + 1 end
    logger:info("Loaded " .. sourceCount .. " source files")

    -- Determine which formats to test
    local formatsToTest = formats
    if not formatsToTest or #formatsToTest == 0 then
        formatsToTest = listSubdirs(exportDir)
    end

    -- Run tests
    local totalTested = 0
    local totalPassed = 0
    local allErrors = {}
    local formatResults = {}

    for _, formatName in ipairs(formatsToTest) do
        local formatConfig = FORMAT_CONFIGS[formatName]
        if formatConfig then
            local formatDir = exportDir .. "/" .. formatName
            if isDir(formatDir) then
                logger:info("Testing format: " .. formatName)
                local tested, passed, errors = testFormatDirectory(
                    formatDir, formatConfig, sourceData, verbose
                )

                totalTested = totalTested + tested
                totalPassed = totalPassed + passed
                for _, err in ipairs(errors) do
                    allErrors[#allErrors + 1] = "[" .. formatName .. "] " .. err
                end

                formatResults[formatName] = {
                    tested = tested,
                    passed = passed,
                    failed = tested - passed,
                }

                local status = (passed == tested) and "PASS" or "FAIL"
                logger:info(string.format(
                    "  %s: %d/%d passed", status, passed, tested
                ))
            else
                logger:warn("Format directory not found: " .. formatDir)
            end
        else
            logger:warn("Unknown format: " .. formatName)
        end
    end

    -- Summary
    logger:info("")
    logger:info("========================================")
    logger:info("SUMMARY")
    logger:info("========================================")
    logger:info(string.format("Total: %d/%d tests passed", totalPassed, totalTested))

    if #allErrors > 0 then
        logger:info("")
        logger:error("Errors:")
        for _, err in ipairs(allErrors) do
            logger:error("  " .. err)
        end
    end

    local success = (totalPassed == totalTested) and (totalTested > 0)
    return success, {
        totalTested = totalTested,
        totalPassed = totalPassed,
        totalFailed = totalTested - totalPassed,
        formatResults = formatResults,
        errors = allErrors,
    }
end

-- ============================================================================
-- COMMAND-LINE INTERFACE
-- ============================================================================

local isMainScript = arg and arg[0] and arg[0]:match("export_tester")
if isMainScript then
    if #arg == 0 then
        print(generateUsage())
        os.exit(1)
    else
        local sourceDirectories = {}
        local exportDir = DEFAULT_EXPORT_DIR
        local formats = {}
        local verbose = false
        local hasError = false

        for i = 1, #arg do
            local arg_i = arg[i]
            local exportDirMatch = arg_i:match("^%-%-export%-dir=(.*)$")
            local formatMatch = arg_i:match("^%-%-format=(.+)$")

            if exportDirMatch then
                exportDir = exportDirMatch
            elseif formatMatch then
                if FORMAT_CONFIGS[formatMatch] then
                    formats[#formats + 1] = formatMatch
                else
                    logger:error("Unknown format: " .. formatMatch)
                    hasError = true
                end
            elseif arg_i == "--verbose" or arg_i == "-v" then
                verbose = true
            elseif arg_i:match("^%-%-") then
                logger:error("Unknown option: " .. arg_i)
                hasError = true
            else
                arg_i = normalizePath(arg_i)
                if isDir(arg_i) then
                    sourceDirectories[#sourceDirectories + 1] = arg_i
                else
                    logger:error("Directory does not exist: " .. arg_i)
                    hasError = true
                end
            end
        end

        if hasError then
            print("\nUse 'lua export_tester.lua' without arguments to see usage.")
            os.exit(1)
        end

        exportDir = normalizePath(exportDir)
        local success = runTests(sourceDirectories, exportDir, #formats > 0 and formats or nil, verbose)
        os.exit(success and 0 or 1)
    end
else
    logger:info("export_tester loaded as a module")
end

-- ============================================================================
-- MODULE API
-- ============================================================================

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    runTests = runTests,
    testExportedFile = testExportedFile,
    testFormatDirectory = testFormatDirectory,
    validateImport = validateImport,
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
