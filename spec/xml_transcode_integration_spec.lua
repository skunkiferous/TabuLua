-- xml_transcode_integration_spec.lua
-- End-to-end: a namespaced .xml data file routed through the xml:tabulua
-- transcoder (selected by the Files.tsv `transcoder` column) loads as a wide,
-- typed table (schema-free — types come from the file's own <header>), and the
-- reformatter round-trips it back to XML in place via the id-selected encode
-- (Step 5). A foreign-namespace .xml selected as xml:tabulua is rejected.

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
local error_reporting = require("infra.error_reporting")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local MANIFEST_FILENAME = "Manifest.transposed.tsv"

local FILES_HEADER = table.concat({
    "fileName:filepath", "typeName:type_spec", "superType:super_type",
    "baseType:boolean", "loadOrder:number", "description:text",
    "transcoder:string|nil",
}, "\t") .. "\n"

local function makeManifest(pkg_id)
    return table.concat({
        "package_id:package_id\t" .. pkg_id,
        "name:string\t" .. pkg_id .. " Package",
        "version:version\t0.1.0",
        "description:markdown\tTest package",
    }, "\n") .. "\n"
end

local NS = "urn:tabulua:table:1"

describe("manifest_loader - XML transcode (Files.tsv-selected)", function()
    local temp_dir = ""
    local log_messages = {}
    local badVal = error_reporting.badValGen()

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "no system temp dir")
        local td = path_join(system_temp, "xmltx_test_" .. tostring(os.time())
            .. "_" .. tostring(math.random(1000000)))
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

    -- Builds a package whose single data file is `data.xml`, routed through
    -- xml:tabulua. The transcoder itself is schema-free (column types come from
    -- the XML's own <header>); the Files.tsv typeName is a required column, so we
    -- give a matching `XData` record type (defined first) — it still validates.
    local function makePkg(xml_body)
        local pkg_dir = path_join(temp_dir, "XmlPkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME),
            makeManifest("XmlPkg")))

        local files_content = FILES_HEADER
            .. "CustomTypes.tsv\tcustom_type_def\t\ttrue\t1\tCustom types\t\n"
            .. "data.xml\tXData\t\tfalse\t2\tData as XML\txml:tabulua\n"
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), files_content))

        assert(file_util.writeFile(path_join(pkg_dir, "CustomTypes.tsv"),
            "name:name\tparent:type_spec|nil\n" ..
            "XData\t{name:identifier,n:integer,loot:{name}}\n"))

        local xml = '<?xml version="1.0" encoding="UTF-8"?>\n<file xmlns="' .. NS .. '">\n'
            .. xml_body .. '\n</file>'
        assert(file_util.writeFile(path_join(pkg_dir, "data.xml"), xml))
        return pkg_dir
    end

    local function findTsv(result, suffix)
        for path, tsv in pairs(result.tsv_files) do
            if path:sub(-#suffix) == suffix then return tsv, path end
        end
        return nil
    end

    local BODY =
        '<header><string>name:identifier</string><string>n:integer</string>'
        .. '<string>loot:{name}</string></header>\n'
        .. '<row><string>sword</string><integer>100</integer>'
        .. '<table><string>gem</string><string>coin</string></table></row>\n'
        .. '<row><string>shield</string><integer>50</integer>'
        .. '<table><string>wood</string></table></row>'

    it("loads data.xml as a wide, typed table (schema-free)", function()
        local pkg_dir = makePkg(BODY)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))

        local tsv = findTsv(result, "data.xml")
        assert.is_not_nil(tsv)
        assert.equals(3, #tsv)                 -- header + 2 rows
        local header = tsv[1]
        assert.is_not_nil(header.name)
        assert.is_not_nil(header.n)
        assert.is_not_nil(header.loot)
        local r1 = tsv[2]
        assert.equals("sword", r1[header.name.idx].parsed)
        assert.equals(100, r1[header.n.idx].parsed)
        -- The composite cell parsed to a Lua table.
        local loot = r1[header.loot.idx].parsed
        assert.same({"gem", "coin"}, loot)
    end)

    it("threads the transcoder id into joinMeta.fn2Transcoder (for the reformatter)", function()
        local pkg_dir = makePkg(BODY)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        local _tsv, path = findTsv(result, "data.xml")
        assert.is_not_nil(path)
        assert.equals("xml:tabulua", result.joinMeta.fn2Transcoder[path])
    end)

    it("reformatter rewrites data.xml in place via the id-selected encode (round-trip)", function()
        local pkg_dir = makePkg(BODY)
        local xml_path = path_join(pkg_dir, "data.xml")

        -- processFiles loads + reformats in place (no exporters). The .xml is a
        -- reversible transcoded source, so it is rewritten from the reformatted
        -- wide TSV via xml:tabulua's encode (not left untouched like a .json).
        reformatter.processFiles({pkg_dir})

        local on_disk = file_util.readFile(xml_path)
        assert.is_not_nil(on_disk)
        -- Still a valid, namespaced TabuLua XML document.
        assert.matches('<file xmlns="' .. NS .. '">', on_disk, 1, true)
        assert.matches("</file>", on_disk, 1, true)

        -- Re-loading the rewritten file reproduces the same data.
        local msgs2 = {}
        local bad2 = error_reporting.badValGen(function(_s, m) msgs2[#msgs2 + 1] = m end)
        bad2.logger = error_reporting.nullLogger
        local result = manifest_loader.processFiles({pkg_dir}, bad2)
        assert.is_not_nil(result)
        assert.equals(0, bad2.errors, table.concat(msgs2, " | "))
        local tsv = findTsv(result, "data.xml")
        assert.is_not_nil(tsv)
        local header = tsv[1]
        assert.equals("sword", tsv[2][header.name.idx].parsed)
        assert.same({"gem", "coin"}, tsv[2][header.loot.idx].parsed)

        -- Reformatting is stable on a second pass (the rewritten XML is canonical).
        local before = file_util.readFile(xml_path)
        reformatter.processFiles({pkg_dir})
        local after = file_util.readFile(xml_path)
        assert.equals(before, after)
    end)

    it("rejects a foreign-namespace .xml selected as xml:tabulua", function()
        local pkg_dir = path_join(temp_dir, "ForeignPkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME),
            makeManifest("ForeignPkg")))
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"),
            FILES_HEADER .. "asset.xml\tstring\t\tfalse\t1\tForeign XML\txml:tabulua\n"))
        -- A non-TabuLua XML asset whose <file> is in a foreign namespace, wrongly
        -- opted in to xml:tabulua. The namespace check (defense-in-depth) rejects it.
        assert(file_util.writeFile(path_join(pkg_dir, "asset.xml"),
            '<?xml version="1.0"?>\n<file xmlns="urn:someone:else">\n'
            .. '<header><string>a:integer</string></header>\n</file>'))

        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.is_true(badVal.errors > 0)
        assert.matches("not in the TabuLua namespace", table.concat(log_messages, " | "))
    end)
end)
