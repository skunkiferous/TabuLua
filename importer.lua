-- Module name
local NAME = "importer"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 10, 0)

-- Dependencies
local read_only = require("read_only")
local readOnly = read_only.readOnly
local file_util = require("file_util")
local readFile = file_util.readFile
local hasExtension = file_util.hasExtension

local deserialization = require("deserialization")
local deserialize = deserialization.deserialize
local deserializeJSON = deserialization.deserializeJSON
local deserializeNaturalJSON = deserialization.deserializeNaturalJSON
local deserializeXML = deserialization.deserializeXML
local deserializeMessagePack = deserialization.deserializeMessagePack

local string_utils = require("string_utils")
local split = string_utils.split
local trim = string_utils.trim

local dkjson = require("dkjson")

local logger = require("named_logger").getLogger(NAME)

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================================
-- LUA FILE IMPORT
-- ============================================================================

--- Imports a Lua file that returns a table (sequence-of-sequences format).
--- @param filePath string Path to the .lua file
--- @return table|nil The imported data as a sequence of sequences
--- @return string|nil Error message if import failed
local function importLuaFile(filePath)
    local content, err = readFile(filePath)
    if not content then
        return nil, "Failed to read Lua file: " .. tostring(err)
    end

    -- Create a sandboxed environment
    local sandbox = {
        math = { huge = math.huge }
    }

    local fn, loadErr = load(content, filePath, "t", sandbox)
    if not fn then
        return nil, "Failed to parse Lua: " .. tostring(loadErr)
    end

    local ok, result = pcall(fn)
    if not ok then
        return nil, "Failed to execute Lua: " .. tostring(result)
    end

    return result, nil
end

-- ============================================================================
-- JSON FILE IMPORT
-- ============================================================================

--- Imports a typed JSON file (array-of-arrays format with type wrappers).
--- @param filePath string Path to the .json file
--- @return table|nil The imported data as a sequence of sequences
--- @return string|nil Error message if import failed
local function importTypedJSONFile(filePath)
    local content, err = readFile(filePath)
    if not content then
        return nil, "Failed to read JSON file: " .. tostring(err)
    end

    -- Parse the outer JSON array
    local parsed, _pos, parseErr = dkjson.decode(content)
    if parseErr then
        return nil, "Failed to parse JSON: " .. tostring(parseErr)
    end

    if type(parsed) ~= "table" then
        return nil, "Expected JSON array at top level"
    end

    -- Each row is in typed JSON format: [size, elem1, ..., [key,val], ...]
    local result = {}
    for i, row in ipairs(parsed) do
        local rowData, rowErr = deserializeJSON(dkjson.encode(row))
        if rowErr then
            return nil, "Failed to deserialize row " .. i .. ": " .. tostring(rowErr)
        end
        result[i] = rowData
    end

    return result, nil
end

--- Imports a natural JSON file (standard array-of-arrays format).
--- @param filePath string Path to the .json file
--- @return table|nil The imported data as a sequence of sequences
--- @return string|nil Error message if import failed
local function importNaturalJSONFile(filePath)
    local content, err = readFile(filePath)
    if not content then
        return nil, "Failed to read file: " .. tostring(err)
    end

    -- Parse the outer JSON array
    local parsed, _pos, parseErr = dkjson.decode(content)
    if parseErr then
        return nil, "Failed to parse JSON: " .. tostring(parseErr)
    end

    if type(parsed) ~= "table" then
        return nil, "Expected JSON array at top level"
    end

    -- Each row is a standard JSON array
    local result = {}
    for i, row in ipairs(parsed) do
        local rowData, rowErr = deserializeNaturalJSON(dkjson.encode(row))
        if rowErr then
            return nil, "Failed to deserialize row " .. i .. ": " .. tostring(rowErr)
        end
        result[i] = rowData
    end

    return result, nil
end

-- ============================================================================
-- TSV FILE IMPORT
-- ============================================================================

