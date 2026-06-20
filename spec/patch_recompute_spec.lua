-- patch_recompute_spec.lua
-- Tests for downstream =expr recompute: after a patch changes a cell,
-- downstream same-row `=expr` cells that read it are re-evaluated, so a derived
-- value stays consistent with the patched input.

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

local MANIFEST_FILENAME = "Manifest.transposed.tsv"
local MANIFEST = [[package_id:package_id	Test
name:string	Test Package
version:version	0.1.0
description:markdown	Recompute test
]]

local FILES =
    "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
    .. "\tpatchOf:filepath|nil\tloadOrder:number\tdescription:text\n"
    .. "Item.tsv\tItem\t\t\t1\tItems\n"
    .. "ItemPatch.tsv\tpatch\t\tItem.tsv\t2\tRow patch\n"

describe("recompute downstream =expr after patches", function()
    local temp_dir, pkg, badVal

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(),
            "recompute_" .. os.time() .. "_" .. math.random(1, 1e6))
        assert(lfs.mkdir(td))
        temp_dir = td
        pkg = path_join(td, "pkg")
        assert(lfs.mkdir(pkg))
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

    -- Writes Item.tsv + ItemPatch.tsv, loads the package, returns the result.
    local function load(itemBody, patchBody)
        assert.is_true(file_util.writeFile(path_join(pkg, MANIFEST_FILENAME), MANIFEST))
        assert.is_true(file_util.writeFile(path_join(pkg, "files.tsv"), FILES))
        assert.is_true(file_util.writeFile(path_join(pkg, "Item.tsv"), itemBody))
        assert.is_true(file_util.writeFile(path_join(pkg, "ItemPatch.tsv"), patchBody))
        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        return result
    end

    -- Reads a column's parsed value for the row whose primary key (col 1) matches.
    local function cell(result, rowName, colName)
        local item
        for fn, tsv in pairs(result.tsv_files) do
            if fn:match("Item%.tsv$") then item = tsv end
        end
        assert.is_not_nil(item)
        local header = item[1]
        local idx = header[colName] and header[colName].idx
        for i = 2, #item do
            local row = item[i]
            if type(row) == "table" and row[1].parsed == rowName then
                return idx and row[idx] and row[idx].parsed
            end
        end
    end

    it("re-evaluates an explicit =expr cell when its input is patched", function()
        local ITEM =
            "name:name\tbase:uint\ttotal:integer\n"
            .. "sword\t10\t=self.base*2\n"          -- total = 20 at load
        local PATCH =
            "name:name\tpatchOp:patch_op\tbase:uint|nil\n"
            .. "sword\tupdate\t50\n"                -- base -> 50
        local result = load(ITEM, PATCH)
        assert.is_true(result.validationPassed,
            "load should pass; errors=" .. tostring(badVal.errors))
        assert.are.equal(50, cell(result, "sword", "base"))
        assert.are.equal(100, cell(result, "sword", "total"),
            "total should recompute from the patched base")
    end)

    it("re-evaluates a default-=expr cell (empty cell, column default) too", function()
        local ITEM =
            "name:name\tbase:uint\ttotal:integer:=self.base*2\n"
            .. "sword\t10\t\n"                       -- total defaults to 20
        local PATCH =
            "name:name\tpatchOp:patch_op\tbase:uint|nil\n"
            .. "sword\tupdate\t50\n"
        local result = load(ITEM, PATCH)
        assert.is_true(result.validationPassed)
        assert.are.equal(100, cell(result, "sword", "total"))
    end)

    it("does NOT clobber an =expr cell the patch set directly", function()
        local ITEM =
            "name:name\tbase:uint\ttotal:integer\n"
            .. "sword\t10\t=self.base*2\n"
        -- Patch sets BOTH base and total explicitly: the explicit total must win.
        local PATCH =
            "name:name\tpatchOp:patch_op\tbase:uint|nil\ttotal:integer|nil\n"
            .. "sword\tupdate\t50\t999\n"
        local result = load(ITEM, PATCH)
        assert.is_true(result.validationPassed)
        assert.are.equal(50, cell(result, "sword", "base"))
        assert.are.equal(999, cell(result, "sword", "total"),
            "a directly-patched =expr cell keeps its explicit value")
    end)

    it("recomputes a chain of dependent =expr cells in order", function()
        local ITEM =
            "name:name\tc:uint\tb:integer\ta:integer\n"
            .. "sword\t5\t=self.c+1\t=self.b+1\n"     -- b=6, a=7
        local PATCH =
            "name:name\tpatchOp:patch_op\tc:uint|nil\n"
            .. "sword\tupdate\t10\n"                  -- c -> 10
        local result = load(ITEM, PATCH)
        assert.is_true(result.validationPassed)
        assert.are.equal(11, cell(result, "sword", "b"), "b = c+1")
        assert.are.equal(12, cell(result, "sword", "a"), "a = b+1 (depends on recomputed b)")
    end)

    it("leaves unrelated rows untouched", function()
        local ITEM =
            "name:name\tbase:uint\ttotal:integer\n"
            .. "sword\t10\t=self.base*2\n"
            .. "shield\t7\t=self.base*2\n"            -- not patched -> stays 14
        local PATCH =
            "name:name\tpatchOp:patch_op\tbase:uint|nil\n"
            .. "sword\tupdate\t50\n"
        local result = load(ITEM, PATCH)
        assert.is_true(result.validationPassed)
        assert.are.equal(100, cell(result, "sword", "total"))
        assert.are.equal(14, cell(result, "shield", "total"))
    end)

    it("a pre-processor sees the recomputed value (recompute runs before pre-processors)", function()
        -- total = base*2 (default =expr). A patch bumps base 10->50, so total should
        -- recompute to 100 BEFORE the package processor runs; the processor copies
        -- total into `flag`, which must therefore be 100, not the stale 20.
        local MANIFEST_P = "package_id:package_id\tTest\nname:string\tT\nversion:version\t0.1.0\n"
            .. "description:markdown\td\npreProcessors:{processor_spec}|nil\t"
            .. "\"(function() for _, r in ipairs(files['item.tsv']) do setCell(r, 'flag', r.total) end return true end)()\"\n"
        local FILES_P =
            "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
            .. "\tpatchOf:filepath|nil\tloadOrder:number\tdescription:text\n"
            .. "Item.tsv\tItem\t\t\t1\tItems\n"
            .. "ItemPatch.tsv\tpatch\t\tItem.tsv\t2\tRow patch\n"
        local ITEM =
            "name:name\tbase:uint\ttotal:integer:=self.base*2\tflag:integer|nil\n"
            .. "sword\t10\t\t\n"
        local PATCH =
            "name:name\tpatchOp:patch_op\tbase:uint|nil\n"
            .. "sword\tupdate\t50\n"
        assert.is_true(file_util.writeFile(path_join(pkg, MANIFEST_FILENAME), MANIFEST_P))
        assert.is_true(file_util.writeFile(path_join(pkg, "files.tsv"), FILES_P))
        assert.is_true(file_util.writeFile(path_join(pkg, "Item.tsv"), ITEM))
        assert.is_true(file_util.writeFile(path_join(pkg, "ItemPatch.tsv"), PATCH))
        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        assert.is_true(result.validationPassed,
            "load should pass; errors=" .. tostring(badVal.errors))
        assert.are.equal(100, cell(result, "sword", "total"))
        assert.are.equal(100, cell(result, "sword", "flag"),
            "pre-processor should have read the recomputed total (100), not stale 20")
    end)

    it("does not bake the recomputed value into the source (no-bake)", function()
        local ITEM =
            "name:name\tbase:uint\ttotal:integer\n"
            .. "sword\t10\t=self.base*2\n"
        local PATCH =
            "name:name\tpatchOp:patch_op\tbase:uint|nil\n"
            .. "sword\tupdate\t50\n"
        load(ITEM, PATCH)
        -- The source Item.tsv must still carry the expression, not the value.
        local src = file_util.readFile(path_join(pkg, "Item.tsv"))
        assert.is_truthy(src:find("=self.base*2", 1, true),
            "source keeps the =expr; got:\n" .. src)
        assert.is_falsy(src:find("\t100", 1, true), "recomputed value must not be baked")
    end)
end)
