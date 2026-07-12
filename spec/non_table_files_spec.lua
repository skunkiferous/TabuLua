-- non_table_files_spec.lua
--
-- A package can SAY what a file is, instead of having it guessed from the
-- extension. `typeName=asset_file` in Files.tsv means "this is not a table": do
-- not parse it, keep it, copy it byte-for-byte to the export, and never rewrite it
-- in place.
--
-- The declaration beats the extension for EVERY extension, which is the whole
-- point. A .json asset is the case that used to be dropped (a .json is a table
-- only when a row gives it a `transcoder`, so an undeclared one was called data
-- and skipped — while an .md asset was copied). A .tsv asset is the case the
-- pipeline could not express AT ALL: any .tsv the loader saw was either parsed —
-- and reformatted in place — or dropped. Now it can be carried through untouched.
--
-- The third role, `ignored` ("pretend it isn't there"), is neither loaded NOR
-- exported — which is what an IgnoredFile-tagged migration script always claimed
-- to be, but wasn't: the loader dropped it from raw_files and the asset pass put it
-- straight back, so it was copied into every export.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local lfs = require("lfs")
local file_util = require("infra.file_util")
local manifest_loader = require("loader.manifest_loader")
local reformatter = require("reformatter")
local exporter = require("serde.exporter")
local error_reporting = require("infra.error_reporting")
local named_logger = require("infra.named_logger")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local MANIFEST_FILENAME = "Manifest.transposed.tsv"

local FILES_HEADER = table.concat({
    "fileName:filepath", "typeName:type_spec", "superType:super_type",
    "baseType:boolean", "loadOrder:number", "description:text", "transcoder:string|nil",
}, "\t") .. "\n"

local MANIFEST = table.concat({
    "package_id:package_id\tPkg",
    "name:string\tAsset Test Package",
    "version:version\t0.1.0",
    "description:markdown\tPackage with declared assets",
}, "\n") .. "\n"

-- Same package, plus the manifest globs: the BULK form of the same two
-- declarations. Every .json under ui/ is an asset; temp files and the scratch
-- directory are not there at all.
local MANIFEST_GLOBS = MANIFEST
    .. "asset_files:{string}|nil\t\"ui/*.json\"\n"
    .. "ignored_files:{string}|nil\t\"*.tmp.tsv\",\"scratch/**\"\n"

-- The one declared TABLE every package here has. `007` is deliberate: it parses to
-- 7 and REFORMATS to "7", so an in-place reformat of this file is guaranteed to
-- change its bytes. That makes it the control for the .tsv-asset test below — it
-- proves the reformatter really did run over the package. (Its exact rewritten
-- bytes are platform-dependent — the in-place rewrite is a text-mode write — so
-- the control asserts the CHANGE, not a byte image.)
local ITEM_TSV = "name:name\tprice:integer\nsword\t007\n"

-- Byte-for-byte assertions need content the asset path cannot legitimately alter:
-- text assets are EOL-normalised on read (as .md and .txt always have been), so
-- these fixtures are LF-only. Everything else about them must survive untouched —
-- including, for the .tsv, formatting no reformatter would ever have chosen.
local THEME_JSON = '{\n  "accent": "#ff0000",\n  "spacing":   4\n}\n'
local LAYOUT_XML = '<layout>\n  <panel id="main"   />\n</layout>\n'
-- Not canonical TSV: padded cells, a value (0042) that would reformat to 42, and a
-- comment the parser would not preserve verbatim. If anything parses and rewrites
-- this file, the bytes change.
local LOOKUP_TSV = "# hand-aligned, do not touch\nkey:name\tvalue:integer\nalpha  \t0042\n"

