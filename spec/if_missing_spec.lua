-- if_missing_spec.lua
-- Tests for the `ifMissing:missing_policy|nil` descriptor column
-- (TODO/mod_ecosystem.md §6 / Phase 6): per override FILE, tolerance for
-- targets that are not there — a patched key missing from the target, a
-- replace_oldvalue_ value not found, or the whole target file absent. The
-- default (column absent, or explicit `error`) keeps today's severities;
-- `warn` logs each miss as a no-op; `silent` no-ops quietly. `add` on an
-- existing key stays an error under every policy.

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local file_util = require("infra.file_util")
local manifest_loader = require("loader.manifest_loader")
local error_reporting = require("infra.error_reporting")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local FILES_HEADER =
    "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
    .. "\tschemaOverlayOf:filepath|nil\tpatchOf:filepath|nil"
    .. "\tifMissing:missing_policy|nil\tloadOrder:number\tdescription:text\n"

-- Writes one package directory: a manifest for `pkgId`, a files.tsv from the
-- given descriptor rows, and the data files themselves.
local function writePkg(root, dirName, pkgId, descRows, dataFiles)
    local dir = path_join(root, dirName)
    assert(lfs.mkdir(dir))
    local manifest = "package_id:package_id\t" .. pkgId .. "\n"
        .. "name:string\t" .. pkgId .. " Package\n"
        .. "version:version\t0.1.0\n"
        .. "description:markdown\tifMissing test\n"
    assert.is_true(file_util.writeFile(path_join(dir, "Manifest.transposed.tsv"), manifest))
    assert.is_true(file_util.writeFile(path_join(dir, "files.tsv"),
        FILES_HEADER .. table.concat(descRows, "")))
    for name, content in pairs(dataFiles) do
        assert.is_true(file_util.writeFile(path_join(dir, name), content))
    end
    return dir
end

local ITEM = "name:name\tprice:uint\ttags:{name}|nil\n"
    .. "sword\t100\t\"melee\"\n"

