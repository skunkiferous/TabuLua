-- gzip_reversible_integration_spec.lua
-- End-to-end for the reversible gzip round-trip (content_pipeline.md §3.6,
-- CP Phase 4 Part B):
--   * a data.tsv.gz on disk is collected, gunzipped by the decode stage, and
--     parsed as ordinary TSV data (proves the collection gap is closed);
--   * the reformatter rewrites it by reformatting the decoded TSV and
--     re-compressing — it MUST NOT clobber the .gz with plaintext TSV.

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
local compression = require("content.compression")
local error_reporting = require("infra.error_reporting")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local MANIFEST_FILENAME = "Manifest.transposed.tsv"

-- Files.tsv header (no transcoder column needed — a .tsv.gz is decoded, not
-- transcoded).
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

-- The decoded TSV the .gz wraps. The non-canonical `050` (reformats to `50`)
-- guarantees the reformatter rewrites — and thus re-compresses — it in one pass,
-- without the trailing-newline settling quirk a blank last line would introduce.
local TSV_HEADER = "name:identifier\tprice:integer\ttag:string|nil\n"
local TSV_MESSY = TSV_HEADER .. "sword\t100\tsharp\nshield\t050\t"
local TSV_CANON = TSV_HEADER .. "sword\t100\tsharp\nshield\t50\t"

describe("manifest_loader / reformatter - reversible gzip (.tsv.gz)", function()
    local temp_dir = ""
    local log_messages = {}
    local badVal = error_reporting.badValGen()

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "no system temp dir")
        local td = path_join(system_temp, "gztest_" .. tostring(os.time())
            .. "_" .. tostring(math.random(1000000)))
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

    -- Builds a package: CustomTypes.tsv defines the Item record type (loadOrder 1),
    -- and data.tsv.gz (loadOrder 2) is the gzip of `tsv_text`.
    local function makePkg(tsv_text)
        local pkg_dir = path_join(temp_dir, "GzPkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME),
            makeManifest("GzPkg")))

        local files_content = FILES_HEADER
            .. "CustomTypes.tsv\tcustom_type_def\t\ttrue\t1\tCustom types\n"
            .. "data.tsv.gz\tItem\t\tfalse\t2\tItems as gzipped TSV\n"
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), files_content))

        assert(file_util.writeFile(path_join(pkg_dir, "CustomTypes.tsv"),
            "name:name\tparent:type_spec|nil\n" ..
            "Item\t{name:identifier,price:integer,tag:string|nil}\n"))

        local gz = compression.compress("gzip", tsv_text)
        assert(gz, "failed to gzip the fixture")
        assert(file_util.writeFileBinary(path_join(pkg_dir, "data.tsv.gz"), gz))
        return pkg_dir
    end

    local function findTsv(result, suffix)
        for path, tsv in pairs(result.tsv_files) do
            if path:sub(-#suffix) == suffix then return tsv, path end
        end
        return nil
    end

    it("collects, gunzips and parses data.tsv.gz as typed Item data", function()
        local pkg_dir = makePkg(TSV_MESSY)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))

        local tsv = findTsv(result, "data.tsv.gz")
        assert.is_not_nil(tsv)
        assert.equals(3, #tsv)                       -- header + 2 rows
        local header = tsv[1]
        assert.equals("sword", tsv[2][header.name.idx].parsed)
        assert.equals(100, tsv[2][header.price.idx].parsed)
        assert.equals("shield", tsv[3][header.name.idx].parsed)
        assert.equals(50, tsv[3][header.price.idx].parsed)
    end)

    it("reformat re-compresses the source — never clobbers it with plaintext", function()
        local pkg_dir = makePkg(TSV_MESSY)
        local gz_path = path_join(pkg_dir, "data.tsv.gz")

        reformatter.processFiles({pkg_dir})

        -- Still a gzip stream (magic 1f 8b), NOT plaintext TSV written over it.
        local on_disk = file_util.readFileBinary(gz_path)
        assert.equals(0x1f, on_disk:byte(1))
        assert.equals(0x8b, on_disk:byte(2))

        -- It gunzips to the CANONICAL TSV (050 -> 50), so a rewrite actually happened.
        local decoded = compression.decompress("gzip", on_disk)
        assert.is_string(decoded)
        assert.not_equals(TSV_MESSY, decoded)
        assert.equals(TSV_CANON, decoded)
    end)

    it("the re-compressed file reloads to the same data", function()
        local pkg_dir = makePkg(TSV_MESSY)
        reformatter.processFiles({pkg_dir})

        -- A fresh load of the rewritten .gz parses cleanly to the same rows.
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        local tsv = findTsv(result, "data.tsv.gz")
        assert.is_not_nil(tsv)
        assert.equals(3, #tsv)
        local header = tsv[1]
        assert.equals("shield", tsv[3][header.name.idx].parsed)
        assert.equals(50, tsv[3][header.price.idx].parsed)
    end)

    it("reformat is idempotent — a second run leaves the bytes unchanged", function()
        local pkg_dir = makePkg(TSV_MESSY)
        local gz_path = path_join(pkg_dir, "data.tsv.gz")

        reformatter.processFiles({pkg_dir})
        local after_first = file_util.readFileBinary(gz_path)

        reformatter.processFiles({pkg_dir})
        local after_second = file_util.readFileBinary(gz_path)

        assert.equals(after_first, after_second)
    end)
end)
