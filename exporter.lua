-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 9, 0)

-- Module name
local NAME = "exporter"

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

local logger = require( "named_logger").getLogger(NAME)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local file_util = require("file_util")
local pathJoin = file_util.pathJoin
local changeExtension = file_util.changeExtension
local hasExtension = file_util.hasExtension
local getParentPath = file_util.getParentPath
local isDir = file_util.isDir
local mkdir = file_util.mkdir
local splitPath = file_util.splitPath
local writeFile = file_util.writeFile

-- Manifest files now use .transposed.tsv extension, handled by hasExtension(file_name, "tsv")

local serialization = require("serialization")
local serialize = serialization.serialize
local serializeJSON = serialization.serializeJSON
local serializeNaturalJSON = serialization.serializeNaturalJSON
local serializeSQL = serialization.serializeSQL
local serializeTableJSON = serialization.serializeTableJSON
local serializeTableNaturalJSON = serialization.serializeTableNaturalJSON
local serializeXML = serialization.serializeXML
local serializeMessagePack = serialization.serializeMessagePack
local serializeSQLBlob = serialization.serializeSQLBlob

local base64 = require("base64")

local parsers = require("parsers")
local extendsOrRestrict = parsers.extendsOrRestrict
local parseType = parsers.parseType
local registerAlias = parsers.registerAlias
local unionTypes = parsers.unionTypes

local error_reporting = require("error_reporting")
local badValGen = error_reporting.badValGen

local raw_tsv = require("raw_tsv")

local tsv_model = require('tsv_model');
local processTSV = tsv_model.processTSV

local predicates = require("predicates")
local isName = predicates.isName

local exploded_columns = require("exploded_columns")
local assembleExplodedValue = exploded_columns.assembleExplodedValue
local generateCollapsedColumnSpec = exploded_columns.generateCollapsedColumnSpec

local file_joining = require("file_joining")
local shouldExport = file_joining.shouldExport
local groupSecondaryFiles = file_joining.groupSecondaryFiles
local findFilePath = file_joining.findFilePath
local joinFiles = file_joining.joinFiles

-- Returns true if a column is of type comment (or comment|nil, or a user type extending comment).
-- Comment columns are developer-only and should be stripped from exports.
local function isCommentColumn(col)
    local colType = col.type
    local baseType = colType:match("^(.+)|nil$") or colType
    return baseType == "comment" or extendsOrRestrict(baseType, "comment")
end

-- Returns true if a column is of type hexbytes (or extending it), stripping |nil suffix.
local function isHexBytesColumn(col)
    local colType = col.type
    local baseType = colType:match("^(.+)|nil$") or colType
    return baseType == "hexbytes" or extendsOrRestrict(baseType, "hexbytes")
end

-- Returns true if a column is of type base64bytes (or extending it), stripping |nil suffix.
local function isBase64BytesColumn(col)
    local colType = col.type
    local baseType = colType:match("^(.+)|nil$") or colType
    return baseType == "base64bytes" or extendsOrRestrict(baseType, "base64bytes")
end

-- Returns true if a column is a bytes type (hexbytes or base64bytes).
local function isBytesColumn(col)
    return isHexBytesColumn(col) or isBase64BytesColumn(col)
end

-- Converts a parsed bytes value to raw binary data.
local function bytesToBinary(col, value)
    if value == nil then return nil end
    if isHexBytesColumn(col) then
        return value:gsub("..", function(h) return string.char(tonumber(h, 16)) end)
    else
        return base64.decode(value)
    end
end

-- Lua base types
local base_types = {"boolean", "integer", "number", "string", "table"}

