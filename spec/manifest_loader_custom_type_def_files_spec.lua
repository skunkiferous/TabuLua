-- manifest_loader_custom_type_def_files_spec.lua
-- Tests for custom type definition files:
-- when a file's typeName is "custom_type_def" or a type that extends it,
-- each data row is registered as a custom type via parsers.registerTypesFromSpec.

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local lfs = require("lfs")
local file_util = require("file_util")
local manifest_loader = require("manifest_loader")
local parsers = require("parsers")
local error_reporting = require("error_reporting")

-- Simple path join helper
local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- Returns a "badVal" that stores errors in the given table
local function mockBadVal(log_messages)
    local log = function(_self, msg) table.insert(log_messages, msg) end
    local badVal = error_reporting.badValGen(log)
    badVal.source_name = "test"
    badVal.line_no = 1
    return badVal
end

-- Manifest filename constant
local MANIFEST_FILENAME = "Manifest.transposed.tsv"

-- Standard Files.tsv header (tab-separated)
local FILES_HEADER = table.concat({
    "fileName:string", "typeName:type_spec", "superType:super_type",
    "baseType:boolean", "publishContext:name|nil", "publishColumn:name|nil",
    "loadOrder:number", "description:text"
}, "\t") .. "\n"

-- Build a minimal manifest for the given package id
local function makeManifest(pkg_id)
    return table.concat({
        "package_id:package_id\t" .. pkg_id,
        "name:string\t" .. pkg_id .. " Package",
        "version:version\t0.1.0",
        "description:markdown\tTest package",
    }, "\n") .. "\n"
end

-- Check whether a type name is registered in the parser state
local function isRegistered(type_name)
    return parsers.parseType(error_reporting.nullBadVal, type_name, false) ~= nil
end

