-- Module name
local NAME = "importer"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 34, 0)

-- Dependencies
local read_only = require("util.read_only")
local readOnly = read_only.readOnly
local file_util = require("infra.file_util")
local readFile = file_util.readFile
local hasExtension = file_util.hasExtension

local deserialization = require("serde.deserialization")
local deserialize = deserialization.deserialize
local deserializeJSON = deserialization.deserializeJSON
local deserializeNaturalJSON = deserialization.deserializeNaturalJSON
local deserializeXML = deserialization.deserializeXML
local deserializeMessagePack = deserialization.deserializeMessagePack

local base64 = require("util.base64")
local int64 = require("util.int64")

-- The reader's half of the SQL format. sql_schema is a LEAF (it requires
-- neither the exporter nor the content pipeline), and sharing it is the point:
-- the metadata table's name, its row-0 sentinel and the version marker have to
-- be spelled here exactly as the writer spelled them, and two copies of a
-- constant is how that stops being true.
local sql_schema = require("serde.sql_schema")
local METADATA_TABLE = sql_schema.METADATA_TABLE
local SCHEMA_VERSION = sql_schema.SCHEMA_VERSION

-- True if a declared TabuLua column type is an int64 (or an alias of one). The
-- type text comes from the embedded tabulua_schema table, which stores the
-- DECLARED type_spec, so a user type extending int64 is not recognized here --
-- as it was not by the type comment this replaced; the plain prefix test covers
-- "int64" and "int64|nil".
local function isInt64ColumnType(declared)
    return declared ~= nil and declared:match("^int64") ~= nil
end

local string_utils = require("util.string_utils")
local split = string_utils.split
local trim = string_utils.trim

local dkjson = require("dkjson")

local logger = require("infra.named_logger").getLogger(NAME)

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
    --
    -- Process the ALREADY-DECODED row; do NOT re-encode it. A row with an empty
    -- optional column decodes to a Lua table with HOLES, and dkjson encodes a
    -- holed table as an OBJECT with string keys ({"1":...,"2":...}), so the
    -- re-encoded row came back keyed by "1" instead of 1 and every cell read as
    -- missing. Patch files, whose rows are sparse by nature, hit this on nearly
    -- every row. processTypedValue exists for exactly this case.
    local result = {}
    for i, row in ipairs(parsed) do
        local rowData, rowErr = deserialization.processTypedValue(row)
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

    -- Each row is a standard JSON array. Process the ALREADY-DECODED row, for
    -- the same reason as the typed path above: re-encoding a row that has holes
    -- (an empty optional column) turns it into an object keyed by "1", "2", ...
    local result = {}
    for i, row in ipairs(parsed) do
        local rowData, rowErr = deserialization.processNaturalValue(row)
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

    -- Skip XML declaration if present. The root may carry attributes (the
    -- exporter now emits <file xmlns="urn:tabulua:table:1">), so locate the
    -- opening tag by its name and skip to the end of that tag rather than
    -- assuming a fixed-width "<file>".
    local dataStart = content:find("<file")
    if not dataStart then
        return nil, "Expected <file> tag"
    end

    -- Find end of file tag
    local dataEnd = content:find("</file>")
    if not dataEnd then
        return nil, "Expected </file> tag"
    end

    -- Extract content between the opening <file ...> tag and </file>.
    local openEnd = content:find(">", dataStart)
    if not openEnd or openEnd >= dataEnd then
        return nil, "Malformed <file> opening tag"
    end
    local fileContent = content:sub(openEnd + 1, dataEnd - 1)

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
            local val, parseErr, newPos = deserialization.deserializeXML(rowContent:sub(cellPos))
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

