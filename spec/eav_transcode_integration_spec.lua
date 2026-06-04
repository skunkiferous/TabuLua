-- eav_transcode_integration_spec.lua
-- End-to-end: an .eav data file is AUTO-routed through the EAV transcoder (by its
-- .eav extension, with NO Files.tsv `transcoder` column) and parsed as data of its
-- typeName, whose schema supplies the column types. Unlike JSON, the source is
-- reversible, so the reformatter rewrites the .eav from the reformatted wide TSV.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local lfs = require("lfs")
local file_util = require("file_util")
local manifest_loader = require("manifest_loader")
local reformatter = require("reformatter")
local error_reporting = require("error_reporting")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local MANIFEST_FILENAME = "Manifest.transposed.tsv"

-- Files.tsv header with NO `transcoder` column: the .eav file auto-matches by
-- extension, so no per-file selection is needed (the whole point of EAV vs JSON).
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

describe("manifest_loader - EAV transcode (extension auto-matched)", function()
    local temp_dir = ""
    local log_messages = {}
    local badVal = error_reporting.badValGen()

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "no system temp dir")
        local td = path_join(system_temp, "eavtx_test_" .. tostring(os.time())
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

    -- A package: a custom_type_def file defining `Item` (loadOrder 1, so it
    -- registers before the .eav file), and Item.eav (loadOrder 2) with no transcoder.
    local function makePkg(items_eav)
        local pkg_dir = path_join(temp_dir, "EavPkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME),
            makeManifest("EavPkg")))

        local files_content = FILES_HEADER
            .. "CustomTypes.tsv\tcustom_type_def\t\ttrue\t1\tCustom types\n"
            .. "Item.eav\tItem\t\tfalse\t2\tItems as EAV\n"
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), files_content))

        assert(file_util.writeFile(path_join(pkg_dir, "CustomTypes.tsv"),
            "name:name\tparent:type_spec|nil\n" ..
            "Item\t{name:identifier,price:integer,tag:string|nil}\n"))

        assert(file_util.writeFile(path_join(pkg_dir, "Item.eav"), items_eav))
        return pkg_dir
    end

    local function findTsv(result, suffix)
        for path, tsv in pairs(result.tsv_files) do
            if path:sub(-#suffix) == suffix then return tsv, path end
        end
        return nil
    end

    -- Canonical EAV: two items, shield is sparse (no tag).
    local CANON = "sword\tname\tsword\nsword\tprice\t100\nsword\ttag\tsharp\n"
        .. "shield\tname\tshield\nshield\tprice\t50\n"

    it("loads Item.eav as typed Item data (no transcoder column)", function()
        local pkg_dir = makePkg(CANON)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))

        local tsv = findTsv(result, "Item.eav")
        assert.is_not_nil(tsv)
        assert.equals(3, #tsv)   -- header + 2 data rows
        local header = tsv[1]
        assert.is_not_nil(header.name)
        assert.is_not_nil(header.price)
        local r1 = tsv[2]
        assert.equals("sword", r1[header.name.idx].parsed)
        assert.equals(100, r1[header.price.idx].parsed)
        local r2 = tsv[3]
        assert.equals("shield", r2[header.name.idx].parsed)
        assert.equals(50, r2[header.price.idx].parsed)
    end)

    it("reports a clear error when the EAV is malformed", function()
        -- A 2-cell row is not a valid triple.
        local pkg_dir = makePkg("sword\tprice\n")
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.is_true(badVal.errors > 0)
        assert.matches("eav transcoder", table.concat(log_messages, " | "))
    end)

    it("reformatter rewrites the .eav source and it reloads to the same data", function()
        -- Use an unsorted / fully-populated EAV; reformatting canonicalises it.
        local pkg_dir = makePkg(CANON)
        reformatter.processFiles({pkg_dir})

        local on_disk = file_util.readFile(path_join(pkg_dir, "Item.eav"))
        assert.is_not_nil(on_disk)
        -- Still header-less triples (no `name:type` header line leaked in).
        assert.is_nil(on_disk:match("name:identifier"))

        -- Reloading the rewritten .eav yields the same typed wide table.
        local badVal2 = error_reporting.badValGen(function() end)
        badVal2.logger = error_reporting.nullLogger
        local result = manifest_loader.processFiles({pkg_dir}, badVal2)
        assert.is_not_nil(result)
        assert.equals(0, badVal2.errors)
        local tsv = findTsv(result, "Item.eav")
        assert.is_not_nil(tsv)
        assert.equals(3, #tsv)
        local header = tsv[1]
        assert.equals("sword", tsv[2][header.name.idx].parsed)
        assert.equals(100, tsv[2][header.price.idx].parsed)
    end)

    it("the rewritten .eav is valid EAV (3-cell rows)", function()
        local pkg_dir = makePkg(CANON)
        reformatter.processFiles({pkg_dir})
        local on_disk = file_util.readFile(path_join(pkg_dir, "Item.eav"))
        local raw_tsv = require("raw_tsv")
        assert.is_true(raw_tsv("isRawTSV", raw_tsv.stringToRawTSV(on_disk)))
        -- Every non-comment row is a 3-cell triple.
        for _, row in ipairs(raw_tsv.stringToRawTSV(on_disk)) do
            if type(row) == "table" then
                assert.equals(3, #row)
            end
        end
    end)
end)
