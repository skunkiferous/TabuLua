-- tsv_diff.lua
-- Compares two TSV files at the data level, understanding columnar structure.
-- Supports order-based and primary-key-based comparison modes.

-- Module versioning
local semver = require("semver")
local VERSION = semver(0, 30, 0)
local NAME = "tsv_diff"

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
                named_logger.setGlobalLevel(named_logger.ERROR)
            end
            break
        end
    end
end

local logger = named_logger.getLogger(NAME)

local raw_tsv = require("tsv.raw_tsv")
local string_utils = require("util.string_utils")
local read_only = require("util.read_only")
local file_util = require("infra.file_util")
local compression = require("content.compression")

local readOnly = read_only.readOnly
local trim = string_utils.trim
local normalizePath = file_util.normalizePath
local isDir = file_util.isDir
local getFilesAndDirs = file_util.getFilesAndDirs
local readFileBinary = file_util.readFileBinary
local didYouMean = require("infra.error_reporting").didYouMean

-- Every recognised CLI option (bare flag names), for the Unknown option
-- did-you-mean. Kept next to the arg parser (an if/elseif chain).
local KNOWN_OPTIONS = {
    "--context", "--epsilon", "--exclude", "--ignore-case", "--log-level",
    "--map", "--max-diffs", "--mode", "--only", "--quiet", "--summary", "--trim",
}

-- ============================================================================
-- INPUT LOADING (compression-aware)
-- ============================================================================

-- Recognized compression extensions, mapped to their codec format name (see
-- compression.lua). A source file may carry one of these as its outermost
-- extension (e.g. `Item.tsv.gz`); it is transparently decompressed before being
-- parsed as TSV. Only gzip ships a provider today; adding a row here is all that
-- is needed once another codec (zstd, …) gains one.
local COMPRESSION_EXT = { gz = "gzip" }

-- Leading bytes of a gzip stream (RFC 1952 magic 0x1f 0x8b), used to sniff a
-- compressed file whose name does NOT advertise it.
local GZIP_MAGIC = "\031\139"

