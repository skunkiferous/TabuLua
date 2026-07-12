-- format_report_spec.lua
-- Tests for `--list-columns` (loader/format_report.lua) and for the mandatory /
-- expected split of Files.tsv's core columns (loader/files_desc.lua).
--
-- The two belong together: an ABSENT OPTIONAL column is deliberately never
-- reported (warning per unused feature per Files.tsv on every load would be
-- noise), which is exactly why --list-columns has to exist — it is the only way
-- a user discovers a column a newer release added. And a MANDATORY core column
-- (fileName / loadOrder) is the opposite case: without it nothing in the package
-- can be declared at all, so it is an error, not a warning.

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
local format_report = require("loader.format_report")
local files_desc = require("loader.files_desc")
local manifest_info = require("loader.manifest_info")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- A Files.tsv header carrying the core columns plus ONE optional column
-- (joinInto), so a report over this package has both a used and many unused
-- optional columns to talk about.
local FILES_HEADER =
    "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
    .. "\tbaseType:boolean\tloadOrder:number\tdescription:text\tjoinInto:filepath|nil\n"

local ITEM = "name:name\tprice:uint\n" .. "sword\t100\n"

-- Writes a minimal one-file package. `header` overrides FILES_HEADER, and
-- `manifestExtra` appends manifest rows, so a test can vary exactly one thing.
local function writePkg(root, pkgId, header, manifestExtra)
    local dir = path_join(root, "pkg")
    assert(lfs.mkdir(dir))
    local manifest = "package_id:package_id\t" .. pkgId .. "\n"
        .. "name:string\t" .. pkgId .. " Package\n"
        .. "version:version\t0.1.0\n"
        .. "description:markdown\tFormat report test\n"
        .. (manifestExtra or "")
    assert.is_true(file_util.writeFile(path_join(dir, "Manifest.transposed.tsv"), manifest))
    assert.is_true(file_util.writeFile(path_join(dir, "Files.tsv"),
        (header or FILES_HEADER)
        .. "Item.tsv\tItem\t\ttrue\t100\tItems\t\n"
        .. "Files.tsv\tFiles\t\ttrue\t0\tThis file\t\n"))
    assert.is_true(file_util.writeFile(path_join(dir, "Item.tsv"), ITEM))
    return dir
end

