-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 30, 0)

-- Module name
local NAME = "manifest_loader"

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

local logger = require( "infra.named_logger").getLogger(NAME)

local table_utils = require("util.table_utils")
local filterSeq = table_utils.filterSeq
local keys = table_utils.keys
local error_reporting = require("infra.error_reporting")
local badValGen = error_reporting.badValGen
local nullBadVal = error_reporting.nullBadVal
local didYouMean = error_reporting.didYouMean
local read_only = require("util.read_only")
local readOnly = read_only.readOnly

local file_util = require("infra.file_util")
local collectFiles = file_util.collectFiles
local hasExtension = file_util.hasExtension
local normalizePath = file_util.normalizePath

local tsv_model = require("tsv.tsv_model")
local processTSV = tsv_model.processTSV

local sandbox_env = require("infra.sandbox_env")

local raw_tsv = require("tsv.raw_tsv")
local stringToRawTSV = raw_tsv.stringToRawTSV

local parsers = require("parsers")
local parseType = parsers.parseType
local isMemberOfTag = parsers.isMemberOfTag

local manifest_info = require("loader.manifest_info")
local isManifestFile = manifest_info.isManifestFile
local resolveDependencies = manifest_info.resolveDependencies
local runPackageBootstraps = manifest_info.runPackageBootstraps
local validateVariantGroups = manifest_info.validateVariantGroups
local versionSatisfies = manifest_info.versionSatisfies

local files_desc = require("loader.files_desc")
local extractFilesDescriptors = files_desc.extractFilesDescriptors
local matchDescriptorFiles = files_desc.matchDescriptorFiles
local orderFilesDescByPackageOrder = files_desc.orderFilesDescByPackageOrder
local loadDescriptorFiles = files_desc.loadDescriptorFiles
local isFilesDescriptor = files_desc.isFilesDescriptor

local validator_executor = require("wiring.validator_executor")
local runRowValidators = validator_executor.runRowValidators
local runFileValidators = validator_executor.runFileValidators
local runPackageValidators = validator_executor.runPackageValidators

local processor_executor = require("wiring.processor_executor")
local runFilePreProcessors = processor_executor.runFilePreProcessors
local runPackagePreProcessors = processor_executor.runPackagePreProcessors
local selectRerunProcessors = processor_executor.selectRerunProcessors

-- Mod schema overlays. collectOverlays runs as a pre-parse pass (so widenTo /
-- newDefault take effect before target cells parse); applyValidatorOverrides runs
-- just before validation.
local schema_overlay = require("overrides.schema_overlay")

-- Mod row patches. applyPatches runs after own-package pre-processors and before
-- validators, mutating each patched parent dataset in place and returning the set
-- of targets the reformatter must not rewrite.
local patch_executor = require("overrides.patch_executor")

-- Optional patch-lineage tracking. Created when there is override work (so the
-- after-patch =expr recompute knows which cells a patch set directly) or when the
-- caller asks for --explain-patch; threaded into every override write path and
-- returned on the result for the CLI to render.
local patch_lineage = require("overrides.patch_lineage")

-- The type-wiring registry replaces the three hand-written branches that
-- previously dispatched Type / enum / custom_type_def behaviour from the
-- per-file load loop. builtin_wiring.lua registers the three onLoad
-- handlers; the dispatcher walks the file's extends chain and fires them.
local type_wiring = require("wiring.type_wiring")
local applyTypeWiring = type_wiring.applyWiring
local hasOnLoadFor = type_wiring.hasOnLoadFor
local hasOnLoad = type_wiring.hasOnLoad
require("wiring.builtin_wiring")

-- The content-pipeline registry owns the read→decode→transcode→normalise→COG
-- sequence that the three load call sites used to hand-roll (see
-- TODO/content_pipeline.md §2, §5). builtin_content_stages registers COG (the
-- `macro` stage) and the core EOL-normalise stage; requiring it here triggers
-- that registration, exactly as `require("wiring.builtin_wiring")` does above.
local content_pipeline = require("content.content_pipeline")
require("content.builtin_content_stages")
local unixEOL = file_util.unixEOL
local readFileBinary = file_util.readFileBinary
local getFileSize = file_util.getFileSize

-- CSV file extension
local CSV = "csv"

-- TSV file extension
local TSV = "tsv"

