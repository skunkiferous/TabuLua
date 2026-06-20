-- Module name
local NAME = "files_desc"

-- Module logger
local logger = require( "infra.named_logger").getLogger(NAME)

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 29, 0)

-- Returns the module version
local function getVersion()
    return tostring(VERSION)
end

-- The type-wiring registry owns two things relevant to files_desc:
--   * hasOnLoad — drives detectPostProcessingNeeded (replaces the former
--     POST_PROCESS_PARENTS hard-coded table).
--   * descriptorColumnsByName — the union of optional Files.tsv columns
--     contributed by feature modules. After the L4 shrink, only the
--     six intrinsic core columns are hard-coded below; everything else
--     comes through the registry.
-- builtin_wiring.lua does the registrations at module load time.
local type_wiring = require("wiring.type_wiring")
require("wiring.builtin_wiring")
local hasOnLoad = type_wiring.hasOnLoad
local descriptorColumnsByName = type_wiring.descriptorColumnsByName

local read_only = require("util.read_only")
local readOnly = read_only.readOnly
local table_utils = require("util.table_utils")
local filterSeq = table_utils.filterSeq
local longestMatchingPrefix = table_utils.longestMatchingPrefix
local appendSeq = table_utils.appendSeq
local clearSeq = table_utils.clearSeq

local file_util = require("infra.file_util")
local getParentPath = file_util.getParentPath
local sortFilesBreadthFirst = file_util.sortFilesBreadthFirst

-- The content pipeline owns the read→COG sequence (see content_pipeline.md §5);
-- requiring builtin_content_stages registers COG as the `macro` stage.
local content_pipeline = require("content.content_pipeline")
require("content.builtin_content_stages")

local raw_tsv = require("tsv.raw_tsv")
local stringToRawTSV = raw_tsv.stringToRawTSV

local tsv_model = require("tsv.tsv_model")
local processTSV = tsv_model.processTSV
local TRANSPOSED_TSV_EXT = tsv_model.TRANSPOSED_TSV_EXT

local parsers = require("parsers")
local parseType = parsers.parseType
local recordFieldTypes = parsers.recordFieldTypes

-- File containing priorities/load-order, in lowercase
local FILES_DESC = "files.tsv"

-- The six intrinsic core columns. Any other column header recognised by
-- this module flows in through the type-wiring registry's
-- descriptorColumns() declarations (see builtin_wiring.lua). The core
-- six are hard-coded because the cascade dispatcher itself depends on
-- typeName / superType / baseType, and the load loop depends on
-- fileName / loadOrder; moving them through the registry would create
-- a bootstrap cycle.
local CORE_COLUMNS_BY_HEADER = {
    ["fileName:filepath"]    = "fileName",
    ["typeName:type_spec"]   = "typeName",
    ["superType:super_type"] = "superType",
    ["baseType:boolean"]     = "baseType",
    ["loadOrder:number"]     = "loadOrder",
    ["description:text"]     = "description",
}

-- The five core columns whose absence is a configuration error worth
-- warning about. `description` is pure user metadata so its absence is
-- harmless.
local REQUIRED_CORE_COLUMNS = {
    "fileName", "typeName", "superType", "baseType", "loadOrder",
}

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
        -- The pipeline reads the file, stores the normalised pre-COG source in
        -- raw_files, and runs COG (the registered `macro` stage).
        local content = content_pipeline.readAndRun(file, loadEnv, badVal, raw_files)
        if not content then
            return nil, "File " .. file .. " could not be read"
        end
        local rawtsv = stringToRawTSV(content)
        return processTSV(tsv_model.defaultOptionsExtractor, ldfExprEval, ldfParserFinder,
            file, rawtsv, badVal, nil, false)
    end

    return result
end

-- Loads a file descriptor as TSV
local loadDescriptorFile = genLoadDescriptorFile()

