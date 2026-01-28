-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 1, 0)

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

local parsers = require("parsers")
local extendsOrRestrict = parsers.extendsOrRestrict
local parseType = parsers.parseType

local raw_tsv = require("raw_tsv")

local tsv_model = require('tsv_model');
local processTSV = tsv_model.processTSV

local predicates = require("predicates")
local isName = predicates.isName

local exploded_columns = require("exploded_columns")
local assembleExplodedValue = exploded_columns.assembleExplodedValue
local generateCollapsedColumnSpec = exploded_columns.generateCollapsedColumnSpec

-- Lua base types
local base_types = {"boolean", "integer", "number", "string", "table"}

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
    local dirChecked = {}
    for file_name, content in pairs(raw_files) do
        local is_tsv = hasExtension(file_name, "tsv")
        local new_name = pathJoin(exportDir, file_name)
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
                local header = tsv[1]
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
                        export_cols[#export_cols + 1] = {col_idx = j}
                    end
                else
                    -- Collapsed export: group exploded columns
                    local processed_roots = {}
                    for j = 1, #header do
                        local col = header[j]
                        if col.is_exploded and col.exploded_path then
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

                for i, row in ipairs(tsv) do
                    if type(row) == "table" then
                        if i > 1 then
                            table.insert(cnt, lineSep)
                        end
                        if type(linePrefix) == "function" then
                            table.insert(cnt, linePrefix(i, header))
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
                                if i == 1 then
                                    -- Header row: output collapsed column spec (serialize it like other header values)
                                    local collapsed_spec = generateCollapsedColumnSpec(ec.root_name, ec.structure)
                                    table.insert(cnt, serializer(i, col, collapsed_spec, ec))
                                else
                                    -- Data row: assemble and serialize the composite value
                                    local assembled = assembleExplodedValue(row, ec.structure)
                                    table.insert(cnt, serializer(i, col, assembled, ec))
                                end
                            else
                                -- Normal export
                                local cell = row[ec.col_idx]
                                table.insert(cnt, serializer(i, col, cell.parsed, ec))
                            end
                        end
                        if type(lineSuffix) == "function" then
                            table.insert(cnt, lineSuffix(i, header))
                        else
                            table.insert(cnt, lineSuffix)
                        end
                    end
                end
                table.insert(cnt, fileSuffix)
                content = table.concat(cnt)
            end
        end
        if not writeExportFile(new_name, content) then
            return false
        end
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
        for _, b in ipairs(base_types) do
            if colType:sub(-4) == "|nil" then
                optional = true
                colType = colType:sub(1,-5)
            end
            if (colType == b) or extendsOrRestrict(colType, b) then
                sqlType = sql_types[b]
                if not optional and not sqlType:find("NOT NULL") then
                    sqlType = sqlType .. " NOT NULL"
                end
                break
            end
        end
        if sqlType == nil then
            logger:error("Unknown column type: " .. colType.." for column " .. col.name)
            sqlType = "TEXT"
        end
        sql_types[key] = sqlType
        logger:info("Mapping column type " .. col.type .. " to SQL type " .. sqlType)
    end
    assert (isName(col.name), "Invalid column name: " .. col.name)
    -- Replace dots with underscores for SQL-safe column names
    local sqlColName = col.name:gsub("%.", "_")
    local result = '"' .. sqlColName .. '" ' .. sqlType
    if col.idx == 1 then
        result = result .. " PRIMARY KEY"
    end
    return result
end

-- Builds the SQL CREATE TABLE statement followed by the INSERT statement
-- export_cols: optional array of {col_idx, is_root, root_name, structure} for collapsed column export
local function createTableInsertSQL(header, export_cols)
    local source_path = splitPath(header.__source)
    local file = source_path[#source_path]
    local file_without_ext = file:match("^(.*)%.[^%.]+$")
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
    local rows = #header.__dataset
    local not_empty = (rows > 1)
    if not_empty then
        not_empty = false
        for i, row in ipairs(header.__dataset) do
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
    local baseExportDir = exportParams.exportDir
    local formatSubdir = exportParams.formatSubdir or ""
    local exportDir = formatSubdir ~= "" and pathJoin(baseExportDir, formatSubdir) or baseExportDir
    local dirChecked = {}
    for file_name, content in pairs(raw_files) do
        local is_tsv = hasExtension(file_name, "tsv")
        local new_name = pathJoin(exportDir, file_name)
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
                local cnt = {}
                for _, row in ipairs(tsv) do
                    if type(row) == "table" then
                        local copy = {}
                        for _, cell in ipairs(row) do
                            copy[#copy + 1] = cell.parsed
                        end
                        cnt[#cnt + 1] = copy
                    end
                end
                content = serializeMessagePack(cnt)
            end
        end
        if not writeExportFile(new_name, content) then
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
    raw_files[new_name] = schema
    -- processTSV(options_extractor, expr_eval, parser_finder, source_name, raw_tsv, badVal, table_subscribers, transposed)
    tsv_files[new_name] = processTSV(nil, nil, parseType, new_name, raw_tsv_model, badVal, nil, false)
    return true
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