-- A compat patch: updates a key present in every version (sword) AND a key
-- only newer targets have (laserSword, absent from this fixture's Item.tsv).
local COMPAT_PATCH = "name:name\tpatchOp:patch_op\tprice:uint|nil\n"
    .. "sword\tupdate\t110\n"
    .. "laserSword\tupdate\t999\n"

-- Finds the parsed value of column `col` in the row keyed `pk` of dataset `fn`.
local function cellOf(tsv_files, fnSuffix, pk, col)
    for fn, tsv in pairs(tsv_files) do
        if fn:sub(-#fnSuffix) == fnSuffix and type(tsv) == "table" then
            local header = tsv[1]
            for i = 2, #tsv do
                local row = tsv[i]
                if type(row) == "table" and tostring(row[1].parsed) == pk then
                    return row[header[col].idx].parsed
                end
            end
        end
    end
    return nil
end

describe("ifMissing tolerance policy", function()
    local temp_dir, badVal

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(),
            "ifmissing_" .. os.time() .. "_" .. math.random(1, 1e6))
        assert(lfs.mkdir(td))
        temp_dir = td
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

    it("keeps a missing-key update a load error by default", function()
        local core = writePkg(temp_dir, "core", "Core",
            {"Item.tsv\tItem\t\t\t\t\t1\tItems\n"}, {["Item.tsv"] = ITEM})
        local mod = writePkg(temp_dir, "mod", "Mod",
            {"CompatPatch.tsv\tpatch\t\t\tItem.tsv\t\t10\tCompat\n"},
            {["CompatPatch.tsv"] = COMPAT_PATCH})
        manifest_loader.processFiles({core, mod}, badVal)
        assert.is_true(badVal.errors > 0, "missing key must stay an error by default")
    end)

    it("explicit ifMissing=error behaves like the default", function()
        local core = writePkg(temp_dir, "core", "Core",
            {"Item.tsv\tItem\t\t\t\t\t1\tItems\n"}, {["Item.tsv"] = ITEM})
        local mod = writePkg(temp_dir, "mod", "Mod",
            {"CompatPatch.tsv\tpatch\t\t\tItem.tsv\terror\t10\tCompat\n"},
            {["CompatPatch.tsv"] = COMPAT_PATCH})
        manifest_loader.processFiles({core, mod}, badVal)
        assert.is_true(badVal.errors > 0)
    end)

    it("tolerates a missing-key update under warn and silent, applying the rest", function()
        for _, policy in ipairs({"warn", "silent"}) do
            local sub = path_join(temp_dir, policy)
            assert(lfs.mkdir(sub))
            local core = writePkg(sub, "core", "Core",
                {"Item.tsv\tItem\t\t\t\t\t1\tItems\n"}, {["Item.tsv"] = ITEM})
            local mod = writePkg(sub, "mod", "Mod",
                {"CompatPatch.tsv\tpatch\t\t\tItem.tsv\t" .. policy .. "\t10\tCompat\n"},
                {["CompatPatch.tsv"] = COMPAT_PATCH})
            local bv = error_reporting.badValGen()
            bv.logger = error_reporting.nullLogger
            local result = manifest_loader.processFiles({core, mod}, bv)
            assert.is_not_nil(result, policy .. ": load must succeed")
            assert.are.equal(0, bv.errors, policy .. ": no errors expected")
            -- The present key was still patched; the absent one was a no-op.
            assert.are.equal(110, cellOf(result.tsv_files, "Item.tsv", "sword", "price"),
                policy .. ": present key must still be patched")
        end
    end)

    it("tolerates a replace_oldvalue_ value not found under warn", function()
        local patch = "name:name\tpatchOp:patch_op"
            .. "\treplace_oldvalue_tags:name|nil\treplace_newvalue_tags:name|nil\n"
            .. "sword\tupdate\tranged\tsniper\n"
        local core = writePkg(temp_dir, "core", "Core",
            {"Item.tsv\tItem\t\t\t\t\t1\tItems\n"}, {["Item.tsv"] = ITEM})
        local mod = writePkg(temp_dir, "mod", "Mod",
            {"TagPatch.tsv\tpatch\t\t\tItem.tsv\twarn\t10\tCompat\n"},
            {["TagPatch.tsv"] = patch})
        local result = manifest_loader.processFiles({core, mod}, badVal)
        assert.is_not_nil(result)
        assert.are.equal(0, badVal.errors)
        -- 'ranged' was never in the list; the tags cell is unchanged.
        local tags = cellOf(result.tsv_files, "Item.tsv", "sword", "tags")
        assert.are.same({"melee"}, tags)
    end)

    it("skips a patch whose whole target file is absent under warn", function()
        local core = writePkg(temp_dir, "core", "Core",
            {"Item.tsv\tItem\t\t\t\t\t1\tItems\n"}, {["Item.tsv"] = ITEM})
        local patch = "name:name\tpatchOp:patch_op\tprice:uint|nil\n"
            .. "sword\tupdate\t110\n"
        local mod = writePkg(temp_dir, "mod", "Mod",
            {"GhostPatch.tsv\tpatch\t\t\tGhost.tsv\twarn\t10\tCompat\n"},
            {["GhostPatch.tsv"] = patch})
        local result = manifest_loader.processFiles({core, mod}, badVal)
        assert.is_not_nil(result, "absent target file must not fail the load")
        assert.are.equal(0, badVal.errors)
        -- Nothing was patched.
        assert.are.equal(100, cellOf(result.tsv_files, "Item.tsv", "sword", "price"))
    end)

    it("skips a schema overlay whose target file is absent under silent", function()
        local core = writePkg(temp_dir, "core", "Core",
            {"Item.tsv\tItem\t\t\t\t\t1\tItems\n"}, {["Item.tsv"] = ITEM})
        local policy = "column:name\twidenTo:type_spec|nil\n"
            .. "price\tuint|int\n"
        local mod = writePkg(temp_dir, "mod", "Mod",
            {"GhostPolicy.tsv\tSchemaOverlay\t\tGhost.tsv\t\tsilent\t10\tCompat\n"},
            {["GhostPolicy.tsv"] = policy})
        local result = manifest_loader.processFiles({core, mod}, badVal)
        assert.is_not_nil(result, "absent overlay target must not fail the load")
        assert.are.equal(0, badVal.errors)
    end)

    it("keeps add-on-existing-key an error even under silent", function()
        local patch = "name:name\tpatchOp:patch_op\tprice:uint|nil\n"
            .. "sword\tadd\t50\n"
        local core = writePkg(temp_dir, "core", "Core",
            {"Item.tsv\tItem\t\t\t\t\t1\tItems\n"}, {["Item.tsv"] = ITEM})
        local mod = writePkg(temp_dir, "mod", "Mod",
            {"AddPatch.tsv\tpatch\t\t\tItem.tsv\tsilent\t10\tCompat\n"},
            {["AddPatch.tsv"] = patch})
        manifest_loader.processFiles({core, mod}, badVal)
        assert.is_true(badVal.errors > 0,
            "add on an existing key is a collision, not a version gap")
    end)
end)
