-- Module name
local NAME = "files_desc"

-- Module logger
local logger = require( "named_logger").getLogger(NAME)

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 13, 0)

-- Returns the module version
local function getVersion()
    return tostring(VERSION)
end

-- Files that need "post-processing" because they define things that need "registering"
local POST_PROCESS_PARENTS = {Type=true, enum=true}

local read_only = require("read_only")
local readOnly = read_only.readOnly
local table_utils = require("table_utils")
local filterSeq = table_utils.filterSeq
local longestMatchingPrefix = table_utils.longestMatchingPrefix
local appendSeq = table_utils.appendSeq
local clearSeq = table_utils.clearSeq

local file_util = require("file_util")
local getParentPath = file_util.getParentPath
local sortFilesBreadthFirst = file_util.sortFilesBreadthFirst
local readFile = file_util.readFile

local lua_cog = require("lua_cog")

local raw_tsv = require("raw_tsv")
local stringToRawTSV = raw_tsv.stringToRawTSV

local tsv_model = require("tsv_model")
local processTSV = tsv_model.processTSV
local TRANSPOSED_TSV_EXT = tsv_model.TRANSPOSED_TSV_EXT

local parsers = require("parsers")
local parseType = parsers.parseType
local recordFieldTypes = parsers.recordFieldTypes

-- File containing priorities/load-order, in lowercase
local FILES_DESC = "files.tsv"

-- Expected columns of the "files descriptor" files
local FILE_NAME_COL = "fileName:string"
local TYPE_NAME_COL = "typeName:type_spec"
local SUPER_TYPE_COL = "superType:super_type"
local BASE_TYPE_COL = "baseType:boolean"
local PUBLISH_CONTEXT_COL = "publishContext:name|nil"
local PUBLISH_COLUMN_COL = "publishColumn:name|nil"
local LOAD_ORDER_COL = "loadOrder:number"
local DESCRIPTION_COL = "description:text"
-- File joining columns
local JOIN_INTO_COL = "joinInto:name|nil"
local JOIN_COLUMN_COL = "joinColumn:name|nil"
local EXPORT_COL = "export:boolean|nil"
local JOINED_TYPE_NAME_COL = "joinedTypeName:type_spec|nil"
-- Validator columns
local ROW_VALIDATORS_COL = "rowValidators:{validator_spec}|nil"
local FILE_VALIDATORS_COL = "fileValidators:{validator_spec}|nil"

