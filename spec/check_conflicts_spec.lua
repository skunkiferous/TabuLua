-- check_conflicts_spec.lua
-- Tests for `--check-conflicts`: the conflicts-only lineage report answering
-- "where do my mods fight?". Part A tests Lineage:conflictReport classification
-- directly (what is a fight vs. benign composition); Part B loads multi-package
-- fixtures end-to-end and checks the report, including the package-qualified
-- source names ("ModA:PricePatch.tsv") that keep two mods' same-named override
-- files distinguishable.

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local patch_lineage = require("overrides.patch_lineage")
local file_util = require("infra.file_util")
local manifest_loader = require("loader.manifest_loader")
local error_reporting = require("infra.error_reporting")

-- ============================================================
-- Part A — classification rules on the collector
-- ============================================================
describe("Lineage:conflictReport classification", function()
    it("reports two whole-cell writes from distinct sources as a chain", function()
        local lin = patch_lineage.new()
        lin:cell("item.tsv", "sword", "price", "= 10", "ModA:P.tsv")
        lin:cell("item.tsv", "sword", "price", "= 20", "ModB:P.tsv")
        local r, n = lin:conflictReport()
        assert.are.equal(1, n)
        assert.is_truthy(r:find("sword : price", 1, true), "report:\n" .. r)
        local a, b = r:find("= 10", 1, true), r:find("= 20", 1, true)
        assert.is_truthy(a and b and a < b, "chain must be in apply order")
        assert.is_truthy(r:find("ModA:P.tsv", 1, true))
        assert.is_truthy(r:find("ModB:P.tsv", 1, true))
    end)

    it("does not report one source rewriting its own cell", function()
        local lin = patch_lineage.new()
        lin:cell("item.tsv", "sword", "price", "= 10", "ModA:P.tsv")
        lin:cell("item.tsv", "sword", "price", "= 20", "ModA:P.tsv")
        local r, n = lin:conflictReport()
        assert.are.equal(0, n)
        assert.is_truthy(r:find("no conflicts detected", 1, true))
    end)

    it("does not report composing list deltas from two sources", function()
        local lin = patch_lineage.new()
        lin:cell("item.tsv", "sword", "tags", "append {a}", "ModA:P.tsv")
        lin:cell("item.tsv", "sword", "tags", "append {b}", "ModB:P.tsv")
        lin:cell("item.tsv", "sword", "tags", "remove {a}", "ModC:P.tsv")
        local _, n = lin:conflictReport()
        assert.are.equal(0, n)
    end)

    it("flags a whole write only when it lands after a different source", function()
        -- "= v" then a delta from another mod composes (the delta builds on it).
        local lin = patch_lineage.new()
        lin:cell("item.tsv", "sword", "tags", "= {a}", "ModA:P.tsv")
        lin:cell("item.tsv", "sword", "tags", "append {b}", "ModB:P.tsv")
        local _, n = lin:conflictReport()
        assert.are.equal(0, n)
        -- A delta then "= v" from another mod discards the delta: a fight.
        local lin2 = patch_lineage.new()
        lin2:cell("item.tsv", "sword", "tags", "append {b}", "ModB:P.tsv")
        lin2:cell("item.tsv", "sword", "tags", "= {a}", "ModA:P.tsv")
        local _, n2 = lin2:conflictReport()
        assert.are.equal(1, n2)
        -- replace_whole is a whole write too.
        local lin3 = patch_lineage.new()
        lin3:cell("item.tsv", "sword", "tags", "append {b}", "ModB:P.tsv")
        lin3:cell("item.tsv", "sword", "tags", "replace_whole {a}", "ModA:P.tsv")
        local _, n3 = lin3:conflictReport()
        assert.are.equal(1, n3)
    end)

    it("does not report a mod patching cells of a row another mod added", function()
        local lin = patch_lineage.new()
        lin:row("item.tsv", "axe", "add", "ModA:P.tsv")
        lin:cell("item.tsv", "axe", "price", "= 30", "ModB:P.tsv")
        local _, n = lin:conflictReport()
        assert.are.equal(0, n)
    end)

    it("reports remove-vs-write row tension, subsuming the row's cell slots", function()
        local lin = patch_lineage.new()
        lin:cell("item.tsv", "sword", "price", "= 10", "ModA:P.tsv")
        lin:cell("item.tsv", "sword", "price", "= 20", "ModB:P.tsv")
        lin:row("item.tsv", "sword", "remove", "ModC:P.tsv")
        local r, n = lin:conflictReport()
        -- One row-tension entry, NOT also a separate sword:price cell entry.
        assert.are.equal(1, n)
        assert.is_truthy(r:find("row remove/replace", 1, true), "report:\n" .. r)
        assert.is_truthy(r:find("[remove]", 1, true))
        assert.is_truthy(r:find("price = 10", 1, true))
        assert.is_falsy(r:find("sword : price", 1, true))
    end)

    it("does not report a single source adding and removing its own row", function()
        local lin = patch_lineage.new()
        lin:row("item.tsv", "tmp", "add", "ModA:P.tsv")
        lin:row("item.tsv", "tmp", "remove", "ModA:P.tsv")
        local _, n = lin:conflictReport()
        assert.are.equal(0, n)
    end)

    it("reports multi-source newDefault but not widenTo unions", function()
        local lin = patch_lineage.new()
        lin:schema("item.tsv", "price", "newDefault 50", "ModA:O.tsv")
        lin:schema("item.tsv", "price", "newDefault 60", "ModB:O.tsv")
        lin:schema("item.tsv", "tags", "widenTo {name}|{ascii}", "ModA:O.tsv")
        lin:schema("item.tsv", "tags", "widenTo {name}|{ascii}", "ModB:O.tsv")
        local r, n = lin:conflictReport()
        assert.are.equal(1, n)
        assert.is_truthy(r:find("[schema] price", 1, true), "report:\n" .. r)
        assert.is_truthy(r:find("newDefault 50", 1, true))
        assert.is_truthy(r:find("newDefault 60", 1, true))
        assert.is_falsy(r:find("widenTo", 1, true))
    end)

    it("renders an empty report when nothing was recorded", function()
        local r, n = patch_lineage.new():conflictReport()
        assert.are.equal(0, n)
        assert.is_truthy(r:find("no conflicts detected", 1, true))
    end)
end)