-- Parse a Files.tsv header into an `{[colName] = idx}` map. The six core
-- columns are recognised by their exact "name:type" header strings; every
-- other column is matched against the type-wiring descriptorColumns()
-- declarations. Unrecognised headers produce a "Column ignored" warning,
-- preserving the prior behaviour.
local function parseFilesDescHeader(file_name, file, log)
    local header = file[1]
    local indicesByName = {}
    local optCols = descriptorColumnsByName()
    -- Build a header-string lookup for registry columns: "name:type" -> decl.
    local optByHeader = {}
    for _, decl in pairs(optCols) do
        optByHeader[decl.name .. ":" .. decl.type] = decl
    end
    for idx, col in ipairs(header) do
        local colStr = tostring(col)
        local coreName = CORE_COLUMNS_BY_HEADER[colStr]
        if coreName then
            indicesByName[coreName] = idx
        else
            local decl = optByHeader[colStr]
            if decl then
                indicesByName[decl.name] = idx
            else
                logger:warn("Column ignored: " .. colStr)
            end
        end
    end
    -- Warn (don't error) about missing required core columns. publishContext
    -- and publishColumn previously also warned on absence — those moved to
    -- the registry and are now properly optional (no warning).
    for _, name in ipairs(REQUIRED_CORE_COLUMNS) do
        if indicesByName[name] == nil then
            log = log or logger
            log:warn("Missing column '" .. name .. "' in " .. file_name)
        end
    end
    return indicesByName
end

-- Check the file name matches the type name
local function checkTypeName(extends, fileDesc, fileName, typeName, superType, log)
    if typeName then
        log = log or logger
        local idx = fileName:find("/[^/]*$")
        local fileNameWithoutPath = (idx and fileName:sub(idx + 1)) or fileName
        -- Peel any decode-extension layers (e.g. a gzip-compressed data file
        -- 'Constant.tsv.gz' -> 'Constant.tsv') so the typeName check compares
        -- against the effective data file name, not the compression wrapper.
        fileNameWithoutPath = content_pipeline.peeledName(fileNameWithoutPath)
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
-- @field lcFn2LineNo table: Map of lowercase filename to line number in descriptor file
-- @field fn2Idx table: Map of descriptor file to column indices
-- @field log logger: Logger instance
-- In addition, opts carries one map per registered descriptor column, keyed by
-- the column's `fieldOnMeta` (e.g. lcFn2JoinInto, lcFn2RowValidators). These are
-- copied in from `metaMaps` (see loadDescriptorFiles) so the row loop can reach
-- a column's target via opts[decl.fieldOnMeta] without naming any column here.

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
    -- Optional-column joinMeta-shaped maps are accessed via the per-column
    -- `fieldOnMeta` declarations (looked up below); no need to alias them
    -- here. Core-column maps stay aliased for the load loop.
    local lcFn2LineNo = opts.lcFn2LineNo
    local fn2Idx = opts.fn2Idx
    local log = opts.log
    local variants = opts.variants
    local lcSkippedFiles = opts.lcSkippedFiles

    local indicesByName = parseFilesDescHeader(file_name, file, log)
    fn2Idx[file_name] = indicesByName

    local fileNameIdx  = indicesByName.fileName
    local typeNameIdx  = indicesByName.typeName
    local superTypeIdx = indicesByName.superType
    local baseTypeIdx  = indicesByName.baseType
    local loadOrderIdx = indicesByName.loadOrder
    local variantIdx   = indicesByName.variant

    -- Registered optional columns the loader will populate into joinMeta.
    -- The per-column `parse` function (when set) normalises the raw cell
    -- value before storage; a nil result means "treat as absent".
    local optColumnDecls = descriptorColumnsByName()

    -- Resolve target maps once per file: the loader's `opts` table holds
    -- one joinMeta-shaped map per column.fieldOnMeta. A nil target means
    -- the loader didn't pre-allocate a map for that column (in practice
    -- every registered column has one, but we guard anyway).
    local columnPlan = {}
    for colName, decl in pairs(optColumnDecls) do
        local idx = indicesByName[colName]
        if idx then
            columnPlan[#columnPlan + 1] = {
                idx = idx,
                target = opts[decl.fieldOnMeta],
                parse = decl.parse,
            }
        end
    end

    if fileNameIdx and loadOrderIdx then
        for i, row in ipairs(file) do
            -- Ignore empty rows and header
            if i > 1 and type(row) == "table" then
                local fn = row[fileNameIdx].parsed
                local lcfn = fn:lower()
                -- Variant filtering: rows with a non-empty variant tag are
                -- only active when that variant is explicitly selected.
                if variantIdx then
                    local variantVal = row[variantIdx] and row[variantIdx].parsed
                    if variantVal and variantVal ~= '' then
                        if not variants or not variants[variantVal] then
                            if lcSkippedFiles then
                                lcSkippedFiles[lcfn] = true
                            end
                            goto continue
                        end
                    end
                end
                local prio = tonumber(row[loadOrderIdx].parsed) or 0
                local tn = typeNameIdx and row[typeNameIdx].parsed
                local st = superTypeIdx and row[superTypeIdx].parsed
                local bt = baseTypeIdx and tostring(row[baseTypeIdx].parsed)

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

                -- Apply the registered descriptor columns. Each column's
                -- `parse` function (when set) normalises the raw value; a
                -- non-nil result is stored into joinMeta[col.fieldOnMeta][lcfn].
                for _, plan in ipairs(columnPlan) do
                    local target = plan.target
                    if target ~= nil then
                        local cell = row[plan.idx]
                        local raw = cell and cell.parsed
                        local stored = plan.parse and plan.parse(raw) or raw
                        if stored ~= nil and stored ~= '' then
                            target[lcfn] = stored
                        end
                    end
                end
                ::continue::
            end
        end
    end
    return max_prio
