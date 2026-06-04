-- Module name
local NAME = "builtin_content_stages"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 22, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local content_pipeline = require("content_pipeline")

local lua_cog = require("lua_cog")

local file_util = require("file_util")
local unixEOL = file_util.unixEOL

-- JSON -> TSV transcoder implementations (one function per layout). This module
-- just registers them as stages; the conversion logic lives in json_transcoders.
local json_transcoders = require("json_transcoders")

-- Codec registry. The decode stage calls compression.decompress("gzip", …)
-- lazily, so the libdeflate rock is only loaded if a .gz is actually processed
-- (see compression.lua). Requiring this module has no side effects and pulls in
-- no compression library.
local compression = require("compression")

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- Cap on a single gzip stage's decompressed output, to bound decompression
-- bombs (a few KB expanding to gigabytes — §3.7). Used both as the stage's
-- declared maxOutputBytes (the dispatcher enforces it as defence-in-depth) and
-- passed to the codec for its cheap up-front ISIZE check.
local GZIP_MAX_OUTPUT_BYTES = 64 * 1024 * 1024

-- ============================================================
-- Built-in content-pipeline stages (mirrors builtin_wiring.lua for the
-- type-wiring registry). Phase 1 registers two text-only stages:
--
--   normalize-eol  the core EOL-normalisation stage. Reads now happen in
--                  binary (§3.4), so the platform-dependent CRLF handling the
--                  C runtime used to do becomes one explicit, testable place.
--                  Runs before the raw_files snapshot, so the stored source
--                  matches the pre-refactor (text-mode-read) bytes.
--
--   cog            COG, as the `macro` stage. Its transform is exactly
--                  lua_cog.processContentBV, whose (name, content, env, badVal)
--                  signature the stage transform mirrors — so COG drops in with
--                  no adaptation. COG is no longer named at the load call sites;
--                  it is just this registered stage.
--
-- Both declare inputKind = "text" so they never run on binary content.
--
-- Phase 2 adds the first `decode` stage: a gzip decompressor that delegates to
-- the compression module (which loads libdeflate lazily, only when a .gz file
-- is actually decoded).
-- ============================================================

content_pipeline.register(NAME, {
    phase = "normalize",
    priority = 100,
    inputKind = "text",
    outputKind = "text",
    matches = function() return true end,   -- every text file
    transform = function(_name, content, _env, _badVal)
        return unixEOL(content)
    end,
})

content_pipeline.register(NAME, {
    phase = "macro",
    priority = 100,
    inputKind = "text",
    outputKind = "text",
    matches = function() return true end,   -- every text file (COG no-ops without markers)
    transform = function(name, content, env, badVal)
        return lua_cog.processContentBV(name, content, env, badVal)
    end,
    -- Sink (export) direction: strip the COG scaffolding so the published copy is
    -- clean, keeping the generated output (content_pipeline.md §3.9). Runs only
    -- when the exporter opts in (exportParams.stripCog); lossy, never written back
    -- over source. needsCog makes it a no-op on files without COG blocks.
    sinkTransform = function(_name, content, _env, _badVal)
        return lua_cog.stripCog(content)
    end,
})

-- gzip decompressor (Phase 2), the first `decode` stage. Matches by the .gz
-- extension OR the gzip magic bytes (so a mislabelled .gz still decodes — §3.2),
-- peels its own extension so the loop re-dispatches on the inner name
-- (data.tsv.gz -> data.tsv), and aborts the file on a corrupt stream, a
-- decompression bomb over the cap, OR an unavailable codec (e.g. libdeflate not
-- installed) — all reported via badVal with a clear reason. The output kind is
-- re-derived from the peeled name by the dispatcher (a .txt.gz becomes text, a
-- .png.gz stays binary), so no outputKind is set here.
content_pipeline.register(NAME, {
    phase = "decode",
    priority = 100,
    extensions = {"gz"},
    magic = "\031\139",                     -- 0x1f 0x8b
    maxOutputBytes = GZIP_MAX_OUTPUT_BYTES,
    -- Reversible (§3.6): the reformatter can rewrite a compressed data source
    -- (data.tsv.gz) by reformatting the decoded TSV and re-gzipping it. `encode`
    -- is the inverse of the gunzip transform — it re-compresses the bytes via the
    -- compression module's gzip/compress provider (pure-Lua, no new dependency).
    -- The reformatter writes the returned bytes back over the original on-disk name.
    reversible = true,
    encode = function(content, _env, _badVal)
        return compression.compress("gzip", content)
    end,
    transform = function(name, content, _env, badVal)
        local data, err = compression.decompress("gzip", content, GZIP_MAX_OUTPUT_BYTES)
        if not data then
            badVal(name, "gzip decode of '" .. name .. "' failed: " .. tostring(err))
            return nil                      -- fatal: drop the file (§3.7-3.8)
        end
        local peeled = (name:gsub("%.[gG][zZ]$", ""))
        if peeled == name then
            -- Magic-matched a file with no .gz extension to peel: return the
            -- bytes with no rename; the dispatcher stops the loop (§7).
            return data
        end
        return data, peeled
    end,
})

-- JSON "object-per-row" transcoder (Phase 3) — the first `transcode` stage and
-- the first *explicitly selected* stage: it has an `id` and no auto-matcher, so
-- it never fires by extension, only when a Files.tsv row names it
-- (transcoder=json:objects). JSON has several tabular layouts that extension
-- matching can't tell apart, so the author chooses per file. The conversion
-- itself lives in json_transcoders.objectsToTSV.
content_pipeline.register(NAME, {
    phase = "transcode",
    id = "json:objects",
    transform = json_transcoders.objectsToTSV,
})

-- json:rows (array-per-row) and json:columns (array-per-column) — the same data
-- in array form, values positional to the schema's sorted field order.
content_pipeline.register(NAME, {
    phase = "transcode",
    id = "json:rows",
    transform = json_transcoders.rowsToTSV,
})

content_pipeline.register(NAME, {
    phase = "transcode",
    id = "json:columns",
    transform = json_transcoders.columnsToTSV,
})

-- Extensions the macro-phase COG scan is eligible to process (cog_markdown.md
-- §2.2-2.3). These are non-data text files that cog_discovery walks for COG
-- blocks; `.tsv`/`.csv` are deliberately excluded (data files are COG-processed
-- on read, so the scan must not double-process them). `.html`/`.xml` work via the
-- HTML-comment marker style (`<!---[[[ … ]]]--->`). NOTE for XML: a COG code line
-- containing "--" makes the source invalid XML (XML forbids "--" in comments);
-- lua_cog.processContentBV reports that as an error for .xml files. Add more here
-- as needed.
-- The XML family (.xml/.xhtml) additionally gets the "no -- in a comment" check
-- in lua_cog.processContentBV.
content_pipeline.registerScanExtensions({"md", "markdown", "html", "txt", "xml", "xhtml"})

-- Snapshot now (built-in stages registered) and restore on global_reset,
-- mirroring how builtin_wiring snapshots the type-wiring registry.
content_pipeline.snapshotState()
local global_reset = require("global_reset")
global_reset.register(content_pipeline.restoreState)

-- ============================================================
-- Public API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
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
