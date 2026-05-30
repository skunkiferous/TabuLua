-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 21, 0)

-- Module name
local NAME = "manifest_loader"

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

local logger = require( "named_logger").getLogger(NAME)

local table_utils = require("table_utils")
local filterSeq = table_utils.filterSeq
local keys = table_utils.keys
local error_reporting = require("error_reporting")
local badValGen = error_reporting.badValGen
local nullBadVal = error_reporting.nullBadVal
local read_only = require("read_only")
local readOnly = read_only.readOnly

local file_util = require("file_util")
local collectFiles = file_util.collectFiles
local hasExtension = file_util.hasExtension
local normalizePath = file_util.normalizePath

local tsv_model = require("tsv_model")
local processTSV = tsv_model.processTSV

local sandbox_env = require("sandbox_env")

local raw_tsv = require("raw_tsv")
local stringToRawTSV = raw_tsv.stringToRawTSV

local parsers = require("parsers")
local parseType = parsers.parseType

local manifest_info = require("manifest_info")
local isManifestFile = manifest_info.isManifestFile
local resolveDependencies = manifest_info.resolveDependencies
local runPackageBootstraps = manifest_info.runPackageBootstraps
local validateVariantGroups = manifest_info.validateVariantGroups

local files_desc = require("files_desc")
local extractFilesDescriptors = files_desc.extractFilesDescriptors
local matchDescriptorFiles = files_desc.matchDescriptorFiles
local orderFilesDescByPackageOrder = files_desc.orderFilesDescByPackageOrder
local loadDescriptorFiles = files_desc.loadDescriptorFiles
local isFilesDescriptor = files_desc.isFilesDescriptor

local validator_executor = require("validator_executor")
local runRowValidators = validator_executor.runRowValidators
local runFileValidators = validator_executor.runFileValidators
local runPackageValidators = validator_executor.runPackageValidators

local processor_executor = require("processor_executor")
local runFilePreProcessors = processor_executor.runFilePreProcessors

-- The type-wiring registry replaces the three hand-written branches that
-- previously dispatched Type / enum / custom_type_def behaviour from the
-- per-file load loop. builtin_wiring.lua registers the three onLoad
-- handlers; the dispatcher walks the file's extends chain and fires them.
local type_wiring = require("type_wiring")
local applyTypeWiring = type_wiring.applyWiring
local hasOnLoadFor = type_wiring.hasOnLoadFor
local hasOnLoad = type_wiring.hasOnLoad
require("builtin_wiring")

-- The content-pipeline registry owns the read→decode→transcode→normalise→COG
-- sequence that the three load call sites used to hand-roll (see
-- TODO/content_pipeline.md §2, §5). builtin_content_stages registers COG (the
-- `macro` stage) and the core EOL-normalise stage; requiring it here triggers
-- that registration, exactly as `require("builtin_wiring")` does above.
local content_pipeline = require("content_pipeline")
require("builtin_content_stages")
local unixEOL = file_util.unixEOL
local readFileBinary = file_util.readFileBinary
local getFileSize = file_util.getFileSize

-- CSV file extension
local CSV = "csv"

-- TSV file extension
local TSV = "tsv"

-- Supported text formats (manifest files use .transposed.tsv which is covered by TSV)
local EXTENSIONS = {TSV, CSV, "txt", "md", "json", "xml", "lua"}

