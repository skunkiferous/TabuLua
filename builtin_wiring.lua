-- Module name
local NAME = "builtin_wiring"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 20, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local logger = require("named_logger").getLogger(NAME)

local error_reporting = require("error_reporting")
local nullBadVal = error_reporting.nullBadVal

local parsers = require("parsers")

local type_wiring = require("type_wiring")

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- Built-in onLoad handlers
--
-- Each handler runs inside manifest_loader's per-file load loop, *before
-- subsequent files parse*, so any parsers/aliases/types it registers are
-- visible to siblings in the same package.
--
-- Before the type-wiring refactor, these lived inline in manifest_loader
-- as three named functions (registerEnumParser, registerAliases,
-- registerCustomTypesFromFile) plus three "is X in extends chain?"
-- walkers that picked which one ran. The walkers are gone; the registry
-- picks now. The handler bodies are otherwise unchanged.
--
-- Signature: (file, fileType, extends, badVal, loadEnv).
-- ============================================================

local function onLoadEnum(file, fileType, extends, badVal, loadEnv)
    if not fileType then return end
    if file[1][1].value ~= "name:identifier" then
        badVal.line_no = 1
        badVal.col_idx = 1
        badVal.row_key = file[1][1].value
        local file_name = file[1].__source
        badVal(file[1][1].value, "First column of ENUM " .. file_name ..
            " should be a name:identifier")
    end
    local labels = {}
    for i, row in ipairs(file) do
        if i > 1 and type(row) == "table" then
            labels[#labels + 1] = row[1].reformatted
        end
    end
    parsers.registerEnumParser(badVal, labels, fileType)
end

local function onLoadType(file, fileType, extends, badVal, loadEnv)
    local defaultSuperType = extends[fileType]
    while defaultSuperType and #defaultSuperType > 0 and
        parsers.parseType(nullBadVal, defaultSuperType, false) == nil do
        defaultSuperType = extends[defaultSuperType]
    end
    if defaultSuperType ~= extends[fileType] then
        logger:info("Default superType for " .. fileType .. " is " ..
            tostring(defaultSuperType))
    end
    for i, line in ipairs(file) do
        if i > 1 and type(line) == "table" then
            badVal.line_no = i
            badVal.col_name = 'name'
            badVal.col_idx = 1
            badVal.row_key = line[1].reformatted
            local type_name = line['name'].reformatted
            local st = line['superType']
            -- All types in the file may have no superType, so the column may be absent.
            local superType = defaultSuperType
            if st ~= nil then
                superType = st.reformatted
            end
            if superType and #superType > 0 then
                if parsers.isBuiltInType(type_name) then
                    logger:warn(type_name .. " is a built-in type, and cannot be aliased to " .. superType)
                elseif not parsers.registerAlias(badVal, type_name, superType) then
                    logger:error("Failed to register alias " .. type_name .. " for " .. superType)
                end
            end
        end
    end
end

-- The fields of custom_type_def extracted from each row for type registration.
local CUSTOM_TYPE_DEF_FIELDS = {
    'name', 'parent', 'min', 'max', 'minLen', 'maxLen',
    'members', 'pattern', 'tags', 'validate', 'values'
}

local function onLoadCustomTypeDef(file, fileType, extends, badVal, loadEnv)
    -- Build inherited defaults by walking the ancestor chain for columns
    -- that are entirely missing from this file's header.
    local header = file[1]
    local inherited_defaults = {}
    local ancestor = fileType
    local loadedFiles = (loadEnv and loadEnv.files) or {}
    while ancestor and extends[ancestor] do
        ancestor = extends[ancestor]
        local ancestor_file = loadedFiles[ancestor]
        if ancestor_file then
            local ancestor_header = ancestor_file[1]
            for _, field in ipairs(CUSTOM_TYPE_DEF_FIELDS) do
                if not inherited_defaults[field] and not header[field] then
                    local col = ancestor_header[field]
                    if col and col.default_expr then
                        inherited_defaults[field] = col.default_expr
                    end
                end
            end
        end
    end

    for i, row in ipairs(file) do
        if i > 1 and type(row) == "table" then
            local spec = {}
            for _, field in ipairs(CUSTOM_TYPE_DEF_FIELDS) do
                local cell = row[field]
                if cell ~= nil then
                    spec[field] = cell.parsed
                elseif inherited_defaults[field] then
                    spec[field] = inherited_defaults[field]
                end
            end
            badVal.line_no = i
            badVal.row_key = row[1].reformatted
            parsers.registerTypesFromSpec(badVal, {spec})
        end
    end
end

-- ============================================================
-- Register the built-in wirings.
--
-- The registry's lookup is case-insensitive; keys mirror the canonical
-- typeName casing as it appears in built-in registration.
-- ============================================================

type_wiring.register("Type", {onLoad = onLoadType})
type_wiring.register("enum", {onLoad = onLoadEnum})
type_wiring.register("custom_type_def", {onLoad = onLoadCustomTypeDef})

-- Snapshot the registry now (built-ins registered) and arrange restoration
-- on global_reset.reset(), mirroring how parsers.lua handles built-in types.
type_wiring.snapshotState()
local global_reset = require("global_reset")
global_reset.register(type_wiring.restoreState)

-- ============================================================
-- Public API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    -- Exposed for tests / debugging.
    onLoadEnum = onLoadEnum,
    onLoadType = onLoadType,
    onLoadCustomTypeDef = onLoadCustomTypeDef,
}

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