end

-- Detect post processing needed. Delegates to the type-wiring registry:
-- if any ancestor in typeName's extends chain has a registered onLoad,
-- the file needs a second descriptor pass so the onLoad's registrations
-- are visible to siblings.
local function detectPostProcessingNeeded(extends, post_proc_files, file_name, typeName, log)
    log = log or logger
    if typeName and #typeName > 0 and hasOnLoad(typeName, extends) then
        post_proc_files[file_name] = typeName
        log:info("Found wired file (typeName=" .. typeName .. "): " .. file_name)
    end
end

-- Reprocess all files of one mod, after first processing
local function reprocessFilesDesc(mod_files, post_proc_files, extends, log, fn2Idx)
    for _, file in ipairs(mod_files) do
        local indices = fn2Idx[file[1].__source]
        local fileNameIdx = indices.fileName
        local typeNameIdx = indices.typeName
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

-- Sets badVal fields for file join validation errors
-- @param badVal table: Error reporting object
-- @param lcfn string: Lowercase filename being validated
-- @param lcFileNames table: Map of lowercase filename to list of descriptor files
-- @param lcFn2LineNo table: Map of lowercase filename to line number in descriptor file
-- @param fn2Idx table: Map of descriptor file to column indices
local function setBadValForJoin(badVal, lcfn, lcFileNames, lcFn2LineNo, fn2Idx)
    local descriptorFiles = lcFileNames[lcfn]
    local descriptorFile = descriptorFiles and descriptorFiles[1]
    badVal.source_name = descriptorFile or "file joining"
    badVal.line_no = lcFn2LineNo[lcfn] or 0
    badVal.row_key = ""
    badVal.col_name = "joinInto"
    local indices = descriptorFile and fn2Idx[descriptorFile]
    badVal.col_idx = (indices and indices.joinInto) or 0
    badVal.col_types = {}
end

