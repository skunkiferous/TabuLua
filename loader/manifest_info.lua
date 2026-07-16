-- Module name
local NAME = "manifest_info"

-- Module logger
local logger = require( "infra.named_logger").getLogger(NAME)

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 32, 0)

-- Returns the module version
local function getVersion()
    return tostring(VERSION)
end

local read_only = require("util.read_only")
local readOnly = read_only.readOnly
local unwrap = read_only.unwrap
local error_reporting = require("infra.error_reporting")
local didYouMean = error_reporting.didYouMean

local parsers = require("parsers")

-- The content pipeline owns the read→COG sequence for manifest files (see
-- content_pipeline.md §5); requiring builtin_content_stages registers COG.
local content_pipeline = require("content.content_pipeline")
require("content.builtin_content_stages")

local sandbox = require("sandbox")
local sandbox_env = require("infra.sandbox_env")

local raw_tsv = require("tsv.raw_tsv")

local string_utils = require("util.string_utils")

local tsv_model = require("tsv.tsv_model")

local file_util = require("infra.file_util")
local getParentPath = file_util.getParentPath
local isSamePath = file_util.isSamePath

-- File name representing a package manifest.
local MANIFEST_FILENAME = "Manifest.transposed.tsv"

-- Constants for MANIFEST_SPEC key fields (used for error reporting)
local PACKAGE_ID_FIELD = "package_id"
local PACKAGE_ID_TYPE = "package_id"
local CUSTOM_TYPES_FIELD = "custom_types"
local CODE_LIBRARIES_FIELD = "code_libraries"
local CODE_LIBRARIES_TYPE = "{{name,string}}|nil"

-- Derived constants
local PACKAGE_ID_ROW_KEY = PACKAGE_ID_FIELD .. ":" .. PACKAGE_ID_TYPE
-- A manifest file is transposed and has exactly one data row (the package definition).
-- Since row 1 is the header and row 2 is the data, after transposition this becomes column 2.
local MANIFEST_DATA_COL_IDX = 2

-- A parser type-specification for the package manifest table
local MANIFEST_SPEC = [[{
    # Defines the package "id"
    package_id:package_id,
    # Defines the package human-readable "name"
    name:string,
    # Defines the package "version"
    version:version,
    # Defines the package description
    # TODO: Add support for internalization
    description:markdown,
    # Defines the source of this package
    url:http|nil,
    # Defines custom types with data-driven validators
    custom_types:{custom_type_def}|nil,
    # Defines code libraries for expressions and COG
    code_libraries:{{name,string}}|nil,
    # Bootstrap entries that run once at engine init with access to the
    # type-wiring registration API. Each entry references a function
    # exported by one of this package's own code libraries. Record
    # fields are written in alphabetical (canonical) order: `fn` then
    # `library`. See TODO/type_wiring.md Phase 3a.
    bootstrap:{{fn:name,library:name}}|nil,
    # Defines the package "dependencies"
    dependencies:{{
        # Defines the "id" of a dependency
        package_id,
        # Defines the package "version requirement" of a dependency
        cmp_version
    }}|nil,
    # Specifies the ids of packages that, if present, must be loaded *before* this package
    load_after:{package_id}|nil,
    # Specifies the ids of packages this package is incompatible with: if any
    # listed package is loaded alongside, the load fails. Symmetric by
    # construction (either side declaring the conflict is enough).
    conflicts:{package_id}|nil,
    # Package-level validators run after all files are loaded
    # Each validator is either a simple expression string (error level) or
    # a structured record {expr:expression, level:error_level|nil}
    package_validators:{validator_spec}|nil,
    # Package-scoped pre-processors (mod overrides).
    # Run after all files are parsed AND after patches are applied, but
    # before validators. Each processor sees the full merged-and-patched state of
    # every loaded file via `files`; its write helpers (setCell / clearCell) are
    # scoped to files this package owns plus files it has declared patches for.
    # Cross-package ordering follows package load order, refined by each spec's
    # optional `requires` field.
    preProcessors:{processor_spec}|nil,
    # Variant groups declare sets of mutually exclusive variant names.
    # Each group is a tuple of (group_name, {allowed_values}).
    # When variants are passed to processFiles(), exactly one value from each
    # declared group must be present. Variant names must be unique across groups.
    variant_groups:{{name,{name},name|nil}}|nil,
    # Globs naming files that are ASSETS: not tables. Matched against each file's
    # path relative to THIS manifest's directory. The bulk form of a Files.tsv row
    # with typeName=asset_file — same role, same result (not parsed, copied
    # byte-for-byte, never reformatted in place), for a whole class of files at
    # once. See util/glob.lua for the syntax (*, **, ?).
    asset_files:{string}|nil,
    # Globs naming files the loader must pretend are not there: not loaded, not
    # exported, and — unlike an undeclared file — not warned about either. This is
    # what silences the temporary files that a data tree accumulates
    # ("*.tmp.tsv", "scratch/**") without having to declare each one.
    ignored_files:{string}|nil
}]]

