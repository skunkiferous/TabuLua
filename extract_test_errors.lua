-- extract_test_errors.lua
-- Extracts failed test information from TAP format test output.

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 17, 0)

-- Module name
local NAME = "extract_test_errors"

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.16.0")
local function getVersion()
    return tostring(VERSION)
end

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

local logger = named_logger.getLogger(NAME)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local file_util = require("file_util")
local normalizePath = file_util.normalizePath
local readFile = file_util.readFile
local writeFile = file_util.writeFile

---------------------------------------------------------------------------
-- TAP parser
---------------------------------------------------------------------------

--- Parses TAP format test output and extracts error information.
--- @param content string The TAP format test output
--- @return table result { total, passed, failed, errorText }
local function parseTAP(content)
    local in_error_block = false
    local error_lines = {}
    local total_tests = 0
    local failed_tests = 0
    local passed_tests = 0

    for line in content:gmatch("[^\r\n]+") do
        if in_error_block then
            -- Continue collecting error details (lines starting with #)
            if line:match("^#") then
                table.insert(error_lines, line)
            elseif line:match("^%s*$") then
                -- Empty line might end error block, but keep it
                table.insert(error_lines, line)
            elseif line:match("^ok %d+") or line:match("^not ok %d+") or line:match("^%d+%.%.%d+") then
                -- New test or test plan line ends error block
                in_error_block = false
                table.insert(error_lines, "") -- Add separator
                passed_tests = passed_tests + (line:match("^ok %d+") and 1 or 0)
                if line:match("^not ok %d+") then
                    failed_tests = failed_tests + 1
                    in_error_block = true
                    table.insert(error_lines, line)
                end
            else
                -- Unknown line in error block, keep it
                table.insert(error_lines, line)
            end
        -- Count test results
        elseif line:match("^ok %d+") then
            passed_tests = passed_tests + 1
        elseif line:match("^not ok %d+") then
            failed_tests = failed_tests + 1
            in_error_block = true
            table.insert(error_lines, line)
        elseif line:match("^%d+%.%.%d+") then
            -- Test plan line (e.g., "1..503")
            local match = line:match("^%d+%.%.(%d+)")
            if match then
                total_tests = tonumber(match) or 0
            end
        end
    end

    return {
        total = total_tests,
        passed = passed_tests,
        failed = failed_tests,
        errorText = table.concat(error_lines, "\n"),
    }
end

---------------------------------------------------------------------------
-- Report formatter
---------------------------------------------------------------------------

--- Formats a parsed TAP result into a human-readable summary report.
--- @param result table Parsed TAP result from parseTAP
--- @return string The formatted report text
local function formatReport(result)
    local separator = "=" .. string.rep("=", 78)
    local parts = {
        separator,
        "TEST RESULTS SUMMARY",
        separator,
        string.format("Total Tests: %d", result.total),
        string.format("Passed: %d", result.passed),
        string.format("Failed: %d", result.failed),
        separator,
        "",
    }

    if result.failed > 0 then
        table.insert(parts, "FAILED TESTS:")
        table.insert(parts, "")
        table.insert(parts, result.errorText)
    else
        table.insert(parts, "All tests passed!")
    end

    return table.concat(parts, "\n") .. "\n"
end

---------------------------------------------------------------------------
-- Main entry point
---------------------------------------------------------------------------

--- Extracts failed test information from a TAP format input file and writes
--- a summary report to an output file.
--- @param input_file string Path to the TAP format test output file
--- @param output_file string Path for the summary report output
--- @return boolean|nil true on success, nil on error
--- @return string|nil error message
--- @return table|nil parsed result with total/passed/failed counts
local function extractErrors(input_file, output_file)
    local content, readErr = readFile(input_file)
    if not content then
        return nil, "could not open input file: " .. input_file .. ": " .. tostring(readErr)
    end

    local result = parseTAP(content)
    local report = formatReport(result)

    local ok, writeErr = writeFile(output_file, report)
    if not ok then
        return nil, "could not open output file: " .. output_file .. ": " .. tostring(writeErr)
    end

    logger:info(string.format("Total: %d | Passed: %d | Failed: %d",
        result.total, result.passed, result.failed))

    return true, nil, result
end

---------------------------------------------------------------------------
-- Command-line interface
---------------------------------------------------------------------------

--- Generate usage/help text for the CLI.
--- @return string
local function generateUsage()
    return [[
extract_test_errors — TAP test error extractor (version ]] .. tostring(VERSION) .. [[)

Usage:
  lua54 extract_test_errors.lua <input_file> [output_file] [options]

Arguments:
  input_file    Path to the TAP format test output file
  output_file   Path for the summary report (default: test_errors.txt)

Options:
  --log-level=LEVEL     Set log level (debug, info, warn, error, fatal)]]
end

local isMainScript = arg and arg[0] and arg[0]:match("extract_test_errors")
if isMainScript then
    if #arg == 0 then
        print(generateUsage())
        os.exit(1)
    end

    -- Parse: <input_file> [output_file] [--log-level=LEVEL]
    local input_file, output_file, hasError = nil, nil, false
    local cliLogger = named_logger.getLogger(NAME)

    for i = 1, #arg do
        local arg_i = arg[i]
        if arg_i:match("^%-%-log%-level=") then
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
        elseif not input_file then
            input_file = normalizePath(arg_i)
        elseif not output_file then
            output_file = normalizePath(arg_i)
        else
            cliLogger:error("Unexpected argument: " .. arg_i)
            hasError = true
        end
    end

    if not input_file then
        cliLogger:error("Missing required argument: <input_file>")
        hasError = true
    end

    if hasError then
        print("\nUse 'lua54 extract_test_errors.lua' without arguments to see usage.")
        os.exit(1)
    end

    output_file = output_file or "test_errors.txt"

    local ok, err, result = extractErrors(input_file, output_file)
    if not ok or not result then
        cliLogger:error(err or "unknown error")
        os.exit(2)
    end

    cliLogger:info("Test results extracted to: " .. output_file)

    -- Return exit code based on test results
    if result.failed > 0 then
        os.exit(1)
    else
        os.exit(0)
    end
end

---------------------------------------------------------------------------
-- Module API
---------------------------------------------------------------------------

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    extractErrors = extractErrors,
    parseTAP = parseTAP,
    formatReport = formatReport,
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