-- Determines the compression format of a source, by its outermost extension
-- first and then by magic-byte sniffing. Returns the codec format name (e.g.
-- "gzip") or nil for an uncompressed file.
local function detectCompression(path, bytes)
    local ext = path:match("%.([^.]+)$")
    local format = ext and COMPRESSION_EXT[ext:lower()]
    if not format and bytes:sub(1, #GZIP_MAGIC) == GZIP_MAGIC then
        format = "gzip"
    end
    return format
end

-- Strips a trailing compression extension from a name, yielding its "logical"
-- name (`Item.tsv.gz` -> `Item.tsv`). A name with no compression extension is
-- returned unchanged. This is what lets a compressed file in one tree pair with
-- its plain counterpart in the other during a directory comparison.
local function stripCompression(name)
    local ext = name:match("%.([^.]+)$")
    if ext and COMPRESSION_EXT[ext:lower()] then
        return name:sub(1, #name - #ext - 1)
    end
    return name
end

--- Loads a TSV file into a raw TSV structure, transparently decompressing a
--- compressed source (gzip, by `.gz` extension or magic bytes) and reading the
--- bytes verbatim so a virtual archive member path works too (file_util handles
--- the archive resolution). Replaces a direct raw_tsv.fileToRawTSV call so every
--- read path — single file or directory walk — gains compression support.
--- @param path string The file path (optionally inside an archive)
--- @return table|nil The raw TSV structure, or nil on error
--- @return string|nil Error message on failure, nil on success
local function loadRawTSV(path)
    local bytes, err = readFileBinary(path)
    if not bytes then
        return nil, err
    end
    local format = detectCompression(path, bytes)
    if format then
        local data, derr = compression.decompress(format, bytes)
        if not data then
            return nil, format .. " decompression failed: " .. tostring(derr)
        end
        bytes = data
    end
    -- stringToRawTSV asserts on invalid UTF-8 / non-string; trap it so a bad
    -- file becomes a clean (nil, err) instead of propagating through a dir walk.
    local ok, raw = pcall(raw_tsv.stringToRawTSV, bytes)
    if not ok then
        return nil, tostring(raw)
    end
    return raw
end

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

--- Extracts data rows from a raw TSV structure, skipping comments and blanks.
--- @param raw table A raw TSV structure from raw_tsv.stringToRawTSV
--- @return table|nil header The first data row (column headers), or nil on error
--- @return table|nil rows Sequence of data rows, or nil on error
--- @return string|nil err Error message if no header found
local function extractDataRows(raw)
    local header = nil
    local rows = {}
    for _, line in ipairs(raw) do
        if type(line) == "table" then
            if not header then
                header = line
            else
                rows[#rows + 1] = line
            end
        end
        -- skip strings (comments and blank lines)
    end
    if not header then
        return nil, nil, "file contains no data rows (no header found)"
    end
    return header, rows
end

--- Builds a map from column name to index for a header row.
--- @param header table Sequence of column name strings
--- @return table Map from column name to its 1-based index
local function headerIndex(header)
    local idx = {}
    for i, col in ipairs(header) do
        idx[col] = i
    end
    return idx
end

--- Normalizes a cell value according to diff options.
--- @param val string The cell value
--- @param options table The diff options
--- @return string The normalized value
local function normalizeValue(val, options)
    if val == nil then
        val = ""
    end
    if options.trim then
        val = trim(val)
    end
    if options.ignoreCase then
        val = val:lower()
    end
    return val
end

--- Compares two cell values, respecting epsilon for numeric values.
--- @param val1 string First value (already normalized)
--- @param val2 string Second value (already normalized)
--- @param epsilon number|nil Numeric tolerance, or nil for exact comparison
--- @return boolean True if values are considered equal
local function valuesEqual(val1, val2, epsilon)
    if val1 == val2 then
        return true
    end
    if epsilon then
        local n1 = tonumber(val1)
        local n2 = tonumber(val2)
        if n1 and n2 then
            return math.abs(n1 - n2) <= epsilon
        end
    end
    return false
end

--- Resolves column mappings and identifies common, added, and removed columns.
--- @param header1 table Header row from file 1
--- @param header2 table Header row from file 2
--- @param options table Diff options (may contain columnMap, only, exclude)
--- @return table result Table with fields:
---   commonCols: sequence of {name1, idx1, name2, idx2}
---   addedCols: sequence of column names only in file 2
---   removedCols: sequence of column names only in file 1
---   pkMatch: boolean, true if primary key columns match
---   pkName1: string, primary key column name in file 1
---   pkName2: string, primary key column name in file 2
local function resolveColumns(header1, header2, options)
    local columnMap = options.columnMap or {}
    local only = options.only
    local exclude = options.exclude or {}

    -- Build exclude set
    local excludeSet = {}
    for _, col in ipairs(exclude) do
        excludeSet[col] = true
    end

    -- Build index maps
    local idx1 = headerIndex(header1)
    local idx2 = headerIndex(header2)

    -- Build forward and reverse mapping from columnMap
    -- columnMap is {old_name = new_name}, mapping file1 names to file2 names
    local map1to2 = {}
    local map2to1 = {}
    for name1, name2 in pairs(columnMap) do
        map1to2[name1] = name2
        map2to1[name2] = name1
    end

    -- Primary key is always column 1
    local pkName1 = header1[1]
    local pkName2 = header2[1]
    local pkMapped = map1to2[pkName1]
    local pkMatch = (pkName1 == pkName2) or (pkMapped == pkName2)

    -- Find common columns
    local commonCols = {}
    local matched2 = {} -- track which file2 columns are matched

    for i, name1 in ipairs(header1) do
        if not excludeSet[name1] then
            local name2 = map1to2[name1] or name1
            if idx2[name2] then
                if not only or only[name1] or only[name2] then
                    commonCols[#commonCols + 1] = {
                        name1 = name1,
                        idx1 = i,
                        name2 = name2,
                        idx2 = idx2[name2],
                    }
                    matched2[name2] = true
                end
            end
        end
    end

    -- Find added columns (in file 2 but not in file 1)
    local addedCols = {}
    for _, name2 in ipairs(header2) do
        if not matched2[name2] and not excludeSet[name2] then
            -- Skip columns filtered out by --only
            if only and not only[name2] then
                -- intentionally ignored
            elseif not map2to1[name2] or not idx1[map2to1[name2]] then
                addedCols[#addedCols + 1] = name2
            end
        end
    end

    -- Find removed columns (in file 1 but not in file 2)
    local removedCols = {}
    local matchedFromFile1 = {}
    for _, cc in ipairs(commonCols) do
        matchedFromFile1[cc.name1] = true
    end
    for _, name1 in ipairs(header1) do
        if not matchedFromFile1[name1] and not excludeSet[name1] then
            -- Skip columns filtered out by --only
            if not only or only[name1] then
                removedCols[#removedCols + 1] = name1
            end
        end
    end

    return {
        commonCols = commonCols,
        addedCols = addedCols,
        removedCols = removedCols,
        pkMatch = pkMatch,
        pkName1 = pkName1,
        pkName2 = pkName2,
    }
end

--- Compares two rows on the common columns.
--- @param row1 table|nil Row from file 1 (sequence of cell strings), nil if missing
--- @param row2 table|nil Row from file 2 (sequence of cell strings), nil if missing
--- @param commonCols table Sequence of {name1, idx1, name2, idx2}
--- @param options table Diff options
--- @return table|nil Sequence of {col, val1, val2} for differing cells, or nil if equal
local function compareRow(row1, row2, commonCols, options)
    local diffs = nil
    for _, cc in ipairs(commonCols) do
        local raw1 = row1 and (row1[cc.idx1] or "") or ""
        local raw2 = row2 and (row2[cc.idx2] or "") or ""
        local v1 = normalizeValue(raw1, options)
        local v2 = normalizeValue(raw2, options)
        if not valuesEqual(v1, v2, options.epsilon) then
            if not diffs then
                diffs = {}
            end
            diffs[#diffs + 1] = {
                col = cc.name1,
                val1 = raw1,
                val2 = raw2,
            }
        end
    end
    return diffs
end

-- ============================================================================
-- ORDER-BASED COMPARISON
-- ============================================================================

--- Compares two TSV data sets by row position.
--- @param rows1 table Sequence of data rows from file 1
--- @param rows2 table Sequence of data rows from file 2
--- @param commonCols table Common column descriptors
--- @param options table Diff options
--- @return table entries Sequence of diff entries: {type, rowIdx, row1, row2, diffs}
--- @return number diffCount Number of differences found
local function compareOrderBased(rows1, rows2, commonCols, options)
    local maxDiffs = options.maxDiffs or math.huge
    local context = options.context or 0
    local result = {}
    local diffCount = 0

    local maxRows = math.max(#rows1, #rows2)

    -- First pass: identify which rows have differences
    local rowDiffs = {} -- rowIdx -> diffs table or "added"/"removed" string
    for i = 1, maxRows do
        if diffCount >= maxDiffs then
            break
        end
        local r1 = rows1[i]
        local r2 = rows2[i]
        if r1 and r2 then
            local diffs = compareRow(r1, r2, commonCols, options)
            if diffs then
                rowDiffs[i] = { type = "changed", diffs = diffs }
                diffCount = diffCount + 1
            end
        elseif r1 and not r2 then
            rowDiffs[i] = { type = "removed" }
            diffCount = diffCount + 1
        elseif r2 and not r1 then
            rowDiffs[i] = { type = "added" }
            diffCount = diffCount + 1
        end
    end

    -- Second pass: collect diff entries with context
    local inContext = {} -- set of row indices to include
    for i = 1, maxRows do
        if rowDiffs[i] then
            -- Add context lines around this diff
            for j = math.max(1, i - context), math.min(maxRows, i + context) do
                inContext[j] = true
            end
        end
    end

    local lastOutput = 0
    for i = 1, maxRows do
        if inContext[i] then
            -- Insert separator if there's a gap
            if lastOutput > 0 and i > lastOutput + 1 then
                result[#result + 1] = { type = "separator", rowIdx = i }
            end
            local r1 = rows1[i]
            local r2 = rows2[i]
            if rowDiffs[i] then
                result[#result + 1] = {
                    type = rowDiffs[i].type,
                    rowIdx = i,
                    row1 = r1,
                    row2 = r2,
                    diffs = rowDiffs[i].diffs,
                }
            else
                -- Context line (unchanged)
                result[#result + 1] = {
                    type = "context",
                    rowIdx = i,
                    row1 = r1,
                    row2 = r2,
                }
            end
            lastOutput = i
        end
    end

    return result, diffCount
end

-- ============================================================================
-- PRIMARY-KEY-BASED COMPARISON
-- ============================================================================

--- Compares two TSV data sets by primary key values.
--- @param rows1 table Sequence of data rows from file 1
--- @param rows2 table Sequence of data rows from file 2
--- @param commonCols table Common column descriptors
--- @param pkIdx1 number Column index of primary key in file 1
--- @param pkIdx2 number Column index of primary key in file 2
--- @param options table Diff options
--- @return table entries Sequence of diff entries: {type, pk, row1, row2, diffs}
--- @return number diffCount Number of differences found
local function comparePKBased(rows1, rows2, commonCols, pkIdx1, pkIdx2, options)
    local maxDiffs = options.maxDiffs or math.huge
    local result = {}
    local diffCount = 0

    -- Build PK index for file 2.
    -- These rows come from raw TSV (stringToRawTSV), not from processTSV,
    -- so there is no native opt_index to reuse. Even if there were, the PKs
    -- are passed through normalizeValue (whitespace/case folding per
    -- options) before being used as keys, so the key shape would not match
    -- the dataset's tostring(evaluated) keys. Building a local map is the
    -- correct approach here.
    local pk2Map = {} -- pk_value -> row
    for _, row in ipairs(rows2) do
        local pk = normalizeValue(row[pkIdx2] or "", options)
        if pk2Map[pk] then
            logger:warn("Duplicate primary key in file 2: " .. pk)
        end
        pk2Map[pk] = row
    end

    -- Track which file 2 PKs are matched
    local matched2 = {}

    -- Compare rows from file 1 against file 2
    for _, row1 in ipairs(rows1) do
        if diffCount >= maxDiffs then
            break
        end
        local pk = normalizeValue(row1[pkIdx1] or "", options)
        local row2 = pk2Map[pk]
        if row2 then
            matched2[pk] = true
            local diffs = compareRow(row1, row2, commonCols, options)
            if diffs then
                result[#result + 1] = {
                    type = "changed",
                    pk = row1[pkIdx1],
                    row1 = row1,
                    row2 = row2,
                    diffs = diffs,
                }
                diffCount = diffCount + 1
            end
        else
            result[#result + 1] = {
                type = "removed",
                pk = row1[pkIdx1],
                row1 = row1,
            }
            diffCount = diffCount + 1
        end
    end

    -- Find rows in file 2 not matched
    for _, row2 in ipairs(rows2) do
        if diffCount >= maxDiffs then
            break
        end
        local pk = normalizeValue(row2[pkIdx2] or "", options)
        if not matched2[pk] then
            result[#result + 1] = {
                type = "added",
                pk = row2[pkIdx2],
                row2 = row2,
            }
            diffCount = diffCount + 1
        end
    end

    return result, diffCount
end

-- ============================================================================
-- OUTPUT FORMATTING
-- ============================================================================

--- Formats a column analysis report.
--- @param colInfo table The result from resolveColumns
--- @return table Sequence of output lines
local function formatColumnReport(colInfo)
    local lines = {}
    lines[#lines + 1] = "=== Column Analysis ==="

    if colInfo.pkMatch then
        lines[#lines + 1] = "Primary key: " .. colInfo.pkName1
        if colInfo.pkName1 ~= colInfo.pkName2 then
            lines[#lines + 1] = "  (mapped from '" .. colInfo.pkName1 .. "' to '" .. colInfo.pkName2 .. "')"
        end
    else
        lines[#lines + 1] = "Primary key MISMATCH: '" .. colInfo.pkName1 .. "' vs '" .. colInfo.pkName2 .. "'"
    end

    lines[#lines + 1] = "Common columns: " .. #colInfo.commonCols
    if #colInfo.addedCols > 0 then
        lines[#lines + 1] = "Added columns (only in file 2): " .. table.concat(colInfo.addedCols, ", ")
    end
    if #colInfo.removedCols > 0 then
        lines[#lines + 1] = "Removed columns (only in file 1): " .. table.concat(colInfo.removedCols, ", ")
    end

    -- Show column mappings
    local hasMappings = false
    for _, cc in ipairs(colInfo.commonCols) do
        if cc.name1 ~= cc.name2 then
            if not hasMappings then
                lines[#lines + 1] = "Column mappings:"
                hasMappings = true
            end
            lines[#lines + 1] = "  '" .. cc.name1 .. "' <-> '" .. cc.name2 .. "'"
        end
    end

    return lines
end

--- Formats cell-level diffs for a single row.
--- @param diffs table Sequence of {col, val1, val2}
--- @return table Sequence of output lines
local function formatCellDiffs(diffs)
    local lines = {}
    for _, d in ipairs(diffs) do
        lines[#lines + 1] = "    " .. d.col .. ": '" .. d.val1 .. "' -> '" .. d.val2 .. "'"
    end
    return lines
end

--- Formats diff results in unified-diff style for order-based mode.
--- @param entries table Sequence of diff entries from compareOrderBased
--- @param diffCount number Total number of differences found
--- @param file1 string File 1 path/name
--- @param file2 string File 2 path/name
--- @param options table Diff options
--- @return table Sequence of output lines
local function formatOrderBased(entries, diffCount, file1, file2, options)
    local lines = {}
    lines[#lines + 1] = "--- " .. file1
    lines[#lines + 1] = "+++ " .. file2
    lines[#lines + 1] = ""

    for _, entry in ipairs(entries) do
        if entry.type == "separator" then
            lines[#lines + 1] = "..."
        elseif entry.type == "context" then
            -- Show first cell as identifier for context lines
            local label = entry.row1 and entry.row1[1] or "?"
            lines[#lines + 1] = "  row " .. entry.rowIdx .. " [" .. label .. "]"
        elseif entry.type == "removed" then
            local label = entry.row1 and entry.row1[1] or "?"
            lines[#lines + 1] = "- row " .. entry.rowIdx .. " [" .. label .. "]"
        elseif entry.type == "added" then
            local label = entry.row2 and entry.row2[1] or "?"
            lines[#lines + 1] = "+ row " .. entry.rowIdx .. " [" .. label .. "]"
        elseif entry.type == "changed" then
            local label = entry.row1 and entry.row1[1] or "?"
            lines[#lines + 1] = "~ row " .. entry.rowIdx .. " [" .. label .. "]"
            if entry.diffs and not options.summary then
                for _, line in ipairs(formatCellDiffs(entry.diffs)) do
                    lines[#lines + 1] = line
                end
            end
        end
    end

    if options.maxDiffs and diffCount >= options.maxDiffs then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "(output truncated after " .. options.maxDiffs .. " differences)"
    end

    return lines
end

--- Formats diff results for primary-key-based mode.
--- @param entries table Sequence of diff entries from comparePKBased
--- @param diffCount number Total number of differences found
--- @param file1 string File 1 path/name
--- @param file2 string File 2 path/name
--- @param options table Diff options
--- @return table Sequence of output lines
local function formatPKBased(entries, diffCount, file1, file2, options)
    local lines = {}
    lines[#lines + 1] = "--- " .. file1
    lines[#lines + 1] = "+++ " .. file2
    lines[#lines + 1] = ""

    local changedCount, addedCount, removedCount = 0, 0, 0

    for _, entry in ipairs(entries) do
        if entry.type == "removed" then
            removedCount = removedCount + 1
            lines[#lines + 1] = "- [" .. entry.pk .. "]"
        elseif entry.type == "added" then
            addedCount = addedCount + 1
            lines[#lines + 1] = "+ [" .. entry.pk .. "]"
        elseif entry.type == "changed" then
            changedCount = changedCount + 1
            lines[#lines + 1] = "~ [" .. entry.pk .. "]"
            if entry.diffs and not options.summary then
                for _, line in ipairs(formatCellDiffs(entry.diffs)) do
                    lines[#lines + 1] = line
                end
            end
        end
    end

    if options.maxDiffs and diffCount >= options.maxDiffs then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "(output truncated after " .. options.maxDiffs .. " differences)"
    end

    return lines
end

--- Formats a summary of differences.
--- @param diffCount number Total number of row differences
--- @param colInfo table Column analysis result
--- @param mode string "order" or "pk"
--- @param entries table Diff entries (for pk mode breakdown)
--- @return table Sequence of output lines
local function formatSummary(diffCount, colInfo, mode, entries)
    local lines = {}
    lines[#lines + 1] = ""
    lines[#lines + 1] = "=== Summary ==="
    lines[#lines + 1] = "Common columns compared: " .. #colInfo.commonCols
    if #colInfo.addedCols > 0 then
        lines[#lines + 1] = "Columns only in file 2: " .. #colInfo.addedCols
    end
    if #colInfo.removedCols > 0 then
        lines[#lines + 1] = "Columns only in file 1: " .. #colInfo.removedCols
    end

    if mode == "pk" then
        local changed, added, removed = 0, 0, 0
        for _, entry in ipairs(entries) do
            if entry.type == "changed" then changed = changed + 1
            elseif entry.type == "added" then added = added + 1
            elseif entry.type == "removed" then removed = removed + 1
            end
        end
        lines[#lines + 1] = "Rows changed: " .. changed
        lines[#lines + 1] = "Rows added: " .. added
        lines[#lines + 1] = "Rows removed: " .. removed
        lines[#lines + 1] = "Total differences: " .. diffCount
    else
        lines[#lines + 1] = "Row differences: " .. diffCount
    end

    if diffCount == 0 then
        lines[#lines + 1] = "Files are identical (on compared columns)."
    end

    return lines
end

-- ============================================================================
-- MAIN DIFF FUNCTION
-- ============================================================================

-- Forward declaration: diff dispatches to diffDirectories (defined below) for
-- directory inputs, and diffDirectories calls diff back on each file pair.
local diffDirectories

--- Compares two TSV data sets.
--- @param input1 string|table Either a file path (string) or a raw TSV structure (table)
--- @param input2 string|table Either a file path (string) or a raw TSV structure (table)
--- @param options table|nil Diff options:
---   mode: "order" (default) or "pk" (primary-key-based)
---   columnMap: table mapping file1 column names to file2 column names
---   trim: boolean, trim leading/trailing whitespace from values
---   ignoreCase: boolean, case-insensitive comparison
---   epsilon: number, numeric tolerance for floating-point comparison
---   only: table (set), only compare these columns
---   exclude: table (sequence), exclude these columns from comparison
---   context: number, context lines around diffs (order mode only, default 0)
---   maxDiffs: number, stop after this many differences
---   summary: boolean, show summary counts only (suppress cell-level detail)
---   quiet: boolean, produce no output (only return status)
--- When both inputs are paths to existing directories, the comparison switches
--- to DIRECTORY MODE: the two trees are walked recursively and compared file by
--- file (see diffDirectories). In that case the 3rd return is a stats table and
--- the 4th is nil.
--- @return boolean|nil identical True if files are identical, false if not, nil on error
--- @return string output The formatted diff output, or error message on failure
--- @return number|table|nil diffCount Row-diff count (file mode) or stats table (dir mode), nil on error
--- @return table|nil colInfo Column analysis result (file mode only), nil on error
local function diff(input1, input2, options)
    options = options or {}

    -- Directory mode: when both inputs are paths to existing directories, compare
    -- the two trees recursively rather than treating each as a single TSV file.
    if type(input1) == "string" and type(input2) == "string"
        and isDir(input1) and isDir(input2) then
        return diffDirectories(input1, input2, options)
    end

    local mode = options.mode or "order"
    assert(mode == "order" or mode == "pk",
        "mode must be 'order' or 'pk', got: " .. tostring(mode))

    -- Load inputs
    local raw1, raw2, err
    if type(input1) == "string" then
        raw1, err = loadRawTSV(input1)
        if not raw1 then
            return nil, "Error reading file 1: " .. (err or "unknown error")
        end
    elseif type(input1) == "table" then
        raw1 = input1
    else
        return nil, "input1 must be a file path (string) or raw TSV table"
    end

    if type(input2) == "string" then
        raw2, err = loadRawTSV(input2)
        if not raw2 then
            return nil, "Error reading file 2: " .. (err or "unknown error")
        end
    elseif type(input2) == "table" then
        raw2 = input2
    else
        return nil, "input2 must be a file path (string) or raw TSV table"
    end

    -- Extract headers and data rows
    local header1, rows1, err1 = extractDataRows(raw1)
    if not header1 then
        return nil, "File 1: " .. err1
    end
    local header2, rows2, err2 = extractDataRows(raw2)
    if not header2 then
        return nil, "File 2: " .. err2
    end

    -- Resolve column structure
    local colInfo = resolveColumns(header1, header2, options)

    -- Name inputs for display
    local name1 = type(input1) == "string" and input1 or "file1"
    local name2 = type(input2) == "string" and input2 or "file2"

    -- Build output
    local outputLines = {}

    -- Column analysis
    for _, line in ipairs(formatColumnReport(colInfo)) do
        outputLines[#outputLines + 1] = line
    end
    outputLines[#outputLines + 1] = ""

    -- Perform comparison
    local entries, diffCount
    if mode == "pk" then
        if not colInfo.pkMatch then
            return nil, "Cannot use primary-key mode: primary key columns differ ('"
                .. colInfo.pkName1 .. "' vs '" .. colInfo.pkName2
                .. "'). Use --map to align them."
        end
        -- Find pk column in common cols (it's always the first common col if matched)
        local pkIdx1 = 1
        local pkIdx2 = colInfo.commonCols[1] and colInfo.commonCols[1].idx2 or 1
        -- Ensure PK column is in common cols
        for _, cc in ipairs(colInfo.commonCols) do
            if cc.name1 == colInfo.pkName1 then
                pkIdx1 = cc.idx1
                pkIdx2 = cc.idx2
                break
            end
        end
        entries, diffCount = comparePKBased(rows1, rows2, colInfo.commonCols,
            pkIdx1, pkIdx2, options)
    else
        entries, diffCount = compareOrderBased(rows1, rows2, colInfo.commonCols, options)
    end

    -- Format diff output
    local diffLines
    if mode == "pk" then
        diffLines = formatPKBased(entries, diffCount, name1, name2, options)
    else
        diffLines = formatOrderBased(entries, diffCount, name1, name2, options)
    end

    if not options.quiet then
        for _, line in ipairs(diffLines) do
            outputLines[#outputLines + 1] = line
        end
    end

    -- Summary
    for _, line in ipairs(formatSummary(diffCount, colInfo, mode, entries)) do
        outputLines[#outputLines + 1] = line
    end

    local output = table.concat(outputLines, "\n") .. "\n"
    local identical = (diffCount == 0 and #colInfo.addedCols == 0 and #colInfo.removedCols == 0)

    return identical, output, diffCount, colInfo
end

-- ============================================================================
-- DIRECTORY MODE
-- ============================================================================

-- Data-file extensions recognized when walking a directory tree. A file whose
-- name (after any compression extension is peeled by stripCompression) ends in
-- one of these is treated as a comparable TSV data file; everything else in the
-- tree is ignored. Kept as a set so other tabular extensions could be added.
local DATA_EXTENSIONS = { tsv = true }

-- True iff a logical (compression-stripped) name denotes a comparable data file.
local function isDataFile(logicalName)
    local ext = logicalName:match("%.([^.]+)$")
    return ext ~= nil and DATA_EXTENSIONS[ext:lower()] == true
end

-- Walks `dir` recursively and returns a map from each data file's LOGICAL
-- relative path (relative to `dir`, with any compression extension peeled) to
-- its actual full path on disk. Keying by the logical path is what pairs a
-- compressed file in one tree (`x/Item.tsv.gz`) with a plain one in the other
-- (`x/Item.tsv`). Returns (nil, err) if the tree cannot be read. A collision
-- (e.g. both `Item.tsv` and `Item.tsv.gz` present) keeps the first and warns.
local function collectDataFiles(dir)
    local normDir = normalizePath(dir)
    local files, err = getFilesAndDirs(normDir, true)
    if not files then
        return nil, err
    end
    local prefix = normDir .. "/"
    local map = {}
    for _, full in ipairs(files) do
        local rel = full
        if full:sub(1, #prefix) == prefix then
            rel = full:sub(#prefix + 1)
        end
        local logical = stripCompression(rel)
        if isDataFile(logical) then
            if map[logical] then
                logger:warn(("Multiple files map to '%s' under %s; keeping '%s', ignoring '%s'")
                    :format(logical, dir, map[logical], full))
            else
                map[logical] = full
            end
        end
    end
    return map
end

-- Splits a string that ends in "\n" into its lines (the trailing newline yields
-- no extra empty element). Used to re-indent a per-file diff under its banner.
local function splitLines(s)
    local out = {}
    for line in s:gmatch("(.-)\n") do
        out[#out + 1] = line
    end
    return out
end

--- Compares two directory trees recursively. Data files are paired by their
--- compression-stripped relative path, so `Item.tsv` and `Item.tsv.gz` match and
--- their UNCOMPRESSED contents are diffed. Each pair present in both trees is run
--- through diff() with the same options; files present in only one tree are
--- reported as added/removed. The output lists every file with a one-character
--- status marker (`=` identical, `~` differs, `+`/`-` only on one side, `!`
--- error), inlining each differing file's full diff (indented) unless --summary
--- or --quiet is set, and ends with an overall directory summary.
--- @param dir1 string Path to the first (left) directory
--- @param dir2 string Path to the second (right) directory
--- @param options table|nil The same options table accepted by diff()
--- @return boolean|nil identical True if the trees match, false if not, nil on error
--- @return string output The formatted report, or an error message on failure
--- @return table|nil stats {compared, differing, only1, only2, errors}, nil on error
function diffDirectories(dir1, dir2, options)
    options = options or {}

    local map1, e1 = collectDataFiles(dir1)
    if not map1 then
        return nil, "Error scanning directory 1: " .. tostring(e1)
    end
    local map2, e2 = collectDataFiles(dir2)
    if not map2 then
        return nil, "Error scanning directory 2: " .. tostring(e2)
    end

    -- Union of logical keys from both trees, sorted for stable output.
    local keySet = {}
    for k in pairs(map1) do keySet[k] = true end
    for k in pairs(map2) do keySet[k] = true end
    local keys = {}
    for k in pairs(keySet) do keys[#keys + 1] = k end
    table.sort(keys)

    local lines = {}
    lines[#lines + 1] = "--- " .. dir1
    lines[#lines + 1] = "+++ " .. dir2
    lines[#lines + 1] = ""

    local stats = { compared = 0, differing = 0, only1 = 0, only2 = 0, errors = 0 }

    for _, key in ipairs(keys) do
        local f1 = map1[key]
        local f2 = map2[key]
        if f1 and f2 then
            stats.compared = stats.compared + 1
            local identical, out, diffCount = diff(f1, f2, options)
            if identical == nil then
                -- out holds the error message for this pair.
                stats.errors = stats.errors + 1
                lines[#lines + 1] = "! " .. key .. "  (error: " .. tostring(out) .. ")"
            elseif identical then
                if not options.quiet then
                    lines[#lines + 1] = "= " .. key
                end
            else
                stats.differing = stats.differing + 1
                local n = type(diffCount) == "number" and diffCount or 0
                lines[#lines + 1] = "~ " .. key .. "  ("
                    .. n .. " row diff" .. (n == 1 and "" or "s") .. ")"
                if not options.summary and not options.quiet then
                    for _, l in ipairs(splitLines(out)) do
                        lines[#lines + 1] = "    " .. l
                    end
                    lines[#lines + 1] = ""
                end
            end
        elseif f1 then
            stats.only1 = stats.only1 + 1
            lines[#lines + 1] = "- " .. key .. "  (only in " .. dir1 .. ")"
        else
            stats.only2 = stats.only2 + 1
            lines[#lines + 1] = "+ " .. key .. "  (only in " .. dir2 .. ")"
        end
    end

    -- Overall summary.
    lines[#lines + 1] = ""
    lines[#lines + 1] = "=== Directory Summary ==="
    lines[#lines + 1] = "Files compared: " .. stats.compared
    lines[#lines + 1] = "Files differing: " .. stats.differing
    lines[#lines + 1] = "Only in " .. dir1 .. ": " .. stats.only1
    lines[#lines + 1] = "Only in " .. dir2 .. ": " .. stats.only2
    if stats.errors > 0 then
        lines[#lines + 1] = "Errors: " .. stats.errors
    end

    local identical = (stats.differing == 0 and stats.only1 == 0
        and stats.only2 == 0 and stats.errors == 0)
    if identical then
        lines[#lines + 1] = "Directories are identical (on compared files)."
    end

    return identical, table.concat(lines, "\n") .. "\n", stats
end

-- ============================================================================
-- CLI
-- ============================================================================

local function generateUsage()
    return [[
Usage: lua54 tsv_diff.lua <path1> <path2> [options]

Compares two TSV files at the data level, OR two directories recursively.

Arguments:
  path1             First TSV file, or a directory
  path2             Second TSV file, or a directory
                    (both must be files, or both must be directories)

Compressed sources (e.g. file.tsv.gz) are decompressed transparently and their
uncompressed contents compared. In directory mode, files are paired by their
relative path with any compression extension peeled, so 'Item.tsv' in one tree
matches 'Item.tsv.gz' in the other.

Modes:
  --mode=order      Compare rows by position (default)
  --mode=pk         Compare rows by primary key (first column)

Options:
  --map=OLD/NEW           Map column name OLD in file 1 to NEW in file 2.
                          Can be specified multiple times.
  --trim                  Ignore leading/trailing whitespace in cell values
  --ignore-case           Case-insensitive cell comparison
  --epsilon=N             Treat numbers within N of each other as equal
                          (N can be a floating-point value, e.g. 0.001)
  --only=COL1,COL2,...    Only compare these columns
  --exclude=COL1,COL2,... Exclude these columns from comparison
  --context=N             Show N context rows around differences (order mode)
  --max-diffs=N           Stop after N differences
  --summary               Show only summary counts, suppress cell-level detail
  --quiet                 Suppress diff output, show only summary
  --log-level=LEVEL       Set log level (debug, info, warn, error, fatal)

Exit codes:
  0   Inputs are identical (files: on compared columns; dirs: on compared files)
  1   Differences found
  2   Error (bad arguments, unreadable files, etc.)]]
end

local isMainScript = arg and arg[0] and arg[0]:match("tsv_diff")
if isMainScript then
    if #arg == 0 then
        print(generateUsage())
        os.exit(1)
    end

    local file1, file2, hasError = nil, nil, false
    local cliOptions = {}
    local columnMapList = {}
    local cliLogger = named_logger.getLogger(NAME)

    for i = 1, #arg do
        local a = arg[i]
        if a == "--trim" then
            cliOptions.trim = true
        elseif a == "--ignore-case" then
            cliOptions.ignoreCase = true
        elseif a == "--summary" then
            cliOptions.summary = true
        elseif a == "--quiet" then
            cliOptions.quiet = true
        elseif a:match("^%-%-mode=") then
            local m = a:match("^%-%-mode=(.+)$")
            if m ~= "order" and m ~= "pk" then
                cliLogger:error("Invalid mode: " .. m .. " (must be 'order' or 'pk')")
                hasError = true
            else
                cliOptions.mode = m
            end
        elseif a:match("^%-%-map=") then
            local mapping = a:match("^%-%-map=(.+)$")
            local old, new = mapping:match("^([^/]+)/(.+)$")
            if not old then
                cliLogger:error("Invalid column mapping (expected OLD/NEW): " .. mapping)
                hasError = true
            else
                columnMapList[#columnMapList + 1] = { old, new }
            end
        elseif a:match("^%-%-epsilon=") then
            local eps = tonumber(a:match("^%-%-epsilon=(.+)$"))
            if not eps or eps < 0 then
                cliLogger:error("Invalid epsilon value: " .. a:match("^%-%-epsilon=(.+)$"))
                hasError = true
            else
                cliOptions.epsilon = eps
            end
        elseif a:match("^%-%-only=") then
            local cols = a:match("^%-%-only=(.+)$")
            local onlySet = {}
            for col in cols:gmatch("[^,]+") do
                onlySet[trim(col)] = true
            end
            cliOptions.only = onlySet
        elseif a:match("^%-%-exclude=") then
            local cols = a:match("^%-%-exclude=(.+)$")
            local excludeList = {}
            for col in cols:gmatch("[^,]+") do
                excludeList[#excludeList + 1] = trim(col)
            end
            cliOptions.exclude = excludeList
        elseif a:match("^%-%-context=") then
            local n = tonumber(a:match("^%-%-context=(.+)$"))
            if not n or n < 0 or n ~= math.floor(n) then
                cliLogger:error("Invalid context value (must be non-negative integer): " .. a)
                hasError = true
            else
                cliOptions.context = n
            end
        elseif a:match("^%-%-max%-diffs=") then
            local n = tonumber(a:match("^%-%-max%-diffs=(.+)$"))
            if not n or n < 1 or n ~= math.floor(n) then
                cliLogger:error("Invalid max-diffs value (must be positive integer): " .. a)
                hasError = true
            else
                cliOptions.maxDiffs = n
            end
        elseif a:match("^%-%-log%-level=") then
            local levelName = a:match("^%-%-log%-level=(.+)$")
            if not LOG_LEVELS[levelName:lower()] then
                cliLogger:error("Unknown log level: " .. levelName
                    .. didYouMean(levelName:lower(), LOG_LEVELS))
                cliLogger:error("Valid levels: debug, info, warn, error, fatal")
                hasError = true
            end
        elseif a:match("^%-%-") then
            local flag = a:match("^(%-%-[%w%-]+)") or a
            cliLogger:error("Unknown option: " .. a
                .. didYouMean(flag, KNOWN_OPTIONS))
            hasError = true
        elseif not file1 then
            file1 = normalizePath(a)
        elseif not file2 then
            file2 = normalizePath(a)
        else
            cliLogger:error("Unexpected argument: " .. a)
            hasError = true
        end
    end

    -- Build column map
    if #columnMapList > 0 then
        local cm = {}
        for _, pair in ipairs(columnMapList) do
            cm[pair[1]] = pair[2]
        end
        cliOptions.columnMap = cm
    end

    if not file1 then
        cliLogger:error("Missing required argument: <path1>")
        hasError = true
    end
    if not file2 then
        cliLogger:error("Missing required argument: <path2>")
        hasError = true
    end

    -- Both paths must be the same kind: two files or two directories. A mismatch
    -- (one of each) is almost always a mistake, and diff() would otherwise try to
    -- read the directory as a TSV file and fail with a confusing message.
    if file1 and file2 and (isDir(file1) ~= isDir(file2)) then
        cliLogger:error("Cannot compare a file with a directory: '"
            .. file1 .. "' and '" .. file2 .. "' must both be files or both directories")
        hasError = true
    end

    if hasError then
        print("\nUse 'lua54 tsv_diff.lua' without arguments to see usage.")
        os.exit(2)
    end

    local identical, output, _, _ = diff(file1, file2, cliOptions)
    if identical == nil then
        -- output contains the error message
        cliLogger:error(output)
        os.exit(2)
    end

    print(output)

    if identical then
        os.exit(0)
    else
        os.exit(1)
    end
end

-- ============================================================================
-- MODULE API
-- ============================================================================

--- Returns the module version as a string.
--- @return string The semantic version string
local function getVersion()
    return tostring(VERSION)
end

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    diff = diff,
    diffDirectories = diffDirectories,
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