describe("non-table files (asset_file / ignored roles)", function()
    local temp_dir = ""
    local badVal
    local log_messages

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(), "assets_"
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

    -- Builds a package whose Files.tsv is FILES_HEADER .. `rows`, plus Item.tsv and
    -- whatever extra files `extras` names (a name may include a subdirectory, which
    -- is created). `opt_manifest` overrides the default manifest.
    local function makePkg(rows, extras, opt_manifest)
        local pkg_dir = path_join(temp_dir, "Pkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME),
            opt_manifest or MANIFEST))
        assert(file_util.writeFile(path_join(pkg_dir, "Files.tsv"),
            FILES_HEADER .. "Item.tsv\tItem\t\ttrue\t100\tItems\t\n" .. (rows or "")))
        assert(file_util.writeFileBinary(path_join(pkg_dir, "Item.tsv"), ITEM_TSV))
        for name, content in pairs(extras or {}) do
            local subdir = name:match("^(.*)/[^/]+$")
            if subdir then
                -- One mkdir per level: "scratch/deep" needs both.
                local sofar = pkg_dir
                for segment in subdir:gmatch("[^/]+") do
                    sofar = path_join(sofar, segment)
                    lfs.mkdir(sofar)
                end
            end
            assert(file_util.writeFileBinary(path_join(pkg_dir, name), content))
        end
        return pkg_dir
    end

    local function findBySuffix(map, suffix)
        for path, v in pairs(map) do
            if path:sub(-#suffix) == suffix then return v, path end
        end
        return nil
    end

    local function messages()
        return table.concat(log_messages, " | ")
    end

    -- files_desc reports through badVal.logger, so a capturing logger there is how
    -- a test sees its warnings (the default badVal.logger in this spec is the null
    -- one). Returns the logger and the list it appends WARN messages to.
    local function capturingLogger()
        local warnings = {}
        local logger = named_logger.new(function(_self, level, message)
            if level == named_logger.WARN then
                warnings[#warnings + 1] = tostring(message)
            end
            return true
        end)
        return logger, warnings
    end

    describe("a declared asset survives to the export, for every extension", function()
        -- The regression this closes: 0.30.0 copied an undeclared .json to the
        -- export; making undeclared data files an error took that away with no way
        -- to ask for it back. `asset_file` is that way back — and it is the same
        -- role .md and .txt have always had implicitly.
        it("copies a declared .json asset byte-for-byte (and never parses it)", function()
            local pkg_dir = makePkg("theme.json\tasset_file\t\tfalse\t200\tUI theme\t\n",
                {["theme.json"] = THEME_JSON})
            local export_dir = path_join(temp_dir, "out")

            -- Model first: not a table, so no parse — but kept.
            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors, messages())
            assert.is_nil(findBySuffix(result.tsv_files, "theme.json"))
            assert.is_not_nil(findBySuffix(result.raw_files, "theme.json"))

            -- Then end-to-end: the exported copy is the same bytes, LF and all.
            reformatter.processFiles({pkg_dir},
                {{fn = exporter.exportJSON, subdir = "json-json"}},
                {exportDir = export_dir})
            assert.equals(THEME_JSON,
                file_util.readFileBinary(path_join(export_dir, "json-json", "theme.json")))
        end)

        it("copies a declared .xml asset byte-for-byte", function()
            local pkg_dir = makePkg("layout.xml\tasset_file\t\tfalse\t200\tUI layout\t\n",
                {["layout.xml"] = LAYOUT_XML})
            local export_dir = path_join(temp_dir, "out")

            reformatter.processFiles({pkg_dir},
                {{fn = exporter.exportJSON, subdir = "json-json"}},
                {exportDir = export_dir})

            assert.equals(LAYOUT_XML,
                file_util.readFileBinary(path_join(export_dir, "json-json", "layout.xml")))
        end)

        -- The case with no prior workaround at all. A .tsv is the most table-ish
        -- extension there is, so this is what proves a declaration beats the
        -- extension rather than merely resolving an ambiguous one.
        it("carries a declared .tsv asset through UNPARSED, UNREFORMATTED and UNRENAMED", function()
            local pkg_dir = makePkg("Lookup.tsv\tasset_file\t\tfalse\t200\tHand-aligned table\t\n",
                {["Lookup.tsv"] = LOOKUP_TSV})
            local export_dir = path_join(temp_dir, "out")

            local loaded = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(loaded)
            -- Not parsed: it is not a table, so it has no dataset.
            assert.is_nil(findBySuffix(loaded.tsv_files, "Lookup.tsv"))
            assert.is_not_nil(findBySuffix(loaded.raw_files, "Lookup.tsv"))

            reformatter.processFiles({pkg_dir},
                {{fn = exporter.exportJSON, subdir = "json-json"}},
                {exportDir = export_dir})

            -- NOT REWRITTEN IN PLACE. The reformatter did run — the control
            -- file below was rewritten by the same call — it simply has nothing to
            -- rewrite here, because an asset is never parsed into a dataset.
            assert.equals(LOOKUP_TSV,
                file_util.readFileBinary(path_join(pkg_dir, "Lookup.tsv")),
                "the reformatter rewrote a file declared asset_file")
            local item_after = file_util.readFileBinary(path_join(pkg_dir, "Item.tsv"))
            assert.are_not.equals(ITEM_TSV, item_after,
                "control: the declared TABLE should have been reformatted in place")
            assert.is_truthy(item_after:match("sword\t7"),
                "control: 007 should have been reformatted to 7, got: " .. item_after)

            -- Exported byte-for-byte, under its OWN name: a .tsv asset is not a
            -- table, so --file=json must not serialize it into Lookup.json.
            assert.equals(LOOKUP_TSV,
                file_util.readFileBinary(path_join(export_dir, "json-json", "Lookup.tsv")))
            assert.is_nil(file_util.readFile(path_join(export_dir, "json-json", "Lookup.json")),
                "an asset .tsv must not be re-serialized into the target format")
            -- The declared table, by contrast, IS serialized to the target format.
            assert.is_not_nil(file_util.readFile(path_join(export_dir, "json-json", "Item.json")))
        end)

        it("declares an asset without warning about it", function()
            -- The old route — invent a typeName, omit the transcoder — worked, but
            -- warned "Don't know how to process". Declaring the ROLE is silent.
            -- stray.json is the control: an UNdeclared file of the same extension,
            -- which must still warn — otherwise this test would pass just as well
            -- with a capture that sees nothing at all.
            local warnings = {}
            local pkg_dir = makePkg("theme.json\tasset_file\t\tfalse\t200\tUI theme\t\n",
                {["theme.json"] = THEME_JSON, ["stray.json"] = THEME_JSON})
            local logger = require("infra.named_logger").getLogger("manifest_loader")
            local realWarn = logger.warn
            logger.warn = function(self, msg) warnings[#warnings + 1] = msg; return realWarn(self, msg) end
            local ok, err = pcall(manifest_loader.processFiles, {pkg_dir}, badVal)
            logger.warn = realWarn
            assert.is_true(ok, tostring(err))

            local sawStray = false
            for _, w in ipairs(warnings) do
                assert.is_falsy(w:match("theme%.json"),
                    "a declared asset should not warn: " .. w)
                if w:match("stray%.json") then sawStray = true end
            end
            assert.is_true(sawStray,
                "control: the UNdeclared .json must still warn (else nothing is being captured)")
        end)
    end)

    describe("the undeclared file is still the one case that loses a file", function()
        it("drops an undeclared .json, and declaring it as an asset brings it back", function()
            -- Same file, same package, one row of difference. This pair IS the
            -- feature: the escape hatch the undeclared-data rule took away.
            local undeclared = makePkg(nil, {["theme.json"] = THEME_JSON})
            local r1 = manifest_loader.processFiles({undeclared}, badVal)
            assert.is_not_nil(r1)
            assert.equals(0, badVal.errors, messages())  -- a warning, not an error
            assert.is_nil(findBySuffix(r1.raw_files, "theme.json"))

            file_util.deleteTempDir(path_join(temp_dir, "Pkg"))
            local declared = makePkg("theme.json\tasset_file\t\tfalse\t200\tUI theme\t\n",
                {["theme.json"] = THEME_JSON})
            local r2 = manifest_loader.processFiles({declared}, badVal)
            assert.is_not_nil(r2)
            assert.equals(0, badVal.errors, messages())
            assert.is_not_nil(findBySuffix(r2.raw_files, "theme.json"))
        end)

        it("still drops an undeclared .tsv (asset_file is a declaration, not a loophole)", function()
            local pkg_dir = makePkg(nil, {["Stray.tsv"] = ITEM_TSV})
            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.is_nil(findBySuffix(result.tsv_files, "Stray.tsv"))
            assert.is_nil(findBySuffix(result.raw_files, "Stray.tsv"))
        end)

        it("keeps loading an undeclared .md (an implicit asset needs no row)", function()
            local pkg_dir = makePkg(nil, {["notes.md"] = "# notes\n"})
            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.is_not_nil(findBySuffix(result.raw_files, "notes.md"))
        end)
    end)

    describe("the ignored role", function()
        -- "Pretend it isn't there" — as distinct from "keep it, don't read it".
        it("neither loads NOR exports an IgnoredFile-tagged file", function()
            local pkg_dir = makePkg("migrate_v2.tsv\tMigrationScript\t\tfalse\t200\tMigration\t\n",
                {["migrate_v2.tsv"] = "command:string\tp1:string\nloadFile\tItem.tsv\nsaveAll\t\n"})
            local export_dir = path_join(temp_dir, "out")

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            reformatter.processFiles({pkg_dir},
                {{fn = exporter.exportJSON, subdir = "json-json"}},
                {exportDir = export_dir})

            assert.is_nil(findBySuffix(result.tsv_files, "migrate_v2.tsv"))
            -- It never reaches raw_files, so it cannot be exported. It USED to:
            -- the loader nil'd it, then the asset pass — walking the unfiltered
            -- file list — stored it again, and every export carried a copy.
            assert.is_nil(findBySuffix(result.raw_files, "migrate_v2.tsv"))
            assert.is_nil(file_util.readFile(
                path_join(export_dir, "json-json", "migrate_v2.tsv")))
            assert.is_nil(file_util.readFile(
                path_join(export_dir, "json-json", "migrate_v2.json")))
            -- The source file is of course still on disk, untouched.
            assert.is_not_nil(file_util.readFile(path_join(pkg_dir, "migrate_v2.tsv")))
        end)
    end)

    describe("manifest globs (asset_files / ignored_files)", function()
        -- The bulk form of the same two declarations, for packages where naming
        -- every file in Files.tsv is not the point.
        it("makes every glob-matched file an asset, with no Files.tsv row", function()
            local pkg_dir = makePkg(nil,
                {["ui/theme.json"] = THEME_JSON}, MANIFEST_GLOBS)
            local export_dir = path_join(temp_dir, "out")

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors, messages())
            -- No row declares it, and yet it is neither parsed nor dropped: the
            -- manifest already said what it is.
            assert.is_nil(findBySuffix(result.tsv_files, "ui/theme.json"))
            assert.is_not_nil(findBySuffix(result.raw_files, "ui/theme.json"))

            reformatter.processFiles({pkg_dir},
                {{fn = exporter.exportJSON, subdir = "json-json"}},
                {exportDir = export_dir})
            assert.equals(THEME_JSON, file_util.readFileBinary(
                path_join(export_dir, "json-json", "ui", "theme.json")))
        end)

        it("ignores glob-matched temp files SILENTLY — the annoyance that started this", function()
            -- A temp .tsv used to be an error, then a warning. Now a package can say
            -- "these are not mine" once, and the loader says nothing at all about
            -- them: not loaded, not exported, not warned.
            local warnings = {}
            local logger = require("infra.named_logger").getLogger("manifest_loader")
            local realWarn = logger.warn
            logger.warn = function(self, msg) warnings[#warnings + 1] = msg; return realWarn(self, msg) end

            local pkg_dir = makePkg(nil, {
                ["Item.tmp.tsv"] = ITEM_TSV,
                ["scratch/wip.tsv"] = ITEM_TSV,
                ["scratch/deep/notes.json"] = THEME_JSON,
                -- Control: undeclared and matched by NO glob, so it must still warn.
                -- Without it, "no warning mentions the ignored files" would pass even
                -- if the capture saw nothing at all.
                ["Loose.tsv"] = ITEM_TSV,
            }, MANIFEST_GLOBS)
            -- pcall so the logger is always restored, even on a failure.
            local ok, result = pcall(manifest_loader.processFiles, {pkg_dir}, badVal)
            logger.warn = realWarn
            assert.is_true(ok, tostring(result))
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors, messages())

            for _, name in ipairs({"Item.tmp.tsv", "scratch/wip.tsv", "scratch/deep/notes.json"}) do
                assert.is_nil(findBySuffix(result.tsv_files, name), name .. " was parsed")
                assert.is_nil(findBySuffix(result.raw_files, name), name .. " was exported")
            end
            local sawControl = false
            for _, w in ipairs(warnings) do
                assert.is_falsy(w:match("tmp%.tsv") or w:match("scratch"),
                    "an ignored_files glob must silence the file entirely, got: " .. w)
                if w:match("Loose%.tsv") then sawControl = true end
            end
            assert.is_true(sawControl,
                "control: the undeclared Loose.tsv must still warn (else nothing is captured)")
            -- The real data is untouched by any of this.
            assert.is_not_nil(findBySuffix(result.tsv_files, "/Item.tsv"))
        end)

        it("does not let a glob reach outside the package that declares it", function()
            -- Ownership is by package (longest root prefix), and the glob is matched
            -- against the path relative to ITS OWN package root — the same rule that
            -- makes a Files.tsv relocatable. A sibling package's identically-named
            -- file is none of this manifest's business.
            local pkg_dir = makePkg(nil, {["Item.tmp.tsv"] = ITEM_TSV}, MANIFEST_GLOBS)

            local other = path_join(temp_dir, "Other")
            assert(lfs.mkdir(other))
            assert(file_util.writeFile(path_join(other, MANIFEST_FILENAME), table.concat({
                "package_id:package_id\tOther",
                "name:string\tOther Package",
                "version:version\t0.1.0",
                "description:markdown\tNo globs here",
            }, "\n") .. "\n"))
            assert(file_util.writeFile(path_join(other, "Files.tsv"),
                FILES_HEADER .. "Keep.tmp.tsv\tKeep\t\ttrue\t100\tDeclared, despite the name\t\n"))
            assert(file_util.writeFileBinary(path_join(other, "Keep.tmp.tsv"), ITEM_TSV))

            local result = manifest_loader.processFiles({pkg_dir, other}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors, messages())
            -- Pkg's ignored_files glob took out Pkg's temp file...
            assert.is_nil(findBySuffix(result.raw_files, "Pkg/Item.tmp.tsv"))
            -- ...and did NOT touch Other's file of the same shape, which Other
            -- declares as a table.
            assert.is_not_nil(findBySuffix(result.tsv_files, "Other/Keep.tmp.tsv"))
        end)

        it("lets a Files.tsv row and a glob agree, and the row still wins its role", function()
            -- ignored beats asset (rule 1 before rule 2), so a file that is both
            -- glob-asset and IgnoredFile-declared is ignored — the stronger "pretend
            -- it isn't there" wins over "keep it".
            local pkg_dir = makePkg(
                "ui/theme.json\tMigrationScript\t\tfalse\t200\tNot really\t\n",
                {["ui/theme.json"] = THEME_JSON}, MANIFEST_GLOBS)

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.is_nil(findBySuffix(result.raw_files, "ui/theme.json"))
        end)
    end)

    describe("a role typeName is not checked as a table type", function()
        -- Both checks below are about TABLE types, and are category errors on a
        -- role: a role is not named after its file, and several files sharing one
        -- is the normal case. They fired on every role typeName — asset_file would
        -- have added three more warnings a user can do nothing about, on top of the
        -- eight the tutorial already emitted for custom_type_def / patch /
        -- bulk_patch / SchemaOverlay / type_wiring_def.
        it("warns neither 'should match fileName' nor 'Multiple types with name'", function()
            local logger, warnings = capturingLogger()
            badVal.logger = logger

            local pkg_dir = makePkg(
                "theme.json\tasset_file\t\tfalse\t200\tTheme\t\n"
                .. "layout.xml\tasset_file\t\tfalse\t300\tLayout\t\n"
                .. "Lookup.tsv\tasset_file\t\tfalse\t400\tLookup\t\n",
                {["theme.json"] = THEME_JSON, ["layout.xml"] = LAYOUT_XML,
                 ["Lookup.tsv"] = LOOKUP_TSV})
            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)

            for _, w in ipairs(warnings) do
                assert.is_falsy(w:match("should match fileName"),
                    "a role typeName is not named after its file: " .. w)
                assert.is_falsy(w:match("Multiple types with name"),
                    "three files may share a role: " .. w)
            end
        end)

        it("still warns for a real table type whose name does not match its file", function()
            -- The check itself is not weakened: only ROLES are exempt. Without this,
            -- the exemption above could be passing for the wrong reason.
            local logger, warnings = capturingLogger()
            badVal.logger = logger

            local pkg_dir = makePkg("Weapon.tsv\tSword\t\ttrue\t200\tMismatched\t\n",
                {["Weapon.tsv"] = ITEM_TSV})
            assert.is_not_nil(manifest_loader.processFiles({pkg_dir}, badVal))

            local found = false
            for _, w in ipairs(warnings) do
                if w:match("should match fileName") then found = true end
            end
            assert.is_true(found, "a real typeName/fileName mismatch must still warn")
        end)
    end)

    describe("a declared marker is not a table type", function()
        it("does not put an asset into loadEnv.files, nor register a record type", function()
            -- An asset has no typeName in the modelling sense: nothing else can
            -- join to it, validate it, or reference it in an expression. Several
            -- files sharing the `asset_file` marker must not collide, either.
            local pkg_dir = makePkg(
                "theme.json\tasset_file\t\tfalse\t200\tTheme\t\n"
                .. "layout.xml\tasset_file\t\tfalse\t300\tLayout\t\n"
                .. "Lookup.tsv\tasset_file\t\tfalse\t400\tLookup\t\n",
                {["theme.json"] = THEME_JSON, ["layout.xml"] = LAYOUT_XML,
                 ["Lookup.tsv"] = LOOKUP_TSV})

            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors, messages())

            assert.is_nil(result.loadEnv.files["asset_file"],
                "asset_file is a role, not a dataset")
            for _, name in ipairs({"theme.json", "layout.xml", "Lookup.tsv"}) do
                assert.is_nil(findBySuffix(result.tsv_files, name), name .. " was parsed")
                assert.is_not_nil(findBySuffix(result.raw_files, name), name .. " was lost")
            end
        end)
    end)
end)