-- Every CREATE TABLE in the file, in declaration order: {name, body}.
-- Matches both `CREATE TABLE "x" (...)` and the metadata table's
-- `CREATE TABLE IF NOT EXISTS "x" (...)`.
local function extractSQLTableDefs(content)
    local defs = {}
    for name, body in
        content:gmatch('CREATE%s+TABLE%s+[%a%s]*"([^"]+)"%s*(%b())') do
        defs[#defs + 1] = {name = name, body = body}
    end
    return defs
end

-- Column names from a CREATE TABLE body, in declaration order.
-- Format: (\n  "col1" TYPE,\n  "col2" TYPE\n)
local function columnNamesFromBody(body)
    local columns = {}
    for colDef in body:sub(2, -2):gmatch('[^,]+') do
        local colName = colDef:match('"([^"]+)"')
        if colName then
            columns[#columns + 1] = colName
        end
    end
    return columns
end

-- The one DATA table in the file: the CREATE TABLE that is not the embedded
-- metadata table.
--
-- Which table holds the data can no longer be answered with "the first
-- CREATE TABLE" -- every exported file now opens with the tabulua_schema DDL --
-- so it is answered by NAME. Two data tables is a refusal rather than a guess:
-- a whole-export concatenation is a database, not a dataset, and picking one of
-- its tables silently would import the wrong file.
local function findDataTable(defs)
    if #defs == 0 then
        return nil, "Could not find CREATE TABLE statement"
    end
    local data, declared = nil, false
    for _, d in ipairs(defs) do
        if d.name == METADATA_TABLE then
            declared = true
        else
            if data then
                return nil, "Expected a single data table, found at least two: '"
                    .. data.name .. "' and '" .. d.name
                    .. "' (a concatenated export is a database, not a dataset)"
            end
            data = d
        end
    end
    if not data then
        return nil, "The file declares only the '" .. METADATA_TABLE
            .. "' metadata table, and no data table"
    end
    local columns = columnNamesFromBody(data.body)
    if #columns == 0 then
        return nil, "Could not extract column names from CREATE TABLE"
    end
    data.columns = columns
    data.declaresMetadata = declared
    return data
end

--- Splits a VALUES section into its `(...)` tuples, as raw text.
---
--- Stops at the `;` that terminates the statement, so a file holding several
--- INSERTs -- every exported file now does: the metadata one, then the data
--- one -- does not bleed from one into the next.
--- @param section string The text following the VALUES keyword
--- @return table|nil Sequence of tuple bodies (the text between parentheses)
--- @return string|nil Error message
local function scanTuples(section)
    local tuples = {}
    local pos = 1
    while true do
        local rowStart = section:find("%(", pos)
        if not rowStart then break end

        -- Find matching closing paren, accounting for nested parens and strings
        local depth = 1
        local rowEnd = rowStart + 1
        local inString = false

        while rowEnd <= #section and depth > 0 do
            local char = section:sub(rowEnd, rowEnd)
            if inString then
                if char == "'" then
                    -- Check for escaped quote
                    if section:sub(rowEnd + 1, rowEnd + 1) == "'" then
                        rowEnd = rowEnd + 1  -- Skip escaped quote
                    else
                        inString = false
                    end
                end
            else
                if char == "'" then
                    inString = true
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

        tuples[#tuples + 1] = section:sub(rowStart + 1, rowEnd - 2)
        pos = rowEnd
        if section:match("^%s*;", pos) then break end
    end
    return tuples
end

--- Parses one tuple's comma-separated SQL literals.
--- @param rowContent string The text between the tuple's parentheses
--- @param deserializeTable function|nil Deserializer for composite cells; nil
---   keeps them as their raw text, which is what the metadata rows want
--- @param typeAt function|nil i -> declared TabuLua type of the i-th value
--- @return table|nil The values (a sequence, with holes where NULL)
--- @return string|nil Error message
--- @return number|nil How many values -- `#` cannot say, over holes
local function parseValueList(rowContent, deserializeTable, typeAt)
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

            -- A MessagePack cell: the mpk bytes hex-wrapped as X'...' and
            -- stored as a STRING (a bytes COLUMN is instead an unquoted
            -- BLOB literal, handled below -- the two are distinct, and
            -- were previously handled the wrong way round).
            if deserializeTable and str:match("^X'%x*'$") and #str % 2 == 1 then
                local mpkVal, mpkErr =
                    deserialization.deserializeMessagePackSQLBlob(str)
                if mpkErr then
                    value = str  -- Not ours after all; keep the text
                else
                    value = mpkVal
                end
            -- Check if this looks like a serialized table (JSON, XML, etc.)
            elseif deserializeTable and (str:sub(1, 1) == "["
                or str:sub(1, 1) == "{" or str:sub(1, 6) == "<table") then
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
            -- An unquoted BLOB literal is a BYTES COLUMN: raw bytes, NOT
            -- MessagePack. Decoding it as mpk was not merely wrong, it was
            -- silently wrong -- X'18' decoded to the number 24 and
            -- X'C3' to true, with no error.
            --
            -- The model value behind those bytes is TEXT, and which text
            -- depends on the declared type: hex digits for hexbytes, base64
            -- for base64bytes. That is why the embedded schema matters -- the
            -- BLOB alone cannot say which.
            local blobEnd = rowContent:find("'", valPos + 2)
            if blobEnd then
                local blob = rowContent:sub(valPos, blobEnd)
                local binary, blobErr =
                    deserialization.deserializeSQLBlob(blob)
                if blobErr then
                    return nil, "Failed to deserialize BLOB: " .. tostring(blobErr)
                end
                local declared = typeAt and typeAt(colIdx) or nil
                if declared and declared:match("^base64bytes") then
                    value = base64.encode(binary)
                else
                    -- hexbytes, or unknown: the hex digits as written
                    value = blob:sub(3, -2)
                end
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
            -- A BIGINT column is read from its DIGITS, never through
            -- tonumber: tonumber("9007199254740993") is already rounded on
            -- LuaJIT, where every number is a double, so the box would be
            -- built from a value the file never contained.
            if isInt64ColumnType(typeAt and typeAt(colIdx) or nil) then
                local box, boxErr = int64.of(numStr)
                if box == nil then
                    return nil, "Failed to read int64 column " .. colIdx
                        .. ": " .. tostring(boxErr)
                end
                value = box
            else
                value = tonumber(numStr)
            end
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

    return row, nil, colIdx - 1
end

--- The tuple bodies of every `INSERT INTO "<tableName>" ... VALUES` in a file.
--- @param content string The SQL file content
--- @param tableName string The table being inserted into
--- @return table|nil Sequence of tuple bodies
--- @return string|nil Error message
local function insertedTuples(content, tableName)
    local tuples = {}
    local needle = 'INSERT INTO "' .. tableName .. '"'
    local from = 1
    while true do
        local s, e = content:find(needle, from, true)
        if not s then break end
        local v = content:find("VALUES", e + 1, true)
        if v then
            local found, err = scanTuples(content:sub(v + 6))
            if not found then
                return nil, err
            end
            for _, t in ipairs(found) do
                tuples[#tuples + 1] = t
            end
        end
        from = e + 1
    end
    return tuples
end

-- A tabulua_schema row: table_name, column_name, sql_name, position, type,
-- default, attributes.
local METADATA_COLUMN_COUNT = 7

-- The v1 `tabulua` vocabulary: table-level keys the reader knows, and the Lua
-- type each must have. Anything else under `tabulua` is preserved and ignored,
-- as is everything under `app` (application-owned, carried verbatim, never
-- interpreted) and under any other top-level key (reserved).
--
-- Nothing here is BEHAVIORAL in the dangerous sense: no entry changes how a
-- cell is parsed, validated or evaluated, and nothing in the bag is ever handed
-- to the sandbox or to `load`. That is the property that stops a hand-authored
-- .sql from becoming a code-injection surface.
local TABULUA_ATTRIBUTES = {
    version = "string",
    model_name = "string",
    collapsed = "boolean",
}

--- Reads row 0's `attributes` bag.
---
--- NULL, or a JSON OBJECT -- an array, a scalar or unparseable text is a hard
--- error rather than a silent shrug, because everything the reader is about to
--- do rests on this file being what it claims to be. Unknown keys are preserved
--- untouched (forward compatibility); v1 interprets only the three keys above,
--- and none of them gates whether the file is read.
--- @param raw string|nil The cell text
--- @return table|nil The decoded bag ({} when NULL)
--- @return string|nil Error message
local function parseAttributes(raw)
    if raw == nil then
        return {}
    end
    if type(raw) ~= "string" then
        return nil, "attributes must be TEXT holding a JSON object"
    end
    -- Bounded: a preserved payload from a file the reader does not control.
    if #raw > sql_schema.MAX_ATTRIBUTES_BYTES then
        return nil, "attributes is " .. #raw .. " bytes, over the "
            .. sql_schema.MAX_ATTRIBUTES_BYTES .. "-byte cap"
    end
    local decoded, err = deserializeNaturalJSON(raw)
    if err or type(decoded) ~= "table" then
        return nil, "attributes is not valid JSON: " .. tostring(err or raw)
    end
    if decoded[1] ~= nil then
        return nil, "attributes must be a JSON object, not an array"
    end
    -- An empty object is the same as NULL.
    local tabulua = decoded.tabulua
    if tabulua ~= nil then
        if type(tabulua) ~= "table" or tabulua[1] ~= nil then
            return nil, "attributes.tabulua must be a JSON object"
        end
        for key, expected in pairs(TABULUA_ATTRIBUTES) do
            local v = tabulua[key]
            if v ~= nil and type(v) ~= expected then
                return nil, "attributes.tabulua." .. key .. " must be a "
                    .. expected .. ", found " .. type(v)
            end
        end
    end
    return decoded
end

--- Reads the embedded tabulua_schema rows describing one data table.
---
--- @param content string The SQL file content
--- @param dataTable table findDataTable's result
--- @return table|nil {version, modelName, columns = {{name, sqlName, typeSpec,
---   default, attributes}}}; nil with no error when the file carries no
---   metadata table at all
--- @return string|nil Error message
local function readSQLMetadata(content, dataTable)
    local tuples, err = insertedTuples(content, METADATA_TABLE)
    if not tuples then
        return nil, err
    end
    if #tuples == 0 then
        -- No metadata AND no claim to have any: an older or foreign export,
        -- read for what SQL alone says. But a file that DECLARES the table and
        -- then describes nothing is malformed, and falling back silently would
        -- read it under physical column names as if that were intended.
        if dataTable.declaresMetadata then
            return nil, "The file declares '" .. METADATA_TABLE
                .. "' but carries no rows in it"
        end
        return nil, nil
    end

    local tableRow, columns, seen = nil, {}, {}
    for _, body in ipairs(tuples) do
        local v, vErr, count = parseValueList(body, nil, nil)
        if not v then
            return nil, "Malformed " .. METADATA_TABLE .. " row: " .. tostring(vErr)
        end
        if count ~= METADATA_COLUMN_COUNT then
            return nil, "Malformed " .. METADATA_TABLE .. " row: expected "
                .. METADATA_COLUMN_COUNT .. " values, found " .. tostring(count)
        end
        -- Rows for another table are another file's, concatenated in; skip them.
        if v[1] == dataTable.name then
            local position = v[4]
            if type(position) ~= "number" then
                return nil, "Malformed " .. METADATA_TABLE
                    .. " row: position must be an integer, found "
                    .. tostring(position)
            end
            if position == 0 then
                tableRow = v
            elseif seen[position] then
                return nil, "Duplicate " .. METADATA_TABLE .. " position "
                    .. position .. " for table '" .. dataTable.name .. "'"
            else
                seen[position] = true
                columns[position] = {
                    name = v[2], sqlName = v[3], typeSpec = v[5],
                    default = v[6], attributes = v[7],
                }
            end
        end
    end

    if not tableRow then
        return nil, "No " .. METADATA_TABLE .. " table-info row (position 0) "
            .. "for table '" .. dataTable.name .. "'"
    end

    -- Column order is recoverable ONLY from the stored position: rows dumped
    -- out of a database come back unordered, so a gap is a lost column, not a
    -- cosmetic problem.
    local n = 0
    for position in pairs(seen) do
        if position > n then n = position end
    end
    for i = 1, n do
        if not columns[i] then
            return nil, "Missing " .. METADATA_TABLE .. " row for position "
                .. i .. " of table '" .. dataTable.name .. "'"
        end
    end

    local attrs, attrErr = parseAttributes(tableRow[7])
    if not attrs then
        return nil, attrErr
    end
    local tabulua = type(attrs.tabulua) == "table" and attrs.tabulua or {}

    -- The metadata describes exactly the physical columns, or the file is not
    -- describing itself. Reported with the version, because "written by a newer
    -- TabuLua" is the likeliest cause of a shape the reader does not know --
    -- provenance sharpening a structural failure, never gating on its own.
    local hint = ""
    if tabulua.version ~= nil and tabulua.version ~= SCHEMA_VERSION then
        hint = " (file written by TabuLua " .. tostring(tabulua.version)
            .. ", this is " .. SCHEMA_VERSION .. ")"
    end
    if n ~= #dataTable.columns then
        return nil, string.format(
            "%s describes %d column(s) but table '%s' has %d%s",
            METADATA_TABLE, n, dataTable.name, #dataTable.columns, hint)
    end

    -- Values are located by the STORED sql_name, never by re-running the
    -- exporter's name sanitizer and never by assuming physical order: a change
    -- to sqlColumnName then cannot mis-read a file written before it, and a
    -- hand-edited or length-capped physical name still imports.
    local physical = {}
    for i, name in ipairs(dataTable.columns) do
        physical[name] = i
    end
    for i = 1, n do
        local at = physical[columns[i].sqlName]
        if not at then
            return nil, string.format(
                "%s names column '%s' (sql_name '%s'), which table '%s' does not have%s",
                METADATA_TABLE, tostring(columns[i].name),
                tostring(columns[i].sqlName), dataTable.name, hint)
        end
        columns[i].at = at
    end

    return {
        version = tabulua.version,
        modelName = tabulua.model_name,
        collapsed = tabulua.collapsed or false,
        tableName = dataTable.name,
        attributes = attrs,
        columns = columns,
    }
end

--- Parses SQL file content and extracts data.
--- This parses our specific SQL export format (CREATE TABLE + INSERT).
---
--- When the file carries the embedded `tabulua_schema` table, that is the
--- source of truth: the header is labelled with the MODEL column names, ordered
--- by the stored position, and each value is located by its stored sql_name.
--- Without it, only the physical CREATE TABLE names are available and no
--- declared types are known -- so a BLOB cannot be told from base64 and a
--- BIGINT cannot be told from an int64.
--- @param content string The SQL file content
--- @param tableDeserializer function|nil Function to deserialize table columns (default: deserializeJSON)
--- @return table|nil The extracted data as a sequence of sequences
--- @return string|nil Error message if parsing failed
--- @return table|nil The embedded schema, when the file carries one
local function parseSQLContent(content, tableDeserializer)
    local deserializeTable = tableDeserializer or deserializeJSON

    local dataTable, tableErr = findDataTable(extractSQLTableDefs(content))
    if not dataTable then
        return nil, tableErr
    end

    local schema, metaErr = readSQLMetadata(content, dataTable)
    if metaErr then
        return nil, metaErr
    end

    local result = {}
    local typeAt
    if schema then
        local header, typeByPosition = {}, {}
        for i, col in ipairs(schema.columns) do
            header[i] = col.name
            typeByPosition[col.at] = col.typeSpec
        end
        result[1] = header
        typeAt = function(i) return typeByPosition[i] end
    else
        result[1] = dataTable.columns
    end

    local tuples, scanErr = insertedTuples(content, dataTable.name)
    if not tuples then
        return nil, scanErr
    end

    for _, body in ipairs(tuples) do
        local values, valErr = parseValueList(body, deserializeTable, typeAt)
        if not values then
            return nil, valErr
        end
        if schema then
            -- Physical order -> model order. Identical for our own exports, but
            -- the mapping is what lets a file whose columns were reordered, or
            -- whose names were rewritten, still read correctly.
            local row = {}
            for i, col in ipairs(schema.columns) do
                row[i] = values[col.at]
            end
            result[#result + 1] = row
        else
            result[#result + 1] = values
        end
    end

    return result, nil, schema
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

--- Builds the SELECT for the SQLite import path, casting every int64 column to
--- TEXT so its digits survive.
---
--- lsqlite3 hands a BIGINT back as a Lua number. On LuaJIT that is a double, so
--- an id past 2^53 would be silently rounded on the way out of the database --
--- after being stored exactly. CAST(... AS TEXT) makes SQLite render the digits
--- itself, and int64.of() rebuilds the box from those exactly.
---
--- Exposed (and pure) because the environments this project is developed in
--- have no lsqlite3, so this is the part of that path that can still be tested.
--- @param tableName string The SQL table name
--- @param columns table Sequence of column names, in CREATE TABLE order
--- @param columnTypes table|nil name -> declared TabuLua type, if the file says
--- @return string The SELECT statement
local function buildInt64SafeSelect(tableName, columns, columnTypes)
    if columnTypes == nil or #columns == 0 then
        return 'SELECT * FROM "' .. tableName .. '"'
    end
    local parts = {}
    for i, name in ipairs(columns) do
        local quoted = '"' .. name .. '"'
        if isInt64ColumnType(columnTypes[name]) then
            parts[i] = "CAST(" .. quoted .. " AS TEXT) AS " .. quoted
        else
            parts[i] = quoted
        end
    end
    return "SELECT " .. table.concat(parts, ", ") .. ' FROM "' .. tableName .. '"'
end

--- Imports an SQL file by loading it into an in-memory SQLite database, or
--- falling back to the text parser when lsqlite3 is unavailable.
---
--- OPT-IN. `importFile` deliberately does NOT route here -- it uses the text
--- parser directly -- because this path DIVERGES from it and carries none of
--- the fixes the text path got: BLOB columns come back as raw bytes rather than
--- their hex/base64 text, and table columns are deserialized by a single
--- `val:sub(1,1)` heuristic instead of the caller's format. Nothing in
--- production reads SQL, so that divergence was never shipped. Use this only
--- when you specifically need a real engine to parse the DDL (its one proven
--- job today: the SQL-executability check in exporter_spec). int64 columns ARE
--- handled correctly here -- read as TEXT via buildInt64SafeSelect.
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

    -- The DATA table, by name -- not "the first CREATE TABLE", which is now the
    -- embedded tabulua_schema in every exported file.
    local dataTable, tableErr = findDataTable(extractSQLTableDefs(content))
    if not dataTable then
        db:close()
        return nil, tableErr
    end
    local tableName = dataTable.name
    local schema, metaErr = readSQLMetadata(content, dataTable)
    if metaErr then
        db:close()
        return nil, metaErr
    end

    -- Query all data. int64 columns come back as TEXT (see
    -- buildInt64SafeSelect) and are turned back into boxes below.
    local declaredColumns = dataTable.columns
    local columnTypes
    if schema then
        columnTypes = {}
        for _, col in ipairs(schema.columns) do
            columnTypes[col.sqlName] = col.typeSpec
        end
    end
    local query = buildInt64SafeSelect(tableName, declaredColumns, columnTypes)

    local result = {}
    -- Column order is the CREATE TABLE's DECLARATION order, not sorted.
    -- db:nrows yields an unordered map, so the previous code sorted the keys
    -- alphabetically -- which put the header in a different order from the
    -- text parser and from the model, so every header comparison failed the
    -- moment this path actually ran (it only does with lsqlite3 present).
    --
    -- With an embedded schema the header is the MODEL names in stored position
    -- order, exactly as the text parser reports them -- one fewer way for the
    -- two readers to disagree (see TODO/sql_input_round_trip.md's deferred
    -- lsqlite3 section, which lists their divergences).
    local columns = declaredColumns
    local labels = columns
    if schema then
        columns, labels = {}, {}
        for i, col in ipairs(schema.columns) do
            columns[i] = col.sqlName
            labels[i] = col.name
        end
    end
    result[1] = labels

    for row in db:nrows(query) do
        -- Extract values in column order
        local dataRow = {}
        for i, col in ipairs(columns) do
            local val = row[col]
            if isInt64ColumnType(columnTypes and columnTypes[col]) then
                local box, boxErr = int64.of(tostring(val))
                if box == nil then
                    db:close()
                    return nil, "Failed to read int64 column '" .. col
                        .. "': " .. tostring(boxErr)
                end
                val = box
            -- Deserialize table values if needed
            elseif type(val) == "string" then
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
        -- The TEXT parser, deliberately, not importSQLFileWithSQLite. The two
        -- diverge (BLOB decoding, per-format table deserialization, column
        -- order), and only the text path carries the fixes those needed --
        -- the SQLite path is exercised by nothing in production (the loader
        -- never reads SQL) so it never got them. Auto-detect must also behave
        -- the SAME whether or not lsqlite3 happens to be installed, which the
        -- SQLite path does not. importSQLFileWithSQLite stays as an explicit
        -- opt-in for a caller that truly wants a real engine to parse the DDL.
        return importSQLFile(filePath, deserializer)
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
    buildInt64SafeSelect = buildInt64SafeSelect,
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
