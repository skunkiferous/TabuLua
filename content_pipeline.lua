-- Module name
local NAME = "content_pipeline"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 21, 0)

local read_only = require("read_only")
local readOnly = read_only.readOnly

local logger = require("named_logger").getLogger(NAME)

local file_util = require("file_util")
local readFileBinary = file_util.readFileBinary

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- Content-pipeline registry (see TODO/content_pipeline.md)
--
-- The sibling of the type-wiring registry. type-wiring dispatches on a
-- file's *parsed* record type; this registry dispatches on a file's *name*
-- (extension / glob / directory / magic bytes) BEFORE any parsing happens,
-- and operates on raw bytes / text, not a parsed file.
--
-- A stage transforms a file's content around parsing. Stages are grouped
-- into ordered phases:
--
--   decode     bytes -> bytes/text   (decompress, decrypt; loops with peeling)
--   transcode  structured -> TSV text (JSON/XML/SQLite/.mtx; single match)
--   normalize  text -> text          (core EOL-normalisation; text only)
--   macro      text -> text          (COG; text only)
--   asset      bytes -> bytes        (image/audio/font; binary only — Phase 6)
--
-- The pipeline tracks each file's content kind ("text" or "binary"). The
-- text-only phases (normalize, macro) never run on binary content, so reading
-- every file binary (§3.4) is safe.
--
-- Phase 1 exercises only `normalize` and `macro` (registered by
-- builtin_content_stages.lua: a core EOL-normalise stage and COG). The
-- decode/transcode/asset dispatch machinery is present but carries no stages
-- yet.
-- ============================================================

-- Coarse phase order. `normalize` is an internal core phase that runs between
-- transcode and macro, so the raw_files snapshot (taken right after it) holds
-- the normalised, pre-macro source — matching the pre-refactor behaviour.
local PHASES = {"decode", "transcode", "normalize", "macro", "asset"}
local PHASE_SET = {}
for _, p in ipairs(PHASES) do PHASE_SET[p] = true end

-- Insertion-ordered list of {moduleName, spec}. Order is the stable tiebreak
-- within a phase when two stages share a priority.
local STAGES = {}
local STAGES_SNAPSHOT = nil

-- Known text extensions (lowercase, no dot). Content kind defaults to
-- "binary"; a file is "text" only if its final extension is in this set or a
-- stage claims it as text (§3.11).
local TEXT_EXTENSIONS = {
    tsv = true, csv = true, txt = true, text = true, md = true, markdown = true,
    html = true, htm = true, json = true, xml = true, lua = true, mtx = true,
    yaml = true, yml = true, ini = true, cfg = true, svg = true,
}

-- ============================================================
-- Helpers
-- ============================================================

-- Returns the final extension of a path (lowercased, no dot), or nil.
local function finalExtension(name)
    local ext = name:match("%.([^%.\\/]+)$")
    if ext then return ext:lower() end
    return nil
end

-- The basename (last path segment) of a name.
local function basename(name)
    return name:match("[^/\\]+$") or name
end

-- Classifies a file's content kind from its name. Default binary (§3.11).
local function classifyKind(name)
    local ext = finalExtension(name)
    if ext and TEXT_EXTENSIONS[ext] then
        return "text"
    end
    return "binary"
end

-- Converts a shell-style glob (only * and ?) to a Lua pattern anchored to the
-- whole string. Used for basenameGlob matching.
local function globToPattern(glob)
    local pat = glob:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
    pat = pat:gsub("%*", ".*"):gsub("%?", ".")
    return "^" .. pat .. "$"
end

-- ============================================================
-- Registration
-- ============================================================

