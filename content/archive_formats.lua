-- Module name
local NAME = "archive_formats"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 31, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

local compression = require("content.compression")

local logger = require("infra.named_logger").getLogger(NAME)
local didYouMean = require("infra.error_reporting").didYouMean

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- Archive / data-set format registry (see TODO/archive_files.md §1)
--
-- An *archive* is one on-disk file that is a CONTAINER for a SET of member
-- files with an internal directory tree (a zip). This is the load-bearing
-- distinction from `compression` (which wraps ONE byte stream): an archive
-- fans out to N members, so it cannot be modelled as a content-pipeline stage.
--
-- The registry mirrors `compression.lua`: a provider registers a LOADER for one
-- archive format (keyed by extension, `zip` to start). The loader runs LAZILY
-- the first time that format is actually opened, and is expected to pull in
-- whatever rock the format needs and return an OPS TABLE (or nil + reason if the
-- dependency is missing). Laziness matters for the same reason it does in
-- `compression`: registering the zip format must NOT require libdeflate; only
-- opening a real zip pulls it. A project that never touches an archive runs fine
-- without libdeflate, and one that hits a zip without it gets a clear "zip
-- archives are not supported" error for that file (logged once), not a crash.
--
-- An ops table:
--   ops.list(bytes, opts) -> entries | (nil, reason)
--       entries: array of { path=<member path>, size=<uncompressed>,
--                           method=<0|8>, compSize=<n>, offset=<local-header n>,
--                           crc=<central-directory CRC-32> }
--   ops.read(bytes, memberPath, maxBytes) -> memberBytes | (nil, reason)
--
-- The high-level `list`/`read` take the FORMAT explicitly (mirroring
-- `compression.decompress(format, bytes, …)`); a caller derives it from a path
-- via `formatForName`. The registry itself does NO disk I/O — Phase 2's
-- `file_util` owns reading container bytes and caching — so the registry stays a
-- pure (bytes -> members) mapping that is trivially testable in isolation.
-- ============================================================

-- format -> entry, entry = { loader, loaded, ops, err }.
local PROVIDERS = {}
local PROVIDERS_SNAPSHOT

-- Registers a loader for one archive `format` (e.g. "zip"). loader() returns an
-- ops table on success, or (nil, reason) when its dependency cannot be loaded.
-- Re-registering a format replaces the previous provider and resets resolution.
local function registerProvider(format, loader)
    if type(format) ~= "string" or format == "" then
        error("archive_formats.registerProvider: format must be a non-empty string", 2)
    end
    if type(loader) ~= "function" then
        error("archive_formats.registerProvider: loader must be a function", 2)
    end
    PROVIDERS[format] = {loader = loader, loaded = false}
end

-- Resolves a `format` to its ops table, loading the provider exactly once and
-- caching the outcome. Returns (ops) or (nil, reason). The first time a
-- provider's dependency fails to load, the reason is logged at error level so an
-- operator sees WHY a format is unavailable; later calls are silent.
local function resolve(format)
    local entry = PROVIDERS[format]
    if not entry then
        return nil, ("no archive provider for format '%s'"):format(tostring(format))
    end
    if not entry.loaded then
        entry.loaded = true
        local ok, a, b = pcall(entry.loader)
        if ok and type(a) == "table" then
            entry.ops = a
        else
            local reason
            if not ok then
                reason = tostring(a)                       -- loader raised
            else
                reason = tostring(b or a or "unavailable") -- loader returned (nil, reason)
            end
            entry.err = reason
            logger:error(("%s archives are not supported: %s"):format(format, reason))
        end
    end
    if entry.ops then
        return entry.ops
    end
    return nil, entry.err or ("%s archives are not supported"):format(format)
end

