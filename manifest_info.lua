-- Module name
local NAME = "manifest_info"

-- Module logger
local logger = require( "named_logger").getLogger(NAME)

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 5, 2)

-- Returns the module version
local function getVersion()
    return tostring(VERSION)
end

local read_only = require("read_only")
local readOnly = read_only.readOnly
local error_reporting = require("error_reporting")

local parsers = require("parsers")

local lua_cog = require("lua_cog")

local sandbox = require("sandbox")

local raw_tsv = require("raw_tsv")

local tsv_model = require("tsv_model")

local file_util = require("file_util")
local getParentPath = file_util.getParentPath
local isSamePath = file_util.isSamePath

-- Safe modules to expose in sandbox
local predicates = require("predicates")
local string_utils = require("string_utils")
local table_utils = require("table_utils")
local comparators = require("comparators")

-- File name representing a package manifest.
local MANIFEST_FILENAME = "Manifest.transposed.tsv"

-- Constants for MANIFEST_SPEC key fields (used for error reporting)
local PACKAGE_ID_FIELD = "package_id"
local PACKAGE_ID_TYPE = "package_id"
local CUSTOM_TYPES_FIELD = "custom_types"
local CUSTOM_TYPES_TYPE = "{custom_type_def}|nil"
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
    # Defines the package "dependencies"
    dependencies:{{
        # Defines the "id" of a dependency
        package_id,
        # Defines the package "version requirement" of a dependency
        cmp_version
    }}|nil,
    # Specifies the ids of packages that, if present, must be loaded *before* this package
    load_after:{package_id}|nil,
    # Package-level validators run after all files are loaded
    # Each validator is either a simple expression string (error level) or
    # a structured record {expr:expression, level:error_level|nil}
    package_validators:{validator_spec}|nil
}]]

-- Our own badVal (uses module logger by default)
local BAD_VAL = error_reporting.badValGen()
BAD_VAL.logger = logger

-- We define 'package_id' as an alias to 'name'
parsers.registerAlias(BAD_VAL, "package_id", "name")

