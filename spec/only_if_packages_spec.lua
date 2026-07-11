-- only_if_packages_spec.lua
-- Integration tests for the `onlyIfPackages` Files.tsv column — conditional
-- file loading for optional mod compatibility (TODO/mod_ecosystem.md §2.1) —
-- and for `packages` inside a bulk-patch `where` selector (§2.2).

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local file_util = require("infra.file_util")
local manifest_loader = require("loader.manifest_loader")
local manifest_info = require("loader.manifest_info")
local error_reporting = require("infra.error_reporting")

-- Simple path join function
local function path_join(...)
  return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- Returns a "badVal" object that stores errors in the given table
local function mockBadVal(log_messages)
  local log = function(_self, msg) table.insert(log_messages, msg) end
  local badVal = error_reporting.badValGen(log)
  badVal.source_name = "test"
  badVal.line_no = 1
  return badVal
end

local MANIFEST_FILENAME = "Manifest.transposed.tsv"

-- Joins one TSV row's cells with tabs (avoids hand-counted tab errors).
local function tsvRow(...)
  return table.concat({...}, "\t") .. "\n"
end

-- The base package: one data file the mod will conditionally patch.
local CORE_MANIFEST = [[package_id:package_id	Core
name:string	Core Package
version:version	1.0.0
description:markdown	The base package
]]
local CORE_FILES = tsvRow("fileName:filepath", "typeName:type_spec", "superType:super_type",
    "baseType:boolean", "loadOrder:number", "description:text")
  .. tsvRow("Item.tsv", "Item", "", "true", "1", "Core items")
local CORE_ITEMS = [[name:name	price:number
sword	10
shield	5
]]

-- The mod: every row is gated. The `load_after` + `onlyIfPackages` pairing is
-- the documented optional-compatibility idiom — ordering half + presence half.
local MOD_MANIFEST = [[package_id:package_id	Mod
name:string	Compat Mod
version:version	1.0.0
description:markdown	Ships optional compatibility with Core
load_after:{package_id}|nil	"Core"
]]
local MOD_FILES = tsvRow("fileName:filepath", "typeName:type_spec", "superType:super_type",
    "baseType:boolean", "loadOrder:number", "patchOf:filepath|nil", "bulkPatchOf:filepath|nil",
    "onlyIfPackages:{package_id}|nil", "description:text")
  .. tsvRow("ItemPatch.tsv", "patch", "", "false", "1", "Item.tsv", "",
    '"Core"', "Patches core items when Core is present")
  .. tsvRow("ItemBulk.tsv", "bulk_patch", "", "false", "2", "", "Item.tsv",
    '"Core"', "Bulk rule whose where selector reads packages")
  .. tsvRow("Extra.tsv", "Extra", "", "true", "3", "", "",
    '"Core"', "Conditional data file")
  .. tsvRow("Ghost.tsv", "Ghost", "", "true", "4", "", "",
    '"NotInstalled"', "Gated on an absent package; file does not exist on disk")
  .. tsvRow("Both.tsv", "Both", "", "true", "5", "", "",
    '"Core","OtherMod"', "Needs two packages (AND semantics)")
local MOD_PATCH = [[name:name	patchOp:patch_op	price:number|nil
sword	update	42
]]
local MOD_BULK = [[ruleName:name	patchOp:patch_op	where:expression	price:expression|nil
core_present_bump	update	=packages['Core'] ~= nil	=row.price + 1
]]
local MOD_EXTRA = [[name:name	bonus:number
extra1	7
]]
local MOD_BOTH = [[name:name	x:number
b1	1
]]

