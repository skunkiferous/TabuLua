-- mod_on_mod_spec.lua
-- Pins mod-on-mod composition (TODO/mod_ecosystem.md survey scenario 2, Phase
-- 7 hardening): a mod's patched-in rows are ordinary rows for every LATER mod,
-- because patches apply in package load order and each apply re-indexes the
-- target by primary key. Nothing in the engine special-cases this — these
-- tests exist so a regression cannot slip in unnoticed. Also pins the
-- --check-conflicts classification of the two composition shapes: patching a
-- row another mod ADDED is benign (not reported); removing a row another mod
-- patched is a fight (reported).

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
    .. "\tschemaOverlayOf:filepath|nil\tpatchOf:filepath|nil\tloadOrder:number\tdescription:text\n"

-- Writes one package directory: a manifest for `pkgId` (optionally with a
-- load_after list), a files.tsv from the descriptor rows, and the data files.
local function writePkg(root, dirName, pkgId, loadAfter, descRows, dataFiles)
    local dir = path_join(root, dirName)
    assert(lfs.mkdir(dir))
    local manifest = "package_id:package_id\t" .. pkgId .. "\n"
        .. "name:string\t" .. pkgId .. " Package\n"
        .. "version:version\t0.1.0\n"
        .. "description:markdown\tMod-on-mod test\n"
    if loadAfter then
        manifest = manifest .. "load_after:{package_id}|nil\t\"" .. loadAfter .. "\"\n"
    end
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

-- ModB adds a brand-new row to Core's file.
local ADD_PATCH = "name:name\tpatchOp:patch_op\tprice:uint|nil\ttags:{name}|nil\n"
    .. "axe\tadd\t50\t\"chop\"\n"

-- Finds the row keyed `pk` in the dataset whose name ends with `fnSuffix`.
local function rowOf(tsv_files, fnSuffix, pk)
    for fn, tsv in pairs(tsv_files) do
        if fn:sub(-#fnSuffix) == fnSuffix and type(tsv) == "table" then
            for i = 2, #tsv do
                local row = tsv[i]
                if type(row) == "table" and tostring(row[1].parsed) == pk then
                    return row, tsv[1]
                end
            end
            return nil, tsv[1]
        end
    end
    return nil, nil
end

describe("mod-on-mod composition (a mod patches another mod's rows)", function()
    local temp_dir, badVal, core, modb

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(),
            "modonmod_" .. os.time() .. "_" .. math.random(1, 1e6))
        assert(lfs.mkdir(td))
        temp_dir = td
        badVal = error_reporting.badValGen()
        badVal.logger = error_reporting.nullLogger
        core = writePkg(temp_dir, "core", "Core", nil,
            {"Item.tsv\tItem\t\t\t\t1\tItems\n"}, {["Item.tsv"] = ITEM})
        modb = writePkg(temp_dir, "modb", "ModB", "Core",
            {"AddPatch.tsv\tpatch\t\t\tItem.tsv\t10\tAdds the axe\n"},
            {["AddPatch.tsv"] = ADD_PATCH})
    end)

    after_each(function()
        if temp_dir then
            local td = temp_dir
            temp_dir = nil
            file_util.deleteTempDir(td)
        end
    end)

    it("lets a later mod update cells and merge lists on a row an earlier mod added", function()
        -- ModC pairs load_after ModB (the ordering half of building on
        -- another mod) with a patch targeting the row ModB's patch added.
        local tune = "name:name\tpatchOp:patch_op\tprice:uint|nil\tappend_tags:{name}|nil\n"
            .. "axe\tupdate\t60\t\"sharp\"\n"
        local modc = writePkg(temp_dir, "modc", "ModC", "ModB",
            {"TunePatch.tsv\tpatch\t\t\tItem.tsv\t10\tTunes the axe\n"},
            {["TunePatch.tsv"] = tune})
        local result = manifest_loader.processFiles({core, modb, modc}, badVal, nil, nil, true)
        assert.is_not_nil(result)
        assert.are.equal(0, badVal.errors)
        assert.is_true(result.validationPassed)

        local row, header = rowOf(result.tsv_files, "Item.tsv", "axe")
        assert.is_not_nil(row, "ModB's added row must exist")
        assert.are.equal(60, row[header["price"].idx].parsed)
        assert.are.same({"chop", "sharp"}, row[header["tags"].idx].parsed)

        -- The lineage chain shows the composition: ModB's add, then ModC's
        -- writes — and --check-conflicts classifies it as benign layering.
        local lineageReport = result.lineage:report()
        local addAt = lineageReport:find("[add]   <- ModB:AddPatch.tsv", 1, true)
        local updAt = lineageReport:find("price = 60   <- ModC:TunePatch.tsv", 1, true)
        assert.is_truthy(addAt, "report:\n" .. lineageReport)
        assert.is_truthy(updAt, "report:\n" .. lineageReport)
        assert.is_truthy(addAt < updAt, "add must precede the later mod's update")
        local _, conflicts = result.lineage:conflictReport()
        assert.are.equal(0, conflicts, "patching an added row is not a fight")
    end)

    it("lets a later mod remove a row an earlier mod added — reported as row tension", function()
        local drop = "name:name\tpatchOp:patch_op\n"
            .. "axe\tremove\n"
        local modc = writePkg(temp_dir, "modc", "ModC", "ModB",
            {"DropPatch.tsv\tpatch\t\t\tItem.tsv\t10\tDrops the axe\n"},
            {["DropPatch.tsv"] = drop})
        local result = manifest_loader.processFiles({core, modb, modc}, badVal, nil, nil, true)
        assert.is_not_nil(result)
        assert.are.equal(0, badVal.errors)

        local row = rowOf(result.tsv_files, "Item.tsv", "axe")
        assert.is_nil(row, "ModC's remove must delete ModB's added row")
        -- Core's own row is untouched.
        assert.is_not_nil((rowOf(result.tsv_files, "Item.tsv", "sword")))

        -- add-by-B then remove-by-C is a genuine tension: reported.
        local r, conflicts = result.lineage:conflictReport()
        assert.are.equal(1, conflicts, "report:\n" .. r)
        assert.is_truthy(r:find("row remove/replace", 1, true))
        assert.is_truthy(r:find("[add]   <- ModB:AddPatch.tsv", 1, true))
        assert.is_truthy(r:find("[remove]   <- ModC:DropPatch.tsv", 1, true))
    end)
end)
