-- relocatable_package_spec.lua
--
-- A Files.tsv declares its paths relative to ITSELF, which is what makes a package
-- RELOCATABLE: a small utility mod can be copied into a subdirectory of a bigger
-- package and keep working with its Files.tsv byte-for-byte unchanged. A package
-- that had to spell out its own location could not be moved without being edited.
--
-- This covers `fileName` and the `relativePath` descriptor columns (joinInto,
-- edgesFor), which name files by PATH and are matched exactly. The override-target
-- columns (patchOf / bulkPatchOf / schemaOverlayOf) resolve by BASENAME and were
-- already location-independent, so they are not part of this.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local lfs = require("lfs")
local file_util = require("infra.file_util")
local manifest_loader = require("loader.manifest_loader")
local error_reporting = require("infra.error_reporting")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local MANIFEST_FILENAME = "Manifest.transposed.tsv"

local function makeManifest(pkg_id)
    return table.concat({
        "package_id:package_id\t" .. pkg_id,
        "name:string\t" .. pkg_id .. " Package",
        "version:version\t0.1.0",
        "description:markdown\tTest package",
    }, "\n") .. "\n"
end

-- The utility mod's Files.tsv. Every path in it is written relative to itself —
-- it says nothing about where the mod lives. The SAME bytes are used standalone
-- and nested, which is the whole point.
local UTIL_FILES = table.concat({
    "fileName:filepath\ttypeName:type_spec\tsuperType:super_type\tbaseType:boolean"
        .. "\tloadOrder:number\tdescription:text\tjoinInto:filepath|nil\tjoinColumn:name|nil",
    "Files.tsv\tFiles\t\ttrue\t0\tThis file\t\t",
    "Util.tsv\tUtil\t\ttrue\t100\tUtility data\t\t",
    "Util.en.tsv\tUtilEN\t\tfalse\t101\tNames joined into Util.tsv\tUtil.tsv\tname",
}, "\n") .. "\n"

local UTIL_TSV = "name:name\tqty:integer\nhammer\t3\n"
local UTIL_EN_TSV = "name:name\tlabel:string\nhammer\tHammer\n"

-- Writes the utility mod's files (NOT its manifest) into `dir`.
local function writeUtilMod(dir)
    assert(file_util.writeFile(path_join(dir, "Files.tsv"), UTIL_FILES))
    assert(file_util.writeFile(path_join(dir, "Util.tsv"), UTIL_TSV))
    assert(file_util.writeFile(path_join(dir, "Util.en.tsv"), UTIL_EN_TSV))
end

