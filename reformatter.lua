-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 33, 0)

-- Module name
local NAME = "reformatter"

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

local named_logger = require("infra.named_logger")

-- Map of log level name strings to level constants
local LOG_LEVELS = {
    ["debug"] = named_logger.DEBUG,
    ["info"]  = named_logger.INFO,
    ["warn"]  = named_logger.WARN,
    ["error"] = named_logger.ERROR,
    ["fatal"] = named_logger.FATAL,
}

-- Apply --log-level early, before other modules are loaded, so their
-- loggers are created at the correct level from the start.
if arg then
    for _, a in ipairs(arg) do
        local levelName = a:match("^%-%-log%-level=(.+)$")
        if levelName then
            local level = LOG_LEVELS[levelName:lower()]
            if level then
                named_logger.setGlobalLevel(level)
            else
                -- Invalid log level: suppress module initialization noise
                -- by setting to ERROR. The actual error is reported later
                -- during full argument validation.
                named_logger.setGlobalLevel(named_logger.ERROR)
            end
            break
        end
    end
end

local logger = named_logger.getLogger(NAME)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly
local unwrap = read_only.unwrap

local file_util = require("infra.file_util")
local safeReplaceFile = file_util.safeReplaceFile
local safeReplaceFileBinary = file_util.safeReplaceFileBinary
local normalizePath = file_util.normalizePath
local isDir = file_util.isDir
local emptyDir = file_util.emptyDir
local mkdir = file_util.mkdir
local hasExtension = file_util.hasExtension

local manifest_loader = require("loader.manifest_loader")
local manifest_info = require("loader.manifest_info")
local format_report = require("loader.format_report")

-- Reversible decode round-trip (§3.6): lets reformat rewrite a compressed data
-- source (data.tsv.gz) by reformatting its decoded TSV and re-compressing it.
local content_pipeline = require("content.content_pipeline")

local error_reporting = require("infra.error_reporting")
local badValGen = error_reporting.badValGen
local nullBadVal = error_reporting.nullBadVal
local didYouMean = error_reporting.didYouMean

local exporter = require("serde.exporter")

-- ============================================================
-- SVG colour policy (the opinionated part of the SVG export).
--
-- The renderer (serde.svg_render) is deliberately scheme-agnostic: it draws
-- with individual colours over its own DEFAULT_COLORS and merges any overrides
-- it is handed. The *named palettes* and the *friendly CLI colour vocabulary*
-- are policy, so they live here in the CLI wrapper — a new scheme is a config
-- change here, not a library edit. Each scheme is a set of overrides keyed by
-- svg_render's colour-slot field names; the empty `default` means "use the
-- renderer's built-in colours".
-- ============================================================

local SVG_SCHEMES = {
    default = {},
    dark = {
        nodeFill = "#2b3245", rootFill = "#26402b", leafFill = "#402b26",
        isolatedFill = "#403a26", stroke = "#8a9ac0", text = "#e8ecf5",
        edgeDirected = "#9aa5b5", edgeUndirected = "#7fa8c9",
        edgeText = "#aab2c0", background = "#1e1e2a",
    },
    mono = {
        nodeFill = "#eeeeee", rootFill = "#dddddd", leafFill = "#cccccc",
        isolatedFill = "#d5d5d5", stroke = "#333333", text = "#111111",
        edgeDirected = "#555555", edgeUndirected = "#888888",
        edgeText = "#444444", background = "none",
    },
    colorblind = {  -- Okabe–Ito-derived link hues (blue / vermillion)
        nodeFill = "#e6f0f5", rootFill = "#cfe8d6", leafFill = "#f5e6cf",
        isolatedFill = "#efe0f0", stroke = "#333333", text = "#111111",
        edgeDirected = "#0072b2", edgeUndirected = "#d55e00",
        edgeText = "#444444", background = "none",
    },
}

-- Default edge palette: edges are coloured by their source node, cycling this
-- list, so a bundle of edges leaving one node reads as one colour and
-- neighbouring sources are told apart (see svg_render.assignEdgeColorIndex).
-- These are the eight categorical hues from the data-viz reference palette,
-- ordered so that adjacent slots are the most distinct (CVD-safe on the
-- adjacent pairlist: worst adjacent ΔE ~9 — which is exactly the neighbouring-
-- node case). Mid-toned, so they read on both light and dark backgrounds.
-- On by default; disable with --no-svg-edge-palette, override with
-- --svg-edge-palette=<c1,c2,...>.
local SVG_EDGE_PALETTE = {
    "#2a78d6", "#008300", "#e87ba4", "#eda100",
    "#1baf7a", "#eb6834", "#4a3aa7", "#e34948",
}

-- Friendly CLI colour name (--svg-color=<key>=<value>) -> svg_render colour slot.
local SVG_COLOR_KEYS = {
    ["node"]            = "nodeFill",
    ["root"]            = "rootFill",
    ["leaf"]            = "leafFill",
    ["isolated"]        = "isolatedFill",
    ["border"]          = "stroke",
    ["label"]           = "text",
    ["edge-directed"]   = "edgeDirected",
    ["edge-undirected"] = "edgeUndirected",
    ["edge-label"]      = "edgeText",
    ["background"]      = "background",
}

-- Resolves a scheme name plus explicit per-slot overrides into a single colour
-- table for svg_render.render's `opts.colors`. Explicit overrides always win
-- over the scheme base (order-independent). Returns nil when nothing is set, so
-- the renderer falls back to its own DEFAULT_COLORS.
local function resolveSvgColors(schemeName, overrides)
    local scheme = SVG_SCHEMES[schemeName or "default"] or {}
    local hasOverrides = overrides ~= nil and next(overrides) ~= nil
    if next(scheme) == nil and not hasOverrides then return nil end
    local out = {}
    for k, v in pairs(scheme) do out[k] = v end
    if overrides then for k, v in pairs(overrides) do out[k] = v end end
    return out
end

-- True if `v` is an acceptable SVG colour literal: a #rgb / #rrggbb hex value or
-- a bare CSS colour name (letters only, e.g. "none"/"steelblue"). Emitted
-- verbatim, so output stays deterministic.
local function isSvgColor(v)
    if type(v) ~= "string" then return false end
    return v:match("^#%x%x%x$") ~= nil
        or v:match("^#%x%x%x%x%x%x$") ~= nil
        or v:match("^%a+$") ~= nil
end

