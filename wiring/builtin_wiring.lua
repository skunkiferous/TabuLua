-- Module name
local NAME = "builtin_wiring"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 32, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

local logger = require("infra.named_logger").getLogger(NAME)

local error_reporting = require("infra.error_reporting")
local nullBadVal = error_reporting.nullBadVal
local didYouMean = error_reporting.didYouMean

local parsers = require("parsers")

local graph_helpers = require("wiring.graph_helpers")
local splitEdgeKey = graph_helpers.splitEdgeKey

local graph_wiring = require("wiring.graph_wiring")
local detectFamily = graph_wiring.detectFamily
local detectEdgeFamily = graph_wiring.detectEdgeFamily

local type_wiring = require("wiring.type_wiring")

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
    'members', 'pattern', 'shape', 'tags', 'validate', 'values'
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

-- SchemaOverlay — built-in record type for schema overlay files.
-- A file declaring `typeName=SchemaOverlay`
-- (or extending it) and `schemaOverlayOf=Target.tsv` in Files.tsv loosens
-- the target file's column metadata: override a column default, widen a
-- column type, or downgrade/suppress a parent validator. Each data row
-- targets one column (or one validator). The rows are consumed by
-- schema_overlay.collectOverlays in a pre-parse pass — there is no onLoad,
-- registering the alias here only marks the typeName as known so the loader
-- skips trying to register it as a record type from each overlay file's
-- (possibly partial) header.
--
-- `validatorLevel` uses a dedicated enum `overlay_level` rather than the
-- existing `error_level` because it adds a `none` member meaning "remove the
-- validator entirely" (error_level is {error,warn} and is reused by
-- validator_spec, so it must not gain a third member).
parsers.registerEnumParser(nullBadVal, {"error", "warn", "none"}, "overlay_level")
parsers.registerAlias(nullBadVal, 'SchemaOverlay',
    '{column:name,newDefault:string|nil,widenTo:type_spec|nil,'
    .. 'suppressValidator:expression|nil,validatorLevel:overlay_level|nil}')

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

