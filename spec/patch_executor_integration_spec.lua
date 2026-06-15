-- patch_executor_integration_spec.lua
-- End-to-end tests for row patches:
-- load a package whose Files.tsv declares a patch file (typeName=patch,
-- patchOf=Target.tsv) and verify add / remove / update / replace ops on the
-- target dataset, the two-step value handling, =nil, and error cases.

local busted = require("busted")
local assert = require("luassert")

local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local file_util = require("file_util")
local manifest_loader = require("manifest_loader")
local error_reporting = require("error_reporting")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local function mockBadVal(log_messages)
    local log = function(_self, msg) table.insert(log_messages, msg) end
    local badVal = error_reporting.badValGen(log)
    badVal.source_name = "test"
    badVal.line_no = 1
    return badVal
end

local MANIFEST_FILENAME = "Manifest.transposed.tsv"
local MANIFEST = [[package_id:package_id	Test
name:string	Test Package
version:version	0.1.0
description:markdown	Row-patch integration test
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
            local cell = row[nameIdx]
            local n = cell and cell.parsed
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
    .. "\tpatchOf:filepath|nil\tloadOrder:number\tdescription:text\n"

-- Parent Item.tsv: price is nullable so =nil and update can clear it.
local ITEM =
    "name:name\tprice:uint|nil\tweight:float\ttier:integer:1\n"
    .. "sword\t100\t3.5\t2\n"
    .. "shield\t25\t5.0\t1\n"
    .. "potion\t10\t0.5\t1\n"

describe("patch_executor integration", function()
    local temp_dir, log_messages, badVal

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        local td = path_join(system_temp, "patch_test_" .. os.time()
            .. "_" .. math.random(1, 1e6))
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

    local function loadWith(patchBody)
        local pkg = path_join(temp_dir, "pkg")
        assert(lfs.mkdir(pkg))
        local FILES = FILES_HEADER
            .. "Item.tsv\tItem\t\t\t1\tItems\n"
            .. "ItemPatch.tsv\tpatch\t\tItem.tsv\t2\tItem patches\n"
        assert.is_true(file_util.writeFile(path_join(pkg, MANIFEST_FILENAME), MANIFEST))
        assert.is_true(file_util.writeFile(path_join(pkg, "files.tsv"), FILES))
        assert.is_true(file_util.writeFile(path_join(pkg, "Item.tsv"), ITEM))
        assert.is_true(file_util.writeFile(path_join(pkg, "ItemPatch.tsv"), patchBody))
        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        return result
    end

    it("add inserts a new row using parent defaults for empty cells", function()
        local PATCH =
            "name:name\tpatchOp:patch_op\tprice:uint|nil\tweight:float|nil\n"
            .. "dagger\tadd\t40\t1.0\n"
        local result = loadWith(PATCH)
        local item = findTsv(result, "Item%.tsv$")
        local byName, header = rowsByName(item)
        assert.is_not_nil(byName.dagger, "dagger should have been added")
        assert.are.equal(40, readCell(byName.dagger, header, "price"))
        assert.are.equal(1.0, readCell(byName.dagger, header, "weight"))
        -- tier omitted in the patch -> parent default (1) applies.
        assert.are.equal(1, readCell(byName.dagger, header, "tier"))
        assert.are.equal(4, countDataRows(item))
    end)

    it("remove deletes the matching row", function()
        local PATCH =
            "name:name\tpatchOp:patch_op\n"
            .. "potion\tremove\n"
        local result = loadWith(PATCH)
        local item = findTsv(result, "Item%.tsv$")
        local byName = rowsByName(item)
        assert.is_nil(byName.potion, "potion should have been removed")
        assert.are.equal(2, countDataRows(item))
    end)

    it("update changes only the named non-empty cells", function()
        local PATCH =
            "name:name\tpatchOp:patch_op\tprice:uint|nil\tweight:float|nil\n"
            .. "sword\tupdate\t250\t\n"
        local result = loadWith(PATCH)
        local item = findTsv(result, "Item%.tsv$")
        local byName, header = rowsByName(item)
        assert.are.equal(250, readCell(byName.sword, header, "price"))
        -- weight cell left empty -> unchanged.
        assert.are.equal(3.5, readCell(byName.sword, header, "weight"))
    end)

    it("update with =nil clears a nullable cell", function()
        local PATCH =
            "name:name\tpatchOp:patch_op\tprice:uint|nil\n"
            .. "shield\tupdate\t=nil\n"
        local result = loadWith(PATCH)
        local item = findTsv(result, "Item%.tsv$")
        local byName, header = rowsByName(item)
        assert.is_nil(readCell(byName.shield, header, "price"))
    end)

    it("replace rewrites a row wholesale (defaults for omitted cells)", function()
        local PATCH =
            "name:name\tpatchOp:patch_op\tprice:uint|nil\tweight:float|nil\n"
            .. "sword\treplace\t5\t9.0\n"
        local result = loadWith(PATCH)
        local item = findTsv(result, "Item%.tsv$")
        local byName, header = rowsByName(item)
        assert.are.equal(5, readCell(byName.sword, header, "price"))
        assert.are.equal(9.0, readCell(byName.sword, header, "weight"))
        -- tier omitted -> back to parent default (1), not the original 2.
        assert.are.equal(1, readCell(byName.sword, header, "tier"))
        assert.are.equal(3, countDataRows(item))
    end)

    it("validators run against the patched state", function()
        -- A file validator that fails if any price > 200; an update pushes
        -- sword to 250, so validation must fail.
        local pkg = path_join(temp_dir, "valpkg")
        assert(lfs.mkdir(pkg))
        local FILES =
            "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
            .. "\tpatchOf:filepath|nil\tloadOrder:number\tdescription:text"
            .. "\tfileValidators:{validator_spec}|nil\n"
            .. "Item.tsv\tItem\t\t\t1\tItems"
            .. "\t\"all(rows, function(r) return r.price == nil or r.price <= 200 end)\"\n"
            .. "ItemPatch.tsv\tpatch\t\tItem.tsv\t2\tPatches\t\n"
        local PATCH =
            "name:name\tpatchOp:patch_op\tprice:uint|nil\n"
            .. "sword\tupdate\t250\n"
        assert.is_true(file_util.writeFile(path_join(pkg, MANIFEST_FILENAME), MANIFEST))
        assert.is_true(file_util.writeFile(path_join(pkg, "files.tsv"), FILES))
        assert.is_true(file_util.writeFile(path_join(pkg, "Item.tsv"), ITEM))
        assert.is_true(file_util.writeFile(path_join(pkg, "ItemPatch.tsv"), PATCH))
        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        assert.is_false(result.validationPassed,
            "validator should see the patched price 250 and fail")
    end)

    it("multiple removes drop all and preserve order of survivors", function()
        local PATCH =
            "name:name\tpatchOp:patch_op\n"
            .. "sword\tremove\n"
            .. "potion\tremove\n"
        local result = loadWith(PATCH)
        local item = findTsv(result, "Item%.tsv$")
        local byName = rowsByName(item)
        assert.is_nil(byName.sword)
        assert.is_nil(byName.potion)
        assert.is_not_nil(byName.shield)
        assert.are.equal(1, countDataRows(item))
        -- The lone survivor is still the original shield row (order preserved).
        assert.are.equal("shield", item[2][colIdx(item[1], "name")].parsed)
    end)

    it("remove one row and add another in the same file (tombstone + append)", function()
        -- Exercises deferred removal: potion is tombstoned, dagger is appended,
        -- and the single compaction pass drops the tombstone while keeping order.
        local PATCH =
            "name:name\tpatchOp:patch_op\tprice:uint|nil\tweight:float|nil\n"
            .. "potion\tremove\n"
            .. "dagger\tadd\t7\t1.5\n"
        local result = loadWith(PATCH)
        local item = findTsv(result, "Item%.tsv$")
        local byName, header = rowsByName(item)
        assert.is_nil(byName.potion, "potion should be removed")
        assert.is_not_nil(byName.dagger, "dagger should be added")
        assert.are.equal(7, readCell(byName.dagger, header, "price"))
        assert.are.equal(3, countDataRows(item))
        -- Survivors keep order, with the appended row last.
        local names = {}
        for i = 2, #item do
            if type(item[i]) == "table" then
                names[#names + 1] = item[i][colIdx(item[1], "name")].parsed
            end
        end
        assert.are.same({"sword", "shield", "dagger"}, names)
    end)

    it("add with an existing key is an error", function()
        local PATCH =
            "name:name\tpatchOp:patch_op\tprice:uint|nil\n"
            .. "sword\tadd\t1\n"
        loadWith(PATCH)
        local joined = table.concat(log_messages, "\n")
        assert.is_true(joined:find("already exists", 1, true) ~= nil,
            "expected add-existing error, got:\n" .. joined)
    end)

    it("update with a missing key is an error", function()
        local PATCH =
            "name:name\tpatchOp:patch_op\tprice:uint|nil\n"
            .. "nope\tupdate\t1\n"
        loadWith(PATCH)
        local joined = table.concat(log_messages, "\n")
        assert.is_true(joined:find("not found in target", 1, true) ~= nil,
            "expected update-missing error, got:\n" .. joined)
    end)
end)
