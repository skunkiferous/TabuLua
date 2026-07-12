-- glob.lua
--
-- Path glob matching, for the manifest's `asset_files` / `ignored_files` lists
-- (TODO/non_table_files.md Phase 2). Deliberately small: a package needs to name
-- FILES in bulk ("every .tmp.tsv", "everything under scratch/"), not to express
-- arbitrary patterns.
--
-- Syntax
--   *    any run of characters WITHIN one path segment (never crosses "/")
--   **   any run of path segments, including none ("scratch/**" matches
--        "scratch/a.tsv" and "scratch/deep/b.tsv")
--   ?    exactly one character, within one segment
--
-- A glob with NO "/" in it matches by BASENAME, at any depth: "*.tmp.tsv" catches
-- "x.tmp.tsv" and "sub/deep/x.tmp.tsv" alike. This is the gitignore rule, and it
-- is what a package author writing "*.tmp.tsv" means — a temp file is a temp file
-- wherever it sits. A glob WITH a "/" is anchored to the package root and matched
-- against the whole relative path, so "scratch/**" ignores that one directory and
-- not a "scratch" nested somewhere else.
--
-- Matching is case-insensitive, matching how the loader keys files.
--
-- (content_pipeline has a globToPattern of its own, but it matches BASENAMES only
-- and its "*" happily crosses "/", which is exactly the semantics a path glob must
-- not have. Sharing it would make one of the two wrong.)

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 30, 0)

-- Module name
local NAME = "glob"

local readOnly = require("util.read_only").readOnly

--- Returns the module version as a string.
--- @return string The semantic version string
local function getVersion()
    return tostring(VERSION)
end

-- Lua-pattern magic characters that must be escaped to match literally. "*" and
-- "?" are absent on purpose: they are the glob metacharacters, handled below.
local MAGIC = "[%^%$%(%)%%%.%[%]%+%-]"

-- Compiles ONE path segment's glob into an anchored Lua pattern. A segment never
-- contains "/", so "*" and "?" are bounded by the segment on both sides.
local function segmentPattern(segment)
    local pat = segment:gsub(MAGIC, "%%%0")
    pat = pat:gsub("%*", "[^/]*")
    pat = pat:gsub("%?", "[^/]")
    return "^" .. pat .. "$"
end

-- Splits a path (or glob) on "/" into its segments.
local function split(path)
    local segments = {}
    for segment in path:gmatch("[^/]+") do
        segments[#segments + 1] = segment
    end
    return segments
end

-- Matches globSegs[gi..] against pathSegs[pi..].
--
-- "**" is the only segment that can consume more (or fewer) than one path
-- segment, so it is the only one that needs to branch: it tries every possible
-- number of segments — including zero, which is what lets "**/x.tsv" match a
-- root-level "x.tsv" — and succeeds if any of them lets the REST of the glob
-- match. Everything else is a straight segment-by-segment walk.
local function matchFrom(globSegs, gi, pathSegs, pi)
    if gi > #globSegs then
        return pi > #pathSegs
    end
    local seg = globSegs[gi]
    if seg == "**" then
        for k = pi, #pathSegs + 1 do
            if matchFrom(globSegs, gi + 1, pathSegs, k) then
                return true
            end
        end
        return false
    end
    if pi > #pathSegs then
        return false
    end
    if pathSegs[pi]:match(segmentPattern(seg)) then
        return matchFrom(globSegs, gi + 1, pathSegs, pi + 1)
    end
    return false
end

--- True iff `path` matches `glob`. Both are normalized (backslashes to "/",
--- lowercased) first, so a glob written for one platform works on the other.
--- @param glob string The glob
--- @param path string The path to test, relative to whatever the glob is anchored to
--- @return boolean
local function matches(glob, path)
    if type(glob) ~= "string" or type(path) ~= "string" then
        return false
    end
    local g = glob:gsub("\\", "/"):lower()
    local p = path:gsub("\\", "/"):lower()
    if g == "" or p == "" then
        return false
    end
    -- No "/" in the glob: match the basename, at any depth (see the header).
    if not g:find("/", 1, true) then
        local basename = p:match("[^/]+$") or p
        return basename:match(segmentPattern(g)) ~= nil
    end
    return matchFrom(split(g), 1, split(p), 1)
end

--- Builds a predicate from a list of globs: true iff a path matches ANY of them.
--- Returns nil for an empty/absent list, so a caller can skip the test entirely
--- (the overwhelmingly common case is a package declaring no globs at all).
--- @param globs table|nil Sequence of glob strings
--- @return function|nil predicate(path) -> boolean
local function matcher(globs)
    if type(globs) ~= "table" or #globs == 0 then
        return nil
    end
    local list = {}
    for _, g in ipairs(globs) do
        list[#list + 1] = g
    end
    return function(path)
        for _, g in ipairs(list) do
            if matches(g, path) then
                return true
            end
        end
        return false
    end
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    matches = matches,
    matcher = matcher,
}

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

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