-- Validates that all joinInto targets exist in lcFileNames (exact full-path match).
-- @param lcFn2JoinInto table: Map of lowercase filename to join target
-- @param lcFileNames table: Map of lowercase filename to list of descriptor files
-- @param badVal table: Error reporting object
-- @param lcFn2LineNo table: Map of lowercase filename to line number in descriptor file
-- @param fn2Idx table: Map of descriptor file to column indices
local function validateJoinTargetsExist(lcFn2JoinInto, lcFileNames, badVal, lcFn2LineNo, fn2Idx)
    for lcfn, joinTarget in pairs(lcFn2JoinInto) do
        if not lcFileNames[joinTarget] then
            setBadValForJoin(badVal, lcfn, lcFileNames, lcFn2LineNo, fn2Idx)
            badVal(lcfn, "joinInto target '" .. joinTarget
                .. "' does not exist (must be the full path as listed in fileName)")
        end
    end
end

-- Validates file join configurations (called after resolveJoinTargets)
-- - No chained joins (secondary files joining into other secondary files)
-- @param lcFn2JoinInto table: Map of lowercase filename to resolved join target
-- @param lcFileNames table: Map of lowercase filename to list of descriptor files
-- @param badVal table: Error reporting object
-- @param lcFn2LineNo table: Map of lowercase filename to line number in descriptor file
-- @param fn2Idx table: Map of descriptor file to column indices
local function validateFileJoins(lcFn2JoinInto, lcFileNames, badVal, lcFn2LineNo, fn2Idx)
    for lcfn, joinTarget in pairs(lcFn2JoinInto) do
        -- Check for chained joins (join target should not itself have a joinInto)
        if lcFn2JoinInto[joinTarget] then
            setBadValForJoin(badVal, lcfn, lcFileNames, lcFn2LineNo, fn2Idx)
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

-- Load all descriptor files, in the order of priority.
--
-- `metaMaps` is a single table that owns every registered descriptor-column
-- map, keyed by the column's `fieldOnMeta` (e.g. metaMaps.lcFn2JoinInto). The
-- loader auto-creates one empty map per registered column before the load
-- loop, so a caller can pass an empty table and read the populated maps back
-- afterwards. Core/derived maps (`lcFn2Type`, `lcFn2LineNo`, `extends`,
-- `post_proc_files`) stay explicit because they are not registered columns.
-- This signature is internal: the only in-tree callers are manifest_loader
-- and the files_desc specs.
local function loadDescriptorFiles(desc_files_order, prios, desc_file2mod_id,
    post_proc_files, extends, lcFn2Type, lcFn2LineNo, metaMaps,
    raw_files, loadEnv, badVal, variants, lcSkippedFiles)
    local desc_files = {}
    local max_prio = -math.huge
    local cur_mod = nil
    local fail = false
    local mod_files = {}
    local lcFileNames = {}
    local lcTypeNames = {}
    local log = badVal.logger
    local fn2Idx = {}

    -- Drive the map lifecycle from the registry: one empty map per registered
    -- descriptor column. The row loop reads its target via opts[fieldOnMeta]
    -- (see processFilesDesc), so every registered column needs a pre-allocated
    -- map whether or not this particular Files.tsv uses it.
    for _, decl in pairs(descriptorColumnsByName()) do
        metaMaps[decl.fieldOnMeta] = metaMaps[decl.fieldOnMeta] or {}
    end

    -- Options object for processFilesDesc. Core/derived maps are set
    -- explicitly; the registered descriptor-column maps are pulled from
    -- metaMaps so adding a feature column needs no edit here.
    local opts = {
        prios = prios,
        prio_offset = 0,
        extends = extends,
        lcFileNames = lcFileNames,
        lcTypeNames = lcTypeNames,
        lcFn2Type = lcFn2Type,
        lcFn2LineNo = lcFn2LineNo,
        fn2Idx = fn2Idx,
        log = log,
        variants = variants,
        lcSkippedFiles = lcSkippedFiles,
    }
    for field, map in pairs(metaMaps) do
        opts[field] = map
    end

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
    validateJoinTargetsExist(metaMaps.lcFn2JoinInto, lcFileNames, badVal, lcFn2LineNo, fn2Idx)
    validateFileJoins(metaMaps.lcFn2JoinInto, lcFileNames, badVal, lcFn2LineNo, fn2Idx)
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
