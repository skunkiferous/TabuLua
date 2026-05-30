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

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

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
