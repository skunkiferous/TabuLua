-- shaped_types_round_trip_spec.lua
-- Phase 3 of string_shaped_types.md: prove the claim that a map keyed by a shaped
-- string type survives EVERY export format, and back, precisely because the key is
-- only ever a string to the serializers. Two layers:
--   (1) value-level: each table serializer emits the shaped key as a string key, and
--       its matching deserializer reads it back (native / typed JSON / natural JSON /
--       XML; SQL embeds one of them);
--   (2) full native pipeline: a {Coord:string} column loaded via manifest_loader,
--       reformatted in place (canonicalizing), and reloaded to the same data.

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
local parsers = require("parsers")
local ser = require("serde.serialization")
local deser = require("serde.deserialization")
local unwrap = require("util.read_only").unwrap

-- The type of the first key of a map. The loaded model wraps a parsed cell in a
-- read-only proxy, whose keys are reachable by index but NOT by next()/pairs(), so we
-- unwrap before iterating. A plainly-built table (the deserializers') unwraps to itself.
local function firstKeyType(m)
    return type(next(unwrap(m)))
end

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local function freshBadVal()
    local logs = {}
    local badVal = error_reporting.badValGen(function(_s, m) logs[#logs + 1] = m end)
    badVal.source_name = "test"
    badVal.line_no = 1
    badVal.logger = error_reporting.nullLogger
    return badVal, logs
end

-- ============================================================
-- Layer 1: value-level serializer/deserializer coverage.
-- ============================================================

describe("shaped-key map survives every serializer", function()
    -- What a {Coord:string} cell parses to: string keys, in the shape's canonical form.
    local function shapedKeyMap()
        return {["1,2"] = "spawn", ["3,4"] = "chest"}
    end

    it("native cell (serializeTable -> deserialize)", function()
        local s = ser.serializeTable(shapedKeyMap())
        -- Emitted with the key quoted as a string, which is what makes ltcn read it
        -- back (Key = Number + String + Boolean; a bare table key it would reject).
        assert.matches('["1,2"]="spawn"', s, 1, true)
        local back = deser.deserialize(s)
        assert.equals("spawn", back["1,2"])
        assert.equals("chest", back["3,4"])
        assert.equals("string", firstKeyType(back))
    end)

    it("typed JSON (serializeTableJSON -> deserializeJSON)", function()
        local s = ser.serializeTableJSON(shapedKeyMap())
        local back = deser.deserializeJSON(s)
        assert.equals("spawn", back["1,2"])
        assert.equals("chest", back["3,4"])
        assert.equals("string", firstKeyType(back))
    end)

    it("natural JSON (serializeTableNaturalJSON -> deserializeNaturalJSON)", function()
        local s = ser.serializeTableNaturalJSON(shapedKeyMap())
        -- A plain JSON object keyed by the canonical string.
        assert.matches('"1,2":"spawn"', s, 1, true)
        local back = deser.deserializeNaturalJSON(s)
        assert.equals("spawn", back["1,2"])
        assert.equals("chest", back["3,4"])
        assert.equals("string", firstKeyType(back))
    end)

    it("XML (serializeTableXML -> deserializeXML)", function()
        local s = ser.serializeTableXML(shapedKeyMap())
        local back = deser.deserializeXML(s)
        assert.equals("spawn", back["1,2"])
        assert.equals("chest", back["3,4"])
        assert.equals("string", firstKeyType(back))
    end)

    it("SQL embeds the map as a string-keyed JSON literal", function()
        local s = ser.serializeSQL(shapedKeyMap())
        -- serializeSQL encodes a table cell through serializeTableJSON, then quotes it.
        assert.matches('"1,2","spawn"', s, 1, true)
        assert.equals("'", s:sub(1, 1))
    end)

    -- The one place the mainline is safe but the general case is not: natural JSON has
    -- no key type, so it coerces a numeric-looking object key back to a number. A Coord
    -- key ("1,2") is never numeric-looking, so it survives -- but this documents WHY a
    -- shaped key must not be a single-scalar shape whose canonical form is a bare
    -- number, and why TabuLua's own type-directed reimport (which DOES know the key is
    -- a Coord) is what keeps even that exact.
    it("natural JSON keeps a comma-bearing shaped key a string (not coerced)", function()
        local back = deser.deserializeNaturalJSON('{"1,2":"a"}')
        assert.equals("string", firstKeyType(back))
        -- Whereas a bare-number key would coerce -- the known natural-JSON limitation,
        -- not a shaped-types one.
        local coerced = deser.deserializeNaturalJSON('{"5":"a"}')
        assert.equals("number", firstKeyType(coerced))
    end)
end)

-- ============================================================
-- Layer 2: full native pipeline (manifest_loader + reformatter).
-- ============================================================

local FILES_HEADER = "fileName:filepath\ttypeName:type_spec\tsuperType:super_type\t"
    .. "baseType:boolean\tloadOrder:number\tdescription:text\ttranscoder:string|nil\n"

describe("shaped-key map round-trips through the native pipeline", function()
    local temp_dir = ""

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "no system temp dir")
        temp_dir = path_join(system_temp, "shrt_" .. tostring(os.time())
            .. "_" .. tostring(math.random(1000000)))
        assert(lfs.mkdir(temp_dir))
    end)

    after_each(function()
        if temp_dir ~= "" then
            file_util.deleteTempDir(temp_dir)
            temp_dir = ""
        end
    end)

    -- A package with a Coord shaped type and a Zone whose `cells` is {Coord:string}.
    -- The source deliberately writes a NON-canonical key ("1, 2" with a space) to prove
    -- the reformatter rewrites it to the canonical "1,2".
    local function makePkg(zonesCell)
        local pkg = path_join(temp_dir, "Pkg")
        assert(lfs.mkdir(pkg))
        assert(file_util.writeFile(path_join(pkg, "Manifest.transposed.tsv"),
            table.concat({
                "package_id:package_id\tPkg",
                "name:string\tPkg",
                "version:version\t0.1.0",
                "description:markdown\tt",
            }, "\n") .. "\n"))
        assert(file_util.writeFile(path_join(pkg, "files.tsv"), FILES_HEADER
            .. "CustomTypes.tsv\tcustom_type_def\t\ttrue\t1\tt\t\n"
            .. "zones.tsv\tZone\t\tfalse\t2\tt\t\n"))
        assert(file_util.writeFile(path_join(pkg, "CustomTypes.tsv"),
            "name:name\tparent:type_spec|nil\tshape:type_spec|nil\n"
            .. "Coord\tstring\t{integer,integer}\n"
            .. "Zone\t{name:identifier,cells:{Coord:string}}\t\n"))
        assert(file_util.writeFile(path_join(pkg, "zones.tsv"),
            "name:identifier\tcells:{Coord:string}\n"
            .. "home\t" .. zonesCell .. "\n"))
        return pkg
    end

    local function findTsv(result, suffix)
        for p, t in pairs(result.tsv_files) do
            if p:sub(-#suffix) == suffix then return t end
        end
    end

    local function loadCells(pkg)
        local badVal, logs = freshBadVal()
        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(logs, " | "))
        local tsv = findTsv(result, "zones.tsv")
        assert.is_not_nil(tsv)
        return tsv[2][tsv[1].cells.idx].parsed
    end

    it("loads a shaped-key map to string keys", function()
        local cells = loadCells(makePkg('["1,2"]="spawn",["3,4"]="chest"'))
        assert.equals("spawn", cells["1,2"])
        assert.equals("chest", cells["3,4"])
        assert.equals("string", firstKeyType(cells))
    end)

    it("canonicalizes a non-canonical key in the reformatted file", function()
        local pkg = makePkg('["1, 2"]="spawn",["3,4"]="chest"')  -- note the space
        loadCells(pkg)  -- asserts a clean initial load

        reformatter.processFiles({pkg})
        local on_disk = file_util.readFile(path_join(pkg, "zones.tsv"))
        assert.is_not_nil(on_disk)
        -- The space is gone: the stored value is the shape's own canonical text.
        assert.matches('["1,2"]="spawn"', on_disk, 1, true)
        assert.is_nil(on_disk:find('["1, 2"]', 1, true))
    end)

    it("reloads the reformatted file to identical data, and is stable", function()
        local pkg = makePkg('["1, 2"]="spawn",["3,4"]="chest"')
        loadCells(pkg)

        reformatter.processFiles({pkg})
        -- Re-registering the same Coord type on reload must be a no-op, not an error.
        local cells = loadCells(pkg)
        assert.equals("spawn", cells["1,2"])
        assert.equals("chest", cells["3,4"])

        -- A second reformat pass changes nothing (the file is already canonical).
        local before = file_util.readFile(path_join(pkg, "zones.tsv"))
        reformatter.processFiles({pkg})
        local after = file_util.readFile(path_join(pkg, "zones.tsv"))
        assert.equals(before, after)
    end)

    it("rejects a cell that is not a valid Coord", function()
        local badVal, logs = freshBadVal()
        local pkg = makePkg('["1,x"]="spawn"')  -- "1,x" is not a {integer,integer}
        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        assert.is_true(badVal.errors > 0)
        assert.matches("does not match shape", table.concat(logs, " | "), 1, true)
    end)
end)

-- ============================================================
-- Idempotent re-registration (what the reload in Layer 2 relies on).
-- ============================================================

describe("shaped type re-registration", function()
    it("is a no-op when the definition is identical", function()
        local b1 = freshBadVal()
        assert.is_true(parsers.registerTypesFromSpec(b1,
            {{name = "IdemCoord", parent = "string", shape = "{integer,integer}"}}))
        local b2 = freshBadVal()
        assert.is_true(parsers.registerTypesFromSpec(b2,
            {{name = "IdemCoord", parent = "string", shape = "{integer,integer}"}}))
        assert.equals(0, b2.errors)
    end)

    it("errors when the same name is redefined with a different shape", function()
        local b1 = freshBadVal()
        assert.is_true(parsers.registerTypesFromSpec(b1,
            {{name = "IdemCoord2", parent = "string", shape = "{integer,integer}"}}))
        local b2, logs = freshBadVal()
        assert.is_false(parsers.registerTypesFromSpec(b2,
            {{name = "IdemCoord2", parent = "string", shape = "{integer,integer,integer}"}}))
        assert.matches("already registered with a different definition",
            table.concat(logs, " | "), 1, true)
    end)
end)