-- The release that first accepted each manifest field, for `--list-columns`.
-- An OPTIONAL manifest field is invisible until you already know it is there:
-- its absence is never reported (loadManifestFile deliberately marks every
-- `|nil` field as "found" before the missing-column check, because warning
-- about every unused feature on every load would be intolerable). So a package
-- written against an older release keeps working, silently, while never
-- learning what it could now be declaring. `--list-columns` is the answer to
-- "what is new since I last looked?", and this table is what lets it say when.
--
-- A field with no entry predates the CHANGELOG's useful range (package_id,
-- name, version, description, url, dependencies, load_after, code_libraries) —
-- there is no honest version to name, and the report leaves those unannotated.
-- ADD AN ENTRY HERE whenever a field is added to MANIFEST_SPEC above.
local MANIFEST_FIELD_SINCE = {
    custom_types       = "0.3.0",
    package_validators = "0.5.0",
    variant_groups     = "0.17.0",
    bootstrap          = "0.21.0",
    preProcessors      = "0.28.0",
    conflicts          = "0.30.0",
    asset_files        = "0.31.0",
    ignored_files      = "0.31.0",
}

-- Our own badVal (uses module logger by default)
local function myBadVal()
    local bad_val = error_reporting.badValGen()
    bad_val.logger = logger
    return bad_val
end

-- We define 'package_id' as an alias to 'name'
parsers.registerAlias(myBadVal(), "package_id", "name")

local MANIFEST_SPEC_PARSER = parsers.parseType(myBadVal(), MANIFEST_SPEC)
local FORMATTED_MANIFEST_SPEC = parsers.findParserSpec(MANIFEST_SPEC_PARSER)

--- The manifest's full field inventory, for the `--list-columns` report.
--- Each entry is {name, type, required, since} — `required` is the negation of
--- "declared |nil in MANIFEST_SPEC", which is exactly the rule loadManifestFile
--- enforces, so the report cannot drift from the loader. Sorted by name.
--- @return table Sequence of {name=string, type=string, required=boolean, since=string|nil}
local function manifestFields()
    local optional = {}
    for _, name in ipairs(parsers.recordOptionalFieldNames(FORMATTED_MANIFEST_SPEC) or {}) do
        optional[name] = true
    end
    local types = parsers.recordFieldTypes(FORMATTED_MANIFEST_SPEC) or {}
    local out = {}
    for _, name in ipairs(parsers.recordFieldNames(FORMATTED_MANIFEST_SPEC) or {}) do
        out[#out + 1] = {
            name = name,
            type = types[name],
            required = not optional[name],
            since = MANIFEST_FIELD_SINCE[name],
        }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Returns true if the installed version satisfies the given version requirement
local function versionSatisfies(req_op, req_version, installed_version)
    if type(req_version) == "string" then
        req_version = semver(req_version)
    end
    if type(installed_version) == "string" then
        installed_version = semver(installed_version)
    end
    if req_op == "=" or req_op == "==" then
        return installed_version == req_version
    elseif req_op == ">" then
        return installed_version > req_version
    elseif req_op == ">=" then
        -- semver defines __lt but not __le. Lua <= 5.4 emulated `a <= b` as `not (b < a)`;
        -- Lua 5.5 dropped that emulation, so `>=` / `<=` on semver objects raise
        -- "attempt to compare two table values". Express both through `<` alone.
        return not (installed_version < req_version)
    elseif req_op == "<" then
        return installed_version < req_version
    elseif req_op == "<=" then
        return not (req_version < installed_version)
    elseif req_op == "~" then
        -- Compatible version, allows patch-level changes if minor version is specified
        return installed_version.major == req_version.major and
            installed_version.minor == req_version.minor and
            installed_version.patch >= req_version.patch
    elseif req_op == "^" then
        -- "pessimistic upgrade" operator
        -- The ^ implementation in semver handles the major version 0 specially. Apparently,
        -- this is on purpose, and "follows best practices".
        return req_version ^ installed_version

    else
        error("Unsupported version comparison operator: " .. tostring(req_op))
    end
end

-- Matches a file representing a package manifest.
local function isManifestFile(manifest_file)
    if type(manifest_file) ~= "string" then
        return false
    end
    -- Match the exact filename at the end of the path (handle both / and \ separators)
    return manifest_file:match("[/\\]" .. MANIFEST_FILENAME:gsub("%.", "%%.") .. "$") ~= nil
        or manifest_file == MANIFEST_FILENAME
end