local function validateSpec(moduleName, spec)
    if type(spec) ~= "table" then
        error("content_pipeline.register: stageSpec must be a table for module '"
            .. moduleName .. "'", 3)
    end
    if not PHASE_SET[spec.phase] then
        error("content_pipeline.register: unknown or missing phase '"
            .. tostring(spec.phase) .. "' for module '" .. moduleName .. "'", 3)
    end
    if spec.transform ~= nil and type(spec.transform) ~= "function" then
        error("content_pipeline.register: transform must be a function for module '"
            .. moduleName .. "'", 3)
    end
    if spec.sinkTransform ~= nil and type(spec.sinkTransform) ~= "function" then
        error("content_pipeline.register: sinkTransform must be a function for module '"
            .. moduleName .. "'", 3)
    end
    if spec.transform == nil and spec.sinkTransform == nil then
        error("content_pipeline.register: stage from module '" .. moduleName
            .. "' must supply a transform and/or a sinkTransform", 3)
    end
    if spec.matches ~= nil and type(spec.matches) ~= "function" then
        error("content_pipeline.register: matches must be a function for module '"
            .. moduleName .. "'", 3)
    end
    if spec.extensions ~= nil and type(spec.extensions) ~= "table" then
        error("content_pipeline.register: extensions must be an array for module '"
            .. moduleName .. "'", 3)
    end
    if spec.id ~= nil and (type(spec.id) ~= "string" or spec.id == "") then
        error("content_pipeline.register: id must be a non-empty string for module '"
            .. moduleName .. "'", 3)
    end
    -- A stage must be dispatchable. There are two ways: an auto-matcher (fires by
    -- extension / glob / dir / magic / predicate), OR an `id` for explicit
    -- selection by name (a transcoder named in Files.tsv — §3.2, content_pipeline.md
    -- Phase 3). An id-only stage has no auto-matcher and never fires unless named,
    -- which is exactly what ambiguous formats like JSON need.
    local hasMatcher = spec.matches ~= nil or spec.extensions ~= nil
        or spec.basenameGlob ~= nil or spec.directory ~= nil or spec.magic ~= nil
    if not hasMatcher and spec.id == nil then
        error("content_pipeline.register: stage from module '" .. moduleName
            .. "' has no matcher and no id (extensions / basenameGlob / directory / magic / matches / id)", 3)
    end
end

