-- patch_lineage_spec.lua
-- Tests for patch lineage + `--explain-patch` (TODO/mod_overrides.md §4.4, Phase 6b):
-- the optional, off-by-default record of which override touched which cell / row /
-- column. Part A tests the collector module directly; Part B loads a package with
-- tracking on and checks the recorded chain end-to-end.

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local patch_lineage = require("patch_lineage")
local file_util = require("file_util")
local manifest_loader = require("manifest_loader")
local error_reporting = require("error_reporting")

-- ============================================================
-- Part A — the collector module
-- ============================================================
describe("patch_lineage module", function()
    it("renders scalars, lists and maps compactly via valueStr", function()
        assert.are.equal("-5", patch_lineage.valueStr(-5))
        assert.are.equal("hi", patch_lineage.valueStr("hi"))
        assert.are.equal("nil", patch_lineage.valueStr(nil))
        assert.are.equal("{a,b}", patch_lineage.valueStr({"a", "b"}))
        assert.are.equal("{fire=10,ice=5}", patch_lineage.valueStr({ice = 5, fire = 10}))
    end)

    it("starts empty", function()
        local lin = patch_lineage.new()
        assert.is_true(lin:isEmpty())
    end)

    it("records and reports cell / row / schema events grouped by target", function()
        local lin = patch_lineage.new()
        lin:schema("item.tsv", "price", "widenTo gold|int", "ItemPricePolicy.tsv")
        lin:cell("item.tsv", "sword", "price", "= -5", "ItemPatch.tsv")
        lin:row("item.tsv", "oldSword", "remove", "ItemPatch.tsv")
        assert.is_false(lin:isEmpty())
        local r = lin:report()
        assert.is_truthy(r:find("item.tsv", 1, true))
        assert.is_truthy(r:find("[schema] price", 1, true))
        assert.is_truthy(r:find("widenTo gold|int", 1, true))
        assert.is_truthy(r:find("sword", 1, true))
        assert.is_truthy(r:find("price = -5", 1, true))
        assert.is_truthy(r:find("[remove]", 1, true))
        assert.is_truthy(r:find("ItemPatch.tsv", 1, true))
    end)

    it("keeps a multi-writer chain in apply order", function()
        local lin = patch_lineage.new()
        lin:cell("item.tsv", "sword", "price", "= 10", "ModA.tsv")
        lin:cell("item.tsv", "sword", "price", "= 20", "ModB.tsv")
        local r = lin:report()
        assert.is_truthy(r:find("ModA.tsv", 1, true) < r:find("ModB.tsv", 1, true),
            "earlier writer should appear before the later (last-writer-wins) one")
    end)

    it("filters by file, pk and column", function()
        local lin = patch_lineage.new()
        lin:cell("item.tsv", "sword", "price", "= 10", "A.tsv")
        lin:cell("item.tsv", "shield", "weight", "= 3", "A.tsv")
        lin:cell("spell.tsv", "fireball", "mana", "= 5", "B.tsv")

        local byFile = lin:report({file = "item.tsv"})
        assert.is_truthy(byFile:find("sword", 1, true))
        assert.is_falsy(byFile:find("fireball", 1, true))

        local byCell = lin:report({file = "item.tsv", pk = "sword", col = "price"})
        assert.is_truthy(byCell:find("price = 10", 1, true))
        assert.is_falsy(byCell:find("shield", 1, true))

        local none = lin:report({file = "nope.tsv"})
        assert.is_truthy(none:find("no overrides recorded", 1, true))
    end)
end)

-- ============================================================
-- Part B — end-to-end through manifest_loader
-- ============================================================
local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local MANIFEST_FILENAME = "Manifest.transposed.tsv"
local MANIFEST = [[package_id:package_id	Test
name:string	Test Package
version:version	0.1.0
description:markdown	Lineage integration test
]]

local FILES =
    "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
    .. "\tschemaOverlayOf:filepath|nil\tpatchOf:filepath|nil\tloadOrder:number\tdescription:text\n"
    .. "Item.tsv\tItem\t\t\t\t1\tItems\n"
    .. "ItemPolicy.tsv\tSchemaOverlay\t\tItem.tsv\t\t2\tWiden price\n"
    .. "ItemPatch.tsv\tpatch\t\t\tItem.tsv\t3\tRow patch\n"

local ITEM =
    "name:name\tprice:uint\ttags:{name}|nil\n"
    .. "sword\t100\t\"melee\"\n"

-- Overlay widens price uint -> uint|int so the patch can set a negative price.
local POLICY =
    "column:name\twidenTo:type_spec|nil\n"
    .. "price\tuint|int\n"

local PATCH =
    "name:name\tpatchOp:patch_op\tprice:uint|int|nil\tappend_tags:{name}|nil\n"
    .. "sword\tupdate\t-5\t\"discounted\"\n"

describe("--explain-patch end-to-end", function()
    local temp_dir, pkg, badVal

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(),
            "lineage_" .. os.time() .. "_" .. math.random(1, 1e6))
        assert(lfs.mkdir(td))
        temp_dir = td
        pkg = path_join(td, "pkg")
        assert(lfs.mkdir(pkg))
        badVal = error_reporting.badValGen()
        badVal.logger = error_reporting.nullLogger
        assert.is_true(file_util.writeFile(path_join(pkg, MANIFEST_FILENAME), MANIFEST))
        assert.is_true(file_util.writeFile(path_join(pkg, "files.tsv"), FILES))
        assert.is_true(file_util.writeFile(path_join(pkg, "Item.tsv"), ITEM))
        assert.is_true(file_util.writeFile(path_join(pkg, "ItemPolicy.tsv"), POLICY))
        assert.is_true(file_util.writeFile(path_join(pkg, "ItemPatch.tsv"), PATCH))
    end)

    after_each(function()
        if temp_dir then
            local td = temp_dir
            temp_dir = nil
            file_util.deleteTempDir(td)
        end
    end)

    it("records nothing when tracking is off (default)", function()
        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        assert.is_nil(result.lineage)
    end)

    it("records schema widen, the cell update, and the list delta when on", function()
        local result = manifest_loader.processFiles({pkg}, badVal, nil, nil, true)
        assert.is_not_nil(result)
        assert.is_not_nil(result.lineage, "lineage should be present when tracking is on")
        local r = result.lineage:report()
        -- Tier-A0 schema overlay.
        assert.is_truthy(r:find("widenTo uint|int", 1, true), "report:\n" .. r)
        assert.is_truthy(r:find("ItemPolicy.tsv", 1, true))
        -- Tier-A cell update + list delta, attributed to the patch file.
        assert.is_truthy(r:find("price = -5", 1, true), "report:\n" .. r)
        assert.is_truthy(r:find("append {discounted}", 1, true), "report:\n" .. r)
        assert.is_truthy(r:find("ItemPatch.tsv", 1, true))
    end)

    it("supports a cell-level filter", function()
        local result = manifest_loader.processFiles({pkg}, badVal, nil, nil, true)
        local r = result.lineage:report({file = "item.tsv", pk = "sword", col = "price"})
        assert.is_truthy(r:find("price = -5", 1, true))
        -- The tags delta is on a different column, so it is filtered out.
        assert.is_falsy(r:find("append {discounted}", 1, true))
    end)
end)
