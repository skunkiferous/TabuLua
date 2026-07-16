-- undeclared_data_files_spec.lua
--
-- Files.tsv is the manifest of what a package's data IS. A DATA file that no
-- Files.tsv row declares is reported and NOT processed: not parsed, not
-- reformatted, and not exported (it never reaches raw_files). "Data" means any
-- file whose extension — after the content pipeline peels decode layers — is
-- .tsv / .csv / .json / .xml / .eav, so Item.tsv.gz is data too.
--
-- ASSETS (.md, .txt, .lua, .zip) deliberately stay as they were: they need no
-- declaration and still load. An input directory with NO Files.tsv at all is not a
-- package directory and is a hard error — nothing declares what its data is, so the
-- loader refuses to guess.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local lfs = require("lfs")
local file_util = require("infra.file_util")
local manifest_loader = require("loader.manifest_loader")
local compression = require("content.compression")
local error_reporting = require("infra.error_reporting")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- Minimal in-test zip builder (stored members only) — same framing as the other
-- archive specs; the engine has no zip writer yet.
local u32le = compression.u32le
local function u16le(n)
    -- arithmetic, not 5.3 bitwise operators: LuaJIT cannot parse those
    n = n % 0x10000
    return string.char(n % 256, math.floor(n / 256))
end