describe("onlyIfPackages", function()
  local temp_dir
  local log_messages
  local badVal
  local core_dir
  local mod_dir

  before_each(function()
    local system_temp = file_util.getSystemTempDir()
    assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
    local td = path_join(system_temp, "only_if_packages_test_" .. os.time() .. "_" .. os.clock())
    assert(lfs.mkdir(td))
    temp_dir = td
    log_messages = {}
    badVal = mockBadVal(log_messages)
    badVal.logger = error_reporting.nullLogger

    core_dir = path_join(temp_dir, "core")
    assert(lfs.mkdir(core_dir))
    assert.is_true(file_util.writeFile(path_join(core_dir, MANIFEST_FILENAME), CORE_MANIFEST))
    assert.is_true(file_util.writeFile(path_join(core_dir, "files.tsv"), CORE_FILES))
    assert.is_true(file_util.writeFile(path_join(core_dir, "Item.tsv"), CORE_ITEMS))

    mod_dir = path_join(temp_dir, "mod")
    assert(lfs.mkdir(mod_dir))
    assert.is_true(file_util.writeFile(path_join(mod_dir, MANIFEST_FILENAME), MOD_MANIFEST))
    assert.is_true(file_util.writeFile(path_join(mod_dir, "files.tsv"), MOD_FILES))
    assert.is_true(file_util.writeFile(path_join(mod_dir, "ItemPatch.tsv"), MOD_PATCH))
    assert.is_true(file_util.writeFile(path_join(mod_dir, "ItemBulk.tsv"), MOD_BULK))
    assert.is_true(file_util.writeFile(path_join(mod_dir, "Extra.tsv"), MOD_EXTRA))
    assert.is_true(file_util.writeFile(path_join(mod_dir, "Both.tsv"), MOD_BOTH))
    -- Ghost.tsv is deliberately NOT written: its row is gated on an absent
    -- package, so the on-disk existence check must not fire for it.
  end)

  after_each(function()
    if temp_dir then
      local td = temp_dir
      temp_dir = nil
      file_util.deleteTempDir(td)
    end
  end)

  -- Finds a loaded dataset by trailing file name, or nil.
  local function findFile(result, suffix)
    for file_name, tsv_data in pairs(result.tsv_files) do
      if file_name:match(suffix .. "$") then
        return tsv_data
      end
    end
    return nil
  end

  -- Returns the parsed price of the item row with the given name.
  local function priceOf(items, name)
    for i = 2, #items do
      local row = items[i]
      if type(row) == "table" and row[1].parsed == name then
        return row[2].parsed
      end
    end
    return nil
  end

  it("applies gated compat files when the required package is loaded", function()
    local result = manifest_loader.processFiles({core_dir, mod_dir}, badVal)
    assert.same({}, log_messages)
    assert.is_not_nil(result)
    assert.is_true(result.validationPassed)

    -- The gated patch applied (sword 10 -> 42), then the gated bulk rule —
    -- whose `where` selector reads `packages` — bumped every row by 1.
    local items = findFile(result, "Item%.tsv")
    assert.is_not_nil(items, "Item.tsv should be loaded")
    assert.equals(43, priceOf(items, "sword"))
    assert.equals(6, priceOf(items, "shield"))

    -- The gated data file loaded like any other.
    assert.is_not_nil(findFile(result, "Extra%.tsv"), "Extra.tsv should be loaded")

    -- AND semantics: Both.tsv requires Core AND OtherMod; OtherMod is not
    -- loaded, so the file is skipped even though it exists on disk.
    assert.is_nil(findFile(result, "Both%.tsv"), "Both.tsv should be skipped")

    -- Ghost.tsv is gated on an absent package and does not exist on disk:
    -- no "does not exist" error was reported (log_messages is empty above).
    assert.is_nil(findFile(result, "Ghost%.tsv"))
  end)

  it("quietly skips gated compat files when the required package is absent", function()
    -- THE optional-compatibility scenario: the mod loads standalone; its
    -- patch/bulk files target Core's data but are gated on Core, so instead
    -- of a hard "patch target not found" error the whole compat layer
    -- deactivates and the load stays green.
    local result = manifest_loader.processFiles({mod_dir}, badVal)
    assert.same({}, log_messages)
    assert.is_not_nil(result)
    assert.is_true(result.validationPassed)
    assert.same({"Mod"}, result.package_order)

    assert.is_nil(findFile(result, "Item%.tsv"))
    assert.is_nil(findFile(result, "ItemPatch%.tsv"))
    assert.is_nil(findFile(result, "ItemBulk%.tsv"))
    assert.is_nil(findFile(result, "Extra%.tsv"))
    assert.is_nil(findFile(result, "Both%.tsv"))
  end)

  it("collects skipped gate ids and flags the unknown ones (typo heuristic)", function()
    -- Ghost.tsv is gated on "NotInstalled" and Both.tsv (partly) on
    -- "OtherMod"; neither id is a loaded package or named by any manifest,
    -- so both are heuristic suspects (the --check-conflicts gate check).
    local result = manifest_loader.processFiles({core_dir, mod_dir}, badVal)
    assert.is_not_nil(result)
    local skipped = result.joinMeta.skippedGates
    assert.is_not_nil(skipped, "skippedGates should ride joinMeta")
    assert.is_not_nil(skipped["NotInstalled"])
    assert.is_not_nil(skipped["OtherMod"])

    local suspects = manifest_info.unknownGateIds(result.packages, skipped)
    assert.equals(2, #suspects)
    assert.equals("NotInstalled", suspects[1].id)
    assert.is_truthy(suspects[1].files[1]:match("Ghost%.tsv$"))
    assert.equals("OtherMod", suspects[2].id)
    assert.is_truthy(suspects[2].files[1]:match("Both%.tsv$"))
  end)
end)

describe("manifest_info.unknownGateIds", function()
  it("excludes ids any manifest names, and suggests near-misses", function()
    -- "Known" = loaded ids + everything mentioned in dependencies /
    -- load_after / conflicts: an id someone references is a real (merely
    -- absent) mod, not a typo.
    local packages = {
      ["Core"] = {load_after = {"OptionalMod"}},
      ["Mod"] = {
        dependencies = {{package_id = "Core", req_op = ">=", req_version = "1.0.0"}},
        conflicts = {"BadMod"},
      },
    }
    local skipped = {
      ["OptionalMod"] = {"a.tsv"},       -- known via load_after: not flagged
      ["BadMod"] = {"b.tsv"},            -- known via conflicts: not flagged
      ["core"] = {"c.tsv"},              -- case slip of a loaded id
      ["Croe"] = {"e.tsv"},              -- transposition typo of a loaded id
      ["totally.wrong"] = {"d.tsv", "a.tsv"},
    }
    local suspects = manifest_info.unknownGateIds(packages, skipped)
    assert.equals(3, #suspects)
    assert.equals("Croe", suspects[1].id)
    assert.equals("Core", suspects[1].suggest)
    assert.equals("core", suspects[2].id)
    assert.equals("Core", suspects[2].suggest)
    assert.equals("totally.wrong", suspects[3].id)
    assert.is_nil(suspects[3].suggest)
    assert.same({"a.tsv", "d.tsv"}, suspects[3].files)
  end)

  it("returns an empty list when nothing was skipped", function()
    assert.same({}, manifest_info.unknownGateIds({["Core"] = {}}, nil))
    assert.same({}, manifest_info.unknownGateIds({["Core"] = {}}, {}))
  end)
end)

describe("manifest_info.unknownVariants", function()
  -- "Known" = variant_group values + every Files.tsv `variant` mention.
  local packages = {
    ["Core"] = {variant_groups = {{"lang", {"en", "fr"}, "en"}}},
  }
  local fileVariants = {ios = true, android = true}  -- used only by file selection

  it("excludes group + file variants, and suggests near-misses", function()
    local provided = {"en", "ios", "androd", "totally-wrong"}
    local suspects = manifest_info.unknownVariants(packages, provided, fileVariants)
    -- "en" (group) and "ios" (file) are known; the rest are flagged.
    assert.equals(2, #suspects)
    -- Sorted by name: androd, totally-wrong
    assert.equals("androd", suspects[1].name)
    assert.equals("android", suspects[1].suggest)  -- near a file variant
    assert.equals("totally-wrong", suspects[2].name)
    assert.is_nil(suspects[2].suggest)             -- nothing close enough
  end)

  it("flags a case slip (selection is case-sensitive) and suggests the real casing", function()
    local suspects = manifest_info.unknownVariants(packages, {"EN"}, fileVariants)
    assert.equals(1, #suspects)
    assert.equals("EN", suspects[1].name)
    assert.equals("en", suspects[1].suggest)
  end)

  it("accepts a set of provided variants as well as a sequence", function()
    local suspects = manifest_info.unknownVariants(packages, {fr = true, ios = true}, fileVariants)
    assert.same({}, suspects)
  end)

  it("returns an empty list when no variants were provided", function()
    assert.same({}, manifest_info.unknownVariants(packages, nil, fileVariants))
    assert.same({}, manifest_info.unknownVariants(packages, {}, fileVariants))
  end)
end)