-- Computes the relative path of a file for export.
-- Uses file2dir to strip the source directory prefix from absolute paths.
local function computeRelativePath(file_name, file2dir)
    if not file2dir then return file_name end
    local dir = file2dir[file_name]
    if dir then
        return file_name:sub(#dir + 2)
    end
    return file_name
end

-- Ensures the parent directory of the given path exists.
-- Uses dirChecked table to avoid redundant checks.
-- Returns true on success, false on failure.
local function ensureParentDir(path, dirChecked)
    local parent = getParentPath(path)
    if parent and not dirChecked[parent] and not isDir(parent) then
        local success, err = mkdir(parent)
        if not success then
            logger:error("Failed to create directory " .. parent .. ": " .. err)
            return false
        end
        dirChecked[parent] = true
    end
    return true
end

-- Writes content to a file with logging.
-- Returns true on success, false on failure.
local function writeExportFile(path, content)
    logger:info("Exporting: " .. path)
    local ok, err = file_util.writeFile(path, content)
    if not ok then
        logger:error("Failed to write " .. path .. ": " .. err)
        return false
    end
    return true
end

-- Column names used for file joining metadata (to be excluded from exported Files.tsv)
local JOIN_COLUMNS = {
    joinInto = true,
    joinColumn = true,
    export = true,
    joinedTypeName = true,
}

-- Transforms Files.tsv for export by:
-- 1. Removing join-related columns from header
-- 2. Filtering out secondary files (files with joinInto set)
-- 3. Replacing typeName with joinedTypeName where appropriate
-- Returns transformed header, data rows, and column index mapping
local function transformFilesDescForExport(tsv, joinMeta)
    local originalHeader = tsv[1]

    -- Build new header without join columns, tracking column mappings
    local newHeader = {}
    local colMapping = {}  -- maps new col index -> original col index
    local typeNameIdx = nil
    local joinedTypeNameIdx = nil

    for i, col in ipairs(originalHeader) do
        if col.name == "typeName" then
            typeNameIdx = i
        end
        if col.name == "joinedTypeName" then
            joinedTypeNameIdx = i
        end
        if not JOIN_COLUMNS[col.name] then
            newHeader[#newHeader + 1] = col
            colMapping[#newHeader] = i
        end
    end

    -- Build filtered rows
    local newRows = {}
    for rowIdx, row in ipairs(tsv) do
        if rowIdx > 1 and type(row) == "table" then
            -- Get the filename to check if it's a secondary file
            local fileName = row[1] and row[1].parsed
            local lcfn = fileName and fileName:lower() or ""

            -- Skip secondary files (those with joinInto set)
            if joinMeta and joinMeta.lcFn2JoinInto[lcfn] then
                -- This is a secondary file, skip it
            else
                -- Build new row with remapped columns
                local newRow = {}
                for newIdx, origIdx in ipairs(colMapping) do
                    local cell = row[origIdx]
                    -- Special handling for typeName column: use joinedTypeName if available
                    if origIdx == typeNameIdx and joinedTypeNameIdx then
                        local joinedTypeName = row[joinedTypeNameIdx]
                        if joinedTypeName and joinedTypeName.parsed and joinedTypeName.parsed ~= "" then
                            -- Create a modified cell with joinedTypeName value
                            newRow[newIdx] = {
                                parsed = joinedTypeName.parsed,
                                value = joinedTypeName.value,
                                reformatted = joinedTypeName.reformatted,
                            }
                        else
                            newRow[newIdx] = cell
                        end
                    else
                        newRow[newIdx] = cell
                    end
                end
                newRows[#newRows + 1] = newRow
            end
        end
    end

    return newHeader, newRows, colMapping
end

-- Checks if a file path corresponds to a Files.tsv descriptor file
local function isFilesDescriptor(file_name)
    local lower = file_name:lower()
    return lower:match("/files%.tsv$") or lower:match("\\files%.tsv$") or lower == "files.tsv"
end

-- Builds a type specification string from a header (array of column definitions)
-- Each column should have 'name' and 'type_spec' fields
local function buildTypeSpecFromHeader(header)
    local parts = {}
    for _, col in ipairs(header) do
        if col.name and col.type_spec then
            parts[#parts + 1] = col.name .. ":" .. col.type_spec
        end
    end
    if #parts == 0 then
        return nil
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Registers a joined type in the type system
-- Returns true on success, false on failure
local function registerJoinedType(joinedTypeName, joinedHeader)
    if not joinedTypeName or joinedTypeName == "" then
        return false
    end
    local typeSpec = buildTypeSpecFromHeader(joinedHeader)
    if not typeSpec then
        logger:warn("Could not build type spec for joined type: " .. joinedTypeName)
        return false
    end
    local badVal = badValGen()
    if registerAlias(badVal, joinedTypeName, typeSpec) then
        logger:info("Registered joined type: " .. joinedTypeName .. " = " .. typeSpec)
        return true
    else
        logger:warn("Failed to register joined type: " .. joinedTypeName)
        return false
    end
end

-- Maps "our types" to SQLite types. This is a *cache*; it will be extended with every new column type
-- we encounters.
local sql_types = {
    ["string"] = "TEXT",
    ["number"] = "REAL",
    ["integer"] = "BIGINT",
    ["boolean"] = "SMALLINT", -- BOOLEAN is not available everywhere, so use SMALLINT with values 0/1
    ["table"] = "TEXT", -- tables are encoded as JSON, and therefore become strings
}

-- Export the parsed files in the "TSV" format.
-- Returns true on success
-- exportParams.exportExploded: if true (default), export exploded columns as-is
--   if false, collapse exploded columns into single composite columns
local function exportTSV(process_files, exportParams, serializer)
    local tsv_files = process_files.tsv_files
    local raw_files = process_files.raw_files
    local joinMeta = process_files.joinMeta
    local file2dir = process_files.file2dir
    local baseExportDir = exportParams.exportDir
    local formatSubdir = exportParams.formatSubdir or ""
    local exportDir = formatSubdir ~= "" and pathJoin(baseExportDir, formatSubdir) or baseExportDir
    local filePrefix = exportParams.filePrefix or ""
    local fileSuffix = exportParams.fileSuffix or ""
    local linePrefix = exportParams.linePrefix or ""
    local lineSuffix = exportParams.lineSuffix or ""
    local lineSep = exportParams.lineSep or "\n"
    local colSep = exportParams.colSep or "\t"
    local fileExt = exportParams.fileExt or "tsv"
    -- Default to true: export exploded columns as separate flat columns
    local exportExploded = exportParams.exportExploded
    if exportExploded == nil then exportExploded = true end

    -- Build map of primary files to their secondary files for joining
    local secondaryGroups = joinMeta and groupSecondaryFiles(joinMeta) or {}

    local dirChecked = {}
    for file_name, content in pairs(raw_files) do
        local content2 = content
        -- Check if this file should be exported
        local lcfn = file_name:lower()
        -- Extract just the filename without path for lookup
        local idx = lcfn:find("/[^/]*$") or lcfn:find("\\[^\\]*$")
        local lcfnKey = idx and lcfn:sub(idx + 1) or lcfn
        if joinMeta and not shouldExport(lcfnKey, joinMeta) then
            logger:info("Skipping export of secondary file: " .. file_name)
            goto continue
        end
        local is_tsv = hasExtension(file_name, "tsv")
        local relative_name = computeRelativePath(file_name, file2dir)
        local new_name = pathJoin(exportDir, relative_name)
        if is_tsv and fileExt ~= "tsv" then
            new_name = changeExtension(new_name, fileExt)
        end
        if not ensureParentDir(new_name, dirChecked) then
            return false
        end
        if is_tsv then
            local tsv = tsv_files[file_name]
            if tsv == nil then
                logger:error("Failed to find TSV for " .. file_name)
            else
                -- Check if this is a primary file with secondary files to join
                local secondaryLcfns = secondaryGroups[lcfnKey]
                local joinedRows, joinedHeader = nil, nil
                if secondaryLcfns and #secondaryLcfns > 0 then
                    -- Build list of secondary TSV data for joining
                    local secondaryTsvList = {}
                    for _, secLcfn in ipairs(secondaryLcfns) do
                        local secPath = findFilePath(secLcfn, tsv_files)
                        if secPath and tsv_files[secPath] then
                            local joinColumn = joinMeta.lcFn2JoinColumn[secLcfn]
                            secondaryTsvList[#secondaryTsvList + 1] = {
                                tsv = tsv_files[secPath],
                                joinColumn = joinColumn,
                                sourceName = secPath,
                            }
                        else
                            logger:warn("Secondary file not found: " .. secLcfn)
                        end
                    end
                    if #secondaryTsvList > 0 then
                        -- Create a minimal badVal for error reporting
                        local badVal = {
                            source_name = file_name,
                            line_no = 0,
                            errors = 0,
                        }
                        setmetatable(badVal, {__call = function(self, val, msg)
                            logger:error(self.source_name .. ": " .. tostring(msg) .. " (" .. tostring(val) .. ")")
                            self.errors = self.errors + 1
                        end})
                        joinedRows, joinedHeader = joinFiles(tsv, secondaryTsvList, badVal)
                        if joinedRows then
                            logger:info("Joined " .. #secondaryTsvList .. " secondary file(s) into " .. file_name)
                            -- Register the joined type if joinedTypeName is specified
                            local joinedTypeName = joinMeta.lcFn2JoinedTypeName[lcfnKey]
                            if joinedTypeName then
                                registerJoinedType(joinedTypeName, joinedHeader)
                            end
                        end
                    end
                end

                -- Special handling for Files.tsv: transform for export
                local transformedHeader, transformedRows = nil, nil
                if isFilesDescriptor(file_name) and joinMeta then
                    transformedHeader, transformedRows = transformFilesDescForExport(tsv, joinMeta)
                    if transformedHeader then
                        logger:info("Transformed Files.tsv for export: removed join columns and secondary files")
                    end
                end

                local header = transformedHeader or joinedHeader or tsv[1]
                local dataRows = transformedRows or joinedRows or tsv
                local useJoinedData = joinedRows ~= nil
                local useTransformedData = transformedRows ~= nil
                local cnt = {}

                -- Build export column info based on exportExploded setting
                -- Note: __exploded_map is accessible via __index on the read-only proxy
                local exploded_map = header.__exploded_map or {}
                local has_exploded = next(exploded_map) ~= nil

                -- Determine which columns to export and how
                -- export_cols: array of {col_idx, is_root, root_name, structure, is_last}
                local export_cols = {}
                if exportExploded or not has_exploded then
                    -- Export all columns as-is
                    for j = 1, #header do
                        if not isCommentColumn(header[j]) then
                            export_cols[#export_cols + 1] = {col_idx = j}
                        end
                    end
                else
                    -- Collapsed export: group exploded columns
                    local processed_roots = {}
                    for j = 1, #header do
                        local col = header[j]
                        if isCommentColumn(col) then
                            -- Skip comment columns
                        elseif col.is_exploded and col.exploded_path then
                            local root_name = col.exploded_path[1]
                            if not processed_roots[root_name] then
                                processed_roots[root_name] = true
                                export_cols[#export_cols + 1] = {
                                    col_idx = j,
                                    is_root = true,
                                    root_name = root_name,
                                    structure = exploded_map[root_name]
                                }
                            end
                            -- Skip other columns in the same exploded group
                        else
                            -- Non-exploded column
                            export_cols[#export_cols + 1] = {col_idx = j}
                        end
                    end
                end
                -- Mark the last column for SQL serializer
                if #export_cols > 0 then
                    export_cols[#export_cols].is_last = true
                end

                -- Generate file prefix (e.g., CREATE TABLE for SQL)
                if type(filePrefix) == "function" then
                    table.insert(cnt, filePrefix(header, export_cols))
                else
                    table.insert(cnt, filePrefix)
                end

                -- Helper function to export a single row
                local function exportRow(rowIdx, row, isHeader)
                    if type(linePrefix) == "function" then
                        table.insert(cnt, linePrefix(rowIdx, header))
                    else
                        table.insert(cnt, linePrefix)
                    end
                    local first_col = true
                    for _, ec in ipairs(export_cols) do
                        if not first_col then
                            table.insert(cnt, colSep)
                        end
                        first_col = false
                        local col = header[ec.col_idx]
                        if ec.is_root then
                            -- Collapsed export: serialize the assembled composite
                            if isHeader then
                                -- Header row: output collapsed column spec
                                local collapsed_spec = generateCollapsedColumnSpec(ec.root_name, ec.structure)
                                table.insert(cnt, serializer(rowIdx, col, collapsed_spec, ec))
                            else
                                -- Data row: assemble and serialize the composite value
                                local assembled = assembleExplodedValue(row, ec.structure)
                                table.insert(cnt, serializer(rowIdx, col, assembled, ec))
                            end
                        else
                            -- Normal export
                            local cell = row[ec.col_idx]
                            table.insert(cnt, serializer(rowIdx, col, cell.parsed, ec))
                        end
                    end
                    if type(lineSuffix) == "function" then
                        table.insert(cnt, lineSuffix(rowIdx, header))
                    else
                        table.insert(cnt, lineSuffix)
                    end
                end

                if useJoinedData or useTransformedData then
                    -- Export header row first (header is separate from data rows)
                    exportRow(1, header, true)
                    -- Export data rows
                    for i, row in ipairs(dataRows) do
                        if type(row) == "table" then
                            table.insert(cnt, lineSep)
                            exportRow(i + 1, row, false)
                        end
                    end
                else
                    -- Original behavior: iterate over tsv which includes header
                    for i, row in ipairs(tsv) do
                        if type(row) == "table" then
                            if i > 1 then
                                table.insert(cnt, lineSep)
                            end
                            exportRow(i, row, i == 1)
                        end
                    end
                end
                table.insert(cnt, fileSuffix)
                content2 = table.concat(cnt)
            end
        end
        if not writeExportFile(new_name, content2) then
            return false
        end
        ::continue::
    end
    return true
end

--- Exports parsed files in TSV format with Lua literal values.
--- @param process_files table Result from mod_loader.processFiles()
--- @param exportParams table Export parameters: {exportDir, formatSubdir, ...}
--- @return boolean True on success, false on failure
--- @side_effect Creates files in exportDir
local function exportLuaTSV(process_files, exportParams)
    logger:info("Exporting files as (Lua)TSV to: " .. exportParams.exportDir)
    local function ser(rowIdx, col, value) return serialize(value, true) end
    return exportTSV(process_files, exportParams, ser)
end

-- Export the parsed files in the "TSV" format. Values are JSON literals.
-- Returns true on success
local function exportJSONTSV(process_files, exportParams)
    logger:info("Exporting files as (JSON)TSV to: " .. exportParams.exportDir)
    local function ser(rowIdx, col, value) return serializeJSON(value, true) end
    return exportTSV(process_files, exportParams, ser)
end

-- Export the parsed files in the "JSON" format, array-of-array style (typed JSON)
-- Returns true on success
local function exportJSON(process_files, exportParams)
    logger:info("Exporting files as JSON (typed) to: " .. exportParams.exportDir)
    local copy = { }
    for k, v in pairs(exportParams) do copy[k] = v end
    copy.filePrefix = "[\n"
    copy.fileSuffix = "\n]"
    copy.linePrefix = "["
    copy.lineSuffix = "]"
    copy.lineSep = ",\n"
    copy.colSep = ","
    copy.fileExt = "json"
    local function ser(rowIdx, col, value) return serializeJSON(value, false) end
    return exportTSV(process_files, copy, ser)
end

-- Export the parsed files in the "TSV" format. Values are natural JSON literals.
-- Returns true on success
local function exportNaturalJSONTSV(process_files, exportParams)
    logger:info("Exporting files as (Natural JSON)TSV to: " .. exportParams.exportDir)
    local function ser(rowIdx, col, value) return serializeNaturalJSON(value, true) end
    return exportTSV(process_files, exportParams, ser)
end

-- Export the parsed files in the "JSON" format, array-of-array style (natural JSON)
-- Returns true on success
local function exportNaturalJSON(process_files, exportParams)
    logger:info("Exporting files as JSON (natural) to: " .. exportParams.exportDir)
    local copy = { }
    for k, v in pairs(exportParams) do copy[k] = v end
    copy.filePrefix = "[\n"
    copy.fileSuffix = "\n]"
    copy.linePrefix = "["
    copy.lineSuffix = "]"
    copy.lineSep = ",\n"
    copy.colSep = ","
    copy.fileExt = "json"
    local function ser(rowIdx, col, value) return serializeNaturalJSON(value, false) end
    return exportTSV(process_files, copy, ser)
end

-- Export the parsed files in the "Lua" format, sequence-of-sequence style
-- Returns true on success
local function exportLua(process_files, exportParams)
    logger:info("Exporting files as Lua to: " .. exportParams.exportDir)
    local copy = { }
    for k, v in pairs(exportParams) do copy[k] = v end
    copy.filePrefix = "return {\n"
    copy.fileSuffix = "\n}"
    copy.linePrefix = "{"
    copy.lineSuffix = "}"
    copy.lineSep = ",\n"
    copy.colSep = ","
    copy.fileExt = "lua"
    local function ser(rowIdx, col, value) return serialize(value, false) end
    return exportTSV(process_files, copy, ser)
end

-- Converts TSV column model to SQL column string
local function colToSQL(col)
    local colType = col.type
    local optional = false
    local key = colType .. ":" .. tostring(optional)
    local sqlType = sql_types[key]
    if sqlType == nil then
        if colType:sub(-4) == "|nil" then
            optional = true
            colType = colType:sub(1,-5)
        end
        -- Check for bytes types first (map to BLOB)
        if (colType == "hexbytes") or extendsOrRestrict(colType, "hexbytes")
            or (colType == "base64bytes") or extendsOrRestrict(colType, "base64bytes") then
            sqlType = optional and "BLOB" or "BLOB NOT NULL"
        else
            for _, b in ipairs(base_types) do
                if (colType == b) or extendsOrRestrict(colType, b) then
                    sqlType = sql_types[b]
                    if not optional and not sqlType:find("NOT NULL") then
                        sqlType = sqlType .. " NOT NULL"
                    end
                    break
                end
            end
        end
        -- Try union types: e.g. integer|string, or aliases resolving to unions like super_type -> type_spec|nil
        if sqlType == nil then
            local uTypes = unionTypes(colType)
            if uTypes then
                local hasTable = false
                for _, ut in ipairs(uTypes) do
                    if ut == "nil" then
                        optional = true
                    elseif ut == "table" or extendsOrRestrict(ut, "table") then
                        hasTable = true
                    end
                end
                -- Union of basic types: all values serialized as strings -> TEXT
                -- Union containing a table type: same as table column type (JSON-encoded TEXT)
                sqlType = sql_types[hasTable and "table" or "string"]
                if not optional and not sqlType:find("NOT NULL") then
                    sqlType = sqlType .. " NOT NULL"
                end
            end
        end
        if sqlType == nil then
            logger:error("Unknown column type: " .. colType.." for column " .. col.name)
            sqlType = "TEXT"
        end
        sql_types[key] = sqlType
        logger:info("Mapping column type " .. col.type .. " to SQL type " .. sqlType)
    end
    -- Replace dots, brackets, and '=' with underscores for SQL-safe column names
    -- (exploded columns use bracket notation like materials[1] or materials[iron]=)
    local sqlColName = col.name:gsub("[%.%[%]%=]", "_"):gsub("_+$", "")
    local result = '"' .. sqlColName .. '" ' .. sqlType
    if col.idx == 1 then
        result = result .. " PRIMARY KEY"
    end
    return result
end

-- Builds the SQL CREATE TABLE statement followed by the INSERT statement
-- export_cols: optional array of {col_idx, is_root, root_name, structure} for collapsed column export
local function createTableInsertSQL(header, export_cols)
    local source_path = splitPath(header.__source or "")
    local file = source_path[#source_path] or "unknown"
    local file_without_ext = file:match("^(.*)%.[^%.]+$") or file
    local tableName = '"' .. file_without_ext .. '"'
    local result = "CREATE TABLE " .. tableName .. " "
    local sep = "(\n  "
    local is_first = true

    if export_cols then
        -- Use export_cols to determine columns (handles collapsed exploded columns)
        for _, ec in ipairs(export_cols) do
            local col = header[ec.col_idx]
            if ec.is_root then
                -- Collapsed column: use root_name and TEXT type (serialized JSON/XML/etc)
                local colDef = '"' .. ec.root_name .. '" TEXT NOT NULL'
                if is_first then
                    colDef = colDef .. " PRIMARY KEY"
                end
                result = result .. sep .. colDef
            else
                result = result .. sep .. colToSQL(col)
            end
            sep = ",\n  "
            is_first = false
        end
    else
        -- Original behavior: iterate all columns
        for _, col in ipairs(header) do
            result = result .. sep .. colToSQL(col)
            sep = ",\n  "
        end
    end

    result = result .. ")"
    local dataset = header.__dataset or {}
    local rows = #dataset
    local not_empty = (rows > 1)
    if not_empty then
        not_empty = false
        for i, row in ipairs(dataset) do
            if i > 1 and type(row) == "table" then
                not_empty = true
                break
            end
        end
    end
    if not_empty then
        result = result .. ";\n"
        result = result .. "INSERT INTO " .. tableName .. " "
    else
        result = result .. "\n--"
    end
    return result
end

-- Export the parsed files in the SQL format, using exportParams.tableSerializer for Lua tables,
-- and defaulting to serializeTableJSON if unspecified
-- Returns true on success
local function exportSQL(process_files, exportParams)
    logger:info("Exporting files as SQL to: " .. exportParams.exportDir)
    local copy = { }
    for k, v in pairs(exportParams) do copy[k] = v end
    copy.filePrefix = createTableInsertSQL
    copy.fileSuffix = "\n;\n"
    copy.linePrefix = "("
    copy.lineSuffix = ")"
    copy.lineSep = ",\n"
    copy.colSep = ","
    copy.fileExt = "sql"
    local tableSerializer = exportParams.tableSerializer or serializeTableJSON
    assert(type(tableSerializer) == "function", "tableSerializer must be a function")
    local function ser(rowIdx, col, value, ec)
        if rowIdx == 1 then
            local header = col.header
            local rows = #header.__dataset
            if rows == 1 then
                return ""
            end
            -- Use ec.root_name for collapsed columns, otherwise col.name
            -- Replace dots with underscores for SQL-safe column names
            local colName = (ec and ec.is_root) and ec.root_name or col.name:gsub("%.", "_")
            local result = '"' .. colName .. '"'
            -- Check if this is the last column (ec.is_last is set by export loop)
            if ec and ec.is_last then
                result = result .. ") VALUES --"
            end
            return result
        end
        -- Convert bytes types to SQL BLOB literals
        if value ~= nil and isBytesColumn(col) then
            if isHexBytesColumn(col) then
                return "X'" .. value .. "'"
            else
                local binary = base64.decode(value)
                return serializeSQLBlob(binary)
            end
        end
        return serializeSQL(value, tableSerializer)
    end
    return exportTSV(process_files, copy, ser)
end

-- Export the parsed files in the "XML" format
-- Returns true on success
local function exportXML(process_files, exportParams)
    logger:info("Exporting files as XML to: " .. exportParams.exportDir)
    local copy = { }
    for k, v in pairs(exportParams) do copy[k] = v end
    copy.filePrefix = '<?xml version="1.0" encoding="UTF-8"?>\n<file>\n'
    copy.fileSuffix = "\n</file>"
    copy.linePrefix = function(rowIdx) return rowIdx == 1 and "<header>" or "<row>" end
    copy.lineSuffix = function(rowIdx) return rowIdx == 1 and "</header>" or "</row>" end
    copy.lineSep = "\n"
    copy.colSep = ""
    copy.fileExt = "xml"
    local function ser(rowIdx, col, value) return serializeXML(value, false) end
    return exportTSV(process_files, copy, ser)
end

-- Export the parsed files in the "MessagePack" format. We could have used additional compression
-- on the files, but lz4 does not work with current versions of Lua, and zstd is not a "stand-alone"
-- library, it requires a native library installed in the system.
-- Returns true on success
local function exportMessagePack(process_files, exportParams)
    local tsv_files = process_files.tsv_files
    local raw_files = process_files.raw_files
    local file2dir = process_files.file2dir
    local baseExportDir = exportParams.exportDir
    local formatSubdir = exportParams.formatSubdir or ""
    local exportDir = formatSubdir ~= "" and pathJoin(baseExportDir, formatSubdir) or baseExportDir
    local dirChecked = {}
    for file_name, content in pairs(raw_files) do
        local content2 = content
        local is_tsv = hasExtension(file_name, "tsv")
        local relative_name = computeRelativePath(file_name, file2dir)
        local new_name = pathJoin(exportDir, relative_name)
        if is_tsv then
            new_name = changeExtension(new_name, "mpk")
        end
        if not ensureParentDir(new_name, dirChecked) then
            return false
        end
        if is_tsv then
            local tsv = tsv_files[file_name]
            if tsv == nil then
                logger:error("Failed to find TSV for " .. file_name)
            else
                -- Since the MessagePack API only allows packing tables using the default implementation,
                -- I need to make a copy of the entire file, so that I can control the output format
                -- Identify bytes columns from the header row for binary conversion
                local bytes_cols = {}
                local headerRow = tsv[1]
                if headerRow and type(headerRow) == "table" then
                    for j, col in ipairs(headerRow) do
                        if isBytesColumn(col) then
                            bytes_cols[j] = col
                        end
                    end
                end
                local cnt = {}
                for rowIdx, row in ipairs(tsv) do
                    if type(row) == "table" then
                        local copy = {}
                        for j, cell in ipairs(row) do
                            local val = cell.parsed
                            -- Convert bytes columns to binary (skip header row)
                            if rowIdx > 1 and bytes_cols[j] and val ~= nil then
                                val = bytesToBinary(bytes_cols[j], val)
                            end
                            copy[#copy + 1] = val
                        end
                        cnt[#cnt + 1] = copy
                    end
                end
                content2 = serializeMessagePack(cnt)
            end
        end
        if not writeExportFile(new_name, content2) then
            return false
        end
    end
    return true
end

--- Exports the type schema to a TSV file.
--- @param exportDir string The directory to export to
--- @param processedFiles table Result from mod_loader.processFiles()
--- @param badVal table badVal instance for error reporting
--- @return boolean True on success, false on failure
--- @side_effect Creates schema.tsv in exportDir; adds to processedFiles
local function exportSchema(exportDir, processedFiles, badVal)
    local new_name = pathJoin(exportDir, "schema.tsv")
    local raw_tsv_model = {}
    local cols = parsers.getSchemaColumns();
    local nameIdx = -1
    local header = {}
    header[1] = 'id:string'
    for i, col in ipairs(cols) do
        if "name" == col.name then
            header[i+1] = 'name:name|nil'
            nameIdx = i
        else
            header[i+1] = col.name..':'..col.type
        end
    end
    raw_tsv_model[1] = header
    local model = parsers.getSchemaModel();
    for i, row in ipairs(model) do
        local tsv_row = {}
        tsv_row[1] = "type"..i
        for j, col in ipairs(cols) do
            local value = row[col.name]
            if j == nameIdx and not isName(value) then
                tsv_row[j+1] = ''
            else
                tsv_row[j+1] = value
            end
        end
        raw_tsv_model[i+1] = tsv_row
    end
    local schema = raw_tsv.rawTSVToString(raw_tsv_model)
    logger:info("Writing schema to " .. new_name)
    local success, err = writeFile(new_name, schema)
    if not success then
        logger:error("Failed to update " .. new_name.." : " .. err)
        return false
    end
    local tsv_files = processedFiles.tsv_files
    local raw_files = processedFiles.raw_files
    -- Use relative key so subsequent exporters can construct correct output paths
    local schema_key = "schema.tsv"
    raw_files[schema_key] = schema
    -- processTSV(options_extractor, expr_eval, parser_finder, source_name, raw_tsv, badVal, table_subscribers, transposed)
    tsv_files[schema_key] = processTSV(nil, nil, parseType, new_name, raw_tsv_model, badVal, nil, false)
    return true
end

--- Pre-registers all joined types so they appear in the schema.
--- This should be called before exportSchema to ensure joined types are available.
--- @param processedFiles table Result from manifest_loader.processFiles()
--- @return number The number of joined types registered
local function registerJoinedTypes(processedFiles)
    local tsv_files = processedFiles.tsv_files
    local joinMeta = processedFiles.joinMeta
    if not joinMeta then
        return 0
    end

    local secondaryGroups = groupSecondaryFiles(joinMeta)
    local count = 0

    for primaryLcfn, secondaryLcfns in pairs(secondaryGroups) do
        local joinedTypeName = joinMeta.lcFn2JoinedTypeName[primaryLcfn]
        if joinedTypeName and #secondaryLcfns > 0 then
            -- Find the primary file
            local primaryPath = findFilePath(primaryLcfn, tsv_files)
            if primaryPath and tsv_files[primaryPath] then
                local primaryTsv = tsv_files[primaryPath]
                -- Build list of secondary TSV data for joining
                local secondaryTsvList = {}
                for _, secLcfn in ipairs(secondaryLcfns) do
                    local secPath = findFilePath(secLcfn, tsv_files)
                    if secPath and tsv_files[secPath] then
                        local joinColumn = joinMeta.lcFn2JoinColumn[secLcfn]
                        secondaryTsvList[#secondaryTsvList + 1] = {
                            tsv = tsv_files[secPath],
                            joinColumn = joinColumn,
                            sourceName = secPath,
                        }
                    end
                end
                if #secondaryTsvList > 0 then
                    -- Perform join to get the merged header
                    local badVal = badValGen()
                    local _, joinedHeader = joinFiles(primaryTsv, secondaryTsvList, badVal)
                    if joinedHeader then
                        if registerJoinedType(joinedTypeName, joinedHeader) then
                            count = count + 1
                        end
                    end
                end
            end
        end
    end

    return count
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    exportJSON = exportJSON,
    exportJSONTSV = exportJSONTSV,
    exportLua = exportLua,
    exportLuaTSV = exportLuaTSV,
    exportMessagePack = exportMessagePack,
    exportNaturalJSON = exportNaturalJSON,
    exportNaturalJSONTSV = exportNaturalJSONTSV,
    exportSchema = exportSchema,
    exportSQL = exportSQL,
    exportXML = exportXML,
    registerJoinedTypes = registerJoinedTypes,
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