local function buildZip(members)
    local locals, central = {}, {}
    local offset = 0
    for _, m in ipairs(members) do
        local crc = compression.crc32(m.data)
        local lfh = "PK\3\4" .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u16le(0) .. u32le(crc) .. u32le(#m.data) .. u32le(#m.data)
            .. u16le(#m.name) .. u16le(0) .. m.name .. m.data
        locals[#locals + 1] = lfh
        central[#central + 1] = "PK\1\2" .. u16le(20) .. u16le(20) .. u16le(0)
            .. u16le(0) .. u16le(0) .. u16le(0) .. u32le(crc) .. u32le(#m.data)
            .. u32le(#m.data) .. u16le(#m.name) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u16le(0) .. u32le(0) .. u32le(offset) .. m.name
        offset = offset + #lfh
    end
    local localBlob = table.concat(locals)
    local centralBlob = table.concat(central)
    local eocd = "PK\5\6" .. u16le(0) .. u16le(0) .. u16le(#members) .. u16le(#members)
        .. u32le(#centralBlob) .. u32le(#localBlob) .. u16le(0)
    return localBlob .. centralBlob .. eocd
end

local MANIFEST_FILENAME = "Manifest.transposed.tsv"

local FILES_HEADER = table.concat({
    "fileName:filepath", "typeName:type_spec", "superType:super_type",
    "baseType:boolean", "loadOrder:number", "description:text", "variant:name|nil",
}, "\t") .. "\n"

local function makeManifest(pkg_id)
    return table.concat({
        "package_id:package_id\t" .. pkg_id,
        "name:string\t" .. pkg_id .. " Package",
        "version:version\t0.1.0",
        "description:markdown\tTest package",
        "variant_groups:{{name,{name},name|nil}}|nil\t{\"lang\",{\"en\",\"fr\"},\"en\"}",
    }, "\n") .. "\n"
end

local ITEM_TSV = "name:name\tprice:integer\nsword\t100\n"

-- Only Item.tsv is declared; every other file the tests drop into the package is
-- undeclared on purpose.
local DECLARED = "Item.tsv\tItem\t\ttrue\t100\tItems\t\n"

describe("undeclared data files", function()
    local temp_dir = ""
    local badVal
    local log_messages

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(), "undeclared_"
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

    -- A package with a Manifest, a Files.tsv declaring only Item.tsv, and whatever
    -- extra (undeclared) files a test asks for. `files_body` overrides the rows.
    local function makePkg(extras, files_body)
        local pkg_dir = path_join(temp_dir, "Pkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME), makeManifest("Pkg")))
        assert(file_util.writeFile(path_join(pkg_dir, "Files.tsv"),
            FILES_HEADER .. (files_body or DECLARED)))
        assert(file_util.writeFile(path_join(pkg_dir, "Item.tsv"), ITEM_TSV))
        for name, content in pairs(extras or {}) do
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

    it("does not load, or export, an undeclared .tsv", function()
        local pkg_dir = makePkg({["Extra.tsv"] = "name:name\tqty:integer\nfoo\t7\n"})
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        -- A warning, not an error: the run still succeeds.
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        -- Not parsed...
        assert.is_nil(findBySuffix(result.tsv_files, "Extra.tsv"))
        -- ...and not carried as an asset either, so the exporter never sees it.
        assert.is_nil(findBySuffix(result.raw_files, "Extra.tsv"))
        -- The declared file is unaffected.
        assert.is_not_nil(findBySuffix(result.tsv_files, "Item.tsv"))
    end)

    it("skips every undeclared data format (.csv/.json/.xml/.eav) and .gz of one", function()
        local pkg_dir = makePkg({
            ["Un.csv"]     = "name:name\tqty:integer\nfoo\t7\n",
            ["Un.json"]    = '[["name:name"],["foo"]]\n',
            ["Un.xml"]     = "<rows><row><name>foo</name></row></rows>\n",
            ["Un.eav"]     = "foo\tqty\t7\n",
            ["Un.tsv.gz"]  = compression.compress("gzip", "name:name\tqty:integer\nfoo\t7\n"),
        })
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        -- Notably an undeclared .eav used to be a hard ERROR (the transcoder needs
        -- the typeName only Files.tsv can give it); it is now simply skipped.
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        for _, name in ipairs({"Un.csv", "Un.json", "Un.xml", "Un.eav", "Un.tsv.gz"}) do
            assert.is_nil(findBySuffix(result.tsv_files, name), name .. " was parsed")
            assert.is_nil(findBySuffix(result.raw_files, name), name .. " was kept as an asset")
        end
    end)

    it("still loads undeclared ASSETS (they need no Files.tsv row)", function()
        local pkg_dir = makePkg({
            ["notes.txt"] = "just a note\n",
            ["README.md"] = "# readme\n",
        })
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        assert.is_not_nil(findBySuffix(result.raw_files, "notes.txt"))
        assert.is_not_nil(findBySuffix(result.raw_files, "README.md"))
    end)

    it("skips an undeclared data member inside a zip", function()
        -- expandArchives makes a zip member indistinguishable from a loose file, so
        -- the same rule applies to it: declare it in Files.tsv or it is not loaded.
        local pkg_dir = makePkg({
            ["mod.zip"] = buildZip({
                {name = "data/InZip.tsv", data = "name:name\tqty:integer\nzed\t9\n"},
            }),
        })
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        assert.is_nil(findBySuffix(result.tsv_files, "mod.zip/data/InZip.tsv"))
        -- The zip itself is an asset and still streams through.
        assert.is_not_nil(findBySuffix(result.raw_files, "mod.zip"))
    end)

    it("does not reject a DECLARED but variant-inactive file", function()
        -- Item.fr.tsv is declared with variant=fr, which is not selected: it is
        -- inactive, not undeclared. It keeps its old treatment — not parsed, but
        -- still carried in raw_files (the exporter skips it by lcSkippedFiles) —
        -- which is exactly what distinguishes it from a rejected file above.
        local files_body = DECLARED
            .. "Item.fr.tsv\tItemFR\t\tfalse\t101\tFrench items\tfr\n"
        local pkg_dir = makePkg({["Item.fr.tsv"] = "name:name\tqty:integer\nfoo\t7\n"},
            files_body)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        assert.is_nil(findBySuffix(result.tsv_files, "Item.fr.tsv"))
        assert.is_not_nil(findBySuffix(result.raw_files, "Item.fr.tsv"))
    end)

    -- The load ABORTS for these (processFiles returns nil, which every caller
    -- checks), rather than loading the directory's data files untyped.
    it("errors on an input directory with data files but no Files.tsv", function()
        -- Not a package directory: nothing declares what its data is, so the loader
        -- refuses to guess.
        local bare = path_join(temp_dir, "Bare")
        assert(lfs.mkdir(bare))
        assert(file_util.writeFile(path_join(bare, "Loose.tsv"), ITEM_TSV))

        assert.is_nil(manifest_loader.processFiles({bare}, badVal))
    end)

    it("errors on an EMPTY input directory", function()
        -- Also not a package directory. Passing one is a mistake (a typo'd path, or
        -- the parent of the real packages), not a silent no-op.
        local empty = path_join(temp_dir, "Empty")
        assert(lfs.mkdir(empty))

        assert.is_nil(manifest_loader.processFiles({empty}, badVal))
    end)

    -- Only the package ROOT needs a Files.tsv. Its `fileName` entries are paths, so
    -- the root's declarations reach into subdirectories, which need no Files.tsv of
    -- their own — the requirement above is on the input directory, not on every
    -- directory.
    it("loads a subdirectory file declared BY PATH in the root Files.tsv", function()
        local pkg_dir = makePkg({})
        assert(lfs.mkdir(path_join(pkg_dir, "sub")))
        assert(file_util.writeFile(path_join(pkg_dir, "sub", "Deep.tsv"), ITEM_TSV))
        assert(file_util.writeFile(path_join(pkg_dir, "Files.tsv"), FILES_HEADER
            .. DECLARED .. "sub/Deep.tsv\tDeep\t\ttrue\t200\tIn a subdirectory\t\n"))

        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        assert.is_not_nil(findBySuffix(result.tsv_files, "sub/Deep.tsv"))
    end)

    it("rejects an UNdeclared subdirectory file", function()
        local pkg_dir = makePkg({})
        assert(lfs.mkdir(path_join(pkg_dir, "sub")))
        assert(file_util.writeFile(path_join(pkg_dir, "sub", "Stray.tsv"), ITEM_TSV))

        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        assert.is_nil(findBySuffix(result.tsv_files, "sub/Stray.tsv"))
        assert.is_nil(findBySuffix(result.raw_files, "sub/Stray.tsv"))
    end)

    -- A Files.tsv row governs a file by its exact path key. These two cover the
    -- ways a file can LOOK like a declared one without being it — both used to slip
    -- through, because the row was matched against the tail of the path.
    it("rejects an undeclared file whose name merely ENDS WITH a declared one's", function()
        -- `DraftItem.tsv` ends with `Item.tsv`, but it is not Item.tsv. It must not
        -- inherit that row (which would make it count as declared while none of the
        -- row's wiring — typeName, joins, validators — actually applied to it).
        -- tutorial/core/DraftItem.tsv is this exact case, on purpose.
        local pkg_dir = makePkg({["DraftItem.tsv"] = "name:name\tqty:integer\nfoo\t7\n"})
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        assert.is_nil(findBySuffix(result.tsv_files, "DraftItem.tsv"))
        assert.is_nil(findBySuffix(result.raw_files, "DraftItem.tsv"))
        -- The real Item.tsv still loads (note "/Item.tsv": plain "Item.tsv" would
        -- itself match "DraftItem.tsv" — the very trap this test is about).
        assert.is_not_nil(findBySuffix(result.tsv_files, "/Item.tsv"))
    end)

    it("rejects an undeclared subdirectory file that SHARES a declared file's name", function()
        -- sub/Item.tsv is a different file from the declared (root) Item.tsv: the
        -- root row's key is `item.tsv`, and nothing declares `sub/item.tsv`.
        local pkg_dir = makePkg({})
        assert(lfs.mkdir(path_join(pkg_dir, "sub")))
        assert(file_util.writeFile(path_join(pkg_dir, "sub", "Item.tsv"), ITEM_TSV))

        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        assert.is_nil(findBySuffix(result.tsv_files, "sub/Item.tsv"))
        assert.is_nil(findBySuffix(result.raw_files, "sub/Item.tsv"))
        assert.is_not_nil(findBySuffix(result.tsv_files, "Pkg/Item.tsv"))
    end)

    it("errors when given the PARENT of the package directories", function()
        -- The classic mistake ('tutorial/' instead of 'tutorial/core/'): the parent
        -- has no Files.tsv of its own, so the same one rule catches it.
        makePkg({})
        assert.is_nil(manifest_loader.processFiles({temp_dir}, badVal))
    end)

    it("rejects an undeclared file in EVERY input package of a multi-package run", function()
        local pkg_dir = makePkg({["Extra.tsv"] = "name:name\tqty:integer\nfoo\t7\n"})
        local other = path_join(temp_dir, "Other")
        assert(lfs.mkdir(other))
        assert(file_util.writeFile(path_join(other, MANIFEST_FILENAME), makeManifest("Other")))
        assert(file_util.writeFile(path_join(other, "Files.tsv"),
            FILES_HEADER .. "Loose.tsv\tLoose\t\ttrue\t100\tLoose\t\n"))
        assert(file_util.writeFile(path_join(other, "Loose.tsv"), ITEM_TSV))
        assert(file_util.writeFile(path_join(other, "Stray.tsv"), ITEM_TSV))

        local result = manifest_loader.processFiles({pkg_dir, other}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        assert.is_nil(findBySuffix(result.tsv_files, "Extra.tsv"))     -- undeclared
        assert.is_nil(findBySuffix(result.tsv_files, "Stray.tsv"))     -- undeclared
        assert.is_not_nil(findBySuffix(result.tsv_files, "Loose.tsv")) -- declared
    end)
end)