-- Returns the sorted keys of a table (for deterministic error listings).
local function sortedKeys(t)
    local names = {}
    for k in pairs(t) do names[#names + 1] = k end
    table.sort(names)
    return names
end

-- Export-time COG doc generation (content_pipeline.md §3.10): discover templates,
-- then expand them after the per-format exporters (which skip them).
local cog_discovery = require("content.cog_discovery")
local doc_generator = require("content.doc_generator")

local serialization = require("serde.serialization")
local serializeTableJSON = serialization.serializeTableJSON
local serializeTableNaturalJSON = serialization.serializeTableNaturalJSON
local serializeTableXML = serialization.serializeTableXML
local serializeMessagePackSQLBlob = serialization.serializeMessagePackSQLBlob

-- Default export directory
local DEFAULT_EXPORT_DIR = "exported"

-- ============================================================================
-- FORMAT CONFIGURATION
-- ============================================================================
-- This configuration table defines all supported file formats, data formats,
-- valid combinations, and defaults. To add a new format, simply extend this
-- configuration - no other code changes required.

-- Data format definitions
-- Each data format defines how Lua values are serialized
local DATA_FORMATS = {
    ["json-typed"] = {
        description = "JSON with Lua type preservation (integers as {\"int\":\"N\"})",
        tsvExporter = exporter.exportJSONTSV,
        jsonExporter = exporter.exportJSON,
        sqlTableSerializer = serializeTableJSON,
    },
    ["json-natural"] = {
        description = "Standard JSON format (compatible with any JSON parser)",
        tsvExporter = exporter.exportNaturalJSONTSV,
        jsonExporter = exporter.exportNaturalJSON,
        sqlTableSerializer = serializeTableNaturalJSON,
    },
    ["lua"] = {
        description = "Lua literal syntax",
        tsvExporter = exporter.exportLuaTSV,
        luaExporter = exporter.exportLua,
    },
    ["xml"] = {
        description = "XML with type-tagged elements",
        sqlTableSerializer = serializeTableXML,
        xmlExporter = exporter.exportXML,
    },
    ["mpk"] = {
        description = "MessagePack binary format",
        mpkExporter = exporter.exportMessagePack,
        sqlTableSerializer = serializeMessagePackSQLBlob,
    },
    -- SVG has no cell-serialization axis (it draws a picture, it doesn't
    -- serialize cells). This passthrough entry exists only so --data
    -- validation and the svg-svg subdir naming stay uniform with every
    -- other format (TODO/graph_svg_export.md).
    ["svg"] = {
        description = "SVG diagram (no cell serialization; passthrough)",
    },
}

-- File format definitions
-- Each file format defines the output file type and valid data formats
local FILE_FORMATS = {
    ["tsv"] = {
        extension = ".tsv",
        description = "Tab-separated values",
        validData = {"lua", "json-typed", "json-natural"},
        defaultData = nil,  -- No default - user must specify
        getExporter = function(dataFormat)
            local df = DATA_FORMATS[dataFormat]
            return df and df.tsvExporter
        end,
    },
    ["json"] = {
        extension = ".json",
        description = "JSON array-of-arrays",
        validData = {"json-typed", "json-natural"},
        defaultData = "json-natural",
        getExporter = function(dataFormat)
            local df = DATA_FORMATS[dataFormat]
            return df and df.jsonExporter
        end,
    },
    ["lua"] = {
        extension = ".lua",
        description = "Lua table (sequence-of-sequences)",
        validData = {"lua"},
        defaultData = "lua",
        getExporter = function(dataFormat)
            local df = DATA_FORMATS[dataFormat]
            return df and df.luaExporter
        end,
    },
    ["xml"] = {
        extension = ".xml",
        description = "XML document",
        validData = {"xml"},
        defaultData = "xml",
        getExporter = function(dataFormat)
            local df = DATA_FORMATS[dataFormat]
            return df and df.xmlExporter
        end,
    },
    ["sql"] = {
        extension = ".sql",
        description = "SQL CREATE TABLE + INSERT statements",
        validData = {"json-typed", "json-natural", "xml", "mpk"},
        defaultData = nil,  -- No default - user must specify
        getExporter = function(dataFormat)
            return exporter.exportSQL
        end,
        getTableSerializer = function(dataFormat)
            local df = DATA_FORMATS[dataFormat]
            return df and df.sqlTableSerializer
        end,
    },
    ["mpk"] = {
        extension = ".mpk",
        description = "MessagePack binary",
        validData = {"mpk"},
        defaultData = "mpk",
        getExporter = function(dataFormat)
            local df = DATA_FORMATS[dataFormat]
            return df and df.mpkExporter
        end,
    },
    ["svg"] = {
        extension = ".svg",
        description = "SVG diagram of graph-family files (skips non-graph files)",
        validData = {"svg"},
        defaultData = "svg",
        getExporter = function() return exporter.exportSVG end,
    },
}

--- Validates that a data format is valid for a file format.
--- @param fileFormat string The file format name
--- @param dataFormat string The data format name
--- @return boolean True if valid combination, false otherwise
local function isValidCombination(fileFormat, dataFormat)
    local ff = FILE_FORMATS[fileFormat]
    if not ff then return false end
    for _, valid in ipairs(ff.validData) do
        if valid == dataFormat then
            return true
        end
    end
    return false
end

--- Creates an exporter configuration for a file/data format combination.
--- @param fileFormat string The file format name
--- @param dataFormat string The data format name
--- @return table|nil Exporter config {fn, subdir, tableSerializer} or nil if invalid
local function createExporter(fileFormat, dataFormat)
    local ff = FILE_FORMATS[fileFormat]
    if not ff then
        logger:error("Unknown file format: " .. tostring(fileFormat))
        return nil
    end

    -- Use default data format if not specified
    local actualDataFormat = dataFormat
    if not actualDataFormat then
        actualDataFormat = ff.defaultData
        if not actualDataFormat then
            logger:error("File format '" .. fileFormat .. "' requires --data option (no default)")
            return nil
        end
    end

    if not isValidCombination(fileFormat, actualDataFormat) then
        logger:error("Invalid combination: --file=" .. fileFormat .. " --data=" .. actualDataFormat)
        logger:error("Valid data formats for " .. fileFormat .. ": " .. table.concat(ff.validData, ", "))
        return nil
    end

    local exportFn = ff.getExporter(actualDataFormat)
    if not exportFn then
        logger:error("No exporter for combination: " .. fileFormat .. " + " .. actualDataFormat)
        return nil
    end

    local result = {
        fn = exportFn,
        subdir = fileFormat .. "-" .. actualDataFormat,
    }

    -- Add table serializer for SQL format
    if ff.getTableSerializer then
        result.tableSerializer = ff.getTableSerializer(actualDataFormat)
    end

    return result
end

-- Every recognised long option, as bare flag names (no `=value`). Kept beside
-- generateUsage (which documents them) so the two can't drift, and used for the
-- "Unknown option" did-you-mean. The arg parser is an if/elseif chain with no
-- other central table, so this list is maintained by hand — add new options to
-- both places.
local KNOWN_OPTIONS = {
    "--check-conflicts", "--clean", "--cog-docs", "--collapse-exploded",
    "--data", "--explain-patch", "--export-dir", "--export-merged",
    "--file", "--list-columns", "--log-level", "--no-number-warn",
    "--no-svg-edge-labels", "--no-svg-edge-palette", "--no-unquoted-warn",
    "--strip-cog", "--svg-color", "--svg-color-scheme", "--svg-edge-palette",
    "--svg-label-column", "--svg-layer-spacing", "--svg-node-spacing",
    "--svg-sweeps", "--variant",
}

--- Generates the usage help text dynamically from the format configuration.
--- @return string The help text
local function generateUsage()
    local lines = {
        "Usage: lua reformatter.lua [OPTIONS] <dir1> [dir2] ...",
        "",
        "DESCRIPTION:",
        "  Processes TSV data files from the specified directories, reformats them",
        "  in-place if needed, and optionally exports them to various formats.",
        "",
        "ARGUMENTS:",
        "  <dir1> [dir2] ...     One or more PACKAGE directories to process. Each must",
        "                        have a Files.tsv in its ROOT, declaring its data files;",
        "                        a data file it does not declare is not loaded. A",
        "                        subdirectory needs no Files.tsv of its own -- the root",
        "                        can declare its files by path (sub/X.tsv) -- but it may",
        "                        have one, whose paths are then relative to IT. That is",
        "                        what makes a package relocatable: drop a utility mod",
        "                        into a subdirectory and its Files.tsv still works,",
        "                        unedited.",
        "",
        "OPTIONS:",
        "  --export-dir=<dir>    Set the base export directory (default: \"exported\")",
        "                        Output goes to subdirectories like exported/json-natural/",
        "",
        "  --file=<format>       Output file format (see FILE FORMATS below)",
        "",
        "  --data=<format>       Data serialization format (see DATA FORMATS below)",
        "                        Required for some file formats, optional for others",
        "",
        "  --collapse-exploded   Collapse exploded columns into single composite columns",
        "                        (e.g., location.level + location.x -> location:{level,x})",
        "                        Default: keep exploded columns as separate flat columns",
        "",
        "  --log-level=<level>   Set log verbosity: debug, info, warn, error, fatal",
        "                        (default: info)",
        "",
        "  --no-number-warn      Suppress 'number' type informational warnings",
        "",
        "  --no-unquoted-warn    Suppress 'Assuming ... is a single unquoted string' warnings",
        "",
        "  --clean               Empty the export directory before exporting",
        "                        Removes all existing files and subdirectories",
        "",
        "  --export-merged[=<dir>]  Write a TSV snapshot of every dataset with all mod",
        "                        overrides applied (patches / overlays / pre-processors)",
        "                        to <dir> (default: \"merged\"), mirroring the source layout.",
        "                        Independent of --file=; can run alone. Diff <dir> against",
        "                        the sources to see exactly what an override changed.",
        "",
        "  --explain-patch[=<F>] Print which mod override set each cell / row / column.",
        "                        Optional filter <F> = <file>[:<pk>[:<column>]] narrows the",
        "                        report (e.g. --explain-patch=Item.tsv:sword:price). Loads",
        "                        and reports; does not require an export.",
        "",
        "  --check-conflicts     Report where mod overrides fight: cells / rows / column",
        "                        defaults written by 2+ sources where the later write",
        "                        discards the earlier (last-writer-wins), as apply-order",
        "                        chains. Benign composition (list/map deltas, widenTo",
        "                        unions, patching a row another mod added) is not flagged.",
        "                        Also flags likely-typo onlyIfPackages gate ids (matched",
        "                        no loaded package, named by no manifest).",
        "                        Diagnostic only: conflicts never fail the run.",
        "",
        "  --list-columns        List every Files.tsv column and Manifest field the engine",
        "                        accepts, marking which your packages already declare and",
        "                        which are available but unused, newest first. An optional",
        "                        column is never warned about when absent, so this is how",
        "                        you find what a newer release added that you could adopt.",
        "                        Loads and reports; nothing is exported.",
        "",
        "  --cog-docs            Refresh COG doc templates (.md/.txt/.html with a COG",
        "                        block) in place against the loaded data, keeping markers.",
        "                        Independent of reformat/export; nothing is exported.",
        "                        Cannot be combined with export options (--file=, --data=,",
        "                        --strip-cog, --clean, --collapse-exploded, --export-dir=).",
        "",
        "  --strip-cog           When exporting, strip the COG scaffolding (markers and",
        "                        code) from generated doc templates, keeping only the",
        "                        generated output. Default off (markers kept).",
        "",
        "  --variant=<name>      Activate a named variant for conditional file inclusion",
        "                        Can be specified multiple times (e.g., --variant=en --variant=ios)",
        "                        Only Files.tsv rows whose variant matches are loaded",
        "",
        "  SVG diagram tuning (only affect --file=svg):",
        "  --svg-sweeps=<N>          Crossing-reduction passes (default 8)",
        "  --svg-node-spacing=<N>    Horizontal gap between nodes in px (default 140)",
        "  --svg-layer-spacing=<N>   Vertical gap between layers in px (default 140)",
        "  --svg-color-scheme=<name> Base colour palette: default, dark, mono, colorblind",
        "  --svg-color=<key>=<color> Override one palette colour (repeatable). Keys:",
        "                            node, root, leaf, isolated, border, label,",
        "                            edge-directed, edge-undirected, edge-label, background.",
        "                            <color> is #rgb, #rrggbb, a CSS colour name, or",
        "                            'none' (background only; transparent canvas).",
        "                            e.g. --svg-color=root=#2e7d32 --svg-color=background=#fff",
        "  --svg-label-column=<col>  Edge-file column to label edges with",
        "                            (default: first non-comment scalar column)",
        "  --no-svg-edge-labels      Do not label edges from the attached edge file",
        "  --svg-edge-palette=<list> Comma-separated colours to colour edges by source",
        "                            node (default: a built-in 8-colour palette), so",
        "                            edge bundles are traceable to their origin.",
        "  --no-svg-edge-palette     Colour all edges one colour (edge-directed/",
        "                            edge-undirected) instead of by source node.",
        "",
        "FILE FORMATS:",
    }

    -- List file formats with their valid data formats
    local fileNames = {}
    for name in pairs(FILE_FORMATS) do
        table.insert(fileNames, name)
    end
    table.sort(fileNames)

    for _, name in ipairs(fileNames) do
        local ff = FILE_FORMATS[name]
        local defaultStr = ff.defaultData and (" (default: " .. ff.defaultData .. ")") or " (no default)"
        table.insert(lines, "  " .. name .. string.rep(" ", 8 - #name) .. ff.description)
        table.insert(lines, "            Valid data: " .. table.concat(ff.validData, ", ") .. defaultStr)
        table.insert(lines, "")
    end

    table.insert(lines, "DATA FORMATS:")

    -- List data formats
    local dataNames = {}
    for name in pairs(DATA_FORMATS) do
        table.insert(dataNames, name)
    end
    table.sort(dataNames)

    for _, name in ipairs(dataNames) do
        local df = DATA_FORMATS[name]
        table.insert(lines, "  " .. name .. string.rep(" ", 14 - #name) .. df.description)
    end

    table.insert(lines, "")
    table.insert(lines, "VALID COMBINATIONS:")
    table.insert(lines, "  File Format   Data Formats                          Default")
    table.insert(lines, "  -----------   ------------------------------------  -------")

    for _, name in ipairs(fileNames) do
        local ff = FILE_FORMATS[name]
        local validStr = table.concat(ff.validData, ", ")
        local defaultStr = ff.defaultData or "(none)"
        local padding1 = string.rep(" ", 14 - #name)
        local padding2 = string.rep(" ", 38 - #validStr)
        table.insert(lines, "  " .. name .. padding1 .. validStr .. padding2 .. defaultStr)
    end

    table.insert(lines, "")
    table.insert(lines, "EXAMPLES:")
    table.insert(lines, "  NOTE: Specify package directories directly -- each must have a Files.tsv")
    table.insert(lines, "        in its root (declaring its data files), or it is an error.")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua tutorial/core/ tutorial/expansion/")
    table.insert(lines, "      Reformat files in package directories (no export)")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --file=json tutorial/core/ tutorial/expansion/")
    table.insert(lines, "      Export as JSON (natural format) to exported/json-json-natural/")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --file=json --data=json-typed tutorial/core/")
    table.insert(lines, "      Export as JSON (typed format) to exported/json-json-typed/")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --file=tsv --data=lua tutorial/core/")
    table.insert(lines, "      Export as TSV with Lua literals to exported/tsv-lua/")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --file=sql --data=json-natural --export-dir=db mypkg/")
    table.insert(lines, "      Export as SQL with JSON columns to db/sql-json-natural/")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --file=lua --file=json tutorial/core/ tutorial/expansion/")
    table.insert(lines, "      Export to multiple formats (uses defaults for each)")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --file=svg tutorial/core/ tutorial/expansion/")
    table.insert(lines, "      Draw graph-family files as SVG diagrams to exported/svg-svg/")
    table.insert(lines, "      (non-graph files are skipped)")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --export-merged tutorial/core/ tutorial/expansion/")
    table.insert(lines, "      Write the post-override merged state of every file to merged/")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --explain-patch tutorial/core/ tutorial/expansion/")
    table.insert(lines, "      Print which mod override set each cell / row / column")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --check-conflicts tutorial/core/ tutorial/expansion/")
    table.insert(lines, "      Report cells / rows / defaults where two or more mods overwrite each other")
    table.insert(lines, "")
    table.insert(lines, "  lua reformatter.lua --list-columns tutorial/core/")
    table.insert(lines, "      List the Files.tsv columns / manifest fields you could be using but aren't")

    return table.concat(lines, "\n")
end

--- Logs that a reformatted file's content changed (or only its trailing EOL did).
local function logContentChange(file_name, new_content, old_content)
    if (new_content .. '\n') == old_content then
        logger:info("Last EOL of " .. file_name .. " has changed")
    else
        logger:warn("Content of " .. file_name .. " has changed")
    end
end

--- Re-formats TSV files in-place, updating files whose content has changed after parsing.
--- @param tsv_files table Map of file paths to parsed TSV data
--- @param raw_files table Map of file paths to original raw content
--- @param badVal table badVal instance for error reporting
--- @side_effect Modifies files on disk if content changed
---
--- Three cases per file (content_pipeline.md §3.6):
---   * Plain .tsv/.csv      — rewrite the reformatted TSV in place (text mode).
---   * Reversible decode     — a compressed data source (data.tsv.gz). raw_files
---     (e.g. data.tsv.gz)      holds the DECODED TSV; rewrite by reformatting that
---                             TSV and re-compressing through the decode stage's
---                             re-encoder, then writing the bytes back (binary).
---   * Everything else       — transcoded sources (items.json) and non-reversible
---                             decodes are read-only: derived TSV must NOT clobber
---                             the original, so they are left untouched.
--- @param fn2Transcoder table|nil Optional map of full file path -> Files.tsv
---   `transcoder` id, so an id-selected reversible transcoder (e.g. xml:tabulua,
---   which has no `extensions`) can be found for the round-trip rewrite.
local function reformat(tsv_files, raw_files, badVal, fn2Transcoder, patchedTargets)
    fn2Transcoder = fn2Transcoder or {}
    patchedTargets = patchedTargets or {}
    for file_name, tsv in pairs(tsv_files) do
        -- A parent file modified in place by a row patch must NOT be rewritten:
        -- its in-memory dataset now reflects the
        -- mod's add/remove/update ops, so serialising it would bake those changes
        -- into the parent's source. The patch FILE itself round-trips normally.
        if patchedTargets[file_name] then
            logger:debug("Leaving patched target untouched (mod patches not baked): "
                .. file_name)
            goto continue
        end
        -- An archive member (utilmod.zip/data/Item.tsv) is a READ-ONLY input in v1:
        -- the reformatter must never try to splice bytes back into a container (and
        -- a write to the .zip-as-directory path would fail outright). Writing back
        -- into an archive is deferred (archive_files.md §5 / Phase 5).
        if (select(2, file_util.resolveArchivePath(file_name))) ~= nil then
            logger:debug("Leaving archive member untouched (read-only input): " .. file_name)
            goto continue
        end
        local old_content = raw_files[file_name]
        if type(old_content) ~= "string" then
            -- Binary passthrough files (§3.5) are descriptor tables, not strings,
            -- and shouldn't be in tsv_files at all; guard defensively.
            logger:warn("Content of " .. file_name .. " missing in raw_files")
            goto continue
        end
        local new_content = tostring(tsv)
        -- A .tsv/.csv with a Files.tsv `transcoder` id (e.g. tsv:lua) is NOT a
        -- native TSV source: its on-disk cells are in an alternate encoding (Lua /
        -- typed-JSON / natural-JSON) and raw_files holds only the derived wide TSV.
        -- Writing the reformatted native TSV here would silently clobber the chosen
        -- encoding, so route it to the id-selected reversibleTranscode branch below
        -- (which round-trips it through the stage's `encode`, or leaves it untouched
        -- if the stage is not reversible). TODO/export_format_reimport.md.
        local nativeTSV = (hasExtension(file_name, "tsv") or hasExtension(file_name, "csv"))
            and not fn2Transcoder[file_name]
        if nativeTSV then
            -- Manifests are reformatted too: user-defined fields are preserved in
            -- the tsv_model, and __comment placeholders restore comment lines.
            if new_content ~= old_content then
                logContentChange(file_name, new_content, old_content)
                if safeReplaceFile(file_name, new_content) then
                    logger:info("Updated: " .. file_name)
                else
                    badVal(file_name, "Failed to update")
                end
            end
        else
            -- Not a plain TSV/CSV. If it's a reversible compressed data source
            -- (data.tsv.gz), round-trip it: reformat the decoded TSV, re-compress,
            -- write the bytes back. old_content here is the DECODED TSV, so the
            -- change check compares like with like.
            local rd = content_pipeline.reversibleDecode(file_name)
            local peeled = rd and rd.peeledName:lower()
            local isReversibleData = rd and peeled
                and (peeled:sub(-4) == ".tsv" or peeled:sub(-4) == ".csv")
            if isReversibleData then
                if new_content ~= old_content then
                    logContentChange(file_name, new_content, old_content)
                    local bytes, err = rd.encode(new_content, nil, badVal)
                    if bytes and safeReplaceFileBinary(file_name, bytes) then
                        logger:info("Updated (re-compressed): " .. file_name)
                    else
                        badVal(file_name, "Failed to re-encode/update: " .. tostring(err))
                    end
                end
            else
                -- A reversible transcoded source (an .eav): rewrite it from the
                -- reformatted wide TSV via the transcode stage's re-encoder
                -- (content_pipeline.md §3.6). old_content / new_content are both the
                -- derived wide TSV, so the change check compares like with like; the
                -- EAV output is text, so write it text-mode (unlike the binary gzip
                -- case above).
                local rt = content_pipeline.reversibleTranscode(file_name, fn2Transcoder[file_name])
                if rt then
                    if new_content ~= old_content then
                        logContentChange(file_name, new_content, old_content)
                        local bytes, err = rt.encode(new_content, nil, badVal)
                        if bytes and safeReplaceFile(file_name, bytes) then
                            logger:info("Updated (re-encoded): " .. file_name)
                        else
                            badVal(file_name, "Failed to re-encode/update: " .. tostring(err))
                        end
                    end
                else
                    -- Transcoded (non-reversible) or non-reversible decoded source:
                    -- derived data is not source of truth, so leave it untouched (§3.6).
                    logger:debug("Leaving derived source untouched: " .. file_name)
                end
            end
        end
        ::continue::
    end
end

--- Computes the destination path for a file in the merged-export tree.
--- A loaded file under input directory `d` is written to
--- `<mergedDir>/<basename(d)>/<path-relative-to-d>`, so each package keeps its
--- own subtree (no collisions when two packages share a basename) and the layout
--- mirrors the source. Files not under any input directory fall back to their
--- basename directly under `mergedDir`.
--- @param file_name string Full (normalized) path of the loaded file
--- @param directories table Sequence of input directory paths
--- @param mergedDir string Root of the merged-export tree
--- @return string The destination path
local function relativeMergedPath(file_name, directories, mergedDir)
    local nf = normalizePath(file_name)
    local bestDir, bestRel = nil, nil
    for _, d in ipairs(directories) do
        local nd = normalizePath(d)
        local prefix = nd .. "/"
        if nf:sub(1, #prefix) == prefix and (not bestDir or #nd > #bestDir) then
            bestDir = nd
            bestRel = nf:sub(#prefix + 1)
        end
    end
    if bestDir then
        local base = bestDir:match("[^/]+$") or bestDir
        return mergedDir .. "/" .. base .. "/" .. bestRel
    end
    return mergedDir .. "/" .. (nf:match("[^/]+$") or nf)
end

--- Serializes one dataset with mod overrides applied, then restores it.
---
--- In-place reformat serializes from each cell's `reformatted` text, which
--- patches/overlays/pre-processors deliberately leave at the *original* value
--- (the "no-bake" trick). To show the merged state we
--- must serialize from the live `parsed` value instead. Rather than reimplement
--- the dataset serializer (preamble, exploded columns, etc.), this temporarily
--- rewrites each data cell's `reformatted` (index 4) from `parsed`, calls the
--- normal `tostring`, then restores every cell — so the live dataset is unchanged
--- afterwards and the existing serializer machinery is reused.
---
--- `=expr` cells are left untouched (their expression text is kept, not the
--- computed value); every other cell is re-rendered from its parsed value, so a
--- patched / overlaid / processor-written value is what appears. Defaults that
--- resolved to a value are rendered too (this is a fully-resolved snapshot, not a
--- source file). Transposed files (manifests) are never override targets, so they
--- are serialized as-is.
--- @param tsv table The dataset
--- @param isTransposed boolean True for transposed files (serialize as-is)
--- @return string The merged TSV text
local function serializeMergedDataset(tsv, isTransposed)
    if isTransposed then
        return tostring(tsv)
    end
    local header = tsv[1]
    local saved = {}
    for ri, row in ipairs(tsv) do
        if ri > 1 and type(row) == "table" then
            for ci, cell in ipairs(row) do
                local val = cell.value
                -- Keep `=expr` cells as their expression; consider the rest.
                if not (type(val) == "string" and val:sub(1, 1) == "=") then
                    local col = header[ci]
                    if col and col.parser then
                        -- Re-render ONLY cells whose parsed value actually changed
                        -- (i.e. an override touched them); leave unchanged cells at
                        -- their original `reformatted` text so they stay byte-identical
                        -- to the source (no requoting of e.g. `Fire`→`"Fire"`, no
                        -- baking of resolved defaults). Both the original on-disk value
                        -- and the live parsed value are compared through the same
                        -- canonical "parsed"-context render.
                        local origParsed = col.parser(nullBadVal,
                            type(val) == "string" and val or "", "tsv")
                        local _, origCanon = col.parser(nullBadVal, origParsed, "parsed")
                        local _, newCanon = col.parser(nullBadVal, cell.parsed, "parsed")
                        if newCanon ~= nil and newCanon ~= origCanon then
                            local raw = unwrap(cell)
                            saved[#saved + 1] = {raw, raw[4]}
                            raw[4] = newCanon
                        end
                    end
                end
            end
        end
    end
    local content = tostring(tsv)
    -- Restore every rewritten cell so the live dataset is untouched.
    for _, s in ipairs(saved) do
        s[1][4] = s[2]
    end
    return content
end

--- Writes one merged dataset to `target`, **encoded to the source file's own
--- on-disk format** so it has the same name and format as the original and diffs
--- cleanly against it (a gz-aware diff compares the decompressed contents). Reuses
--- the same reversible encoders the in-place reformatter uses for round-trip:
---   * plain `.tsv`/`.csv`         — written verbatim (binary, LF — a text-mode
---                                   write would translate to CRLF on Windows and
---                                   every line would spuriously differ from source).
---   * reversible compressed `.gz` — re-compressed through the decode stage's encoder.
---   * reversible transcoded       — re-encoded through the transcoder (`.eav`, and
---                                   id-selected `json:*` / `xml:tabulua`).
---   * archive member              — left as-is for now (read-only input); skipped.
---   * non-reversible / unknown    — skipped (its format can't be reproduced, so a
---                                   same-named merged file could not diff cleanly).
--- @return boolean True if a file was written
local function writeMergedFile(file_name, content, target, fn2Transcoder, badVal)
    -- Archive members are left for now (writing back into a container is deferred).
    if (select(2, file_util.resolveArchivePath(file_name))) ~= nil then
        logger:debug("Merged export skips archive member (left as-is): " .. file_name)
        return false
    end
    local parent = file_util.getParentPath(target)
    if parent then
        local ok, err = mkdir(parent)
        if not ok then
            badVal(target, "Failed to create merged directory: " .. tostring(err))
            return false
        end
    end

    local function write(bytes)
        -- Always binary: text content is LF and must stay LF; encoded content
        -- (gzip / transcoder) is raw bytes. safeReplaceFile is unusable here (it
        -- renames a not-yet-existent original), so this is a plain create/overwrite.
        local ok, err = file_util.writeFileBinary(target, bytes)
        if not ok then
            badVal(target, "Failed to write merged file: " .. tostring(err))
        end
        return ok
    end

    local nativeTSV = (hasExtension(file_name, "tsv") or hasExtension(file_name, "csv"))
        and not fn2Transcoder[file_name]
    if nativeTSV then
        return write(content)
    end

    local rd = content_pipeline.reversibleDecode(file_name)
    local peeled = rd and rd.peeledName:lower()
    if rd and peeled and (peeled:sub(-4) == ".tsv" or peeled:sub(-4) == ".csv") then
        local bytes, err = rd.encode(content, nil, badVal)
        if bytes then return write(bytes) end
        badVal(target, "Failed to re-encode merged file: " .. tostring(err))
        return false
    end

    local rt = content_pipeline.reversibleTranscode(file_name, fn2Transcoder[file_name])
    if rt then
        local bytes, err = rt.encode(content, nil, badVal)
        if bytes then return write(bytes) end
        badVal(target, "Failed to re-encode merged file: " .. tostring(err))
        return false
    end

    logger:debug("Merged export skips non-reversible source (cannot reproduce its "
        .. "format for a clean diff): " .. file_name)
    return false
end

--- Writes a snapshot of every loaded dataset to a separate `mergedDir`, with all
--- mod overrides applied (row/bulk patches, schema overlays, pre-processors).
--- Unlike in-place reformat — which deliberately skips patched targets so overrides
--- are never baked into the parent's source — this writes the *post-override*
--- in-memory state, so the merged tree shows the final merged data and can be
--- diffed against the sources (the `--export-merged` tool).
--- Each file is encoded to its source's on-disk format (see `writeMergedFile`).
--- @param tsv_files table Map of file paths to parsed (overridden) datasets
--- @param directories table Sequence of input directory paths
--- @param mergedDir string Root of the merged-export tree
--- @param fn2Transcoder table|nil Full path -> transcoder id (for reversible re-encode)
--- @param badVal table badVal instance for error reporting
local function exportMerged(tsv_files, directories, mergedDir, fn2Transcoder, badVal)
    fn2Transcoder = fn2Transcoder or {}
    logger:info("Writing merged (overridden) state to: " .. mergedDir)
    local count = 0
    for file_name, tsv in pairs(tsv_files) do
        if type(tsv) == "table" then
            -- Manifests are transposed and never override targets — serialize as-is.
            local isTransposed = file_name:match("%.transposed%.tsv$") ~= nil
            local content = serializeMergedDataset(tsv, isTransposed)
            local target = relativeMergedPath(file_name, directories, mergedDir)
            if writeMergedFile(file_name, content, target, fn2Transcoder, badVal) then
                count = count + 1
            end
        end
    end
    logger:info("Merged export: wrote " .. count .. " file(s) to " .. mergedDir)
end

--- Parses an `--explain-patch` filter spec `<file>[:<pk>[:<col>]]` into the
--- {file, pk, col} shape `patch_lineage:report` expects. Empty parts mean "no
--- filter on that axis"; the file part is lowercased to match the lineage keys.
--- A non-string spec (bare `--explain-patch`) yields an empty (unfiltered) filter.
--- @param spec string|boolean The flag value
--- @return table {file?, pk?, col?}
local function parseExplainFilter(spec)
    if type(spec) ~= "string" then return {} end
    local file, pk, col = spec:match("^([^:]*):?([^:]*):?(.*)$")
    local function nz(s) return (s and s ~= "") and s or nil end
    return {file = file and file ~= "" and file:lower() or nil, pk = nz(pk), col = nz(col)}
end

--- Main entry point: loads, reformats, and optionally exports files.
--- @param directories table Sequence of directory paths containing TSV files
--- @param exporters table|nil Optional sequence of exporters, each either a function or {fn, subdir, tableSerializer}
--- @param exportParams table|nil Optional export parameters: {exportDir, ...}
--- @param opt_variants table|nil Optional sequence of variant names to activate
--- @side_effect Reformats files in-place; creates export files if exporters specified
--- @error Throws if directories is not a table or contains non-string values
local function processFiles(directories, exporters, exportParams, opt_variants)
    local td = type(directories)
    if td == "nil" or (td == "table" and #directories == 0) then
        logger:error("No input directories specified")
        return
    end
    if td ~= "table" then
        error("processFiles: directories not a table: "..td)
    end
    for _,d in pairs(directories) do
        if type(d) ~= "string" then
            error("processFiles: directory not a string: "..type(d))
        end
        if not isDir(d) then
            logger:error("processFiles: directory does not exist: "..d)
            return
        end
    end
    local badVal = badValGen()
    badVal.logger = logger

    -- Determine export directory early so we can exclude it from file collection
    local exportDir = (exportParams and exportParams.exportDir) or DEFAULT_EXPORT_DIR
    local mergedDir = exportParams and exportParams.mergedDir
    local excludeDirs = {}
    for _, directory in ipairs(directories) do
        if directory and directory ~= "" then
            local candidate = normalizePath(directory .. "/" .. exportDir)
            if candidate then
                excludeDirs[candidate] = true
            end
            -- Also exclude the merged-export tree so re-runs never re-load a
            -- previously written merged snapshot as if it were source.
            if mergedDir then
                local mc = normalizePath(directory .. "/" .. mergedDir)
                if mc then excludeDirs[mc] = true end
            end
        end
    end
    if mergedDir then
        local mc = normalizePath(mergedDir)
        if mc then excludeDirs[mc] = true end
    end

    -- --explain-patch / --check-conflicts: enable patch-lineage tracking during load.
    local explainPatch = exportParams and exportParams.explainPatch
    local checkConflicts = exportParams and exportParams.checkConflicts
    local result = manifest_loader.processFiles(directories, badVal, excludeDirs,
        opt_variants, explainPatch ~= nil or checkConflicts == true)
    if result then
        local tsv_files = result.tsv_files
        local raw_files = result.raw_files
        reformat(tsv_files, raw_files, badVal,
            result.joinMeta and result.joinMeta.fn2Transcoder,
            result.joinMeta and result.joinMeta.patchedTargets)
        -- Print the override lineage report (independent of reformat/export).
        if explainPatch ~= nil and result.lineage then
            print(result.lineage:report(parseExplainFilter(explainPatch)))
        end
        -- Print the format inventory: every Files.tsv column / manifest field the
        -- engine accepts, marked with what these packages already declare. An
        -- absent OPTIONAL column is never warned about (it cannot be — see
        -- format_report), so this report is the only way to discover one that a
        -- newer release added. Diagnostic only — never affects the exit code.
        if exportParams and exportParams.listColumns then
            print(format_report.report(result.packages, result.joinMeta))
        end
        -- Print the conflicts-only report: slots 2+ sources overwrote, as
        -- apply-order chains. Diagnostic only — never affects the exit code.
        if checkConflicts and result.lineage then
            print((result.lineage:conflictReport()))
            -- onlyIfPackages typo heuristic (mod_ecosystem §2.1): a misspelled
            -- gate id silently deactivates its file forever, indistinguishable
            -- from "mod absent" — except that a typo matches no known id
            -- anywhere. Printed only when there is something to flag.
            local suspects = manifest_info.unknownGateIds(result.packages,
                result.joinMeta and result.joinMeta.skippedGates)
            if #suspects > 0 then
                local lines = {"", "=== onlyIfPackages check ===", "",
                    "Gate ids matching no loaded package and named by no manifest"
                    .. " (possible typos):"}
                for _, s in ipairs(suspects) do
                    local line = "  '" .. s.id .. "'   gates: "
                        .. table.concat(s.files, ", ")
                    if s.suggest then
                        line = line .. "   (did you mean '" .. s.suggest .. "'?)"
                    end
                    lines[#lines + 1] = line
                end
                print(table.concat(lines, "\n"))
            end
            -- Provided-variant typo heuristic (did_you_mean.md §3): a --variant=X
            -- naming no known variant selects nothing and is silently ignored.
            -- Known = variant_group values + every Files.tsv `variant` mention.
            local badVariants = manifest_info.unknownVariants(result.packages,
                opt_variants, result.joinMeta and result.joinMeta.knownVariants)
            if #badVariants > 0 then
                local lines = {"", "=== --variant check ===", "",
                    "Selected variants matching no variant group and no"
                    .. " Files.tsv variant (selects nothing — possible typos):"}
                for _, s in ipairs(badVariants) do
                    local line = "  '" .. s.name .. "'"
                    if s.suggest then
                        line = line .. "   (did you mean '" .. s.suggest .. "'?)"
                    end
                    lines[#lines + 1] = line
                end
                print(table.concat(lines, "\n"))
            end
        end
        local errors = badVal.errors
        if errors > 0 then
            logger:error("Reformatting errors: " .. errors)
        else
            -- Merged export: write the post-override state
            -- of every dataset to a separate tree. Independent of the format
            -- exporters below — it can run alone (just load + merged snapshot) or
            -- alongside an export.
            if mergedDir then
                exportMerged(tsv_files, directories, mergedDir,
                    result.joinMeta and result.joinMeta.fn2Transcoder, badVal)
            end
            if exporters and #exporters > 0 then
                logger:info("Using export directory: " .. exportDir)
                if not isDir(exportDir) then
                    logger:warn("Export directory " .. exportDir .. " does not exist, creating it...")
                    local success, err = mkdir(exportDir)
                    if not success then
                        logger:error("Failed to create export directory " .. exportDir.." : " .. err)
                        return
                    end
                elseif exportParams and exportParams.cleanExportDir then
                    logger:info("Cleaning export directory: " .. exportDir)
                    local success, err = emptyDir(exportDir, logger)
                    if not success then
                        logger:error("Failed to clean export directory " .. exportDir .. " : " .. err)
                        return
                    end
                end
                local epCopy = {}
                if exportParams then
                    for k, v in pairs(exportParams) do
                        epCopy[k] = v
                    end
                end
                epCopy.exportDir = exportDir
                -- Discover COG doc templates once. The per-format exporters skip
                -- them (templates are generated, not copied — §3.10); doc_generator
                -- expands them afterwards. The shared read cache means each
                -- template is read once across discovery and expansion.
                local docCache = file_util.newReadCache()
                local templates = cog_discovery.discover(directories, excludeDirs, docCache)
                local templateSet = {}
                for _, t in ipairs(templates) do templateSet[t] = true end
                epCopy.cogTemplates = templateSet
                -- Register joined types before generating schema so they appear in it
                local joinedTypeCount = exporter.registerJoinedTypes(result)
                if joinedTypeCount > 0 then
                    logger:info("Pre-registered " .. joinedTypeCount .. " joined type(s) for schema")
                end
                exporter.exportSchema(exportDir, result, badVal)
                for _, exp in ipairs(exporters) do
                    -- Support both plain functions and {fn, subdir, tableSerializer} tables
                    if type(exp) == "function" then
                        exp(result, epCopy)
                    else
                        epCopy.formatSubdir = exp.subdir
                        if exp.tableSerializer then
                            epCopy.tableSerializer = exp.tableSerializer
                        end
                        local success = exp.fn(result, epCopy)
                        if not success then
                            logger:error("Failed to export to " .. exp.subdir)
                            return
                        end
                        epCopy.tableSerializer = nil
                    end
                end
                -- Expand the discovered doc templates against the loaded data and
                -- write them to the export dir (optional stripCog), mirroring layout.
                doc_generator.generate(templates, docCache, result, directories, epCopy, badVal)
            end
        end
    else
        logger:error("manifest_loader failed to process files in " .. table.concat(directories, ", "))
    end
end

--- Refreshes COG doc templates in place: loads the data, discovers templates,
--- and rewrites each source template with its COG region regenerated (markers
--- KEPT). The `--cog-docs` mode — independent of reformat/export
--- (cog_markdown.md §2.4). Does not reformat data files or export anything.
--- @param directories table Sequence of package directory paths
--- @param opt_variants table|nil Optional sequence of variant names to activate
--- @side_effect Rewrites COG doc template source files in place
local function refreshDocs(directories, opt_variants)
    local td = type(directories)
    if td == "nil" or (td == "table" and #directories == 0) then
        logger:error("No input directories specified")
        return
    end
    if td ~= "table" then
        error("refreshDocs: directories not a table: "..td)
    end
    for _, d in pairs(directories) do
        if type(d) ~= "string" then
            error("refreshDocs: directory not a string: "..type(d))
        end
        if not isDir(d) then
            logger:error("refreshDocs: directory does not exist: "..d)
            return
        end
    end
    local badVal = badValGen()
    badVal.logger = logger

    -- Exclude the conventional export dir so generated copies aren't refreshed.
    local excludeDirs = {}
    for _, d in ipairs(directories) do
        if d and d ~= "" then
            local candidate = normalizePath(d .. "/" .. DEFAULT_EXPORT_DIR)
            if candidate then excludeDirs[candidate] = true end
        end
    end

    local result = manifest_loader.processFiles(directories, badVal, excludeDirs, opt_variants)
    if not result then
        logger:error("manifest_loader failed to process files in " .. table.concat(directories, ", "))
        return
    end

    local cache = file_util.newReadCache()
    local templates = cog_discovery.discover(directories, excludeDirs, cache)
    if #templates == 0 then
        logger:info("No COG doc templates found to refresh")
        return
    end
    doc_generator.refreshInPlace(templates, cache, result, badVal)
    if badVal.errors > 0 then
        logger:error("Doc refresh errors: " .. badVal.errors)
    end
end

local isMainScript = arg and arg[0] and arg[0]:match("reformatter")
if isMainScript then
    -- Main execution
    logger:info("reformatter version: " .. getVersion())
    if #arg == 0 then
        print(generateUsage())
        os.exit(1)
    else
        local directories = {}
        local exporters = {}
        local exportParams = {}
        local exportDir = DEFAULT_EXPORT_DIR
        local collapseExploded = false  -- --collapse-exploded flag
        local cleanExportDir = false    -- --clean flag
        local cogDocs = false           -- --cog-docs flag (in-place doc refresh)
        local stripCog = false          -- --strip-cog flag (strip COG on doc export)
        local exportDirSet = false      -- whether --export-dir= was given
        local mergedDir = nil           -- --export-merged[=<dir>] target (nil = off)
        local mergedSet = false         -- whether --export-merged was given
        local explainPatch = nil        -- --explain-patch[=<filter>] (nil = off, true = all)
        local checkConflicts = false    -- --check-conflicts flag (conflicts-only report)
        local listColumns = false       -- --list-columns flag (format inventory report)
        local variants = {}             -- --variant=<name> values
        local svgSchemeName = nil       -- --svg-color-scheme=<name> (nil = default)
        local svgColorOverrides = {}    -- --svg-color=<key>=<v> (slot -> colour)
        local svgEdgePaletteOff = false -- --no-svg-edge-palette (single-colour edges)
        local svgEdgePalette = nil      -- --svg-edge-palette=<c,..> (nil = default)
        local pendingFile = nil  -- Pending --file= waiting for optional --data=
        local pendingData = nil  -- Pending --data= waiting for --file=
        local hasError = false

        -- Helper to finalize a pending file format export
        local function finalizePending()
            if pendingFile then
                local exp = createExporter(pendingFile, pendingData)
                if exp then
                    table.insert(exporters, exp)
                else
                    hasError = true
                end
                pendingFile = nil
                pendingData = nil
            elseif pendingData then
                logger:error("--data=" .. pendingData .. " specified without --file=")
                hasError = true
                pendingData = nil
            end
        end

        for i = 1, #arg do
            local arg_i = arg[i]
            local fileMatch = arg_i:match("^%-%-file=(.+)$")
            local dataMatch = arg_i:match("^%-%-data=(.+)$")
            local exportDirMatch = arg_i:match("^%-%-export%-dir=(.*)$")

            if fileMatch then
                -- Finalize any previous pending export
                finalizePending()
                -- Validate file format
                if not FILE_FORMATS[fileMatch] then
                    logger:error("Unknown file format: " .. fileMatch
                        .. didYouMean(fileMatch, FILE_FORMATS))
                    logger:error("Valid formats: " .. table.concat((function()
                        local names = {}
                        for name in pairs(FILE_FORMATS) do table.insert(names, name) end
                        table.sort(names)
                        return names
                    end)(), ", "))
                    hasError = true
                else
                    pendingFile = fileMatch
                end
            elseif dataMatch then
                -- Validate data format
                if not DATA_FORMATS[dataMatch] then
                    logger:error("Unknown data format: " .. dataMatch
                        .. didYouMean(dataMatch, DATA_FORMATS))
                    logger:error("Valid formats: " .. table.concat((function()
                        local names = {}
                        for name in pairs(DATA_FORMATS) do table.insert(names, name) end
                        table.sort(names)
                        return names
                    end)(), ", "))
                    hasError = true
                elseif pendingData then
                    logger:error("Multiple --data= without --file= between them")
                    hasError = true
                else
                    pendingData = dataMatch
                end
            elseif exportDirMatch then
                exportDir = exportDirMatch
                exportDirSet = true
            elseif arg_i:match("^%-%-export%-merged=") then
                local md = arg_i:match("^%-%-export%-merged=(.*)$")
                mergedDir = (md and md ~= "") and md or "merged"
                mergedSet = true
            elseif arg_i == "--export-merged" then
                mergedDir = "merged"
                mergedSet = true
            elseif arg_i:match("^%-%-explain%-patch=") then
                explainPatch = arg_i:match("^%-%-explain%-patch=(.*)$")
                if explainPatch == "" then explainPatch = true end
            elseif arg_i == "--explain-patch" then
                explainPatch = true
            elseif arg_i == "--check-conflicts" then
                checkConflicts = true
            elseif arg_i == "--list-columns" then
                listColumns = true
            elseif arg_i:match("^%-%-log%-level=") then
                local levelName = arg_i:match("^%-%-log%-level=(.+)$")
                local level = LOG_LEVELS[levelName:lower()]
                if level then
                    named_logger.setGlobalLevel(level)
                else
                    logger:error("Unknown log level: " .. levelName
                        .. didYouMean(levelName:lower(), LOG_LEVELS))
                    logger:error("Valid levels: debug, info, warn, error, fatal")
                    hasError = true
                end
            elseif arg_i == "--collapse-exploded" then
                collapseExploded = true
            elseif arg_i == "--no-number-warn" then
                require("parsers.state").suppressNumberTypeWarning = true
            elseif arg_i == "--no-unquoted-warn" then
                require("parsers.state").suppressUnquotedStringWarning = true
            elseif arg_i == "--clean" then
                cleanExportDir = true
            elseif arg_i == "--cog-docs" then
                cogDocs = true
            elseif arg_i == "--strip-cog" then
                stripCog = true
            elseif arg_i:match("^%-%-variant=") then
                local variantName = arg_i:match("^%-%-variant=(.+)$")
                if variantName then
                    table.insert(variants, variantName)
                else
                    logger:error("--variant= requires a name")
                    hasError = true
                end
            elseif arg_i:match("^%-%-svg%-sweeps=") then
                local v = tonumber(arg_i:match("^%-%-svg%-sweeps=(.+)$"))
                if v then exportParams.svgSweeps = v
                else logger:error("--svg-sweeps= requires a number"); hasError = true end
            elseif arg_i:match("^%-%-svg%-node%-spacing=") then
                local v = tonumber(arg_i:match("^%-%-svg%-node%-spacing=(.+)$"))
                if v then exportParams.svgNodeSpacing = v
                else logger:error("--svg-node-spacing= requires a number"); hasError = true end
            elseif arg_i:match("^%-%-svg%-layer%-spacing=") then
                local v = tonumber(arg_i:match("^%-%-svg%-layer%-spacing=(.+)$"))
                if v then exportParams.svgLayerSpacing = v
                else logger:error("--svg-layer-spacing= requires a number"); hasError = true end
            elseif arg_i:match("^%-%-svg%-color%-scheme=") then
                local name = arg_i:match("^%-%-svg%-color%-scheme=(.+)$")
                if name and SVG_SCHEMES[name] then
                    svgSchemeName = name
                else
                    local schemes = sortedKeys(SVG_SCHEMES)
                    logger:error("Unknown SVG color scheme: " .. tostring(name)
                        .. didYouMean(name, schemes))
                    logger:error("Valid schemes: " .. table.concat(schemes, ", "))
                    hasError = true
                end
            elseif arg_i:match("^%-%-svg%-color=") then
                -- --svg-color=<key>=<color>, repeatable, overrides one colour.
                local spec = arg_i:match("^%-%-svg%-color=(.+)$")
                local key, val = nil, nil
                if spec then key, val = spec:match("^([%w%-]+)=(.+)$") end
                if not key then
                    logger:error("--svg-color= expects <key>=<color>"
                        .. " (e.g. --svg-color=root=#2e7d32)")
                    hasError = true
                elseif not SVG_COLOR_KEYS[key] then
                    local keys = sortedKeys(SVG_COLOR_KEYS)
                    logger:error("Unknown SVG color key: " .. key
                        .. didYouMean(key, keys))
                    logger:error("Valid keys: " .. table.concat(keys, ", "))
                    hasError = true
                elseif not isSvgColor(val) then
                    logger:error("Invalid color '" .. tostring(val)
                        .. "' for --svg-color=" .. key
                        .. " (expected #rgb, #rrggbb, or a CSS colour name)")
                    hasError = true
                else
                    svgColorOverrides[SVG_COLOR_KEYS[key]] = val
                end
            elseif arg_i:match("^%-%-svg%-label%-column=") then
                exportParams.svgLabelColumn = arg_i:match("^%-%-svg%-label%-column=(.+)$")
            elseif arg_i == "--no-svg-edge-labels" then
                exportParams.svgLabelEdges = false
            elseif arg_i == "--no-svg-edge-palette" then
                svgEdgePaletteOff = true
            elseif arg_i:match("^%-%-svg%-edge%-palette=") then
                -- Comma-separated colour list overriding the default palette.
                local spec = arg_i:match("^%-%-svg%-edge%-palette=(.+)$")
                local colors, bad = {}, nil
                for raw in (spec or ""):gmatch("[^,]+") do
                    -- fresh local: a for-in control variable is <const> on
                    -- Lua 5.5 and cannot be reassigned (the ltcn lesson)
                    local c = raw:match("^%s*(.-)%s*$")  -- trim
                    if isSvgColor(c) then colors[#colors + 1] = c
                    else bad = c end
                end
                if bad then
                    logger:error("Invalid colour '" .. tostring(bad)
                        .. "' in --svg-edge-palette="
                        .. " (expected #rgb, #rrggbb, or a CSS colour name)")
                    hasError = true
                elseif #colors == 0 then
                    logger:error("--svg-edge-palette= expects one or more"
                        .. " comma-separated colours")
                    hasError = true
                else
                    svgEdgePalette = colors
                end
            elseif arg_i:match("^%-%-") then
                local flag = arg_i:match("^(%-%-[%w%-]+)") or arg_i
                logger:error("Unknown option: " .. arg_i
                    .. didYouMean(flag, KNOWN_OPTIONS))
                hasError = true
            else
                -- Directory argument - finalize any pending export first
                finalizePending()
                arg_i = normalizePath(arg_i)
                table.insert(directories, arg_i)
            end
        end

        -- Finalize any remaining pending export
        finalizePending()

        -- --cog-docs is an in-place refresh mode (rewrites source doc templates,
        -- keeping markers) and exports nothing. Combining it with export options
        -- used to silently ignore them — leaving the export dir empty. Error
        -- instead, so the conflicting intent is surfaced rather than swallowed.
        if cogDocs then
            local offending = {}
            if #exporters > 0 then offending[#offending + 1] = "--file=" end
            if stripCog then offending[#offending + 1] = "--strip-cog" end
            if cleanExportDir then offending[#offending + 1] = "--clean" end
            if collapseExploded then offending[#offending + 1] = "--collapse-exploded" end
            if exportDirSet then offending[#offending + 1] = "--export-dir=" end
            if mergedSet then offending[#offending + 1] = "--export-merged" end
            if explainPatch ~= nil then offending[#offending + 1] = "--explain-patch" end
            if checkConflicts then offending[#offending + 1] = "--check-conflicts" end
            if listColumns then offending[#offending + 1] = "--list-columns" end
            if #offending > 0 then
                logger:error("--cog-docs cannot be combined with export options ("
                    .. table.concat(offending, ", ") .. "). It refreshes COG doc "
                    .. "templates in place and exports nothing. Run --cog-docs on its "
                    .. "own, or drop it to export (add --strip-cog to strip COG markers "
                    .. "from the generated docs).")
                hasError = true
            end
        end

        if hasError then
            print("\nUse 'lua reformatter.lua' without arguments to see usage.")
            os.exit(1)
        end

        if cogDocs then
            -- In-place doc refresh mode: rewrite COG templates in their source
            -- files, independent of reformat/export.
            refreshDocs(directories, #variants > 0 and variants or nil)
        else
            exportDir = normalizePath(exportDir)
            exportParams.exportDir = exportDir
            -- Resolve the SVG colour scheme + per-colour overrides into a single
            -- override table for the (scheme-agnostic) renderer. nil when neither
            -- was given, so the renderer keeps its own defaults.
            exportParams.svgColors = resolveSvgColors(svgSchemeName, svgColorOverrides)
            -- Edge palette (colour edges by source node): on by default with the
            -- built-in palette, replaced by an explicit --svg-edge-palette list,
            -- or turned off (single-colour edges) by --no-svg-edge-palette.
            if svgEdgePaletteOff then
                exportParams.svgEdgePalette = nil
            else
                exportParams.svgEdgePalette = svgEdgePalette or SVG_EDGE_PALETTE
            end
            -- Set exportExploded=false when --collapse-exploded is specified
            if collapseExploded then
                exportParams.exportExploded = false
            end
            -- Set cleanExportDir=true when --clean is specified
            if cleanExportDir then
                exportParams.cleanExportDir = true
            end
            -- Set stripCog=true when --strip-cog is specified: generated COG doc
            -- templates have their scaffolding removed on export (default off).
            if stripCog then
                exportParams.stripCog = true
            end
            -- --export-merged[=<dir>]: write the post-override merged snapshot.
            if mergedSet then
                exportParams.mergedDir = normalizePath(mergedDir)
            end
            -- --explain-patch[=<filter>]: track + print override lineage.
            if explainPatch ~= nil then
                exportParams.explainPatch = explainPatch
            end
            -- --check-conflicts: track lineage + print the conflicts-only report.
            if checkConflicts then
                exportParams.checkConflicts = true
            end
            -- --list-columns: print the format inventory (which columns/fields the
            -- loaded packages declare, and which they could be adopting).
            if listColumns then
                exportParams.listColumns = true
            end
            processFiles(directories, exporters, exportParams, #variants > 0 and variants or nil)
        end
    end
else
    logger:info("reformatter loaded as a module")
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    processFiles = processFiles,
    refreshDocs = refreshDocs,
    -- SVG colour policy (named palettes + CLI colour vocabulary), exposed for
    -- tests. The renderer stays scheme-agnostic; these live in the wrapper.
    resolveSvgColors = resolveSvgColors,
    SVG_SCHEMES = SVG_SCHEMES,
    SVG_COLOR_KEYS = SVG_COLOR_KEYS,
    SVG_EDGE_PALETTE = SVG_EDGE_PALETTE,
}

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
