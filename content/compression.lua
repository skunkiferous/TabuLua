-- Module name
local NAME = "compression"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 28, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

local logger = require("infra.named_logger").getLogger(NAME)

-- Returns the module version as a string.
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- Compression codec registry (see TODO/content_pipeline.md §3.7, §9 Q2)
--
-- Each (format, direction) pair — e.g. ("gzip", "decompress") — is an
-- *independently and optionally supported* codec. A provider registers a
-- LOADER for a pair; the loader is run lazily the first time that pair is
-- actually used, and is expected to pull in whatever rock/native lib the codec
-- needs and return the operation function (or nil + reason if the dependency
-- is missing).
--
-- The point of the laziness: registering the gzip stage does NOT require
-- `libdeflate`; only inflating a real `.gz` file does. A pipeline that never
-- touches a compressed file works fine on a machine without `libdeflate` — and
-- a pipeline that *does* hit a `.gz` without it gets a clear "gzip decompression
-- is not supported" error for that file (logged once), instead of a hard
-- require failure at startup.
--
-- direction is "decompress" or "compress". Today gzip ships in BOTH directions
-- (gunzip and gzip), both built on the pure-Lua libdeflate rock; other formats
-- (zstd, brotli, …) are simply pairs with no provider yet — isSupported()
-- reports false and the operation returns an error.
-- ============================================================

local DECOMPRESS = "decompress"
local COMPRESS = "compress"

-- format -> { [direction] = entry }, entry = { loader, loaded, impl, err }.
local PROVIDERS = {}

-- Registers a loader for one (format, direction). loader() returns the operation
-- function on success, or (nil, reason) when its dependency cannot be loaded.
-- Re-registering a pair replaces the previous provider and resets its resolution.
local function registerProvider(format, direction, loader)
    if type(format) ~= "string" or format == "" then
        error("compression.registerProvider: format must be a non-empty string", 2)
    end
    if direction ~= DECOMPRESS and direction ~= COMPRESS then
        error("compression.registerProvider: direction must be '" .. DECOMPRESS
            .. "' or '" .. COMPRESS .. "'", 2)
    end
    if type(loader) ~= "function" then
        error("compression.registerProvider: loader must be a function", 2)
    end
    PROVIDERS[format] = PROVIDERS[format] or {}
    PROVIDERS[format][direction] = {loader = loader, loaded = false}
end

-- Resolves a (format, direction) to its operation function, loading the provider
-- exactly once and caching the outcome. Returns (fn) or (nil, reason). The first
-- time a provider's dependency fails to load, the reason is logged at error level
-- so an operator sees *why* a format is unavailable; later calls are silent.
local function resolve(format, direction)
    local byFormat = PROVIDERS[format]
    local entry = byFormat and byFormat[direction]
    if not entry then
        return nil, ("no %s provider for format '%s'"):format(direction, tostring(format))
    end
    if not entry.loaded then
        entry.loaded = true
        local ok, a, b = pcall(entry.loader)
        if ok and type(a) == "function" then
            entry.impl = a
        else
            local reason
            if not ok then
                reason = tostring(a)                       -- loader raised
            else
                reason = tostring(b or a or "unavailable") -- loader returned (nil, reason)
            end
            entry.err = reason
            logger:error(("%s %s is not supported: %s"):format(format, direction, reason))
        end
    end
    if entry.impl then
        return entry.impl
    end
    return nil, entry.err or ("%s %s is not supported"):format(format, direction)
end

-- True iff the given (format, direction) codec can be used right now (a provider
-- is registered and its dependency loads). Triggers the one-time load attempt.
local function isSupported(format, direction)
    return (resolve(format, direction)) ~= nil
end

-- Decompresses `bytes` using `format`. maxBytes (optional) caps the output to
-- bound decompression bombs (§3.7). Returns (data) or (nil, reason) — including
-- when the format is unsupported, so callers can surface one error path.
local function decompress(format, bytes, maxBytes)
    local impl, err = resolve(format, DECOMPRESS)
    if not impl then
        return nil, err
    end
    return impl(bytes, maxBytes)
