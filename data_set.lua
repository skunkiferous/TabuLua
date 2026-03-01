-- data_set.lua
-- A mutable in-memory dataset holding multiple raw TSV files for migration operations.
-- Works with raw TSV (no type parsing) so it can be used without type registration.

-- Module versioning
local semver = require("semver")
local VERSION = semver(0, 14, 0)
local NAME = "data_set"

local raw_tsv = require("raw_tsv")
local file_util = require("file_util")
local string_utils = require("string_utils")
local read_only = require("read_only")
local sandbox = require("sandbox")

local predicates = require("predicates")
local lfs = require("lfs")

local readOnly = read_only.readOnly
local split = string_utils.split
local isName = predicates.isName
local normalizePath = file_util.normalizePath
local pathJoin = file_util.pathJoin
local isAbsolutePath = file_util.isAbsolutePath
local isDir = file_util.isDir
local writeFile = file_util.writeFile
local mkdir = file_util.mkdir
local getParentPath = file_util.getParentPath

-- Module logger
local logger = require("named_logger").getLogger(NAME)

--- Returns the module version as a string.
--- @return string
local function getVersion()
    return tostring(VERSION)
end

-- Header separator
local HDR_SEP = ":"

---------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------

--- Parse a single column header spec like "name:type_spec|nil:default_val"
--- The default value may itself contain ':' characters, so we only split on
--- the first two colons: name, typeSpec, and everything after the second colon
--- is the default expression.
--- @param spec string The full header spec
--- @param index number The 1-based column index
--- @return table Column info {name, typeSpec, default, spec, index}
local function parseColumnSpec(spec, index)
    local name, typeSpec, default
    local pos1 = spec:find(HDR_SEP, 1, true)
    if not pos1 then
        -- No colon: just a name
        name = spec
        typeSpec = ""
    else
        name = spec:sub(1, pos1 - 1)
        local pos2 = spec:find(HDR_SEP, pos1 + 1, true)
        if not pos2 then
            -- One colon: name:typeSpec
            typeSpec = spec:sub(pos1 + 1)
        else
            -- Two+ colons: name:typeSpec:default (default may contain ':')
            typeSpec = spec:sub(pos1 + 1, pos2 - 1)
            default = spec:sub(pos2 + 1)
        end
    end
    return {
        name = name,
        typeSpec = typeSpec,
        default = default,
        spec = spec,
        index = index,
    }
end

