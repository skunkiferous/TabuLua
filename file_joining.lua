-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 10, 0)

-- Module name
local NAME = "file_joining"

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

local read_only = require("read_only")
local readOnly = read_only.readOnly

local table_utils = require("table_utils")
local shallowCopy = table_utils.tableShallowCopy

--- Builds an index of rows by a specified join column.
--- @param tsv table The parsed TSV data (array of rows, first row is header)
--- @param joinColumn string The column name to index by
--- @return table|nil index Map of join key -> row, or nil if column not found
--- @return string|nil error Error message if column not found
local function buildJoinIndex(tsv, joinColumn)
    local header = tsv[1]
    local joinColIdx = -1

    -- Find the join column index
    for idx, col in ipairs(header) do
        if col.name == joinColumn then
            joinColIdx = idx
            break
        end
    end

    if joinColIdx == -1 then
        return nil, "Join column '" .. joinColumn .. "' not found"
    end

    local index = {}
    for i, row in ipairs(tsv) do
        if i > 1 and type(row) == "table" then
            local key = row[joinColIdx].parsed
            if key ~= nil and key ~= '' then
                index[key] = row
            end
        end
    end

    return index, nil
end

--- Finds the default join column (first column) for a file.
--- @param tsv table The parsed TSV data
--- @return string|nil The name of the first column, or nil if not found
local function getDefaultJoinColumn(tsv)
    local header = tsv[1]
    if header and header[1] then
        return header[1].name
    end
    return nil
end