--- Imports a TSV file with Lua literal values.
--- @param filePath string Path to the .tsv file
--- @return table|nil The imported data as a sequence of sequences
--- @return string|nil Error message if import failed
local function importLuaTSVFile(filePath)
    local content, err = readFile(filePath)
    if not content then
        return nil, "Failed to read TSV file: " .. tostring(err)
    end

    local result = {}
    local lineNum = 0
    for line in content:gmatch("[^\r\n]+") do
        lineNum = lineNum + 1
        local trimmed = trim(line)
        -- Skip comments and blank lines
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local cells = split(line, "\t")
            local row = {}
            for j, cell in ipairs(cells) do
                if cell == "" then
                    row[j] = nil
                else
                    local val, cellErr = deserialize(cell)
                    if cellErr then
                        return nil, "Failed to parse cell at line " .. lineNum .. ", column " .. j .. ": " .. tostring(cellErr)
                    end
                    row[j] = val
                end
            end
            result[#result + 1] = row
        end
    end

    return result, nil
end

--- Imports a TSV file with typed JSON values.
--- @param filePath string Path to the .tsv file
--- @return table|nil The imported data as a sequence of sequences
--- @return string|nil Error message if import failed
local function importTypedJSONTSVFile(filePath)
    local content, err = readFile(filePath)
    if not content then
        return nil, "Failed to read TSV file: " .. tostring(err)
    end

    local result = {}
    local lineNum = 0
    for line in content:gmatch("[^\r\n]+") do
        lineNum = lineNum + 1
        local trimmed = trim(line)
        -- Skip comments and blank lines
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local cells = split(line, "\t")
            local row = {}
            for j, cell in ipairs(cells) do
                if cell == "" then
                    row[j] = nil
                else
                    local val, cellErr = deserializeJSON(cell)
                    if cellErr then
                        return nil, "Failed to parse cell at line " .. lineNum .. ", column " .. j .. ": " .. tostring(cellErr)
                    end
                    row[j] = val
                end
            end
            result[#result + 1] = row
        end
    end

    return result, nil
end

--- Imports a TSV file with natural JSON values.
--- @param filePath string Path to the .tsv file
--- @return table|nil The imported data as a sequence of sequences
--- @return string|nil Error message if import failed
local function importNaturalJSONTSVFile(filePath)
    local content, err = readFile(filePath)
    if not content then
        return nil, "Failed to read TSV file: " .. tostring(err)
    end

    local result = {}
    local lineNum = 0
    for line in content:gmatch("[^\r\n]+") do
        lineNum = lineNum + 1
        local trimmed = trim(line)
        -- Skip comments and blank lines
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local cells = split(line, "\t")
            local row = {}
            for j, cell in ipairs(cells) do
                if cell == "" then
                    row[j] = nil
                else
                    local val, cellErr = deserializeNaturalJSON(cell)
                    if cellErr then
                        return nil, "Failed to parse cell at line " .. lineNum .. ", column " .. j .. ": " .. tostring(cellErr)
                    end
                    row[j] = val
                end
            end
            result[#result + 1] = row
        end
    end

    return result, nil
end

-- ============================================================================
-- XML FILE IMPORT
-- ============================================================================

--- Imports an XML file in our specific format.
--- @param filePath string Path to the .xml file
--- @return table|nil The imported data as a sequence of sequences
--- @return string|nil Error message if import failed
local function importXMLFile(filePath)
    local content, err = readFile(filePath)
    if not content then
        return nil, "Failed to read XML file: " .. tostring(err)
    end

    -- Skip XML declaration if present
    local dataStart = content:find("<file>")
    if not dataStart then
        return nil, "Expected <file> tag"
    end

    -- Find end of file tag
    local dataEnd = content:find("</file>")
    if not dataEnd then
        return nil, "Expected </file> tag"
    end

    -- Extract content between <file> and </file>
    local fileContent = content:sub(dataStart + 6, dataEnd - 1)

    local result = {}
    local pos = 1

    -- Parse each row (header or row tag)
    while pos <= #fileContent do
        -- Skip whitespace
        pos = fileContent:match("^%s*()", pos)
        if pos > #fileContent then break end

        -- Check for header or row tag
        local tagStart, tagEnd, tagName = fileContent:find("<(header)>", pos)
        if not tagStart then
            tagStart, tagEnd, tagName = fileContent:find("<(row)>", pos)
        end

        if not tagStart then
            break
        end

        -- Find closing tag
        local closeTag = "</" .. tagName .. ">"
        local closeStart = fileContent:find(closeTag, tagEnd + 1, true)
        if not closeStart then
            return nil, "Missing closing </" .. tagName .. "> tag"
        end

        -- Extract row content
        local rowContent = fileContent:sub(tagEnd + 1, closeStart - 1)

        -- Parse each cell in the row
        local row = {}
        local cellIdx = 0
        local cellPos = 1
        while cellPos <= #rowContent do
            -- Skip whitespace
            cellPos = rowContent:match("^%s*()", cellPos)
            if cellPos > #rowContent then break end

            -- Parse the XML value
            -- newPos is relative to the substring, so add (cellPos - 1) to get position in rowContent
            local val, newPos, parseErr = deserialization.deserializeXML(rowContent:sub(cellPos))
            if parseErr then
                return nil, "Failed to parse cell: " .. tostring(parseErr)
            end
            if not newPos then
                -- No more content to parse
                break
            end
            -- Use explicit index to preserve nil values in their correct positions
            cellIdx = cellIdx + 1
            row[cellIdx] = val

            -- Use the position returned by deserializeXML (handles nested elements correctly)
            cellPos = cellPos + newPos - 1
        end

        result[#result + 1] = row
        pos = closeStart + #closeTag
    end

    return result, nil
end

-- ============================================================================
-- MESSAGEPACK FILE IMPORT
-- ============================================================================

--- Imports a MessagePack file.
--- @param filePath string Path to the .mpk file
--- @return table|nil The imported data
--- @return string|nil Error message if import failed
local function importMessagePackFile(filePath)
    local content, err = readFile(filePath)
    if not content then
        return nil, "Failed to read MPK file: " .. tostring(err)
    end

    return deserializeMessagePack(content)
end

-- ============================================================================
-- SQL FILE IMPORT
-- ============================================================================

--- Parses SQL file content and extracts data.
--- This parses our specific SQL export format (CREATE TABLE + INSERT).
--- @param content string The SQL file content
--- @param tableDeserializer function|nil Function to deserialize table columns (default: deserializeJSON)
--- @return table|nil The extracted data as a sequence of sequences
--- @return string|nil Error message if parsing failed
local function parseSQLContent(content, tableDeserializer)
    local deserializeTable = tableDeserializer or deserializeJSON

    local result = {}

    -- Extract column names from CREATE TABLE
    -- Format: CREATE TABLE "tablename" (\n  "col1" TYPE,\n  "col2" TYPE\n)
    local colDefs = content:match('CREATE TABLE ".-"%s*(%b())')
    if not colDefs then
        return nil, "Could not find CREATE TABLE statement"
    end

    local columns = {}
    colDefs = colDefs:sub(2, -2)  -- Remove outer parentheses
    if colDefs then
        for colDef in colDefs:gmatch('[^,]+') do
            local colName = colDef:match('"([^"]+)"')
            if colName then
                columns[#columns + 1] = colName
            end
        end
    end

    if #columns == 0 then
        return nil, "Could not extract column names from CREATE TABLE"
    end

    -- Add header row
    result[1] = columns

    -- Find INSERT statement and VALUES
    local valuesStart = content:find("VALUES")
    if not valuesStart then
        -- No data, just return header
        return result, nil
    end

    -- Parse each row of values
    local valuesSection = content:sub(valuesStart + 6)

    -- Find each row: (value1, value2, ...)
    local pos = 1
    while true do
        local rowStart = valuesSection:find("%(", pos)
        if not rowStart then break end

        -- Find matching closing paren, accounting for nested parens and strings
        local depth = 1
        local rowEnd = rowStart + 1
        local inString = false
        local stringChar = nil

        while rowEnd <= #valuesSection and depth > 0 do
            local char = valuesSection:sub(rowEnd, rowEnd)
            if inString then
                if char == stringChar then
                    -- Check for escaped quote
                    local nextChar = valuesSection:sub(rowEnd + 1, rowEnd + 1)
                    if nextChar == stringChar then
                        rowEnd = rowEnd + 1  -- Skip escaped quote
                    else
                        inString = false
                    end
                end
            else
                if char == "'" then
                    inString = true
                    stringChar = "'"
                elseif char == "(" then
                    depth = depth + 1
                elseif char == ")" then
                    depth = depth - 1
                end
            end
            rowEnd = rowEnd + 1
        end

        if depth ~= 0 then
            return nil, "Unmatched parenthesis in VALUES"
        end

        -- Extract row content (between parens)
        local rowContent = valuesSection:sub(rowStart + 1, rowEnd - 2)

        -- Parse values
        local row = {}
        local valPos = 1
        local colIdx = 1

        while valPos <= #rowContent do
            -- Skip whitespace
            valPos = rowContent:match("^%s*()", valPos)
            if valPos > #rowContent then break end

            local char = rowContent:sub(valPos, valPos)
            local value

            if char == "'" then
                -- String value - find closing quote
                local strEnd = valPos + 1
                local strContent = {}
                while strEnd <= #rowContent do
                    local c = rowContent:sub(strEnd, strEnd)
                    if c == "'" then
                        local nextC = rowContent:sub(strEnd + 1, strEnd + 1)
                        if nextC == "'" then
                            -- Escaped quote
                            strContent[#strContent + 1] = "'"
                            strEnd = strEnd + 2
                        else
                            -- End of string
                            break
                        end
                    else
                        strContent[#strContent + 1] = c
                        strEnd = strEnd + 1
                    end
                end
                local str = table.concat(strContent)

                -- Check if this looks like a serialized table (JSON, XML, etc.)
                if str:sub(1, 1) == "[" or str:sub(1, 1) == "{" or str:sub(1, 6) == "<table" then
                    local tableVal, tableErr = deserializeTable(str)
                    if tableErr then
                        value = str  -- Fall back to string if deserialization fails
                    else
                        value = tableVal
                    end
                else
                    value = str
                end
                valPos = strEnd + 1
            elseif char == "X" and rowContent:sub(valPos, valPos + 1) == "X'" then
                -- BLOB value
                local blobEnd = rowContent:find("'", valPos + 2)
                if blobEnd then
                    local blob = rowContent:sub(valPos, blobEnd)
                    local blobVal, blobErr = deserialization.deserializeMessagePackSQLBlob(blob)
                    if blobErr then
                        return nil, "Failed to deserialize BLOB: " .. tostring(blobErr)
                    end
                    value = blobVal
                    valPos = blobEnd + 1
                else
                    return nil, "Unterminated BLOB literal"
                end
            elseif rowContent:sub(valPos, valPos + 3) == "NULL" then
                value = nil
                valPos = valPos + 4
            elseif char:match("[%d%-]") then
                -- Number
                local numEnd = rowContent:find("[^%d%.%-eE]", valPos)
                local numStr
                if numEnd then
                    numStr = rowContent:sub(valPos, numEnd - 1)
                    valPos = numEnd
                else
                    numStr = rowContent:sub(valPos)
                    valPos = #rowContent + 1
                end
                value = tonumber(numStr)
            else
                -- Unknown, try to read until comma
                local nextComma = rowContent:find(",", valPos)
                if nextComma then
                    value = rowContent:sub(valPos, nextComma - 1)
                    valPos = nextComma
                else
                    value = rowContent:sub(valPos)
                    valPos = #rowContent + 1
                end
            end

            row[colIdx] = value
            colIdx = colIdx + 1

            -- Skip comma and whitespace
            valPos = rowContent:match("^%s*,?%s*()", valPos)
        end

        result[#result + 1] = row
        pos = rowEnd
    end

    return result, nil
end

--- Imports an SQL file.
--- @param filePath string Path to the .sql file
--- @param tableDeserializer function|nil Function to deserialize table columns
--- @return table|nil The imported data as a sequence of sequences
--- @return string|nil Error message if import failed
local function importSQLFile(filePath, tableDeserializer)
    local content, err = readFile(filePath)
    if not content then
        return nil, "Failed to read SQL file: " .. tostring(err)
    end

    return parseSQLContent(content, tableDeserializer)
end

--- Imports an SQL file using SQLite3 if available.
--- Falls back to parsing if SQLite is not available.
--- @param filePath string Path to the .sql file
--- @param tableDeserializer function|nil Function to deserialize table columns
--- @return table|nil The imported data as a sequence of sequences
--- @return string|nil Error message if import failed
local function importSQLFileWithSQLite(filePath, tableDeserializer)
    -- Try to use SQLite if available
    local ok, sqlite3 = pcall(require, "lsqlite3")
    if not ok then
        logger:info("SQLite3 not available, using SQL parser")
        return importSQLFile(filePath, tableDeserializer)
    end

    local content, err = readFile(filePath)
    if not content then
        return nil, "Failed to read SQL file: " .. tostring(err)
    end

    -- Create in-memory database
    local db = sqlite3.open_memory()
    if not db then
        return nil, "Failed to create in-memory database"
    end

    -- Execute the SQL
    local execErr = db:exec(content)
    if execErr ~= sqlite3.OK then
        local errMsg = db:errmsg()
        db:close()
        return nil, "SQL execution error: " .. tostring(errMsg)
    end

    -- Get table name from CREATE TABLE statement
    local tableName = content:match('CREATE TABLE "([^"]+)"')
    if not tableName then
        db:close()
        return nil, "Could not extract table name"
    end

    -- Query all data
    local result = {}
    local columns = nil

    for row in db:nrows("SELECT * FROM \"" .. tableName .. "\"") do
        if not columns then
            -- Extract column names from first row
            columns = {}
            for k in pairs(row) do
                columns[#columns + 1] = k
            end
            table.sort(columns)  -- Ensure consistent order
            result[1] = columns
        end

        -- Extract values in column order
        local dataRow = {}
        for i, col in ipairs(columns) do
            local val = row[col]
            -- Deserialize table values if needed
            if type(val) == "string" then
                if val:sub(1, 1) == "[" or val:sub(1, 1) == "{" or val:sub(1, 6) == "<table" then
                    local deserializer = tableDeserializer or deserializeJSON
                    local tableVal, tableErr = deserializer(val)
                    if not tableErr then
                        val = tableVal
                    end
                end
            end
            dataRow[i] = val
        end
        result[#result + 1] = dataRow
    end

    db:close()
    return result, nil
end

-- ============================================================================
-- AUTO-DETECT IMPORT
-- ============================================================================

--- Auto-detects file format and imports accordingly.
--- @param filePath string Path to the file
--- @param dataFormat string|nil Optional data format hint for TSV/SQL files
--- @return table|nil The imported data
--- @return string|nil Error message if import failed
local function importFile(filePath, dataFormat)
    if hasExtension(filePath, "lua") then
        return importLuaFile(filePath)
    elseif hasExtension(filePath, "json") then
        if dataFormat == "json-typed" then
            return importTypedJSONFile(filePath)
        else
            return importNaturalJSONFile(filePath)
        end
    elseif hasExtension(filePath, "tsv") then
        if dataFormat == "json-typed" then
            return importTypedJSONTSVFile(filePath)
        elseif dataFormat == "json-natural" then
            return importNaturalJSONTSVFile(filePath)
        else
            return importLuaTSVFile(filePath)
        end
    elseif hasExtension(filePath, "xml") then
        return importXMLFile(filePath)
    elseif hasExtension(filePath, "mpk") then
        return importMessagePackFile(filePath)
    elseif hasExtension(filePath, "sql") then
        local deserializer
        if dataFormat == "json-typed" then
            deserializer = deserializeJSON
        elseif dataFormat == "json-natural" then
            deserializer = deserializeNaturalJSON
        elseif dataFormat == "xml" then
            deserializer = deserializeXML
        elseif dataFormat == "mpk" then
            deserializer = deserialization.deserializeMessagePackSQLBlob
        end
        return importSQLFileWithSQLite(filePath, deserializer)
    else
        return nil, "Unknown file extension"
    end
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    importFile = importFile,
    importLuaFile = importLuaFile,
    importLuaTSVFile = importLuaTSVFile,
    importMessagePackFile = importMessagePackFile,
    importNaturalJSONFile = importNaturalJSONFile,
    importNaturalJSONTSVFile = importNaturalJSONTSVFile,
    importSQLFile = importSQLFile,
    importSQLFileWithSQLite = importSQLFileWithSQLite,
    importTypedJSONFile = importTypedJSONFile,
    importTypedJSONTSVFile = importTypedJSONTSVFile,
    importXMLFile = importXMLFile,
    parseSQLContent = parseSQLContent,
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