-- Supported file extensions the loader collects. `gz` lets compressed data files
-- (data.tsv.gz) be picked up so the content pipeline can decode them; whether a
-- given .gz is parsed as data or streamed as an asset is decided per file by its
-- peeled name (see isCompressedDataFile / loadOtherFiles). `zip` lets archive
-- files be seen so collectAndLogFiles can expand them into their virtual members
-- (file_util.expandArchives); the zip itself streams as an asset, while a
-- collectable member (`utilmod.zip/data/Item.tsv`) participates like a loose file.
-- Manifest files use .transposed.tsv, which is covered by TSV.
local EXTENSIONS = {TSV, CSV, "txt", "md", "json", "xml", "lua", "gz", "eav", "zip"}

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
local function buildTableSubscribers(contexts, lcFNKey, lcFn2Ctx, lcFn2Col, badVal)
    local table_subscribers = nil
    local publishContext = lcFn2Ctx[lcFNKey]
    local publishColumn = lcFn2Col[lcFNKey]
    if publishContext or publishColumn then
        -- Are we storing values in a specific context?
        if publishContext then
            local context = contexts[publishContext]
            if context == nil then
                -- A new context is attached to the default env (loadEnv), so its
                -- name must not shadow an existing expression-environment name:
                -- an engine surface (`files`, `packages`, `versionSatisfies`), a
                -- code library, or a curated sandbox global (`math`, `table`,
                -- ...). Shadowing would silently break every later expression
                -- that reads the original name.
                if contexts[''][publishContext] ~= nil then
                    badVal(publishContext, "publishContext '" .. publishContext
                        .. "' conflicts with an existing expression-environment name")
                    return nil
                end
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
    options_extractor, expr_eval, loadEnv, badVal, opt_transcoder, opt_schemaOverlays)
    badVal.source = file_name
    local lcFNKey = computeFilenameKey(file_name, file2dir)
    local fileType = lcFn2Type[lcFNKey]
    -- Files whose typeName is a member of the IgnoredFile tag (e.g. migration
    -- scripts, typeName=MigrationScript) are declared in Files.tsv but must NOT
    -- be loaded as data: their columns carry no fixed per-row type and their
    -- primary key may repeat, so parsing would fail. Recognised declaratively
    -- via the type tag rather than a hard-coded shape heuristic; any user type
    -- can opt in the same way by adding IgnoredFile to its `tags`. Gated before
    -- the content read, so the file is never parsed and not stored in raw_files.
    if fileType and isMemberOfTag("IgnoredFile", fileType) then
        logger:info("Skipping IgnoredFile-tagged file: " .. file_name)
        raw_files[file_name] = nil
        return
    end
    -- The content pipeline reads the file (binary), populates raw_files with the
    -- normalised pre-COG source, and runs the decode→transcode→normalise→COG
    -- stages. COG is no longer named here — it is the registered `macro` stage.
    -- The ctx always carries the file's typeName so a transcoder can build a typed
    -- header from the schema; transcoder is the explicit Files.tsv id, or nil for an
    -- extension-auto-matched transcoder (e.g. .eav), which runTranscode resolves by
    -- extension. For a plain .tsv (no transcode stage matches) the ctx is inert.
    local ctx = {transcoder = opt_transcoder, typeName = fileType}
    local content = content_pipeline.readAndRun(file_name, loadEnv, badVal, raw_files, ctx)
    if not content then
        return
    end
    local rawtsv = stringToRawTSV(content)

    local table_subscribers = buildTableSubscribers(contexts, lcFNKey, lcFn2Ctx, lcFn2Col, badVal)
    logFile(file_name, fileType, extends, table_subscribers)

    -- Look up parent file's header for inheriting column defaults
    local parent_header = nil
    if fileType and extends[fileType] then
        local parent_file = loadEnv.files[extends[fileType]]
        if parent_file then
            parent_header = parent_file[1]
        end
    end

    -- Schema overlay overrides for this target file (widenTo / newDefault), keyed by
    -- column name; nil when no mod overlays this file. They must be applied as the
    -- header parses, so they flow into processTSV.
    local schemaColumnOverrides = schema_overlay.columnOverridesFor(opt_schemaOverlays, lcFNKey)
    -- Note: bulk_patch files need their `where` /
    -- transform `=expr` cells kept RAW (evaluated at apply time, not at load). That
    -- is handled at the COLUMN level: those columns are `expression`-typed, and
    -- processCell skips load-time evaluation for expression columns (col.skip_cell_eval).
    -- No whole-file lever is required here.
    local file = processTSV(options_extractor, expr_eval, parseType,
        file_name, rawtsv, badVal, table_subscribers, false, parent_header,
        schemaColumnOverrides)
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