-- Returns true, if this is a process-first meta-data file
local function isFilesDescriptor(file)
    return file:lower():sub(-#FILES_DESC) == FILES_DESC
end

-- Finds, and removes, the metadata files that define the priority
local function extractFilesDescriptors(files)
    return filterSeq(files, isFilesDescriptor)
end

-- Matches packages (package_id=>package{.path}]) and their descriptor files
local function matchDescriptorFiles(packages, descriptorFilesNames, log)
    log = log or logger
    local paths = {}
    local path2pkg_id = {}
    for package_id, package in pairs(packages) do
        local path = (getParentPath(package.path) or ""):lower()
        paths[#paths+1] = path
        path2pkg_id[path] = package_id
    end
    local result = {}
    local fail = false
    for _, file in ipairs(descriptorFilesNames) do
        local parent = (getParentPath(file) or ""):lower()
        local package_id = path2pkg_id[parent]
        if package_id then
            result[file] = package_id
        else
            -- Hopefully, file descriptor belongs to subdirectory of a package
            local matching = longestMatchingPrefix(paths, parent)
            if #matching > 0 then
                result[file] = path2pkg_id[matching]
            else
                log:error("File descriptor " .. file .. " does not belong to any package")
                fail = true
            end
        end
    end
    if fail then
        return nil
    end
    return result
end

-- Order files descriptors, based on package dependencies
-- Within a single package, files are sorted in breadth-first order,
-- but, the order of files descriptors within a package should not matter
local function orderFilesDescByPackageOrder(package_order, desc_file2pkg_id)
    local desc_files_order = {}
    for _, package_id in ipairs(package_order) do
        local pkg_files = {}
        for file, package_id2 in pairs(desc_file2pkg_id) do
            if package_id == package_id2 then
                pkg_files[#pkg_files+1] = file
            end
        end
        sortFilesBreadthFirst(pkg_files)
        appendSeq(desc_files_order, pkg_files)
    end
    return desc_files_order
end

-- Loads a file descriptor as TSV
local function genLoadDescriptorFile()
    local ldfParserFinder = parseType
        -- Only for loadDescriptorFile ...
    local ldfExprEval = tsv_model.expressionEvaluatorGenerator({})

    -- Loads a file descriptor as TSV
    local result = function(file, raw_files, loadEnv, badVal)
        logger:info("Processing descriptor file: " .. file)
        local content, err = readFile(file)
        if not content then
            badVal(nil, "File " .. file .. " could not be read: " .. err)
            return nil, err
        end
        raw_files[file] = content
        content = lua_cog.processContentBV(file, content, loadEnv, badVal)
        local rawtsv = stringToRawTSV(content)
        return processTSV(tsv_model.defaultOptionsExtractor, ldfExprEval, ldfParserFinder,
            file, rawtsv, badVal, nil, false)
    end

    return result
end

-- Loads a file descriptor as TSV
local loadDescriptorFile = genLoadDescriptorFile()

-- Warn if column is missing
local function warnMissingColumn(file_name, col_idx, col_name, log)
    if col_idx == -1 then
        log = log or logger
        log:warn("Missing column '" .. col_name .. "' in " .. file_name)
    end
end

-- Parse files descriptions header
local function parseFilesDescHeader(file_name, file, log)
    local header = file[1]
    local fileNameIdx = -1
    local typeNameIdx = -1
    local superTypeIdx = -1
    local baseTypeIdx = -1
    local publishContextIdx = -1
    local publishColumnIdx = -1
    local loadOrderIdx = -1
    local joinIntoIdx = -1
    local joinColumnIdx = -1
    local exportIdx = -1
    local joinedTypeNameIdx = -1
    local rowValidatorsIdx = -1
    local fileValidatorsIdx = -1
    for idx, col in ipairs(header) do
        local colStr = tostring(col)
        if colStr == FILE_NAME_COL then
            fileNameIdx = idx
        elseif colStr == TYPE_NAME_COL then
            typeNameIdx = idx
        elseif colStr == SUPER_TYPE_COL then
            superTypeIdx = idx
        elseif colStr == BASE_TYPE_COL then
            baseTypeIdx = idx
        elseif colStr == PUBLISH_CONTEXT_COL then
            publishContextIdx = idx
        elseif colStr == PUBLISH_COLUMN_COL then
            publishColumnIdx = idx
        elseif colStr == LOAD_ORDER_COL then
            loadOrderIdx = idx
        elseif colStr == JOIN_INTO_COL then
            joinIntoIdx = idx
        elseif colStr == JOIN_COLUMN_COL then
            joinColumnIdx = idx
        elseif colStr == EXPORT_COL then
            exportIdx = idx
        elseif colStr == JOINED_TYPE_NAME_COL then
            joinedTypeNameIdx = idx
        elseif colStr == ROW_VALIDATORS_COL then
            rowValidatorsIdx = idx
        elseif colStr == FILE_VALIDATORS_COL then
            fileValidatorsIdx = idx
        elseif colStr== DESCRIPTION_COL then
            -- For the user only; ignore ...
        else
            logger:warn("Column ignored: "..colStr)
        end
    end
    warnMissingColumn(file_name, fileNameIdx, "fileName", log)
    warnMissingColumn(file_name, typeNameIdx, "typeName", log)
    warnMissingColumn(file_name, superTypeIdx, "superType", log)
    warnMissingColumn(file_name, baseTypeIdx, "baseType", log)
    warnMissingColumn(file_name, publishContextIdx, "publishContext", log)
    warnMissingColumn(file_name, publishColumnIdx, "publishColumn", log)
    warnMissingColumn(file_name, loadOrderIdx, "loadOrder", log)
    -- Note: join columns and validator columns are optional, so we don't warn if missing
    return fileNameIdx, typeNameIdx, superTypeIdx, baseTypeIdx, publishContextIdx,
        publishColumnIdx, loadOrderIdx, joinIntoIdx, joinColumnIdx, exportIdx, joinedTypeNameIdx,
        rowValidatorsIdx, fileValidatorsIdx
end

-- Check the file name matches the type name
local function checkTypeName(extends, fileDesc, fileName, typeName, superType, log)
    if typeName then
        log = log or logger
        local idx = fileName:find("/[^/]*$")
        local fileNameWithoutPath = (idx and fileName:sub(idx + 1)) or fileName
        -- Handle compound extension ".transposed.tsv" as a single extension
        local fileNameWithoutExt
        if fileNameWithoutPath:sub(-#TRANSPOSED_TSV_EXT) == TRANSPOSED_TSV_EXT then
            fileNameWithoutExt = fileNameWithoutPath:sub(1, -#TRANSPOSED_TSV_EXT - 1)
        else
            idx = (fileNameWithoutPath:reverse()):find("%.")
            fileNameWithoutExt = fileNameWithoutPath:sub(1, -idx-1)
        end
        if typeName:lower() ~= fileNameWithoutExt:lower() then
            -- Retry after removing dots (e.g., Item.en -> ItemEn matches ItemEN)
            local dotless = fileNameWithoutExt:gsub("%.", "")
            if typeName:lower() ~= dotless:lower() then
                log:warn("typeName '" .. typeName
                    .. "' in " .. fileDesc
                    .. " should match fileName '" .. fileName
                    .. "' without extension")
            end
        end
        if superType and #superType > 0 then
            if typeName:lower() == superType:lower() then
                log:warn("typeName '" .. typeName
                    .. "' is same as superType '" .. superType
                    .. "' in " .. fileDesc)
            else
                extends[typeName] = superType
            end
        end
    end
end

-- Check the file base type
local function checkBaseType(fileDesc, fileName, baseType, superType, log)
    if baseType then
        log = log or logger
        if baseType ~= "true" and baseType ~= "false" then
            log:warn("baseType '" .. baseType
                .. "' in " .. fileDesc
                .. " should be 'true' or 'false'")
        elseif baseType == "true" and superType ~= "" and superType ~= nil
            and superType ~= "enum" then
            log:warn("superType '" .. superType .. "' of file '"
                .. fileName .. "' in " .. fileDesc
                .. " should be '' or baseType should be 'false'")
        end
    end
end

-- Collect data to later validate file and type names reuse
local function trackFileAndTypeNames(lcFileNames, lcTypeNames, lcfn, tn, file_name)
    local fnDefined = lcFileNames[lcfn] or {}
    fnDefined[#fnDefined+1] = file_name
    lcFileNames[lcfn] = fnDefined
    if tn then
        local tnDefined = lcTypeNames[tn:lower()] or {}
        tnDefined[#tnDefined+1] = file_name
        lcTypeNames[tn:lower()] = tnDefined
    end
end

-- Options object for processFilesDesc
-- @field prios table: Map of lowercase filename to priority
-- @field prio_offset number: Offset to add to priorities
-- @field extends table: Map of type name to super type
-- @field lcFileNames table: Map of lowercase filename to list of descriptor files
-- @field lcTypeNames table: Map of lowercase type name to list of descriptor files
-- @field lcFn2Type table: Map of lowercase filename to type name
-- @field lcFn2Ctx table: Map of lowercase filename to publish context
-- @field lcFn2Col table: Map of lowercase filename to publish column
-- @field lcFn2JoinInto table: Map of lowercase filename to join target filename
-- @field lcFn2JoinColumn table: Map of lowercase filename to join column name
-- @field lcFn2Export table: Map of lowercase filename to export flag (boolean|nil)
-- @field lcFn2JoinedTypeName table: Map of lowercase filename to joined type name
-- @field lcFn2RowValidators table: Map of lowercase filename to row validators list
-- @field lcFn2FileValidators table: Map of lowercase filename to file validators list
-- @field lcFn2LineNo table: Map of lowercase filename to line number in descriptor file
-- @field fn2Idx table: Map of descriptor file to column indices
-- @field log logger: Logger instance

-- Process the content of a descriptor file
-- @param file_name string: Path to the descriptor file
-- @param file table: Parsed TSV content
-- @param max_prio number: Current maximum priority
-- @param opts table: Options object (see above)
-- @return number: Updated maximum priority
local function processFilesDesc(file_name, file, max_prio, opts)
    local prios = opts.prios
    local prio_offset = opts.prio_offset
    local extends = opts.extends
    local lcFileNames = opts.lcFileNames
    local lcTypeNames = opts.lcTypeNames
    local lcFn2Type = opts.lcFn2Type
    local lcFn2Ctx = opts.lcFn2Ctx
    local lcFn2Col = opts.lcFn2Col
    local lcFn2JoinInto = opts.lcFn2JoinInto
    local lcFn2JoinColumn = opts.lcFn2JoinColumn
    local lcFn2Export = opts.lcFn2Export
    local lcFn2JoinedTypeName = opts.lcFn2JoinedTypeName
    local lcFn2RowValidators = opts.lcFn2RowValidators
    local lcFn2FileValidators = opts.lcFn2FileValidators
    local lcFn2LineNo = opts.lcFn2LineNo
    local fn2Idx = opts.fn2Idx
    local log = opts.log

    local fileNameIdx, typeNameIdx, superTypeIdx, baseTypeIdx, publishContextIdx, publishColumnIdx,
        loadOrderIdx, joinIntoIdx, joinColumnIdx, exportIdx, joinedTypeNameIdx,
        rowValidatorsIdx, fileValidatorsIdx =
        parseFilesDescHeader(file_name, file, log)
    fn2Idx[file_name] = {fileNameIdx, typeNameIdx, superTypeIdx, baseTypeIdx, publishContextIdx,
        publishColumnIdx, loadOrderIdx, joinIntoIdx, joinColumnIdx, exportIdx, joinedTypeNameIdx,
        rowValidatorsIdx, fileValidatorsIdx}
    if fileNameIdx ~= -1 and loadOrderIdx ~= -1 then
        for i, row in ipairs(file) do
            -- Ignore empty rows and header
            if i > 1 and type(row) == "table" then
                local fn = row[fileNameIdx].parsed
                local lcfn = fn:lower()
                local prio = tonumber(row[loadOrderIdx].parsed) or 0
                local tn = row[typeNameIdx].parsed
                local st = row[superTypeIdx].parsed
                local bt = tostring(row[baseTypeIdx].parsed)

                prio = prio + prio_offset
                prios[lcfn] = prio
                if prio > max_prio then
                    max_prio = prio
                end
                trackFileAndTypeNames(lcFileNames, lcTypeNames, lcfn, tn, file_name)
                checkTypeName(extends, file_name, fn, tn, st, log)
                checkBaseType(file_name, fn, bt, st, log)
                lcFn2Type[lcfn] = tn
                lcFn2LineNo[lcfn] = i
                lcFn2Ctx[lcfn] = row[publishContextIdx].parsed
                if lcFn2Ctx[lcfn] == '' then
                    lcFn2Ctx[lcfn] = nil
                end
                lcFn2Col[lcfn] = row[publishColumnIdx].parsed
                if lcFn2Col[lcfn] == '' then
                    lcFn2Col[lcfn] = nil
                end
                -- Handle file joining columns
                if joinIntoIdx ~= -1 then
                    local joinInto = row[joinIntoIdx] and row[joinIntoIdx].parsed
                    if joinInto and joinInto ~= '' then
                        lcFn2JoinInto[lcfn] = joinInto:lower()
                    end
                end
                if joinColumnIdx ~= -1 then
                    local joinColumn = row[joinColumnIdx] and row[joinColumnIdx].parsed
                    if joinColumn and joinColumn ~= '' then
                        lcFn2JoinColumn[lcfn] = joinColumn
                    end
                end
                if exportIdx ~= -1 then
                    local exportVal = row[exportIdx] and row[exportIdx].parsed
                    if exportVal ~= nil and exportVal ~= '' then
                        lcFn2Export[lcfn] = exportVal
                    end
                end
                if joinedTypeNameIdx ~= -1 then
                    local joinedTypeName = row[joinedTypeNameIdx] and row[joinedTypeNameIdx].parsed
                    if joinedTypeName and joinedTypeName ~= '' then
                        lcFn2JoinedTypeName[lcfn] = joinedTypeName
                    end
                end
                -- Handle validator columns
                if rowValidatorsIdx ~= -1 then
                    local rowValidators = row[rowValidatorsIdx] and row[rowValidatorsIdx].parsed
                    if rowValidators and type(rowValidators) == "table" and #rowValidators > 0 then
                        lcFn2RowValidators[lcfn] = rowValidators
                    end
                end
                if fileValidatorsIdx ~= -1 then
                    local fileValidators = row[fileValidatorsIdx] and row[fileValidatorsIdx].parsed
                    if fileValidators and type(fileValidators) == "table" and #fileValidators > 0 then
                        lcFn2FileValidators[lcfn] = fileValidators
                    end
                end
            end
        end
    end
    return max_prio
end

-- Detect post processing needed
local function detectPostProcessingNeeded(extends, post_proc_files, file_name, typeName, log)
    log = log or logger
    local tn = typeName
    while tn and #tn > 0 do
        if POST_PROCESS_PARENTS[tn] then
            post_proc_files[file_name] = typeName
            log:info("Found " .. tn .. " file: " .. file_name)
            break
        end
        tn = extends[tn]
    end
end

-- Reprocess all files of one mod, after first processing
local function reprocessFilesDesc(mod_files, post_proc_files, extends, log, fn2Idx)
    for _, file in ipairs(mod_files) do
        local fileNameIdx, typeNameIdx = table.unpack(fn2Idx[file[1].__source])
        for i, row in ipairs(file) do
            -- Ignore empty rows and header
            if i > 1 and type(row) == "table" then
                local fn = row[fileNameIdx].parsed
                local tn = row[typeNameIdx].parsed
                detectPostProcessingNeeded(extends, post_proc_files,
                fn, tn, log)
            end
        end
    end
end

-- Validates that sibling sub-types have consistent field types.
-- When two types extend the same parent (are siblings), any fields with the same name
-- must have the same type. This prevents ambiguity when working with the type hierarchy.
-- Exception: if both sibling types for a field are valid subtypes of the parent's field
-- type, the siblings may differ (each has narrowed the inherited field independently).
-- @param extends table: Map of type name to parent type name (child -> parent)
-- @param lcTypeNames table: Map of lowercase type name to list of descriptor file paths
-- @param badVal table: Error reporting object
local function validateSiblingFieldTypes(extends, lcTypeNames, badVal)
    -- Build parent -> children mapping (invert the extends table)
    local children = {}
    for childType, parentType in pairs(extends) do
        if not children[parentType] then
            children[parentType] = {}
        end
        children[parentType][#children[parentType] + 1] = childType
    end

    -- Returns true if t equals or extends base (same-or-subtype check).
    local function compatibleWith(t, base)
        return t == base or parsers.extendsOrRestrict(t, base)
    end

    -- For each parent with multiple children, check field consistency
    for parentType, childTypes in pairs(children) do
        if #childTypes > 1 then
            -- Collect all fields from all children (and their descendants)
            -- fieldName -> { typeName -> fieldType }
            local fieldsByName = {}

            for _, childType in ipairs(childTypes) do
                local fieldTypes = recordFieldTypes(childType)
                if fieldTypes then
                    for fieldName, fieldType in pairs(fieldTypes) do
                        if not fieldsByName[fieldName] then
                            fieldsByName[fieldName] = {}
                        end
                        fieldsByName[fieldName][childType] = fieldType
                    end
                end
            end

            -- Check for conflicts: same field name with different types
            local parentFieldTypes = recordFieldTypes(parentType)
            for fieldName, typeMap in pairs(fieldsByName) do
                local firstType = nil
                local firstTypeName = nil
                for typeName, fieldType in pairs(typeMap) do
                    if firstType == nil then
                        firstType = fieldType
                        firstTypeName = typeName
                    elseif firstType ~= fieldType then
                        -- Types differ. Allow it if this field comes from the parent and
                        -- each sibling's type is a valid subtype of the parent field type.
                        local parentFieldType = parentFieldTypes and parentFieldTypes[fieldName]
                        if not (parentFieldType
                            and compatibleWith(firstType, parentFieldType)
                            and compatibleWith(fieldType, parentFieldType)) then
                            -- Found a genuine conflict!
                            badVal.source_name = "type hierarchy"
                            badVal.line_no = 0
                            badVal(fieldName, "field has different types in sibling sub-types of '"
                                .. parentType .. "': " .. firstTypeName .. " has '" .. firstType
                                .. "' but " .. typeName .. " has '" .. fieldType .. "'")
                        end
                    end
                end
            end
        end
    end
end

-- Validates file join configurations
-- - No chained joins (secondary files joining into other secondary files)
-- - No circular dependencies
-- - Join targets must exist
-- @param lcFn2JoinInto table: Map of lowercase filename to join target
-- @param lcFileNames table: Map of lowercase filename to list of descriptor files
-- @param badVal table: Error reporting object
local function validateFileJoins(lcFn2JoinInto, lcFileNames, badVal)
    -- Check each file with a joinInto
    for lcfn, joinTarget in pairs(lcFn2JoinInto) do
        -- Check that join target exists
        if not lcFileNames[joinTarget] then
            badVal.source_name = "file joining"
            badVal.line_no = 0
            badVal(lcfn, "joinInto target '" .. joinTarget .. "' does not exist")
        end

        -- Check for chained joins (join target should not itself have a joinInto)
        if lcFn2JoinInto[joinTarget] then
            badVal.source_name = "file joining"
            badVal.line_no = 0
            badVal(lcfn, "chained joins not allowed: '" .. lcfn ..
                "' joins into '" .. joinTarget ..
                "' which joins into '" .. lcFn2JoinInto[joinTarget] .. "'")
        end
    end
end

-- Validates file and type names reuse
-- Files.tsv is exempt because every package is expected to have one
local function validateFileAndTypeNames(lcFileNames, lcTypeNames, log)
    log = log or logger
    for fn, fd in pairs(lcFileNames) do
        if #fd > 1 and fn ~= "files.tsv" then
            log:warn("Multiple files with name '" .. fn
                .. "' in " .. table.concat(fd, ", "))
        end
    end
    for tn, fd in pairs(lcTypeNames) do
        if #fd > 1 and tn ~= "files" then
            log:warn("Multiple types with name '" .. tn
                .. "' in " .. table.concat(fd, ", "))
        end
    end
end

-- Load all descriptor files, in the order of priority
local function loadDescriptorFiles(desc_files_order, prios, desc_file2mod_id,
    post_proc_files, extends, lcFn2Type, lcFn2Ctx, lcFn2Col,
    lcFn2JoinInto, lcFn2JoinColumn, lcFn2Export, lcFn2JoinedTypeName,
    lcFn2RowValidators, lcFn2FileValidators, lcFn2LineNo,
    raw_files, loadEnv, badVal)
    local desc_files = {}
    local max_prio = -math.huge
    local cur_mod = nil
    local fail = false
    local mod_files = {}
    local lcFileNames = {}
    local lcTypeNames = {}
    local log = badVal.logger
    local fn2Idx = {}

    -- Options object for processFilesDesc
    local opts = {
        prios = prios,
        prio_offset = 0,
        extends = extends,
        lcFileNames = lcFileNames,
        lcTypeNames = lcTypeNames,
        lcFn2Type = lcFn2Type,
        lcFn2Ctx = lcFn2Ctx,
        lcFn2Col = lcFn2Col,
        lcFn2JoinInto = lcFn2JoinInto,
        lcFn2JoinColumn = lcFn2JoinColumn,
        lcFn2Export = lcFn2Export,
        lcFn2JoinedTypeName = lcFn2JoinedTypeName,
        lcFn2RowValidators = lcFn2RowValidators,
        lcFn2FileValidators = lcFn2FileValidators,
        lcFn2LineNo = lcFn2LineNo,
        fn2Idx = fn2Idx,
        log = log,
    }

    for _, file_name in ipairs(desc_files_order) do
        local file = loadDescriptorFile(file_name, raw_files, loadEnv, badVal)
        if file then
            local file_mod = desc_file2mod_id[file_name]
            if cur_mod ~= file_mod then
                reprocessFilesDesc(mod_files, post_proc_files,
                    extends, log, fn2Idx)
                clearSeq(mod_files)
                if cur_mod then
                    opts.prio_offset = max_prio + 1
                end
                max_prio = -math.huge
                cur_mod = file_mod
            end
            desc_files[#desc_files+1] = file
            max_prio = processFilesDesc(file_name, file, max_prio, opts)
            mod_files[#mod_files+1] = file
        else
            fail = true
        end
    end
    if #mod_files > 0 then
        reprocessFilesDesc(mod_files, post_proc_files,
            extends, log, fn2Idx)
    end
    validateFileAndTypeNames(lcFileNames, lcTypeNames, log)
    validateSiblingFieldTypes(extends, lcTypeNames, badVal)
    validateFileJoins(lcFn2JoinInto, lcFileNames, badVal)
    if fail then
        return nil
    end
    return desc_files
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    extractFilesDescriptors = extractFilesDescriptors,
    getVersion = getVersion,
    isFilesDescriptor = isFilesDescriptor,
    matchDescriptorFiles = matchDescriptorFiles,
    orderFilesDescByPackageOrder = orderFilesDescByPackageOrder,
    loadDescriptorFile = loadDescriptorFile,
    loadDescriptorFiles = loadDescriptorFiles,
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