-- Takes a "single-row" manifest file and create a read-only "package manifest" table
local function extractManifestFromTSV(badVal, cols, manifest_tsv)
    -- At this point, we know the file has the required columns (and maybe more)
    local header = manifest_tsv[1]
    local src = header.__source
    local manifest_row = nil
    for i,row in ipairs(manifest_tsv) do
        if i > 1 and type(row) == "table" then
            if manifest_row then
                badVal(src, "Multiple package definitions in manifest file")
                return nil
            end
            manifest_row = row
        end
    end
    if not manifest_row then
        badVal(src, "No/missing package definition in manifest file")
        return nil
    end

    local manifest = {}
    manifest.path = src
    for _, col in ipairs(cols) do
        local tmp = manifest_row[col]
        if tmp ~= nil then
            manifest[col] = tmp.parsed
        end
    end

    if manifest.dependencies and next(unwrap(manifest.dependencies)) then
        local copy = {}
        for i, d in ipairs(manifest.dependencies) do
            local package_id = d[1]
            local cmp_version = d[2]
            local req_op, req_version = cmp_version:match("^([^%d]+)(.*)$")
            copy[i] = readOnly({package_id = package_id, req_op = req_op, req_version = req_version})
        end
        manifest.dependencies = readOnly(copy)
    else
        manifest.dependencies = nil
    end
    if manifest.load_after and #manifest.load_after > 0 then
        manifest.load_after = readOnly(manifest.load_after)
    else
        manifest.load_after = nil
    end
    if manifest.conflicts and #manifest.conflicts > 0 then
        manifest.conflicts = readOnly(manifest.conflicts)
    else
        manifest.conflicts = nil
    end
    if manifest.custom_types and next(unwrap(manifest.custom_types)) then
        manifest.custom_types = readOnly(manifest.custom_types)
    else
        manifest.custom_types = nil
    end
    if manifest.code_libraries and next(unwrap(manifest.code_libraries)) then
        manifest.code_libraries = readOnly(manifest.code_libraries)
    else
        manifest.code_libraries = nil
    end
    if manifest.package_validators and next(unwrap(manifest.package_validators)) then
        manifest.package_validators = readOnly(manifest.package_validators)
    else
        manifest.package_validators = nil
    end
    if manifest.preProcessors and next(unwrap(manifest.preProcessors)) then
        manifest.preProcessors = readOnly(manifest.preProcessors)
    else
        manifest.preProcessors = nil
    end
    if manifest.variant_groups and next(unwrap(manifest.variant_groups)) then
        manifest.variant_groups = readOnly(manifest.variant_groups)
    else
        manifest.variant_groups = nil
    end
    if manifest.asset_files and #manifest.asset_files > 0 then
        manifest.asset_files = readOnly(manifest.asset_files)
    else
        manifest.asset_files = nil
    end
    if manifest.ignored_files and #manifest.ignored_files > 0 then
        manifest.ignored_files = readOnly(manifest.ignored_files)
    else
        manifest.ignored_files = nil
    end
    return readOnly(manifest)
end