-- True iff a collected file is TSV/CSV data only AFTER the content pipeline peels
-- its decode extensions — i.e. a compressed data file like data.tsv.gz. A .gz
-- that peels to a non-TSV name (notes.txt.gz, image.png.gz) is NOT data and stays
-- on the stream/passthrough path. Plain .tsv/.csv peel to themselves, so this is
-- false for them (they are matched directly by the caller's hasExtension checks).
local function isCompressedDataFile(file_name)
    local peeled = content_pipeline.peeledName(file_name)
    if peeled == file_name then return false end
    local lower = peeled:lower()
    return lower:sub(-4) == ".tsv" or lower:sub(-4) == ".csv"
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
    extends, raw_files, loadEnv, badVal, lcSkippedFiles, lcFn2Transcoder, opt_schemaOverlays)
    local expr_eval, contexts, options_extractor = setupLoadEnvironment(loadEnv)
    lcFn2Transcoder = lcFn2Transcoder or {}

    -- Tracks types registered by registerFileType (as opposed to pre-existing/built-in types).
    -- Used to limit parent-child field validation to user-defined file record types only.
    local fileRegisteredTypes = {}
    for _, file_name in ipairs(files) do
        local key = computeFilenameKey(file_name, file2dir)
        -- Skip files that were filtered out by variant selection
        if lcSkippedFiles and next(lcSkippedFiles) then
            if lcSkippedFiles[key] then
                goto continue
            end
        end
        -- A file is parsed as data if it's a TSV/CSV, a compressed TSV/CSV the
        -- pipeline can decode (data.tsv.gz), if Files.tsv assigned it a transcoder
        -- (e.g. a .json routed through json:objects), OR if its extension
        -- auto-matches a transcoder (e.g. .eav). Everything else is copied/streamed
        -- through as an asset (unchanged).
        if hasExtension(file_name, CSV) or hasExtension(file_name, TSV)
            or lcFn2Transcoder[key] or isCompressedDataFile(file_name)
            or content_pipeline.autoTranscodes(file_name) then
            processSingleTSVFile(fileRegisteredTypes, file_name, file2dir, contexts,
                lcFn2Type, lcFn2Ctx, lcFn2Col,
                lcFn2PreProcessors, lcFn2RowValidators, lcFn2FileValidators,
                extends, raw_files, files_cache,
                options_extractor, expr_eval, loadEnv, badVal, lcFn2Transcoder[key],
                opt_schemaOverlays)
        else
            processUnknownFile(file_name, raw_files, badVal)
        end
        ::continue::
    end
end