-- The extension of `file_name`, lowercased, or nil. Mirrors the loose-file
-- convention: only the final extension is considered (a member's own further
-- decode layers, e.g. `.tsv.gz`, are the content pipeline's job once addressable).
local function extensionOf(file_name)
    if type(file_name) ~= "string" then
        return nil
    end
    local ext = file_name:match("%.([^.\\/]+)$")
    return ext and ext:lower() or nil
end

-- The registered archive format for `file_name` (by extension), or nil. Triggers
-- no provider load — it only checks whether a provider is registered, so it is
-- cheap to call on every collected path.
local function formatForName(file_name)
    local ext = extensionOf(file_name)
    if ext and PROVIDERS[ext] then
        return ext
    end
    return nil
end

-- True iff `file_name`'s extension is a registered archive format.
local function isArchive(file_name)
    return formatForName(file_name) ~= nil
end

-- Lists the members of an archive of `format` held in `bytes`. opts (optional)
-- is provider-specific (the zip provider honours `maxMembers`). Returns the
-- entries array or (nil, reason) — including when the format is unsupported, so
-- callers have one error path. Metadata only: never extracts a member.
local function list(format, bytes, opts)
    local ops, err = resolve(format)
    if not ops then
        return nil, err
    end
    return ops.list(bytes, opts)
end

-- Extracts one member (`memberPath`) from an archive of `format` held in
-- `bytes`. maxBytes (optional) caps the member's uncompressed size to bound a
-- zip bomb (rejected on the central-directory size before inflating, then
-- backstopped on the actual output). Returns the member bytes or (nil, reason).
local function read(format, bytes, memberPath, maxBytes)
    local ops, err = resolve(format)
    if not ops then
        return nil, err
    end
    return ops.read(bytes, memberPath, maxBytes)
end

-- ============================================================
-- Built-in zip provider (pure-Lua central-directory parse + libdeflate inflate)
--
-- Zip is parseable in pure Lua — the same byte-framing work as gzip. We do NOT
-- reimplement DEFLATE: a zip method-8 member is a RAW DEFLATE stream, decoded by
-- the very `compression.decompress("gzip", …)` libdeflate path the gzip provider
-- uses (TODO/archive_files.md §2). No off-the-shelf zip rock is pure-Lua on
-- LuaRocks (all bind a native C lib), so this thin framing parser + libdeflate is
-- less code and dependency surface than vendoring one. v1 targets the common
-- case: a single-disk, non-encrypted, non-Zip64 zip with method 0/8 entries —
-- which is what a TabuLua-built mod produces; everything else is a clear error.
-- ============================================================

-- Zip signatures (little-endian 32-bit), as their four leading bytes.
local SIG_EOCD = {0x50, 0x4b, 0x05, 0x06}  -- end of central directory  "PK\5\6"
local SIG_CDFH = {0x50, 0x4b, 0x01, 0x02}  -- central-directory header  "PK\1\2"
local SIG_LFH  = {0x50, 0x4b, 0x03, 0x04}  -- local file header         "PK\3\4"

-- Default cap on the member count from the central directory (entry-count bomb,
-- §Safety). Overridable per call via opts.maxMembers. The non-Zip64 format can
-- itself only address 65535 entries; this is a softer policy ceiling.
local DEFAULT_MAX_MEMBERS = 65535

-- Reads a little-endian 16-bit integer at 1-based `i`; nil if out of range.
local function u16(s, i)
    local a, b = s:byte(i), s:byte(i + 1)
    if not b then return nil end
    return a + b * 256
end

-- Reads a little-endian 32-bit integer at 1-based `i`; nil if out of range.
local function u32(s, i)
    local a, b, c, d = s:byte(i), s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

-- True iff the four bytes of `sig` appear at 1-based `i` in `s`.
local function sigAt(s, i, sig)
    return s:byte(i) == sig[1] and s:byte(i + 1) == sig[2]
        and s:byte(i + 2) == sig[3] and s:byte(i + 3) == sig[4]
end

-- 0xFFFF / 0xFFFFFFFF sentinels mark a value that lives in a Zip64 extra field,
-- which v1 does not parse — its presence means the archive is Zip64.
local U16_MAX = 0xFFFF
local U32_MAX = 0xFFFFFFFF

-- True iff `path` is unsafe to materialise relative to the archive root: an
-- absolute path, a drive-lettered path, or one that escapes the root via `..`
-- after normalisation (zip-slip, §Safety). Member paths are always
-- archive-relative; anything else is rejected rather than silently mis-placed.
local function isUnsafeMemberPath(path)
    if path:match("^[/\\]") then return true end       -- absolute (POSIX/UNC)
    if path:match("^%a:") then return true end          -- drive letter (Windows)
    local depth = 0
    for seg in path:gmatch("[^/\\]+") do
        if seg == ".." then
            depth = depth - 1
            if depth < 0 then return true end
        elseif seg ~= "." then
            depth = depth + 1
        end
    end
    return false
end

-- Locates the End-Of-Central-Directory record by scanning backward from EOF for
-- its signature, allowing for a trailing comment (max 65535 bytes). Returns its
-- 1-based offset or (nil, reason).
local function findEOCD(s)
    local n = #s
    if n < 22 then
        return nil, "not a zip archive (too short for an end-of-central-directory record)"
    end
    local minPos = math.max(1, n - 21 - U16_MAX)
    for i = n - 21, minPos, -1 do
        if sigAt(s, i, SIG_EOCD) then
            return i
        end
    end
    return nil, "not a zip archive (end-of-central-directory record not found)"
end

-- Parses the central directory of zip `bytes` into the entries array (see the
-- ops contract above), or (nil, reason). Metadata only — no member is extracted.
-- Directory entries (names ending in "/") are omitted; a zip-slip / absolute
-- member path fails the whole parse (never a silent mis-read). Zip64, split, and
-- encrypted archives are explicit clear errors.
local function parseCentralDirectory(s, opts)
    if type(s) ~= "string" then
        return nil, "zip data must be a string"
    end
    local eocd, err = findEOCD(s)
    if not eocd then
        return nil, err
    end
    local diskNo = u16(s, eocd + 4)
    local cdDisk = u16(s, eocd + 6)
    if diskNo ~= 0 or cdDisk ~= 0 then
        return nil, "split (multi-disk) zip archives are not supported"
    end
    local total = u16(s, eocd + 10)
    local cdSize = u32(s, eocd + 12)
    local cdOffset = u32(s, eocd + 16)
    if not (total and cdSize and cdOffset) then
        return nil, "corrupt zip (truncated end-of-central-directory record)"
    end
    if total == U16_MAX or cdSize == U32_MAX or cdOffset == U32_MAX then
        return nil, "Zip64 archives are not supported"
    end
    local maxMembers = (opts and opts.maxMembers) or DEFAULT_MAX_MEMBERS
    if total > maxMembers then
        return nil, ("zip has too many members (%d, cap %d)"):format(total, maxMembers)
    end

    local entries = {}
    local pos = cdOffset + 1                     -- to 1-based
    for k = 1, total do
        if pos + 45 > #s then
            return nil, "corrupt zip (central directory overruns the archive)"
        end
        if not sigAt(s, pos, SIG_CDFH) then
            return nil, ("corrupt zip (bad central-directory signature at entry %d)"):format(k)
        end
        local flag = u16(s, pos + 8)
        local method = u16(s, pos + 10)
        local crc = u32(s, pos + 16)
        local compSize = u32(s, pos + 20)
        local size = u32(s, pos + 24)
        local nameLen = u16(s, pos + 28)
        local extraLen = u16(s, pos + 30)
        local commentLen = u16(s, pos + 32)
        local offset = u32(s, pos + 42)
        if not (flag and method and crc and compSize and size
                and nameLen and extraLen and commentLen and offset) then
            return nil, ("corrupt zip (truncated central-directory header at entry %d)"):format(k)
        end
        if (flag & 0x01) ~= 0 then
            return nil, "encrypted zip archives are not supported"
        end
        if compSize == U32_MAX or size == U32_MAX or offset == U32_MAX then
            return nil, "Zip64 archives are not supported"
        end
        local nameStart = pos + 46
        local name = s:sub(nameStart, nameStart + nameLen - 1)
        if #name ~= nameLen then
            return nil, ("corrupt zip (member name overruns the archive at entry %d)"):format(k)
        end
        -- The zip spec (APPNOTE 4.4.17.1) mandates forward slashes, but some
        -- writers (notably Windows PowerShell's Compress-Archive) emit backslashes.
        -- Normalise here, at the single point where a member name enters the
        -- system, so the rest of the loader — virtual member paths, findMember
        -- lookups, Files.tsv references — sees one separator convention and a
        -- Windows-made zip loads like any other. `read` matches this normalised
        -- path and then seeks by the central-directory offset, never by name, so
        -- the raw on-disk name is not needed past this point.
        name = name:gsub("\\", "/")
        -- Skip directory entries; they carry no data and are not member files
        -- (checked after normalisation, so a backslash-terminated one is caught).
        if not name:match("/$") then
            if isUnsafeMemberPath(name) then
                return nil, ("unsafe member path in zip (zip-slip / absolute): %q"):format(name)
            end
            entries[#entries + 1] = {
                path = name, size = size, method = method,
                compSize = compSize, offset = offset, crc = crc,
            }
        end
        pos = pos + 46 + nameLen + extraLen + commentLen
    end
    return entries
end

-- Builds the zip ops table. `inflate(body)` is the raw-DEFLATE decoder injected
-- by the loader (= compression's libdeflate path), so this framing logic stays
-- free of any direct rock dependency.
local function makeZipOps(inflate)
    local ops = {}

    function ops.list(bytes, opts)
        return parseCentralDirectory(bytes, opts)
    end

    function ops.read(bytes, memberPath, maxBytes)
        local entries, err = parseCentralDirectory(bytes)
        if not entries then
            return nil, err
        end
        local entry
        for _, e in ipairs(entries) do
            if e.path == memberPath then
                entry = e
                break
            end
        end
        if not entry then
            local members = {}
            for _, e in ipairs(entries) do members[#members + 1] = e.path end
            return nil, ("member not found in zip: %q"):format(memberPath)
                .. didYouMean(memberPath, members)
        end
        -- Cheap up-front bomb check on the declared uncompressed size, before
        -- inflating anything (then backstopped on the actual output below).
        if maxBytes and entry.size > maxBytes then
            return nil, ("member %q uncompressed size (%d bytes) exceeds the %d-byte cap")
                :format(memberPath, entry.size, maxBytes)
        end
        local lho = entry.offset + 1                 -- to 1-based
        if lho + 29 > #bytes or not sigAt(bytes, lho, SIG_LFH) then
            return nil, ("corrupt zip (bad local header for member %q)"):format(memberPath)
        end
        -- The local header's name/extra lengths can differ from the central
        -- directory's, so the data offset must be computed from the local header.
        local lNameLen = u16(bytes, lho + 26)
        local lExtraLen = u16(bytes, lho + 28)
        if not (lNameLen and lExtraLen) then
            return nil, ("corrupt zip (truncated local header for member %q)"):format(memberPath)
        end
        local dataStart = lho + 30 + lNameLen + lExtraLen
        local body = bytes:sub(dataStart, dataStart + entry.compSize - 1)
        if #body ~= entry.compSize then
            return nil, ("corrupt zip (compressed data overruns the archive for member %q)")
                :format(memberPath)
        end
        local data
        if entry.method == 0 then                    -- stored
            data = body
        elseif entry.method == 8 then                -- raw DEFLATE
            data = inflate(body, maxBytes)
            if data == nil then
                return nil, ("zip inflate failed for member %q (corrupt DEFLATE stream)")
                    :format(memberPath)
            end
        else
            return nil, ("unsupported zip compression method %d for member %q (only stored/deflate)")
                :format(entry.method, memberPath)
        end
        if maxBytes and #data > maxBytes then
            return nil, ("member %q (%d bytes) exceeds the %d-byte cap")
                :format(memberPath, #data, maxBytes)
        end
        -- Mandatory integrity check vs the central-directory CRC-32 (§Safety, Q4).
        if compression.crc32(data) ~= entry.crc then
            return nil, ("zip member %q failed CRC-32 integrity check (corrupt archive)")
                :format(memberPath)
        end
        return data
    end

    return ops
end

-- The zip provider, registered (but NOT loaded) at module require time. The
-- loader pulls libdeflate lazily on first open; without it the whole zip format
-- reports unsupported (logged once) and the archive's members simply don't load.
registerProvider("zip", function()
    local LibDeflate, err = compression.requireLibDeflate()
    if not LibDeflate then
        return nil, err
    end
    -- A zip method-8 member is a raw DEFLATE stream (no gzip/zlib envelope), so
    -- the same DecompressDeflate call the gzip provider makes inflates it.
    local function inflate(body, _maxBytes)
        return LibDeflate:DecompressDeflate(body)
    end
    return makeZipOps(inflate)
end)

-- ============================================================
-- Snapshot / restore (for global_reset), mirroring compression / content_pipeline.
-- ============================================================

local function snapshotState()
    local s = {}
    for fmt, e in pairs(PROVIDERS) do
        -- Snapshot the loader binding only; the per-resolution cache (loaded/ops/
        -- err) is rebuilt lazily, so a restore re-arms a fresh, unresolved entry.
        s[fmt] = e.loader
    end
    PROVIDERS_SNAPSHOT = s
end

local function restoreState()
    for fmt in pairs(PROVIDERS) do PROVIDERS[fmt] = nil end
    if PROVIDERS_SNAPSHOT then
        for fmt, loader in pairs(PROVIDERS_SNAPSHOT) do
            PROVIDERS[fmt] = {loader = loader, loaded = false}
        end
    end
end

-- ============================================================
-- Public API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    registerProvider = registerProvider,
    isArchive = isArchive,
    formatForName = formatForName,
    list = list,
    read = read,
    snapshotState = snapshotState,
    restoreState = restoreState,
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

-- Snapshot now (the built-in zip provider is registered) and restore on
-- global_reset, mirroring compression / content_pipeline.
snapshotState()
local global_reset = require("util.global_reset")
global_reset.register(restoreState)

return readOnly(API, {__tostring = apiToString, __call = apiCall, __type = NAME})
