-- bulk_patch_integration_spec.lua
-- End-to-end tests for bulk filter/transform patches: a `bulk_patch` file
-- (typeName=bulk_patch, bulkPatchOf=Target.tsv)
-- selects parent rows by a `where` expression and updates or removes the matches.

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

local function mockBadVal(log_messages)
    local badVal = error_reporting.badValGen(function(_s, msg)
        table.insert(log_messages, msg)
    end)
    badVal.source_name = "test"
    badVal.line_no = 1
    return badVal
end

local MANIFEST_FILENAME = "Manifest.transposed.tsv"
local MANIFEST = [[package_id:package_id	Test
name:string	Test Package
version:version	0.1.0
description:markdown	Bulk-patch integration test
]]

local function colIdx(header, name)
    local col = header[name]
    return col and col.idx or nil
end

local function rowsByName(tsv_file)
    local header = tsv_file[1]
    local nameIdx = colIdx(header, "name")
    local byName = {}
    for i = 2, #tsv_file do
        local row = tsv_file[i]
        if type(row) == "table" then
            local n = row[nameIdx] and row[nameIdx].parsed
            if n ~= nil then byName[n] = row end
        end
    end
    return byName, header
end

local function readCell(row, header, colName)
    local idx = colIdx(header, colName)
    if not idx then return nil end
    local cell = row[idx]
    return cell and cell.parsed
end

local function findTsv(result, pattern)
    for fn, tsv in pairs(result.tsv_files) do
        if fn:match(pattern) then return tsv end
    end
    return nil
end

local function countDataRows(tsv)
    local n = 0
    for i = 2, #tsv do
        if type(tsv[i]) == "table" then n = n + 1 end
    end
    return n
end

local FILES_HEADER =
    "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
    .. "\tpatchOf:filepath|nil\tbulkPatchOf:filepath|nil"
    .. "\tloadOrder:number\tdescription:text\n"

local ITEM =
    "name:name\tprice:uint\tcategory:name\ttags:{name}\n"
    .. "sword\t100\tweapon\t\"melee\",\"iron\"\n"
    .. "shield\t25\tarmor\t\"defense\"\n"
    .. "herb\t5\tconsumable\t\"medicine\",\"healing\"\n"
    .. "elixir\t50\tconsumable\t\"medicine\",\"rare\"\n"

