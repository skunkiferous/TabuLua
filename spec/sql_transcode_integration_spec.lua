-- sql_transcode_integration_spec.lua
-- End-to-end: a `.sql` file produced by exporter.exportSQL is routed back through
-- the sql:* transcoder (selected by the Files.tsv `transcoder` column) and loads
-- as the SAME wide, typed table its native .tsv source did. Schema-free: the
-- model column names, type_specs and defaults come from the file's own embedded
-- tabulua_schema table, not from the Files.tsv typeName.
--
-- Pure-Lua throughout: lsqlite3 is never involved, so these run identically on
-- Lua 5.3/5.4/5.5 and LuaJIT (TODO/sql_input_round_trip.md).

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
local serialization = require("serde.serialization")
local sql_schema = require("serde.sql_schema")
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

-- The record every fixture uses. Deliberately covers the three column kinds
-- whose SQL representation is NOT simply the model value:
--   flag  boolean -> SMALLINT 1/0 (SQL has no boolean)
--   id    int64   -> a bare BIGINT literal, read back from its digits
--   loot  {name}  -> a composite, encoded by whichever --data the file used
local TDATA_SPEC = "{name:identifier,n:integer,flag:boolean,id:int64,loot:{name}}"
local DATA_HEADER =
    "name:identifier\tn:integer\tflag:boolean\tid:int64\tloot:{name}\n"
-- The array cell is in the NATIVE wide-TSV form: quoted elements, no outer
-- braces (`"gem","coin"`, as tutorial/core/Item.tsv writes tags:{name}).
local DATA_BODY = DATA_HEADER
    .. 'sword\t100\ttrue\t9007199254740993\t"gem","coin"\n'
    .. 'shield\t50\tfalse\t-9223372036854775808\t"wood"\n'

-- The four cell encodings a .sql export can carry: the exporter's table
-- serializer and the transcoder id are the two halves of one encoding.
local ENCODINGS = {
    {id = "sql:json-typed",   ser = serialization.serializeTableJSON},
    {id = "sql:json-natural", ser = serialization.serializeTableNaturalJSON},
    {id = "sql:xml",          ser = serialization.serializeTableXML},
    {id = "sql:mpk",          ser = serialization.serializeMessagePackSQLBlob},
}