-- `joinInto` names a file by PATH and is matched exactly (not by basename, as the
-- override-target columns are), so it is `relativePath`: resolved against the
-- directory of the Files.tsv it appears in, exactly like `fileName`. That is what
-- lets a package be relocated — dropped into a subdirectory of a bigger one —
-- without editing its Files.tsv.
type_wiring.registerModule("file_joining", {
    descriptorColumns = {
        {name = "joinInto",       type = "filepath|nil", relativePath = true,
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

-- The `since` on each column below is the release that first accepted it, and
-- feeds `--list-columns` (see validateColumnDecl). The columns declared ABOVE
-- carry none: they predate the CHANGELOG's useful range, so there is no honest
-- version to name — and nobody needs to "discover" joinInto anyway.

-- Conditional file loading for optional mod compatibility
-- (TODO/mod_ecosystem.md §2.1). A Files.tsv row listing package ids in
-- `onlyIfPackages` is active only when EVERY listed package is loaded (AND);
-- otherwise the row is skipped exactly like a variant-filtered row — the file
-- is not parsed, not exported, and exempt from the on-disk existence check.
-- This lets a mod ship a patch / overlay / data file that targets another mod
-- and quietly deactivates when that mod is absent. The gating itself runs in
-- files_desc.processFilesDesc (same spot as `variant`); the column registers
-- here so header recognition and the joinMeta map lifecycle stay
-- registry-driven. (`package_id` is the manifest alias for `name`.)
type_wiring.registerModule("package_gating", {
    descriptorColumns = {
        {name = "onlyIfPackages", type = "{package_id}|nil", since = "0.30.0",
         fieldOnMeta = "lcFn2OnlyIfPackages", parse = listOrNil},
    },
})

type_wiring.registerModule("validators", {
    descriptorColumns = {
        {name = "rowValidators",  type = "{validator_spec}|nil", since = "0.5.0",
         fieldOnMeta = "lcFn2RowValidators",  parse = listOrNil},
        {name = "fileValidators", type = "{validator_spec}|nil", since = "0.5.0",
         fieldOnMeta = "lcFn2FileValidators", parse = listOrNil},
    },
})

type_wiring.registerModule("pre_processors", {
    descriptorColumns = {
        {name = "preProcessors", type = "{processor_spec}|nil", since = "0.19.0",
         fieldOnMeta = "lcFn2PreProcessors",  parse = listOrNil},
    },
})

-- Mod-style schema overlay selection. A file with `schemaOverlayOf` set (and typeName=SchemaOverlay) targets a
-- parent file by basename — same lookup convention as joinInto / edgesFor —
-- and loosens that file's column metadata before its cells are parsed. The
-- value lowercases for case-insensitive basename matching.
-- The three override target columns accept an alternative declared type,
-- `override_target|nil`, which additionally allows a 'package.id:' qualifier
-- ("some.pkg:Item.tsv") binding the target to one package's file when two
-- packages ship the same file name (TODO/mod_ecosystem.md §4). The default
-- `filepath|nil` spelling stays valid for unqualified targets (':' does not
-- parse as part of a filepath, which is also why the qualifier is unambiguous).
type_wiring.registerModule("schema_overlay", {
    descriptorColumns = {
        {name = "schemaOverlayOf", type = "filepath|nil", since = "0.28.0",
         altTypes = {"override_target|nil"},
         fieldOnMeta = "lcFn2SchemaOverlayOf", parse = lowerOrNil},
    },
})

-- Mod-style row patches. A file with
-- `typeName=patch` and `patchOf=Target.tsv` declares add / remove / update /
-- replace operations against a parent file's rows. `patchOf` targets the parent
-- by basename (same convention as joinInto / schemaOverlayOf). `patch_op` is the
-- enum of operations carried by the patch file's `patchOp` column.
parsers.registerEnumParser(nullBadVal, {"add", "remove", "update", "replace"}, "patch_op")
-- `missing_policy` is the enum for the `ifMissing` column below.
parsers.registerEnumParser(nullBadVal, {"error", "silent", "warn"}, "missing_policy")
type_wiring.registerModule("row_patch", {
    descriptorColumns = {
        {name = "patchOf", type = "filepath|nil", since = "0.28.0",
         altTypes = {"override_target|nil"},
         fieldOnMeta = "lcFn2PatchOf", parse = lowerOrNil},
        -- Bulk filter/transform patches: a file
        -- with `typeName=bulk_patch` and `bulkPatchOf=Target.tsv` selects parent
        -- rows by a `where` expression and updates/removes the matches.
        {name = "bulkPatchOf", type = "filepath|nil", since = "0.28.0",
         altTypes = {"override_target|nil"},
         fieldOnMeta = "lcFn2BulkPatchOf", parse = lowerOrNil},
        -- Missing-target tolerance for multi-version compat patches
        -- (mod_ecosystem §6), per override FILE: what to do when a patched key
        -- (update / replace_oldvalue_ / list-remove_ value) or the whole target
        -- file is not there — error (the default, today's severities), warn
        -- (logged no-op), or silent. `add` on an EXISTING key stays an error
        -- always (that is a collision, not a version gap), and `replace` never
        -- needed tolerance (a missing key appends — upsert).
        {name = "ifMissing", type = "missing_policy|nil", since = "0.30.0",
         fieldOnMeta = "lcFn2IfMissing", parse = lowerOrNil},
    },
})
-- `patch` is a reserved typeName keyword, not a row record type: it marks a file
-- as a patch document so the loader does not try to register its (subset) header
-- as a record type or validate its rows against a parent row type. Registering it
-- as an alias to the empty record makes `typeName=patch` parse as a type_spec and
-- makes parsers.parseType("patch") truthy, so registerFileType skips it just like
-- any already-known type. The patch file's own cells are still parsed against its
-- own header column types.
parsers.registerAlias(nullBadVal, 'patch', '{}')

-- `bulk_patch` is the reserved typeName keyword for bulk filter/transform patch
-- files. Like `patch`, it is aliased to the empty record so
-- it parses as a type_spec and registerFileType auto-skips it. A bulk_patch file's
-- column 1 is a unique RULE NAME, a `where:expression` column selects parent rows,
-- and the remaining columns transform (or, with patchOp=remove, drop) the matches.
-- The file is parsed with cell-evaluation DISABLED (see manifest_loader) so its
-- `=expr` transform/where cells survive as raw strings, evaluated at apply time
-- against the matched TARGET row rather than at load against the rule row.
parsers.registerAlias(nullBadVal, 'bulk_patch', '{}')

-- ============================================================
-- Engine ROLE typeNames (TODO/non_table_files.md Phase 3)
--
-- Every name below is a word a Files.tsv row uses to say what the engine should DO
-- with a file — parse its rows as type definitions, apply it as a patch, copy it as
-- an asset, ignore it — rather than the name of the record type the file's rows ARE.
--
-- Two checks in files_desc are about TABLE types, and are category errors when
-- applied to a role:
--
--   * "typeName 'X' should match fileName 'Y' without extension" — a role is not
--     named after its file. `ui/theme.json` declared `asset_file` is correct, and
--     three files can all be `asset_file`.
--   * "Multiple types with name 'X'" — several files legitimately share a role. A
--     package with three patches is not declaring the type `patch` three times.
--
-- Both fired on every role typeName, which is why a clean tutorial run has been
-- emitting eight warnings a user can do nothing about. Marking the role here fixes
-- the whole class at once, and a user type joining a role tag (`tags=IgnoredFile`)
-- keeps its own name and its own checks, as it should.
-- ============================================================
for _, roleName in ipairs({
    "asset_file",       -- the file is an asset: not a table (AssetFile tag)
    "MigrationScript",  -- the file is a migration script: not loaded (IgnoredFile tag)
    "patch",            -- the file's rows patch another file's rows
    "bulk_patch",       -- ...ditto, by filter/transform rule
    "SchemaOverlay",    -- the file's rows loosen another file's column metadata
    "custom_type_def",  -- the file's rows DEFINE types
    "type_wiring_def",  -- ...and its rows wire behaviour onto them
    "Type",             -- the file's rows define types (the original two)
    "enum",
    "files",            -- Files.tsv itself: the descriptor, not a table
}) do
    type_wiring.register(roleName, {role = true})
end

-- Content-pipeline transcoder selection (see TODO/content_pipeline.md Phase 3).
-- A non-data text/binary file (e.g. a .json) is normally copied through as an
-- asset; setting `transcoder` to a registered transcoder id (e.g. json:objects)
-- instead routes it through the content pipeline to be converted to TSV and
-- parsed as data of its `typeName`. The value is a free-form id (it may contain
-- ':'), so it is typed `string|nil` rather than `name|nil`.
type_wiring.registerModule("content_pipeline", {
    descriptorColumns = {
        {name = "transcoder", type = "string|nil", since = "0.22.0",
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
            local knownFiles = {}
            for _, fn in pairs(lcfnToFileName) do knownFiles[#knownFiles + 1] = fn end
            badVal(edgeLcfn, "edgesFor target '" .. nodeLcfn
                .. "' does not exist (must match an entry in fileName)"
                .. didYouMean(nodeLcfn, knownFiles))
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
        -- Like joinInto, `edgesFor` names its node file by PATH and is matched
        -- exactly, so it too resolves relative to its Files.tsv's directory.
        {name = "edgesFor", type = "filepath|nil", relativePath = true, since = "0.20.0",
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
local global_reset = require("util.global_reset")
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
