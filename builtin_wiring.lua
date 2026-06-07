-- Module name
local NAME = "builtin_wiring"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 25, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local logger = require("named_logger").getLogger(NAME)

local error_reporting = require("error_reporting")
local nullBadVal = error_reporting.nullBadVal

local parsers = require("parsers")

local graph_helpers = require("graph_helpers")
local splitEdgeKey = graph_helpers.splitEdgeKey

local graph_wiring = require("graph_wiring")
local detectFamily = graph_wiring.detectFamily
local detectEdgeFamily = graph_wiring.detectEdgeFamily

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


-- onLoad handler for files whose typeName is (or extends) `type_wiring_def`.
-- Each data row becomes one type_wiring.register call. typeName names the
-- target type; the three spec-list columns flow straight into the
-- corresponding per-typeName slots. Unknown typeNames register harmlessly —
-- the cascade dispatcher only fires the contributions when a file's
-- extends chain reaches a registered name.
local function onLoadTypeWiringDef(file, fileType, extends, badVal, loadEnv)
    for i, row in ipairs(file) do
        if i > 1 and type(row) == "table" then
            local typeNameCell = row["typeName"]
            local typeName = typeNameCell and typeNameCell.parsed
            if typeName and typeName ~= '' then
                local contributions = {}
                local function pickList(field)
                    local cell = row[field]
                    local v = cell and cell.parsed
                    if type(v) == "table" and #v > 0 then
                        contributions[field] = v
                    end
                end
                pickList("preProcessors")
                pickList("rowValidators")
                pickList("fileValidators")
                if next(contributions) then
                    badVal.line_no = i
                    badVal.row_key = typeName
                    local ok, err = pcall(type_wiring.register, typeName, contributions)
                    if not ok then
                        badVal(typeName, "type_wiring_def: register failed: "
                            .. tostring(err))
                    end
                end
            end
        end
    end
end

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

-- type_wiring_def — built-in record type for user-package "wiring files".
-- A file declaring `typeName=type_wiring_def` (or extending it) has its
-- rows dispatched as type_wiring.register(...) calls by the cascade
-- dispatcher; no hard-coded filename detection is needed. Convention is
-- to call such files TypeWiring.tsv, but the engine recognises them by
-- record type rather than basename.
parsers.registerAlias(nullBadVal, 'type_wiring_def',
    '{fileValidators:{validator_spec}|nil,preProcessors:{processor_spec}|nil,'
    .. 'rowValidators:{validator_spec}|nil,typeName:name}')
type_wiring.register("type_wiring_def", {onLoad = onLoadTypeWiringDef})

-- ============================================================
-- Module-level: re-declare the ten optional Files.tsv columns that
-- used to be hard-coded in files_desc.lua. After the L4 shrink, only
-- the six intrinsic core columns (fileName, typeName, superType,
-- baseType, loadOrder, description) are hard-coded in files_desc.lua;
-- everything else lives here under the feature module that uses it.
--
-- The fieldOnMeta values match the existing keys in joinMeta so
-- downstream consumers (exporter, manifest_loader, etc.) keep working
-- unchanged.
-- ============================================================

-- Normalisers used by descriptor-column declarations: every column the
-- engine treats as "empty string === absent" goes through nilIfEmpty;
-- the joinInto column additionally lowercases (basename matching is
-- case-insensitive).
local function nilIfEmpty(v)
    if v == nil or v == "" then return nil end
    return v
end

local function lowerOrNil(v)
    if v == nil or v == "" then return nil end
    return v:lower()
end

-- For list-typed columns (rowValidators/fileValidators/preProcessors):
-- empty table is treated as absent so consumers can iterate with ipairs
-- safely (the previous hand-written code had the same `#v > 0` guard).
local function listOrNil(v)
    if type(v) ~= "table" or #v == 0 then return nil end
    return v
end

type_wiring.registerModule("publish", {
    descriptorColumns = {
        {name = "publishContext", type = "name|nil",
         fieldOnMeta = "lcFn2Ctx",            parse = nilIfEmpty},
        {name = "publishColumn",  type = "name|nil",
         fieldOnMeta = "lcFn2Col",            parse = nilIfEmpty},
    },
})

type_wiring.registerModule("file_joining", {
    descriptorColumns = {
        {name = "joinInto",       type = "filepath|nil",
         fieldOnMeta = "lcFn2JoinInto",       parse = lowerOrNil},
        {name = "joinColumn",     type = "name|nil",
         fieldOnMeta = "lcFn2JoinColumn",     parse = nilIfEmpty},
        {name = "export",         type = "boolean|nil",
         fieldOnMeta = "lcFn2Export",         parse = nilIfEmpty},
        {name = "joinedTypeName", type = "type_spec|nil",
         fieldOnMeta = "lcFn2JoinedTypeName", parse = nilIfEmpty},
    },
})

