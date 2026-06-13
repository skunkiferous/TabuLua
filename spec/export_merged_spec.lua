-- export_merged_spec.lua
-- Tests for `--export-merged` (TODO/mod_overrides.md §7.1, Phase 6a): the
-- reformatter writes a TSV snapshot of every dataset with mod overrides applied
-- to a separate tree, WITHOUT baking those overrides into the parent source.

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local file_util = require("file_util")
local reformatter = require("reformatter")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local MANIFEST_FILENAME = "Manifest.transposed.tsv"
local MANIFEST = [[package_id:package_id	Test
name:string	Test Package
version:version	0.1.0
description:markdown	Export-merged test
]]

local FILES =
    "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
    .. "\tpatchOf:filepath|nil\tloadOrder:number\tdescription:text\n"
    .. "Item.tsv\tItem\t\t\t1\tItems\n"
    .. "Patch.tsv\tpatch\t\tItem.tsv\t2\tRow patch\n"

local ITEM =
    "name:name\tprice:uint\ttags:{name}|nil\n"
    .. "sword\t100\t\"melee\"\n"
    .. "shield\t25\t\"defense\"\n"

-- Patch: change sword's price and append a tag.
local PATCH =
    "name:name\tpatchOp:patch_op\tprice:uint|nil\tappend_tags:{name}|nil\n"
    .. "sword\tupdate\t999\t\"patched\"\n"

describe("--export-merged", function()
    local temp_dir, pkg, mergedRoot

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(),
            "mergedspec_" .. os.time() .. "_" .. math.random(1, 1e6))
        assert(lfs.mkdir(td))
        temp_dir = td
        pkg = path_join(td, "pkg")
        assert(lfs.mkdir(pkg))
        mergedRoot = path_join(td, "merged_out")
        assert.is_true(file_util.writeFile(path_join(pkg, MANIFEST_FILENAME), MANIFEST))
        assert.is_true(file_util.writeFile(path_join(pkg, "files.tsv"), FILES))
        assert.is_true(file_util.writeFile(path_join(pkg, "Item.tsv"), ITEM))
        assert.is_true(file_util.writeFile(path_join(pkg, "Patch.tsv"), PATCH))
    end)

    after_each(function()
        if temp_dir then
            local td = temp_dir
            temp_dir = nil
            file_util.deleteTempDir(td)
        end
    end)

    it("writes the merged (patched) state to the merged tree", function()
        reformatter.processFiles({pkg}, nil, {mergedDir = mergedRoot})
        -- Layout: <mergedRoot>/<basename(inputDir)>/<relpath> => merged_out/pkg/Item.tsv
        local mergedItem = file_util.readFile(path_join(mergedRoot, "pkg", "Item.tsv"))
        assert.is_not_nil(mergedItem, "merged Item.tsv should exist")
        -- The patch is reflected: sword's price is 999 and the tag was appended.
        assert.is_truthy(mergedItem:match("sword\t999\t"),
            "merged sword price should be the patched 999; got:\n" .. mergedItem)
        assert.is_truthy(mergedItem:find("patched", 1, true),
            "merged sword tags should include the appended 'patched'; got:\n" .. mergedItem)
        -- Untouched row is preserved verbatim.
        assert.is_truthy(mergedItem:match("shield\t25\t"))
    end)

    it("does not bake the patch into the parent source (no-bake)", function()
        reformatter.processFiles({pkg}, nil, {mergedDir = mergedRoot})
        -- The SOURCE Item.tsv must still show the original price 100, no 'patched' tag.
        local srcItem = file_util.readFile(path_join(pkg, "Item.tsv"))
        assert.is_truthy(srcItem:match("sword\t100\t"),
            "source sword price must stay 100; got:\n" .. srcItem)
        assert.is_falsy(srcItem:find("patched", 1, true),
            "source must not contain the appended tag; got:\n" .. srcItem)
    end)

    it("mirrors the patch file itself into the merged tree too", function()
        reformatter.processFiles({pkg}, nil, {mergedDir = mergedRoot})
        local mergedPatch = file_util.readFile(path_join(mergedRoot, "pkg", "Patch.tsv"))
        assert.is_not_nil(mergedPatch, "merged tree is a full snapshot incl. the patch file")
    end)

    it("runs standalone (no format exporters) and creates the merged dir", function()
        assert.is_false(file_util.isDir(mergedRoot))
        reformatter.processFiles({pkg}, {}, {mergedDir = mergedRoot})
        assert.is_true(file_util.isDir(path_join(mergedRoot, "pkg")))
    end)
end)
