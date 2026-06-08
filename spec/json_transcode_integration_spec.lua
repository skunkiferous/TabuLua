-- json_transcode_integration_spec.lua
-- End-to-end: a .json data file is routed through the json:objects transcoder
-- (selected by the Files.tsv `transcoder` column) and parsed as data of its
-- typeName, whose schema supplies the column types.

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

-- Files.tsv header WITH the content-pipeline `transcoder` column.
local FILES_HEADER = table.concat({
    "fileName:filepath", "typeName:type_spec", "superType:super_type",
    "baseType:boolean", "loadOrder:number", "description:text",
    "transcoder:string|nil",
}, "\t") .. "\n"

local function makeManifest(pkg_id)
    return table.concat({
        "package_id:package_id\t" .. pkg_id,
        "name:string\t" .. pkg_id .. " Package",
        "version:version\t0.1.0",
        "description:markdown\tTest package",
    }, "\n") .. "\n"
end

describe("manifest_loader - JSON transcode (Files.tsv-selected)", function()
    local temp_dir = ""
    local log_messages = {}
    local badVal = error_reporting.badValGen()

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "no system temp dir")
        local td = path_join(system_temp, "jsontx_test_" .. tostring(os.time())
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

    -- Builds a package: a custom_type_def file defining the `Item` record type
    -- (loadOrder 1, so it registers before the JSON file), and items.json routed
    -- through json:objects (loadOrder 2).
    local function makePkg(items_json)
        local pkg_dir = path_join(temp_dir, "JsonPkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME),
            makeManifest("JsonPkg")))

        local files_content = FILES_HEADER
            .. "CustomTypes.tsv\tcustom_type_def\t\ttrue\t1\tCustom types\t\n"
            .. "items.json\tItem\t\tfalse\t2\tItems as JSON\tjson:objects\n"
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), files_content))

        assert(file_util.writeFile(path_join(pkg_dir, "CustomTypes.tsv"),
            "name:name\tparent:type_spec|nil\n" ..
            "Item\t{name:identifier,price:integer,tag:string|nil}\n"))

        assert(file_util.writeFile(path_join(pkg_dir, "items.json"), items_json))
        return pkg_dir
    end

    -- Finds the parsed tsv_files entry whose source path ends with `suffix`.
    local function findTsv(result, suffix)
        for path, tsv in pairs(result.tsv_files) do
            if path:sub(-#suffix) == suffix then return tsv, path end
        end
        return nil
    end

    it("loads items.json as typed Item data", function()
        local pkg_dir = makePkg(
            '[{"name":"sword","price":100,"tag":"sharp"},{"name":"shield","price":50}]')
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))

        local tsv = findTsv(result, "items.json")
        assert.is_not_nil(tsv)
        -- header + 2 data rows
        assert.equals(3, #tsv)
        -- Column values parsed per the schema types.
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

    it("keeps items.json in raw_files (derived TSV) but never rewrites the .json source", function()
        local original = '[{"name":"axe","price":7}]'
        local pkg_dir = makePkg(original)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))

        -- The on-disk source is untouched by loading.
        local on_disk = file_util.readFile(path_join(pkg_dir, "items.json"))
        assert.equals(original, on_disk)
    end)

    it("the reformatter rewrites the .json source to canonical JSON (round-trip)", function()
        -- json:objects is now reversible (json_input_round_trip.md), so the
        -- reformatter rewrites items.json from the reformatted wide TSV via the
        -- id-selected encode, the way it round-trips .xml/.eav. The round-trip is
        -- normalizing (canonical JSON), so we assert it re-parses to the same data
        -- and is stable on a second pass — not byte equality with the input.
        local original = '[{"name":"axe","price":7}]'
        local pkg_dir = makePkg(original)
        local json_path = path_join(pkg_dir, "items.json")

        reformatter.processFiles({pkg_dir})
        local on_disk = file_util.readFile(json_path)
        assert.is_not_nil(on_disk)
        local decoded = require("dkjson").decode(on_disk)
        assert.same({{name = "axe", price = 7}}, decoded)

        -- Re-loading the rewritten file reproduces the same typed data.
        local msgs2 = {}
        local bad2 = error_reporting.badValGen(function(_s, m) msgs2[#msgs2 + 1] = m end)
        bad2.logger = error_reporting.nullLogger
        local result = manifest_loader.processFiles({pkg_dir}, bad2)
        assert.equals(0, bad2.errors, table.concat(msgs2, " | "))
        local tsv = findTsv(result, "items.json")
        local header = tsv[1]
        assert.equals("axe", tsv[2][header.name.idx].parsed)
        assert.equals(7, tsv[2][header.price.idx].parsed)

        -- Canonical form is stable on a second reformat pass.
        local before = file_util.readFile(json_path)
        reformatter.processFiles({pkg_dir})
        assert.equals(before, file_util.readFile(json_path))
    end)

    it("reports a clear error when the JSON is malformed", function()
        local pkg_dir = makePkg('[{"name":"sword", BROKEN}]')
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.is_true(badVal.errors > 0)
        local joined = table.concat(log_messages, " | ")
        assert.matches("json transcoder", joined)
    end)
end)