end

-- Compresses `bytes` using `format`. opts (optional) is codec-specific (gzip
-- accepts `{level = 1..9}`, passed through to libdeflate). Returns (data) or
-- (nil, reason) — including when the format is unsupported, so callers have one
-- error path. gzip/compress ships; other formats report unsupported until a
-- provider is registered.
local function compress(format, bytes, opts)
    local impl, err = resolve(format, COMPRESS)
    if not impl then
        return nil, err
    end
    return impl(bytes, opts)
end

-- ============================================================
-- Built-in providers
-- ============================================================

-- Parses a gzip header (RFC 1952) and locates the raw DEFLATE body. Returns
-- (bodyStart, isize): bodyStart is the 1-based index where the DEFLATE stream
-- begins, and isize is the uncompressed size modulo 2^32 from the 4-byte
-- trailer. Returns (nil, errmsg) for a malformed/too-short header. Pure byte
-- parsing — needs no external library, so it lives outside the loader.
local function gzipFraming(s)
    if type(s) ~= "string" or #s < 18 then
        return nil, "gzip data too short"
    end
    if s:byte(1) ~= 0x1f or s:byte(2) ~= 0x8b then
        return nil, "not a gzip stream (bad magic)"
    end
    if s:byte(3) ~= 8 then
        return nil, "unsupported gzip compression method " .. s:byte(3)
    end
    local flg = s:byte(4)
    local pos = 11                                  -- past the 10-byte fixed header
    if (flg & 0x04) ~= 0 then                       -- FEXTRA: 2-byte length + payload
        if pos + 1 > #s then return nil, "truncated gzip FEXTRA field" end
        local xlen = s:byte(pos) + s:byte(pos + 1) * 256
        pos = pos + 2 + xlen
    end
    if (flg & 0x08) ~= 0 then                        -- FNAME: NUL-terminated
        while pos <= #s and s:byte(pos) ~= 0 do pos = pos + 1 end
        pos = pos + 1
    end
    if (flg & 0x10) ~= 0 then                        -- FCOMMENT: NUL-terminated
        while pos <= #s and s:byte(pos) ~= 0 do pos = pos + 1 end
        pos = pos + 1
    end
    if (flg & 0x02) ~= 0 then                        -- FHCRC: 2 bytes
        pos = pos + 2
    end
    if pos > #s - 8 then
        return nil, "gzip header overruns the data"
    end
    local n = #s                                     -- ISIZE: trailing 4 bytes, little-endian
    local isize = s:byte(n - 3) + s:byte(n - 2) * 256
        + s:byte(n - 1) * 65536 + s:byte(n) * 16777216
    return pos, isize
end

