-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 30, 0)

-- Module name
local NAME = "exporter"

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

local logger = require( "infra.named_logger").getLogger(NAME)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly
local unwrap = read_only.unwrap

local file_util = require("infra.file_util")
local pathJoin = file_util.pathJoin
local changeExtension = file_util.changeExtension
local hasExtension = file_util.hasExtension
local resolveArchivePath = file_util.resolveArchivePath
local getParentPath = file_util.getParentPath
local isDir = file_util.isDir
local mkdir = file_util.mkdir
local splitPath = file_util.splitPath
local writeFile = file_util.writeFile

-- Manifest files now use .transposed.tsv extension, handled by hasExtension(file_name, "tsv")

local serialization = require("serde.serialization")
local serialize = serialization.serialize
local serializeJSON = serialization.serializeJSON
local serializeNaturalJSON = serialization.serializeNaturalJSON
local serializeSQL = serialization.serializeSQL
local serializeTableJSON = serialization.serializeTableJSON
local serializeXML = serialization.serializeXML
local serializeMessagePack = serialization.serializeMessagePack
local serializeSQLBlob = serialization.serializeSQLBlob

local base64 = require("util.base64")

local parsers = require("parsers")
local extendsOrRestrict = parsers.extendsOrRestrict
local parseType = parsers.parseType
local registerAlias = parsers.registerAlias
local unionTypes = parsers.unionTypes

local error_reporting = require("infra.error_reporting")
local badValGen = error_reporting.badValGen
local nullBadVal = error_reporting.nullBadVal
local didYouMean = error_reporting.didYouMean

-- Sink (export) direction of the content pipeline. Used for the opt-in
-- exportParams.stripCog, which drops COG scaffolding from exported text.
-- Requiring builtin_content_stages registers the COG sink stage so runSink works
-- even when the exporter is used without going through the full loader.
local content_pipeline = require("content.content_pipeline")
require("content.builtin_content_stages")

local raw_tsv = require("tsv.raw_tsv")

local tsv_model = require('tsv.tsv_model');
local processTSV = tsv_model.processTSV

local predicates = require("util.predicates")
local isName = predicates.isName

local exploded_columns = require("tsv.exploded_columns")
local assembleExplodedValue = exploded_columns.assembleExplodedValue
local generateCollapsedColumnSpec = exploded_columns.generateCollapsedColumnSpec

local file_joining = require("tsv.file_joining")
local shouldExport = file_joining.shouldExport
local groupSecondaryFiles = file_joining.groupSecondaryFiles
local findFilePath = file_joining.findFilePath
local joinFiles = file_joining.joinFiles

-- Graph-diagram export (TODO/graph_svg_export.md): family detection plus the
-- pure layout + render modules. The exporter is the thin glue between them.
local graph_wiring = require("wiring.graph_wiring")
local detectRole = graph_wiring.detectRole
local graph_layout = require("wiring.graph_layout")
local svg_render = require("serde.svg_render")

-- Column names used for file joining metadata (to be excluded from exported Files.tsv)
local JOIN_COLUMNS = {
    joinInto = true,
    joinColumn = true,
    export = true,
    joinedTypeName = true,
    variant = true,
}

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
local BASE_TYPES = {"boolean", "integer", "number", "string", "table"}

-- Computes the relative path of a file for export.
-- Uses file2dir to strip the source directory prefix from absolute paths.
local function computeRelativePath(file_name, file2dir)
    if not file2dir then return file_name end
    local dir = file2dir[file_name]
    if dir then
        if dir == "." then
            return file_name
        end
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

-- When exportParams.stripCog is on, runs string content through the content
-- pipeline's sink direction (COG-comment stripping, §3.9) before it is written;
-- otherwise returns it unchanged. Applied uniformly to every export-write path,
-- and a no-op on content with no COG markers, so it is safe on regenerated TSV as
-- well as raw-passthrough text. `file_name` is the on-disk source name (used only
-- to gate the text-only sink stage by extension).
local function applySinkStrip(file_name, content, exportParams)
    if exportParams and exportParams.stripCog and type(content) == "string" then
        return (content_pipeline.runSink(file_name, content, {}, nullBadVal))
    end
    return content
end