-- Loads a file representing a package manifest, and returns it if valid.
local function loadManifestFile(badVal, raw_files, cog_env, manifest_file)
    badVal.source_name = manifest_file
    if not isManifestFile(manifest_file) then
        badVal(manifest_file, "Bad manifest file name")
        return nil
    end

    -- The pipeline reads the manifest, stores its normalised pre-COG source in
    -- raw_files, and runs COG (the registered `macro` stage).
    local content = content_pipeline.readAndRun(manifest_file, cog_env, badVal, raw_files)
    if not content then
        return nil
    end

    local loaded_tsv = raw_tsv.stringToRawTSV(content)
    local before = badVal.errors
    local manifest_tsv = tsv_model.processTSV(
        tsv_model.defaultOptionsExtractor,
        nil, -- no expression evaluation
        parsers.parseType,
        manifest_file,
        loaded_tsv,
        badVal,
        nil,
        true -- transpose
    )
    if not manifest_tsv or before ~= badVal.errors then
        -- Problem already logged by tsv_model.processTSV
        badVal(manifest_file, "processTSV() failed")
        return nil
    end

    -- Due to the transposition, we might have '__comment' placeholder columns (from comment lines).
    -- So we cannot use the "raw" model type specification from the header (__type_spec)
    local header = manifest_tsv[1]
    local fields = parsers.recordFieldTypes(FORMATTED_MANIFEST_SPEC)
    local found = {}
    local log = badVal.logger
    for i = 1, #header do
        local col = header[i].name
        if col:sub(1,9) ~= '__comment' then
            local type_spec = header[i].type_spec
            local expected = fields[col]
            if expected then
                if type_spec ~= expected then
                    badVal(type_spec, "Bad type for column '" .. col .. "'. Expected: " .. expected)
                    return nil
                end
                found[col] = true
            else
                -- Unexpected / user-defined field
                log:warn("Unknown column '" .. col .. "' in manifest file: "
                    .. manifest_file .. didYouMean(col, fields))
            end
        end
    end
    for _,opt_col in ipairs(parsers.recordOptionalFieldNames(FORMATTED_MANIFEST_SPEC)) do
        found[opt_col] = true
    end
    local cols = parsers.recordFieldNames(FORMATTED_MANIFEST_SPEC)
    for _,col in ipairs(cols) do
        if not found[col] then
            -- A required column is absent — often a header typo. Suggest the
            -- closest actual header column (found is polluted with optional
            -- spec names by now, so read the real columns off the header).
            local present = {}
            for i = 1, #header do
                local hn = header[i].name
                if hn:sub(1, 9) ~= '__comment' then present[#present + 1] = hn end
            end
            badVal(manifest_file, "Missing column '" .. col .. "' in manifest file"
                .. didYouMean(col, present))
            return nil
        end
    end
    local manifest = extractManifestFromTSV(badVal, cols, manifest_tsv)
    if not manifest then
        return nil
    end
    return manifest, manifest_tsv
end

-- Register the package custom types (data-driven validators)
local function registerCustomTypes(badVal, manifest)
    badVal.col_idx = MANIFEST_DATA_COL_IDX
    badVal.row_key = PACKAGE_ID_ROW_KEY
    badVal.col_name = CUSTOM_TYPES_FIELD
    return error_reporting.withColType(badVal, "custom type definition", function()
        local custom_types = manifest.custom_types
        if custom_types then
            logger:info("Registering custom types for package " .. manifest.package_id)
            -- Convert the tuple-based format to record-based format for registerTypesFromSpec
            local typeSpecs = {}
            for _, ct in ipairs(custom_types) do
                -- ct is a record with named fields, or a tuple with alphabetical field order:
                -- {max, maxLen, members, min, minLen, name, parent, pattern, shape, tags,
                --  validate, values}
                local spec
                if ct.name then
                    -- Already in record format
                    spec = ct
                else
                    -- Tuple format: convert to record
                    -- Fields are alphabetically ordered: max, maxLen, members, min, minLen,
                    -- name, parent, pattern, shape, tags, validate, values
                    spec = {
                        max = ct[1],
                        maxLen = ct[2],
                        members = ct[3],
                        min = ct[4],
                        minLen = ct[5],
                        name = ct[6],
                        parent = ct[7],
                        pattern = ct[8],
                        shape = ct[9],
                        tags = ct[10],
                        validate = ct[11],
                        values = ct[12],
                    }
                end
                typeSpecs[#typeSpecs + 1] = spec
            end
            return parsers.registerTypesFromSpec(badVal, typeSpecs)
        end
        return true
    end)
end

-- Maximum operations allowed when loading a library
local CODE_LIBRARY_MAX_OPERATIONS = 10000

-- Load a single code library file and return its exports
local function loadCodeLibrary(badVal, package_path, library_name, library_path)
    -- Construct full path
    local full_path = package_path .. "/" .. library_path

    -- Read library file
    local content, err = file_util.readFile(full_path)
    if not content then
        badVal(library_path, "Failed to read library file: " .. tostring(err))
        return nil
    end

    -- Create sandboxed environment with the shared safe API surface
    -- (safe builtins, math, curated string/table, predicates, stringUtils,
    -- tableUtils, equals). Code libraries need nothing site-specific.
    local lib_env = sandbox_env.new()

    -- Execute in sandbox with quota
    local opt = {quota = CODE_LIBRARY_MAX_OPERATIONS, env = lib_env}
    local success, protected_func = pcall(sandbox.protect, content, opt)
    if not success then
        badVal(library_path, "Failed to compile library '" .. library_name .. "': " .. tostring(protected_func))
        return nil
    end

    local ok, result = pcall(protected_func)
    if not ok then
        badVal(library_path, "Failed to execute library '" .. library_name .. "': " .. tostring(result))
        return nil
    end

    if type(result) ~= "table" then
        badVal(library_path, "Library '" .. library_name .. "' must return a table, got: " .. type(result))
        return nil
    end

    logger:info("Loaded library '" .. library_name .. "' from " .. library_path)
    return readOnly(result)
end

-- Load all code libraries for a package and add them to the load environment
local function loadCodeLibraries(badVal, manifest, loadEnv)
    local code_libraries = manifest.code_libraries
    if not code_libraries then
        return true
    end

    badVal.col_idx = MANIFEST_DATA_COL_IDX
    badVal.row_key = PACKAGE_ID_ROW_KEY
    badVal.col_name = CODE_LIBRARIES_FIELD
    return error_reporting.withColType(badVal, CODE_LIBRARIES_TYPE, function()
        local package_path = getParentPath(manifest.path)

        for _, lib in ipairs(code_libraries) do
            local name = lib[1]
            local path = lib[2]

            -- Check for name conflicts
            if loadEnv[name] ~= nil then
                badVal(name, "Library name '" .. name .. "' conflicts with existing environment variable")
                return false
            end

            local exports = loadCodeLibrary(badVal, package_path, name, path)
            if not exports then
                return false
            end

            loadEnv[name] = exports
        end

        return true
    end)
end

-- Runs each package's `bootstrap` manifest entries (Phase 3a of
-- TODO/type_wiring.md). For each package walked in dependency order,
-- resolves every `{library, fn}` entry against loadEnv[library] and
-- invokes fn(api). Errors via badVal (never raised) so a misconfigured
-- bootstrap doesn't tear down the whole load. The api is the proxy
-- from type_wiring.makeBootstrapAPI(); seal() should be called by the
-- caller AFTER this function returns AND after TypeWiring.tsv rows
-- have been processed.
local function runPackageBootstraps(badVal, packages, package_order, loadEnv, api)
    for _, package_id in ipairs(package_order) do
        local manifest = packages[package_id]
        local bootstrap = manifest and manifest.bootstrap
        if bootstrap then
            badVal.source_name = manifest.path
            badVal.line_no = 0
            badVal.row_key = PACKAGE_ID_ROW_KEY
            badVal.col_name = "bootstrap"
            for i, entry in ipairs(bootstrap) do
                local library = entry.library or entry[1]
                local fn_name = entry.fn or entry[2]
                if type(library) ~= "string" or type(fn_name) ~= "string" then
                    badVal(tostring(library or fn_name or ""),
                        "bootstrap[" .. i .. "]: invalid entry (expected {library, fn})")
                else
                    local exports = loadEnv[library]
                    if exports == nil then
                        -- Suggest one of this package's declared library names.
                        local libNames = {}
                        for _, cl in ipairs(manifest.code_libraries or {}) do
                            libNames[#libNames + 1] = cl.name or cl[1]
                        end
                        badVal(library, "bootstrap: library '" .. library
                            .. "' not loaded (must match one of this package's"
                            .. " code_libraries entries)" .. didYouMean(library, libNames))
                    else
                        local fn = exports[fn_name]
                        if type(fn) ~= "function" then
                            badVal(fn_name, "bootstrap: function '" .. fn_name
                                .. "' not exported by library '" .. library .. "'"
                                .. didYouMean(fn_name, exports))
                        else
                            local ok, err = pcall(fn, api)
                            if not ok then
                                badVal(fn_name, "bootstrap function '" .. library
                                    .. "." .. fn_name .. "' raised: " .. tostring(err))
                            else
                                logger:info("Ran bootstrap " .. library .. "." .. fn_name
                                    .. " for package " .. package_id)
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Loads and processes all manifest files, building a dependency graph.
-- opt_manifestRank (optional) maps a manifest file path to a numeric load
-- preference (smaller = earlier; see resolveDependencies); the returned
-- pkgRank re-keys it by package_id for the topological sort's tie-break.
local function buildDependencyGraph(badVal, raw_files, manifest_tsv_files, cog_env, manifest_files,
    opt_manifestRank)
    local graph = {}
    local packages = {}
    local pkgRank = opt_manifestRank and {} or nil
    local fail = false

    -- Scan and load package metadata
    for _, manifest_file in ipairs(manifest_files) do
        local manifest, manifest_tsv = loadManifestFile(badVal, raw_files, cog_env, manifest_file)
        if manifest then
            packages[manifest.package_id] = manifest
            graph[manifest.package_id] = {}
            if pkgRank then
                pkgRank[manifest.package_id] = opt_manifestRank[manifest_file]
            end
            if not registerCustomTypes(badVal, manifest) then
                fail = true
            end
            if not loadCodeLibraries(badVal, manifest, cog_env) then
                fail = true
            end
            manifest_tsv_files[manifest_file] = manifest_tsv
        else
            fail = true
        end
    end

    -- Build dependency graph. Iterate packages in sorted package-id order so
    -- the edge lists are built deterministically; `pairs()` order over string
    -- keys is randomized per process (Lua 5.2+ hash seed), which would make
    -- the resulting load order of mutually-unrelated packages non-deterministic
    -- between runs. See TODO/package_order_determinism.md.
    local sorted_package_ids = {}
    for package_id in pairs(packages) do
        sorted_package_ids[#sorted_package_ids + 1] = package_id
    end
    table.sort(sorted_package_ids)
    for _, package_id in ipairs(sorted_package_ids) do
        local manifest = packages[package_id]
        for _, dep in ipairs(manifest.dependencies or {}) do
            if not packages[dep.package_id] then
                logger:error("Missing dependency: " .. dep.package_id .. " for package "
                    .. package_id .. didYouMean(dep.package_id, packages))
                fail = true
            else
                local mv = packages[dep.package_id].version
                if not versionSatisfies(dep.req_op, dep.req_version,
                    mv) then
                    logger:error("Version mismatch: " .. dep.package_id .. " for package " .. package_id)
                    fail = true
                end
                table.insert(graph[package_id], dep.package_id)
            end
        end
        for _, load_after_pkg in ipairs(manifest.load_after or {}) do
            if packages[load_after_pkg] then
                table.insert(graph[package_id], load_after_pkg)
            end
        end
        -- Declared incompatibilities: a load with both sides present fails.
        -- Checked from every package's manifest, so the declaration is
        -- symmetric by construction — either side declaring it is enough. A
        -- conflict naming an absent package is silently vacuous (that is the
        -- point: the declaration only bites when both are installed).
        for _, conflict_pkg in ipairs(manifest.conflicts or {}) do
            if conflict_pkg == package_id then
                logger:error("Package " .. package_id
                    .. " declares a conflict with itself")
                fail = true
            elseif packages[conflict_pkg] then
                logger:error("Conflicting packages loaded together: " .. package_id
                    .. " declares a conflict with " .. conflict_pkg)
                fail = true
            end
        end
    end

    return graph, packages, fail, pkgRank
end

-- Finds and logs one dependency cycle among the nodes not yet loaded. Called
-- when the greedy topological sort stalls: every remaining node then has an
-- unmet prerequisite among the remaining nodes, so walking prerequisite edges
-- restricted to those nodes must revisit one, yielding the cycle path. The
-- walk starts at the smallest remaining id and follows the smallest remaining
-- prerequisite, so the reported path is deterministic.
local function logCycle(graph, done)
    local start = nil
    for node in pairs(graph) do
        if not done[node] and (start == nil or node < start) then
            start = node
        end
    end
    local path = {}
    local pos = {}
    local node = start
    while node and not pos[node] do
        pos[node] = #path + 1
        path[#path + 1] = node
        local nextNode = nil
        for _, pre in ipairs(graph[node]) do
            if not done[pre] and (nextNode == nil or pre < nextNode) then
                nextNode = pre
            end
        end
        node = nextNode
    end
    if not node then
        -- Unreachable when called from a stalled sort; guard for direct misuse.
        logger:error("Circular dependency detected")
        return
    end
    local cycle = {}
    for i = pos[node], #path do
        cycle[#cycle + 1] = path[i]
    end
    cycle[#cycle + 1] = node
    logger:error("Circular dependency detected: " .. table.concat(cycle, " -> "))
end

-- Finds the load order, based on the dependencies graph.
-- Greedy deterministic topological sort (Kahn): at each step, load the
-- lowest-ranked package whose prerequisites have all loaded. A package's rank
-- is the pair (opt_rank[id] or +infinity, id): the caller-supplied numeric
-- preference first — resolveDependencies derives it from the order the input
-- root directories were given, so a host application controls the order of
-- unrelated packages by argument order — then alphabetical package_id. So
-- `dependencies` / `load_after` edges always dominate, unrelated packages
-- follow the caller's preference, and remaining ties are alphabetical (never
-- the randomized `pairs()` order of the graph table).
-- See TODO/package_order_determinism.md.
local function topologicalSort(graph, opt_rank)
    local rank = opt_rank or {}
    -- Node list sorted by id: a stable scan order for the greedy pick.
    local nodes = {}
    for node in pairs(graph) do
        nodes[#nodes + 1] = node
    end
    table.sort(nodes)
    -- unmet[node] = number of distinct prerequisites not yet loaded;
    -- dependents[prereq] = nodes whose unmet count drops when prereq loads.
    local unmet = {}
    local dependents = {}
    for _, node in ipairs(nodes) do
        local seen = {}
        local count = 0
        for _, pre in ipairs(graph[node]) do
            if not seen[pre] then
                seen[pre] = true
                count = count + 1
                local dl = dependents[pre]
                if not dl then
                    dl = {}
                    dependents[pre] = dl
                end
                dl[#dl + 1] = node
            end
        end
        unmet[node] = count
    end
    local function before(a, b)
        local ra = rank[a] or math.huge
        local rb = rank[b] or math.huge
        if ra ~= rb then
            return ra < rb
        end
        return a < b
    end
    local result = {}
    local done = {}
    for _ = 1, #nodes do
        local best = nil
        for _, node in ipairs(nodes) do
            if not done[node] and unmet[node] == 0 and (best == nil or before(node, best)) then
                best = node
            end
        end
        if not best then
            -- Every remaining node waits on another remaining node: a cycle.
            logCycle(graph, done)
            return nil
        end
        done[best] = true
        result[#result + 1] = best
        for _, dep in ipairs(dependents[best] or {}) do
            unmet[dep] = unmet[dep] - 1
        end
    end
    return result
end

-- Packages cannot reside in the same directory, or a subdirectory, of each other
local function checkPackagesDoNotOverlap(packages)
    local fail = false

    local keys = {}
    for k in pairs(packages) do
        keys[#keys + 1] = k
    end

    for i = 1, #keys do
        for j = i + 1, #keys do
            local m1 = packages[keys[i]]
            local m2 = packages[keys[j]]
            local p1 = (getParentPath(m1.path) or "")
            local p2 = (getParentPath(m2.path) or "")
            if isSamePath(p1, p2) then
                logger:error("Packages cannot reside in the same directory: " .. m1.package_id
                    .. " and " .. m2.package_id)
                fail = true
            elseif isSamePath(p1:sub(1, #p2), p2) then
                logger:error("Packages cannot reside in a subdirectory of each other: "
                    .. m1.package_id .. " in " .. m2.package_id)
                fail = true
            elseif isSamePath(p2:sub(1, #p1), p1) then
                logger:error("Packages cannot reside in a subdirectory of each other: "
                    .. m2.package_id .. " in " .. m1.package_id)
                fail = true
            end
        end
    end
    return fail
end

-- Loads and processes all manifest files, resolving the package load order.
-- opt_manifestRank (optional) maps a manifest file path to a numeric load
-- preference for packages the dependency graph leaves unordered (smaller =
-- earlier; ties and unranked packages fall back to alphabetical package_id).
-- manifest_loader derives it from the position of each package's input root
-- directory in the caller's `directories` argument, giving a host application
-- (game launcher, mod manager) user-controlled load order by argument order.
local function resolveDependencies(badVal, raw_files, manifest_tsv_files, cog_env, manifest_files,
    opt_manifestRank)
    local graph, packages, fail, pkgRank = buildDependencyGraph(badVal, raw_files, manifest_tsv_files,
        cog_env, manifest_files, opt_manifestRank)
    local load_order = topologicalSort(graph, pkgRank)
    fail = checkPackagesDoNotOverlap(packages) or fail
    if fail or not load_order then
        return nil
    end
    return load_order, packages
end

--- Validates that the provided variants satisfy all declared variant groups in a manifest.
--- Each group requires exactly one of its allowed values to be present in the variants set.
--- Variant names must be globally unique across all groups within a package.
--- @param manifest table The package manifest (must have variant_groups field)
--- @param variants table|nil Set of active variant names (keys=names, values=true), or nil to skip
--- @param badVal table Error reporting object
--- @return boolean True if validation passes, false if errors found
--- @return table|nil Defaults to apply (variant name -> true), or nil if none
local function validateVariantGroups(manifest, variants, badVal)
    local groups = manifest.variant_groups
    if not groups then
        return true
    end

    -- Collect defaults and apply them when no variant from a group is explicitly provided
    local defaults = nil  -- lazily created: {name = true, ...}
    if not variants then
        -- No variants provided: apply defaults where available, error otherwise
        local ok = true
        badVal.source_name = manifest.path
        badVal.line_no = 0
        for _, group in ipairs(groups) do
            local groupName = group[1]
            local allowed = group[2]
            local default = group[3]
            if default and default ~= '' then
                if not defaults then defaults = {} end
                defaults[default] = true
            else
                badVal(groupName, "variant group '" .. groupName
                    .. "' requires exactly one of: " .. table.concat(allowed, ", ")
                    .. " -- but no variants were provided")
                ok = false
            end
        end
        return ok, defaults
    end

    local ok = true
    -- Check variant names are unique across all groups
    local seen = {}  -- variant name -> group name
    for _, group in ipairs(groups) do
        local groupName = group[1]
        local allowed = group[2]
        for _, v in ipairs(allowed) do
            if seen[v] then
                badVal.source_name = manifest.path
                badVal.line_no = 0
                badVal(v, "variant '" .. v .. "' appears in both group '"
                    .. seen[v] .. "' and group '" .. groupName .. "'")
                ok = false
            else
                seen[v] = groupName
            end
        end
    end

    -- For each group, check exactly one of its values is selected;
    -- if none selected and a default exists, apply it
    for _, group in ipairs(groups) do
        local groupName = group[1]
        local allowed = group[2]
        local default = group[3]
        local selected = {}
        for _, v in ipairs(allowed) do
            if variants[v] then
                selected[#selected + 1] = v
            end
        end
        if #selected == 0 then
            if default and default ~= '' then
                -- Apply default
                if not defaults then defaults = {} end
                defaults[default] = true
            else
                badVal.source_name = manifest.path
                badVal.line_no = 0
                badVal(groupName, "variant group '" .. groupName
                    .. "' requires exactly one of: " .. table.concat(allowed, ", "))
                ok = false
            end
        elseif #selected > 1 then
            badVal.source_name = manifest.path
            badVal.line_no = 0
            badVal(groupName, "variant group '" .. groupName
                .. "' has multiple selected: " .. table.concat(selected, ", ")
                .. " -- expected exactly one")
            ok = false
        end
    end

    return ok, defaults
end

--- The `onlyIfPackages` typo heuristic behind `--check-conflicts`
--- (mod_ecosystem §2.1). A misspelled gate id silently deactivates its file
--- forever — indistinguishable at load time from "that mod is not installed".
--- The distinguishing signal: an id that matched NO known id anywhere in the
--- run. Known = every loaded package_id, plus every id any loaded manifest
--- names in `dependencies` / `load_after` / `conflicts` (an id someone else
--- references is a real mod that is merely absent, not a typo).
--- @param packages table package_id -> manifest, the loaded set
--- @param skippedGates table|nil gate id -> {gated file names}, collected by
---   files_desc from SKIPPED onlyIfPackages rows (joinMeta.skippedGates)
--- @return table Sorted list of {id=string, files={string, sorted},
---   suggest=string|nil} — `suggest` is the closest known id by
---   case-insensitive edit distance (string_utils.closestMatch), so it covers
---   case slips, transposed characters, and near-miss spellings alike
local function unknownGateIds(packages, skippedGates)
    if not skippedGates or next(skippedGates) == nil then return {} end
    local known, knownLc = {}, {}
    local function addKnown(id)
        if id and not known[id] then
            known[id] = true
            knownLc[id:lower()] = id
        end
    end
    for pid, manifest in pairs(packages or {}) do
        addKnown(pid)
        for _, dep in ipairs(manifest.dependencies or {}) do
            addKnown(dep.package_id)
        end
        for _, id in ipairs(manifest.load_after or {}) do addKnown(id) end
        for _, id in ipairs(manifest.conflicts or {}) do addKnown(id) end
    end
    -- Sorted lowercase candidate list, so the did-you-mean pick is
    -- deterministic (closestMatch keeps the first of equally-close ties).
    local knownLcList = {}
    for lc in pairs(knownLc) do knownLcList[#knownLcList + 1] = lc end
    table.sort(knownLcList)
    local out = {}
    for id, files in pairs(skippedGates) do
        if not known[id] then
            local sortedFiles = {}
            for _, f in ipairs(files) do sortedFiles[#sortedFiles + 1] = f end
            table.sort(sortedFiles)
            local lc = id:lower()
            local suggest = knownLc[lc]
            if not suggest then
                local near = string_utils.closestMatch(lc, knownLcList)
                suggest = near and knownLc[near] or nil
            end
            out[#out + 1] = {id = id, files = sortedFiles, suggest = suggest}
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- The provided-variant typo heuristic behind `--check-conflicts`, the variant
--- analogue of `unknownGateIds` (did_you_mean.md Phase 3). A `--variant=X` that
--- names no known variant selects nothing and is silently ignored —
--- `validateVariantGroups` only checks values that belong to a declared group.
--- The distinguishing signal: a provided variant matching NO known variant
--- anywhere. Known = every value any `variant_group` allows, PLUS every value
--- any loaded Files.tsv `variant` column mentions — variants legitimately exist
--- outside declared groups via file selection, so those uses count as known
--- (mirroring how `unknownGateIds` counts manifest mentions as known).
--- Matching is case-sensitive (file/group selection is, so a case slip is
--- itself a typo); the suggestion is case-insensitive.
--- @param packages table package_id -> manifest, the loaded set
--- @param providedVariants table|nil Sequence or set of the user's --variant= values
--- @param fileVariants table|nil Set of variant values mentioned in Files.tsv
---   `variant` columns (joinMeta.knownVariants)
--- @return table Sorted list of {name=string, suggest=string|nil} — `suggest`
---   is the closest known variant by case-insensitive edit distance, or nil
local function unknownVariants(packages, providedVariants, fileVariants)
    if not providedVariants then return {} end
    -- Normalise provided variants to a list of names (sequence or set).
    local provided = {}
    if providedVariants[1] ~= nil then
        for _, v in ipairs(providedVariants) do provided[#provided + 1] = v end
    else
        for v in pairs(providedVariants) do provided[#provided + 1] = v end
    end
    if #provided == 0 then return {} end
    -- Known set (exact) + lowercase -> original casing (for suggestions).
    local known, knownLc = {}, {}
    local function addKnown(v)
        if type(v) == "string" and v ~= "" and not known[v] then
            known[v] = true
            knownLc[v:lower()] = v
        end
    end
    for _, manifest in pairs(packages or {}) do
        for _, group in ipairs(manifest.variant_groups or {}) do
            for _, v in ipairs(group[2] or {}) do addKnown(v) end
        end
    end
    for v in pairs(fileVariants or {}) do addKnown(v) end
    -- Sorted lowercase candidate list, so the did-you-mean pick is deterministic
    -- (closestMatch keeps the first of equally-close ties).
    local knownLcList = {}
    for lc in pairs(knownLc) do knownLcList[#knownLcList + 1] = lc end
    table.sort(knownLcList)
    table.sort(provided)
    local out = {}
    for _, name in ipairs(provided) do
        if not known[name] then
            local lc = name:lower()
            local suggest = knownLc[lc]
            if not suggest then
                local near = string_utils.closestMatch(lc, knownLcList)
                suggest = near and knownLc[near] or nil
            end
            out[#out + 1] = {name = name, suggest = suggest}
        end
    end
    return out
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    isManifestFile = isManifestFile,
    loadManifestFile = loadManifestFile,
    manifestFields = manifestFields,
    resolveDependencies = resolveDependencies,
    runPackageBootstraps = runPackageBootstraps,
    unknownGateIds = unknownGateIds,
    unknownVariants = unknownVariants,
    validateVariantGroups = validateVariantGroups,
    versionSatisfies = versionSatisfies,
    FILENAME = MANIFEST_FILENAME,
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