local MANIFEST_SPEC_PARSER = parsers.parseType(BAD_VAL, MANIFEST_SPEC)
local FORMATTED_MANIFEST_SPEC = parsers.findParserSpec(MANIFEST_SPEC_PARSER)

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
        return installed_version >= req_version
    elseif req_op == "<" then
        return installed_version < req_version
    elseif req_op == "<=" then
        return installed_version <= req_version
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

    if manifest.dependencies and next(manifest.dependencies) then
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
    if manifest.custom_types and next(manifest.custom_types) then
        manifest.custom_types = readOnly(manifest.custom_types)
    else
        manifest.custom_types = nil
    end
    if manifest.code_libraries and next(manifest.code_libraries) then
        manifest.code_libraries = readOnly(manifest.code_libraries)
    else
        manifest.code_libraries = nil
    end
    if manifest.package_validators and next(manifest.package_validators) then
        manifest.package_validators = readOnly(manifest.package_validators)
    else
        manifest.package_validators = nil
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

    local content, err = file_util.readFile(manifest_file)
    if not content then
        badVal(manifest_file, "Failed to find/read manifest file: " .. err)
        return nil
    end
    raw_files[manifest_file] = content
    content = lua_cog.processContentBV(manifest_file, content, cog_env, badVal)

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
                log:warn("Unknown column '" .. col .. "' in manifest file: " .. manifest_file)
            end
        end
    end
    for _,opt_col in ipairs(parsers.recordOptionalFieldNames(FORMATTED_MANIFEST_SPEC)) do
        found[opt_col] = true
    end
    local cols = parsers.recordFieldNames(FORMATTED_MANIFEST_SPEC)
    for _,col in ipairs(cols) do
        if not found[col] then
            badVal(manifest_file, "Missing column '" .. col .. "' in manifest file")
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
    return error_reporting.withColType(badVal, CUSTOM_TYPES_TYPE, function()
        local custom_types = manifest.custom_types
        if custom_types then
            logger:info("Registering custom types for package " .. manifest.package_id)
            -- Convert the tuple-based format to record-based format for registerTypesFromSpec
            local typeSpecs = {}
            for _, ct in ipairs(custom_types) do
                -- ct is a tuple: {name, parent, min, max, minLen, maxLen, pattern, values, validate, ancestor}
                -- or a record with named fields
                local spec
                if ct.name then
                    -- Already in record format
                    spec = ct
                else
                    -- Tuple format: convert to record
                    spec = {
                        name = ct[1],
                        parent = ct[2],
                        min = ct[3],
                        max = ct[4],
                        minLen = ct[5],
                        maxLen = ct[6],
                        pattern = ct[7],
                        values = ct[8],
                        validate = ct[9],
                        ancestor = ct[10],
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

    -- Create sandboxed environment with safe globals
    local lib_env = {
        -- Lua built-ins
        math = math,
        string = string,
        table = table,
        pairs = pairs,
        ipairs = ipairs,
        type = type,
        tostring = tostring,
        tonumber = tonumber,
        select = select,
        unpack = unpack or table.unpack,
        next = next,
        pcall = pcall,
        error = error,
        assert = assert,

        -- Safe API: All predicates (pure validation functions)
        predicates = predicates,

        -- Safe API: String utilities (pure functions)
        stringUtils = {
            trim = string_utils.trim,
            split = string_utils.split,
            parseVersion = string_utils.parseVersion,
        },

        -- Safe API: Table utilities (read-only inspection)
        tableUtils = {
            keys = table_utils.keys,
            values = table_utils.values,
            pairsCount = table_utils.pairsCount,
            longestMatchingPrefix = table_utils.longestMatchingPrefix,
            sortCaseInsensitive = table_utils.sortCaseInsensitive,
        },

        -- Safe API: Deep equality comparison
        equals = comparators.equals,
    }

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

-- Loads and processes all manifest files, building a dependency graph
local function buildDependencyGraph(badVal, raw_files, manifest_tsv_files, cog_env, manifest_files)
    local graph = {}
    local packages = {}
    local fail = false

    -- Scan and load package metadata
    for _, manifest_file in ipairs(manifest_files) do
        local manifest, manifest_tsv = loadManifestFile(badVal, raw_files, cog_env, manifest_file)
        if manifest then
            packages[manifest.package_id] = manifest
            graph[manifest.package_id] = {}
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

    -- Build dependency graph
    for package_id, manifest in pairs(packages) do
        for _, dep in ipairs(manifest.dependencies or {}) do
            if not packages[dep.package_id] then
                logger:error("Missing dependency: " .. dep.package_id .. " for package " .. package_id)
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
    end

    return graph, packages, fail
end

-- Finds the load order, based on the dependencies graph
local function topologicalSort(graph)
    local result = {}
    local visited = {}
    local recursion_stack = {}

    local function dfs(node, path)
        if recursion_stack[node] then
            logger:error("Circular dependency detected: " .. table.concat(path, " -> ")
                .. " -> " .. node)
            return false
        end

        if not visited[node] then
            visited[node] = true
            recursion_stack[node] = true

            for _, neighbor in ipairs(graph[node]) do
                local new_path = {table.unpack(path)}
                table.insert(new_path, node)
                if not dfs(neighbor, new_path) then
                    return false
                end
            end

            recursion_stack[node] = false
            table.insert(result, node)
        end
        return true
    end

    for node in pairs(graph) do
        if not visited[node] then
            if not dfs(node, {}) then
                return nil
            end
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

-- Loads and processes all manifest files, resolving the package load order
local function resolveDependencies(badVal, raw_files, manifest_tsv_files, cog_env, manifest_files)
    local graph, packages, fail = buildDependencyGraph(badVal, raw_files, manifest_tsv_files,
        cog_env, manifest_files)
    local load_order = topologicalSort(graph)
    fail = checkPackagesDoNotOverlap(packages) or fail
    if fail or not load_order then
        return nil
    end
    return load_order, packages
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
    resolveDependencies = resolveDependencies,
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