describe("manifest_loader - custom type definition files", function()
    -- Initialised here so the linter knows these are never nil inside it() blocks;
    -- before_each replaces them with fresh instances before every test.
    local temp_dir = ""
    local log_messages = {}
    local badVal = error_reporting.badValGen()

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "",
            "Could not find system temp directory")
        local td = path_join(system_temp, "ctd_test_" .. tostring(os.time()))
        assert(lfs.mkdir(td))
        temp_dir = td
        log_messages = {}
        badVal = mockBadVal(log_messages)
        badVal.logger = error_reporting.nullLogger
    end)

    -- before_each always runs before it(), so temp_dir is always a real path here.
    after_each(function()
        file_util.deleteTempDir(temp_dir)
        temp_dir = ""
    end)

    -- Create a package directory with a manifest, Files.tsv rows, and extra files.
    -- files_rows: sequence of tab-separated row strings (without the header)
    -- extra_files: {filename -> content} table
    local function makePkg(pkg_id, files_rows, extra_files)
        local pkg_dir = path_join(temp_dir, pkg_id)
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(
            path_join(pkg_dir, MANIFEST_FILENAME), makeManifest(pkg_id)))
        local files_content = FILES_HEADER
        for _, row in ipairs(files_rows) do
            files_content = files_content .. row .. "\n"
        end
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), files_content))
        for fname, content in pairs(extra_files or {}) do
            assert(file_util.writeFile(path_join(pkg_dir, fname), content))
        end
        return pkg_dir
    end

    -- -------------------------------------------------------------------------
    describe("typeName=custom_type_def (direct)", function()

        it("registers a simple alias type", function()
            -- Type names must be unique across all tests since registration is global state
            local pkg_dir = makePkg("DirectAlias", {
                "CustomTypes.tsv\tcustom_type_def\t\ttrue\t\t\t1\tCustom types"
            }, {
                ["CustomTypes.tsv"] =
                    "name:name\tparent:type_spec|nil\n" ..
                    "ctdAlias1\tinteger\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
            assert.is_true(isRegistered("ctdAlias1"))
        end)

        it("registers a range-constrained numeric type", function()
            local pkg_dir = makePkg("DirectNumeric", {
                "CustomTypes.tsv\tcustom_type_def\t\ttrue\t\t\t1\tCustom types"
            }, {
                ["CustomTypes.tsv"] =
                    "name:name\tparent:type_spec|nil\tmin:number|nil\tmax:number|nil\n" ..
                    "ctdPosInt\tinteger\t1\t\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
            assert.is_true(isRegistered("ctdPosInt"))
        end)

        it("registers a string-constrained type", function()
            local pkg_dir = makePkg("DirectString", {
                "CustomTypes.tsv\tcustom_type_def\t\ttrue\t\t\t1\tCustom types"
            }, {
                ["CustomTypes.tsv"] =
                    "name:name\tparent:type_spec|nil\tminLen:integer|nil\tmaxLen:integer|nil\n" ..
                    "ctdShortName\tstring\t1\t20\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
            assert.is_true(isRegistered("ctdShortName"))
        end)

        it("registers an expression-validated type", function()
            local pkg_dir = makePkg("DirectExpr", {
                "CustomTypes.tsv\tcustom_type_def\t\ttrue\t\t\t1\tCustom types"
            }, {
                ["CustomTypes.tsv"] =
                    "name:name\tparent:type_spec|nil\tvalidate:string|nil\n" ..
                    "ctdEvenInt\tinteger\tvalue % 2 == 0\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
            assert.is_true(isRegistered("ctdEvenInt"))
        end)

        it("registers multiple types from the same file", function()
            local pkg_dir = makePkg("DirectMulti", {
                "CustomTypes.tsv\tcustom_type_def\t\ttrue\t\t\t1\tCustom types"
            }, {
                ["CustomTypes.tsv"] =
                    "name:name\tparent:type_spec|nil\tmin:number|nil\tmax:number|nil\n" ..
                    "ctdMultiA\tinteger\t0\t\n" ..
                    "ctdMultiB\tinteger\t\t100\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
            assert.is_true(isRegistered("ctdMultiA"))
            assert.is_true(isRegistered("ctdMultiB"))
        end)

        it("handles an empty custom type def file without error", function()
            local pkg_dir = makePkg("DirectEmpty", {
                "CustomTypes.tsv\tcustom_type_def\t\ttrue\t\t\t1\tCustom types"
            }, {
                ["CustomTypes.tsv"] =
                    "name:name\tparent:type_spec|nil\n"
                -- no data rows
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
        end)

        it("registered types are usable as column types in subsequent files", function()
            -- CustomTypes.tsv (loadOrder=1) defines ctdUsableScore.
            -- Data.tsv (loadOrder=2) uses ctdUsableScore as a column type.
            local pkg_dir = makePkg("DirectUsable", {
                "CustomTypes.tsv\tcustom_type_def\t\ttrue\t\t\t1\tCustom types",
                "Data.tsv\tDataRow\t\ttrue\t\t\t2\tData using custom type"
            }, {
                ["CustomTypes.tsv"] =
                    "name:name\tparent:type_spec|nil\tmin:number|nil\tmax:number|nil\n" ..
                    "ctdUsableScore\tinteger\t0\t100\n",
                ["Data.tsv"] =
                    "id:name\tscore:ctdUsableScore\n" ..
                    "player1\t75\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
        end)

        it("errors on duplicate name with a different type (collision detection)", function()
            -- ctdCollide is already registered by the first row as an alias to integer.
            -- The second row tries to register ctdCollide as float — must fail.
            local pkg_dir = makePkg("DirectCollide", {
                "CustomTypes.tsv\tcustom_type_def\t\ttrue\t\t\t1\tCustom types"
            }, {
                ["CustomTypes.tsv"] =
                    "name:name\tparent:type_spec|nil\n" ..
                    "ctdCollide\tinteger\n" ..
                    "ctdCollide\tfloat\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            -- Second registration of ctdCollide (with different type) must produce an error
            assert.is_true(badVal.errors > 0)
        end)

    end)

    -- -------------------------------------------------------------------------
    describe("typeName is a named sub-type of custom_type_def", function()

        it("registers types when superType=custom_type_def", function()
            -- Files.tsv declares MyTypeDefs as a sub-type of custom_type_def.
            -- The loader should detect it via the extends chain and register its rows.
            local pkg_dir = makePkg("SubTypeDirect", {
                "MyTypeDefs.tsv\tMyTypeDefs\tcustom_type_def\tfalse\t\t\t1\tMy types"
            }, {
                ["MyTypeDefs.tsv"] =
                    "name:name\tparent:type_spec|nil\n" ..
                    "ctdSubAlias\tstring\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
            assert.is_true(isRegistered("ctdSubAlias"))
        end)

        it("registers types when the sub-type has extra columns beyond custom_type_def", function()
            -- Extra columns (gameCategory) are parsed but ignored during type registration.
            local pkg_dir = makePkg("SubTypeExtra", {
                "GameTypes.tsv\tGameTypes\tcustom_type_def\tfalse\t\t\t1\tGame types"
            }, {
                ["GameTypes.tsv"] =
                    "name:name\tparent:type_spec|nil\tmin:number|nil\tgameCategory:string\n" ..
                    "ctdExtraHealth\tinteger\t0\tStats\n" ..
                    "ctdExtraMana\tinteger\t0\tStats\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
            assert.is_true(isRegistered("ctdExtraHealth"))
            assert.is_true(isRegistered("ctdExtraMana"))
        end)

        it("extra-column types are usable as column types in data files", function()
            local pkg_dir = makePkg("SubTypeExtraUsable", {
                "GameTypes.tsv\tGameTypes\tcustom_type_def\tfalse\t\t\t1\tGame types",
                "Units.tsv\tUnit\t\ttrue\t\t\t2\tUnit data"
            }, {
                ["GameTypes.tsv"] =
                    "name:name\tparent:type_spec|nil\tmin:number|nil\tgameCategory:string\n" ..
                    "ctdExtraUsableHp\tinteger\t0\tStats\n",
                ["Units.tsv"] =
                    "id:name\thp:ctdExtraUsableHp\n" ..
                    "warrior\t250\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
        end)

    end)

    -- -------------------------------------------------------------------------
    describe("cascaded custom type definition files", function()

        it("a later file can use types defined by an earlier file (by loadOrder)", function()
            -- TypesA.tsv (loadOrder=1) defines ctdBaseNum.
            -- TypesB.tsv (loadOrder=2) defines ctdDerivedNum with parent=ctdBaseNum.
            local pkg_dir = makePkg("Cascaded", {
                "TypesA.tsv\tcustom_type_def\t\ttrue\t\t\t1\tBase types",
                "TypesB.tsv\tcustom_type_def\t\ttrue\t\t\t2\tDerived types"
            }, {
                ["TypesA.tsv"] =
                    "name:name\tparent:type_spec|nil\tmin:number|nil\n" ..
                    "ctdCascBaseNum\tinteger\t0\n",
                ["TypesB.tsv"] =
                    "name:name\tparent:type_spec|nil\tmin:number|nil\n" ..
                    "ctdCascDerivedNum\tctdCascBaseNum\t1\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
            assert.is_true(isRegistered("ctdCascBaseNum"))
            assert.is_true(isRegistered("ctdCascDerivedNum"))
        end)

    end)

    -- -------------------------------------------------------------------------
    describe("coexistence with manifest-defined custom types", function()

        it("both manifest and file custom types are registered", function()
            -- The manifest defines ctdManifestType; the file defines ctdFileType.
            -- Both should be usable.
            local pkg_dir = makePkg("CoexistPkg", {
                "CustomTypes.tsv\tcustom_type_def\t\ttrue\t\t\t1\tCustom types"
            }, {
                ["CustomTypes.tsv"] =
                    "name:name\tparent:type_spec|nil\n" ..
                    "ctdCoexistFile\tinteger\n"
            })
            -- Rewrite manifest to also declare a custom type inline
            local manifest_with_custom = makeManifest("CoexistPkg") ..
                "custom_types:{custom_type_def}|nil\t{name=\"ctdCoexistManifest\",parent=\"integer\"}\n"
            assert(file_util.writeFile(
                path_join(pkg_dir, MANIFEST_FILENAME), manifest_with_custom))

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
            assert.is_true(isRegistered("ctdCoexistManifest"))
            assert.is_true(isRegistered("ctdCoexistFile"))
        end)

        it("errors when file redefines a manifest type with a different parent", function()
            local pkg_dir = makePkg("CollidePkg", {
                "CustomTypes.tsv\tcustom_type_def\t\ttrue\t\t\t1\tCustom types"
            }, {
                ["CustomTypes.tsv"] =
                    "name:name\tparent:type_spec|nil\n" ..
                    "ctdCollideManifest\tfloat\n"  -- manifest registers it as integer
            })
            -- Manifest registers ctdCollideManifest as integer
            local manifest_with_custom = makeManifest("CollidePkg") ..
                "custom_types:{custom_type_def}|nil\t{name=\"ctdCollideManifest\",parent=\"integer\"}\n"
            assert(file_util.writeFile(
                path_join(pkg_dir, MANIFEST_FILENAME), manifest_with_custom))

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            -- File tries to register ctdCollideManifest as float while manifest registered it as integer
            assert.is_true(badVal.errors > 0)
        end)

    end)

    -- -------------------------------------------------------------------------
    describe("record type registration and parent-child field validation", function()

        it("registers the record type of a custom_type_def file", function()
            -- A custom_type_def file should have its column structure registered as a record type
            local pkg_dir = makePkg("RecTypeReg", {
                "UnitDefs.tsv\tctdUnitDefs\tcustom_type_def\tfalse\t\t\t1\tUnit defs"
            }, {
                ["UnitDefs.tsv"] =
                    "name:name\tparent:type_spec|nil\n" ..
                    "ctdRecTypeUnit\tinteger\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
            -- The file type itself should be registered as a record type
            assert.is_true(isRegistered("ctdUnitDefs"))
            -- And the types it defines should also be registered
            assert.is_true(isRegistered("ctdRecTypeUnit"))
        end)

        it("accepts a child file whose fields are same as parent", function()
            -- Parent and child have identical column types -> no error
            local pkg_dir = makePkg("FieldSame", {
                "Parent.tsv\tctdFieldParent\tcustom_type_def\tfalse\t\t\t1\tParent defs",
                "Child.tsv\tctdFieldChild\tctdFieldParent\tfalse\t\t\t2\tChild defs"
            }, {
                ["Parent.tsv"] =
                    "name:name\tparent:{extends:number}|nil\n" ..
                    "ctdFieldParentType\tfloat\n",
                ["Child.tsv"] =
                    "name:name\tparent:{extends:number}|nil\n" ..
                    "ctdFieldChildType\tinteger\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
        end)

        it("accepts a child file whose fields are more restrictive than parent", function()
            -- Parent has parent:{extends:number}, child has parent:{extends:float}
            -- {extends:float} is more restrictive than {extends:number} -> OK
            local pkg_dir = makePkg("FieldNarrower", {
                "Parent.tsv\tctdNarrowParent\tcustom_type_def\tfalse\t\t\t1\tParent defs",
                "Child.tsv\tctdNarrowChild\tctdNarrowParent\tfalse\t\t\t2\tChild defs"
            }, {
                ["Parent.tsv"] =
                    "name:name\tparent:{extends:number}|nil\n" ..
                    "ctdNarrowParentT\tfloat\n",
                ["Child.tsv"] =
                    "name:name\tparent:{extends:float}|nil\n" ..
                    "ctdNarrowChildT\tfloat\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors)
        end)

        it("errors when child file has less restrictive field than parent", function()
            -- Parent has parent:{extends:float}, child has parent:{extends:number}
            -- {extends:number} is LESS restrictive than {extends:float} -> ERROR
            local pkg_dir = makePkg("FieldWider", {
                "Parent.tsv\tctdWideParent\tcustom_type_def\tfalse\t\t\t1\tParent defs",
                "Child.tsv\tctdWideChild\tctdWideParent\tfalse\t\t\t2\tChild defs"
            }, {
                ["Parent.tsv"] =
                    "name:name\tparent:{extends:float}|nil\n" ..
                    "ctdWideParentT\tfloat\n",
                ["Child.tsv"] =
                    "name:name\tparent:{extends:number}|nil\n" ..
                    "ctdWideChildT\tinteger\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            -- Child widens a parent field type -> must produce an error
            assert.is_true(badVal.errors > 0)
        end)

        it("errors when child file changes a field to an incompatible type", function()
            -- Parent has parent:type_spec, child changes it to parent:string
            local pkg_dir = makePkg("FieldIncompat", {
                "Parent.tsv\tctdIncompatParent\tcustom_type_def\tfalse\t\t\t1\tParent defs",
                "Child.tsv\tctdIncompatChild\tctdIncompatParent\tfalse\t\t\t2\tChild defs"
            }, {
                ["Parent.tsv"] =
                    "name:name\tparent:type_spec|nil\n" ..
                    "ctdIncompatParentT\tinteger\n",
                ["Child.tsv"] =
                    "name:name\tparent:string|nil\n" ..
                    "ctdIncompatChildT\tinteger\n"
            })

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            -- Incompatible field type -> must produce an error
            assert.is_true(badVal.errors > 0)
        end)

    end)

end)