describe("manifest_loader - SQL transcode (Files.tsv-selected)", function()
    local temp_dir = ""
    local log_messages = {}
    local badVal = error_reporting.badValGen()

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "no system temp dir")
        local td = path_join(system_temp, "sqltx_test_" .. tostring(os.time())
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

    -- A record type alias is registered PROCESS-wide, so two tests declaring
    -- `TData` with different fields collide ("already registered to a different
    -- type"). Each package therefore gets its own type name.
    local typeSeq = 0
    local function nextTypeName()
        typeSeq = typeSeq + 1
        return "TData" .. typeSeq
    end

    -- A package around one data file. `dataName` is "data.tsv" (native) or
    -- "data.sql" (transcoded); `transcoder` is nil for the native case.
    -- `typeName`/`typeSpec` default to a fresh name over TDATA_SPEC.
    local function makePkg(pkgName, dataName, dataContent, transcoder,
                           typeName, typeSpec)
        typeName = typeName or nextTypeName()
        typeSpec = typeSpec or TDATA_SPEC
        local pkg_dir = path_join(temp_dir, pkgName)
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME),
            table.concat({
                "package_id:package_id\t" .. pkgName,
                "name:string\t" .. pkgName .. " Package",
                "version:version\t0.1.0",
                "description:markdown\tTest package",
            }, "\n") .. "\n"))

        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"),
            FILES_HEADER
            .. "CustomTypes.tsv\tcustom_type_def\t\ttrue\t1\tCustom types\t\n"
            .. dataName .. "\t" .. typeName .. "\t\tfalse\t2\tData\t"
            .. (transcoder or "") .. "\n"))

        assert(file_util.writeFile(path_join(pkg_dir, "CustomTypes.tsv"),
            "name:name\tparent:type_spec|nil\n"
            .. typeName .. "\t" .. typeSpec .. "\n"))

        assert(file_util.writeFile(path_join(pkg_dir, dataName), dataContent))
        return pkg_dir
    end

    local function findTsv(result, suffix)
        for path, tsv in pairs(result.tsv_files) do
            if path:sub(-#suffix) == suffix then return tsv, path end
        end
        return nil
    end

    -- Loads a native package and exports it as SQL with the given cell
    -- serializer, returning the .sql text. This is the REAL writer, so the test
    -- is a genuine export/import pairing rather than a hand-built fixture.
    local function exportedSQL(tableSerializer)
        local src_dir = makePkg("SqlSrc", "data.tsv", DATA_BODY, nil)
        local msgs = {}
        local bad = error_reporting.badValGen(
            function(_s, m) msgs[#msgs + 1] = m end)
        bad.logger = error_reporting.nullLogger
        local result = manifest_loader.processFiles({src_dir}, bad)
        assert.is_not_nil(result)
        assert.equals(0, bad.errors, table.concat(msgs, " | "))

        local out_dir = path_join(temp_dir, "out")
        assert(lfs.mkdir(out_dir))
        assert.is_true(exporter.exportSQL(result,
            {exportDir = out_dir, tableSerializer = tableSerializer}))

        -- The exporter writes package-namespaced paths, so find the file.
        local found
        local function walk(dir)
            for entry in lfs.dir(dir) do
                if entry ~= "." and entry ~= ".." then
                    local p = path_join(dir, entry)
                    if lfs.attributes(p, "mode") == "directory" then
                        walk(p)
                    elseif entry == "data.sql" then
                        found = p
                    end
                end
            end
        end
        walk(out_dir)
        assert.is_not_nil(found, "exportSQL produced no data.sql")
        local sql = file_util.readFile(found)
        assert.is_not_nil(sql)
        -- Clear the way for the reader-side package: same temp root.
        file_util.deleteTempDir(src_dir)
        return sql, result
    end

    -- The model assertions every encoding must satisfy.
    local function assertModel(tsv)
        assert.is_not_nil(tsv)
        assert.equals(3, #tsv)                 -- header + 2 rows
        local header = tsv[1]
        assert.is_not_nil(header.name)
        assert.is_not_nil(header.loot)
        local int64 = require("util.int64")
        local r1, r2 = tsv[2], tsv[3]
        assert.equals("sword", r1[header.name.idx].parsed)
        assert.equals(100, r1[header.n.idx].parsed)
        assert.is_true(r1[header.flag.idx].parsed)
        assert.equals("9007199254740993",
            int64.tostring(r1[header.id.idx].parsed))
        assert.same({"gem", "coin"}, r1[header.loot.idx].parsed)
        assert.equals("shield", r2[header.name.idx].parsed)
        assert.is_false(r2[header.flag.idx].parsed)
        assert.equals("-9223372036854775808",
            int64.tostring(r2[header.id.idx].parsed))
        assert.same({"wood"}, r2[header.loot.idx].parsed)
    end

    for _, enc in ipairs(ENCODINGS) do
        it("loads an exported .sql through " .. enc.id
            .. " as the same model as its .tsv source", function()
            local sql = exportedSQL(enc.ser)
            local pkg_dir = makePkg("SqlPkg", "data.sql", sql, enc.id)
            local result = manifest_loader.processFiles({pkg_dir}, badVal)
            assert.is_not_nil(result)
            assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
            assertModel(findTsv(result, "data.sql"))
        end)
    end

    it("threads the transcoder id into joinMeta.fn2Transcoder", function()
        local sql = exportedSQL(serialization.serializeTableNaturalJSON)
        local pkg_dir = makePkg("SqlPkg", "data.sql", sql, "sql:json-natural")
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        local _tsv, path = findTsv(result, "data.sql")
        assert.is_not_nil(path)
        assert.equals("sql:json-natural", result.joinMeta.fn2Transcoder[path])
    end)

    it("loads a header-only .sql (no data rows)", function()
        -- exportSQL comments the INSERT out entirely when a file has no rows,
        -- so the reader sees a CREATE TABLE and nothing else. The metadata is
        -- still there, so the header still rebuilds.
        local sql = sql_schema.metadataSQL("data", "data", {
            {name = "name", sqlName = "name", typeSpec = "identifier"},
            {name = "n", sqlName = "n", typeSpec = "integer"},
        }) .. 'CREATE TABLE "data" (\n'
            .. '  "name" TEXT NOT NULL PRIMARY KEY,\n'
            .. '  "n" BIGINT NOT NULL)\n--'
        local pkg_dir = makePkg("SqlPkg", "data.sql", sql, "sql:json-natural",
            nil, "{name:identifier,n:integer}")
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        local tsv = findTsv(result, "data.sql")
        assert.is_not_nil(tsv)
        assert.equals(1, #tsv)                 -- header only
        assert.is_not_nil(tsv[1].name)
        assert.is_not_nil(tsv[1].n)
    end)

    it("carries a column default through, which the type comment could not",
        function()
        local sql = sql_schema.metadataSQL("data", "data", {
            {name = "name", sqlName = "name", typeSpec = "identifier"},
            {name = "n", sqlName = "n", typeSpec = "integer", default = "7"},
        }) .. 'CREATE TABLE "data" (\n'
            .. '  "name" TEXT NOT NULL PRIMARY KEY,\n'
            .. '  "n" BIGINT NOT NULL);\n'
            .. 'INSERT INTO "data" ("name","n") VALUES --\n'
            .. "('sword',3)\n;\n"
        local pkg_dir = makePkg("SqlPkg", "data.sql", sql, "sql:json-natural",
            nil, "{name:identifier,n:integer}")
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        local tsv = findTsv(result, "data.sql")
        assert.is_not_nil(tsv)
        assert.equals("7", tsv[1].n.default_expr)
    end)

    -- ------------------------------------------------------------------
    -- Reversibility: the reformatter rewrites the .sql in place.
    -- ------------------------------------------------------------------

    it("reformatter rewrites data.sql via the sql:* encode, unchanged",
        function()
        -- The strongest statement available: the encode re-emits through the
        -- SAME writer exportSQL uses, so reformatting an exported .sql is a
        -- NO-OP. (The round-trip contract itself is only "normalizing", as for
        -- json/xml -- but there is nothing here for normalizing to change.)
        local sql = exportedSQL(serialization.serializeTableNaturalJSON)
        local pkg_dir = makePkg("SqlPkg", "data.sql", sql, "sql:json-natural")
        local data_path = path_join(pkg_dir, "data.sql")

        reformatter.processFiles({pkg_dir})

        local on_disk = file_util.readFile(data_path)
        assert.is_not_nil(on_disk)
        -- Still SQL -- the native-TSV rewrite would have clobbered it
        assert.matches('CREATE TABLE "data"', on_disk, 1, true)
        assert.matches('"tabulua_schema"', on_disk, 1, true)
        assert.equals(sql, on_disk)
    end)

    it("keeps the table named for its file, across a reformat", function()
        -- The encode gets the file name from the pipeline for exactly this: the
        -- table is named after the file, and an encoder without the name would
        -- rename the user's table on every reformat.
        local sql = exportedSQL(serialization.serializeTableNaturalJSON)
        local pkg_dir = makePkg("SqlPkg", "data.sql", sql, "sql:json-natural")
        reformatter.processFiles({pkg_dir})
        local on_disk = file_util.readFile(path_join(pkg_dir, "data.sql"))
        assert.matches('CREATE TABLE "data"', on_disk, 1, true)
        assert.matches("DELETE FROM \"tabulua_schema\" WHERE \"table_name\" = 'data'",
            on_disk, 1, true)
    end)

    it("re-reads to the same model after a reformat, and is stable", function()
        local sql = exportedSQL(serialization.serializeTableNaturalJSON)
        local pkg_dir = makePkg("SqlPkg", "data.sql", sql, "sql:json-natural")
        local data_path = path_join(pkg_dir, "data.sql")

        reformatter.processFiles({pkg_dir})

        local msgs2 = {}
        local bad2 = error_reporting.badValGen(
            function(_s, m) msgs2[#msgs2 + 1] = m end)
        bad2.logger = error_reporting.nullLogger
        local result = manifest_loader.processFiles({pkg_dir}, bad2)
        assert.is_not_nil(result)
        assert.equals(0, bad2.errors, table.concat(msgs2, " | "))
        assertModel(findTsv(result, "data.sql"))

        -- Reformatting is stable on a second pass.
        local before = file_util.readFile(data_path)
        reformatter.processFiles({pkg_dir})
        assert.equals(before, file_util.readFile(data_path))
    end)

    it("round-trips BLOB columns, whose model value is TEXT", function()
        -- A bytes column is declared BLOB and SQL says nothing more, but the
        -- model value behind it is TEXT -- hex digits for hexbytes, base64 for
        -- base64bytes -- and only the embedded schema can say which. This is
        -- the one cell kind that is not written by serializeSQL at all.
        local spec = "{name:identifier,bitmap:hexbytes,raw:base64bytes}"
        local body = "name:identifier\tbitmap:hexbytes\traw:base64bytes\n"
            .. "icon\t18ff\tYWJj\n"

        local src_dir = makePkg("SqlSrc", "data.tsv", body, nil, nil, spec)
        local msgs = {}
        local bad = error_reporting.badValGen(
            function(_s, m) msgs[#msgs + 1] = m end)
        bad.logger = error_reporting.nullLogger
        local native = manifest_loader.processFiles({src_dir}, bad)
        assert.is_not_nil(native)
        assert.equals(0, bad.errors, table.concat(msgs, " | "))

        local out_dir = path_join(temp_dir, "bout")
        assert(lfs.mkdir(out_dir))
        assert.is_true(exporter.exportSQL(native, {exportDir = out_dir,
            tableSerializer = serialization.serializeTableNaturalJSON}))
        local sql, found
        local function walk(dir)
            for entry in lfs.dir(dir) do
                if entry ~= "." and entry ~= ".." then
                    local p = path_join(dir, entry)
                    if lfs.attributes(p, "mode") == "directory" then
                        walk(p)
                    elseif entry == "data.sql" then
                        found = p
                        sql = file_util.readFile(p)
                    end
                end
            end
        end
        walk(out_dir)
        assert.is_not_nil(found)
        -- hexbytes is a bare X'…' literal (canonicalized to upper case by its
        -- own parser); base64bytes is written as the DECODED bytes
        assert.matches("X'18FF'", sql, 1, true)
        assert.matches("X'616263'", sql, 1, true)
        file_util.deleteTempDir(src_dir)

        local pkg_dir = makePkg("SqlPkg", "data.sql", sql, "sql:json-natural",
            nil, spec)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        local tsv = findTsv(result, "data.sql")
        assert.is_not_nil(tsv)
        local header = tsv[1]
        -- The model TEXT is back, in each column's own encoding
        assert.equals("18FF", tsv[2][header.bitmap.idx].parsed)
        assert.equals("YWJj", tsv[2][header.raw.idx].parsed)

        -- ...and writing it back reproduces the export byte for byte.
        reformatter.processFiles({pkg_dir})
        assert.equals(sql, file_util.readFile(path_join(pkg_dir, "data.sql")))
    end)

    it("loses comment ROWS, the one documented round-trip loss", function()
        -- A `#` line in a native TSV is kept by the native reformatter as a
        -- __comment placeholder row. SQL has no representation for it, so the
        -- SQL round-trip is NORMALIZING AND MILDLY LOSSY -- a step below
        -- json/xml, which lose only formatting. (Column DEFAULTS are not lost:
        -- the metadata table carries them.)
        local commented = DATA_HEADER
            .. "# a note about swords\n"
            .. 'sword\t100\ttrue\t9007199254740993\t"gem","coin"\n'
        local src_dir = makePkg("SqlSrc", "data.tsv", commented, nil)
        local msgs = {}
        local bad = error_reporting.badValGen(
            function(_s, m) msgs[#msgs + 1] = m end)
        bad.logger = error_reporting.nullLogger
        local native = manifest_loader.processFiles({src_dir}, bad)
        assert.is_not_nil(native)
        assert.equals(0, bad.errors, table.concat(msgs, " | "))
        -- The native model DOES carry the comment line...
        local nativeTsv = findTsv(native, "data.tsv")
        assert.matches("# a note about swords", tostring(nativeTsv), 1, true)

        local out_dir = path_join(temp_dir, "cout")
        assert(lfs.mkdir(out_dir))
        assert.is_true(exporter.exportSQL(native, {exportDir = out_dir,
            tableSerializer = serialization.serializeTableNaturalJSON}))
        local sql
        local function walk(dir)
            for entry in lfs.dir(dir) do
                if entry ~= "." and entry ~= ".." then
                    local p = path_join(dir, entry)
                    if lfs.attributes(p, "mode") == "directory" then
                        walk(p)
                    elseif entry == "data.sql" then
                        sql = file_util.readFile(p)
                    end
                end
            end
        end
        walk(out_dir)
        assert.is_not_nil(sql)
        file_util.deleteTempDir(src_dir)

        -- ...and the .sql does not, in either direction.
        assert.is_nil(sql:match("a note about swords"))
        local pkg_dir = makePkg("SqlPkg", "data.sql", sql, "sql:json-natural")
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))
        local tsv = findTsv(result, "data.sql")
        assert.is_not_nil(tsv)
        assert.is_nil(tostring(tsv):match("a note about swords"))
        -- The DATA survived; only the comment row went.
        assert.equals(2, #tsv)
        assert.equals("sword", tsv[2][tsv[1].name.idx].parsed)
    end)

    -- ------------------------------------------------------------------
    -- Refusals. Each names what is wrong rather than importing a wrong shape.
    -- ------------------------------------------------------------------

    local function refuses(sql, pattern)
        local pkg_dir = makePkg("SqlPkg", "data.sql", sql, "sql:json-natural")
        manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_true(badVal.errors > 0, "expected the file to be refused")
        local joined = table.concat(log_messages, " | ")
        assert.matches(pattern, joined)
    end

    it("refuses a .sql with no tabulua_schema table", function()
        -- An older export, or SQL from another tool: the model column names and
        -- types simply are not in the file.
        refuses('CREATE TABLE "data" (\n'
            .. '  "name" TEXT NOT NULL PRIMARY KEY);\n'
            .. 'INSERT INTO "data" ("name") VALUES --\n'
            .. "('sword')\n;\n", "no 'tabulua_schema' table")
    end)

    it("refuses a --collapse-exploded export, naming the flag", function()
        -- The metadata describes the COLLAPSED shape accurately, so the counts
        -- agree and nothing is self-contradicting -- which is exactly why the
        -- file has to say so outright.
        local sql = sql_schema.metadataSQL("data", "data", {
            {name = "name", sqlName = "name", typeSpec = "identifier"},
            {name = "stats", sqlName = "stats",
             typeSpec = "{attack:integer}", isRoot = true},
        }) .. 'CREATE TABLE "data" (\n'
            .. '  "name" TEXT NOT NULL PRIMARY KEY,\n'
            .. '  "stats" TEXT NOT NULL)\n--'
        refuses(sql, "collapse%-exploded")
    end)

    it("refuses a whole-export concatenation (two data tables)", function()
        local one = sql_schema.metadataSQL("data", "data", {
            {name = "name", sqlName = "name", typeSpec = "identifier"},
        }) .. 'CREATE TABLE "data" (\n'
            .. '  "name" TEXT NOT NULL PRIMARY KEY)\n--\n'
        local two = sql_schema.metadataSQL("other", "other", {
            {name = "name", sqlName = "name", typeSpec = "identifier"},
        }) .. 'CREATE TABLE "other" (\n'
            .. '  "name" TEXT NOT NULL PRIMARY KEY)\n--\n'
        refuses(one .. two, "found at least two")
    end)

    it("refuses metadata that does not match the data table", function()
        local sql = sql_schema.metadataSQL("data", "data", {
            {name = "name", sqlName = "name", typeSpec = "identifier"},
            {name = "gone", sqlName = "gone", typeSpec = "integer"},
        }) .. 'CREATE TABLE "data" (\n'
            .. '  "name" TEXT NOT NULL PRIMARY KEY)\n--'
        refuses(sql, "describes 2 column")
    end)

    it("refuses an unterminated literal", function()
        local sql = sql_schema.metadataSQL("data", "data", {
            {name = "name", sqlName = "name", typeSpec = "identifier"},
        }) .. 'CREATE TABLE "data" (\n'
            .. '  "name" TEXT NOT NULL PRIMARY KEY);\n'
            .. 'INSERT INTO "data" ("name") VALUES --\n'
            .. "('unclosed\n;\n"
        refuses(sql, "Unmatched parenthesis")
    end)

    it("refuses an oversized attributes bag", function()
        -- The bag is a preserved payload from a file the reader does not
        -- control, so it is bounded rather than trusted.
        local huge = string.rep("x", sql_schema.MAX_ATTRIBUTES_BYTES + 1)
        local sql = table.concat({
            'CREATE TABLE IF NOT EXISTS "tabulua_schema" (',
            '  "table_name" TEXT NOT NULL);',
            'INSERT INTO "tabulua_schema" VALUES',
            "  ('data','<TABLE>','<TABLE>',0,'<TABLE>',NULL,'{\"app\":{\"x\":\""
                .. huge .. "\"}}'),",
            "  ('data','name','name',1,'identifier',NULL,NULL);",
            'CREATE TABLE "data" (',
            '  "name" TEXT NOT NULL PRIMARY KEY)',
            "--",
        }, "\n")
        refuses(sql, "over the")
    end)
end)
