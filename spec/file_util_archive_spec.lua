-- file_util_archive_spec.lua
--
-- Phase 2 of TODO/archive_files.md: virtual member paths + archive-aware
-- readFileBinary / getFileSize. The fixture zip is built in-test (the engine has
-- no zip writer until Phase 5) and written to a temp dir, so these exercise the
-- real on-disk resolution path.

local busted = require("busted")
local assert = require("luassert")

local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local file_util = require("infra.file_util")
local compression = require("content.compression")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- ---- in-test zip builder (same framing as archive_formats_spec) ----
local u32le = compression.u32le
local function u16le(n)
    -- arithmetic, not 5.3 bitwise operators: LuaJIT cannot parse those
    n = n % 0x10000
    return string.char(n % 256, math.floor(n / 256))
end
local LibDeflate = require("LibDeflate")

local function buildZip(members)
    local locals, central = {}, {}
    local offset = 0
    for _, m in ipairs(members) do
        local method = m.method or 0
        local body = (method == 8) and LibDeflate:CompressDeflate(m.data) or m.data
        local crc = compression.crc32(m.data)
        local lfh = "PK\3\4" .. u16le(20) .. u16le(0) .. u16le(method) .. u16le(0)
            .. u16le(0) .. u32le(crc) .. u32le(#body) .. u32le(#m.data)
            .. u16le(#m.name) .. u16le(0) .. m.name .. body
        locals[#locals + 1] = lfh
        central[#central + 1] = "PK\1\2" .. u16le(20) .. u16le(20) .. u16le(0)
            .. u16le(method) .. u16le(0) .. u16le(0) .. u32le(crc) .. u32le(#body)
            .. u32le(#m.data) .. u16le(#m.name) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u16le(0) .. u32le(0) .. u32le(offset) .. m.name
        offset = offset + #lfh
    end
    local localBlob = table.concat(locals)
    local centralBlob = table.concat(central)
    local eocd = "PK\5\6" .. u16le(0) .. u16le(0) .. u16le(#members) .. u16le(#members)
        .. u32le(#centralBlob) .. u32le(#localBlob) .. u16le(0)
    return localBlob .. centralBlob .. eocd
end

local ITEM_TSV = "id\tvalue\nitem1\t42\nitem2\t100\n"

describe("file_util archive awareness", function()
    local temp_dir, zip_path

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(), "lua_archive_test_" .. os.time() .. "_" .. math.random(1e6))
        assert(lfs.mkdir(td))
        temp_dir = td
        zip_path = path_join(td, "utilmod.zip")
        local zip = buildZip({
            {name = "data/Item.tsv", data = ITEM_TSV, method = 0},
            {name = "Big.txt", data = ("packed "):rep(100), method = 8},
        })
        assert(file_util.writeFileBinary(zip_path, zip))
    end)

    after_each(function()
        if temp_dir then
            local td = temp_dir
            temp_dir = nil
            file_util.deleteTempDir(td)
        end
    end)

    describe("resolveArchivePath", function()
        it("splits a path that points inside a real archive file", function()
            local container, member = file_util.resolveArchivePath(zip_path .. "/data/Item.tsv")
            assert.equals(zip_path, container)
            assert.equals("data/Item.tsv", member)
        end)

        it("returns (path, nil) for an ordinary loose file", function()
            local loose = path_join(temp_dir, "loose.tsv")
            assert(file_util.writeFileBinary(loose, "x\n"))
            local container, member = file_util.resolveArchivePath(loose)
            assert.equals(loose, container)
            assert.is_nil(member)
        end)

        it("returns (path, nil) when the .zip segment is the whole path (no member)", function()
            local container, member = file_util.resolveArchivePath(zip_path)
            assert.equals(zip_path, container)
            assert.is_nil(member)
        end)

        it("treats a directory literally named *.zip as a directory, not an archive", function()
            local dirZip = path_join(temp_dir, "notreally.zip")
            assert(lfs.mkdir(dirZip))
            local container, member = file_util.resolveArchivePath(dirZip .. "/inside.tsv")
            assert.equals(dirZip .. "/inside.tsv", container)
            assert.is_nil(member)
        end)

        it("normalises backslash member separators to forward slashes", function()
            local _, member = file_util.resolveArchivePath(zip_path .. "\\data\\Item.tsv")
            assert.equals("data/Item.tsv", member)
        end)
    end)

    describe("readFileBinary", function()
        it("extracts a stored member transparently", function()
            local data, err = file_util.readFileBinary(zip_path .. "/data/Item.tsv")
            assert.is_nil(err)
            assert.equals(ITEM_TSV, data)
        end)

        it("extracts a deflated member transparently", function()
            local data = file_util.readFileBinary(zip_path .. "/Big.txt")
            assert.equals(("packed "):rep(100), data)
        end)

        it("errors for a member that does not exist", function()
            local data, err = file_util.readFileBinary(zip_path .. "/nope.tsv")
            assert.is_nil(data)
            assert.matches("member not found", err)
        end)

        it("enforces the per-member maxBytes cap", function()
            local data, err = file_util.readFileBinary(zip_path .. "/data/Item.tsv", 4)
            assert.is_nil(data)
            assert.matches("exceeds", err)
        end)

        it("reads a loose file byte-identically (ablation)", function()
            local loose = path_join(temp_dir, "plain.bin")
            local bytes = string.char(0, 13, 10, 255, 1, 2, 3)
            assert(file_util.writeFileBinary(loose, bytes))
            assert.equals(bytes, file_util.readFileBinary(loose))
        end)
    end)

    describe("getFileSize", function()
        it("returns a member's uncompressed size without extracting", function()
            local size, err = file_util.getFileSize(zip_path .. "/data/Item.tsv")
            assert.is_nil(err)
            assert.equals(#ITEM_TSV, size)
        end)

        it("returns the uncompressed (not compressed) size of a deflated member", function()
            local size = file_util.getFileSize(zip_path .. "/Big.txt")
            assert.equals(#(("packed "):rep(100)), size)
        end)

        it("errors for a missing member", function()
            local size, err = file_util.getFileSize(zip_path .. "/nope.tsv")
            assert.is_nil(size)
            assert.matches("member not found", err)
        end)

        it("stats a loose file as before (ablation)", function()
            local loose = path_join(temp_dir, "loose.txt")
            assert(file_util.writeFileBinary(loose, "1234567890"))
            assert.equals(10, file_util.getFileSize(loose))
        end)
    end)
end)
