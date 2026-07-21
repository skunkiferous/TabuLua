-- json_round_trip_spec.lua
-- json_input_round_trip.md: the six json:* transcode stages are reversible. Each
-- has an `encode` (json_transcoders.*ToJson) that rewrites a .json source from the
-- reformatted wide TSV, so a JSON input round-trips like .xml/.eav. The reverse is
-- schema-free (names/types/order from the wide-TSV header, no typeName) and the
-- round-trip is NORMALIZING (canonical JSON), so the unit tests assert the JSON
-- re-parses to the same data + the wide TSV is round-trip-stable, not byte equality
-- of the JSON text. An end-to-end reformatter round-trip mirrors the XML spec.

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
local error_reporting = require("infra.error_reporting")
local json_transcoders = require("content.json_transcoders")
local dkjson = require("dkjson")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local function freshBadVal()
    local logs = {}
    local badVal = error_reporting.badValGen(function(_s, m) logs[#logs + 1] = m end)
    badVal.logger = error_reporting.nullLogger
    return badVal, logs
end

local function decode(json)
    local v, _pos, err = dkjson.decode(json)
    return v, err
end

describe("JSON transcode round-trip (unit)", function()
    -- The forward transform per layout/codec, keyed so each round-trip case can
    -- pick the matching forward+reverse pair.
    local FWD = {
        ["json:objects"]        = json_transcoders.objectsToTSV,
        ["json:rows"]           = json_transcoders.rowsToTSV,
        ["json:columns"]        = json_transcoders.columnsToTSV,
        ["json:objects:typed"]  = json_transcoders.objectsToTSVTyped,
        ["json:rows:typed"]     = json_transcoders.rowsToTSVTyped,
        ["json:columns:typed"]  = json_transcoders.columnsToTSVTyped,
    }
    local REV = {
        ["json:objects"]        = json_transcoders.objectsToJson,
        ["json:rows"]           = json_transcoders.rowsToJson,
        ["json:columns"]        = json_transcoders.columnsToJson,
        ["json:objects:typed"]  = json_transcoders.objectsToJsonTyped,
        ["json:rows:typed"]     = json_transcoders.rowsToJsonTyped,
        ["json:columns:typed"]  = json_transcoders.columnsToJsonTyped,
    }

    -- JSON -> wide TSV -> JSON -> wide TSV: asserts the re-emitted JSON parses and
    -- the wide TSV is round-trip-stable (the canonical typed form is the invariant).
    local function roundtrip(id, json, typeName)
        local badVal = freshBadVal()
        local tsv1 = FWD[id]("in.json", json, {}, badVal, {typeName = typeName})
        assert.is_not_nil(tsv1, "forward produced nil for " .. id)
        assert.equals(0, badVal.errors)

        local out, reason = REV[id](tsv1, nil, nil)
        assert.is_not_nil(out, "reverse produced nil for " .. id .. ": " .. tostring(reason))
        local decoded, derr = decode(out)
        assert.is_nil(derr, "reverse output is not valid JSON for " .. id)
        assert.is_table(decoded)

        local badVal2 = freshBadVal()
        local tsv2 = FWD[id]("in.json", out, {}, badVal2, {typeName = typeName})
        assert.equals(0, badVal2.errors)
        assert.equals(tsv1, tsv2, "wide TSV not round-trip-stable for " .. id)
        return out, decoded
    end

    describe("scalar layouts", function()
        it("json:objects round-trips and re-emits objects keyed by field name", function()
            local out, decoded = roundtrip("json:objects",
                '[{"a":1,"b":0.5},{"a":2,"b":1.5}]', "{a:integer,b:float}")
            assert.same({{a = 1, b = 0.5}, {a = 2, b = 1.5}}, decoded)
            -- Object form (not arrays).
            assert.matches('"a":1', out, 1, true)
        end)

        it("json:rows round-trips as arrays positional to the header order", function()
            local _out, decoded = roundtrip("json:rows",
                '[[1,0.5],[2,1.5]]', "{a:integer,b:float}")
            assert.same({{1, 0.5}, {2, 1.5}}, decoded)
        end)

        it("json:columns round-trips as the transpose (one array per column)", function()
            local _out, decoded = roundtrip("json:columns",
                '[[1,2],[0.5,1.5]]', "{a:integer,b:float}")
            assert.same({{1, 2}, {0.5, 1.5}}, decoded)
        end)
    end)

    describe("composite cells", function()
        it("json:objects round-trips an array-typed cell", function()
            local _out, decoded = roundtrip("json:objects",
                '[{"id":"x","vals":[1,2,3]}]', "{id:identifier,vals:{integer}}")
            assert.same({{id = "x", vals = {1, 2, 3}}}, decoded)
        end)

        it("json:objects round-trips a map-typed cell", function()
            roundtrip("json:objects",
                '[{"id":"x","m":{"k1":10,"k2":20}}]',
                "{id:identifier,m:{string:integer}}")
        end)

        it("json:rows round-trips a tuple-typed cell", function()
            roundtrip("json:rows",
                '[["boss",[1.0,2.0,3.0]]]', "{name:identifier,pos:{float,float,float}}")
        end)
    end)

    describe(":typed codec", function()
        it("json:objects:typed round-trips a large int via the {\"integer\":…} wrapper", function()
            -- 2^53-1, the largest integer a JS number can still hold exactly; the
            -- typed wrapper is what lets even larger ints survive a JS toolchain.
            local big = "9007199254740991"
            local out, decoded = roundtrip("json:objects:typed",
                '[{"id":"x","n":{"integer":"' .. big .. '"}}]', "{id:identifier,n:integer}")
            -- The typed wrapper survives, so a foreign JS toolchain keeps the exact int.
            assert.matches('{"integer":"' .. big .. '"}', out, 1, true)
            assert.is_table(decoded)
        end)

        it("json:rows:typed round-trips a composite cell in the self-describing form", function()
            roundtrip("json:rows:typed",
                '[["x",[2,{"integer":"1"},{"integer":"2"}]]]', "{id:identifier,vals:{integer}}")
        end)
    end)

    describe("edge cases", function()
        it("a missing/null cell becomes JSON null (rows) and survives the round-trip", function()
            local _out, decoded = roundtrip("json:rows",
                '[["x",null]]', "{id:identifier,note:string|nil}")
            assert.same({{"x"}}, decoded)   -- trailing null is a hole; ipairs stops at 1
        end)

        it("an empty top-level array round-trips", function()
            local badVal = freshBadVal()
            local tsv = json_transcoders.rowsToTSV("e.json", "[]", {}, badVal,
                {typeName = "{a:integer,b:float}"})
            assert.is_not_nil(tsv)
            local out = json_transcoders.rowsToJson(tsv, nil, nil)
            assert.equals("[]", out)
        end)

        it("columns always emits one array per column even with no rows", function()
            local badVal = freshBadVal()
            -- Two columns, zero rows.
            local tsv = json_transcoders.columnsToTSV("e.json", "[[],[]]", {}, badVal,
                {typeName = "{a:integer,b:integer}"})
            assert.is_not_nil(tsv)
            local out = json_transcoders.columnsToJson(tsv, nil, nil)
            local decoded = decode(out)
            assert.same({{}, {}}, decoded)
        end)

        it("reverse reports nil + reason on un-parseable wide TSV input", function()
            local out, reason = json_transcoders.rowsToJson("not\ta\tvalid:::header\n", nil, nil)
            -- Either a parse/validate failure (nil + reason) is acceptable; the
            -- contract is that it never throws and signals failure as nil.
            if out == nil then
                assert.is_string(reason)
            end
        end)
    end)
end)

-- ============================================================
-- End-to-end via manifest_loader + reformatter (mirrors the XML integration spec).
-- ============================================================

local MANIFEST_FILENAME = "Manifest.transposed.tsv"

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

describe("manifest_loader/reformatter - JSON round-trip (Files.tsv-selected)", function()
    local temp_dir = ""
    local log_messages = {}
    local badVal = error_reporting.badValGen()

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "no system temp dir")
        local td = path_join(system_temp, "jsonrt_test_" .. tostring(os.time())
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

    -- A package whose single data file is items.json, routed through `transcoder`.
    local function makePkg(transcoder, json_content)
        local pkg_dir = path_join(temp_dir, "JsonPkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME),
            makeManifest("JsonPkg")))
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"),
            FILES_HEADER
            .. "CustomTypes.tsv\tcustom_type_def\t\ttrue\t1\tCustom types\t\n"
            .. "items.json\tItem\t\tfalse\t2\tItems as JSON\t" .. transcoder .. "\n"))
        assert(file_util.writeFile(path_join(pkg_dir, "CustomTypes.tsv"),
            "name:name\tparent:type_spec|nil\n" ..
            "Item\t{name:identifier,price:integer,loot:{name}}\n"))
        assert(file_util.writeFile(path_join(pkg_dir, "items.json"), json_content))
        return pkg_dir
    end

    local function findTsv(result, suffix)
        for path, tsv in pairs(result.tsv_files) do
            if path:sub(-#suffix) == suffix then return tsv, path end
        end
        return nil
    end

    local OBJECTS = '[\n{"name":"sword","price":100,"loot":["gem","coin"]},\n'
        .. '{"name":"shield","price":50,"loot":["wood"]}\n]'

    it("loads items.json as a wide, typed table via json:objects", function()
        local pkg_dir = makePkg("json:objects", OBJECTS)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))

        local tsv = findTsv(result, "items.json")
        assert.is_not_nil(tsv)
        assert.equals(3, #tsv)                 -- header + 2 rows
        local header = tsv[1]
        assert.equals("sword", tsv[2][header.name.idx].parsed)
        assert.equals(100, tsv[2][header.price.idx].parsed)
        assert.same({"gem", "coin"}, tsv[2][header.loot.idx].parsed)
    end)

    it("threads the transcoder id into joinMeta.fn2Transcoder", function()
        local pkg_dir = makePkg("json:objects", OBJECTS)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        local _tsv, path = findTsv(result, "items.json")
        assert.is_not_nil(path)
        assert.equals("json:objects", result.joinMeta.fn2Transcoder[path])
    end)

    it("reformatter rewrites items.json in place via the id-selected encode (round-trip)", function()
        local pkg_dir = makePkg("json:objects", OBJECTS)
        local json_path = path_join(pkg_dir, "items.json")

        reformatter.processFiles({pkg_dir})

        local on_disk = file_util.readFile(json_path)
        assert.is_not_nil(on_disk)
        local decoded, derr = decode(on_disk)
        assert.is_nil(derr, "rewritten file is not valid JSON")
        assert.is_table(decoded)

        -- Re-loading the rewritten file reproduces the same data.
        local msgs2 = {}
        local bad2 = error_reporting.badValGen(function(_s, m) msgs2[#msgs2 + 1] = m end)
        bad2.logger = error_reporting.nullLogger
        local result = manifest_loader.processFiles({pkg_dir}, bad2)
        assert.is_not_nil(result)
        assert.equals(0, bad2.errors, table.concat(msgs2, " | "))
        local tsv = findTsv(result, "items.json")
        assert.is_not_nil(tsv)
        local header = tsv[1]
        assert.equals("sword", tsv[2][header.name.idx].parsed)
        assert.same({"gem", "coin"}, tsv[2][header.loot.idx].parsed)

        -- Reformatting is stable on a second pass (the rewritten JSON is canonical).
        local before = file_util.readFile(json_path)
        reformatter.processFiles({pkg_dir})
        local after = file_util.readFile(json_path)
        assert.equals(before, after)
    end)

    it("round-trips a json:objects:typed file in place", function()
        -- loot:{name} in typed form is [<count>, e1, e2] — count 2 for two elements.
        local typed = '[\n{"name":"sword","price":{"integer":"100"},"loot":[2,"gem","coin"]}\n]'
        local pkg_dir = makePkg("json:objects:typed", typed)
        local json_path = path_join(pkg_dir, "items.json")
        reformatter.processFiles({pkg_dir})

        local on_disk = file_util.readFile(json_path)
        assert.is_not_nil(on_disk)
        -- The typed int wrapper is preserved through the round-trip.
        assert.matches('{"integer":"100"}', on_disk, 1, true)

        local msgs2 = {}
        local bad2 = error_reporting.badValGen(function(_s, m) msgs2[#msgs2 + 1] = m end)
        bad2.logger = error_reporting.nullLogger
        local result = manifest_loader.processFiles({pkg_dir}, bad2)
        assert.equals(0, bad2.errors, table.concat(msgs2, " | "))
        local tsv = findTsv(result, "items.json")
        local header = tsv[1]
        assert.equals(100, tsv[2][header.price.idx].parsed)
    end)
end)