-- gzip decompression (gunzip), built on the pure-Lua libdeflate rock. libdeflate
-- 1.0.2 exposes raw-deflate / zlib but not the gzip wrapper, so we parse the
-- envelope (gzipFraming) and hand the DEFLATE body to DecompressDeflate. The
-- loader fails gracefully — returning (nil, reason) — when libdeflate is absent.
registerProvider("gzip", DECOMPRESS, function()
    local ok, LibDeflate = pcall(require, "libdeflate")
    if not ok or type(LibDeflate) ~= "table" then
        return nil, "libdeflate rock is not installed"
    end
    return function(s, maxBytes)
        local bodyStart, isizeOrErr = gzipFraming(s)
        if not bodyStart then
            return nil, isizeOrErr
        end
        -- Cheap up-front bomb check: reject on the declared ISIZE before
        -- inflating anything (ISIZE is only mod 2^32, hence the backstop below).
        if maxBytes and isizeOrErr > maxBytes then
            return nil, ("decompressed size (%d bytes, per gzip ISIZE) exceeds the %d-byte cap")
                :format(isizeOrErr, maxBytes)
        end
        -- DecompressDeflate ignores the trailing CRC32/ISIZE (returned as the
        -- unconsumed-byte count, which we don't need).
        local data = LibDeflate:DecompressDeflate(s:sub(bodyStart))
        if data == nil then
            return nil, "gzip inflate failed (corrupt DEFLATE stream)"
        end
        if maxBytes and #data > maxBytes then
            return nil, ("decompressed size (%d bytes) exceeds the %d-byte cap")
                :format(#data, maxBytes)
        end
        return data
    end
end)

-- CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320) in pure Lua, for the gzip
-- trailer. libdeflate computes Adler-32 (for the zlib wrapper) but never exposes
-- CRC-32, and the gzip envelope's integrity field is specifically CRC-32 — so a
-- small, dependency-free implementation lives here. The 256-entry lookup table is
-- built once, lazily on the first compression, so merely requiring this module
-- (or only ever decompressing) costs nothing.
local CRC32_TABLE
local function crc32(s)
    local t = CRC32_TABLE
    if not t then
        t = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if (c & 1) ~= 0 then
                    c = 0xEDB88320 ~ (c >> 1)
                else
                    c = c >> 1
                end
            end
            t[i] = c
        end
        CRC32_TABLE = t
    end
    local crc = 0xFFFFFFFF
    for i = 1, #s do
        crc = (crc >> 8) ~ t[(crc ~ s:byte(i)) & 0xFF]
    end
    return crc ~ 0xFFFFFFFF
end

-- Encodes a number as 4 little-endian bytes — the format of the gzip trailer's
-- CRC32 and ISIZE fields — taking it modulo 2^32 as the format requires.
local function u32le(n)
    n = n & 0xFFFFFFFF
    return string.char(n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF)
end

-- The fixed 10-byte gzip header (RFC 1952): magic 1f 8b, CM=8 (deflate), FLG=0
-- (no name/comment/extra/hcrc), MTIME=0, XFL=0, OS=255 (unknown). A header this
-- plain is what gzipFraming (above) parses on the way back in.
local GZIP_HEADER = string.char(0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff)

-- gzip compression, the inverse of the decompress provider above. libdeflate
-- produces the raw DEFLATE body; we wrap it in the RFC 1952 envelope ourselves
-- (the fixed header, then a CRC32 + ISIZE trailer computed in pure Lua). The
-- output round-trips through our own gunzip provider AND standard `gunzip`/zcat.
-- `opts.level` (1..9) is forwarded to libdeflate's deflate level. The loader
-- degrades gracefully — (nil, reason) — when libdeflate is absent.
registerProvider("gzip", COMPRESS, function()
    local ok, LibDeflate = pcall(require, "libdeflate")
    if not ok or type(LibDeflate) ~= "table" then
        return nil, "libdeflate rock is not installed"
    end
    return function(s, opts)
        if type(s) ~= "string" then
            return nil, "gzip compress expects a string"
        end
        local configs
        if type(opts) == "table" and opts.level then
            configs = {level = opts.level}
        end
        local body = LibDeflate:CompressDeflate(s, configs)
        if type(body) ~= "string" then
            return nil, "libdeflate CompressDeflate failed"
        end
        return GZIP_HEADER .. body .. u32le(crc32(s)) .. u32le(#s)
    end
end)

-- ============================================================
-- Public API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    DECOMPRESS = DECOMPRESS,
    COMPRESS = COMPRESS,
    registerProvider = registerProvider,
    isSupported = isSupported,
    decompress = decompress,
    compress = compress,
    -- Low-level primitives reused by the archive_formats zip provider (a zip's
    -- method-8 member is raw DEFLATE — decoded via decompress's libdeflate — and
    -- each member carries a CRC-32 integrity field with the same IEEE polynomial
    -- as the gzip trailer). Exposed so the zip reader/writer needs no second copy
    -- (TODO/archive_files.md Q4): crc32(bytes) -> number, u32le(n) -> 4-byte LE.
    crc32 = crc32,
    u32le = u32le,
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