-- Registers a stage. moduleName is for provenance in logs.
local function register(moduleName, spec)
    if type(moduleName) ~= "string" or moduleName == "" then
        error("content_pipeline.register: moduleName must be a non-empty string", 2)
    end
    validateSpec(moduleName, spec)
    STAGES[#STAGES + 1] = {moduleName = moduleName, spec = spec}
    logger:info("Registered " .. spec.phase .. " stage from " .. moduleName)
end

-- ============================================================
-- Matching + dispatch
-- ============================================================

-- True iff `spec` matches a file with the given effective name / content / kind.
-- Matchers are ORed; inputKind (if set) is a hard gate applied first.
local function specMatches(spec, name, content, kind)
    if spec.inputKind ~= nil and spec.inputKind ~= kind then
        return false
    end
    if spec.matches and spec.matches(name, content) then
        return true
    end
    if spec.extensions then
        local ext = finalExtension(name)
        if ext then
            for _, e in ipairs(spec.extensions) do
                if type(e) == "string" and e:lower() == ext then
                    return true
                end
            end
        end
    end
    if spec.basenameGlob then
        if basename(name):match(globToPattern(spec.basenameGlob)) then
            return true
        end
    end
    if spec.directory then
        local dir = spec.directory:gsub("\\", "/")
        local nm = name:gsub("\\", "/")
        if nm:find(dir, 1, true) then
            return true
        end
    end
    if spec.magic and content and #content >= #spec.magic then
        if content:sub(1, #spec.magic) == spec.magic then
            return true
        end
    end
    return false
end

-- Selects the stages of one `phase` that apply to a given file, in the exact
-- order they should run. This is the heart of dispatch: every phase runner
-- (runPhase / runDecode / runTranscode / runSink) calls it and then just walks
-- the returned list.
--
--   phase    one of PHASES — only stages registered for this phase are considered.
--   name     the *effective* file name (after any decode peeling), used by the
--            name-based matchers (extension / glob / directory).
--   content  the current bytes/text, used by the `magic` matcher and passed to
--            a stage's custom `matches` predicate.
--   kind     "text" or "binary" — gates stages via their inputKind (see specMatches).
--   useSink  false/nil → we want source-direction stages (spec.transform);
--            true      → we want sink/export-direction stages (spec.sinkTransform).
--            A stage that lacks the relevant function is skipped, so a
--            source-only stage never shows up in a sink pass and vice-versa.
--
-- Two passes:
--   1. Filter. Walk STAGES in registration order; keep an entry only if its
--      phase matches, it has the requested direction's function (`fn`), AND its
--      matchers fire for this file. For each keeper we remember three things:
--        spec     — the stage spec (so the runner can call its transform)
--        order    — its index in STAGES, i.e. registration order (the tiebreak)
--        priority — spec.priority, defaulting to 100 when unspecified
--   2. Sort. Lower priority runs first (priority is "earliness", not importance:
--      a completion stage at 50 runs before a user stage at 100). Ties — two
--      stages with the same priority — fall back to `order`, so the
--      earlier-registered stage runs first. That makes ordering fully
--      deterministic and independent of pairs()/table iteration quirks.
local function matchingStages(phase, name, content, kind, useSink)
    local out = {}
    for i, entry in ipairs(STAGES) do
        local spec = entry.spec
        -- Pick the function for the direction we're dispatching; a nil here
        -- means this stage doesn't participate in this direction, so skip it.
        local fn = useSink and spec.sinkTransform or spec.transform
        if spec.phase == phase and fn and specMatches(spec, name, content, kind) then
            out[#out + 1] = {spec = spec, order = i, priority = spec.priority or 100}
        end
    end
    -- Stable order: primarily by ascending priority, then by registration order.
    table.sort(out, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.order < b.order
    end)
    return out
end

-- Runs every matching stage of a non-looping phase in order, threading the
-- content and (optional) renamed effective name through each. `ctx` is the
-- optional per-file context (transcoder id, typeName, …); stages that don't need
-- it simply ignore the extra argument.
local function runPhase(phase, name, content, kind, env, badVal, ctx)
    for _, m in ipairs(matchingStages(phase, name, content, kind)) do
        local newContent, newName = m.spec.transform(name, content, env, badVal, ctx)
        if newContent ~= nil then content = newContent end
        if newName ~= nil and newName ~= "" then name = newName end
    end
    return content, name
end

-- Finds a registered stage of `phase` by its explicit `id`, or nil. Used to
-- select a transcoder named in Files.tsv (§3.2).
local function findStageById(phase, id)
    for _, entry in ipairs(STAGES) do
        if entry.spec.phase == phase and entry.spec.id == id then
            return entry.spec
        end
    end
    return nil
end

-- decode: loop with extension peeling. Each iteration runs the highest-priority
-- matching decode stage, then re-evaluates matchers against the new effective
-- name (so .tsv.gz.enc decrypts then gunzips). The loop stops when no decode
-- stage matches or the effective name stops changing (peeling must rename, else
-- the same stage would match forever — §3.3, §7).
--
-- Returns (content, name, kind, fatal). `fatal` is true when a matched decode
-- stage could not produce output — a corrupt input, or a decompression bomb
-- over its maxOutputBytes cap (§3.7). The stage reports the cause via badVal and
-- returns nil content; runPipeline then drops the file. A decode stage that
-- matches MUST return non-nil content on success, so nil unambiguously means
-- "abort this file".
--
-- Phase 1 registered no decode stages (this returned immediately); Phase 2 adds
-- the gzip stage (builtin_content_stages.lua).
local function runDecode(name, content, kind, env, badVal, ctx)
    while true do
        local stages = matchingStages("decode", name, content, kind)
        if #stages == 0 then break end
        local spec = stages[1].spec
        local newContent, newName = spec.transform(name, content, env, badVal, ctx)
        if newContent == nil then
            -- Matched stage failed (it has already reported via badVal). Abort.
            return nil, name, kind, true
        end
        -- maxOutputBytes enforcement (defence in depth): even if a stage forgets
        -- to self-check, a decode output over the declared cap aborts the file.
        if spec.maxOutputBytes and #newContent > spec.maxOutputBytes then
            badVal(name, "content_pipeline: decode output of '" .. name
                .. "' exceeds maxOutputBytes (" .. tostring(spec.maxOutputBytes)
                .. " bytes)")
            return nil, name, kind, true
        end
        content = newContent
        if newName ~= nil and newName ~= "" and newName ~= name then
            -- Peeled to a new effective name: re-derive the content kind from it
            -- (gunzip of data.tsv.gz -> data.tsv is text; of img.png.gz -> binary)
            -- unless the stage forced a specific outputKind.
            name = newName
            kind = spec.outputKind or classifyKind(name)
        else
            -- No rename (e.g. a magic-only match on a mislabelled file): we can't
            -- peel further, so stop to avoid re-matching the same stage forever.
            if spec.outputKind ~= nil then kind = spec.outputKind end
            logger:warn("decode stage did not change the effective name of '"
                .. name .. "'; stopping decode loop to avoid a cycle")
            break
        end
    end
    return content, name, kind, false
end

-- transcode: at most one stage per file (you don't transcode TSV into TSV).
-- Selection is either EXPLICIT — ctx.transcoder names a stage `id` (the Files.tsv
-- `transcoder` column, the path used for ambiguous formats like JSON) — or
-- AUTO by the usual matchers (none ship yet; reserved for unambiguous formats).
-- Returns (content, name, kind, fatal); a transcode failure aborts the file
-- (§3.7), as does naming an unknown transcoder.
local function runTranscode(name, content, kind, env, badVal, ctx)
    local spec
    if ctx and ctx.transcoder then
        spec = findStageById("transcode", ctx.transcoder)
        if not spec then
            badVal(name, "content_pipeline: unknown transcoder '"
                .. tostring(ctx.transcoder) .. "' for '" .. name .. "'")
            return nil, name, kind, true
        end
    else
        local stages = matchingStages("transcode", name, content, kind)
        if #stages == 0 then return content, name, kind, false end
        if #stages > 1 then
            badVal(name, "content_pipeline: multiple transcode stages match '"
                .. name .. "' (ambiguous)")
        end
        spec = stages[1].spec
    end
    local newContent, newName = spec.transform(name, content, env, badVal, ctx)
    if newContent == nil then
        -- Transcode failed (malformed input / bad schema; reported via badVal).
        return nil, name, kind, true
    end
    content = newContent
    if newName ~= nil and newName ~= "" then name = newName end
    if spec.outputKind ~= nil then kind = spec.outputKind end
    return content, name, kind, false
end

-- Core orchestration shared by run (in-memory) and readAndRun (reads first).
-- Runs decode -> transcode -> normalize -> [snapshot raw_files] -> macro.
-- The raw_files snapshot (keyed by the on-disk name, not the peeled effective
-- name — §3.3) holds the normalised, pre-macro source: exactly what the
-- pre-refactor pipeline stored. text-only phases are skipped on binary content.
local function runPipeline(name, content, kind, env, badVal, raw_files, rawKey, ctx)
    local fatal
    content, name, kind, fatal = runDecode(name, content, kind, env, badVal, ctx)
    if fatal then return nil end
    content, name, kind, fatal = runTranscode(name, content, kind, env, badVal, ctx)
    if fatal then return nil end
    if kind == "text" then
        content, name = runPhase("normalize", name, content, kind, env, badVal, ctx)
    end
    if raw_files ~= nil and rawKey ~= nil then
        raw_files[rawKey] = content
    end
    if kind == "text" then
        content, name = runPhase("macro", name, content, kind, env, badVal, ctx)
    end
    return content, name
end

-- ============================================================
-- Public entry points
-- ============================================================

-- Runs the pipeline on already-in-memory bytes (for tests / embedded sources).
-- Does not touch raw_files. opt_ctx is the optional per-file context
-- ({transcoder=id, typeName=name}). Returns (text, effectiveName).
local function run(file_name, bytes, env, badVal, opt_ctx)
    if type(file_name) ~= "string" then
        error("content_pipeline.run: file_name must be a string", 2)
    end
    if type(bytes) ~= "string" then
        error("content_pipeline.run: bytes must be a string", 2)
    end
    local kind = classifyKind(file_name)
    return runPipeline(file_name, bytes, kind, env, badVal, nil, nil, opt_ctx)
end

-- Reads a file from disk (binary) and runs the full source pipeline on it.
-- Populates raw_files[file_name] with the normalised, pre-macro source when a
-- raw_files table is given (it owns the read now — §5). opt_ctx is the optional
-- per-file context ({transcoder=id, typeName=name}) the loader passes from
-- Files.tsv. Returns (text, effectiveName), or nil on a fatal read/stage error
-- (already reported via badVal), so callers can `if not content then return end`.
local function readAndRun(file_name, env, badVal, raw_files, opt_ctx)
    if type(file_name) ~= "string" then
        error("content_pipeline.readAndRun: file_name must be a string", 2)
    end
    local bytes, err = readFileBinary(file_name)
    if not bytes then
        badVal(nil, "File could not be read: " .. tostring(err))
        return nil
    end
    local kind = classifyKind(file_name)
    return runPipeline(file_name, bytes, kind, env, badVal, raw_files, file_name, opt_ctx)
end

-- Runs the sink (export-side) pipeline on a file's content: the inverse phase
-- order of the source direction, invoking each matching stage's sinkTransform.
-- Phase 1 registers no sink stages, so this is a no-op passthrough; COG-comment
-- stripping and reverse stages arrive in Phase 5+.
local function runSink(file_name, content, env, badVal)
    if type(file_name) ~= "string" then
        error("content_pipeline.runSink: file_name must be a string", 2)
    end
    local kind = classifyKind(file_name)
    local name = file_name
    for _, phase in ipairs({"asset", "macro", "transcode", "decode"}) do
        for _, m in ipairs(matchingStages(phase, name, content, kind, true)) do
            local newContent = m.spec.sinkTransform(name, content, env, badVal)
            if newContent ~= nil then content = newContent end
        end
    end
    return content, name
end

-- True iff the file's content kind is "text" (per its extension). Exposed so
-- the loader can decide between the text (load + parse/COG) and binary
-- (passthrough-by-reference) paths without duplicating the extension table.
local function isTextFile(file_name)
    return classifyKind(file_name) == "text"
end

-- ============================================================
-- Snapshot / restore (for global_reset), mirroring type_wiring.
-- ============================================================

local function snapshotState()
    local s = {}
    for i, e in ipairs(STAGES) do s[i] = e end
    STAGES_SNAPSHOT = s
end

local function restoreState()
    for i in ipairs(STAGES) do STAGES[i] = nil end
    if STAGES_SNAPSHOT then
        for i, e in ipairs(STAGES_SNAPSHOT) do STAGES[i] = e end
    end
end

-- Test/debug accessor (not part of the documented surface).
local function _getStages()
    local out = {}
    for _, e in ipairs(STAGES) do
        out[#out + 1] = {moduleName = e.moduleName, phase = e.spec.phase}
    end
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
    register = register,
    run = run,
    readAndRun = readAndRun,
    runSink = runSink,
    isTextFile = isTextFile,
    classifyKind = classifyKind,
    snapshotState = snapshotState,
    restoreState = restoreState,
    _getStages = _getStages,
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
