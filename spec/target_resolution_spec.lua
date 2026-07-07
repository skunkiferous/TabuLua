-- target_resolution_spec.lua
-- Integration tests for override-target resolution at mod-ecosystem scale
-- (TODO/mod_ecosystem.md §4): deterministic resolution + warning when an
-- unqualified patchOf/schemaOverlayOf target basename is ambiguous (two
-- packages ship the same file name), and the package-qualified
-- 'package.id:Name.tsv' form that binds a target to one package's file.

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

local function manifestFor(id, load_after)
  local m = "package_id:package_id\t" .. id .. "\n"
    .. "name:string\tPackage " .. id .. "\n"
    .. "version:version\t1.0.0\n"
    .. "description:markdown\tTarget-resolution fixture package " .. id .. "\n"
  if load_after then
    m = m .. "load_after:{package_id}|nil\t" .. load_after .. "\n"
  end
  return m
end

local DATA_FILES_DESC = tsvRow("fileName:filepath", "typeName:type_spec", "superType:super_type",
    "baseType:boolean", "loadOrder:number", "description:text")
  .. tsvRow("Shared.tsv", "Shared", "", "true", "1", "A file name both base packages ship")

-- Both Core and ModA ship a `Shared.tsv` — the basename collision under test.
local CORE_SHARED = [[name:name	price:uint
sword	10
gem	5
]]
local MODA_SHARED_VALID = [[name:name	price:uint
sword	100
]]
-- Only parses when a schema overlay widens ModA's price column to uint|int.
local MODA_SHARED_NEGATIVE = [[name:name	price:uint
sword	100
debt	-5
]]

