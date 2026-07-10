-- Module name
local NAME = "builtin_content_stages"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 30, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

local content_pipeline = require("content.content_pipeline")

local lua_cog = require("content.lua_cog")

local file_util = require("infra.file_util")
local unixEOL = file_util.unixEOL

-- JSON -> TSV transcoder implementations (one function per layout). This module
-- just registers them as stages; the conversion logic lives in json_transcoders.
local json_transcoders = require("content.json_transcoders")

-- EAV (long-format) -> TSV transcoder. Unlike JSON it is auto-matched by the
-- .eav extension and reversible (see eav_transcoder.lua).
local eav_transcoder = require("content.eav_transcoder")

-- XML (our export format) -> TSV transcoder. Id-selected (never auto-fires on a
-- stray .xml), schema-free, namespaced, and reversible (see xml_transcoder.lua).
local xml_transcoder = require("content.xml_transcoder")

-- TSV-with-alternate-cell-encoding transcoders (tsv:lua / tsv:json-typed /
-- tsv:json-natural). Id-selected (they share the .tsv extension with native data,
-- so never auto-fire), schema-free, and reversible (see tsv_transcoders.lua).
local tsv_transcoders = require("content.tsv_transcoders")

-- Lua-file (.lua, `return { <header>, <row>, … }`) transcoder. Id-selected: a .lua
-- is a code library by default, so a data .lua must be opted in explicitly with
-- transcoder=lua:tabulua — it never auto-fires (see lua_transcoder.lua).
local lua_transcoder = require("content.lua_transcoder")

-- Codec registry. The decode stage calls compression.decompress("gzip", …)
-- lazily, so the libdeflate rock is only loaded if a .gz is actually processed
-- (see compression.lua). Requiring this module has no side effects and pulls in
-- no compression library.
local compression = require("content.compression")

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
--
-- All six JSON stages are reversible (json_input_round_trip.md): each declares an
-- `encode` (json_transcoders.*ToJson), so the reformatter rewrites a .json source
-- from the reformatted wide TSV — reached through the id-selected
-- reversibleTranscode (built for XML, so no engine change is needed here), the
-- text output written via safeReplaceFile. The round-trip is normalizing (canonical
-- JSON), not byte-identical; see json_transcoders.lua.
content_pipeline.register(NAME, {
    phase = "transcode",
    id = "json:objects",
    inputExtensions = {"json"},          -- guard only (Step 2), not a matcher
    reversible = true,
    encode = json_transcoders.objectsToJson,
    transform = json_transcoders.objectsToTSV,
})

-- json:rows (array-per-row) and json:columns (array-per-column) — the same data
-- in array form, values positional to the schema's sorted field order.
content_pipeline.register(NAME, {
    phase = "transcode",
    id = "json:rows",
    inputExtensions = {"json"},
    reversible = true,
    encode = json_transcoders.rowsToJson,
    transform = json_transcoders.rowsToTSV,
})

content_pipeline.register(NAME, {
    phase = "transcode",
    id = "json:columns",
    inputExtensions = {"json"},
    reversible = true,
    encode = json_transcoders.columnsToJson,
    transform = json_transcoders.columnsToTSV,
})

-- The `:typed` variants of the three layouts. Same row layouts, but cell values
-- are in TabuLua's self-describing typed JSON encoding ({"int":…}/{"float":…}
-- wrappers and the [size,…] table form) — the read-back of exportJSON. They
-- preserve every type, including non-string and table-valued map keys, where
-- json-natural cannot (json_complex_values.md Phase 2).
content_pipeline.register(NAME, {
    phase = "transcode",
    id = "json:objects:typed",
    inputExtensions = {"json"},
    reversible = true,
    encode = json_transcoders.objectsToJsonTyped,
    transform = json_transcoders.objectsToTSVTyped,
})

content_pipeline.register(NAME, {
    phase = "transcode",
    id = "json:rows:typed",
    inputExtensions = {"json"},
    reversible = true,
    encode = json_transcoders.rowsToJsonTyped,
    transform = json_transcoders.rowsToTSVTyped,
})

content_pipeline.register(NAME, {
    phase = "transcode",
    id = "json:columns:typed",
    inputExtensions = {"json"},
    reversible = true,
    encode = json_transcoders.columnsToJsonTyped,
    transform = json_transcoders.columnsToTSVTyped,
})