describe("format_report (--list-columns)", function()
    local temp_dir, badVal

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(),
            "fmtreport_" .. os.time() .. "_" .. math.random(1, 1e6))
        assert(lfs.mkdir(td))
        temp_dir = td
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

    local function reportFor(dir)
        local result = manifest_loader.processFiles({dir}, badVal)
        assert.is_not_nil(result)
        return format_report.report(result.packages, result.joinMeta)
    end

    it("marks a declared optional column used and an undeclared one unused", function()
        local r = reportFor(writePkg(temp_dir, "test.fmt"))
        -- joinInto IS in the header; edgesFor is not.
        assert.is_truthy(r:find("[x]  joinInto", 1, true), "report:\n" .. r)
        assert.is_truthy(r:find("[ ]  edgesFor", 1, true), "report:\n" .. r)
    end)

    it("annotates an unused column with the release that added it", function()
        local r = reportFor(writePkg(temp_dir, "test.fmt"))
        -- ifMissing arrived in 0.30.0 and this package does not declare it.
        local line = r:match("[^\n]*ifMissing[^\n]*")
        assert.is_truthy(line, "report:\n" .. r)
        assert.is_truthy(line:find("0.30.0", 1, true), "line: " .. line)
    end)

    it("lists the newest unused column/field first in the summary", function()
        local r = reportFor(writePkg(temp_dir, "test.fmt"))
        local summary = r:match("available but unused.-$")
        assert.is_truthy(summary, "report:\n" .. r)
        -- asset_files (0.31.0) must precede ifMissing (0.30.0), which must
        -- precede anything older — that ordering IS the feature.
        local newer = summary:find("asset_files", 1, true)
        local older = summary:find("ifMissing", 1, true)
        assert.is_truthy(newer and older, "summary:\n" .. summary)
        assert.is_true(newer < older, "newest-first ordering broken:\n" .. summary)
    end)

    it("counts a manifest field as used only when the package sets it", function()
        -- The header must spell the field's declared type exactly, as any real
        -- manifest does (loadManifestFile rejects a mismatch).
        local r = reportFor(writePkg(temp_dir, "test.fmt", nil,
            "conflicts:{package_id}|nil\t\"other.pkg\"\n"))
        assert.is_truthy(r:find("[x]  conflicts", 1, true), "report:\n" .. r)
        -- Declared by no manifest here.
        assert.is_truthy(r:find("[ ]  asset_files", 1, true), "report:\n" .. r)
    end)

    it("reports every optional column as unused for a bare package", function()
        -- A Files.tsv with ONLY the core columns: every feature column is
        -- available-but-unused, which is precisely the case this report serves.
        local bare = "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
            .. "\tbaseType:boolean\tloadOrder:number\tdescription:text\n"
        local dir = path_join(temp_dir, "pkg")
        assert(lfs.mkdir(dir))
        assert.is_true(file_util.writeFile(path_join(dir, "Manifest.transposed.tsv"),
            "package_id:package_id\ttest.bare\nname:string\tBare\n"
            .. "version:version\t0.1.0\ndescription:markdown\tBare\n"))
        assert.is_true(file_util.writeFile(path_join(dir, "Files.tsv"),
            bare .. "Item.tsv\tItem\t\ttrue\t100\tItems\n"
            .. "Files.tsv\tFiles\t\ttrue\t0\tThis file\n"))
        assert.is_true(file_util.writeFile(path_join(dir, "Item.tsv"), ITEM))
        local r = reportFor(dir)
        assert.is_truthy(r:find("[ ]  joinInto", 1, true), "report:\n" .. r)
        assert.is_truthy(r:find("[ ]  patchOf", 1, true), "report:\n" .. r)
        assert.is_falsy(r:find("[x]  joinInto", 1, true), "report:\n" .. r)
    end)

    it("survives being called with no packages loaded", function()
        local r = format_report.report(nil, nil)
        assert.is_truthy(r:find("Files.tsv columns (0 descriptors loaded)", 1, true))
        assert.is_truthy(r:find("available but unused", 1, true))
    end)
end)

describe("format inventory sources", function()
    it("classifies fileName/loadOrder as required core columns", function()
        local byName = {}
        for _, col in ipairs(files_desc.coreColumns()) do
            byName[col.name] = col
        end
        assert.are.equal("required", byName.fileName.status)
        assert.are.equal("required", byName.loadOrder.status)
        assert.are.equal("expected", byName.typeName.status)
        -- description is pure user metadata: its absence is not even a warning.
        assert.are.equal("optional", byName.description.status)
    end)

    it("marks only the non-|nil manifest fields required", function()
        local byName = {}
        for _, f in ipairs(manifest_info.manifestFields()) do
            byName[f.name] = f
        end
        assert.is_true(byName.package_id.required)
        assert.is_true(byName.version.required)
        assert.is_false(byName.asset_files.required)
        assert.is_false(byName.conflicts.required)
        -- `since` is what lets the report rank unused fields newest-first.
        assert.are.equal("0.30.0", byName.conflicts.since)
    end)
end)