-- Find the priority of the file
local function findPriority(priorities, file, missingPriority)
    local lfile = file:lower()
    local matches = {}
    for f,p in pairs(priorities) do
        if lfile:sub(-#f) == f then
            matches[#matches+1] = f
        end
    end
    if #matches == 0 then
        -- "Priority-defining-files" has priority 0, so anything else should be higher
        missingPriority[file] = true
        return 1
    end
    local m, l = nil, 0
    for _,f in ipairs(matches) do
        if #f > l then
            l = #f
            m = f
        end
    end
    return priorities[m]
end

-- Order files by priority
local function orderFilesByPriorities(files, priorities)
    logger:info("Sorting files by priority ...")
    local missingPriority = {}
    local cache = {}
    for _,file in ipairs(files) do
        cache[file] = findPriority(priorities, file, missingPriority)
    end
    table.sort(files, function(a, b)
        local aPriority = cache[a]
        local bPriority = cache[b]
        if aPriority == bPriority then
            return a:lower() < b:lower()
        end
        return aPriority < bPriority
    end)
    for _,file in ipairs(keys(missingPriority)) do
        if not hasExtension(file, "lua") then
            if hasExtension(file, "md") then
                logger:debug("No priority found for " .. file)
            else
                logger:warn("No priority found for " .. file)
            end
        end
    end
    logger:debug("Sorted files: "..table.concat(files, ", "))
end

-- Finds, and removes, the manifest files that define the package dependencies
local function extractManifestFiles(files)
    return filterSeq(files, isManifestFile)
end

-- Register a record type for a TSV file based on its column structure.
-- When 'extends' is provided and the fileType has a parent with a registered record type,
-- validates that each child field type is same-or-subtype of the corresponding parent field.
-- Files whose typeName transitively extends Type or enum are skipped because the
-- corresponding wired onLoad has already registered the record-type/parser for them.
local function registerFileType(fileRegisteredTypes, file, fileType, extends, badVal)
    if not fileType or #fileType == 0 then
        return  -- No type name specified
    end
    if hasOnLoadFor(fileType, extends, "Type")
        or hasOnLoadFor(fileType, extends, "enum") then
        return  -- Type/enum definitions are handled by their wired onLoad.
    end
    -- Skip if this type is already parseable (built-in alias or previously registered).
    -- This avoids conflicts when a file uses typeName=custom_type_def directly, whose
    -- column subset would differ from the full built-in record definition.
    if parseType(nullBadVal, fileType, false) then
        return
    end

    local header = file[1]
    -- __type_spec is accessible via __index on the read-only proxy
    local typeSpec = header.__type_spec

    if typeSpec and typeSpec ~= "{}" then
        if not parsers.registerAlias(badVal, fileType, typeSpec) then
            logger:warn("Failed to register type " .. fileType .. " = " .. typeSpec)
        else
            logger:info("Registered type: " .. fileType .. " = " .. typeSpec)
            fileRegisteredTypes[fileType] = true
            -- Validate child fields against parent record type (if parent is a record).
            -- Only validate against parents that were also registered by registerFileType
            -- (not pre-existing/built-in types whose fields are intentionally broad).
            local parentType = extends and extends[fileType]
            if parentType and fileRegisteredTypes[parentType] then
                local parentFields = parsers.recordFieldTypes(parentType)
                if parentFields then
                    local childFields = parsers.recordFieldTypes(fileType)
                    if childFields then
                        for field, parentFieldType in pairs(parentFields) do
                            local childFieldType = childFields[field]
                            if childFieldType and childFieldType ~= parentFieldType then
                                if not parsers.extendsOrRestrict(childFieldType, parentFieldType) then
                                    badVal(field, "field type '" .. childFieldType
                                        .. "' in " .. fileType
                                        .. " is not a subtype of '" .. parentFieldType
                                        .. "' from parent type " .. parentType)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Builds the table subscribers. The context that the subscribers should use is stored under
-- contexts[1]. The name of the context that the subscribers should use is stored under
-- contexts[2]. The default context(loadEnv) is stored under contexts['']
local function buildTableSubscribers(contexts, lcFNKey, lcFn2Ctx, lcFn2Col)
    local table_subscribers = nil
    local publishContext = lcFn2Ctx[lcFNKey]
    local publishColumn = lcFn2Col[lcFNKey]
    if publishContext or publishColumn then
        -- Are we storing values in a specific context?
        if publishContext then
            local context = contexts[publishContext]
            if context == nil then
                logger:info("Creating context " .. publishContext.." for expressions evaluation")
                context = {}
                contexts[publishContext] = context
                contexts[''][publishContext] = context
            end
            contexts[1] = context
            contexts[2] = publishContext
        else
            contexts[1] = contexts[''] -- loadEnv is the default environment
            contexts[2] = ''
        end
        -- Are we only storing the value of a specific column?
        if publishColumn then
            local addColToContext = contexts[true]
            if addColToContext == nil then
                addColToContext = function (col, row, cell)
                    local context_key = row[1]
                    local context_value = cell.parsed
                    contexts[1][context_key] = context_value
                    local ctx = "global"
                    if contexts[2] ~= '' then
                        ctx = contexts[2]
                    end
                    logger:info("Registering "..ctx.." 'constant' " .. context_key .. ": " ..
                        tostring(context_value))
                end
                contexts[true] = addColToContext
            end
            table_subscribers = {[publishColumn]=addColToContext}
        else
            local addRowToContext = contexts[false]
            if addRowToContext == nil then
                addRowToContext = function (col, row, cell)
                    if row[1] then
                        local context_key = row[1]
                        contexts[1][context_key] = row
                    end
                end
                contexts[false] = addRowToContext
            end
            table_subscribers = addRowToContext
        end
    end
    return table_subscribers
end

-- Logs the file being processed. Type/enum/custom_type_def files are reported
-- as "wired" with their typeName so future wired families (graph nodes, etc.)
-- don't need a new branch here.
local function logFile(file_name, fileType, extends, table_subscribers)
    if fileType and hasOnLoad(fileType, extends) then
        logger:info("Processing wired file (typeName=" .. fileType .. "): " .. file_name)
    elseif type(table_subscribers) == "table" then
        logger:info("Processing constants file: " .. file_name)
    else
        logger:info("Processing ordinary file:" .. file_name)
    end
end

-- Sets up the load environment with expression evaluator and contexts
-- Note: loadEnv must already have its {__index = sandbox_env.cogGlobals()}
-- metatable set at creation time (see processFiles).
local function setupLoadEnvironment(loadEnv)
    local expr_eval = tsv_model.expressionEvaluatorGenerator(loadEnv)
    local contexts = {}
    contexts[''] = loadEnv -- loadEnv is the default environment
    local options_extractor = tsv_model.defaultOptionsExtractor
    return expr_eval, contexts, options_extractor
end

-- Computes the lowercase file name key relative to its directory
local function computeFilenameKey(file_name, file2dir)
    local dir = normalizePath(file2dir[file_name]) or ""
    local nfile = normalizePath(file_name) or file_name
    -- When directory is "." (CWD), normalizePath strips any leading "./" from the
    -- file name, so the key is simply the normalized relative path.
    if dir == "." or dir == "" then
        return nfile:lower()
    end
    local prefix = dir .. "/"
    if nfile:sub(1, #prefix) == prefix then
        return nfile:sub(#prefix + 1):lower()
    end
    return nfile:lower()
end

-- Checks if a raw TSV structure looks like a migration script.
-- Migration scripts have a header row with columns: command, p1, p2, p3, ...
-- Column names may include type suffixes (e.g., command:string, p1:string).
-- Returns true if the header matches the migration script pattern.
local function isMigrationScript(rawtsv)
    -- Find the first data row (non-comment, non-blank)
    for _, line in ipairs(rawtsv) do
        if type(line) == "table" then
            -- Need at least 2 columns (command + p1)
            if #line < 2 then
                return false
            end
            -- Extract column name without type suffix
            local col1 = tostring(line[1]):match("^([^:]+)")
            if col1 ~= "command" then
                return false
            end
            -- Check that remaining columns are p1, p2, p3, ... in order
            for i = 2, #line do
                local colName = tostring(line[i]):match("^([^:]+)")
                if colName ~= ("p" .. (i - 1)) then
                    return false
                end
            end
            return true
        end
    end
    return false
end

-- Ensures `map[key]` is a populated array, creating an empty one if missing.
-- Returns the array. Used to give type_wiring.applyWiring writable targets
-- for the per-file processor / validator wiring contributions.
local function ensureList(map, key)
    local list = map[key]
    if list == nil then
        list = {}
        map[key] = list
    end
    return list
end

-- Processes a single TSV/CSV file: reads, parses, and dispatches any
-- type-wiring contributions whose registered typeName appears in this
-- file's extends chain (replaces the former Type/enum/custom_type_def
-- branches and the post-load applyGraphAutoWiring pass).
local function processSingleTSVFile(fileRegisteredTypes, file_name, file2dir, contexts,
    lcFn2Type, lcFn2Ctx, lcFn2Col,
    lcFn2PreProcessors, lcFn2RowValidators, lcFn2FileValidators,
    extends, raw_files, files_cache,
    options_extractor, expr_eval, loadEnv, badVal)
    badVal.source = file_name
    -- The content pipeline reads the file (binary), populates raw_files with the
    -- normalised pre-COG source, and runs the decode→transcode→normalise→COG
    -- stages. COG is no longer named here — it is the registered `macro` stage.
    local content = content_pipeline.readAndRun(file_name, loadEnv, badVal, raw_files)
    if not content then
        return
    end
    local rawtsv = stringToRawTSV(content)

    if isMigrationScript(rawtsv) then
        logger:warn("Skipping migration script: " .. file_name)
        raw_files[file_name] = nil
        return
    end

    local lcFNKey = computeFilenameKey(file_name, file2dir)
    local table_subscribers = buildTableSubscribers(contexts, lcFNKey, lcFn2Ctx, lcFn2Col)

    local fileType = lcFn2Type[lcFNKey]
    logFile(file_name, fileType, extends, table_subscribers)

    -- Look up parent file's header for inheriting column defaults
    local parent_header = nil
    if fileType and extends[fileType] then
        local parent_file = loadEnv.files[extends[fileType]]
        if parent_file then
            parent_header = parent_file[1]
        end
    end

    local file = processTSV(options_extractor, expr_eval, parseType,
        file_name, rawtsv, badVal, table_subscribers, false, parent_header)
    badVal.line_no = 0
    badVal.row_key = ""
    files_cache[file_name] = file

    if file then
        if fileType then
            loadEnv.files[fileType] = file
        end
        -- Dispatch type-wiring contributions for this file: fires registered
        -- onLoad handlers AND accumulates per-file preProcessors / row+file
        -- validators into the joinMeta maps. The maps are mutated in place;
        -- ensureList creates an empty list the first time a file gets a
        -- wired entry.
        applyTypeWiring(fileType, extends, {
            file = file, badVal = badVal, loadEnv = loadEnv,
            preProcessors  = ensureList(lcFn2PreProcessors,  lcFNKey),
            rowValidators  = ensureList(lcFn2RowValidators,  lcFNKey),
            fileValidators = ensureList(lcFn2FileValidators, lcFNKey),
        })
        -- Register the file's column structure as a type (skipped for Type/enum
        -- descendants — those are handled by their wired onLoad above).
        registerFileType(fileRegisteredTypes, file, fileType, extends, badVal)
    end
end

-- Stores a not-yet-parsed file in raw_files for verbatim / streamed export.
-- Text files (per the content-pipeline extension table) are read in binary and
-- EOL-normalised to a string — matching what the old text-mode read produced.
-- Binary files no stage needs are NOT loaded: they get an O(1) passthrough
-- descriptor (a stat, not a read) and are block-streamed at export time, so a
-- multi-hundred-MB asset never sits in memory (§3.5 "Large binary files").
-- opt_badVal, if given, reports read/stat failures.
local function storeRawFile(file_name, raw_files, opt_badVal)
    if content_pipeline.isTextFile(file_name) then
        local content, err = readFileBinary(file_name)
        if content then
            raw_files[file_name] = unixEOL(content)
        elseif opt_badVal then
            opt_badVal(nil, "File could not be read: " .. tostring(err))
        end
    else
        local size, err = getFileSize(file_name)
        if size then
            raw_files[file_name] = {
                __passthrough = true,
                kind = "binary",
                sourcePath = file_name,
                size = size,
            }
        elseif opt_badVal then
            opt_badVal(nil, "File could not be stat'd: " .. tostring(err))
        end
    end
end

-- Reads a non-TSV/CSV file and stores its content (or a passthrough descriptor).
local function processUnknownFile(file_name, raw_files, badVal)
    if hasExtension(file_name, "lua") then
        logger:info("Loading code library: " .. file_name)
    elseif hasExtension(file_name, "md") then
        logger:debug("Don't know how to process " .. file_name)
    else
        logger:warn("Don't know how to process " .. file_name)
    end
    storeRawFile(file_name, raw_files, badVal)
end

-- Load all the non-description files
local function loadOtherFiles(files, files_cache, file2dir, lcFn2Type, lcFn2Ctx, lcFn2Col,
    lcFn2PreProcessors, lcFn2RowValidators, lcFn2FileValidators,
    extends, raw_files, loadEnv, badVal, lcSkippedFiles)
    local expr_eval, contexts, options_extractor = setupLoadEnvironment(loadEnv)

    -- Tracks types registered by registerFileType (as opposed to pre-existing/built-in types).
    -- Used to limit parent-child field validation to user-defined file record types only.
    local fileRegisteredTypes = {}
    for _, file_name in ipairs(files) do
        -- Skip files that were filtered out by variant selection
        if lcSkippedFiles and next(lcSkippedFiles) then
            local key = computeFilenameKey(file_name, file2dir)
            if lcSkippedFiles[key] then
                goto continue
            end
        end
        if hasExtension(file_name, CSV) or hasExtension(file_name, TSV) then
            processSingleTSVFile(fileRegisteredTypes, file_name, file2dir, contexts,
                lcFn2Type, lcFn2Ctx, lcFn2Col,
                lcFn2PreProcessors, lcFn2RowValidators, lcFn2FileValidators,
                extends, raw_files, files_cache,
                options_extractor, expr_eval, loadEnv, badVal)
        else
            processUnknownFile(file_name, raw_files, badVal)
        end
        ::continue::
    end
end

-- Process files once the order has been established.
-- Returns the TSV files and join metadata.
local function processOrderedFiles(badVal, files, file2dir, desc_files_order, desc_file2pkg_id,
    raw_files, loadEnv, opt_variants)
    local priorities = {}
    local post_proc_files = {}
    local extends = {}
    local lcFn2Type = {}
    local lcFn2Ctx = {}
    local lcFn2Col = {}
    -- File joining metadata
    local lcFn2JoinInto = {}
    local lcFn2JoinColumn = {}
    local lcFn2Export = {}
    local lcFn2JoinedTypeName = {}
    -- Validator maps
    local lcFn2RowValidators = {}
    local lcFn2FileValidators = {}
    -- Pre-processor map
    local lcFn2PreProcessors = {}
    -- Graph edge-file map: lcfn of edge file -> lcfn of its target node file
    local lcFn2EdgesFor = {}
    local lcFn2LineNo = {}
    -- Variant filtering: convert array to set if needed, collect skipped files
    local variantsSet = nil
    if opt_variants then
        variantsSet = {}
        for _, v in ipairs(opt_variants) do
            variantsSet[v] = true
        end
    end
    local lcSkippedFiles = {}
    local desc_files = loadDescriptorFiles(desc_files_order, priorities, desc_file2pkg_id,
        post_proc_files, extends, lcFn2Type, lcFn2Ctx, lcFn2Col,
        lcFn2JoinInto, lcFn2JoinColumn, lcFn2Export, lcFn2JoinedTypeName,
        lcFn2RowValidators, lcFn2FileValidators, lcFn2PreProcessors, lcFn2LineNo,
        raw_files, loadEnv, badVal, variantsSet, lcSkippedFiles, lcFn2EdgesFor)
    if not desc_files then
        logger:error("Could not load/process files descriptors. Aborting.")
        return
    end
    -- Note: the type-wiring registry replaces the former typesSet / enumsSet /
    -- customTypesSet precomputation. Each wired onLoad fires from the per-file
    -- load loop via type_wiring.applyWiring, walking the file's extends chain.

    -- Phase 3b of TODO/type_wiring.md: any user "wiring files" — files
    -- whose typeName extends the built-in `type_wiring_def` — fire their
    -- onLoad during the regular per-file load loop below, just like Type
    -- / enum / custom_type_def files. No special-case file discovery.

    -- Check that files referenced in Files.tsv actually exist on disk
    local filesOnDisk = {}
    -- Also build a reverse map: lowercased basename -> list of relative keys on disk
    local basenameToKeys = {}
    for _, file_name in ipairs(files) do
        local key = computeFilenameKey(file_name, file2dir)
        filesOnDisk[key] = true
        local basename = key:match("[/\\]([^/\\]+)$") or key
        if not basenameToKeys[basename] then
            basenameToKeys[basename] = {}
        end
        basenameToKeys[basename][#basenameToKeys[basename] + 1] = key
    end
    for lcfn, _ in pairs(lcFn2Type) do
        if not filesOnDisk[lcfn] and not isFilesDescriptor(lcfn) and not lcSkippedFiles[lcfn] then
            badVal.source_name = "Files.tsv"
            badVal.line_no = lcFn2LineNo[lcfn] or 0
            badVal.row_key = ""
            badVal.col_name = ""
            badVal.col_idx = 0
            badVal.col_types = {}
            -- Check if a file with the same basename exists elsewhere
            local basename = lcfn:match("[/\\]([^/\\]+)$") or lcfn
            local candidates = basenameToKeys[basename]
            if candidates and #candidates > 0 then
                badVal(lcfn, "file listed in Files.tsv was not found at the expected path; " ..
                    "a file with that name exists at: " .. table.concat(candidates, ", ") ..
                    " -- check if it is in the wrong directory")
            else
                badVal(lcfn, "file listed in Files.tsv does not exist on disk")
            end
        end
    end
    -- Remove variant-skipped files before sorting, so they don't trigger
    -- spurious "No priority found" warnings
    if next(lcSkippedFiles) then
        local filtered = {}
        for _, file_name in ipairs(files) do
            local key = computeFilenameKey(file_name, file2dir)
            if not lcSkippedFiles[key] then
                filtered[#filtered + 1] = file_name
            end
        end
        files = filtered
    end
    orderFilesByPriorities(files, priorities)
    local tsv_files = {}
    for _, desc_file in ipairs(desc_files) do
        tsv_files[desc_file[1].__source] = desc_file
    end
    loadOtherFiles(files, tsv_files, file2dir, lcFn2Type,
    lcFn2Ctx, lcFn2Col,
    lcFn2PreProcessors, lcFn2RowValidators, lcFn2FileValidators,
    extends, raw_files, loadEnv, badVal, lcSkippedFiles)
    -- Note: graph wiring (completion pre-processors + structural file
    -- validators) is now applied per-file through type_wiring.applyWiring
    -- inside processSingleTSVFile — see builtin_wiring.lua's register()
    -- calls for basic_graph_node / graph_node / tree_node.
    -- Build join metadata for exporter
    local joinMeta = {
        lcFn2JoinInto = lcFn2JoinInto,
        lcFn2JoinColumn = lcFn2JoinColumn,
        lcFn2Export = lcFn2Export,
        lcFn2JoinedTypeName = lcFn2JoinedTypeName,
        -- Validator metadata
        lcFn2RowValidators = lcFn2RowValidators,
        lcFn2FileValidators = lcFn2FileValidators,
        -- Pre-processor metadata
        lcFn2PreProcessors = lcFn2PreProcessors,
        -- Graph edge-file metadata (Phase A5)
        lcFn2EdgesFor = lcFn2EdgesFor,
        -- Type metadata: lcfn -> typeName, and typeName -> superType chain.
        -- Exposed for the graph edge-file consistency validator and any
        -- future post-load passes that need the type lineage.
        lcFn2Type = lcFn2Type,
        extends = extends,
        -- Variant metadata
        lcSkippedFiles = lcSkippedFiles,
    }
    return tsv_files, joinMeta
end

-- Initializes badVal if not provided
local function initializeBadVal(badVal)
    if badVal == nil then
        badVal = badValGen()
        badVal.logger = logger
    end
    return badVal
end

-- Checks if a file is a TSV or CSV data file (not just any file like README.md)
local function isTsvOrCsvFile(file)
    local lower = file:lower()
    return lower:sub(-4) == ".tsv" or lower:sub(-4) == ".csv"
end

-- Checks if a directory has TSV/CSV files ONLY in subdirectories but no package markers directly
-- This catches the case where user specifies a parent dir instead of package dirs
-- Returns true if the directory is INVALID:
--   - Has TSV/CSV files in subdirectories but no manifest/Files.tsv directly
-- Returns false if the directory is valid:
--   - Empty directory (or only non-TSV files like README.md)
--   - Has manifest/Files.tsv directly
--   - Has TSV/CSV data files directly (simple package without subdirs)
local function hasSubdirFilesButNoPackageMarkers(directory, files)
    local dirPrefix = directory
    -- Normalize: ensure directory ends without separator for prefix matching
    if dirPrefix:sub(-1) == "/" or dirPrefix:sub(-1) == "\\" then
        dirPrefix = dirPrefix:sub(1, -2)
    end
    local dirPrefixLen = #dirPrefix
    local hasTsvInSubdirs = false
    local hasDirectTsvFiles = false
    local hasPackageMarker = false
    for _, file in ipairs(files) do
        -- Check if file belongs to this directory
        if file:sub(1, dirPrefixLen) == dirPrefix then
            -- Get the part after the directory prefix
            local suffix = file:sub(dirPrefixLen + 1)
            -- Remove leading separator
            if suffix:sub(1, 1) == "/" or suffix:sub(1, 1) == "\\" then
                suffix = suffix:sub(2)
            end
            -- Check if this is a direct child (no subdirectory separators in suffix)
            local slashPos = suffix:find("[/\\]")
            local isDirectChild = (slashPos == nil)
            if isDirectChild then
                if isTsvOrCsvFile(file) then
                    hasDirectTsvFiles = true
                end
                if isManifestFile(file) or isFilesDescriptor(file) then
                    hasPackageMarker = true
                end
            else
                if isTsvOrCsvFile(file) then
                    hasTsvInSubdirs = true
                end
            end
        end
    end
    -- Invalid only if TSV/CSV files exist in subdirs but no package markers and no direct TSV files
    -- This catches "tutorial/" case but allows simple packages with TSV files directly in the dir
    return hasTsvInSubdirs and not hasPackageMarker and not hasDirectTsvFiles
end

-- Collects files from directories and logs any errors
-- Also validates that each top-level directory contains package markers
-- Returns files list, or nil if validation fails
local function collectAndLogFiles(directories, file2dir, opt_excludeDirs)
    local files, errors = collectFiles(directories, EXTENSIONS, file2dir, logger, opt_excludeDirs)
    if errors then
        for _, err in ipairs(errors) do
            logger:error(err)
        end
        -- We continue anyway, in case we did not need the files that cause errors
    end
    -- Validate that each top-level directory contains package markers
    -- Only error if the directory has files but no manifest directly in it
    -- (empty directories are allowed - they just produce no packages)
    local hasInvalidDir = false
    for _, dir in ipairs(directories) do
        if dir and dir ~= "" then
            if hasSubdirFilesButNoPackageMarkers(dir, files) then
                logger:error("Directory '" .. dir .. "' contains files but no Manifest or Files.tsv directly. " ..
                    "Specify package directories directly (e.g., 'tutorial/core/' not 'tutorial/').")
                hasInvalidDir = true
            end
        end
    end
    if hasInvalidDir then
        return nil
    end
    return files
end

-- Resolves package dependencies and returns package order and packages table
local function resolvePackageDependencies(badVal, files, raw_files, manifest_tsv_files, loadEnv)
    local manifest_files_names = extractManifestFiles(files)
    for _, file in ipairs(manifest_files_names) do
        logger:info('Found manifest file: ' .. file)
    end

    local package_order, packages = resolveDependencies(badVal, raw_files, manifest_tsv_files, loadEnv, manifest_files_names)
    if not package_order then
        logger:error("Could not resolve package dependencies. Aborting.")
        return nil, nil
    end

    -- Print load order
    logger:info("Package Load Order:")
    for i, package_id in ipairs(package_order) do
        logger:info(i .. ". " .. packages[package_id].name .. " (" .. package_id .. ")")
    end

    return package_order, packages
end

-- Resolves file descriptors and returns their ordered list
local function resolveFileDescriptors(files, packages, package_order)
    local desc_files_names = extractFilesDescriptors(files)
    local desc_file2pkg_id = matchDescriptorFiles(packages, desc_files_names)
    if not desc_file2pkg_id then
        logger:error("Could not match files descriptors to packages. Aborting.")
        return nil, nil
    end
    local desc_files_order = orderFilesDescByPackageOrder(package_order, desc_file2pkg_id)
    return desc_files_order, desc_file2pkg_id
end

-- Loads any remaining files that haven't been loaded yet
local function loadRemainingFiles(files, raw_files)
    for _, file_name in ipairs(files) do
        if not raw_files[file_name] then
            storeRawFile(file_name, raw_files)
        end
    end
end

-- Merges manifest TSV files into the main TSV files table
local function mergeManifestFiles(tsv_files, manifest_tsv_files)
    for manifest_file, manifest_tsv in pairs(manifest_tsv_files) do
        tsv_files[manifest_file] = manifest_tsv
    end
end

-- Extracts data rows from a TSV file (skips header and non-table rows).
-- Mirrors the dataset's PK index so consumers can do `rows[pkValue]` to
-- retrieve a row in O(1) without rebuilding a name->row map. PK is taken
-- from column 1 (per the tsv_model convention; see tsv_model.lua opt_index)
-- and tostring-normalised so a numeric-typed PK does not collide with
-- positional indexing.
local function extractDataRows(tsv_file)
    local rows = {}
    for i, row in ipairs(tsv_file) do
        if i > 1 and type(row) == "table" then
            rows[#rows + 1] = row
            local pkCell = row[1]
            if type(pkCell) == "table" and getmetatable(pkCell) == "cell" then
                local pk = pkCell.parsed
                if pk == nil then pk = pkCell.evaluated end
                if pk ~= nil and type(pk) ~= "table" then
                    pk = tostring(pk)
                    if rows[pk] == nil then rows[pk] = row end
                end
            end
        end
    end
    return rows
end

-- Computes the lowercase file name key relative to its directory
local function computeFilenameKeyForValidation(file_name)
    -- Extract just the filename from the full path
    local name = file_name:match("[/\\]([^/\\]+)$") or file_name
    return name:lower()
end

-- Runs every file's pre-processors after parsing but before validation.
-- Pre-processors mutate parsed cells (typically to derive back-references or
-- normalise data) and run in priority order within a file. Across files,
-- iteration order matches the tsv_files map iteration order, which is
-- non-deterministic but acceptable because processors are documented to be
-- per-file (cross-file ordering is the cross-package processor's concern,
-- deferred to a future feature).
-- Returns true if all error-level processors completed without failure.
local function runAllPreProcessors(tsv_files, joinMeta, loadEnv, badVal)
    local lcFn2PreProcessors = joinMeta.lcFn2PreProcessors or {}
    local allWarnings = {}
    local allOk = true

    for file_name, tsv_file in pairs(tsv_files) do
        local lcfn = computeFilenameKeyForValidation(file_name)
        local processors = lcFn2PreProcessors[lcfn]
        if processors and #processors > 0 then
            local dataRows = extractDataRows(tsv_file)
            local header = tsv_file[1]
            local ok, warnings = runFilePreProcessors(
                processors, dataRows, header, file_name, badVal, loadEnv)
            if not ok then
                allOk = false
            end
            for _, w in ipairs(warnings) do
                allWarnings[#allWarnings + 1] = w
            end
        end
    end

    return allOk, allWarnings
end

-- Runs all validators (row, file, package) after files are loaded
-- Returns true if all error-level validators passed
local function runAllValidators(tsv_files, joinMeta, packages, package_order, loadEnv, badVal)
    local lcFn2RowValidators = joinMeta.lcFn2RowValidators or {}
    local lcFn2FileValidators = joinMeta.lcFn2FileValidators or {}

    local allWarnings = {}
    local allOk = true

    -- Process each file
    for file_name, tsv_file in pairs(tsv_files) do
        local lcfn = computeFilenameKeyForValidation(file_name)
        local rowValidators = lcFn2RowValidators[lcfn]
        local fileValidators = lcFn2FileValidators[lcfn]

        -- Skip files with no validators
        if not rowValidators and not fileValidators then
            goto continue_file
        end

        local dataRows = extractDataRows(tsv_file)

        -- Run row validators
        if rowValidators and #rowValidators > 0 then
            badVal.source_name = file_name
            local rowCtx = {}  -- writable context shared across all rows
            for i, row in ipairs(dataRows) do
                -- Row index is i+1 because header is row 1
                local rowIndex = i + 1
                local success, warnings = runRowValidators(
                    rowValidators, row, rowIndex, file_name, badVal, loadEnv, rowCtx)
                if not success then
                    allOk = false
                end
                for _, w in ipairs(warnings) do
                    allWarnings[#allWarnings + 1] = w
                end
            end
        end

        -- Run file validators
        if fileValidators and #fileValidators > 0 then
            local success, warnings = runFileValidators(
                fileValidators, dataRows, file_name, badVal, loadEnv)
            if not success then
                allOk = false
            end
            for _, w in ipairs(warnings) do
                allWarnings[#allWarnings + 1] = w
            end
        end

        ::continue_file::
    end

    -- Run package validators for each package
    for _, package_id in ipairs(package_order) do
        local manifest = packages[package_id]
        if manifest and manifest.package_validators then
            -- Build a map of files for this package
            -- Note: In a full implementation, we would filter files by package
            -- For now, we pass all files
            local packageFiles = {}
            for file_name, tsv_file in pairs(tsv_files) do
                local lcfn = computeFilenameKeyForValidation(file_name)
                packageFiles[lcfn] = extractDataRows(tsv_file)
            end

            local success, warnings = runPackageValidators(
                manifest.package_validators, packageFiles, package_id, badVal, loadEnv)
            if not success then
                allOk = false
            end
            for _, w in ipairs(warnings) do
                allWarnings[#allWarnings + 1] = w
            end
        end
    end

    if #allWarnings > 0 then
        logger:info(string.format("Validation completed with %d warning(s)", #allWarnings))
    end

    return allOk, allWarnings
end

--- Processes all TSV/CSV files in the given directories.
--- Resolves package dependencies, loads file descriptors, parses files with type registration.
--- @param directories table Sequence of directory paths to process
--- @param badVal table|nil Optional badVal instance for error reporting (created if nil)
--- @param opt_excludeDirs table|nil Optional set of normalized directory paths to skip during file collection
--- @param opt_variants table|nil Optional array of active variant names (e.g., {"en", "debug"})
--- @return table|nil Result table with {raw_files, tsv_files, package_order, packages}, or nil on error
--- @side_effect Logs progress and errors; registers type parsers and aliases
local function processFiles(directories, badVal, opt_excludeDirs, opt_variants)
    badVal = initializeBadVal(badVal)
    -- Reset file-registered types tracking for this processing run
    fileRegisteredTypes = {}

    local file2dir = {}
    local files = collectAndLogFiles(directories, file2dir, opt_excludeDirs)
    if not files then
        return nil
    end

    local raw_files = {}
    local manifest_tsv_files = {}
    -- loadEnv is the sandbox environment for cell expressions and COG scripts.
    -- Its __index falls through ONLY to the curated safe-globals set from
    -- sandbox_env -- never to the real _G -- so expressions and COG cannot
    -- reach require, debug, io, os.*, raw{get,set}, {set,get}metatable, etc.
    -- Code-library exports and `loadEnv.files` are added as direct keys below.
    local loadEnv = setmetatable({}, {__index = sandbox_env.cogGlobals()})
    loadEnv.files = {}   -- populated with each parsed dataset; available in cog scripts

    local package_order, packages = resolvePackageDependencies(badVal, files, raw_files, manifest_tsv_files, loadEnv)
    if not package_order then
        return nil
    end

    -- Validate variant groups declared in manifests; collect defaults
    local variantsSet = nil
    if opt_variants then
        variantsSet = {}
        for _, v in ipairs(opt_variants) do
            variantsSet[v] = true
        end
    end
    for _, pkg_id in ipairs(package_order) do
        local manifest = packages[pkg_id]
        if manifest and manifest.variant_groups then
            local _ok, defaults = validateVariantGroups(manifest, variantsSet, badVal)
            if defaults then
                if not variantsSet then variantsSet = {} end
                for k in pairs(defaults) do
                    variantsSet[k] = true
                end
            end
        end
    end
    -- Convert back to array for processOrderedFiles
    if variantsSet and not opt_variants then
        -- Defaults were applied but no explicit variants were provided
        opt_variants = {}
        for k in pairs(variantsSet) do
            opt_variants[#opt_variants + 1] = k
        end
    end

    -- Phase 3a of TODO/type_wiring.md: create the bootstrap api/seal pair
    -- and invoke each package's manifest `bootstrap` entries in dependency
    -- order. seal() fires immediately after — the api's only legitimate
    -- use is inside the bootstrap calls themselves; a captured handle
    -- invoked later (e.g. from a library function called during file
    -- loading) errors at the call site.
    --
    -- Phase 3b's "wiring files" (typeName extending `type_wiring_def`)
    -- do NOT use this api — they go through the regular per-file onLoad
    -- pipeline and call type_wiring.register directly, so no seal is
    -- needed for them.
    local bootstrapAPI, sealBootstrap = type_wiring.makeBootstrapAPI()
    runPackageBootstraps(badVal, packages, package_order, loadEnv, bootstrapAPI)
    sealBootstrap()

    local desc_files_order, desc_file2pkg_id = resolveFileDescriptors(files, packages, package_order)
    if not desc_files_order then
        return nil
    end

    local tsv_files, joinMeta = processOrderedFiles(badVal, files, file2dir,
        desc_files_order, desc_file2pkg_id,
        raw_files, loadEnv, opt_variants)

    loadRemainingFiles(files, raw_files)
    mergeManifestFiles(tsv_files, manifest_tsv_files)

    -- Run pre-processors (mutate parsed rows) before any validation. Processors
    -- must see published contexts the same way validators do, so loadEnv is
    -- threaded through unchanged.
    local processorsOk, processorWarnings = runAllPreProcessors(
        tsv_files, joinMeta, loadEnv, badVal)

    -- Run all validators (row, file, package) after files are loaded
    local validatorsOk, validationWarnings = runAllValidators(
        tsv_files, joinMeta, packages, package_order, loadEnv, badVal)

    -- Run any registered enginePostPasses (feature modules contribute these
    -- via type_wiring.registerModule). They get (tsv_files, joinMeta, badVal)
    -- and return true on success, false on any reported error. The graph
    -- edge↔node consistency check (formerly the direct call to
    -- validateGraphEdgeFiles) now lives here as the "graph_wiring" module's
    -- registered post-pass — see builtin_wiring.lua.
    local postPassesOk = type_wiring.runEnginePostPasses(tsv_files, joinMeta, badVal)

    -- Combine pre-processor warnings with validator warnings for callers
    if processorWarnings and #processorWarnings > 0 then
        for _, w in ipairs(processorWarnings) do
            validationWarnings[#validationWarnings + 1] = w
        end
    end

    return {
        raw_files = raw_files,
        tsv_files = tsv_files,
        package_order = package_order,
        packages = packages,
        joinMeta = joinMeta,
        file2dir = file2dir,
        -- `validationPassed` covers BOTH pre-processors and validators: true iff
        -- every error-level processor and every error-level validator succeeded.
        -- (Pre-processors run before validators in the pipeline, but for callers
        -- they are folded into the same pass/fail signal.)
        validationPassed = processorsOk and validatorsOk and postPassesOk,
        validationWarnings = validationWarnings,
    }
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    processFiles = processFiles,
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