-- ============================================================
-- Part B — end-to-end through manifest_loader
-- ============================================================
local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local FILES_HEADER =
    "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
    .. "\tschemaOverlayOf:filepath|nil\tpatchOf:filepath|nil\tloadOrder:number\tdescription:text\n"

-- Writes one package directory: a manifest for `pkgId`, a files.tsv from the
-- given descriptor rows, and the data files themselves.
local function writePkg(root, dirName, pkgId, descRows, dataFiles)
    local dir = path_join(root, dirName)
    assert(lfs.mkdir(dir))
    local manifest = "package_id:package_id\t" .. pkgId .. "\n"
        .. "name:string\t" .. pkgId .. " Package\n"
        .. "version:version\t0.1.0\n"
        .. "description:markdown\tConflict report test\n"
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

describe("--check-conflicts end-to-end", function()
    local temp_dir, badVal

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(),
            "conflicts_" .. os.time() .. "_" .. math.random(1, 1e6))
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

    it("reports two mods updating one cell, with package-qualified sources", function()
        -- Both mods deliberately name their patch file the same way — the
        -- package qualifier is what keeps the chain readable.
        local core = writePkg(temp_dir, "core", "Core",
            {"Item.tsv\tItem\t\t\t\t1\tItems\n"}, {["Item.tsv"] = ITEM})
        local patchA = "name:name\tpatchOp:patch_op\tprice:uint|nil\n"
            .. "sword\tupdate\t110\n"
        local patchB = "name:name\tpatchOp:patch_op\tprice:uint|nil\n"
            .. "sword\tupdate\t120\n"
        local moda = writePkg(temp_dir, "moda", "ModA",
            {"PricePatch.tsv\tpatch\t\t\tItem.tsv\t10\tPatch\n"},
            {["PricePatch.tsv"] = patchA})
        local modb = writePkg(temp_dir, "modb", "ModB",
            {"PricePatch.tsv\tpatch\t\t\tItem.tsv\t10\tPatch\n"},
            {["PricePatch.tsv"] = patchB})
        local result = manifest_loader.processFiles({core, moda, modb}, badVal, nil, nil, true)
        assert.is_not_nil(result)
        assert.is_not_nil(result.lineage)
        local r, n = result.lineage:conflictReport()
        assert.are.equal(1, n, "report:\n" .. r)
        assert.is_truthy(r:find("sword : price", 1, true), "report:\n" .. r)
        local a = r:find("= 110   <- ModA:PricePatch.tsv", 1, true)
        local b = r:find("= 120   <- ModB:PricePatch.tsv", 1, true)
        assert.is_truthy(a, "report:\n" .. r)
        assert.is_truthy(b, "report:\n" .. r)
        assert.is_truthy(a < b, "chain must follow apply (load) order")
    end)

    it("does not report two overlays widening the same column (union)", function()
        local core = writePkg(temp_dir, "core", "Core",
            {"Item.tsv\tItem\t\t\t\t1\tItems\n"}, {["Item.tsv"] = ITEM})
        local policy = "column:name\twidenTo:type_spec|nil\n"
            .. "price\tuint|int\n"
        local moda = writePkg(temp_dir, "moda", "ModA",
            {"PricePolicy.tsv\tSchemaOverlay\t\tItem.tsv\t\t10\tPolicy\n"},
            {["PricePolicy.tsv"] = policy})
        local modb = writePkg(temp_dir, "modb", "ModB",
            {"PricePolicy.tsv\tSchemaOverlay\t\tItem.tsv\t\t10\tPolicy\n"},
            {["PricePolicy.tsv"] = policy})
        local result = manifest_loader.processFiles({core, moda, modb}, badVal, nil, nil, true)
        assert.is_not_nil(result)
        local r, n = result.lineage:conflictReport()
        assert.are.equal(0, n, "report:\n" .. r)
        assert.is_truthy(r:find("no conflicts detected", 1, true))
    end)

    it("reports two overlays setting the same column default (last wins)", function()
        -- Item file with an empty price cell so the merged default applies.
        local item = "name:name\tprice:uint\ttags:{name}|nil\n"
            .. "sword\t100\t\"melee\"\n"
            .. "apple\t\t\n"
        local core = writePkg(temp_dir, "core", "Core",
            {"Item.tsv\tItem\t\t\t\t1\tItems\n"}, {["Item.tsv"] = item})
        local function policy(v)
            return "column:name\tnewDefault:ascii|nil\n" .. "price\t" .. v .. "\n"
        end
        local moda = writePkg(temp_dir, "moda", "ModA",
            {"PricePolicy.tsv\tSchemaOverlay\t\tItem.tsv\t\t10\tPolicy\n"},
            {["PricePolicy.tsv"] = policy("50")})
        local modb = writePkg(temp_dir, "modb", "ModB",
            {"PricePolicy.tsv\tSchemaOverlay\t\tItem.tsv\t\t10\tPolicy\n"},
            {["PricePolicy.tsv"] = policy("60")})
        local result = manifest_loader.processFiles({core, moda, modb}, badVal, nil, nil, true)
        assert.is_not_nil(result)
        local r, n = result.lineage:conflictReport()
        assert.are.equal(1, n, "report:\n" .. r)
        assert.is_truthy(r:find("[schema] price", 1, true), "report:\n" .. r)
        local a = r:find("newDefault 50   <- ModA:PricePolicy.tsv", 1, true)
        local b = r:find("newDefault 60   <- ModB:PricePolicy.tsv", 1, true)
        assert.is_truthy(a, "report:\n" .. r)
        assert.is_truthy(b, "report:\n" .. r)
        assert.is_truthy(a < b, "losing default must precede the winner")
    end)

    it("reports one mod removing a row another mod patched", function()
        local core = writePkg(temp_dir, "core", "Core",
            {"Item.tsv\tItem\t\t\t\t1\tItems\n"}, {["Item.tsv"] = ITEM})
        local patchA = "name:name\tpatchOp:patch_op\tprice:uint|nil\n"
            .. "sword\tupdate\t110\n"
        local patchB = "name:name\tpatchOp:patch_op\n"
            .. "sword\tremove\n"
        local moda = writePkg(temp_dir, "moda", "ModA",
            {"PricePatch.tsv\tpatch\t\t\tItem.tsv\t10\tPatch\n"},
            {["PricePatch.tsv"] = patchA})
        local modb = writePkg(temp_dir, "modb", "ModB",
            {"RemovePatch.tsv\tpatch\t\t\tItem.tsv\t10\tPatch\n"},
            {["RemovePatch.tsv"] = patchB})
        local result = manifest_loader.processFiles({core, moda, modb}, badVal, nil, nil, true)
        assert.is_not_nil(result)
        local r, n = result.lineage:conflictReport()
        assert.are.equal(1, n, "report:\n" .. r)
        assert.is_truthy(r:find("row remove/replace", 1, true), "report:\n" .. r)
        assert.is_truthy(r:find("price = 110   <- ModA:PricePatch.tsv", 1, true), "report:\n" .. r)
        assert.is_truthy(r:find("[remove]   <- ModB:RemovePatch.tsv", 1, true), "report:\n" .. r)
    end)

    it("renders an empty report when there is no override work", function()
        local core = writePkg(temp_dir, "core", "Core",
            {"Item.tsv\tItem\t\t\t\t1\tItems\n"}, {["Item.tsv"] = ITEM})
        local result = manifest_loader.processFiles({core}, badVal, nil, nil, true)
        assert.is_not_nil(result)
        assert.is_not_nil(result.lineage, "tracking on -> lineage present even with no work")
        local r, n = result.lineage:conflictReport()
        assert.are.equal(0, n)
        assert.is_truthy(r:find("no conflicts detected", 1, true))
        assert.are.equal(0, badVal.errors)
    end)
end)