type_wiring.registerModule("variants", {
    descriptorColumns = {
        {name = "variant", type = "name|nil",
         fieldOnMeta = "lcFn2Variant",        parse = nilIfEmpty},
    },
})

type_wiring.registerModule("validators", {
    descriptorColumns = {
        {name = "rowValidators",  type = "{validator_spec}|nil",
         fieldOnMeta = "lcFn2RowValidators",  parse = listOrNil},
        {name = "fileValidators", type = "{validator_spec}|nil",
         fieldOnMeta = "lcFn2FileValidators", parse = listOrNil},
    },
})

type_wiring.registerModule("pre_processors", {
    descriptorColumns = {
        {name = "preProcessors", type = "{processor_spec}|nil",
         fieldOnMeta = "lcFn2PreProcessors",  parse = listOrNil},
    },
})

-- Content-pipeline transcoder selection (see TODO/content_pipeline.md Phase 3).
-- A non-data text/binary file (e.g. a .json) is normally copied through as an
-- asset; setting `transcoder` to a registered transcoder id (e.g. json:objects)
-- instead routes it through the content pipeline to be converted to TSV and
-- parsed as data of its `typeName`. The value is a free-form id (it may contain
-- ':'), so it is typed `string|nil` rather than `name|nil`.
type_wiring.registerModule("content_pipeline", {
    descriptorColumns = {
        {name = "transcoder", type = "string|nil",
         fieldOnMeta = "lcFn2Transcoder",     parse = nilIfEmpty},
    },
})

-- ============================================================
-- Graph wiring (Phase 2b)
--
-- Owns the edgesFor descriptor column, the enginePostPasses entry for
-- edge↔node consistency, and the per-typeName completion/validation
-- bundles for the three graph node families. Sandbox helpers
-- (completeBasicGraph etc.) are registered by processor_executor and
-- validator_executor themselves — see the comments there. Splitting
-- registrations across modules avoids a circular dependency between
-- builtin_wiring and processor_executor.
-- ============================================================

-- Returns the parsed value of a row's cell by column name. Falls back to
-- evaluated/value if `parsed` is absent (older cells). Used by the edge
-- file validator below.
local function cellValue(row, header, colName)
    local col = header[colName]
    if not col then return nil end
    local cell = row[col.idx]
    if not cell then return nil end
    if cell.parsed ~= nil then return cell.parsed end
    return cell.evaluated
end

-- True if `list` contains `value`. Handles nil lists.
local function listContains(list, value)
    if list == nil then return false end
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

