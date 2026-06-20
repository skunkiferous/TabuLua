-- schema_overlay_integration_spec.lua
-- End-to-end tests for schema overlays:
-- load a package whose Files.tsv declares a SchemaOverlay file
-- targeting a data file, and verify the overlay's widenTo / newDefault /
-- suppressValidator effects on the loaded data and on validation.

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
description:markdown	Schema overlay integration test
]]

local function colIdx(header, name)
    local col = header[name]
    return col and col.idx or nil
end

local function rowsByName(tsv_file)
    local header = tsv_file[1]
    local nameIdx = colIdx(header, "name")
    assert.is_not_nil(nameIdx, "name column not found in header")
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
    if not cell then return nil end
    return cell.parsed
end

local function findTsv(result, pattern)
    for fn, tsv in pairs(result.tsv_files) do
        if fn:match(pattern) then return tsv end
    end
    return nil
end

local function writeAll(pkg_dir, filesTsv, dataFiles)
    assert.is_true(file_util.writeFile(
        path_join(pkg_dir, MANIFEST_FILENAME), MANIFEST))
    assert.is_true(file_util.writeFile(
        path_join(pkg_dir, "files.tsv"), filesTsv))
    for fname, content in pairs(dataFiles) do
        assert.is_true(file_util.writeFile(
            path_join(pkg_dir, fname), content))
    end
end

-- Files.tsv header carrying the columns these tests need (core + overlay +
-- validators). Each row is appended by the individual test.
local FILES_HEADER =
    "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
    .. "\tschemaOverlayOf:filepath|nil\tfileValidators:{validator_spec}|nil"
    .. "\tloadOrder:number\tdescription:text\n"

describe("schema_overlay integration", function()
    local temp_dir
    local log_messages
    local badVal

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "")
        local td = path_join(system_temp, "schema_overlay_test_" .. os.time()
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

    it("widenTo lets a value the parent type would reject parse", function()
        local pkg = path_join(temp_dir, "widen")
        assert(lfs.mkdir(pkg))

        local FILES = FILES_HEADER
            .. "Item.tsv\tItem\t\t\t\t1\tItems\n"
            .. "ItemSchema.tsv\tSchemaOverlay\t\tItem.tsv\t\t2\tWiden price\n"

        -- price:uint would reject a negative value; the overlay widens it to number.
        local ITEM = "name:name\tprice:uint\n"
            .. "sword\t100\n"
            .. "debt\t-5\n"
        local OVERLAY = "column:name\twidenTo:type_spec|nil\n"
            .. "price\tnumber\n"

        writeAll(pkg, FILES, {["Item.tsv"] = ITEM, ["ItemSchema.tsv"] = OVERLAY})

        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        assert.is_true(result.validationPassed,
            "load should pass; widened column accepts -5")

        local item = findTsv(result, "Item%.tsv$")
        assert.is_not_nil(item, "Item.tsv not loaded")
        local byName, header = rowsByName(item)
        assert.are.equal(-5, readCell(byName.debt, header, "price"))
        assert.are.equal(100, readCell(byName.sword, header, "price"))
        -- The widening is a load-time view: the effective `type` is widened
        -- (so cells parse against it), but the declared `type_spec` stays as
        -- the file authored it, so the reformatter round-trips the source.
        assert.are.equal("number", header["price"].type)
        assert.are.equal("uint", header["price"].type_spec)
    end)

    it("newDefault overrides the default used for empty cells", function()
        local pkg = path_join(temp_dir, "default")
        assert(lfs.mkdir(pkg))

        local FILES = FILES_HEADER
            .. "Spell.tsv\tSpell\t\t\t\t1\tSpells\n"
            .. "SpellSchema.tsv\tSchemaOverlay\t\tSpell.tsv\t\t2\tDefault cooldown\n"

        -- cooldown has no default in the parent; the overlay supplies 3.0.
        local SPELL = "name:name\tcooldown:number\n"
            .. "fireball\t5\n"
            .. "heal\t\n"
        local OVERLAY = "column:name\tnewDefault:string|nil\n"
            .. "cooldown\t3.0\n"

        writeAll(pkg, FILES, {["Spell.tsv"] = SPELL, ["SpellSchema.tsv"] = OVERLAY})

        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)

        local spell = findTsv(result, "Spell%.tsv$")
        assert.is_not_nil(spell, "Spell.tsv not loaded")
        local byName, header = rowsByName(spell)
        assert.are.equal(5, readCell(byName.fireball, header, "cooldown"))
        assert.are.equal(3.0, readCell(byName.heal, header, "cooldown"),
            "empty cooldown should use the overlaid default 3.0")
    end)

    it("rejects a widenTo that narrows the parent type", function()
        local pkg = path_join(temp_dir, "narrow")
        assert(lfs.mkdir(pkg))

        local FILES = FILES_HEADER
            .. "Item.tsv\tItem\t\t\t\t1\tItems\n"
            .. "ItemSchema.tsv\tSchemaOverlay\t\tItem.tsv\t\t2\tNarrow price\n"

        local ITEM = "name:name\tprice:number\n"
            .. "sword\t100\n"
        -- number -> uint is a narrowing, not a widening: must be rejected.
        local OVERLAY = "column:name\twidenTo:type_spec|nil\n"
            .. "price\tuint\n"

        writeAll(pkg, FILES, {["Item.tsv"] = ITEM, ["ItemSchema.tsv"] = OVERLAY})

        manifest_loader.processFiles({pkg}, badVal)
        local joined = table.concat(log_messages, "\n")
        assert.is_true(joined:find("narrowing is not allowed", 1, true) ~= nil,
            "expected a narrowing error, got:\n" .. joined)
    end)

    it("suppressValidator=none removes a failing parent validator", function()
        local pkg = path_join(temp_dir, "suppress")
        assert(lfs.mkdir(pkg))

        -- Item.tsv carries a file validator that always fails (#rows > 100 on a
        -- 2-row file). The overlay removes it, so the load passes.
        local FILES = FILES_HEADER
            .. "Item.tsv\tItem\t\t\t\"#rows > 100\"\t1\tItems\n"
            .. "ItemSchema.tsv\tSchemaOverlay\t\tItem.tsv\t\t2\tSilence check\n"

        local ITEM = "name:name\tprice:uint\n"
            .. "sword\t100\n"
            .. "shield\t25\n"
        local OVERLAY = "column:name\tsuppressValidator:expression|nil\tvalidatorLevel:overlay_level|nil\n"
            .. "price\t#rows > 100\tnone\n"

        writeAll(pkg, FILES, {["Item.tsv"] = ITEM, ["ItemSchema.tsv"] = OVERLAY})

        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        assert.is_true(result.validationPassed,
            "validator should have been suppressed; load expected to pass.\n"
            .. table.concat(log_messages, "\n"))
    end)

    it("without the overlay, the same validator fails (control)", function()
        local pkg = path_join(temp_dir, "control")
        assert(lfs.mkdir(pkg))

        local FILES = FILES_HEADER
            .. "Item.tsv\tItem\t\t\t\"#rows > 100\"\t1\tItems\n"

        local ITEM = "name:name\tprice:uint\n"
            .. "sword\t100\n"
            .. "shield\t25\n"

        writeAll(pkg, FILES, {["Item.tsv"] = ITEM})

        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        assert.is_false(result.validationPassed,
            "control: validator should fail without an overlay")
    end)
end)