-- Builds a map from each loaded data file (full tsv_files key) to the id of the
-- package that owns it. Ownership is by directory: a file belongs to the package
-- whose root (the manifest's directory) is the longest path prefix of the file's
-- directory — the same rule files_desc.matchDescriptorFiles uses for Files.tsv.
-- `names` is any table whose KEYS are the file names (tsv_files, or a plain set).
local function buildFileToPackage(packages, names)
    local paths = {}
    local path2pkg = {}
    for pid, pkg in pairs(packages) do
        local root = (file_util.getParentPath(pkg.path) or ""):lower()
        paths[#paths + 1] = root
        path2pkg[root] = pid
    end
    local fn2pkg = {}
    for file_name in pairs(names) do
        local parent = (file_util.getParentPath(file_name) or ""):lower()
        local pid = path2pkg[parent]
        if not pid then
            -- Subdirectory of a package: longest matching root prefix wins.
            local best = ""
            for _, root in ipairs(paths) do
                if #root > #best and parent:sub(1, #root) == root then
                    best = root
                end
            end
            pid = path2pkg[best]
        end
        fn2pkg[file_name] = pid
    end
    return fn2pkg
end

-- Process files once the order has been established.
-- Returns the TSV files and join metadata.
local function processOrderedFiles(badVal, files, file2dir, desc_files_order, desc_file2pkg_id,
    raw_files, loadEnv, opt_variants, packages)
    local priorities = {}
    local post_proc_files = {}
    local extends = {}
    -- Core/derived maps (not registered descriptor columns).
    local lcFn2Type = {}
    local lcFn2LineNo = {}
    -- metaMaps owns every registered descriptor-column map. loadDescriptorFiles
    -- auto-allocates one empty map per registered fieldOnMeta and populates them
    -- during the load; it becomes joinMeta below (plus the core entries). No
    -- per-column map is named here, so a feature column (e.g. graph edgesFor)
    -- flows through purely via its registry declaration.
    local metaMaps = {}
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
        post_proc_files, extends, lcFn2Type, lcFn2LineNo, metaMaps,
        raw_files, loadEnv, badVal, variantsSet, lcSkippedFiles)
    if not desc_files then
        logger:error("Could not load/process files descriptors. Aborting.")
        return
    end
    -- Local aliases for the maps still consumed inside this module (context/
    -- column publishing, validator/processor execution, transcoder routing).
    -- These are core engine behaviours, not addable features, so naming them
    -- here is deliberate — but they are allocated and populated via metaMaps,
    -- not by hand. validators/processors are mutated in place during the load
    -- loop (ensureList), so the aliases and metaMaps share the same tables.
    local lcFn2Ctx = metaMaps.lcFn2Ctx
    local lcFn2Col = metaMaps.lcFn2Col
    local lcFn2RowValidators = metaMaps.lcFn2RowValidators
    local lcFn2FileValidators = metaMaps.lcFn2FileValidators
    local lcFn2PreProcessors = metaMaps.lcFn2PreProcessors
    local lcFn2Transcoder = metaMaps.lcFn2Transcoder
    local lcFn2SchemaOverlayOf = metaMaps.lcFn2SchemaOverlayOf or {}
    -- Per-file missing-target policy (mod_ecosystem §6): consumed by the patch
    -- plan below and by the overlay-target resolver (a whole-target-file miss).
    local lcFn2IfMissing = metaMaps.lcFn2IfMissing or {}
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
    -- Schema overlays: collect every overlay file (now that `files` is in load
    -- order, so newDefault last-wins is correct) and parse them ahead of the
    -- main load loop. The resulting per-target column overrides (widenTo /
    -- newDefault) are threaded into each target file's parse.
    local overlayFiles = {}
    for _, fn in ipairs(files) do
        if lcFn2SchemaOverlayOf[computeFilenameKey(fn, file2dir)] then
            overlayFiles[#overlayFiles + 1] = fn
        end
    end
    -- Overlay-target resolver (pre-parse): the same deterministic, optionally
    -- 'package.id:'-qualified resolution patches use, but over the relative
    -- file keys the overlay application looks up (computeFilenameKey space) —
    -- so an overlay binds to exactly ONE file even when two packages ship the
    -- same basename (previously both were silently overlaid). A missing target
    -- is a reported error (mod_ecosystem §4; gate the overlay row with
    -- onlyIfPackages when its target belongs to an optional package).
    local resolveOverlayTarget = nil
    if #overlayFiles > 0 then
        local relKeySet, relKey2pkg = {}, {}
        local fullSet = {}
        for _, fn in ipairs(files) do fullSet[fn] = true end
        local full2pkg = buildFileToPackage(packages or {}, fullSet)
        for _, fn in ipairs(files) do
            local key = computeFilenameKey(fn, file2dir)
            relKeySet[key] = true
            relKey2pkg[key] = full2pkg[fn]
        end
        local resolve = patch_executor.newTargetResolver(relKeySet, relKey2pkg)
        resolveOverlayTarget = function(target, sourceFile)
            local resolved, info = resolve(target)
            if not resolved then
                local reason = info and info.reason
                -- ifMissing tolerance (mod_ecosystem §6): under warn/silent a
                -- missing target makes this overlay file a logged no-op
                -- instead of a load error (multi-version compat overlays).
                local policy = lcFn2IfMissing[computeFilenameKey(sourceFile, file2dir)]
                if policy == "warn" or policy == "silent" then
                    local msg = sourceFile .. ": schema overlay target '" .. target
                        .. "' not found; skipping this overlay file (ifMissing="
                        .. policy .. ")"
                    if policy == "warn" then logger:warn(msg) else logger:info(msg) end
                    return nil
                end
                badVal.source_name = sourceFile
                badVal.line_no = 0
                if reason == "not_in_package" then
                    badVal(target, "schema overlay target '" .. target
                        .. "': package '" .. info.pkg
                        .. "' is not loaded or owns no such file"
                        .. didYouMean(info.base, info.candidates))
                else
                    badVal(target, "schema overlay target '" .. target
                        .. "' not found (must match a loaded file by basename,"
                        .. " optionally qualified as 'package.id:Name.tsv')"
                        .. didYouMean(info.base, info.candidates))
                end
                return nil
            end
            if info and info.ambiguous then
                local _, targetBase = patch_executor.splitQualifiedTarget(target)
                logger:warn(sourceFile .. ": schema overlay target '" .. target
                    .. "' is ambiguous — candidates: "
                    .. table.concat(info.ambiguous, ", ")
                    .. "; using '" .. resolved
                    .. "' (qualify the target as 'package.id:" .. targetBase
                    .. "' to disambiguate)")
            end
            return resolved
        end
    end
    local schemaOverlays = schema_overlay.collectOverlays(overlayFiles, file2dir,
        computeFilenameKey, lcFn2SchemaOverlayOf, lcFn2Transcoder,
        raw_files, loadEnv, badVal, resolveOverlayTarget)
    -- Row patches: build the apply plan in load order (so newDefault /
    -- last-writer-wins is deterministic). Each entry pairs a patch file with the
    -- basename of the parent file it targets; patch_executor.applyPatches consumes
    -- it after the load loop (it needs the fully parsed datasets).
    local lcFn2PatchOf = metaMaps.lcFn2PatchOf or {}
    local lcFn2BulkPatchOf = metaMaps.lcFn2BulkPatchOf or {}
    local patchPlan = {}
    for _, fn in ipairs(files) do
        local key = computeFilenameKey(fn, file2dir)
        -- A file is a row patch (`patchOf`) or a bulk patch (`bulkPatchOf`); both go
        -- in the one load-ordered plan, tagged by kind, so they compose at apply time.
        local target = lcFn2PatchOf[key]
        local kind = "patch"
        if not target then
            target = lcFn2BulkPatchOf[key]
            kind = "bulk"
        end
        if target then
            -- Preserve an optional 'package.id:' qualifier (mod_ecosystem §4);
            -- the file part reduces to its lowercased basename either way,
            -- matching patch_executor's resolution convention.
            local qual, rest = target:match("^([^:/\\]+):(.+)$")
            local filePart = rest or target
            local targetBase = (filePart:match("[/\\]([^/\\]+)$") or filePart):lower()
            if qual then
                targetBase = qual:lower() .. ":" .. targetBase
            end
            patchPlan[#patchPlan + 1] = {file = fn, target = targetBase, kind = kind,
                ifMissing = lcFn2IfMissing[key]}
        end
    end
    loadOtherFiles(files, tsv_files, file2dir, lcFn2Type,
    lcFn2Ctx, lcFn2Col,
    lcFn2PreProcessors, lcFn2RowValidators, lcFn2FileValidators,
    extends, raw_files, loadEnv, badVal, lcSkippedFiles, lcFn2Transcoder, schemaOverlays)
    -- Note: graph wiring (completion pre-processors + structural file
    -- validators) is now applied per-file through type_wiring.applyWiring
    -- inside processSingleTSVFile — see builtin_wiring.lua's register()
    -- calls for basic_graph_node / graph_node / tree_node.
    -- Build join metadata for exporter. Every registered descriptor-column map
    -- is already in metaMaps (allocated by loadDescriptorFiles, populated during
    -- the load and per-file processing), so joinMeta IS that table plus the
    -- core/derived entries. Feature columns (e.g. graph edgesFor) therefore
    -- appear here automatically with no edit.
    local joinMeta = metaMaps
    -- Type metadata: lcfn -> typeName, and typeName -> superType chain. Exposed
    -- for the graph edge-file consistency validator and any future post-load
    -- passes that need the type lineage.
    joinMeta.lcFn2Type = lcFn2Type
    joinMeta.extends = extends
    -- Variant metadata
    joinMeta.lcSkippedFiles = lcSkippedFiles
    -- Full-path -> transcoder id, for the reformatter's id-selected reversible
    -- round-trip: an id-only transcoder (e.g. xml:tabulua) has no `extensions`,
    -- so reversibleTranscode can't find it by file name alone. lcFn2Transcoder is
    -- keyed by the relative filename key; re-key it by the same full file_name the
    -- reformatter iterates (tsv_files keys). Built here because computeFilenameKey
    -- is module-private.
    local fn2Transcoder = {}
    for _, file_name in ipairs(files) do
        local tc = lcFn2Transcoder[computeFilenameKey(file_name, file2dir)]
        if tc then fn2Transcoder[file_name] = tc end
    end
    joinMeta.fn2Transcoder = fn2Transcoder
    -- Schema overlays, for the validator-severity overrides applied just before
    -- runAllValidators (the per-file validator lists only exist after the load loop,
    -- so the suppressValidator / validatorLevel part of an overlay cannot run in the
    -- pre-parse pass that handled widen/default).
    joinMeta.schemaOverlays = schemaOverlays
    -- Row patch plan (load-ordered), consumed by patch_executor.applyPatches
    -- in processFiles after pre-processors and before validators.
    joinMeta.patchPlan = patchPlan
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
    -- Expand any collected archives into their virtual member paths, so a
    -- Files.tsv reference to a member inside a zip (utilmod.zip/data/Item.tsv)
    -- resolves like a loose file. Metadata only — no member is extracted here.
    files = file_util.expandArchives(files, EXTENSIONS, file2dir, logger)
    return files
end

-- Resolves package dependencies and returns package order and packages table.
-- `directories` (the caller's input roots, in argument order) and `file2dir`
-- (file -> the root it was collected from) rank each manifest by its root's
-- position, so packages unrelated by `dependencies` / `load_after` load in
-- input-root order (then alphabetical package_id within one root) — a host
-- application expresses user-controlled load order simply by argument order.
-- See TODO/package_order_determinism.md Phase 2.
local function resolvePackageDependencies(badVal, files, raw_files, manifest_tsv_files, loadEnv,
    directories, file2dir)
    local manifest_files_names = extractManifestFiles(files)
    for _, file in ipairs(manifest_files_names) do
        logger:info('Found manifest file: ' .. file)
    end

    -- Rank each manifest by the position of its input root directory. A
    -- directory listed twice keeps its first position; collectFiles ignored
    -- nil / "" entries, so they are skipped here too.
    local dirRank = {}
    for i, directory in ipairs(directories or {}) do
        if directory and directory ~= "" and dirRank[directory] == nil then
            dirRank[directory] = i
        end
    end
    local manifestRank = {}
    for _, file in ipairs(manifest_files_names) do
        local directory = file2dir and file2dir[file]
        if directory then
            manifestRank[file] = dirRank[directory]
        end
    end

    local package_order, packages = resolveDependencies(badVal, raw_files, manifest_tsv_files, loadEnv,
        manifest_files_names, manifestRank)
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

-- Topologically orders the loaded packages, refining the load order by the
-- `requires` edges declared on package-scoped processors. An edge Q->P means
-- "package Q's package-scoped processors must run before P's". Edges
-- to packages that are not loaded are dropped with a warning (the requirement is
-- vacuous). A cycle in the requires graph is a hard error. Ties are broken by
-- load order so the schedule is deterministic.
-- Returns an ordered array of package ids, or nil on a cycle (after reporting).
local function schedulePackageProcessors(package_order, pkgProcessors, badVal)
    local loadIdx = {}
    for i, pid in ipairs(package_order) do
        loadIdx[pid] = i
    end
    local loaded = {}
    for _, pid in ipairs(package_order) do
        loaded[pid] = true
    end

    -- Build edges Q -> P (Q before P) and in-degrees over all loaded packages.
    local adj = {}
    local indeg = {}
    for _, pid in ipairs(package_order) do
        adj[pid] = {}
        indeg[pid] = 0
    end
    local seenEdge = {}
    for pid, processors in pairs(pkgProcessors) do
        for _, spec in ipairs(processors) do
            local req = processor_executor.normalizeProcessorSpec(spec).requires
            for _, q in ipairs(req) do
                if not loaded[q] then
                    logger:warn(string.format(
                        "Package '%s' pre-processor requires package '%s', "
                        .. "which is not loaded; ordering constraint ignored", pid, q))
                elseif q ~= pid then
                    local edgeKey = q .. "\0" .. pid
                    if not seenEdge[edgeKey] then
                        seenEdge[edgeKey] = true
                        adj[q][#adj[q] + 1] = pid
                        indeg[pid] = indeg[pid] + 1
                    end
                end
            end
        end
    end

    -- Kahn's algorithm, always emitting the ready node with the smallest load
    -- index for a deterministic, load-order-respecting schedule.
    local emitted = {}
    local result = {}
    local remaining = #package_order
    while remaining > 0 do
        local pick = nil
        for _, pid in ipairs(package_order) do
            if not emitted[pid] and indeg[pid] == 0 then
                if pick == nil or loadIdx[pid] < loadIdx[pick] then
                    pick = pid
                end
            end
        end
        if pick == nil then
            -- No ready node but packages remain => a requires cycle.
            local stuck = {}
            for _, pid in ipairs(package_order) do
                if not emitted[pid] then stuck[#stuck + 1] = pid end
            end
            badVal.source_name = "package pre-processors"
            badVal("requires", "cyclic `requires` ordering among package-scoped "
                .. "pre-processors: " .. table.concat(stuck, ", "))
            return nil
        end
        emitted[pick] = true
        result[#result + 1] = pick
        remaining = remaining - 1
        for _, p in ipairs(adj[pick]) do
            indeg[p] = indeg[p] - 1
        end
    end
    return result
end

-- Cross-package pre-processor phase (package-scoped mod-override processors).
-- Runs AFTER patches are applied and BEFORE validators, so processors see (and
-- validators see the effects of) the fully merged-and-patched state. For each
-- package, in requires-refined load order, it (a) re-runs that package's own
-- file-level processors flagged rerunAfterPatches against the patched data, then
-- (b) runs the package's manifest-declared package-scoped processors with write
-- access scoped to files it owns or has declared patches for.
-- Returns (ok, warnings).
local function runAllPackagePreProcessors(tsv_files, joinMeta, packages, package_order, loadEnv, badVal, opt_lineage,
    opt_fn2pkg)
    local lcFn2PreProcessors = joinMeta.lcFn2PreProcessors or {}
    local patchPlan = joinMeta.patchPlan or {}

    -- Which packages declare package-scoped (manifest) processors?
    local pkgProcessors = {}
    for _, pid in ipairs(package_order) do
        local manifest = packages[pid]
        if manifest and manifest.preProcessors and #manifest.preProcessors > 0 then
            pkgProcessors[pid] = manifest.preProcessors
        end
    end

    -- Which files have rerunAfterPatches-flagged file-level processors?
    local rerunByFile = {}
    local anyRerun = false
    for file_name in pairs(tsv_files) do
        local lcfn = computeFilenameKeyForValidation(file_name)
        local rerun = selectRerunProcessors(lcFn2PreProcessors[lcfn])
        if #rerun > 0 then
            rerunByFile[file_name] = rerun
            anyRerun = true
        end
    end

    -- Nothing to do: skip all the ownership/scheduling work.
    if not next(pkgProcessors) and not anyRerun then
        return true, {}
    end

    local fn2pkg = opt_fn2pkg or buildFileToPackage(packages, tsv_files)

    -- Resolve patch targets to full file names (same deterministic,
    -- optionally package-qualified resolution applyPatches used — see
    -- patch_executor.newTargetResolver), and accumulate the write scope of
    -- each package: files it owns + files it patches.
    local resolveTarget = patch_executor.newTargetResolver(tsv_files, fn2pkg)
    local writableByPkg = {}
    local function grantWrite(pid, fn)
        if not pid or not fn then return end
        writableByPkg[pid] = writableByPkg[pid] or {}
        writableByPkg[pid][fn] = true
    end
    for file_name, pid in pairs(fn2pkg) do
        grantWrite(pid, file_name)
    end
    for _, entry in ipairs(patchPlan) do
        local ownerPid = fn2pkg[entry.file]
        grantWrite(ownerPid, (resolveTarget(entry.target)))
    end

    local order = schedulePackageProcessors(package_order, pkgProcessors, badVal)
    if not order then
        return false, {}
    end

    local allWarnings = {}
    local allOk = true

    for _, pid in ipairs(order) do
        -- (a) Re-run this package's rerun-flagged file processors.
        for file_name, rerun in pairs(rerunByFile) do
            if fn2pkg[file_name] == pid then
                local tsv_file = tsv_files[file_name]
                local ok, warnings = runFilePreProcessors(
                    rerun, extractDataRows(tsv_file), tsv_file[1], file_name, badVal, loadEnv)
                if not ok then allOk = false end
                for _, w in ipairs(warnings) do
                    allWarnings[#allWarnings + 1] = w
                end
            end
        end

        -- (b) Run this package's package-scoped processors.
        local processors = pkgProcessors[pid]
        if processors then
            local writable = writableByPkg[pid] or {}
            local fileEntries = {}
            for file_name, tsv_file in pairs(tsv_files) do
                local key = computeFilenameKeyForValidation(file_name)
                fileEntries[key] = {
                    rows = extractDataRows(tsv_file),
                    header = tsv_file[1],
                    fileName = file_name,
                    writable = writable[file_name] == true,
                }
            end
            local ok, warnings = runPackagePreProcessors(
                processors, fileEntries, pid, badVal, loadEnv, opt_lineage)
            if not ok then allOk = false end
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
local function processFiles(directories, badVal, opt_excludeDirs, opt_variants, opt_trackLineage)
    badVal = initializeBadVal(badVal)
    -- Patch-lineage collector. Created when there is override work (so the after-
    -- patch `=expr` recompute knows which cells a patch set directly) OR when the
    -- caller asks for --explain-patch. A plain non-mod load creates none and pays
    -- nothing; `lineage` is decided below, once the patch plan is known.
    local lineage = nil
    -- Reset file-registered types tracking for this processing run
    fileRegisteredTypes = {}
    -- The archive cache only earns its keep WITHIN a load (a zip's N members would
    -- otherwise each re-parse the whole archive). Clear it at the start of each run
    -- so cached bytes never outlive the load that populated them, bounding memory to
    -- one run's archives without re-reading anything mid-load (file_util.lua Q6).
    file_util.clearArchiveCache()

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
    -- Reserve the `packages` / `versionSatisfies` expression-environment names
    -- BEFORE code libraries load (they load during dependency resolution, below),
    -- so a code library claiming either name fails with the standard "conflicts
    -- with existing environment variable" error instead of silently clobbering
    -- the engine surface. The `packages` placeholder is replaced with the real
    -- read-only content once the package set is resolved.
    -- See TODO/mod_ecosystem.md §2.2 (Phase 1).
    loadEnv.packages = {}
    loadEnv.versionSatisfies = versionSatisfies

    local package_order, packages = resolvePackageDependencies(badVal, files, raw_files,
        manifest_tsv_files, loadEnv, directories, file2dir)
    if not package_order then
        return nil
    end

    -- Publish the loaded-package set to every sandbox surface that sees loadEnv
    -- (`=expr` cells, COG blocks, validators — including bulk_patch `where`
    -- selectors — and pre-processors): `packages` maps each loaded package_id to
    -- a read-only {name, version} record, so an expression can branch on another
    -- mod's presence (`packages["some.mod"]`) or version
    -- (`versionSatisfies(">=", "2.0.0", packages["some.mod"].version)`); an
    -- absent package indexes to nil. Version is exposed as a plain string.
    -- Manifest-file COG cannot see this (manifests load while the package set is
    -- still being resolved and only ever see the empty placeholder above).
    local packagesCtx = {}
    for _, pkg_id in ipairs(package_order) do
        local manifest = packages[pkg_id]
        packagesCtx[pkg_id] = readOnly({
            name = manifest.name,
            version = tostring(manifest.version),
        })
    end
    loadEnv.packages = readOnly(packagesCtx)

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
    -- The bootstrap api combines the type-wiring registration surface with the
    -- content-pipeline one, so a package `bootstrap` can register custom stages
    -- (e.g. a transcoder) alongside type wiring. Each registry seals its own
    -- half after the bootstrap phase.
    local twAPI, sealTypeWiring = type_wiring.makeBootstrapAPI()
    local registerContentStage, sealContentPipeline = content_pipeline.makeBootstrapAPI()
    local bootstrapAPI = readOnly({
        register = twAPI.register,
        registerModule = twAPI.registerModule,
        registerContentStage = registerContentStage,
    })
    runPackageBootstraps(badVal, packages, package_order, loadEnv, bootstrapAPI)
    sealTypeWiring()
    sealContentPipeline()

    local desc_files_order, desc_file2pkg_id = resolveFileDescriptors(files, packages, package_order)
    if not desc_files_order then
        return nil
    end

    local tsv_files, joinMeta = processOrderedFiles(badVal, files, file2dir,
        desc_files_order, desc_file2pkg_id,
        raw_files, loadEnv, opt_variants, packages)

    loadRemainingFiles(files, raw_files)
    mergeManifestFiles(tsv_files, manifest_tsv_files)

    -- Run pre-processors (mutate parsed rows) before any validation. Processors
    -- must see published contexts the same way validators do, so loadEnv is
    -- threaded through unchanged.
    local processorsOk, processorWarnings = runAllPreProcessors(
        tsv_files, joinMeta, loadEnv, badVal)

    -- Row patches: apply add / remove / update / replace ops from patch files to
    -- their target parent datasets, in load order. Runs after own-package
    -- pre-processors and before validators, so validators (and the exporter) see the
    -- patched state. patchedTargets is the set of parent files the reformatter must
    -- not rewrite (patches are never baked into parent source).
    -- Decide whether to track lineage: needed whenever there is override work (the
    -- recompute reads the directly-set cells from it), or when the caller
    -- requested --explain-patch. A plain non-mod load tracks nothing.
    local hasOverrideWork = (joinMeta.patchPlan and #joinMeta.patchPlan > 0)
        or (joinMeta.schemaOverlays and next(joinMeta.schemaOverlays) ~= nil)
    if not hasOverrideWork then
        for _, pid in ipairs(package_order) do
            local m = packages[pid]
            if m and m.preProcessors and #m.preProcessors > 0 then
                hasOverrideWork = true
                break
            end
        end
    end
    if opt_trackLineage or hasOverrideWork then
        lineage = patch_lineage.new()
    end

    -- File ownership (tsv_files key -> package id), computed once and shared by
    -- lineage source attribution, the patch executor (package-qualified targets,
    -- ambiguity diagnostics) and the package-scoped processor write scope below.
    local fn2pkg = buildFileToPackage(packages, tsv_files)

    -- Record the (already-applied, pre-parse) column overlays into the lineage
    -- first, so schema effects precede the row/cell events below.
    if lineage then
        schema_overlay.recordLineage(joinMeta.schemaOverlays, lineage, fn2pkg)
    end

    local patchesOk, patchedTargets = patch_executor.applyPatches(
        tsv_files, joinMeta.patchPlan, loadEnv, badVal, lineage, fn2pkg)
    joinMeta.patchedTargets = patchedTargets

    -- Recompute downstream `=expr` cells whose same-row inputs an override changed
    -- (e.g. patching baseDamage updates totalDamage=…self.baseDamage…). Uses the
    -- lineage's directly-set cells to find changed rows and to avoid clobbering a
    -- cell an override set explicitly. Idempotent (re-evaluating an unaffected cell
    -- yields the same value), so it runs in TWO passes: this one, right after patches,
    -- so the package-scoped processors below see consistent derived data; and a
    -- second pass after them, to fold in any cells the processors themselves changed.
    local recomputeOk = true
    if lineage then
        recomputeOk = patch_executor.recomputeAfterPatches(
            tsv_files, lineage:dirtyCells(), loadEnv, badVal)
    end

    -- Package-scoped cross-package pre-processors: a child package's
    -- manifest-declared processors mutate the merged-and-patched state (scoped to
    -- files it owns or patched), and any parent file processor flagged
    -- rerunAfterPatches re-derives against the patched data. Runs after patches,
    -- before validators, in requires-refined package load order.
    local pkgProcessorsOk, pkgProcessorWarnings = runAllPackagePreProcessors(
        tsv_files, joinMeta, packages, package_order, loadEnv, badVal, lineage, fn2pkg)

    -- Second recompute pass: recompute again after the processors, now that they may
    -- have changed more cells. `dirtyCells()` includes their writes too.
    if lineage then
        local recomputeOk2 = patch_executor.recomputeAfterPatches(
            tsv_files, lineage:dirtyCells(), loadEnv, badVal)
        recomputeOk = recomputeOk and recomputeOk2
    end

    -- Schema overlays: downgrade / remove parent validators a mod has declared a
    -- suppressValidator for, before the validators run against the (possibly
    -- patched) data. Mutates the per-file validator lists in joinMeta.
    schema_overlay.applyValidatorOverrides(joinMeta.schemaOverlays, joinMeta, badVal,
        lineage, fn2pkg)

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

    -- Combine pre-processor warnings (own-package and cross-package) with
    -- validator warnings for callers
    if processorWarnings and #processorWarnings > 0 then
        for _, w in ipairs(processorWarnings) do
            validationWarnings[#validationWarnings + 1] = w
        end
    end
    if pkgProcessorWarnings and #pkgProcessorWarnings > 0 then
        for _, w in ipairs(pkgProcessorWarnings) do
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
        -- The COG/expression env, with loadEnv.files[typeName] populated for every
        -- loaded dataset. Exposed so the export-time doc generator can expand COG
        -- doc templates against the same data the load-time COG blocks saw.
        loadEnv = loadEnv,
        -- `validationPassed` covers pre-processors (own-package and package-scoped
        -- cross-package), row patches, and validators: true iff every error-level
        -- processor, patch op, and validator succeeded. (These run in pipeline
        -- order before/around validators, but for callers they are folded into
        -- the same pass/fail signal.)
        validationPassed = processorsOk and patchesOk and pkgProcessorsOk
            and recomputeOk and validatorsOk and postPassesOk,
        validationWarnings = validationWarnings,
        -- Patch lineage: present whenever there was override work (the recompute
        -- needs it) or --explain-patch was requested. Consumed by --explain-patch.
        lineage = lineage,
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
