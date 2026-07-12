-- Module name
local NAME = "doc_generator"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 31, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

local logger = require("infra.named_logger").getLogger(NAME)

local content_pipeline = require("content.content_pipeline")
-- Registers the COG macro stage (transform + stripCog sinkTransform) so run /
-- runSink work here even if the exporter is used standalone.
require("content.builtin_content_stages")

local file_util = require("infra.file_util")
local normalizePath = file_util.normalizePath
local getParentPath = file_util.getParentPath
local pathJoin = file_util.pathJoin
local mkdir = file_util.mkdir
local writeFile = file_util.writeFile
local isDir = file_util.isDir

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- Data-driven doc generation (content_pipeline.md §3.10, cog_markdown.md §2.4).
--
-- At export time, COG doc templates (discovered by cog_discovery) are expanded
-- against the fully-loaded dataset and written to the export dir, mirroring the
-- source layout. The template is run through the content pipeline's macro stage
-- (COG) with the load-time env, so a `<!---[[[ … ]]]--->` block can read any
-- dataset; optionally the COG scaffolding is stripped (exportParams.stripCog) for
-- a clean published file. Templates are produced, NEVER TSV-parsed.
-- ============================================================

-- Builds the COG env for doc templates: the load-time env, but with `files`
-- exposing each dataset under BOTH its typeName and its filename (basename), so a
-- template can write files["Item"] or files["Item.tsv"]. Everything else (sandbox
-- globals, code-library exports) is inherited from loadEnv via __index.
local function buildDocEnv(loadEnv, tsv_files)
    local files = {}
    if loadEnv and loadEnv.files then
        for typeName, file in pairs(loadEnv.files) do
            files[typeName] = file
        end
    end
    for path, file in pairs(tsv_files or {}) do
        local base = path:match("[^/\\]+$") or path
        files[base] = file
    end
    return setmetatable({files = files}, {__index = loadEnv or {}})
end

-- Relative path of `filePath` under whichever of `directories` contains it
-- (forward-slash normalized). Falls back to the basename.
local function relativeTo(filePath, directories)
    local nf = normalizePath(filePath)
    if nf then
        for _, d in ipairs(directories) do
            local nd = normalizePath(d)
            if nd and nf:sub(1, #nd + 1) == nd .. "/" then
                return nf:sub(#nd + 2)
            end
        end
    end
    return (filePath:match("[^/\\]+$")) or filePath
end

-- Generates docs from `templates` (a list of template paths) into
-- exportParams.exportDir, mirroring source layout. `cache` is the read cache
-- shared with discovery (so each template is read once). `result` supplies the
-- loaded data (result.loadEnv / result.tsv_files). Returns true on success.
local function generate(templates, cache, result, directories, exportParams, badVal)
    local exportDir = exportParams and exportParams.exportDir
    if not exportDir or not templates or #templates == 0 then
        return true
    end
    cache = cache or file_util.newReadCache()
    local docEnv = buildDocEnv(result and result.loadEnv, result and result.tsv_files)
    local ok = true
    for _, tmpl in ipairs(templates) do
        local content = cache.read(tmpl)
        if content then
            -- Expand COG (run = normalise + macro; no decode/transcode on a doc),
            -- then optionally strip the scaffolding for a clean published file.
            local expanded = content_pipeline.run(tmpl, content, docEnv, badVal)
            if expanded ~= nil then
                if exportParams.stripCog then
                    expanded = (content_pipeline.runSink(tmpl, expanded, docEnv, badVal))
                end
                local outPath = pathJoin(exportDir, relativeTo(tmpl, directories))
                local parent = getParentPath(outPath)
                if parent and not isDir(parent) then
                    local mok, merr = mkdir(parent)
                    if not mok then
                        logger:error("doc_generator: cannot create dir " .. parent
                            .. ": " .. tostring(merr))
                        ok = false
                    end
                end
                local wok, werr = writeFile(outPath, expanded)
                if wok then
                    logger:info("Generated doc: " .. outPath)
                else
                    logger:error("doc_generator: cannot write " .. outPath
                        .. ": " .. tostring(werr))
                    ok = false
                end
            end
        end
    end
    return ok
end

-- Refreshes COG doc templates IN PLACE: each template is expanded against the
-- loaded data and written back over its own source file, KEEPING the COG markers
-- so it stays re-runnable (cog_markdown.md §2.4 in-place mode — the classic `cog`
-- use). Unlike generate(), this never strips and never writes to an export dir;
-- it is the `--cog-docs` build/CI step that keeps a committed README.md current.
-- Idempotent: COG regenerates the same output region, so re-running is a no-op.
local function refreshInPlace(templates, cache, result, badVal)
    if not templates or #templates == 0 then
        return true
    end
    cache = cache or file_util.newReadCache()
    local docEnv = buildDocEnv(result and result.loadEnv, result and result.tsv_files)
    local ok = true
    for _, tmpl in ipairs(templates) do
        local content = cache.read(tmpl)
        if content then
            local expanded = content_pipeline.run(tmpl, content, docEnv, badVal)
            if expanded ~= nil then
                local wok, werr = writeFile(tmpl, expanded)
                if wok then
                    logger:info("Refreshed doc in place: " .. tmpl)
                else
                    logger:error("doc_generator: cannot rewrite " .. tmpl
                        .. ": " .. tostring(werr))
                    ok = false
                end
            end
        end
    end
    return ok
end

-- ============================================================
-- Public API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    generate = generate,
    refreshInPlace = refreshInPlace,
    buildDocEnv = buildDocEnv,
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