describe("relocatable packages (Files.tsv paths are relative to the Files.tsv)", function()
    local temp_dir = ""
    local badVal
    local log_messages

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(), "relocatable_"
            .. tostring(os.time()) .. "_" .. tostring(math.random(1000000)))
        assert(lfs.mkdir(td))
        temp_dir = td
        log_messages = {}
        local log = function(_self, msg) table.insert(log_messages, msg) end
        badVal = error_reporting.badValGen(log)
        badVal.logger = error_reporting.nullLogger
    end)

    after_each(function()
        if temp_dir ~= "" then
            file_util.deleteTempDir(temp_dir)
            temp_dir = ""
        end
    end)

    local function findBySuffix(map, suffix)
        for path, v in pairs(map) do
            if path:sub(-#suffix) == suffix then return v, path end
        end
        return nil
    end

    -- joinInto is stored resolved, in the same key space as the loaded files, and
    -- the exporter matches it exactly against them — so checking the resolved value
    -- is checking the thing that actually has to line up. (The join itself is
    -- applied at EXPORT time, so it is not visible in the loaded dataset.)
    local function joinTargetOf(result, secondaryKey)
        return (result.joinMeta and result.joinMeta.lcFn2JoinInto or {})[secondaryKey]
    end

    it("loads the utility mod standalone", function()
        local pkg = path_join(temp_dir, "utilmod")
        assert(lfs.mkdir(pkg))
        assert(file_util.writeFile(path_join(pkg, MANIFEST_FILENAME), makeManifest("utilmod")))
        writeUtilMod(pkg)

        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        assert.is_not_nil(findBySuffix(result.tsv_files, "utilmod/Util.tsv"))
    end)

    it("loads the SAME utility mod copied, unedited, into a subdirectory", function()
        -- The bigger package. The utility mod is dropped into a plain subdirectory
        -- of it, with its Files.tsv untouched — no manifest, it is not its own
        -- package, just a folder of files the mod's own Files.tsv describes.
        local big = path_join(temp_dir, "bigmod")
        assert(lfs.mkdir(big))
        assert(file_util.writeFile(path_join(big, MANIFEST_FILENAME), makeManifest("bigmod")))
        assert(file_util.writeFile(path_join(big, "Files.tsv"),
            "fileName:filepath\ttypeName:type_spec\tsuperType:super_type\tbaseType:boolean"
            .. "\tloadOrder:number\tdescription:text\n"
            .. "Files.tsv\tFiles\t\ttrue\t0\tThis file\n"
            .. "Big.tsv\tBig\t\ttrue\t50\tBig data\n"))
        assert(file_util.writeFile(path_join(big, "Big.tsv"), "name:name\tqty:integer\nsword\t1\n"))

        local nested = path_join(big, "mods", "utilmod")
        assert(lfs.mkdir(path_join(big, "mods")))
        assert(lfs.mkdir(nested))
        writeUtilMod(nested)     -- byte-identical to the standalone copy

        local result = manifest_loader.processFiles({big}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))

        -- fileName resolved against the nested Files.tsv's own directory.
        local util = findBySuffix(result.tsv_files, "mods/utilmod/Util.tsv")
        assert.is_not_nil(util)
        assert.is_not_nil(findBySuffix(result.tsv_files, "bigmod/Big.tsv"))

        -- ...and so did joinInto: written as `Util.tsv`, it means the one INSIDE the
        -- mod. Were it resolved against the package root it would have missed (or,
        -- worse, hit a same-named file belonging to someone else).
        assert.equals("mods/utilmod/util.tsv",
            joinTargetOf(result, "mods/utilmod/util.en.tsv"))
    end)

    it("does not let a Files.tsv point outside its own directory with ..", function()
        -- `..` is not a valid `filepath` (isFileName rejects a trailing '.'), so a
        -- descriptor can only declare files at or below itself. A package that
        -- reached up into its parent would be assuming where it was installed —
        -- exactly what relocatability rules out. The bad cell is reported, and the
        -- loader carries on rather than crashing on it.
        local pkg = path_join(temp_dir, "pkg")
        assert(lfs.mkdir(pkg))
        assert(file_util.writeFile(path_join(pkg, MANIFEST_FILENAME), makeManifest("pkg")))
        assert(file_util.writeFile(path_join(pkg, "Files.tsv"),
            "fileName:filepath\ttypeName:type_spec\tsuperType:super_type\tbaseType:boolean"
            .. "\tloadOrder:number\tdescription:text\n"
            .. "Files.tsv\tFiles\t\ttrue\t0\tThis file\n"))
        assert(file_util.writeFile(path_join(pkg, "Shared.tsv"), UTIL_TSV))

        local sub = path_join(pkg, "sub")
        assert(lfs.mkdir(sub))
        assert(file_util.writeFile(path_join(sub, "Files.tsv"),
            "fileName:filepath\ttypeName:type_spec\tsuperType:super_type\tbaseType:boolean"
            .. "\tloadOrder:number\tdescription:text\n"
            .. "../Shared.tsv\tShared\t\ttrue\t100\tUp one level\n"))

        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        assert.is_true(badVal.errors > 0)
    end)

    it("still resolves a root Files.tsv's paths from the root", function()
        -- The unchanged, overwhelmingly common case: at a package root the prefix is
        -- empty, so a path like `sub/Deep.tsv` means exactly what it always did.
        local pkg = path_join(temp_dir, "pkg")
        assert(lfs.mkdir(pkg))
        assert(lfs.mkdir(path_join(pkg, "sub")))
        assert(file_util.writeFile(path_join(pkg, MANIFEST_FILENAME), makeManifest("pkg")))
        assert(file_util.writeFile(path_join(pkg, "Files.tsv"),
            "fileName:filepath\ttypeName:type_spec\tsuperType:super_type\tbaseType:boolean"
            .. "\tloadOrder:number\tdescription:text\n"
            .. "Files.tsv\tFiles\t\ttrue\t0\tThis file\n"
            .. "sub/Deep.tsv\tDeep\t\ttrue\t100\tIn a subdirectory\n"))
        assert(file_util.writeFile(path_join(pkg, "sub", "Deep.tsv"), UTIL_TSV))

        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        assert.is_not_nil(findBySuffix(result.tsv_files, "sub/Deep.tsv"))
    end)
end)
