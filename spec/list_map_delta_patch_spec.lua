-- list_map_delta_patch_spec.lua
-- End-to-end tests for row-patch list/map delta companion columns:
-- append_/prepend_/remove_(/_last_),
-- replace_ (wholesale), replace_oldvalue_/replace_newvalue_ (/_last_) on list
-- columns, append_/remove_/replace_ on map columns, prefix-collision precedence,
-- and the edge cases.

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
description:markdown	List/map delta patch test
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

-- A list (read-only proxy) -> plain Lua array, for assert.are.same.
local function asArray(v)
    local out = {}
    if v ~= nil then for _, x in ipairs(v) do out[#out + 1] = x end end
    return out
end

local FILES_HEADER =
    "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
    .. "\tpatchOf:filepath|nil\tloadOrder:number\tdescription:text\n"

-- Parent with a list column (tags) and a map column (resistances).
local CREATURE =
    "name:name\ttags:{name}\tresistances:{name:uint}\tdrops:{name}\n"
    .. "dragon\t\"fire\",\"flying\",\"boss\"\tfire=100,ice=0\t\"steel\",\"gold\",\"steel\"\n"
    .. "goblin\t\"melee\"\tpoison=50\t\"copper\"\n"

describe("list/map delta patches", function()
    local temp_dir, log_messages, badVal

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(),
            "delta_" .. os.time() .. "_" .. math.random(1, 1e6))
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

    local pkgCounter = 0
    local function loadWith(patchBody)
        pkgCounter = pkgCounter + 1
        local pkg = path_join(temp_dir, "pkg" .. pkgCounter)
        assert(lfs.mkdir(pkg))
        local FILES = FILES_HEADER
            .. "Creature.tsv\tCreature\t\t\t1\tCreatures\n"
            .. "CreaturePatch.tsv\tpatch\t\tCreature.tsv\t2\tPatches\n"
        assert.is_true(file_util.writeFile(path_join(pkg, MANIFEST_FILENAME), MANIFEST))
        assert.is_true(file_util.writeFile(path_join(pkg, "files.tsv"), FILES))
        assert.is_true(file_util.writeFile(path_join(pkg, "Creature.tsv"), CREATURE))
        assert.is_true(file_util.writeFile(path_join(pkg, "CreaturePatch.tsv"), patchBody))
        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        return result
    end

    local function dragonTags(result)
        local c = findTsv(result, "Creature%.tsv$")
        local byName, header = rowsByName(c)
        return asArray(readCell(byName.dragon, header, "tags"))
    end

    it("append_ adds values to the tail of a list", function()
        local P = "name:name\tpatchOp:patch_op\tappend_tags:{name}|nil\n"
            .. "dragon\tupdate\t\"undead\",\"ancient\"\n"
        local r = loadWith(P)
        assert.are.same({"fire", "flying", "boss", "undead", "ancient"}, dragonTags(r))
    end)

    it("prepend_ inserts values at the head, preserving order", function()
        local P = "name:name\tpatchOp:patch_op\tprepend_tags:{name}|nil\n"
            .. "dragon\tupdate\t\"legendary\",\"named\"\n"
        local r = loadWith(P)
        assert.are.same({"legendary", "named", "fire", "flying", "boss"}, dragonTags(r))
    end)

    it("remove_ drops the first occurrence of each value", function()
        local P = "name:name\tpatchOp:patch_op\tremove_tags:{name}|nil\n"
            .. "dragon\tupdate\t\"flying\"\n"
        local r = loadWith(P)
        assert.are.same({"fire", "boss"}, dragonTags(r))
    end)

    it("remove_ targets the first of duplicates; remove_last_ the last", function()
        -- dragon.drops is {steel, gold, steel}
        local function dropsOf(P)
            local r = loadWith(P)
            local c = findTsv(r, "Creature%.tsv$"); local byName, h = rowsByName(c)
            return asArray(readCell(byName.dragon, h, "drops"))
        end
        assert.are.same({"gold", "steel"},
            dropsOf("name:name\tpatchOp:patch_op\tremove_drops:{name}|nil\ndragon\tupdate\t\"steel\"\n"))
        assert.are.same({"steel", "gold"},
            dropsOf("name:name\tpatchOp:patch_op\tremove_last_drops:{name}|nil\ndragon\tupdate\t\"steel\"\n"))
    end)

    it("replace_ sets the whole list wholesale", function()
        local P = "name:name\tpatchOp:patch_op\treplace_tags:{name}|nil\n"
            .. "dragon\tupdate\t\"calm\"\n"
        local r = loadWith(P)
        assert.are.same({"calm"}, dragonTags(r))
    end)

    it("replace_oldvalue_/replace_newvalue_ replace in place by value (first match)", function()
        local P = "name:name\tpatchOp:patch_op"
            .. "\treplace_oldvalue_drops:name|nil\treplace_newvalue_drops:name|nil\n"
            .. "dragon\tupdate\tsteel\tmithril\n"
        local r = loadWith(P)
        local c = findTsv(r, "Creature%.tsv$"); local byName, h = rowsByName(c)
        -- first steel -> mithril, position preserved
        assert.are.same({"mithril", "gold", "steel"}, asArray(readCell(byName.dragon, h, "drops")))
    end)

    it("replace_last_oldvalue_/newvalue_ replace the last match", function()
        local P = "name:name\tpatchOp:patch_op"
            .. "\treplace_last_oldvalue_drops:name|nil\treplace_last_newvalue_drops:name|nil\n"
            .. "dragon\tupdate\tsteel\tmithril\n"
        local r = loadWith(P)
        local c = findTsv(r, "Creature%.tsv$"); local byName, h = rowsByName(c)
        assert.are.same({"steel", "gold", "mithril"}, asArray(readCell(byName.dragon, h, "drops")))
    end)

    it("append_ merges entries into a map; remove_ drops keys", function()
        local P = "name:name\tpatchOp:patch_op"
            .. "\tappend_resistances:{name:uint}|nil\tremove_resistances:{name}|nil\n"
            .. "dragon\tupdate\tlightning=75,fire=50\tice\n"
        local r = loadWith(P)
        local c = findTsv(r, "Creature%.tsv$"); local byName, h = rowsByName(c)
        local res = readCell(byName.dragon, h, "resistances")
        assert.are.equal(50, res.fire, "fire overwritten to 50")
        assert.are.equal(75, res.lightning, "lightning added")
        assert.is_nil(res.ice, "ice removed")
    end)

    it("a direct column name wins over a merge-prefix interpretation", function()
        -- A parent column literally named `append_tags` binds directly; the
        -- merge-prefix form is the fall-back only when no direct match exists.
        local CREATURE2 =
            "name:name\ttags:{name}\tappend_tags:name\n"
            .. "wolf\t\"fang\"\tplain\n"
        local pkg = path_join(temp_dir, "collide")
        assert(lfs.mkdir(pkg))
        local FILES = FILES_HEADER
            .. "Creature.tsv\tCreature\t\t\t1\tCreatures\n"
            .. "CreaturePatch.tsv\tpatch\t\tCreature.tsv\t2\tPatches\n"
        local P = "name:name\tpatchOp:patch_op\tappend_tags:name|nil\n"
            .. "wolf\tupdate\tchanged\n"
        assert.is_true(file_util.writeFile(path_join(pkg, MANIFEST_FILENAME), MANIFEST))
        assert.is_true(file_util.writeFile(path_join(pkg, "files.tsv"), FILES))
        assert.is_true(file_util.writeFile(path_join(pkg, "Creature.tsv"), CREATURE2))
        assert.is_true(file_util.writeFile(path_join(pkg, "CreaturePatch.tsv"), P))
        local r = manifest_loader.processFiles({pkg}, badVal)
        local c = findTsv(r, "Creature%.tsv$"); local byName, h = rowsByName(c)
        -- The literal `append_tags` column was set directly; tags untouched.
        assert.are.equal("changed", readCell(byName.wolf, h, "append_tags"))
        assert.are.same({"fang"}, asArray(readCell(byName.wolf, h, "tags")))
    end)

    it("replace_oldvalue_ with a value not in the list is an error", function()
        local P = "name:name\tpatchOp:patch_op"
            .. "\treplace_oldvalue_drops:name|nil\treplace_newvalue_drops:name|nil\n"
            .. "dragon\tupdate\tplatinum\tmithril\n"
        loadWith(P)
        local joined = table.concat(log_messages, "\n")
        assert.is_true(joined:find("not found in the list", 1, true) ~= nil,
            "expected not-found error, got:\n" .. joined)
    end)

    it("an in-place pair with only one half is a header error", function()
        local P = "name:name\tpatchOp:patch_op\treplace_oldvalue_drops:name|nil\n"
            .. "dragon\tupdate\tsteel\n"
        loadWith(P)
        local joined = table.concat(log_messages, "\n")
        assert.is_true(joined:find("needs both", 1, true) ~= nil,
            "expected paired-column error, got:\n" .. joined)
    end)

    it("sub-record dotted-path columns patch an exploded field directly", function()
        -- No new mechanism: `stats.attack` is a normal (exploded) parent column,
        -- so the patch column binds to it directly; sibling stats.* are untouched.
        local STATS =
            "name:name\tstats.attack:integer\tstats.defense:integer\n"
            .. "dragon\t80\t40\n"
        local pkg = path_join(temp_dir, "subrec")
        assert(lfs.mkdir(pkg))
        local FILES = FILES_HEADER
            .. "Stats.tsv\tStats\t\t\t1\tStats\n"
            .. "StatsPatch.tsv\tpatch\t\tStats.tsv\t2\tPatches\n"
        local P = "name:name\tpatchOp:patch_op\tstats.attack:integer|nil\n"
            .. "dragon\tupdate\t99\n"
        assert.is_true(file_util.writeFile(path_join(pkg, MANIFEST_FILENAME), MANIFEST))
        assert.is_true(file_util.writeFile(path_join(pkg, "files.tsv"), FILES))
        assert.is_true(file_util.writeFile(path_join(pkg, "Stats.tsv"), STATS))
        assert.is_true(file_util.writeFile(path_join(pkg, "StatsPatch.tsv"), P))
        local r = manifest_loader.processFiles({pkg}, badVal)
        local s = findTsv(r, "Stats%.tsv$"); local byName, h = rowsByName(s)
        assert.are.equal(99, readCell(byName.dragon, h, "stats.attack"))
        assert.are.equal(40, readCell(byName.dragon, h, "stats.defense"))
    end)
end)
