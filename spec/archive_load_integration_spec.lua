-- archive_load_integration_spec.lua
--
-- Phase 3 of TODO/archive_files.md: collection / expansion + end-to-end load.
-- A package whose Files.tsv references members INSIDE a zip loads them like loose
-- files:
--   * a member .tsv loads as typed data and its rows appear in the model;
--   * a member data.tsv.gz decodes AND parses (archive ∘ content-pipeline);
--   * a collectable text member (notes.txt) gets an asset/raw_files entry;
--   * a Files.tsv typo inside the archive yields the normal "not found" error.
-- The fixture zip is built in-test (no zip writer until Phase 5).

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local lfs = require("lfs")
local file_util = require("file_util")
local manifest_loader = require("manifest_loader")
local compression = require("compression")
local error_reporting = require("error_reporting")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local MANIFEST_FILENAME = "Manifest.transposed.tsv"

local FILES_HEADER = table.concat({
    "fileName:filepath", "typeName:type_spec", "superType:super_type",
    "baseType:boolean", "loadOrder:number", "description:text",
}, "\t") .. "\n"

local function makeManifest(pkg_id)
    return table.concat({
        "package_id:package_id\t" .. pkg_id,
        "name:string\t" .. pkg_id .. " Package",
        "version:version\t0.1.0",
        "description:markdown\tTest package",
    }, "\n") .. "\n"
end

-- ---- in-test zip builder (stored + deflated members; same framing as the
-- archive_formats / file_util archive specs) ----
local u32le = compression.u32le
local function u16le(n)
    n = n & 0xFFFF
    return string.char(n & 0xFF, (n >> 8) & 0xFF)
end
local LibDeflate = require("libdeflate")

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

local ITEM_TYPES = "name:name\tparent:type_spec|nil\n" ..
    "Item\t{name:identifier,price:integer}\n"

-- The loose-TSV member.
local ITEM_TSV = "name:identifier\tprice:integer\nsword\t100\nshield\t50\n"
-- The gzipped-TSV member (different rows, so the two are distinguishable).
local GZ_TSV = "name:identifier\tprice:integer\nbow\t75\n"
local NOTES = "just an asset, not data\n"

describe("manifest_loader - archive member loading (zip)", function()
    local temp_dir = ""
    local log_messages = {}
    local badVal = error_reporting.badValGen()

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(),
            "ziploadtest_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000000)))
        assert(lfs.mkdir(td))
        temp_dir = td
        log_messages = {}
        local log = function(_self, msg) table.insert(log_messages, msg) end
        badVal = error_reporting.badValGen(log)
        badVal.logger = error_reporting.nullLogger
    end)

    after_each(function()
        if temp_dir ~= "" then
            file_util.deleteTempDir(temp_dir)
            temp_dir = ""
        end
    end)

    -- Builds a package: loose CustomTypes.tsv (loadOrder 1) defining Item, and a
    -- utilmod.zip whose members are referenced in Files.tsv. `files_body` is the
    -- Files.tsv rows after the header; pass a custom one to inject a typo.
    local function makePkg(files_body)
        local pkg_dir = path_join(temp_dir, "ZipPkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME), makeManifest("ZipPkg")))
        assert(file_util.writeFile(path_join(pkg_dir, "CustomTypes.tsv"), ITEM_TYPES))
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), FILES_HEADER .. files_body))

        local zip = buildZip({
            {name = "data/Item.tsv", data = ITEM_TSV, method = 0},
            {name = "data.tsv.gz", data = compression.compress("gzip", GZ_TSV), method = 0},
            {name = "notes.txt", data = NOTES, method = 8},
        })
        assert(file_util.writeFileBinary(path_join(pkg_dir, "utilmod.zip"), zip))
        return pkg_dir
    end

    local DEFAULT_FILES = table.concat({
        "CustomTypes.tsv\tcustom_type_def\t\ttrue\t1\tCustom types",
        "utilmod.zip/data/Item.tsv\tItem\t\tfalse\t2\tItems inside the zip",
        "utilmod.zip/data.tsv.gz\tItem\t\tfalse\t3\tGzipped items inside the zip",
    }, "\n") .. "\n"

    local function findBySuffix(map, suffix)
        for path, v in pairs(map) do
            if path:sub(-#suffix) == suffix then return v, path end
        end
        return nil
    end

    it("loads a member .tsv as typed Item data", function()
        local pkg_dir = makePkg(DEFAULT_FILES)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))

        local tsv = findBySuffix(result.tsv_files, "utilmod.zip/data/Item.tsv")
        assert.is_not_nil(tsv)
        assert.equals(3, #tsv)                          -- header + 2 rows
        local header = tsv[1]
        assert.equals("sword", tsv[2][header.name.idx].parsed)
        assert.equals(100, tsv[2][header.price.idx].parsed)
        assert.equals("shield", tsv[3][header.name.idx].parsed)
        assert.equals(50, tsv[3][header.price.idx].parsed)
    end)

    it("decodes AND parses a member data.tsv.gz (archive ∘ content-pipeline)", function()
        local pkg_dir = makePkg(DEFAULT_FILES)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))

        local tsv = findBySuffix(result.tsv_files, "utilmod.zip/data.tsv.gz")
        assert.is_not_nil(tsv)
        assert.equals(2, #tsv)                          -- header + 1 row
        local header = tsv[1]
        assert.equals("bow", tsv[2][header.name.idx].parsed)
        assert.equals(75, tsv[2][header.price.idx].parsed)
    end)

    it("gives a collectable text member (notes.txt) an asset/raw_files entry", function()
        -- notes.txt is not listed in Files.tsv (assets aren't), but expandArchives
        -- still collects it; as a non-data text file it is stored as a raw asset,
        -- read transparently through the archive.
        local pkg_dir = makePkg(DEFAULT_FILES)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))

        local raw = findBySuffix(result.raw_files, "utilmod.zip/notes.txt")
        assert.is_not_nil(raw)
        assert.equals(NOTES, raw)                        -- text asset stored verbatim
    end)

    it("still streams the zip itself as a passthrough asset", function()
        local pkg_dir = makePkg(DEFAULT_FILES)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        local raw = findBySuffix(result.raw_files, "utilmod.zip")
        assert.is_not_nil(raw)
        assert.is_true(raw.__passthrough)
        assert.equals("binary", raw.kind)
    end)

    it("reports the normal 'not found' error for a typo in a member path", function()
        local files = table.concat({
            "CustomTypes.tsv\tcustom_type_def\t\ttrue\t1\tCustom types",
            "utilmod.zip/data/Nope.tsv\tItem\t\tfalse\t2\tTypo member",
        }, "\n") .. "\n"
        local pkg_dir = makePkg(files)
        manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_true(badVal.errors > 0)
        local joined = table.concat(log_messages, " | ")
        assert.matches("does not exist", joined)
    end)
end)