describe("bulk_patch integration", function()
    local temp_dir, log_messages, badVal

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(),
            "bulkpatch_" .. os.time() .. "_" .. math.random(1, 1e6))
        assert(lfs.mkdir(td))
        temp_dir = td
        log_messages = {}
        badVal = mockBadVal(log_messages)
        badVal.logger = error_reporting.nullLogger
    end)

    after_each(function()
        if temp_dir then
            local td = temp_dir
            temp_dir = nil
            file_util.deleteTempDir(td)
        end
    end)

    -- Loads a package with Item.tsv and one bulk_patch file (ItemBulk.tsv).
    local function loadBulk(bulkBody)
        local pkg = path_join(temp_dir, "pkg")
        assert(lfs.mkdir(pkg))
        local FILES = FILES_HEADER
            .. "Item.tsv\tItem\t\t\t\t1\tItems\n"
            .. "ItemBulk.tsv\tbulk_patch\t\t\tItem.tsv\t2\tBulk patches\n"
        assert.is_true(file_util.writeFile(path_join(pkg, MANIFEST_FILENAME), MANIFEST))
        assert.is_true(file_util.writeFile(path_join(pkg, "files.tsv"), FILES))
        assert.is_true(file_util.writeFile(path_join(pkg, "Item.tsv"), ITEM))
        assert.is_true(file_util.writeFile(path_join(pkg, "ItemBulk.tsv"), bulkBody))
        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        return result
    end

    it("update transform doubles price of matched rows (=expr, self=target)", function()
        local BULK =
            "ruleName:name\tpatchOp:patch_op\twhere:expression\tprice:expression|nil\n"
            .. "doublecons\tupdate\trow.category == 'consumable'\t=row.price * 2\n"
        local result = loadBulk(BULK)
        local item = findTsv(result, "Item%.tsv$")
        local byName, header = rowsByName(item)
        assert.are.equal(10, readCell(byName.herb, header, "price"))
        assert.are.equal(100, readCell(byName.elixir, header, "price"))
        -- Non-matches untouched.
        assert.are.equal(100, readCell(byName.sword, header, "price"))
        assert.are.equal(25, readCell(byName.shield, header, "price"))
    end)

    it("update transform sets a literal value on matched rows", function()
        local BULK =
            "ruleName:name\tpatchOp:patch_op\twhere:expression\tcategory:expression|nil\n"
            .. "cheapen\tupdate\trow.price < 30\tcheap\n"
        local result = loadBulk(BULK)
        local item = findTsv(result, "Item%.tsv$")
        local byName, header = rowsByName(item)
        assert.are.equal("cheap", readCell(byName.shield, header, "category"))
        assert.are.equal("cheap", readCell(byName.herb, header, "category"))
        assert.are.equal("weapon", readCell(byName.sword, header, "category"))
    end)

    it("remove drops all rows matching the selector", function()
        local BULK =
            "ruleName:name\tpatchOp:patch_op\twhere:expression\n"
            .. "dropweapons\tremove\trow.category == 'weapon'\n"
        local result = loadBulk(BULK)
        local item = findTsv(result, "Item%.tsv$")
        local byName = rowsByName(item)
        assert.is_nil(byName.sword)
        assert.are.equal(3, countDataRows(item))
    end)

    it("where can use helpers over list cells (remove all medicine items)", function()
        local BULK =
            "ruleName:name\tpatchOp:patch_op\twhere:expression\n"
            .. "nomeds\tremove\tany(row.tags, function(t) return t == 'medicine' end)\n"
        local result = loadBulk(BULK)
        local item = findTsv(result, "Item%.tsv$")
        local byName = rowsByName(item)
        assert.is_nil(byName.herb)
        assert.is_nil(byName.elixir)
        assert.is_not_nil(byName.sword)
        assert.is_not_nil(byName.shield)
        assert.are.equal(2, countDataRows(item))
    end)

    it("a selector matching zero rows is a no-op (load still passes)", function()
        local BULK =
            "ruleName:name\tpatchOp:patch_op\twhere:expression\tprice:expression|nil\n"
            .. "none\tupdate\trow.category == 'nonexistent'\t=999\n"
        local result = loadBulk(BULK)
        assert.is_true(result.validationPassed)
        local item = findTsv(result, "Item%.tsv$")
        local byName, header = rowsByName(item)
        assert.are.equal(100, readCell(byName.sword, header, "price"))
    end)

    it("a throwing where selector is reported as an error", function()
        local BULK =
            "ruleName:name\tpatchOp:patch_op\twhere:expression\tprice:expression|nil\n"
            .. "boom\tupdate\trow.missing.field == 1\t=1\n"
        local result = loadBulk(BULK)
        assert.is_false(result.validationPassed)
        local joined = table.concat(log_messages, "\n")
        assert.is_true(joined:find("where", 1, true) ~= nil,
            "expected a where error, got:\n" .. joined)
    end)

    it("a row patch and a bulk patch compose on the same target", function()
        local pkg = path_join(temp_dir, "compose")
        assert(lfs.mkdir(pkg))
        local FILES = FILES_HEADER
            .. "Item.tsv\tItem\t\t\t\t1\tItems\n"
            .. "ItemPatch.tsv\tpatch\t\tItem.tsv\t\t2\tRow patch\n"
            .. "ItemBulk.tsv\tbulk_patch\t\t\tItem.tsv\t3\tBulk patch\n"
        local PATCH =
            "name:name\tpatchOp:patch_op\tprice:uint|nil\n"
            .. "sword\tupdate\t777\n"
        local BULK =
            "ruleName:name\tpatchOp:patch_op\twhere:expression\tprice:expression|nil\n"
            .. "doublecons\tupdate\trow.category == 'consumable'\t=row.price * 2\n"
        assert.is_true(file_util.writeFile(path_join(pkg, MANIFEST_FILENAME), MANIFEST))
        assert.is_true(file_util.writeFile(path_join(pkg, "files.tsv"), FILES))
        assert.is_true(file_util.writeFile(path_join(pkg, "Item.tsv"), ITEM))
        assert.is_true(file_util.writeFile(path_join(pkg, "ItemPatch.tsv"), PATCH))
        assert.is_true(file_util.writeFile(path_join(pkg, "ItemBulk.tsv"), BULK))
        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        local item = findTsv(result, "Item%.tsv$")
        local byName, header = rowsByName(item)
        assert.are.equal(777, readCell(byName.sword, header, "price"), "row patch applied")
        assert.are.equal(10, readCell(byName.herb, header, "price"), "bulk patch applied")
    end)
end)