describe("Files.tsv mandatory core columns", function()
    local temp_dir, badVal, warnings

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(),
            "mandcol_" .. os.time() .. "_" .. math.random(1, 1e6))
        assert(lfs.mkdir(td))
        temp_dir = td
        warnings = {}
        badVal = error_reporting.badValGen()
        badVal.logger = {
            warn = function(_, msg) warnings[#warnings + 1] = tostring(msg) end,
            error = function() end, info = function() end, debug = function() end,
        }
    end)

    after_each(function()
        if temp_dir then
            local td = temp_dir
            temp_dir = nil
            file_util.deleteTempDir(td)
        end
    end)

    -- Without loadOrder the row loop declares NOTHING (see processFilesDesc's
    -- `if fileNameIdx and loadOrderIdx` guard), so the package silently loads as
    -- empty. That has to fail the run, not warn.
    it("errors when loadOrder is missing", function()
        local header = "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
            .. "\tbaseType:boolean\tdescription:text\n"
        local dir = path_join(temp_dir, "pkg")
        assert(lfs.mkdir(dir))
        assert.is_true(file_util.writeFile(path_join(dir, "Manifest.transposed.tsv"),
            "package_id:package_id\ttest.noorder\nname:string\tNoOrder\n"
            .. "version:version\t0.1.0\ndescription:markdown\tNo loadOrder\n"))
        assert.is_true(file_util.writeFile(path_join(dir, "Files.tsv"),
            header .. "Item.tsv\tItem\t\ttrue\tItems\n"))
        assert.is_true(file_util.writeFile(path_join(dir, "Item.tsv"), ITEM))
        local before = badVal.errors
        manifest_loader.processFiles({dir}, badVal)
        assert.is_true(badVal.errors > before,
            "a missing loadOrder must be an error, not a warning")
    end)

    -- superType is tolerated (each row simply reads it as nil), so it warns.
    it("only warns when superType is missing", function()
        local header = "fileName:filepath\ttypeName:type_spec\tbaseType:boolean"
            .. "\tloadOrder:number\tdescription:text\n"
        local dir = path_join(temp_dir, "pkg")
        assert(lfs.mkdir(dir))
        assert.is_true(file_util.writeFile(path_join(dir, "Manifest.transposed.tsv"),
            "package_id:package_id\ttest.nosuper\nname:string\tNoSuper\n"
            .. "version:version\t0.1.0\ndescription:markdown\tNo superType\n"))
        assert.is_true(file_util.writeFile(path_join(dir, "Files.tsv"),
            header .. "Item.tsv\tItem\ttrue\t100\tItems\n"
            .. "Files.tsv\tFiles\ttrue\t0\tThis file\n"))
        assert.is_true(file_util.writeFile(path_join(dir, "Item.tsv"), ITEM))
        local before = badVal.errors
        manifest_loader.processFiles({dir}, badVal)
        assert.are.equal(before, badVal.errors,
            "a missing superType must not fail the load")
        local found = false
        for _, w in ipairs(warnings) do
            if w:find("Missing column 'superType'", 1, true) then found = true end
        end
        assert.is_true(found, "expected a superType warning; got:\n"
            .. table.concat(warnings, "\n"))
    end)

    -- The whole point of the split: an absent OPTIONAL column says nothing.
    it("says nothing about absent optional columns", function()
        local bare = "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
            .. "\tbaseType:boolean\tloadOrder:number\tdescription:text\n"
        local dir = path_join(temp_dir, "pkg")
        assert(lfs.mkdir(dir))
        assert.is_true(file_util.writeFile(path_join(dir, "Manifest.transposed.tsv"),
            "package_id:package_id\ttest.quiet\nname:string\tQuiet\n"
            .. "version:version\t0.1.0\ndescription:markdown\tQuiet\n"))
        assert.is_true(file_util.writeFile(path_join(dir, "Files.tsv"),
            bare .. "Item.tsv\tItem\t\ttrue\t100\tItems\n"
            .. "Files.tsv\tFiles\t\ttrue\t0\tThis file\n"))
        assert.is_true(file_util.writeFile(path_join(dir, "Item.tsv"), ITEM))
        manifest_loader.processFiles({dir}, badVal)
        for _, w in ipairs(warnings) do
            assert.is_falsy(w:find("joinInto", 1, true),
                "an unused optional column must not warn: " .. w)
            assert.is_falsy(w:find("edgesFor", 1, true),
                "an unused optional column must not warn: " .. w)
        end
    end)
end)
