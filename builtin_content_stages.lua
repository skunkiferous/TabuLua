-- Module name
local NAME = "builtin_content_stages"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 21, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local content_pipeline = require("content_pipeline")

local lua_cog = require("lua_cog")

local file_util = require("file_util")
local unixEOL = file_util.unixEOL

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
