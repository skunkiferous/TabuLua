-- json_complex_values_spec.lua
-- Phase 1 of json_complex_values.md: the json-natural transcoders accept
-- composite (table-typed) cell values, and flag non-round-trippable numbers
-- while carrying on (D5). Table-typed map KEYS need no transcoder guard — the
-- type system itself rejects such a type (D4), as the last test documents.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local lfs = require("lfs")
local file_util = require("infra.file_util")
local manifest_loader = require("loader.manifest_loader")
local error_reporting = require("infra.error_reporting")
local json_transcoders = require("content.json_transcoders")
local parsers = require("parsers")
local serializeJSON = require("serde.serialization").serializeJSON

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- Builds a `json:objects:typed` document from a list of rows (field→Lua value),
-- encoding every value in TabuLua's typed JSON form via serializeJSON (so an
-- integer becomes {"int":"…"}, a map becomes [size,[k,v],…], etc.).
local function typedObjectsFile(rows)
    local objs = {}
    for _, row in ipairs(rows) do
        local parts = {}
        for field, value in pairs(row) do
            parts[#parts + 1] = string.format("%q", field) .. ":" .. serializeJSON(value)
        end
        objs[#objs + 1] = "{" .. table.concat(parts, ",") .. "}"
    end
    return "[" .. table.concat(objs, ",") .. "]"
end

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

-- Registered type names persist across tests in one Lua process, so each test
-- registers its `Item` type under a fresh, unique name.
local typeCounter = 0
local function uniqueTypeName()
    typeCounter = typeCounter + 1
    return "ItemT" .. typeCounter
end

describe("JSON transcode - complex values (json-natural)", function()
    local temp_dir = ""
    local log_messages = {}
    local badVal = error_reporting.badValGen()

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "no system temp dir")
        local td = path_join(system_temp, "jsoncx_test_" .. tostring(os.time())
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

    -- Builds a package whose item record type (given as `item_type`) is registered
    -- under a fresh unique name, with items.json routed through `transcoder`.
    local function makePkg(item_type, transcoder, items_json)
        local typeName = uniqueTypeName()
        local pkg_dir = path_join(temp_dir, "JsonPkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME),
            makeManifest("JsonPkg")))

        local files_content = FILES_HEADER
            .. "CustomTypes.tsv\tcustom_type_def\t\ttrue\t1\tCustom types\t\n"
            .. "items.json\t" .. typeName .. "\t\tfalse\t2\tItems as JSON\t"
            .. transcoder .. "\n"
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), files_content))

        assert(file_util.writeFile(path_join(pkg_dir, "CustomTypes.tsv"),
            "name:name\tparent:type_spec|nil\n" ..
            typeName .. "\t" .. item_type .. "\n"))

        assert(file_util.writeFile(path_join(pkg_dir, "items.json"), items_json))
        return pkg_dir
    end

    local function findTsv(result, suffix)
        for path, tsv in pairs(result.tsv_files) do
            if path:sub(-#suffix) == suffix then return tsv, path end
        end
        return nil
    end

    -- Loads the package and returns the parsed value of `field` in the first data
    -- row of items.json, asserting a clean load.
    local function loadField(item_type, transcoder, items_json, field)
        local pkg_dir = makePkg(item_type, transcoder, items_json)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        local tsv = findTsv(result, "items.json")
        assert.is_not_nil(tsv)
        local header = tsv[1]
        return tsv[2][header[field].idx].parsed
    end

    it("an array cell {string} round-trips to a Lua sequence", function()
        local v = loadField("{name:identifier,tags:{string}}", "json:objects",
            '[{"name":"sword","tags":["sharp","metal"]}]', "tags")
        assert.same({"sharp", "metal"}, v)
    end)

    it("a map cell {string:integer} round-trips to a Lua map", function()
        local v = loadField("{name:identifier,stats:{string:integer}}", "json:objects",
            '[{"name":"x","stats":{"atk":5,"def":3}}]', "stats")
        assert.same({atk = 5, def = 3}, v)
    end)

    it("a tuple cell {integer,integer} round-trips (json:rows, positional)", function()
        -- Sorted field order: coord, name -> [[1,2],"a"].
        local v = loadField("{coord:{integer,integer},name:identifier}", "json:rows",
            '[[[1,2],"a"]]', "coord")
        assert.same({1, 2}, v)
    end)

    it("a nested record cell round-trips", function()
        local v = loadField(
            "{name:identifier,origin:{x:integer,y:integer}}", "json:objects",
            '[{"name":"x","origin":{"x":3,"y":4}}]', "origin")
        assert.same({x = 3, y = 4}, v)
    end)

    it("a map cell also works via json:columns", function()
        local v = loadField("{name:identifier,stats:{string:integer}}", "json:columns",
            '[["x"],[{"atk":7}]]', "stats")
        assert.same({atk = 7}, v)
    end)

    it("a simple scalar value still loads unchanged (regression)", function()
        local v = loadField("{name:identifier,price:integer}", "json:objects",
            '[{"name":"x","price":42}]', "price")
        assert.equals(42, v)
    end)

    -- Non-string SCALAR map keys are the real json-typed motivator; natural handles
    -- them too, because JSON forces object keys to strings and processNaturalValue
    -- coerces them back ("1"->1, "true"->true).
    it("an integer-keyed map {integer:string} round-trips (keys coerced back)", function()
        local v = loadField("{id:identifier,m:{integer:string}}", "json:objects",
            '[{"id":"x","m":{"1":"a","2":"b"}}]', "m")
        assert.same({[1] = "a", [2] = "b"}, v)
    end)

    it("a boolean-keyed map {boolean:string} round-trips", function()
        local v = loadField("{id:identifier,m:{boolean:string}}", "json:objects",
            '[{"id":"x","m":{"true":"yes","false":"no"}}]', "m")
        assert.same({[true] = "yes", [false] = "no"}, v)
    end)

    -- D6: type-directed reconstruction rebuilds each map key with the KEY type's
    -- own parser, so a numeric-looking string key is kept as a string for a
    -- string-keyed map (no guessing). This is the case that used to fail.
    it("a numeric-looking string map key round-trips (D6 type-directed keys)", function()
        local v = loadField("{id:identifier,m:{string:string}}", "json:objects",
            '[{"id":"x","m":{"01":"a","1":"b"}}]', "m")
        assert.same({["01"] = "a", ["1"] = "b"}, v)
    end)

    it("sees through a nullable container `{string:string}|nil`", function()
        local v = loadField("{id:identifier,m:{string:string}|nil}", "json:objects",
            '[{"id":"x","m":{"01":"a"}}]', "m")
        assert.same({["01"] = "a"}, v)
    end)

    it("types keys per depth in a nested map (string outer, integer inner)", function()
        -- outer key "a" stays a string; inner key "1" becomes the number 1.
        local v = loadField("{id:identifier,m:{string:{integer:string}}}", "json:objects",
            '[{"id":"x","m":{"a":{"1":"x"}}}]', "m")
        assert.same({a = {[1] = "x"}}, v)
    end)

    it("the type system already rejects a table-typed map key (D4 needs no guard)", function()
        local logs = {}
        local bv = error_reporting.badValGen(function(_s, m) logs[#logs + 1] = m end)
        bv.logger = error_reporting.nullLogger
        -- A map whose KEY is a tuple: the type parser refuses to build it, so such
        -- a column type can never reach the transcoder.
        local parser = parsers.parseType(bv, "{{integer,integer}:string}", "tsv")
        assert.is_nil(parser)
        assert.matches("key_type can never be a table", table.concat(logs, " | "))
    end)

    -- ---- json-typed (`:typed`) — Phase 2 ----

    it("`:typed` loads typed scalars (int wrappers) and composites", function()
        local v = loadField("{name:identifier,price:integer,stats:{string:integer}}",
            "json:objects:typed",
            typedObjectsFile({{name = "sword", price = 100, stats = {atk = 7, def = 3}}}),
            "stats")
        assert.same({atk = 7, def = 3}, v)
    end)

    -- The headline reason for typed: a JSON producer that cannot represent an
    -- int64 as a NUMBER (e.g. JavaScript, capped at 2^53) emits it as a
    -- string-tagged integer {"int":"<digits>"}, which survives any JSON toolchain.
    it("`:typed` carries an int64 exactly via the {\"int\":\"...\"} string wrapper", function()
        local v = loadField("{id:identifier,big:long}", "json:objects:typed",
            '[{"id":"x","big":{"int":"9223372036854775807"}}]', "big")
        assert.equals(9223372036854775807, v)
    end)

    it("`:typed` preserves non-string scalar keys exactly", function()
        local m = {}; m[10] = "a"; m[20] = "b"   -- map<integer,string>, sparse
        local v = loadField("{id:identifier,m:{integer:string}}", "json:objects:typed",
            typedObjectsFile({{id = "x", m = m}}), "m")
        assert.same({[10] = "a", [20] = "b"}, v)
    end)

    -- The one thing `:typed` can do that natural cannot: in an UNTYPED `table`
    -- column there is no key type to guide natural (it would coerce "1" -> 1), but
    -- the self-describing typed encoding keeps the exact string key "1".
    it("`:typed` preserves an exact scalar key in an untyped `table` column", function()
        local v = loadField("{id:identifier,m:table}", "json:objects:typed",
            typedObjectsFile({{id = "x", m = {["1"] = "a"}}}), "m")
        assert.same({["1"] = "a"}, v)
    end)

    it("natural coerces that same key (`table` column gives it no type to honour)", function()
        local v = loadField("{id:identifier,m:table}", "json:objects",
            '[{"id":"x","m":{"1":"a"}}]', "m")
        assert.same({[1] = "a"}, v)   -- coerced to a number key, unlike :typed
    end)
end)

describe("JSON transcode - complex values: non-finite flag-and-continue (D5)", function()
    -- Direct transcoder calls with an inline typeName: no package needed.
    local function freshBadVal()
        local logs = {}
        local badVal = error_reporting.badValGen(function(_s, m) logs[#logs + 1] = m end)
        badVal.logger = error_reporting.nullLogger
        return badVal, logs
    end

    it("flags EVERY non-finite number but still emits TSV", function()
        local badVal, logs = freshBadVal()
        -- 1e999 overflows to inf on decode (NaN/Infinity are not valid JSON tokens).
        local out = json_transcoders.objectsToTSV("t.json",
            '[{"a":1e999,"b":1e999}]', {}, badVal, {typeName = "{a:float,b:float}"})
        assert.is_not_nil(out)                       -- carried on: output produced
        assert.equals(2, badVal.errors)              -- both offending values flagged
        assert.matches("not representable in JSON", table.concat(logs, " | "))
    end)

    it("flags a non-finite number nested inside a composite cell", function()
        local badVal, logs = freshBadVal()
        local out = json_transcoders.objectsToTSV("t.json",
            '[{"id":"x","vals":[1, 1e999, 3]}]', {}, badVal,
            {typeName = "{id:identifier,vals:{float}}"})
        assert.is_not_nil(out)
        assert.equals(1, badVal.errors)
        assert.matches("infinite number", table.concat(logs, " | "))
    end)

    it("leaves a finite composite cell untouched", function()
        local badVal = freshBadVal()
        local out = json_transcoders.objectsToTSV("t.json",
            '[{"id":"x","vals":[1, 2, 3]}]', {}, badVal,
            {typeName = "{id:identifier,vals:{integer}}"})
        assert.is_not_nil(out)
        assert.equals(0, badVal.errors)
    end)
end)