--- Validate a column name. Accepts valid Lua identifiers and dotted names
--- (exploded column paths like "location.level"). Does not validate
--- collection notation (e.g. "items[1]") — that is handled by the full
--- tsv_model parser. Type specs are not validated here either, since the
--- migration tool operates at the raw level without type registration.
--- @param name string The column name to validate
--- @return boolean true if valid
local function isValidColumnName(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    -- Accept valid identifiers and dotted paths (isName handles both)
    return isName(name)
end

--- Parse the header row into columns list and columnIndex lookup.
--- Validates column names and checks for duplicates.
--- @param headerRow table A sequence of header spec strings
--- @return table|nil columns Ordered list of column info, or nil on error
--- @return table|string columnIndex (map of name → column info), or error message
local function parseHeader(headerRow)
    local columns = {}
    local columnIndex = {}
    for i, spec in ipairs(headerRow) do
        local col = parseColumnSpec(spec, i)
        if not isValidColumnName(col.name) then
            return nil, string.format(
                "invalid column name at index %d: %q (must be a valid identifier or dotted path)",
                i, col.name)
        end
        if columnIndex[col.name] then
            return nil, string.format(
                "duplicate column name at index %d: %q (first at index %d)",
                i, col.name, columnIndex[col.name].index)
        end
        columns[i] = col
        columnIndex[col.name] = col
    end
    return columns, columnIndex
end

--- Rebuild the header row from columns list.
--- @param columns table Ordered list of column info
--- @return table headerRow A sequence of spec strings
local function rebuildHeaderRow(columns)
    local row = {}
    for i, col in ipairs(columns) do
        row[i] = col.spec
    end
    return row
end

--- Rebuild a column spec string from its parts.
--- @param col table Column info
--- @return string The rebuilt spec
local function rebuildSpec(col)
    local spec = col.name
    if col.typeSpec and col.typeSpec ~= "" then
        spec = spec .. HDR_SEP .. col.typeSpec
        if col.default then
            spec = spec .. HDR_SEP .. col.default
        end
    elseif col.default then
        spec = spec .. HDR_SEP .. HDR_SEP .. col.default
    end
    return spec
end

--- Find the raw index of the first data row (non-comment, non-blank) in a rawTSV.
--- This is the header row.
--- @param rawTSV table The raw TSV structure
--- @return number|nil The 1-based raw index of the header row
local function findHeaderRowIndex(rawTSV)
    for i, line in ipairs(rawTSV) do
        if type(line) == "table" then
            return i
        end
    end
    return nil
end

--- Find a data row by primary key (value in column 1).
--- @param fileEntry table The file entry
--- @param key string The primary key value
--- @return number|nil rawIndex The raw index in rawTSV, or nil if not found
--- @return table|nil row The data row, or nil
local function findDataRowByKey(fileEntry, key)
    local rawTSV = fileEntry.rawTSV
    local headerIdx = fileEntry.headerRowIndex
    for i, line in ipairs(rawTSV) do
        if i ~= headerIdx and type(line) == "table" then
            if line[1] == key then
                return i, line
            end
        end
    end
    return nil, nil
end

--- Iterator over data rows (skipping header, comments, blanks).
--- Yields rawIndex, row for each data row.
--- @param fileEntry table The file entry
--- @return function iterator
local function iterDataRows(fileEntry)
    local rawTSV = fileEntry.rawTSV
    local headerIdx = fileEntry.headerRowIndex
    local i = 0
    local n = #rawTSV
    return function()
        while i < n do
            i = i + 1
            local line = rawTSV[i]
            if i ~= headerIdx and type(line) == "table" then
                return i, line
            end
        end
        return nil
    end
end

--- Resolve a position table to a numeric column index for insertion.
--- @param columns table Ordered list of column info
--- @param columnIndex table Name → column info lookup
--- @param position table|nil Position spec: {after="name"}, {before="name"}, {index=N}, or nil (append)
--- @return number|nil The 1-based target index
--- @return string|nil Error message
local function resolveColumnPosition(columns, columnIndex, position)
    if position == nil then
        return #columns + 1, nil
    end
    if type(position) ~= "table" then
        return nil, "position must be a table or nil"
    end
    if position.after then
        local ref = columnIndex[position.after]
        if not ref then
            return nil, "column not found for position.after: " .. tostring(position.after)
        end
        return ref.index + 1, nil
    end
    if position.before then
        local ref = columnIndex[position.before]
        if not ref then
            return nil, "column not found for position.before: " .. tostring(position.before)
        end
        return ref.index, nil
    end
    if position.index then
        local idx = position.index
        if type(idx) ~= "number" or idx < 1 then
            return nil, "position.index must be a positive number"
        end
        return idx, nil
    end
    return nil, "invalid position: must have 'after', 'before', or 'index' field"
end

--- Resolve a position table to a raw line index for inserting comments/blanks.
--- @param fileEntry table The file entry
--- @param position table Position spec
--- @return number|nil The raw line index for insertion
--- @return string|nil Error message
local function resolveLinePosition(fileEntry, position)
    if position == nil then
        return #fileEntry.rawTSV + 1, nil
    end
    if type(position) ~= "table" then
        return nil, "position must be a table or nil"
    end
    if position.afterRow then
        local idx = findDataRowByKey(fileEntry, position.afterRow)
        if not idx then
            return nil, "row not found for position.afterRow: " .. tostring(position.afterRow)
        end
        return idx + 1, nil
    end
    if position.beforeRow then
        local idx = findDataRowByKey(fileEntry, position.beforeRow)
        if not idx then
            return nil, "row not found for position.beforeRow: " .. tostring(position.beforeRow)
        end
        return idx, nil
    end
    if position.afterHeader then
        return fileEntry.headerRowIndex + 1, nil
    end
    if position.beforeHeader then
        return fileEntry.headerRowIndex, nil
    end
    if position.atEnd then
        return #fileEntry.rawTSV + 1, nil
    end
    if position.rawIndex then
        return position.rawIndex, nil
    end
    return nil, "invalid position: must have afterRow, beforeRow, afterHeader, beforeHeader, atEnd, or rawIndex"
end

--- Re-index columns after structural changes.
--- @param fileEntry table The file entry to re-index
local function reindexColumns(fileEntry)
    fileEntry.columnIndex = {}
    for i, col in ipairs(fileEntry.columns) do
        col.index = i
        fileEntry.columnIndex[col.name] = col
    end
end

--- Mark a file entry as dirty.
--- @param fileEntry table
local function markDirty(fileEntry)
    fileEntry.dirty = true
end

---------------------------------------------------------------------------
-- DataSet class
---------------------------------------------------------------------------

local DataSet = {}
DataSet.__index = DataSet

--- Create a new DataSet rooted at a directory.
--- @param rootDir string The base directory for resolving relative file paths
--- @param options table|nil Options: {logger=...}
--- @return table A new DataSet instance
function DataSet.new(rootDir, options)
    if type(rootDir) ~= "string" then
        error("rootDir must be a string", 2)
    end
    local normalized = normalizePath(rootDir)
    if not normalized then
        error("rootDir is empty", 2)
    end
    if not isAbsolutePath(normalized) then
        error("rootDir must be an absolute path: " .. rootDir, 2)
    end
    if not isDir(normalized) then
        error("rootDir is not an existing directory: " .. rootDir, 2)
    end
    options = options or {}
    local self = setmetatable({}, DataSet)
    self.rootDir = normalized
    self.files = {}
    self.logger = options.logger or logger
    return self
end

--- Validate that a fileName is a safe relative path (no '..' escape, no absolute path).
--- @param fileName string The relative file name to validate
--- @return boolean|nil true if valid, nil on error
--- @return string|nil error message
local function validateFileName(fileName)
    if type(fileName) ~= "string" or fileName == "" then
        return nil, "fileName must be a non-empty string"
    end
    if isAbsolutePath(fileName) then
        return nil, "fileName must be a relative path: " .. fileName
    end
    local normalized = normalizePath(fileName)
    if not normalized then
        return nil, "fileName normalizes to empty: " .. fileName
    end
    -- Check for '..' escape: after normalization, '..' at start means escaping root
    if normalized == ".." or normalized:sub(1, 3) == "../" then
        return nil, "fileName must not escape root directory: " .. fileName
    end
    return true
end

--- Assert that a file is loaded and return its entry.
--- @param self table The DataSet
--- @param fileName string The relative file name
--- @return table|nil fileEntry
--- @return string|nil error message
local function assertFileLoaded(self, fileName)
    local entry = self.files[fileName]
    if not entry then
        return nil, "file not loaded: " .. tostring(fileName)
    end
    return entry, nil
end

--- Assert that a column exists in a file.
--- @param fileEntry table
--- @param columnName string
--- @return table|nil column info
--- @return string|nil error message
local function assertColumnExists(fileEntry, columnName)
    local col = fileEntry.columnIndex[columnName]
    if not col then
        return nil, "column not found: " .. tostring(columnName)
    end
    return col, nil
end

---------------------------------------------------------------------------
-- File operations
---------------------------------------------------------------------------

--- Load a TSV file from disk into the dataset.
--- @param fileName string Relative path (forward slashes)
--- @return boolean|nil true on success, nil on error
--- @return string|nil error message
function DataSet:loadFile(fileName)
    local ok, valErr = validateFileName(fileName)
    if not ok then return nil, valErr end
    if self.files[fileName] then
        return nil, "file already loaded: " .. fileName
    end
    local diskPath = pathJoin(self.rootDir, fileName)
    local data, err = raw_tsv.fileToRawTSV(diskPath)
    if not data then
        return nil, "failed to load " .. fileName .. ": " .. tostring(err)
    end
    local headerIdx = findHeaderRowIndex(data)
    if not headerIdx then
        return nil, "no header row found in " .. fileName
    end
    local columns, columnIndex = parseHeader(data[headerIdx])
    if not columns then
        return nil, "invalid header in " .. fileName .. ": " .. tostring(columnIndex)
    end
    self.files[fileName] = {
        rawTSV = data,
        columns = columns,
        columnIndex = columnIndex,
        headerRowIndex = headerIdx,
        dirty = false,
        transposed = false,
        diskPath = diskPath,
        originalName = fileName,
    }
    return true
end

--- Load a transposed TSV file (auto-transposes to normal orientation).
--- @param fileName string Relative path
--- @return boolean|nil true on success, nil on error
--- @return string|nil error message
function DataSet:loadTransposedFile(fileName)
    local ok, valErr = validateFileName(fileName)
    if not ok then return nil, valErr end
    if self.files[fileName] then
        return nil, "file already loaded: " .. fileName
    end
    local diskPath = pathJoin(self.rootDir, fileName)
    local data, err = raw_tsv.fileToRawTSV(diskPath)
    if not data then
        return nil, "failed to load " .. fileName .. ": " .. tostring(err)
    end
    data = raw_tsv.transposeRawTSV(data)
    local headerIdx = findHeaderRowIndex(data)
    if not headerIdx then
        return nil, "no header row found in " .. fileName .. " (after transpose)"
    end
    local columns, columnIndex = parseHeader(data[headerIdx])
    if not columns then
        return nil, "invalid header in " .. fileName .. ": " .. tostring(columnIndex)
    end
    self.files[fileName] = {
        rawTSV = data,
        columns = columns,
        columnIndex = columnIndex,
        headerRowIndex = headerIdx,
        dirty = false,
        transposed = true,
        diskPath = diskPath,
        originalName = fileName,
    }
    return true
end

--- Save a file from the dataset back to disk.
--- Creates parent directories as needed.
--- @param fileName string Relative path
--- @return boolean|nil true on success, nil on error
--- @return string|nil error message
function DataSet:saveFile(fileName)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local diskPath = pathJoin(self.rootDir, fileName)
    -- Guard: if the file was created/renamed/copied (not loaded from this path),
    -- refuse to overwrite an existing unrelated file on disk.
    if fileName ~= entry.originalName then
        local attr = lfs.attributes(diskPath)
        if attr then
            return nil, "refusing to overwrite existing file on disk: " .. fileName ..
                " (originally loaded as " .. tostring(entry.originalName) .. ")"
        end
    end
    local parent = getParentPath(diskPath)
    if parent then
        local ok, mkErr = mkdir(parent)
        if not ok then
            return nil, "failed to create directory for " .. fileName .. ": " .. tostring(mkErr)
        end
    end
    local content = raw_tsv.rawTSVToString(entry.rawTSV)
    local ok, writeErr = writeFile(diskPath, content)
    if not ok then
        return nil, "failed to write " .. fileName .. ": " .. tostring(writeErr)
    end
    -- If this file was renamed/copied from a different path, delete the original from disk
    if entry.originalName and entry.originalName ~= fileName then
        local oldDiskPath = pathJoin(self.rootDir, entry.originalName)
        os.remove(oldDiskPath)
        entry.originalName = fileName
    end
    entry.dirty = false
    entry.diskPath = diskPath
    return true
end

--- Save all modified files to disk.
--- @return boolean|nil true on success, nil on error
--- @return string|nil error message (first failure)
function DataSet:saveAll()
    for fileName, entry in pairs(self.files) do
        if entry.dirty then
            local ok, err = self:saveFile(fileName)
            if not ok then
                return nil, err
            end
        end
    end
    return true
end

--- Create a new file with given column headers.
--- @param fileName string Relative path
--- @param columnSpecs table|string Sequence of column spec strings, or pipe-delimited string
--- @return boolean|nil true on success, nil on error
--- @return string|nil error message
function DataSet:createFile(fileName, columnSpecs)
    local ok, valErr = validateFileName(fileName)
    if not ok then return nil, valErr end
    if self.files[fileName] then
        return nil, "file already exists in dataset: " .. fileName
    end
    -- Check if file already exists on disk
    local diskPath = pathJoin(self.rootDir, fileName)
    local attr = lfs.attributes(diskPath)
    if attr then
        return nil, "file already exists on disk: " .. fileName
    end
    if type(columnSpecs) == "string" then
        columnSpecs = split(columnSpecs, "|")
    end
    if type(columnSpecs) ~= "table" or #columnSpecs == 0 then
        return nil, "columnSpecs must be a non-empty table or pipe-delimited string"
    end
    local headerRow = {}
    for i, spec in ipairs(columnSpecs) do
        headerRow[i] = spec
    end
    local data = { headerRow }
    local columns, columnIndex = parseHeader(headerRow)
    if not columns then
        return nil, "invalid header: " .. tostring(columnIndex)
    end
    self.files[fileName] = {
        rawTSV = data,
        columns = columns,
        columnIndex = columnIndex,
        headerRowIndex = 1,
        dirty = true,
        transposed = false,
        diskPath = pathJoin(self.rootDir, fileName),
        originalName = fileName,
    }
    return true
end

--- Delete a file from the dataset and from disk.
--- @param fileName string Relative path
--- @return boolean|nil true on success, nil on error
--- @return string|nil error message
function DataSet:deleteFile(fileName)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local diskPath = pathJoin(self.rootDir, fileName)
    local ok, rmErr = os.remove(diskPath)
    if not ok and rmErr then
        -- File may not exist on disk yet (created but never saved)
        -- Only error if it actually exists
        local f = io.open(diskPath, "r")
        if f then
            f:close()
            return nil, "failed to delete " .. fileName .. ": " .. tostring(rmErr)
        end
    end
    self.files[fileName] = nil
    return true
end

--- Rename/move a file within the dataset.
--- The file is not moved on disk until saveFile/saveAll is called.
--- @param oldName string Current relative path
--- @param newName string New relative path
--- @return boolean|nil true on success, nil on error
--- @return string|nil error message
function DataSet:renameFile(oldName, newName)
    local ok, valErr = validateFileName(newName)
    if not ok then return nil, valErr end
    local entry, err = assertFileLoaded(self, oldName)
    if not entry then return nil, err end
    if self.files[newName] then
        return nil, "target file already exists in dataset: " .. newName
    end
    -- Check if target file already exists on disk
    local targetDiskPath = pathJoin(self.rootDir, newName)
    local attr = lfs.attributes(targetDiskPath)
    if attr then
        return nil, "target file already exists on disk: " .. newName
    end
    self.files[newName] = entry
    self.files[oldName] = nil
    entry.diskPath = pathJoin(self.rootDir, newName)
    markDirty(entry)
    return true
end

--- Copy a file within the dataset.
--- @param sourceName string Source file name
--- @param targetName string Target file name
--- @return boolean|nil true on success, nil on error
--- @return string|nil error message
function DataSet:copyFile(sourceName, targetName)
    local ok, valErr = validateFileName(targetName)
    if not ok then return nil, valErr end
    local entry, err = assertFileLoaded(self, sourceName)
    if not entry then return nil, err end
    if self.files[targetName] then
        return nil, "target file already exists in dataset: " .. targetName
    end
    -- Check if target file already exists on disk
    local targetDiskPath = pathJoin(self.rootDir, targetName)
    local attr = lfs.attributes(targetDiskPath)
    if attr then
        return nil, "target file already exists on disk: " .. targetName
    end
    -- Deep copy rawTSV
    local newRaw = {}
    for i, line in ipairs(entry.rawTSV) do
        if type(line) == "table" then
            local row = {}
            for j, cell in ipairs(line) do
                row[j] = cell
            end
            newRaw[i] = row
        else
            newRaw[i] = line
        end
    end
    local columns, columnIndex = parseHeader(newRaw[entry.headerRowIndex])
    if not columns then
        return nil, "invalid header in copy: " .. tostring(columnIndex)
    end
    self.files[targetName] = {
        rawTSV = newRaw,
        columns = columns,
        columnIndex = columnIndex,
        headerRowIndex = entry.headerRowIndex,
        dirty = true,
        transposed = entry.transposed,
        diskPath = pathJoin(self.rootDir, targetName),
        originalName = targetName,
    }
    return true
end

--- Return list of file names in the dataset.
--- @return table Sorted list of file names
function DataSet:listFiles()
    local names = {}
    for name in pairs(self.files) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

--- Check if a file is loaded.
--- @param fileName string
--- @return boolean
function DataSet:hasFile(fileName)
    return self.files[fileName] ~= nil
end

--- Get the raw TSV data structure for a file.
--- @param fileName string
--- @return table|nil The rawTSV structure, or nil if not loaded
--- @return string|nil error message
function DataSet:getFile(fileName)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    return entry.rawTSV
end

--- Check if a file has unsaved modifications.
--- @param fileName string
--- @return boolean|nil dirty flag, or nil if not loaded
--- @return string|nil error message
function DataSet:isDirty(fileName)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    return entry.dirty
end

---------------------------------------------------------------------------
-- Column operations
---------------------------------------------------------------------------

--- Return ordered list of column names for a file.
--- @param fileName string
--- @return table|nil List of column names
--- @return string|nil error message
function DataSet:getColumnNames(fileName)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local names = {}
    for i, col in ipairs(entry.columns) do
        names[i] = col.name
    end
    return names
end

--- Return the full header spec for a column.
--- @param fileName string
--- @param columnName string
--- @return string|nil The spec string
--- @return string|nil error message
function DataSet:getColumnSpec(fileName, columnName)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local col
    col, err = assertColumnExists(entry, columnName)
    if not col then return nil, err end
    return col.spec
end

--- Return the 1-based index of a column.
--- @param fileName string
--- @param columnName string
--- @return number|nil The column index
--- @return string|nil error message
function DataSet:getColumnIndex(fileName, columnName)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local col
    col, err = assertColumnExists(entry, columnName)
    if not col then return nil, err end
    return col.index
end

--- Check if a column exists.
--- @param fileName string
--- @param columnName string
--- @return boolean
function DataSet:hasColumn(fileName, columnName)
    local entry = self.files[fileName]
    if not entry then return false end
    return entry.columnIndex[columnName] ~= nil
end

--- Add a new column to a file.
--- @param fileName string
--- @param columnSpec string Full header spec (e.g., "parent:type_spec|nil")
--- @param position table|nil Position: {after="name"}, {before="name"}, {index=N}, or nil (append)
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:addColumn(fileName, columnSpec, position)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local col = parseColumnSpec(columnSpec, 0) -- index set by reindex
    if not isValidColumnName(col.name) then
        return nil, "invalid column name: " .. tostring(col.name)
    end
    if entry.columnIndex[col.name] then
        return nil, "column already exists: " .. col.name
    end
    local targetIdx
    targetIdx, err = resolveColumnPosition(entry.columns, entry.columnIndex, position)
    if not targetIdx then return nil, err end
    -- Insert into columns list
    table.insert(entry.columns, targetIdx, col)
    reindexColumns(entry)
    -- Update header row
    entry.rawTSV[entry.headerRowIndex] = rebuildHeaderRow(entry.columns)
    -- Insert empty cell in all data rows
    for _, row in iterDataRows(entry) do
        table.insert(row, targetIdx, "")
    end
    markDirty(entry)
    return true
end

--- Remove a column from a file.
--- @param fileName string
--- @param columnName string
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:removeColumn(fileName, columnName)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local col
    col, err = assertColumnExists(entry, columnName)
    if not col then return nil, err end
    local idx = col.index
    -- Remove from columns list
    table.remove(entry.columns, idx)
    reindexColumns(entry)
    -- Update header row
    entry.rawTSV[entry.headerRowIndex] = rebuildHeaderRow(entry.columns)
    -- Remove cell from all data rows
    for _, row in iterDataRows(entry) do
        table.remove(row, idx)
    end
    markDirty(entry)
    return true
end

--- Rename a column (preserves type and default).
--- @param fileName string
--- @param oldName string
--- @param newName string
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:renameColumn(fileName, oldName, newName)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local col
    col, err = assertColumnExists(entry, oldName)
    if not col then return nil, err end
    if entry.columnIndex[newName] then
        return nil, "column already exists: " .. newName
    end
    -- Update the column info
    entry.columnIndex[oldName] = nil
    col.name = newName
    col.spec = rebuildSpec(col)
    entry.columnIndex[newName] = col
    -- Update header row
    entry.rawTSV[entry.headerRowIndex] = rebuildHeaderRow(entry.columns)
    markDirty(entry)
    return true
end

--- Move a column to a new position.
--- @param fileName string
--- @param columnName string
--- @param position table Position: {after="name"}, {before="name"}, {index=N}
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:moveColumn(fileName, columnName, position)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local col
    col, err = assertColumnExists(entry, columnName)
    if not col then return nil, err end
    local oldIdx = col.index
    -- Remove from old position first
    table.remove(entry.columns, oldIdx)
    reindexColumns(entry)
    -- Resolve target position (after removal, indices may have shifted)
    local targetIdx
    targetIdx, err = resolveColumnPosition(entry.columns, entry.columnIndex, position)
    if not targetIdx then
        -- Restore on error
        table.insert(entry.columns, oldIdx, col)
        reindexColumns(entry)
        return nil, err
    end
    -- Insert at new position
    table.insert(entry.columns, targetIdx, col)
    reindexColumns(entry)
    -- Update header row
    entry.rawTSV[entry.headerRowIndex] = rebuildHeaderRow(entry.columns)
    -- Adjust targetIdx if removing shifted it
    local insertIdx = targetIdx
    if oldIdx < targetIdx then
        insertIdx = insertIdx -- already correct after removal
    end
    -- Reorder cells in all data rows
    for _, row in iterDataRows(entry) do
        local cell = table.remove(row, oldIdx)
        table.insert(row, insertIdx, cell)
    end
    markDirty(entry)
    return true
end

--- Change the type in a column header.
--- @param fileName string
--- @param columnName string
--- @param newType string
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:setColumnType(fileName, columnName, newType)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    if type(newType) ~= "string" or newType == "" then
        return nil, "newType must be a non-empty string"
    end
    local col
    col, err = assertColumnExists(entry, columnName)
    if not col then return nil, err end
    col.typeSpec = newType
    col.spec = rebuildSpec(col)
    -- Update header row
    entry.rawTSV[entry.headerRowIndex] = rebuildHeaderRow(entry.columns)
    markDirty(entry)
    return true
end

--- Set/change/remove the default value for a column.
--- @param fileName string
--- @param columnName string
--- @param defaultValue string|nil The default value (nil to remove)
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:setColumnDefault(fileName, columnName, defaultValue)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local col
    col, err = assertColumnExists(entry, columnName)
    if not col then return nil, err end
    col.default = defaultValue
    col.spec = rebuildSpec(col)
    entry.rawTSV[entry.headerRowIndex] = rebuildHeaderRow(entry.columns)
    markDirty(entry)
    return true
end

---------------------------------------------------------------------------
-- Row operations
---------------------------------------------------------------------------

--- Return number of data rows in a file.
--- @param fileName string
--- @return number|nil count
--- @return string|nil error message
function DataSet:rowCount(fileName)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local count = 0
    for _ in iterDataRows(entry) do
        count = count + 1
    end
    return count
end

--- Check if a row with the given primary key exists.
--- @param fileName string
--- @param key string
--- @return boolean
function DataSet:hasRow(fileName, key)
    local entry = self.files[fileName]
    if not entry then return false end
    local idx = findDataRowByKey(entry, key)
    return idx ~= nil
end

--- Get a row by primary key (returns name→value table).
--- @param fileName string
--- @param key string
--- @return table|nil Map of columnName → cellValue
--- @return string|nil error message
function DataSet:getRow(fileName, key)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local _, row = findDataRowByKey(entry, key)
    if not row then
        return nil, "row not found: " .. tostring(key)
    end
    local result = {}
    for _, col in ipairs(entry.columns) do
        result[col.name] = row[col.index] or ""
    end
    return result
end

--- Get a row by 1-based data-row index.
--- @param fileName string
--- @param rowIndex number 1-based index among data rows only
--- @return table|nil Map of columnName → cellValue
--- @return string|nil error message
function DataSet:getRowByIndex(fileName, rowIndex)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local count = 0
    for _, row in iterDataRows(entry) do
        count = count + 1
        if count == rowIndex then
            local result = {}
            for _, col in ipairs(entry.columns) do
                result[col.name] = row[col.index] or ""
            end
            return result
        end
    end
    return nil, "row index out of range: " .. tostring(rowIndex)
end

--- Append a new data row.
--- @param fileName string
--- @param values table Sequence of cell values or name→value table
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:addRow(fileName, values)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local row = {}
    if #values > 0 then
        -- Sequence of cell values
        for i, v in ipairs(values) do
            row[i] = v
        end
    else
        -- Name→value table
        for _, col in ipairs(entry.columns) do
            row[col.index] = values[col.name] or ""
        end
    end
    -- Check for duplicate primary key
    if row[1] and row[1] ~= "" then
        local existing = findDataRowByKey(entry, row[1])
        if existing then
            return nil, "duplicate primary key: " .. tostring(row[1])
        end
    end
    table.insert(entry.rawTSV, row)
    markDirty(entry)
    return true
end

--- Remove a row by primary key.
--- @param fileName string
--- @param key string
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:removeRow(fileName, key)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local idx = findDataRowByKey(entry, key)
    if not idx then
        return nil, "row not found: " .. tostring(key)
    end
    -- Safety guard: findDataRowByKey already skips the header, but be defensive
    if idx == entry.headerRowIndex then
        return nil, "cannot remove the header row"
    end
    table.remove(entry.rawTSV, idx)
    markDirty(entry)
    return true
end

---------------------------------------------------------------------------
-- Cell operations
---------------------------------------------------------------------------

--- Get a single cell value.
--- @param fileName string
--- @param key string Primary key
--- @param columnName string
--- @return string|nil The cell value
--- @return string|nil error message
function DataSet:getCell(fileName, key, columnName)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local col
    col, err = assertColumnExists(entry, columnName)
    if not col then return nil, err end
    local _, row = findDataRowByKey(entry, key)
    if not row then
        return nil, "row not found: " .. tostring(key)
    end
    return row[col.index] or ""
end

--- Set a single cell value.
--- @param fileName string
--- @param key string Primary key
--- @param columnName string
--- @param value string
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:setCell(fileName, key, columnName, value)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local col
    col, err = assertColumnExists(entry, columnName)
    if not col then return nil, err end
    local _, row = findDataRowByKey(entry, key)
    if not row then
        return nil, "row not found: " .. tostring(key)
    end
    -- Note: findDataRowByKey skips the header row, so this can only modify data cells.
    -- Setting column 1 (primary key) changes the row's lookup key — this is intentional
    -- (used by filesHelper:updatePath).
    row[col.index] = value
    markDirty(entry)
    return true
end

--- Set ALL cells in a column to a value.
--- @param fileName string
--- @param columnName string
--- @param value string
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:setCells(fileName, columnName, value)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local col
    col, err = assertColumnExists(entry, columnName)
    if not col then return nil, err end
    for _, row in iterDataRows(entry) do
        row[col.index] = value
    end
    markDirty(entry)
    return true
end

--- Conditional cell update: set cells where another column matches a value.
--- @param fileName string
--- @param columnName string Column to update
--- @param value string New value
--- @param whereColumn string Column to check
--- @param whereValue string Value to match
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:setCellsWhere(fileName, columnName, value, whereColumn, whereValue)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local col
    col, err = assertColumnExists(entry, columnName)
    if not col then return nil, err end
    local whereCol
    whereCol, err = assertColumnExists(entry, whereColumn)
    if not whereCol then return nil, err end
    for _, row in iterDataRows(entry) do
        if row[whereCol.index] == whereValue then
            row[col.index] = value
        end
    end
    markDirty(entry)
    return true
end

--- Apply a sandboxed expression to each cell in a column.
--- The expression receives: value, row, rowIndex, key, fileName as variables.
--- @param fileName string
--- @param columnName string
--- @param expression string Lua expression to evaluate
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:transformCells(fileName, columnName, expression)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local col
    col, err = assertColumnExists(entry, columnName)
    if not col then return nil, err end
    local code = "return (" .. expression .. ")"
    local dataRowIndex = 0
    for _, row in iterDataRows(entry) do
        dataRowIndex = dataRowIndex + 1
        -- Build row context as name→value table
        local rowCtx = {}
        for _, c in ipairs(entry.columns) do
            rowCtx[c.name] = row[c.index] or ""
        end
        local env = {
            value = row[col.index] or "",
            row = rowCtx,
            rowIndex = dataRowIndex,
            key = row[1] or "",
            fileName = fileName,
            tostring = tostring,
            tonumber = tonumber,
            type = type,
            math = math,
            string = string,
            table = table,
        }
        -- Provide read-only access to other cells/rows in the dataset
        env.getCell = function(fn, k, cn)
            return self:getCell(fn, k, cn)
        end
        env.getRow = function(fn, k)
            return self:getRow(fn, k)
        end
        local opt = {env = env}
        if sandbox.quota_supported then
            opt.quota = 10000
        end
        local ok, protected = pcall(sandbox.protect, code, opt)
        if not ok then
            return nil, "transformCells compile error: " .. tostring(protected)
        end
        local execOk, result = pcall(protected)
        if not execOk then
            return nil, "transformCells error at row " .. tostring(row[1]) .. ": " .. tostring(result)
        end
        if result ~= nil then
            row[col.index] = result
        end
    end
    markDirty(entry)
    return true
end

---------------------------------------------------------------------------
-- Comment / blank line operations
---------------------------------------------------------------------------

--- Insert a comment line.
--- @param fileName string
--- @param text string Comment text (without leading #)
--- @param position table|nil Position spec
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:addComment(fileName, text, position)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local idx
    idx, err = resolveLinePosition(entry, position)
    if not idx then return nil, err end
    if type(text) ~= "string" then
        return nil, "comment text must be a string, got: " .. type(text)
    end
    local comment = "# " .. text
    table.insert(entry.rawTSV, idx, comment)
    -- Adjust headerRowIndex if insertion was before it
    if idx <= entry.headerRowIndex then
        entry.headerRowIndex = entry.headerRowIndex + 1
    end
    markDirty(entry)
    return true
end

--- Insert a blank line.
--- @param fileName string
--- @param position table|nil Position spec
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:addBlankLine(fileName, position)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    local idx
    idx, err = resolveLinePosition(entry, position)
    if not idx then return nil, err end
    table.insert(entry.rawTSV, idx, "")
    if idx <= entry.headerRowIndex then
        entry.headerRowIndex = entry.headerRowIndex + 1
    end
    markDirty(entry)
    return true
end

--- Remove a line at a raw (absolute) index.
--- @param fileName string
--- @param rawIndex number 1-based raw index
--- @return boolean|nil true on success
--- @return string|nil error message
function DataSet:removeLineAt(fileName, rawIndex)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    if rawIndex < 1 or rawIndex > #entry.rawTSV then
        return nil, "raw index out of range: " .. tostring(rawIndex)
    end
    if rawIndex == entry.headerRowIndex then
        return nil, "cannot remove the header row"
    end
    table.remove(entry.rawTSV, rawIndex)
    if rawIndex < entry.headerRowIndex then
        entry.headerRowIndex = entry.headerRowIndex - 1
    end
    markDirty(entry)
    return true
end

--- Get total raw line count (including comments/blanks).
--- @param fileName string
--- @return number|nil count
--- @return string|nil error message
function DataSet:getRawLineCount(fileName)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    return #entry.rawTSV
end

--- Get any line by absolute index.
--- @param fileName string
--- @param rawIndex number
--- @return any|nil The line (string or table)
--- @return string|nil error message
function DataSet:getRawLine(fileName, rawIndex)
    local entry, err = assertFileLoaded(self, fileName)
    if not entry then return nil, err end
    if rawIndex < 1 or rawIndex > #entry.rawTSV then
        return nil, "raw index out of range: " .. tostring(rawIndex)
    end
    return entry.rawTSV[rawIndex]
end

--- Check if a line at rawIndex is a comment.
--- @param fileName string
--- @param rawIndex number
--- @return boolean
function DataSet:isCommentLine(fileName, rawIndex)
    local entry = self.files[fileName]
    if not entry then return false end
    local line = entry.rawTSV[rawIndex]
    return type(line) == "string" and line:sub(1, 1) == "#"
end

--- Check if a line at rawIndex is blank.
--- @param fileName string
--- @param rawIndex number
--- @return boolean
function DataSet:isBlankLine(fileName, rawIndex)
    local entry = self.files[fileName]
    if not entry then return false end
    local line = entry.rawTSV[rawIndex]
    return type(line) == "string" and string_utils.trim(line) == ""
end

---------------------------------------------------------------------------
-- Files.tsv helper
---------------------------------------------------------------------------

local FilesHelper = {}
FilesHelper.__index = FilesHelper

--- Create a Files.tsv helper.
--- @param filesName string|nil The Files.tsv file name (default "Files.tsv")
--- @return table|nil FilesHelper instance, or nil on error
--- @return string|nil error message
function DataSet:filesHelper(filesName)
    filesName = filesName or "Files.tsv"
    local entry, err = assertFileLoaded(self, filesName)
    if not entry then return nil, err end
    local helper = setmetatable({}, FilesHelper)
    helper.ds = self
    helper.filesName = filesName
    return helper
end

--- Update the fileName column for a file entry.
--- @param oldPath string Current fileName value (primary key)
--- @param newPath string New fileName value
--- @return boolean|nil true on success
--- @return string|nil error message
function FilesHelper:updatePath(oldPath, newPath)
    if type(newPath) ~= "string" or newPath == "" then
        return nil, "newPath must be a non-empty string"
    end
    return self.ds:setCell(self.filesName, oldPath, "fileName", newPath)
end

--- Update the superType column for a file entry.
--- @param fileName string The primary key in Files.tsv
--- @param newSuperType string New superType value
--- @return boolean|nil true on success
--- @return string|nil error message
function FilesHelper:updateSuperType(fileName, newSuperType)
    if type(newSuperType) ~= "string" then
        return nil, "newSuperType must be a string"
    end
    return self.ds:setCell(self.filesName, fileName, "superType", newSuperType)
end

--- Update the loadOrder column for a file entry.
--- @param fileName string The primary key in Files.tsv
--- @param newLoadOrder string New loadOrder value
--- @return boolean|nil true on success
--- @return string|nil error message
function FilesHelper:updateLoadOrder(fileName, newLoadOrder)
    if type(newLoadOrder) ~= "string" then
        return nil, "newLoadOrder must be a string"
    end
    return self.ds:setCell(self.filesName, fileName, "loadOrder", newLoadOrder)
end

--- Update the typeName column for a file entry.
--- @param fileName string The primary key in Files.tsv
--- @param newTypeName string New typeName value
--- @return boolean|nil true on success
--- @return string|nil error message
function FilesHelper:updateTypeName(fileName, newTypeName)
    if type(newTypeName) ~= "string" or newTypeName == "" then
        return nil, "newTypeName must be a non-empty string"
    end
    return self.ds:setCell(self.filesName, fileName, "typeName", newTypeName)
end

--- Add a new file entry.
--- @param entry table Map of field→value or sequence of values
--- @return boolean|nil true on success
--- @return string|nil error message
function FilesHelper:addEntry(entry)
    if type(entry) ~= "table" then
        return nil, "entry must be a table"
    end
    return self.ds:addRow(self.filesName, entry)
end

--- Remove a file entry by fileName.
--- @param fileName string The primary key
--- @return boolean|nil true on success
--- @return string|nil error message
function FilesHelper:removeEntry(fileName)
    return self.ds:removeRow(self.filesName, fileName)
end

--- Get all fields for a file entry.
--- @param fileName string The primary key
--- @return table|nil Map of field→value
--- @return string|nil error message
function FilesHelper:getEntry(fileName)
    return self.ds:getRow(self.filesName, fileName)
end

---------------------------------------------------------------------------
-- Manifest helper
---------------------------------------------------------------------------

local ManifestHelper = {}
ManifestHelper.__index = ManifestHelper

--- Create a Manifest helper.
--- @param manifestName string|nil The manifest file name (default "Manifest.transposed.tsv")
--- @return table|nil ManifestHelper instance, or nil on error
--- @return string|nil error message
function DataSet:manifestHelper(manifestName)
    manifestName = manifestName or "Manifest.transposed.tsv"
    local entry, err = assertFileLoaded(self, manifestName)
    if not entry then return nil, err end
    local helper = setmetatable({}, ManifestHelper)
    helper.ds = self
    helper.manifestName = manifestName
    return helper
end

--- Get a manifest field value.
--- @param fieldName string The field name (primary key in transposed format)
--- @return string|nil The value
--- @return string|nil error message
function ManifestHelper:getField(fieldName)
    -- In transposed format, column 1 is the field name, column 2 is the value
    local entry, err = assertFileLoaded(self.ds, self.manifestName)
    if not entry then return nil, err end
    local _, row = findDataRowByKey(entry, fieldName)
    if not row then
        return nil, "manifest field not found: " .. tostring(fieldName)
    end
    return row[2] or ""
end

--- Set a manifest field value.
--- @param fieldName string The field name
--- @param value string The new value
--- @return boolean|nil true on success
--- @return string|nil error message
function ManifestHelper:setField(fieldName, value)
    local entry, err = assertFileLoaded(self.ds, self.manifestName)
    if not entry then return nil, err end
    local _, row = findDataRowByKey(entry, fieldName)
    if not row then
        return nil, "manifest field not found: " .. tostring(fieldName)
    end
    if type(value) ~= "string" then
        return nil, "value must be a string, got: " .. type(value)
    end
    row[2] = value
    markDirty(entry)
    return true
end

--- Get the package_id field.
--- @return string|nil
--- @return string|nil error message
function ManifestHelper:getPackageId()
    return self:getField("package_id")
end

--- Get the version field.
--- @return string|nil
--- @return string|nil error message
function ManifestHelper:getVersion()
    return self:getField("version")
end

---------------------------------------------------------------------------
-- Module API
---------------------------------------------------------------------------

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    new = DataSet.new,
    getVersion = getVersion,
}

local function apiCall(_, operation, ...)
    if operation == "version" then
        return VERSION
    elseif operation == "new" then
        return DataSet.new(...)
    elseif API[operation] then
        return API[operation](...)
    else
        error("Unknown operation: " .. tostring(operation), 2)
    end
end

return readOnly(API, {__tostring = apiToString, __call = apiCall, __type = NAME})