-- EAV (long-format) transcoder (eav_long_format.md). Unlike the JSON layouts, EAV
-- is unambiguous by extension, so it AUTO-matches `.eav` (no Files.tsv `transcoder`
-- column needed); the `id` lets it also be selected explicitly on a non-.eav file.
-- It is reversible: the reformatter rewrites an .eav source from the reformatted
-- wide TSV via `encode` (content_pipeline.md §3.6). The forward transform types
-- the rebuilt header from the file's typeName schema (eav_transcoder.eavToTSV).
content_pipeline.register(NAME, {
    phase = "transcode",
    id = "eav",
    extensions = {"eav"},
    outputKind = "text",
    reversible = true,
    encode = eav_transcoder.tsvToEav,
    transform = eav_transcoder.eavToTSV,
})

-- XML (our export format) transcoder (xml_input_round_trip.md). Unlike the JSON
-- layouts AND unlike .eav, it has NO `extensions` key: it is id-only, so a
-- non-data .xml asset is never auto-interpreted as data — the author opts a
-- specific file in with transcoder=xml:tabulua in Files.tsv. The specific id
-- (family `xml`, variant `tabulua`) leaves the `xml:*` space free for
-- user-registered XML formats. inputExtensions is the Step-2 guard (catches a
-- mis-pointed transcoder column), NOT a matcher. It is reversible: the
-- reformatter rewrites an .xml source from the reformatted wide TSV via `encode`
-- (content_pipeline.md §3.6, reached through the id-selected reversibleTranscode
-- path). The forward transform is schema-free — column names/types come from the
-- file's own <header>, not a typeName (xml_transcoder.xmlToTSV).
content_pipeline.register(NAME, {
    phase = "transcode",
    id = "xml:tabulua",
    inputExtensions = {"xml"},
    outputKind = "text",
    reversible = true,
    encode = xml_transcoder.tsvToXml,
    transform = xml_transcoder.xmlToTSV,
})

-- TSV-with-alternate-cell-encoding transcoders (TODO/export_format_reimport.md).
-- Like the JSON layouts they are id-only (no `extensions`): they share the .tsv
-- extension with native data files, so auto-matching would be ambiguous and
-- dangerous — the author opts a specific file in with transcoder=tsv:lua /
-- tsv:json-typed / tsv:json-natural in Files.tsv. inputExtensions={"tsv"} is the
-- guard (catches a mis-pointed transcoder column), NOT a matcher. They are
-- reversible: the reformatter rewrites the source from the reformatted wide TSV via
-- `encode`. Because these share the .tsv extension, the reformatter routes a
-- transcoder-assigned .tsv to the id-selected reversibleTranscode path rather than
-- down the native-TSV rewrite (reformatter.lua). The forward transform is
-- schema-free — column names/types come from the file's own header.
content_pipeline.register(NAME, {
    phase = "transcode",
    id = "tsv:lua",
    inputExtensions = {"tsv"},
    outputKind = "text",
    reversible = true,
    encode = tsv_transcoders.tsvToLua,
    transform = tsv_transcoders.luaToTSV,
})

content_pipeline.register(NAME, {
    phase = "transcode",
    id = "tsv:json-typed",
    inputExtensions = {"tsv"},
    outputKind = "text",
    reversible = true,
    encode = tsv_transcoders.tsvToJsonTyped,
    transform = tsv_transcoders.jsonTypedToTSV,
})

content_pipeline.register(NAME, {
    phase = "transcode",
    id = "tsv:json-natural",
    inputExtensions = {"tsv"},
    outputKind = "text",
    reversible = true,
    encode = tsv_transcoders.tsvToJsonNatural,
    transform = tsv_transcoders.jsonNaturalToTSV,
})

-- Lua-file transcoder (TODO/export_format_reimport.md, Phase 2). The .lua export is
-- a single `return { <header>, <row>, … }` table; id-only because a .lua is a CODE
-- LIBRARY to the loader by default — a data .lua must be opted in with
-- transcoder=lua:tabulua, so it never auto-fires. inputExtensions={"lua"} is the
-- guard. Reversible: the reformatter rewrites the .lua source from the reformatted
-- wide TSV via `encode`. A .lua misses the reformatter's native-TSV rewrite branch
-- (unlike the tsv:* stages), so no reformatter change is needed here — the
-- id-selected reversibleTranscode path round-trips it like .xml/.eav. The forward
-- transform is schema-free — the header (row 1) carries the column types.
content_pipeline.register(NAME, {
    phase = "transcode",
    id = "lua:tabulua",
    inputExtensions = {"lua"},
    outputKind = "text",
    reversible = true,
    encode = lua_transcoder.tsvToLua,
    transform = lua_transcoder.luaToTSV,
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
local global_reset = require("util.global_reset")
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