-- enginePostPasses callback for edge↔node consistency. Same algorithm as
-- the pre-refactor graph_wiring.validateEdgeFiles, just reshaped to the
-- registry's (tsv_files, joinMeta, badVal) signature.
local function validateEdgeFilesPass(tsv_files, joinMeta, badVal)
    local lcFn2EdgesFor = joinMeta.lcFn2EdgesFor or {}
    local lcFn2Type = joinMeta.lcFn2Type or {}
    local extendsMap = joinMeta.extends or {}

    if next(lcFn2EdgesFor) == nil then
        return true -- no edge files declared
    end

    -- Build a reverse index from lcfn -> full file_name (the tsv_files key).
    local lcfnToFileName = {}
    for file_name in pairs(tsv_files) do
        local lcfn = file_name:match("[/\\]([^/\\]+)$") or file_name
        lcfnToFileName[lcfn:lower()] = file_name
    end

    -- Detect collisions: at most one edge file per node file.
    local nodeToEdge = {}
    local ok = true
    for edgeLcfn, nodeLcfn in pairs(lcFn2EdgesFor) do
        local existing = nodeToEdge[nodeLcfn]
        if existing then
            badVal.source_name = lcfnToFileName[edgeLcfn] or edgeLcfn
            badVal(edgeLcfn, "node file '" .. nodeLcfn
                .. "' already has an edge file: '" .. existing
                .. "'. A node file may have at most one edge file.")
            ok = false
        else
            nodeToEdge[nodeLcfn] = edgeLcfn
        end
    end

    -- Per-edge-file checks.
    for edgeLcfn, nodeLcfn in pairs(lcFn2EdgesFor) do
        local edgeFileName = lcfnToFileName[edgeLcfn]
        local nodeFileName = lcfnToFileName[nodeLcfn]
        if not edgeFileName then
            -- Edge file declared in Files.tsv but not present on disk;
            -- reported separately by the loader's existence check.
            ok = false
        elseif not nodeFileName then
            badVal.source_name = edgeFileName
            badVal(edgeLcfn, "edgesFor target '" .. nodeLcfn
                .. "' does not exist (must match an entry in fileName)")
            ok = false
        else
            local edgeRole = detectEdgeFamily(lcFn2Type[edgeLcfn], extendsMap)
            local nodeRole = detectFamily(lcFn2Type[nodeLcfn], extendsMap)
            if not edgeRole then
                badVal.source_name = edgeFileName
                badVal(edgeLcfn, "file declares 'edgesFor' but its typeName '"
                    .. tostring(lcFn2Type[edgeLcfn])
                    .. "' does not extend any edge family"
                    .. " (basic_graph_edge / graph_edge / tree_edge)")
                ok = false
            elseif not nodeRole then
                badVal.source_name = edgeFileName
                badVal(edgeLcfn, "edgesFor target '" .. nodeLcfn
                    .. "' has typeName '" .. tostring(lcFn2Type[nodeLcfn])
                    .. "' which does not extend any node family"
                    .. " (basic_graph_node / graph_node / tree_node)")
                ok = false
            elseif edgeRole ~= nodeRole then
                badVal.source_name = edgeFileName
                badVal(edgeLcfn, "edge family mismatch: edge file is '"
                    .. edgeRole .. "' but node file is '" .. nodeRole
                    .. "' (basic edges only pair with basic node files,"
                    .. " directed edges with directed node files)")
                ok = false
            else
                -- Endpoint and link-consistency checks.
                local nodeTsv = tsv_files[nodeFileName]
                local nodeHeader = nodeTsv[1]
                local edgeTsv = tsv_files[edgeFileName]
                local edgeHeader = edgeTsv[1]
                local linkField = (nodeRole == "basic")
                    and "graphLinks" or "graphChildren"
                badVal.source_name = edgeFileName
                for i = 2, #edgeTsv do
                    local row = edgeTsv[i]
                    if type(row) == "table" then
                        local key = cellValue(row, edgeHeader, "name")
                        if type(key) == "string" then
                            local a, b = splitEdgeKey(key)
                            if a and b then
                                local rowA = nodeTsv[a]
                                local rowB = nodeTsv[b]
                                if not rowA then
                                    badVal(key, "edge endpoint '" .. a
                                        .. "' is not a row in '"
                                        .. nodeLcfn .. "'")
                                    ok = false
                                end
                                if not rowB then
                                    badVal(key, "edge endpoint '" .. b
                                        .. "' is not a row in '"
                                        .. nodeLcfn .. "'")
                                    ok = false
                                end
                                if rowA and rowB then
                                    local aLinks = cellValue(rowA, nodeHeader, linkField)
                                    if not listContains(aLinks, b) then
                                        badVal(key,
                                            "edge has no matching link in '"
                                            .. nodeLcfn .. "': '" .. a
                                            .. "." .. linkField
                                            .. "' does not contain '" .. b
                                            .. "'")
                                        ok = false
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return ok
end

-- Graph wiring's contributions: descriptorColumn (edgesFor), enginePostPass
-- (edge↔node consistency). Sandbox helpers are added by processor_executor
-- and validator_executor — they self-register to avoid the circular
-- dependency a centralised registration would create here.
type_wiring.registerModule("graph_wiring", {
    descriptorColumns = {
        {name = "edgesFor", type = "filepath|nil",
         fieldOnMeta = "lcFn2EdgesFor",       parse = lowerOrNil},
    },
    enginePostPasses = {validateEdgeFilesPass},
})

-- Per-typeName completion + validator bundles for the three graph node
-- families. We register the FULL bundle per leaf (per-leaf flattening,
-- option (a) under "Parser-alias dispatch" in TODO/type_wiring.md L5)
-- because tree_node is a parser-alias of graph_node and `extends`
-- doesn't follow parser-alias links — so the cascade walker stops at
-- "tree_node" and never reaches "graph_node"'s contributions.
--
-- priority=50 puts completion ahead of the default user processor
-- priority of 100; rerunAfterPatches=true so cross-package mod patches
-- re-symmetrise the link fields before validators see them.
local BASIC_COMPLETION = {
    expr = "completeBasicGraph(rows)",
    priority = 50,
    rerunAfterPatches = true,
    level = "error",
}
local DIRECTED_COMPLETION = {
    expr = "completeDirectedGraph(rows)",
    priority = 50,
    rerunAfterPatches = true,
    level = "error",
}

type_wiring.register("basic_graph_node", {
    preProcessors  = {BASIC_COMPLETION},
    fileValidators = {
        {expr = "graphRefsExist(rows, 'basic')", level = "error"},
    },
})

type_wiring.register("graph_node", {
    preProcessors  = {DIRECTED_COMPLETION},
    fileValidators = {
        {expr = "graphRefsExist(rows, 'directed')", level = "error"},
        {expr = "graphAcyclic(rows)",               level = "error"},
    },
})

type_wiring.register("tree_node", {
    preProcessors  = {DIRECTED_COMPLETION},
    fileValidators = {
        {expr = "graphRefsExist(rows, 'directed')", level = "error"},
        {expr = "graphAcyclic(rows)",               level = "error"},
        {expr = "graphTreeShape(rows)",             level = "error"},
    },
})

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
    onLoadTypeWiringDef = onLoadTypeWiringDef,
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
