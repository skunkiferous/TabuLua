-- archive_formats_spec.lua

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local after_each = busted.after_each

local archive_formats = require("content.archive_formats")
local compression = require("content.compression")

-- ------------------------------------------------------------
-- A tiny in-test zip BUILDER. The engine has no zip writer until the
-- (deferred) archive_files.md Phase 5, so fixtures are assembled here from the
-- raw framing: a single-disk, non-Zip64 zip with method 0 (stored) and/or
-- method 8 (raw DEFLATE) members. Stored needs no dependency; deflate uses the
-- same libdeflate the production provider does. crc32 comes from compression
-- (the very value the provider verifies on read).
-- ------------------------------------------------------------

local u32le = compression.u32le
local function u16le(n)
    -- arithmetic, not 5.3 bitwise operators: LuaJIT cannot parse those
    n = n % 0x10000
    return string.char(n % 256, math.floor(n / 256))
end

local LibDeflate
do
    local ok, lib = pcall(require, "LibDeflate")
    if ok and type(lib) == "table" then LibDeflate = lib end
end

-- members: array of { name=<path>, data=<bytes>, method=0|8 } (method default 0).
-- Returns the assembled zip bytes. With opts.comment a trailing EOCD comment is
-- appended (to exercise the backward scan).
local function buildZip(members, opts)
    opts = opts or {}
    local locals, central = {}, {}
    local offset = 0
    for _, m in ipairs(members) do
        local method = m.method or 0
        local data = m.data
        local body
        if method == 8 then
            body = LibDeflate:CompressDeflate(data)
        else
            body = data
        end
        local crc = compression.crc32(data)
        local lfh = "PK\3\4" .. u16le(20) .. u16le(0) .. u16le(method)
            .. u16le(0) .. u16le(0) .. u32le(crc) .. u32le(#body) .. u32le(#data)
            .. u16le(#m.name) .. u16le(0) .. m.name .. body
        locals[#locals + 1] = lfh
        central[#central + 1] = "PK\1\2" .. u16le(20) .. u16le(20) .. u16le(0)
            .. u16le(method) .. u16le(0) .. u16le(0) .. u32le(crc) .. u32le(#body)
            .. u32le(#data) .. u16le(#m.name) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u16le(0) .. u32le(0) .. u32le(offset) .. m.name
        offset = offset + #lfh
    end
    local localBlob = table.concat(locals)
    local centralBlob = table.concat(central)
    local comment = opts.comment or ""
    local eocd = "PK\5\6" .. u16le(0) .. u16le(0) .. u16le(#members) .. u16le(#members)
        .. u32le(#centralBlob) .. u32le(#localBlob) .. u16le(#comment) .. comment
    return localBlob .. centralBlob .. eocd
end

-- A reusable fixture: a stored and a deflated member.
local function sampleZip()
    return buildZip({
        {name = "data/Item.tsv", data = "id\tvalue\nitem1\t42\n", method = 0},
        {name = "readme.txt", data = ("hello world "):rep(50), method = 8},
    })
end

describe("archive_formats", function()
    after_each(function()
        -- Re-arm the built-in zip provider after any test that registered a fake
        -- one, so tests stay order-independent (mirrors snapshot/restore).
        archive_formats.restoreState()
    end)

    describe("getVersion", function()
        it("returns a version string", function()
            assert.is_truthy(archive_formats.getVersion():match("%d+%.%d+%.%d+"))
        end)
    end)

    describe("formatForName / isArchive", function()
        it("recognises a .zip by extension", function()
            assert.equals("zip", archive_formats.formatForName("mods/utilmod.zip"))
            assert.is_true(archive_formats.isArchive("utilmod.ZIP"))
        end)

        it("is case-insensitive on the extension", function()
            assert.equals("zip", archive_formats.formatForName("X.Zip"))
        end)

        it("returns nil for a non-archive extension", function()
            assert.is_nil(archive_formats.formatForName("data/Item.tsv"))
            assert.is_false(archive_formats.isArchive("data/Item.tsv"))
            assert.is_false(archive_formats.isArchive("noextension"))
        end)
    end)

    describe("list", function()
        it("enumerates members of a fixture zip (metadata only)", function()
            local entries, err = archive_formats.list("zip", sampleZip())
            assert.is_nil(err)
            assert.equals(2, #entries)
            local byPath = {}
            for _, e in ipairs(entries) do byPath[e.path] = e end
            assert.is_truthy(byPath["data/Item.tsv"])
            assert.equals(18, byPath["data/Item.tsv"].size)   -- uncompressed
            assert.equals(0, byPath["data/Item.tsv"].method)
            assert.equals(8, byPath["readme.txt"].method)
        end)

        it("omits directory entries (names ending in /)", function()
            local zip = buildZip({
                {name = "dir/", data = ""},
                {name = "dir/a.tsv", data = "x\n"},
            })
            local entries = archive_formats.list("zip", zip)
            assert.equals(1, #entries)
            assert.equals("dir/a.tsv", entries[1].path)
        end)

        -- Windows PowerShell's Compress-Archive writes backslash-separated member
        -- names, against APPNOTE 4.4.17.1. Such a zip used to enumerate as
        -- `data\Item.tsv` while every lookup normalised to `data/Item.tsv`, so the
        -- member could never be read back ("member not found", with a did-you-mean
        -- pointing at the name we had just listed).
        it("normalises backslash-separated member names to forward slashes", function()
            local zip = buildZip({{name = "data\\Item.tsv", data = "x\n"}})
            local entries, err = archive_formats.list("zip", zip)
            assert.is_nil(err)
            assert.equals(1, #entries)
            assert.equals("data/Item.tsv", entries[1].path)
        end)

        it("omits a backslash-terminated directory entry", function()
            local zip = buildZip({
                {name = "dir\\", data = ""},
                {name = "dir\\a.tsv", data = "x\n"},
            })
            local entries = archive_formats.list("zip", zip)
            assert.equals(1, #entries)
            assert.equals("dir/a.tsv", entries[1].path)
        end)

        it("finds the EOCD past a trailing comment", function()
            local zip = buildZip({{name = "a.txt", data = "hi"}},
                {comment = "this is a zip file comment"})
            local entries, err = archive_formats.list("zip", zip)
            assert.is_nil(err)
            assert.equals(1, #entries)
        end)

        it("trips the member-count cap", function()
            local entries, err = archive_formats.list("zip", sampleZip(), {maxMembers = 1})
            assert.is_nil(entries)
            assert.matches("too many members", err)
        end)

        it("rejects a zip-slip / absolute member path", function()
            local zip = buildZip({{name = "../../etc/passwd", data = "x"}})
            local entries, err = archive_formats.list("zip", zip)
            assert.is_nil(entries)
            assert.matches("unsafe member path", err)
        end)

        it("errors on data that is not a zip", function()
            local entries, err = archive_formats.list("zip", "not a zip at all")
            assert.is_nil(entries)
            assert.matches("not a zip archive", err)
        end)

        it("errors on a corrupt central-directory signature", function()
            local zip = sampleZip()
            -- Corrupt the first central-directory header signature. The central
            -- directory begins right after the local section; flip a byte inside
            -- the first "PK\1\2" by rebuilding from a clearly-bad blob.
            local bad = zip:gsub("PK\1\2", "PK\1X", 1)
            local entries, err = archive_formats.list("zip", bad)
            assert.is_nil(entries)
            assert.is_string(err)
        end)
    end)

    describe("read", function()
        it("reads a stored (method 0) member verbatim", function()
            local data, err = archive_formats.read("zip", sampleZip(), "data/Item.tsv")
            assert.is_nil(err)
            assert.equals("id\tvalue\nitem1\t42\n", data)
        end)

        -- The pay-off of normalising at parse time: a backslash-named member is
        -- addressable by its normalised path, so a Windows-made zip loads like any
        -- other. `read` matches the normalised path and then seeks by the
        -- central-directory offset, never by the raw on-disk name.
        it("reads a backslash-named member by its normalised path", function()
            local zip = buildZip({{name = "data\\Item.tsv", data = "id\tvalue\nitem1\t42\n"}})
            local data, err = archive_formats.read("zip", zip, "data/Item.tsv")
            assert.is_nil(err)
            assert.equals("id\tvalue\nitem1\t42\n", data)
        end)

        it("reads a deflated (method 8) member", function()
            local expected = ("hello world "):rep(50)
            local data, err = archive_formats.read("zip", sampleZip(), "readme.txt")
            assert.is_nil(err)
            assert.equals(expected, data)
        end)

        it("returns an error for a member that does not exist", function()
            local data, err = archive_formats.read("zip", sampleZip(), "nope.tsv")
            assert.is_nil(data)
            assert.matches("member not found", err)
        end)

        it("trips the maxBytes bomb cap on the declared size before inflating", function()
            local data, err = archive_formats.read("zip", sampleZip(), "readme.txt", 5)
            assert.is_nil(data)
            assert.matches("exceeds", err)
        end)

        it("honours a maxBytes large enough for the member", function()
            local data = archive_formats.read("zip", sampleZip(), "data/Item.tsv", 1024)
            assert.equals("id\tvalue\nitem1\t42\n", data)
        end)

        it("fails the read on a CRC-32 mismatch (corrupt archive)", function()
            -- Build a stored member, then corrupt its stored data byte in place.
            local zip = buildZip({{name = "a.txt", data = "ABCDEFGH", method = 0}})
            -- The stored data "ABCDEFGH" appears once in the local section.
            local bad = zip:gsub("ABCDEFGH", "ABCDEFGX", 1)
            local data, err = archive_formats.read("zip", bad, "a.txt")
            assert.is_nil(data)
            assert.matches("CRC%-32", err)
        end)
    end)

    describe("provider resolution (graceful degradation)", function()
        it("treats a missing dependency as unsupported (loader returns nil, reason)", function()
            archive_formats.registerProvider("fakezip", function()
                return nil, "pretend-rock is not installed"
            end)
            local entries, err = archive_formats.list("fakezip", "whatever")
            assert.is_nil(entries)
            assert.matches("pretend%-rock is not installed", err)
            local data, rerr = archive_formats.read("fakezip", "whatever", "m")
            assert.is_nil(data)
            assert.matches("pretend%-rock is not installed", rerr)
        end)

        it("treats a loader that raises as unsupported (graceful)", function()
            archive_formats.registerProvider("boomzip", function()
                error("boom while loading")
            end)
            local entries, err = archive_formats.list("boomzip", "whatever")
            assert.is_nil(entries)
            assert.is_string(err)
        end)

        it("returns an error for an unregistered format", function()
            local entries, err = archive_formats.list("rar", "whatever")
            assert.is_nil(entries)
            assert.matches("no archive provider", err)
        end)

        it("loads each provider at most once and caches the result", function()
            local calls = 0
            archive_formats.registerProvider("countzip", function()
                calls = calls + 1
                return {list = function() return {} end, read = function() return "" end}
            end)
            archive_formats.list("countzip", "a")
            archive_formats.read("countzip", "a", "m")
            archive_formats.list("countzip", "b")
            assert.equals(1, calls)
        end)

        it("validates registerProvider arguments", function()
            assert.has_error(function() archive_formats.registerProvider("", function() end) end)
            assert.has_error(function() archive_formats.registerProvider("x", "nope") end)
        end)
    end)
end)
