-- ollama_batch.lua
-- Batch-processes TSV rows through a local Ollama LLM.
-- Reads a config TSV, sends batches to Ollama, tracks progress in a TSV file.
-- Supports input/output transformation via external Lua code, and reference data.

-- Module versioning
local semver = require("semver")
local VERSION = semver(0, 20, 0)
local NAME = "ollama_batch"

local named_logger = require("named_logger")

-- Map of log level name strings to level constants
local LOG_LEVELS = {
    ["debug"] = named_logger.DEBUG,
    ["info"]  = named_logger.INFO,
    ["warn"]  = named_logger.WARN,
    ["error"] = named_logger.ERROR,
    ["fatal"] = named_logger.FATAL,
}

-- Apply --log-level early, before other modules are loaded
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

local raw_tsv = require("raw_tsv")
local string_utils = require("string_utils")
local file_util = require("file_util")
local read_only = require("read_only")
local dkjson = require("dkjson")

local readOnly = read_only.readOnly
local split = string_utils.split
local trim = string_utils.trim
local normalizePath = file_util.normalizePath
local readFile = file_util.readFile
local writeFile = file_util.writeFile
local pathJoin = file_util.pathJoin

local http = require("socket.http")
local ltn12 = require("ltn12")

--- Returns the module version as a string.
--- @return string
local function getVersion()
    return tostring(VERSION)
end

---------------------------------------------------------------------------
-- Config loading
---------------------------------------------------------------------------

--- Required config keys (must be present in the config TSV).
local REQUIRED_KEYS = {
    "input_file", "input_columns", "generated_columns",
    "output_file", "output_columns", "prompt_file", "progress_file",
}

--- Default values for optional config keys.
local CONFIG_DEFAULTS = {
    model = "qwen2.5:32b",
    batch_size = "30",
    timeout = "500",
    ollama_url = "http://localhost:11434/api/generate",
    temperature = "0.1",
    max_tokens = "4096",
    inter_batch_delay = "1",
    error_delay = "2",
}

--- Load a config TSV file (key/value pairs).
--- @param configFile string Path to the config TSV
--- @return table|nil Config table, or nil on error
--- @return string|nil Error message
local function loadConfig(configFile)
    local data, err = raw_tsv.fileToRawTSV(configFile)
    if not data then
        return nil, "failed to load config: " .. tostring(err)
    end
    local config = {}
    local headerFound = false
    for _, line in ipairs(data) do
        if type(line) == "table" then
            if not headerFound then
                headerFound = true
            else
                local key = line[1]
                local value = line[2] or ""
                if key and key ~= "" then
                    config[key] = value
                end
            end
        end
    end
    -- Apply defaults for missing optional keys
    for k, v in pairs(CONFIG_DEFAULTS) do
        if config[k] == nil or config[k] == "" then
            config[k] = v
        end
    end
    -- Validate required keys
    for _, k in ipairs(REQUIRED_KEYS) do
        if not config[k] or config[k] == "" then
            return nil, "missing required config key: " .. k
        end
    end
    -- Parse numeric values
    config.batch_size = tonumber(config.batch_size)
    config.timeout = tonumber(config.timeout)
    config.temperature = tonumber(config.temperature)
    config.max_tokens = tonumber(config.max_tokens)
    config.inter_batch_delay = tonumber(config.inter_batch_delay)
    config.error_delay = tonumber(config.error_delay)
    if not config.batch_size then
        return nil, "batch_size must be a number"
    end
    if not config.timeout then
        return nil, "timeout must be a number"
    end
    return config
end

---------------------------------------------------------------------------
-- TSV I/O helpers
---------------------------------------------------------------------------

