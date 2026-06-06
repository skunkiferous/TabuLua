-- Module name
local NAME = "cog_discovery"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 24, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local lfs = require("lfs")

local content_pipeline = require("content_pipeline")
local lua_cog = require("lua_cog")

local file_util = require("file_util")
local collectFiles = file_util.collectFiles
local getFilesAndDirs = file_util.getFilesAndDirs
local readFileBinary = file_util.readFileBinary
local normalizePath = file_util.normalizePath
local getParentPath = file_util.getParentPath
local isDir = file_util.isDir

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- COG template discovery (cog_markdown.md Part 2).
--
-- Data files are enumerated via Files.tsv; doc/templating files are not. This
-- module auto-scans the same package roots for non-data text files whose
-- extension is COG-scan eligible (content_pipeline.isScanEligible / the set
-- registered by builtin_content_stages) AND that actually contain a COG block
-- (lua_cog.needsCog). The needsCog gate makes the broad scan cheap and safe: a
-- file with no COG block is a one-substring no-op, so dropping a `.md` with a
-- `<!---[[[ … ]]]--->` block anywhere in a package "just works", with no
-- per-file registration. A `.cogignore` marker file opts a directory subtree out.
--
-- To read each template only once, the caller may pass a shared read cache
-- (file_util.newReadCache): discover() checks needsCog through it, and the
-- doc generator later reads the same templates through the same cache (a hit).
-- ============================================================

-- Name of the opt-out marker. A directory that directly contains a file with
-- this name is excluded from the scan, along with everything beneath it.
local COGIGNORE = ".cogignore"

-- True iff `dir` directly contains a .cogignore marker file.
local function hasCogignore(dir)
    return lfs.attributes(dir .. "/" .. COGIGNORE, "mode") == "file"
end

-- Builds the set (normalized path -> true) of directories opted out via a
-- .cogignore marker. Dotfiles are skipped by getFilesAndDirs, so the marker is
-- detected by an explicit stat per directory rather than by the walk.
local function findIgnoredDirs(directories)
    local ignored = {}
    for _, root in ipairs(directories) do
        if root and root ~= "" and isDir(root) then
            local norm = normalizePath(root)
            if norm then
                if hasCogignore(norm) then ignored[norm] = true end
                local _files, dirs = getFilesAndDirs(root, true)
                if dirs then
                    for _, d in ipairs(dirs) do
                        local dn = normalizePath(d)
                        if dn and hasCogignore(dn) then ignored[dn] = true end
                    end
                end
            end
        end
    end
    return ignored
end

-- True if `filePath` lives in, or anywhere beneath, an ignored directory.
local function isUnderIgnored(filePath, ignored)
    if next(ignored) == nil then return false end
    local dir = getParentPath(normalizePath(filePath))
    while dir and dir ~= "" do
        if ignored[dir] then return true end
        local parent = getParentPath(dir)
        if parent == dir then break end
        dir = parent
    end
    return false
end

-- Discovers COG templates under `directories`: files whose extension is COG-scan
-- eligible AND that contain a COG block, excluding anything under a .cogignore'd
-- directory (or under opt_excludeDirs, e.g. the export dir). Returns a sorted
-- list of file paths. `.tsv`/`.csv` are never eligible, so data files are never
-- double-processed. `opt_cache` (file_util.newReadCache) lets the caller share
-- the file reads with a later pass (the doc generator).
local function discover(directories, opt_excludeDirs, opt_cache)
    if type(directories) ~= "table" then
        error("cog_discovery.discover: directories must be a table", 2)
    end
    local exts = content_pipeline.scanExtensions()
    if #exts == 0 then return {} end

    local read = (opt_cache and opt_cache.read) or readFileBinary
    local files = collectFiles(directories, exts, nil, nil, opt_excludeDirs)
    local ignored = findIgnoredDirs(directories)

    local out = {}
    for _, f in ipairs(files) do
        if not isUnderIgnored(f, ignored) then
            local content = read(f)
            if content and lua_cog.needsCog(content) then
                out[#out + 1] = f
            end
        end
    end
    table.sort(out)
    return out
end

-- ============================================================
-- Public API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    discover = discover,
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