-- Block-streams a passthrough binary's bytes from its source to the export path
-- without ever loading the whole file into memory (§3.5). Used when a raw_files
-- entry is a {__passthrough=true, sourcePath, ...} descriptor rather than a
-- string — i.e. a binary file no content-pipeline stage needed.
local function streamExportFile(path, sourcePath)
    logger:info("Exporting (streamed): " .. path)
    local ok, err = file_util.copyFileStreamed(sourcePath, path)
    if not ok then
        logger:error("Failed to stream " .. path .. " from " .. tostring(sourcePath)
            .. ": " .. tostring(err))
        return false
    end
    return true
end

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

            -- Skip secondary files (those with joinInto set) and variant-filtered files
            if (joinMeta and joinMeta.lcFn2JoinInto[lcfn])
                or (joinMeta and joinMeta.lcSkippedFiles and joinMeta.lcSkippedFiles[lcfn]) then
                -- This is a secondary or variant-skipped file, skip it
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
        -- A COG doc template is generated (expanded) by doc_generator, not copied
        -- verbatim here (content_pipeline.md §3.10) — skip it.
        if exportParams.cogTemplates and exportParams.cogTemplates[file_name] then
            goto continue
        end
        -- A virtual archive member (utilmod.zip/data/Item.tsv) is an INPUT only: its
        -- data feeds the model, but the packed archive (streamed verbatim, below) is
        -- its export representation. Re-emitting it would both duplicate the packed
        -- copy and create a confusing .zip-as-directory layout (archive_files.md §5).
        if (select(2, resolveArchivePath(file_name))) ~= nil then
            goto continue
        end
        -- Compute relative path for both export and join metadata lookups
        local relative_name = computeRelativePath(file_name, file2dir)
        local lcfnKey = relative_name:lower():gsub("\\", "/")
        -- Check if this file should be exported
        if joinMeta and not shouldExport(lcfnKey, joinMeta) then
            if joinMeta.lcSkippedFiles and joinMeta.lcSkippedFiles[lcfnKey] then
                logger:info("Skipping export of variant-inactive file: " .. file_name)
            else
                logger:info("Skipping export of secondary file: " .. file_name)
            end
            goto continue
        end
        local is_tsv = hasExtension(file_name, "tsv")
        local new_name = pathJoin(exportDir, relative_name)
        if is_tsv and fileExt ~= "tsv" then
            new_name = changeExtension(new_name, fileExt)
        end
        if not ensureParentDir(new_name, dirChecked) then
            return false
        end
        -- A passthrough descriptor (binary file no stage processed) is streamed
        -- by reference, never held in memory (§3.5).
        if type(content) == "table" and content.__passthrough then
            if not streamExportFile(new_name, content.sourcePath) then
                return false
            end
            goto continue
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
                            local knownFiles = {}
                            for path in pairs(tsv_files) do
                                local lp = path:lower()
                                knownFiles[#knownFiles + 1] = lp:match("[^/\\]+$") or lp
                            end
                            logger:warn("Secondary file not found: " .. secLcfn
                                .. didYouMean(secLcfn, knownFiles))
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
                local has_exploded = next(unwrap(exploded_map)) ~= nil

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
        -- stripCog only on raw-passthrough text (non-TSV); regenerated TSV has no
        -- COG markers, and we must never run it on binary export formats.
        if not is_tsv then
            content2 = applySinkStrip(file_name, content2, exportParams)
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
local function colToSQL(sql_types, col)
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
            for _, b in ipairs(BASE_TYPES) do
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
local function createTableInsertSQL(sql_types, header, export_cols)
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
                result = result .. sep .. colToSQL(sql_types, col)
            end
            sep = ",\n  "
            is_first = false
        end
    else
        -- Original behavior: iterate all columns
        for _, col in ipairs(header) do
            result = result .. sep .. colToSQL(sql_types, col)
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
    -- Maps "our types" to SQLite types. This is a *cache*; it will be extended with every new column type
    -- we encounters.
    local sql_types = {
        ["string"] = "TEXT",
        ["number"] = "REAL",
        ["integer"] = "BIGINT",
        ["boolean"] = "SMALLINT", -- BOOLEAN is not available everywhere, so use SMALLINT with values 0/1
        ["table"] = "TEXT", -- tables are encoded as JSON, and therefore become strings
    }
    copy.filePrefix = function(header, export_cols) return createTableInsertSQL(sql_types, header, export_cols) end
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
    -- The root carries the TabuLua table namespace (urn:tabulua:table:1) so a
    -- reader can tell "is this XML ours?" from the vocabulary, not a generic
    -- <file> name. The trailing version segment is baked into every exported
    -- file, so it is fixed once (see TODO/xml_input_round_trip.md). The
    -- xml_transcoder verifies this namespace when reading an .xml file back in.
    copy.filePrefix = '<?xml version="1.0" encoding="UTF-8"?>\n<file xmlns="urn:tabulua:table:1">\n'
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
    local joinMeta = process_files.joinMeta
    local baseExportDir = exportParams.exportDir
    local formatSubdir = exportParams.formatSubdir or ""
    local exportDir = formatSubdir ~= "" and pathJoin(baseExportDir, formatSubdir) or baseExportDir
    local dirChecked = {}
    for file_name, content in pairs(raw_files) do
        local content2 = content
        -- COG doc templates are generated by doc_generator, not copied here (§3.10).
        if exportParams.cogTemplates and exportParams.cogTemplates[file_name] then
            goto continue
        end
        -- A virtual archive member (utilmod.zip/data/Item.tsv) is an INPUT only: its
        -- data feeds the model, but the packed archive (streamed verbatim, below) is
        -- its export representation. Re-emitting it would both duplicate the packed
        -- copy and create a confusing .zip-as-directory layout (archive_files.md §5).
        if (select(2, resolveArchivePath(file_name))) ~= nil then
            goto continue
        end
        -- Compute relative path for both export and join metadata lookups
        local relative_name = computeRelativePath(file_name, file2dir)
        local lcfnKey = relative_name:lower():gsub("\\", "/")
        -- Check if this file should be exported
        if joinMeta and not shouldExport(lcfnKey, joinMeta) then
            if joinMeta.lcSkippedFiles and joinMeta.lcSkippedFiles[lcfnKey] then
                logger:info("Skipping MessagePack export of variant-inactive file: " .. file_name)
            else
                logger:info("Skipping MessagePack export of secondary file: " .. file_name)
            end
            goto continue
        end
        local is_tsv = hasExtension(file_name, "tsv")
        local new_name = pathJoin(exportDir, relative_name)
        if is_tsv then
            new_name = changeExtension(new_name, "mpk")
        end
        if not ensureParentDir(new_name, dirChecked) then
            return false
        end
        -- Passthrough binary: stream the original bytes (§3.5).
        if type(content) == "table" and content.__passthrough then
            if not streamExportFile(new_name, content.sourcePath) then
                return false
            end
            goto continue
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
        -- stripCog only on raw-passthrough text; never on the binary MessagePack.
        if not is_tsv then
            content2 = applySinkStrip(file_name, content2, exportParams)
        end
        if not writeExportFile(new_name, content2) then
            return false
        end
        ::continue::
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

-- ============================================================
-- SVG graph-diagram export (TODO/graph_svg_export.md)
--
-- Unlike every other exporter, exportSVG is *selective*: it walks the
-- processed files, draws each one whose type belongs to a graph node family,
-- and skips everything else (logged at info — a graph-only picture of a
-- non-graph file is meaningless). It is the thin glue between family
-- detection, the pure graph_layout engine, and the pure svg_render renderer.
-- Phase 3 handles the directed families (graph_node / tree_node); undirected
-- (basic_graph_node) support lands in Phase 4.
-- ============================================================

-- Reads the parsed value of a named column on a data row (nil-safe). The TSV
-- model keys the header both numerically and by column name, so header[name]
-- is the descriptor and .idx is the cell position.
local function readNamedCell(row, header, colName)
    local col = header[colName]
    local idx = col and col.idx
    if not idx then return nil end
    local cell = row[idx]
    return cell and cell.parsed or nil
end

-- Builds the {nodes, adjacency, roles} inputs for a directed graph file from
-- its processed TSV. `nodes` is name-ordered for determinism; adjacency
-- follows graphChildren; a node's role tags whether it is a root/leaf so the
-- renderer can tint entry and terminal points.
local function buildDirectedGraph(tsv)
    local header = tsv[1]
    local nodes, adjacency, roles = {}, {}, {}
    for i = 2, #tsv do
        local row = tsv[i]
        if type(row) == "table" then
            local name = readNamedCell(row, header, "name")
            if name ~= nil then
                nodes[#nodes + 1] = name
                local children = readNamedCell(row, header, "graphChildren") or {}
                local parents = readNamedCell(row, header, "graphParents") or {}
                local kids = {}
                for _, c in ipairs(children) do kids[#kids + 1] = c end
                adjacency[name] = kids
                local isRoot = #parents == 0
                local isLeaf = #children == 0
                -- No parents AND no children = an isolated node (no edges).
                if isRoot and isLeaf then roles[name] = "isolated"
                elseif isRoot then roles[name] = "root"
                elseif isLeaf then roles[name] = "leaf" end
            end
        end
    end
    return nodes, adjacency, roles
end

-- Builds the {nodes, neighbours} inputs for an undirected (basic) graph file
-- from its processed TSV. `neighbours` follows graphLinks (symmetric). Roles
-- are not tinted for undirected graphs (they have no roots/leaves).
local function buildUndirectedGraph(tsv)
    local header = tsv[1]
    local nodes, neighbours = {}, {}
    for i = 2, #tsv do
        local row = tsv[i]
        if type(row) == "table" then
            local name = readNamedCell(row, header, "name")
            if name ~= nil then
                nodes[#nodes + 1] = name
                local links = readNamedCell(row, header, "graphLinks") or {}
                local nbrs = {}
                for _, l in ipairs(links) do nbrs[#nbrs + 1] = l end
                neighbours[name] = nbrs
            end
        end
    end
    return nodes, neighbours
end

-- Picks the edge-file column whose value labels each drawn edge. An explicit
-- name (exportParams.svgLabelColumn) wins; otherwise the first non-`name`,
-- non-comment column — e.g. `requiredLevel` on the tutorial's SkillEdges.tsv.
-- Returns the cell index, or nil if there is nothing to label with.
local function pickEdgeLabelColumn(header, preferred)
    if preferred and header[preferred] then return header[preferred].idx end
    for j = 1, #header do
        local col = header[j]
        if col.name ~= "name" and not isCommentColumn(col) then
            return j
        end
    end
    return nil
end

-- Builds a map from an edge file's primary key (e.g. "perception__aim") to the
-- string label taken from the chosen column. Table-valued cells are skipped
-- (a label is a scalar). Returns nil when there is no usable column.
local function buildEdgeLabelMap(edgeTsv, preferred)
    local header = edgeTsv[1]
    local nameIdx = header["name"] and header["name"].idx
    local labelIdx = pickEdgeLabelColumn(header, preferred)
    if not nameIdx or not labelIdx then return nil end
    local map = {}
    for i = 2, #edgeTsv do
        local row = edgeTsv[i]
        if type(row) == "table" then
            local key = row[nameIdx] and row[nameIdx].parsed
            local val = row[labelIdx] and row[labelIdx].parsed
            if key ~= nil and val ~= nil and type(val) ~= "table" then
                map[key] = tostring(val)
            end
        end
    end
    return map
end

--- Exports graph-family files as SVG diagrams, one per node file. Non-graph
--- files are skipped with an info log. Returns true on success.
--- @param process_files table Result from the loader (tsv_files, joinMeta, …).
--- @param exportParams table Export parameters: {exportDir, formatSubdir, …}.
--- @return boolean
local function exportSVG(process_files, exportParams)
    logger:info("Exporting graph files as SVG to: " .. exportParams.exportDir)
    local tsv_files = process_files.tsv_files or {}
    local joinMeta = process_files.joinMeta or {}
    local file2dir = process_files.file2dir
    local lcFn2Type = joinMeta.lcFn2Type or {}
    local extendsMap = joinMeta.extends or {}

    local baseExportDir = exportParams.exportDir
    local formatSubdir = exportParams.formatSubdir or ""
    local exportDir = formatSubdir ~= "" and pathJoin(baseExportDir, formatSubdir)
        or baseExportDir

    -- Edge-file annotation setup: a node file's drawn edges are labelled with
    -- data from its attached `edgesFor` edge file (default on). Build the
    -- node→edge reverse index and a basename→path index once.
    local svgLabelEdges = exportParams.svgLabelEdges
    if svgLabelEdges == nil then svgLabelEdges = true end
    local nodeToEdge = {}
    for edgeLc, nodeLc in pairs(joinMeta.lcFn2EdgesFor or {}) do
        nodeToEdge[nodeLc] = edgeLc
    end
    local baseToPath = {}
    for fn in pairs(tsv_files) do
        baseToPath[(fn:match("[^/\\]+$") or fn):lower()] = fn
    end

    -- Deterministic file order.
    local fileNames = {}
    for fn in pairs(tsv_files) do fileNames[#fileNames + 1] = fn end
    table.sort(fileNames)

    local dirChecked = {}
    local drawn, skipped = 0, 0
    for _, file_name in ipairs(fileNames) do
        local relative_name = computeRelativePath(file_name, file2dir)
        -- Type/family are keyed by basename lowercased, matching how Files.tsv
        -- metadata is indexed (see builtin_wiring's edge-consistency pass).
        local baseLc = (relative_name:match("[^/\\]+$") or relative_name):lower()
        local typeName = lcFn2Type[baseLc]
        local role = typeName and detectRole(typeName, extendsMap) or nil

        -- Respect the same variant / secondary-file gating as the TSV export.
        local lcfnKey = relative_name:lower():gsub("\\", "/")
        local exportable = true
        if joinMeta.lcFn2Export and joinMeta.lcFn2JoinInto then
            exportable = shouldExport(lcfnKey, joinMeta)
        end

        if role == nil then
            logger:info("No graph to draw for " .. file_name .. " (skipping)")
            skipped = skipped + 1
        elseif not exportable then
            logger:info("Skipping export of secondary/variant-inactive graph file: "
                .. file_name)
            skipped = skipped + 1
        else
            local tsv = tsv_files[file_name]
            local layoutOpts = {
                sweeps = exportParams.svgSweeps,
                nodeSpacing = exportParams.svgNodeSpacing,
                layerSpacing = exportParams.svgLayerSpacing,
            }
            local laidOut, directed, roles, nodeCount
            if role.family == "directed" then
                -- DAG / tree: layer by longest path, arrowheads, root/leaf tint.
                local nodes, adjacency
                nodes, adjacency, roles = buildDirectedGraph(tsv)
                laidOut = graph_layout.layout(nodes, adjacency, layoutOpts)
                directed = true
                nodeCount = #nodes
            else
                -- Undirected (basic): synthesize a BFS layering, orient edges
                -- for the engine, and draw without arrowheads or role tints.
                local nodes, neighbours = buildUndirectedGraph(tsv)
                local layers, adjacency = graph_layout.bfsLayering(nodes, neighbours)
                layoutOpts.layers = layers
                laidOut = graph_layout.layout(nodes, adjacency, layoutOpts)
                directed = false
                nodeCount = #nodes
            end
            -- Attach roles (directed only) so the renderer can tint roots/leaves.
            if roles then
                for name, node in pairs(laidOut.nodes) do
                    node.role = roles[name]
                end
            end
            -- Annotate edges from the attached edge file, if any. Try both key
            -- orderings so a directed "parent__child" key and an undirected
            -- canonical key both resolve.
            if svgLabelEdges and nodeToEdge[baseLc] then
                local edgePath = baseToPath[nodeToEdge[baseLc]]
                local edgeTsv = edgePath and tsv_files[edgePath]
                local labelMap = edgeTsv and buildEdgeLabelMap(edgeTsv,
                    exportParams.svgLabelColumn)
                if labelMap then
                    for _, edge in ipairs(laidOut.edges) do
                        local v = labelMap[edge.from .. "__" .. edge.to]
                            or labelMap[edge.to .. "__" .. edge.from]
                        if v ~= nil then edge.label = v end
                    end
                end
            end
            local svg = svg_render.render(laidOut, {
                directed = directed,
                colors = exportParams.svgColors,
            })

            local out_name = changeExtension(pathJoin(exportDir, relative_name), "svg")
            if not ensureParentDir(out_name, dirChecked) then
                return false
            end
            if not writeExportFile(out_name, svg) then
                return false
            end
            logger:info(string.format("Drew %s (%d nodes, %d crossings)",
                file_name, nodeCount, laidOut.crossings))
            drawn = drawn + 1
        end
    end

    logger:info(string.format(
        "SVG export complete: %d graph file(s) drawn, %d file(s) skipped",
        drawn, skipped))
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
    exportSVG = exportSVG,
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