--- Load a TSV file as a list of row tables (keyed by column name).
--- @param filePath string Path to the TSV file
--- @return table|nil List of row tables
--- @return table|nil Header (list of column names)
--- @return string|nil Error message
local function loadTSVRows(filePath)
    local data, err = raw_tsv.fileToRawTSV(filePath)
    if not data then
        return nil, nil, "failed to load " .. filePath .. ": " .. tostring(err)
    end
    local header = nil
    local rows = {}
    for _, line in ipairs(data) do
        if type(line) == "table" then
            if not header then
                header = line
            else
                local row = {}
                for i, col in ipairs(header) do
                    row[col] = line[i] or ""
                end
                rows[#rows + 1] = row
            end
        end
    end
    if not header then
        return nil, nil, "no header row found in " .. filePath
    end
    return rows, header
end

--- Load a reference file. If it has multiple columns, load as row tables.
--- If it has a single column (TXT-style), load as a simple list of strings.
--- @param filePath string Path to the reference file
--- @return table Reference data: either list of strings or list of row tables
--- @return string|nil Error message
local function loadReference(filePath)
    local data, err = raw_tsv.fileToRawTSV(filePath)
    if not data then
        return nil, "failed to load reference " .. filePath .. ": " .. tostring(err)
    end
    -- Find the header
    local header = nil
    for _, line in ipairs(data) do
        if type(line) == "table" then
            header = line
            break
        end
    end
    if not header then
        return nil, "no header row in reference " .. filePath
    end
    -- Single column = list of strings (TXT-style)
    if #header == 1 then
        local result = {}
        local headerFound = false
        for _, line in ipairs(data) do
            if type(line) == "table" then
                if not headerFound then
                    headerFound = true
                else
                    result[#result + 1] = line[1] or ""
                end
            end
        end
        return result
    end
    -- Multiple columns = row tables
    local rows = {}
    local headerFound = false
    for _, line in ipairs(data) do
        if type(line) == "table" then
            if not headerFound then
                headerFound = true
            else
                local row = {}
                for i, col in ipairs(header) do
                    row[col] = line[i] or ""
                end
                rows[#rows + 1] = row
            end
        end
    end
    return rows
end

--- Write rows as a TSV file.
--- @param filePath string Path to the output file
--- @param columns table List of column names
--- @param rows table List of row tables
--- @return boolean|nil True on success
--- @return string|nil Error message
local function writeTSV(filePath, columns, rows)
    local lines = {}
    lines[1] = table.concat(columns, "\t")
    for _, row in ipairs(rows) do
        local cells = {}
        for i, col in ipairs(columns) do
            local v = row[col]
            if v == nil then
                cells[i] = ""
            else
                -- Sanitize: replace tabs and newlines with spaces
                cells[i] = tostring(v):gsub("[\t\r\n]", " ")
            end
        end
        lines[#lines + 1] = table.concat(cells, "\t")
    end
    local content = table.concat(lines, "\n") .. "\n"
    return writeFile(filePath, content)
end

--- Atomically write a TSV file (write to .tmp, then rename).
--- @param filePath string Path to the output file
--- @param columns table List of column names
--- @param rows table List of row tables
--- @return boolean|nil True on success
--- @return string|nil Error message
local function writeTSVAtomic(filePath, columns, rows)
    local tmpPath = filePath .. ".tmp"
    local ok, err = writeTSV(tmpPath, columns, rows)
    if not ok then
        return nil, err
    end
    -- Rename tmp to final
    ok, err = os.rename(tmpPath, filePath)
    if not ok then
        os.remove(tmpPath)
        return nil, "failed to rename " .. tmpPath .. " to " .. filePath .. ": " .. tostring(err)
    end
    return true
end

---------------------------------------------------------------------------
-- Progress tracking (TSV-based)
---------------------------------------------------------------------------

--- Build a key string from a row's key columns.
--- @param row table The row table
--- @param keyColumns table List of key column names
--- @return string The compound key (columns joined with "|||")
local function makeKey(row, keyColumns)
    local parts = {}
    for i, col in ipairs(keyColumns) do
        parts[i] = row[col] or ""
    end
    return table.concat(parts, "|||")
end

--- Load progress from a TSV file.
--- Returns a set of already-processed keys, and the list of progress rows.
--- @param filePath string Path to the progress TSV
--- @param keyColumns table List of key column names
--- @return table Set of processed keys (key -> true)
--- @return table List of progress row tables
--- @return string|nil Error message if loading failed
local function loadProgress(filePath, keyColumns)
    local content = readFile(filePath)
    if not content then
        return {}, {}, nil
    end
    local rows, _, loadErr = loadTSVRows(filePath)
    if not rows then
        return {}, {}, loadErr
    end
    local processed = {}
    for _, row in ipairs(rows) do
        local key = makeKey(row, keyColumns)
        processed[key] = true
    end
    return processed, rows
end

--- Append rows to the progress TSV file.
--- Creates the file with header if it doesn't exist.
--- @param filePath string Path to the progress TSV
--- @param columns table List of column names for the progress file
--- @param newRows table List of row tables to append
--- @return boolean|nil True on success
--- @return string|nil Error message
local function appendProgress(filePath, columns, newRows)
    if #newRows == 0 then
        return true
    end
    -- Check if file exists (has content)
    local existing = readFile(filePath)
    local needHeader = not existing or existing == ""
    local lines = {}
    if needHeader then
        lines[1] = table.concat(columns, "\t")
    end
    for _, row in ipairs(newRows) do
        local cells = {}
        for i, col in ipairs(columns) do
            local v = row[col]
            if v == nil then
                cells[i] = ""
            else
                cells[i] = tostring(v):gsub("[\t\r\n]", " ")
            end
        end
        lines[#lines + 1] = table.concat(cells, "\t")
    end
    local content = table.concat(lines, "\n") .. "\n"
    -- Append to file
    local file, err = io.open(filePath, "a")
    if not file then
        return nil, "failed to open progress file: " .. tostring(err)
    end
    file:write(content)
    file:close()
    return true
end

---------------------------------------------------------------------------
-- Ollama HTTP API
---------------------------------------------------------------------------

--- Send a prompt to a local Ollama instance.
--- @param prompt string The user prompt
--- @param systemPrompt string The system prompt
--- @param config table The batch config
--- @return string|nil The response text
--- @return string|nil Error message
local function queryOllama(prompt, systemPrompt, config)
    local payload = dkjson.encode({
        model = config.model,
        prompt = prompt,
        system = systemPrompt,
        stream = false,
        options = {
            temperature = config.temperature,
            num_predict = config.max_tokens,
        },
    })
    local responseBody = {}
    local result, statusCode, _, statusLine = http.request{
        url = config.ollama_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#payload),
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(responseBody),
    }
    if not result then
        return nil, "HTTP request failed: " .. tostring(statusCode)
    end
    if statusCode ~= 200 then
        return nil, string.format("Ollama returned HTTP %s: %s",
            tostring(statusCode), tostring(statusLine))
    end
    local body = table.concat(responseBody)
    local parsed, _, err = dkjson.decode(body)
    if not parsed then
        return nil, "failed to parse Ollama response JSON: " .. tostring(err)
    end
    return parsed.response or ""
end

---------------------------------------------------------------------------
-- LLM response parsing
---------------------------------------------------------------------------

--- Strip <think>...</think> blocks and extract the outermost JSON array.
--- Repairs trailing commas in malformed JSON.
--- @param text string The raw LLM response text
--- @return table|nil Parsed JSON array (list of tables)
--- @return string|nil Error message
local function stripLLMJSON(text)
    -- Remove <think>...</think> blocks
    text = text:gsub("<think>.-</think>", "")
    -- Find the outermost JSON array
    local jsonStr = text:match("%[.+%]")
    if not jsonStr then
        return nil, "no JSON array found in response"
    end
    -- Try parsing directly
    local parsed, _, err = dkjson.decode(jsonStr)
    if parsed and type(parsed) == "table" then
        return parsed
    end
    -- Try repairing trailing commas: ,} or ,]
    local fixed = jsonStr:gsub(",%s*([}%]])", "%1")
    parsed, _, err = dkjson.decode(fixed)
    if parsed and type(parsed) == "table" then
        return parsed
    end
    return nil, "failed to parse JSON from response: " .. tostring(err)
end

---------------------------------------------------------------------------
-- Prompt building
---------------------------------------------------------------------------

--- Load a prompt template and replace {REFERENCE:filename} placeholders
--- with the content of reference files.
--- @param promptFile string Path to the prompt template
--- @param refs table Reference data (filename -> content table)
--- @return string|nil The expanded prompt text
--- @return string|nil Error message
local function loadPrompt(promptFile, refs)
    local content, err = readFile(promptFile)
    if not content then
        return nil, "failed to load prompt file: " .. tostring(err)
    end
    -- Replace {REFERENCE:filename} with the file content as a comma-separated list
    content = content:gsub("{REFERENCE:([^}]+)}", function(refName)
        local refData = refs[refName]
        if not refData then
            return "{REFERENCE:" .. refName .. ":NOT_FOUND}"
        end
        if type(refData[1]) == "string" then
            -- Single-column reference: join as comma-separated
            return table.concat(refData, ", ")
        else
            -- Multi-column reference: encode as JSON
            return dkjson.encode(refData)
        end
    end)
    return content
end

--- Build the batch prompt: a JSON array of input row objects.
--- @param batch table List of input row tables
--- @return string The prompt text (JSON array)
local function buildBatchPrompt(batch)
    return dkjson.encode(batch)
end

---------------------------------------------------------------------------
-- User code loading
---------------------------------------------------------------------------

--- Load an optional Lua code file that returns a function.
--- @param filePath string|nil Path to the Lua file, or nil to skip
--- @return function|nil The loaded function, or nil if no file
--- @return string|nil Error message
local function loadUserFunction(filePath)
    if not filePath or filePath == "" then
        return nil
    end
    local fn, err = loadfile(filePath)
    if not fn then
        return nil, "failed to load code file " .. filePath .. ": " .. tostring(err)
    end
    local ok, result = pcall(fn)
    if not ok then
        return nil, "error executing code file " .. filePath .. ": " .. tostring(result)
    end
    if type(result) ~= "function" then
        return nil, "code file " .. filePath .. " must return a function, got " .. type(result)
    end
    return result
end

---------------------------------------------------------------------------
-- Matching LLM results back to batch items
---------------------------------------------------------------------------

--- Match LLM result objects to the original batch items.
--- Uses positional matching first, then overrides with name-based matching
--- if a "name" field is present in results.
--- @param results table List of result dicts from LLM
--- @param batch table List of original input row dicts
--- @param keyColumns table Key column names for building name index
--- @return table List of (result or nil), same length as batch
local function matchResultsToBatch(results, batch, keyColumns)
    -- Build name index from results
    local nameIndex = {}
    for _, r in ipairs(results) do
        if type(r) == "table" then
            local rawName = r.name or r.Name or ""
            if type(rawName) == "string" then
                rawName = trim(rawName):lower()
                if rawName ~= "" then
                    nameIndex[rawName] = r
                    -- Also try without quotes
                    local noQuotes = rawName:gsub('"', "")
                    if noQuotes ~= rawName then
                        nameIndex[noQuotes] = r
                    end
                end
            end
        end
    end
    local matched = {}
    for i, item in ipairs(batch) do
        -- Try positional first
        local cls = results[i]
        -- Try name override using first key column
        if #keyColumns > 0 then
            local itemName = trim(item[keyColumns[1]] or ""):lower()
            if itemName ~= "" then
                local nameMatch = nameIndex[itemName] or nameIndex[itemName:gsub('"', "")]
                if nameMatch then
                    cls = nameMatch
                end
            end
        end
        matched[i] = cls
    end
    return matched
end

---------------------------------------------------------------------------
-- Format helpers
---------------------------------------------------------------------------

--- Format an ETA duration in seconds as "Xh YYm" or "Ym".
--- @param seconds number The duration in seconds
--- @return string The formatted ETA string
local function formatETA(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then
        return string.format("%dh%02dm", h, m)
    end
    return string.format("%dm", m)
end

---------------------------------------------------------------------------
-- Main batch runner
---------------------------------------------------------------------------

--- Run batch processing.
--- @param configFile string Path to the config TSV
--- @param baseDir string Base directory for resolving relative paths
--- @param options table|nil Options: {dryRun=bool, verbose=bool, logger=logger,
---                          resume=bool, status=bool, modelOverride=string,
---                          batchSizeOverride=number, timeoutOverride=number}
--- @return boolean|nil True on success, nil on error
--- @return string|nil Error message
local function run(configFile, baseDir, options)
    options = options or {}
    local logger = options.logger or named_logger.getLogger(NAME)

    -- Load config
    local config, err = loadConfig(configFile)
    if not config then
        return nil, err
    end

    -- Apply CLI overrides
    if options.modelOverride then
        config.model = options.modelOverride
    end
    if options.batchSizeOverride then
        config.batch_size = options.batchSizeOverride
    end
    if options.timeoutOverride then
        config.timeout = options.timeoutOverride
    end

    -- Resolve paths relative to baseDir
    local function resolve(path)
        if not path or path == "" then return nil end
        if file_util.isAbsolutePath(path) then return normalizePath(path) end
        return pathJoin(baseDir, path)
    end

    local inputFile = resolve(config.input_file)
    local outputFile = resolve(config.output_file)
    local progressFile = resolve(config.progress_file)
    local promptFile = resolve(config.prompt_file)

    -- Parse pipe-delimited column lists
    local inputColumns = split(config.input_columns, "|")
    local generatedColumns = split(config.generated_columns, "|")
    local outputColumns = split(config.output_columns, "|")

    -- The progress file stores: key columns + generated columns
    -- Key columns = inputColumns (the columns sent to the model that identify a row)
    local progressColumns = {}
    for _, c in ipairs(inputColumns) do
        progressColumns[#progressColumns + 1] = c
    end
    for _, c in ipairs(generatedColumns) do
        progressColumns[#progressColumns + 1] = c
    end

    -- Load input data
    local inputRows, _, loadErr = loadTSVRows(inputFile)
    if not inputRows then
        return nil, loadErr or "failed to load input file"
    end
    logger:info(string.format("Loaded %d rows from %s", #inputRows, config.input_file))

    -- Load progress
    local processed, progressRows = loadProgress(progressFile, inputColumns)
    local processedCount = 0
    for _ in pairs(processed) do processedCount = processedCount + 1 end

    -- Status mode: show progress and exit
    if options.status then
        local pct = #inputRows > 0 and (processedCount / #inputRows * 100) or 0
        logger:info(string.format("Progress: %d/%d (%.1f%%)", processedCount, #inputRows, pct))
        return true
    end

    -- Resume guard
    if not options.resume and processedCount > 0 then
        logger:info(string.format("Found existing progress (%d items processed).", processedCount))
        logger:info("Use --resume to continue, or delete the progress file to start over.")
        return true
    end

    -- Load reference files
    local refs = {}
    if config.reference and config.reference ~= "" then
        local refNames = split(config.reference, "|")
        for _, refName in ipairs(refNames) do
            local refPath = resolve(refName)
            local refData
            refData, err = loadReference(refPath)
            if not refData then
                return nil, err
            end
            refs[refName] = refData
            logger:info(string.format("Loaded reference: %s (%d entries)", refName, #refData))
        end
    end

    -- Load system prompt
    local systemPrompt
    systemPrompt, err = loadPrompt(promptFile, refs)
    if not systemPrompt then
        return nil, err
    end

    -- Load optional user functions
    local prepareInput, processOutput
    if config.prepare_input then
        prepareInput, err = loadUserFunction(resolve(config.prepare_input))
        if err then return nil, err end
    end
    if config.process_output then
        processOutput, err = loadUserFunction(resolve(config.process_output))
        if err then return nil, err end
    end

    logger:info(string.format("Model: %s  batch-size: %d  timeout: %ds",
        config.model, config.batch_size, config.timeout))

    -- Filter out already-processed rows
    local remaining = {}
    for _, row in ipairs(inputRows) do
        local key = makeKey(row, inputColumns)
        if not processed[key] then
            remaining[#remaining + 1] = row
        end
    end
    logger:info(string.format("Remaining: %d / %d", #remaining, #inputRows))

    if #remaining == 0 then
        logger:info("All rows processed. Writing output.")
        -- Build and write final output
        local outRows = {}
        local progressLookup = {}
        for _, pRow in ipairs(progressRows) do
            local key = makeKey(pRow, inputColumns)
            progressLookup[key] = pRow
        end
        for _, inRow in ipairs(inputRows) do
            local key = makeKey(inRow, inputColumns)
            local pRow = progressLookup[key] or {}
            local outRow = {}
            for _, col in ipairs(outputColumns) do
                outRow[col] = pRow[col] or inRow[col] or ""
            end
            outRows[#outRows + 1] = outRow
        end
        local wOk, wErr = writeTSVAtomic(outputFile, outputColumns, outRows)
        if not wOk then
            return nil, "failed to write output: " .. tostring(wErr)
        end
        logger:info("Written: " .. config.output_file)
        return true
    end

    -- Build batches
    local batches = {}
    for i = 1, #remaining, config.batch_size do
        local batch = {}
        for j = i, math.min(i + config.batch_size - 1, #remaining) do
            batch[#batch + 1] = remaining[j]
        end
        batches[#batches + 1] = batch
    end
    logger:info(string.format("Batches: %d", #batches))

    -- Batch processing loop
    local startTime = os.clock()
    local classifiedAtStart = processedCount
    local errorCount = 0

    for batchIdx, batch in ipairs(batches) do
        local totalDone = classifiedAtStart
        -- Count current progress
        for _ in pairs(processed) do end
        totalDone = processedCount

        local elapsed = os.clock() - startTime
        local doneThisRun = processedCount - classifiedAtStart
        local rate = elapsed > 1 and (doneThisRun / elapsed) or 0
        local remainingCount = #inputRows - processedCount
        local etaStr = rate > 0 and formatETA(remainingCount / rate) or "???"

        logger:info(string.format("[Batch %d/%d] %d/%d (%.1f%%) %.3f items/s  ETA: %s",
            batchIdx, #batches,
            processedCount, #inputRows,
            processedCount / #inputRows * 100,
            rate, etaStr))

        -- Prepare input rows for the model
        local modelInput = {}
        for _, row in ipairs(batch) do
            local inputRow = {}
            for _, col in ipairs(inputColumns) do
                inputRow[col] = row[col] or ""
            end
            if prepareInput then
                local ok2, transformed = pcall(prepareInput, inputRow, refs)
                if ok2 and type(transformed) == "table" then
                    inputRow = transformed
                else
                    logger:warn("prepareInput error: " .. tostring(transformed))
                end
            end
            modelInput[#modelInput + 1] = inputRow
        end

        -- Build prompt and query Ollama
        local batchPrompt = buildBatchPrompt(modelInput)
        if options.dryRun then
            logger:info("  [dry-run] would send " .. #batch .. " items to Ollama")
            goto continue
        end

        local response, queryErr = queryOllama(batchPrompt, systemPrompt, config)
        if not response then
            errorCount = errorCount + 1
            logger:error(string.format("  ERROR: %s", tostring(queryErr)))
            -- Sleep on error
            if config.error_delay > 0 then
                local socket = require("socket")
                socket.sleep(config.error_delay)
            end
            goto continue
        end

        -- Parse response
        local results, parseErr = stripLLMJSON(response)
        if not results then
            errorCount = errorCount + 1
            logger:error(string.format("  PARSE ERROR (%d chars): %s",
                #response, tostring(parseErr)))
            -- Write debug dump
            local debugFile = progressFile:gsub("%.tsv$", "") ..
                "_debug_batch" .. batchIdx .. ".txt"
            writeFile(debugFile, response)
            goto continue
        end

        -- Match results to batch items
        local matchedResults = matchResultsToBatch(results, batch, inputColumns)
        local matchedCount = 0

        -- Process results and build progress rows
        local newProgressRows = {}
        for i, row in ipairs(batch) do
            local cls = matchedResults[i]
            local progressRow = {}
            -- Copy key columns from input
            for _, col in ipairs(inputColumns) do
                progressRow[col] = row[col] or ""
            end
            if cls and type(cls) == "table" then
                -- Extract generated columns from result
                -- Remove the "name" matching hint
                cls.name = nil
                cls.Name = nil
                for _, col in ipairs(generatedColumns) do
                    progressRow[col] = tostring(cls[col] or "")
                end
                -- Apply optional output processing
                if processOutput then
                    local ok2, transformed = pcall(processOutput, progressRow, refs)
                    if ok2 and type(transformed) == "table" then
                        progressRow = transformed
                    else
                        logger:warn("processOutput error: " .. tostring(transformed))
                    end
                end
                matchedCount = matchedCount + 1
            else
                -- Unmatched: store with empty generated columns so it isn't retried
                for _, col in ipairs(generatedColumns) do
                    progressRow[col] = ""
                end
            end
            newProgressRows[#newProgressRows + 1] = progressRow
            local key = makeKey(row, inputColumns)
            processed[key] = true
            processedCount = processedCount + 1
        end

        -- Append to progress file
        local aOk, aErr = appendProgress(progressFile, progressColumns, newProgressRows)
        if not aOk then
            logger:error("Failed to save progress: " .. tostring(aErr))
        end

        logger:info(string.format("  -> %d/%d matched", matchedCount, #batch))

        -- Inter-batch delay
        if config.inter_batch_delay > 0 then
            local socket = require("socket")
            socket.sleep(config.inter_batch_delay)
        end

        ::continue::
    end

    -- Write final output: merge input rows with progress data
    logger:info("Writing final output...")

    -- Reload progress (includes rows from this run)
    local _, allProgressRows = loadProgress(progressFile, inputColumns)
    local progressLookup = {}
    for _, pRow in ipairs(allProgressRows) do
        local key = makeKey(pRow, inputColumns)
        progressLookup[key] = pRow
    end

    local outRows = {}
    for _, inRow in ipairs(inputRows) do
        local key = makeKey(inRow, inputColumns)
        local pRow = progressLookup[key] or {}
        local outRow = {}
        for _, col in ipairs(outputColumns) do
            -- Generated columns come from progress; input columns from input
            outRow[col] = pRow[col] or inRow[col] or ""
        end
        outRows[#outRows + 1] = outRow
    end

    local wOk, wErr = writeTSVAtomic(outputFile, outputColumns, outRows)
    if not wOk then
        return nil, "failed to write output: " .. tostring(wErr)
    end

    logger:info(string.format("Done. %d/%d processed. Errors: %d. Output: %s",
        processedCount, #inputRows, errorCount, config.output_file))
    return true
end

---------------------------------------------------------------------------
-- Command-line interface
---------------------------------------------------------------------------

--- Generate usage/help text for the CLI.
--- @return string
local function generateUsage()
    return [[
ollama_batch — TabuLua LLM batch processing tool (version ]] .. tostring(VERSION) .. [[)

Usage:
  lua54 ollama_batch.lua <config.tsv> <baseDir> [options]

Arguments:
  config.tsv    Path to the batch config file (TSV: key/value pairs)
  baseDir       Base directory for resolving relative file paths

Options:
  --resume              Resume from last checkpoint
  --status              Show progress and exit
  --dry-run             Skip Ollama calls (validate config only)
  --verbose             Log each step
  --log-level=LEVEL     Set log level (debug, info, warn, error, fatal)
  --model=MODEL         Override the model from config
  --batch-size=N        Override the batch size from config
  --timeout=N           Override the timeout (seconds) from config

Config file keys:
  input_file            Input TSV file path
  input_columns         Pipe-delimited columns to send to the model
  generated_columns     Pipe-delimited columns the model generates
  output_file           Output TSV file path
  output_columns        Pipe-delimited columns for the output file
  prompt_file           Path to the system prompt text file
  progress_file         Path to the progress TSV file
  model                 Ollama model name (default: qwen2.5:32b)
  batch_size            Items per batch (default: 30)
  timeout               Request timeout in seconds (default: 500)
  ollama_url            Ollama API URL (default: http://localhost:11434/api/generate)
  temperature           LLM temperature (default: 0.1)
  max_tokens            Max tokens to generate (default: 4096)
  inter_batch_delay     Seconds between batches (default: 1)
  error_delay           Seconds to wait after error (default: 2)
  reference             Pipe-delimited reference file paths (optional)
  prepare_input         Lua file returning input transform function (optional)
  process_output        Lua file returning output transform function (optional)

Prompt file placeholders:
  {REFERENCE:filename}  Replaced with content of the named reference file

User code files:
  prepare_input file must return: function(inputRow, refs) -> transformedRow
  process_output file must return: function(outputRow, refs) -> transformedRow]]
end

local isMainScript = arg and arg[0] and arg[0]:match("ollama_batch")
if isMainScript then
    if #arg == 0 then
        print(generateUsage())
        os.exit(1)
    end

    -- Parse CLI arguments
    local configFile, baseDir, options, hasError = nil, nil, {}, false
    local cliLogger = named_logger.getLogger(NAME)

    for i = 1, #arg do
        local arg_i = arg[i]
        if arg_i == "--resume" then
            options.resume = true
        elseif arg_i == "--status" then
            options.status = true
        elseif arg_i == "--dry-run" then
            options.dryRun = true
        elseif arg_i == "--verbose" then
            options.verbose = true
        elseif arg_i:match("^%-%-log%-level=") then
            local levelName = arg_i:match("^%-%-log%-level=(.+)$")
            if not LOG_LEVELS[levelName:lower()] then
                cliLogger:error("Unknown log level: " .. levelName)
                cliLogger:error("Valid levels: debug, info, warn, error, fatal")
                hasError = true
            end
        elseif arg_i:match("^%-%-model=") then
            options.modelOverride = arg_i:match("^%-%-model=(.+)$")
        elseif arg_i:match("^%-%-batch%-size=") then
            local n = tonumber(arg_i:match("^%-%-batch%-size=(.+)$"))
            if n then
                options.batchSizeOverride = n
            else
                cliLogger:error("--batch-size requires a number")
                hasError = true
            end
        elseif arg_i:match("^%-%-timeout=") then
            local n = tonumber(arg_i:match("^%-%-timeout=(.+)$"))
            if n then
                options.timeoutOverride = n
            else
                cliLogger:error("--timeout requires a number")
                hasError = true
            end
        elseif arg_i:match("^%-%-") then
            cliLogger:error("Unknown option: " .. arg_i)
            hasError = true
        elseif not configFile then
            configFile = normalizePath(arg_i)
        elseif not baseDir then
            baseDir = normalizePath(arg_i)
        else
            cliLogger:error("Unexpected argument: " .. arg_i)
            hasError = true
        end
    end

    if not configFile then
        cliLogger:error("Missing required argument: <config.tsv>")
        hasError = true
    end
    if not baseDir then
        cliLogger:error("Missing required argument: <baseDir>")
        hasError = true
    end

    if hasError then
        print("\nUse 'lua54 ollama_batch.lua' without arguments to see usage.")
        os.exit(1)
    end

    options.logger = cliLogger
    local ok, err = run(configFile, baseDir, options)
    if not ok then
        cliLogger:error(err)
        os.exit(1)
    end
    os.exit(0)
end

---------------------------------------------------------------------------
-- Module API
---------------------------------------------------------------------------

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    run = run,
    getVersion = getVersion,
    -- Exported utilities for custom scripts
    loadConfig = loadConfig,
    loadTSVRows = loadTSVRows,
    loadReference = loadReference,
    writeTSV = writeTSV,
    writeTSVAtomic = writeTSVAtomic,
    queryOllama = queryOllama,
    stripLLMJSON = stripLLMJSON,
    makeKey = makeKey,
    loadProgress = loadProgress,
    appendProgress = appendProgress,
    matchResultsToBatch = matchResultsToBatch,
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