--- Detects column name conflicts between primary and secondary files.
--- @param primaryHeader table Header of the primary file
--- @param secondaryHeader table Header of the secondary file
--- @param joinColumn string The join column (allowed to be duplicate)
--- @return table|nil conflicts Array of conflicting column names, or nil if none
local function detectColumnConflicts(primaryHeader, secondaryHeader, joinColumn)
    local primaryCols = {}
    for _, col in ipairs(primaryHeader) do
        if col.name ~= joinColumn then
            primaryCols[col.name] = true
        end
    end

    local conflicts = {}
    for _, col in ipairs(secondaryHeader) do
        if col.name ~= joinColumn and primaryCols[col.name] then
            conflicts[#conflicts + 1] = col.name
        end
    end

    if #conflicts > 0 then
        return conflicts
    end
    return nil
end

--- Performs a LEFT JOIN between a primary file and multiple secondary files.
--- All rows from the primary file are included; matching rows from secondary files add columns.
--- @param primaryTsv table The primary TSV data
--- @param secondaryTsvList table Array of {tsv, joinColumn, sourceName} for each secondary file
--- @param badVal table Error reporting object
--- @return table|nil joinedRows Array of joined rows (excluding header), or nil on error
--- @return table|nil joinedHeader The merged header, or nil on error
local function joinFiles(primaryTsv, secondaryTsvList, badVal)
    local primaryHeader = primaryTsv[1]
    local joinColumn = nil

    -- Build indices for all secondary files and detect conflicts
    local secondaryData = {}
    for _, secInfo in ipairs(secondaryTsvList) do
        local secTsv = secInfo.tsv
        local secJoinColumn = secInfo.joinColumn or getDefaultJoinColumn(secTsv)
        local secSourceName = secInfo.sourceName

        if secJoinColumn == nil then
            badVal.source_name = secSourceName
            badVal.line_no = 0
            badVal(nil, "Cannot determine join column for secondary file")
            return nil, nil
        end

        if joinColumn == nil then
            joinColumn = secJoinColumn
        elseif joinColumn ~= secJoinColumn then
            badVal.source_name = secSourceName
            badVal.line_no = 0
            badVal(secJoinColumn, "All secondary files must use the same join column. Expected '"
                .. joinColumn .. "' but got '" .. secJoinColumn .. "'")
            return nil, nil
        end

        -- Check for column conflicts
        local secHeader = secTsv[1]
        local conflicts = detectColumnConflicts(primaryHeader, secHeader, joinColumn)
        if conflicts then
            badVal.source_name = secSourceName
            badVal.line_no = 0
            for _, colName in ipairs(conflicts) do
                badVal(colName, "Column name conflict with primary file")
            end
            return nil, nil
        end

        -- Build index
        local index, err = buildJoinIndex(secTsv, secJoinColumn)
        if not index then
            badVal.source_name = secSourceName
            badVal.line_no = 0
            badVal(secJoinColumn, err)
            return nil, nil
        end

        secondaryData[#secondaryData + 1] = {
            tsv = secTsv,
            header = secHeader,
            index = index,
            joinColumn = secJoinColumn,
            sourceName = secSourceName,
            matchedKeys = {},  -- Track which keys were matched
        }
    end

    -- Find the join column index in primary file
    local primaryJoinColIdx = -1
    for idx, col in ipairs(primaryHeader) do
        if col.name == joinColumn then
            primaryJoinColIdx = idx
            break
        end
    end

    if primaryJoinColIdx == -1 then
        badVal.source_name = primaryTsv[1].__source
        badVal.line_no = 0
        badVal(joinColumn, "Join column not found in primary file")
        return nil, nil
    end

    -- Build merged header
    local mergedHeader = {}
    for _, col in ipairs(primaryHeader) do
        mergedHeader[#mergedHeader + 1] = col
    end
    for _, secData in ipairs(secondaryData) do
        for _, col in ipairs(secData.header) do
            if col.name ~= joinColumn then
                mergedHeader[#mergedHeader + 1] = col
            end
        end
    end

    -- Perform the join
    local joinedRows = {}
    for i, primaryRow in ipairs(primaryTsv) do
        if i > 1 and type(primaryRow) == "table" then
            local joinKey = primaryRow[primaryJoinColIdx].parsed
            local mergedRow = shallowCopy(primaryRow)

            -- Add columns from each secondary file
            for _, secData in ipairs(secondaryData) do
                local secRow = secData.index[joinKey]
                if secRow then
                    secData.matchedKeys[joinKey] = true
                    -- Copy non-join columns from secondary row
                    for colIdx, col in ipairs(secData.header) do
                        if col.name ~= joinColumn then
                            mergedRow[#mergedRow + 1] = secRow[colIdx]
                        end
                    end
                else
                    -- No match: add nil cells for secondary columns
                    for j, col in ipairs(secData.header) do
                        if col.name ~= joinColumn then
                            mergedRow[#mergedRow + 1] = {
                                parsed = nil,
                                value = "",
                                reformatted = "",
                            }
                        end
                    end
                end
            end

            joinedRows[#joinedRows + 1] = mergedRow
        end
    end

    -- Report unmatched rows in secondary files as errors
    for _, secData in ipairs(secondaryData) do
        for key, _secRow in pairs(secData.index) do
            if not secData.matchedKeys[key] then
                badVal.source_name = secData.sourceName
                badVal.line_no = 0
                badVal(key, "Row in secondary file has no matching row in primary file")
            end
        end
    end

    return joinedRows, mergedHeader
end

--- Determines if a file should be exported based on joinMeta.
--- Files with joinInto default to export=false, others default to true.
--- @param lcfn string Lowercase filename
--- @param joinMeta table Join metadata from manifest_loader
--- @return boolean True if the file should be exported
local function shouldExport(lcfn, joinMeta)
    local explicitExport = joinMeta.lcFn2Export[lcfn]
    if explicitExport ~= nil then
        return explicitExport
    end
    -- Default: export=false if joinInto is set, export=true otherwise
    return joinMeta.lcFn2JoinInto[lcfn] == nil
end

--- Groups secondary files by their primary file target.
--- @param joinMeta table Join metadata from manifest_loader
--- @return table Map of primary lcfn -> array of secondary lcfn
local function groupSecondaryFiles(joinMeta)
    local groups = {}
    for lcfn, joinTarget in pairs(joinMeta.lcFn2JoinInto) do
        if not groups[joinTarget] then
            groups[joinTarget] = {}
        end
        groups[joinTarget][#groups[joinTarget] + 1] = lcfn
    end
    return groups
end

--- Finds the actual file path from a lowercase filename.
--- @param lcfn string Lowercase filename
--- @param tsv_files table Map of file paths to TSV data
--- @return string|nil The actual file path, or nil if not found
local function findFilePath(lcfn, tsv_files)
    for path in pairs(tsv_files) do
        local lpath = path:lower()
        if lpath:sub(-#lcfn) == lcfn then
            local pos = #lpath - #lcfn
            if pos == 0 or lpath:sub(pos, pos) == "/" or lpath:sub(pos, pos) == "\\" then
                return path
            end
        end
    end
    return nil
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    buildJoinIndex = buildJoinIndex,
    getDefaultJoinColumn = getDefaultJoinColumn,
    detectColumnConflicts = detectColumnConflicts,
    joinFiles = joinFiles,
    shouldExport = shouldExport,
    groupSecondaryFiles = groupSecondaryFiles,
    findFilePath = findFilePath,
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