describe("override target resolution (ambiguity + package-qualified)", function()
  local temp_dir
  local log_messages
  local badVal

  before_each(function()
    local system_temp = file_util.getSystemTempDir()
    assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
    local td = path_join(system_temp, "target_resolution_test_" .. os.time() .. "_" .. os.clock())
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

  -- Writes the three packages and returns their directories in load order.
  -- `modaShared` picks ModA's Shared.tsv content; `modbFiles` is ModB's whole
  -- files.tsv; `modbData` maps ModB file names to contents.
  local function setupPackages(modaShared, modbFiles, modbData)
    local core_dir = path_join(temp_dir, "core")
    assert(lfs.mkdir(core_dir))
    assert.is_true(file_util.writeFile(path_join(core_dir, MANIFEST_FILENAME), manifestFor("Core")))
    assert.is_true(file_util.writeFile(path_join(core_dir, "files.tsv"), DATA_FILES_DESC))
    assert.is_true(file_util.writeFile(path_join(core_dir, "Shared.tsv"), CORE_SHARED))

    local moda_dir = path_join(temp_dir, "moda")
    assert(lfs.mkdir(moda_dir))
    assert.is_true(file_util.writeFile(path_join(moda_dir, MANIFEST_FILENAME), manifestFor("ModA")))
    assert.is_true(file_util.writeFile(path_join(moda_dir, "files.tsv"), DATA_FILES_DESC))
    assert.is_true(file_util.writeFile(path_join(moda_dir, "Shared.tsv"), modaShared))

    local modb_dir = path_join(temp_dir, "modb")
    assert(lfs.mkdir(modb_dir))
    assert.is_true(file_util.writeFile(path_join(modb_dir, MANIFEST_FILENAME),
      manifestFor("ModB", '"Core","ModA"')))
    assert.is_true(file_util.writeFile(path_join(modb_dir, "files.tsv"), modbFiles))
    for name, content in pairs(modbData) do
      assert.is_true(file_util.writeFile(path_join(modb_dir, name), content))
    end
    return core_dir, moda_dir, modb_dir
  end

  -- `override_target|nil` is the opt-in declared type that allows the
  -- 'package.id:' qualifier (plain `filepath|nil` stays valid for
  -- unqualified targets).
  local MODB_PATCH_HEADER = tsvRow("fileName:filepath", "typeName:type_spec",
    "superType:super_type", "baseType:boolean", "loadOrder:number",
    "patchOf:override_target|nil", "description:text")
  local PATCH_SWORD_42 = [[name:name	patchOp:patch_op	price:number|nil
sword	update	42
]]

  -- Finds a loaded dataset whose full name matches the Lua pattern, or nil.
  local function findFile(result, pattern)
    for file_name, tsv_data in pairs(result.tsv_files) do
      if file_name:match(pattern) then
        return tsv_data
      end
    end
    return nil
  end

  -- Returns the parsed price of the row with the given name.
  local function priceOf(tsv, name)
    for i = 2, #tsv do
      local row = tsv[i]
      if type(row) == "table" and row[1].parsed == name then
        return row[2].parsed
      end
    end
    return nil
  end

  it("resolves an ambiguous unqualified patch target deterministically", function()
    -- Two loaded files are named Shared.tsv; the unqualified target binds to
    -- the alphabetically-first full name (core/Shared.tsv) — with a warning —
    -- and the other file is untouched.
    local core_dir, moda_dir, modb_dir = setupPackages(MODA_SHARED_VALID,
      MODB_PATCH_HEADER
        .. tsvRow("SharedPatch.tsv", "patch", "", "false", "1", "Shared.tsv", "Unqualified patch"),
      {["SharedPatch.tsv"] = PATCH_SWORD_42})

    local result = manifest_loader.processFiles({core_dir, moda_dir, modb_dir}, badVal)
    assert.same({}, log_messages)
    assert.is_not_nil(result)
    assert.is_true(result.validationPassed)

    assert.equals(42, priceOf(findFile(result, "/core/Shared%.tsv$"), "sword"))
    assert.equals(100, priceOf(findFile(result, "/moda/Shared%.tsv$"), "sword"))
  end)

  it("binds a package-qualified patch target to the named package's file", function()
    local core_dir, moda_dir, modb_dir = setupPackages(MODA_SHARED_VALID,
      MODB_PATCH_HEADER
        .. tsvRow("SharedPatch.tsv", "patch", "", "false", "1", "ModA:Shared.tsv", "Qualified patch"),
      {["SharedPatch.tsv"] = PATCH_SWORD_42})

    local result = manifest_loader.processFiles({core_dir, moda_dir, modb_dir}, badVal)
    assert.same({}, log_messages)
    assert.is_not_nil(result)
    assert.is_true(result.validationPassed)

    -- The qualifier flips the winner: ModA's file is patched, Core's is not.
    assert.equals(10, priceOf(findFile(result, "/core/Shared%.tsv$"), "sword"))
    assert.equals(42, priceOf(findFile(result, "/moda/Shared%.tsv$"), "sword"))
  end)

  it("errors when the qualifier names an unknown package", function()
    local core_dir, moda_dir, modb_dir = setupPackages(MODA_SHARED_VALID,
      MODB_PATCH_HEADER
        .. tsvRow("SharedPatch.tsv", "patch", "", "false", "1", "NoSuchMod:Shared.tsv", "Bad qualifier"),
      {["SharedPatch.tsv"] = PATCH_SWORD_42})

    local result = manifest_loader.processFiles({core_dir, moda_dir, modb_dir}, badVal)
    assert.is_not_nil(result)
    assert.is_false(result.validationPassed)
    local found = false
    for _, msg in ipairs(log_messages) do
      if tostring(msg):find("is not loaded or owns no such file", 1, true) then
        found = true
        break
      end
    end
    assert.is_true(found, "expected the unknown-package qualifier error")
  end)

  it("binds a package-qualified schema overlay to the named package's file", function()
    -- ModA's Shared.tsv holds a negative price, which only parses when an
    -- overlay widens ITS price column. Qualifying the overlay to ModA proves
    -- per-file binding: the load is green, and Core keeps the narrow type.
    local MODB_OVERLAY_FILES = tsvRow("fileName:filepath", "typeName:type_spec",
        "superType:super_type", "baseType:boolean", "loadOrder:number",
        "schemaOverlayOf:override_target|nil", "description:text")
      .. tsvRow("SharedPolicy.tsv", "SchemaOverlay", "", "false", "1",
        "ModA:Shared.tsv", "Widen ModA's price only")
    local OVERLAY_WIDEN = [[column:name	widenTo:type_spec|nil
price	uint|int
]]
    local core_dir, moda_dir, modb_dir = setupPackages(MODA_SHARED_NEGATIVE,
      MODB_OVERLAY_FILES, {["SharedPolicy.tsv"] = OVERLAY_WIDEN})

    local result = manifest_loader.processFiles({core_dir, moda_dir, modb_dir}, badVal)
    assert.same({}, log_messages)
    assert.is_not_nil(result)
    assert.is_true(result.validationPassed)
    assert.equals(-5, priceOf(findFile(result, "/moda/Shared%.tsv$"), "debt"))
  end)

  it("does not overlay a same-basename file in another package", function()
    -- The counter-case: the overlay qualified to CORE must no longer reach
    -- ModA's file (pre-§4 behaviour overlaid every same-basename file), so
    -- ModA's negative price fails to parse and the load reports errors.
    local MODB_OVERLAY_FILES = tsvRow("fileName:filepath", "typeName:type_spec",
        "superType:super_type", "baseType:boolean", "loadOrder:number",
        "schemaOverlayOf:override_target|nil", "description:text")
      .. tsvRow("SharedPolicy.tsv", "SchemaOverlay", "", "false", "1",
        "Core:Shared.tsv", "Widen Core's price only")
    local OVERLAY_WIDEN = [[column:name	widenTo:type_spec|nil
price	uint|int
]]
    local core_dir, moda_dir, modb_dir = setupPackages(MODA_SHARED_NEGATIVE,
      MODB_OVERLAY_FILES, {["SharedPolicy.tsv"] = OVERLAY_WIDEN})

    local _result = manifest_loader.processFiles({core_dir, moda_dir, modb_dir}, badVal)
    assert.is_true(#log_messages > 0,
      "ModA's negative price must fail without the overlay reaching its file")
  end)
end)
