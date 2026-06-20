-- archive_export_integration_spec.lua
--
-- Phase 4 of TODO/archive_files.md: export + reformatter behaviour for archives.
--   * the archive file streams to the export VERBATIM (byte-identical), and its
--     members are NOT re-emitted at a nested .zip/ path (input-only);
--   * the reformatter leaves the archive (and its members) untouched — archives
--     are read-only inputs in v1.
-- The fixture zip is built in-test (no zip writer until Phase 5).

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local lfs = require("lfs")
local file_util = require("infra.file_util")
local manifest_loader = require("loader.manifest_loader")
local reformatter = require("reformatter")
local exporter = require("serde.exporter")
local compression = require("content.compression")
local error_reporting = require("infra.error_reporting")

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

-- ---- in-test zip builder ----
local u32le = compression.u32le
local function u16le(n)
    n = n & 0xFFFF
    return string.char(n & 0xFF, (n >> 8) & 0xFF)
end

local function buildZip(members)
    local locals, central = {}, {}
    local offset = 0
    for _, m in ipairs(members) do
        local body = m.data                          -- all stored (method 0)
        local crc = compression.crc32(m.data)
        local lfh = "PK\3\4" .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u16le(0) .. u32le(crc) .. u32le(#body) .. u32le(#m.data)
            .. u16le(#m.name) .. u16le(0) .. m.name .. body
        locals[#locals + 1] = lfh
        central[#central + 1] = "PK\1\2" .. u16le(20) .. u16le(20) .. u16le(0)
            .. u16le(0) .. u16le(0) .. u16le(0) .. u32le(crc) .. u32le(#body)
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
local ITEM_TSV = "name:identifier\tprice:integer\nsword\t100\nshield\t50\n"

local FILES_BODY = table.concat({
    "CustomTypes.tsv\tcustom_type_def\t\ttrue\t1\tCustom types",
    "utilmod.zip/data/Item.tsv\tItem\t\tfalse\t2\tItems inside the zip",
}, "\n") .. "\n"

describe("exporter / reformatter - archives (zip)", function()
    local temp_dir, pkg_dir, zip_path, zip_bytes
    local badVal

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(),
            "zipexp_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000000)))
        assert(lfs.mkdir(td))
        temp_dir = td
        pkg_dir = path_join(td, "ZipPkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME), makeManifest("ZipPkg")))
        assert(file_util.writeFile(path_join(pkg_dir, "CustomTypes.tsv"), ITEM_TYPES))
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), FILES_HEADER .. FILES_BODY))
        zip_bytes = buildZip({{name = "data/Item.tsv", data = ITEM_TSV}})
        zip_path = path_join(pkg_dir, "utilmod.zip")
        assert(file_util.writeFileBinary(zip_path, zip_bytes))
        badVal = error_reporting.badValGen()
        badVal.logger = error_reporting.nullLogger
    end)

    after_each(function()
        if temp_dir then
            local td = temp_dir
            temp_dir = nil
            file_util.deleteTempDir(td)
        end
    end)

    it("streams the archive verbatim and does NOT re-emit its members", function()
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors)

        local exportDir = path_join(temp_dir, "out")
        assert(lfs.mkdir(exportDir))
        assert.is_true(exporter.exportLuaTSV(result, {exportDir = exportDir}))

        -- The zip is exported as a regular FILE, byte-identical to the source.
        local exported_zip = path_join(exportDir, "utilmod.zip")
        assert.is_true(file_util.isFile(exported_zip))
        assert.equals(zip_bytes, file_util.readFileBinary(exported_zip))

        -- It is NOT exploded into a directory: no utilmod.zip/ tree, no member file.
        assert.is_false(file_util.isDir(exported_zip))
        assert.is_false(file_util.isFile(path_join(exportDir, "utilmod.zip", "data", "Item.tsv")))

        -- A loose data file still exports normally (sanity: the export ran).
        assert.is_true(file_util.isFile(path_join(exportDir, "CustomTypes.tsv")))
    end)

    it("leaves the archive (and its members) untouched on reformat", function()
        reformatter.processFiles({pkg_dir})
        -- The source zip bytes are unchanged: the reformatter never wrote into it.
        assert.equals(zip_bytes, file_util.readFileBinary(zip_path))
        -- And it certainly did not turn the zip into a directory.
        assert.is_true(file_util.isFile(zip_path))
    end)
end)
