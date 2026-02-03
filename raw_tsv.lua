-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 5, 0)

-- Module name
local NAME = "raw_tsv"

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

local string_utils = require("string_utils")
local split = string_utils.split
local trim = string_utils.trim
local read_only = require("read_only")
local readOnly = read_only.readOnly

local predicates = require("predicates")
local isFullSeq = predicates.isFullSeq
local isValidUTF8 = predicates.isValidUTF8

local file_util = require("file_util")
local unixEOL = file_util.unixEOL
local readFile = file_util.readFile

--- Converts a string to a raw TSV structure.
--- Lines are split by newline, data lines are split by tab.
--- Comment lines (starting with #) and blank lines are preserved as strings.
--- @param s string The TSV content string (must be valid UTF-8)
--- @return table A sequence where each element is either a string (comment/blank) or a sequence of cells
--- @error Throws if s is not a string or not valid UTF-8
local function stringToRawTSV(s)
    local t = type(s)
    assert(t == "string", "Argument must be a string: " .. t)
    assert(isValidUTF8(s), "Argument must be a valid UTF8 string")
    local lines = {}
    for _,line in ipairs(split(unixEOL(s), "\n")) do
        if (line:sub(1, 1) == "#") or (trim(line) == "") then
            table.insert(lines, line)
        else
            table.insert(lines, split(line))
        end
    end
    if lines[#lines] == "" then
        table.remove(lines)
    end
    return lines
end

--- Converts a raw TSV structure back to a string.
--- Uses \n for line endings and \t for cell separators.
--- @param t table The raw TSV structure (sequence of strings or cell sequences)
--- @return string The TSV content as a string
--- @error Throws if t is not a table, cells contain invalid characters (tab/CR/LF),
---        cells are not valid UTF-8, or cells are not basic types
local function rawTSVToString(t)
    local tp = type(t)
    assert(tp == "table", "Argument must be a table: " .. tp)
    local result = {}
    for r, line in ipairs(t) do
        if type(line) == "string" then
            table.insert(result, line)
        else
            local size = #line
            for i=1, size do
                local cell = line[i]
                if i > 1 then
                    table.insert(result, "\t")
                end
                local c = ""
                local tc = type(cell)
                if tc == "string" then
                    if cell:find("[\t\r\n]") then
                        error(string.format("Cell at row %d, column %d contains invalid characters (tab, CR, or LF)", r, i), 2)
                    end
                    if not isValidUTF8(cell) then
                        error(string.format("Cell at row %d, column %d contains invalid UTF-8", r, i), 2)
                    end
                    c = cell
                elseif tc == "number" or tc == "boolean" or tc == "nil" then
                    c = tostring(cell)
                else
                    error("Invalid cell type: " .. tc, 2)
                end
                table.insert(result, c)
            end
        end
        table.insert(result, "\n")
    end
    return table.concat(result)
end

--- Reads a file and converts it to a raw TSV structure.
--- @param file string The file path to read
--- @return table|nil The raw TSV structure, or nil on error
--- @return string|nil Error message if file cannot be read, nil on success
local function fileToRawTSV(file)
    local content, err = readFile(file)
    if not content then
        return nil, err
    end
    return stringToRawTSV(content)
end

--- Checks if a value is a valid raw TSV structure.
--- Valid structure: a sequence where each element is either a string or a sequence of basic types.
--- @param t any The value to check
--- @return boolean True if t is a valid raw TSV structure, false otherwise
local function isRawTSV(t)
    if not isFullSeq(t) then
        return false
    end
    for _, line in ipairs(t) do
        local lt = type(line)
        if lt ~= "string" and lt ~= "table" then
            return false
        end
        if lt == "table" then
            for _, cell in ipairs(line) do
                local tc = type(cell)
                if tc ~= "string" and tc ~= "number" and tc ~= "boolean" and tc ~= "nil" then
                    return false
                end
            end
        end
    end
    return true
end
--- Transposes a raw TSV structure (swaps rows and columns).
--- Comment/blank lines (stored as strings) are converted to rows with:
--- - Column 1: dummy marker (e.g., "dummy0:comment")
--- - Column 2: original content
--- - Remaining columns: empty strings
--- @param t table A valid raw TSV structure
--- @return table The transposed structure
--- @error Throws if t is not a valid raw TSV structure
local function transposeRawTSV(t)
    if not isRawTSV(t) then
        error("Invalid raw TSV structure", 2)
    end

    -- First pass: determine dimensions and validate
    local max_columns = 0
    for _, row in ipairs(t) do
        if type(row) == "table" then
            max_columns = math.max(max_columns, #row)
        end
    end

    -- Create result structure
    local result = {}
    local dummies = 0

    -- Initialize all columns
    for c = 1, max_columns do
        result[c] = {}
    end

    -- Fill in transposed values
    for r, row in ipairs(t) do
        if type(row) == "table" then
            for c = 1, max_columns do
                local cell = row[c] or ""  -- Handle missing cells
                result[c][r] = cell
            end
        elseif type(row) == "string" then
            -- For comment/blank lines: column 1 gets dummy marker, column 2 gets original content
            for c = 1, max_columns do
                if c == 1 then
                    result[c][r] = 'dummy'..dummies..':comment'
                elseif c == 2 then
                    result[c][r] = row  -- Preserve original comment/blank content
                else
                    result[c][r] = ""
                end
            end
            dummies = dummies + 1
        else
            error("Invalid row type: " .. type(row), 2)
        end
    end

    return result
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    fileToRawTSV = fileToRawTSV,
    getVersion=getVersion,
    isRawTSV = isRawTSV,
    rawTSVToString = rawTSVToString,
    stringToRawTSV = stringToRawTSV,
    transposeRawTSV = transposeRawTSV,
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
