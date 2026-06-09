-- lua_transcode_integration_spec.lua
-- End-to-end: a `.lua` data file (`return { <header>, <row>, … }`) routed through
-- the lua:tabulua transcoder (selected by the Files.tsv `transcoder` column) loads
-- as a wide, typed table (schema-free). This also asserts the data-vs-code-library
-- routing gate: a `.lua` with a transcoder is parsed as DATA, not loaded as code.
-- The reformatter round-trips the .lua source in place via the id-selected encode.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local lfs = require("lfs")
local file_util = require("file_util")
local manifest_loader = require("manifest_loader")
local reformatter = require("reformatter")
local error_reporting = require("error_reporting")

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

describe("manifest_loader - Lua-file transcode (Files.tsv-selected)", function()
    local temp_dir = ""
    local log_messages = {}
    local badVal = error_reporting.badValGen()

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "no system temp dir")
        local td = path_join(system_temp, "luatx_test_" .. tostring(os.time())
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

    -- A package whose data file `data.lua` is a `return { … }` table, routed through
    -- lua:tabulua. Schema-free (types from the file's own header); the Files.tsv
    -- typeName is a required column, so a matching `TData` record type is defined first.
    local function makePkg(data_lua)
        local pkg_dir = path_join(temp_dir, "LuaPkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, MANIFEST_FILENAME),
            makeManifest("LuaPkg")))

        local files_content = FILES_HEADER
            .. "CustomTypes.tsv\tcustom_type_def\t\ttrue\t1\tCustom types\t\n"
            .. "data.lua\tTData\t\tfalse\t2\tData as Lua\tlua:tabulua\n"
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), files_content))

        assert(file_util.writeFile(path_join(pkg_dir, "CustomTypes.tsv"),
            "name:name\tparent:type_spec|nil\n" ..
            "TData\t{name:identifier,n:integer,loot:{name}}\n"))

        assert(file_util.writeFile(path_join(pkg_dir, "data.lua"), data_lua))
        return pkg_dir
    end

    local function findTsv(result, suffix)
        for path, tsv in pairs(result.tsv_files) do
            if path:sub(-#suffix) == suffix then return tsv, path end
        end
        return nil
    end

    local LUA_BODY = 'return {\n'
        .. '{"name:identifier","n:integer","loot:{name}"},\n'
        .. '{"sword",100,{"gem","coin"}},\n'
        .. '{"shield",50,{"wood"}}\n}'

    it("loads data.lua as DATA (not a code library) and types it (schema-free)", function()
        local pkg_dir = makePkg(LUA_BODY)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))

        -- The data-vs-code-library gate routed the transcoder-assigned .lua to the
        -- data path: it appears in tsv_files as a parsed table.
        local tsv = findTsv(result, "data.lua")
        assert.is_not_nil(tsv)
        assert.equals(3, #tsv)                 -- header + 2 rows
        local header = tsv[1]
        assert.is_not_nil(header.name)
        assert.is_not_nil(header.n)
        assert.is_not_nil(header.loot)
        local r1 = tsv[2]
        assert.equals("sword", r1[header.name.idx].parsed)
        assert.equals(100, r1[header.n.idx].parsed)
        assert.same({"gem", "coin"}, r1[header.loot.idx].parsed)
    end)

    it("threads the transcoder id into joinMeta.fn2Transcoder (for the reformatter)", function()
        local pkg_dir = makePkg(LUA_BODY)
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        local _tsv, path = findTsv(result, "data.lua")
        assert.is_not_nil(path)
        assert.equals("lua:tabulua", result.joinMeta.fn2Transcoder[path])
    end)

    it("reformatter rewrites data.lua via the id-selected encode (round-trip)", function()
        local pkg_dir = makePkg(LUA_BODY)
        local data_path = path_join(pkg_dir, "data.lua")

        reformatter.processFiles({pkg_dir})

        local on_disk = file_util.readFile(data_path)
        assert.is_not_nil(on_disk)
        -- Still a `return { … }` Lua document (not native TSV).
        assert.matches("^return {", on_disk)
        assert.matches('"name:identifier"', on_disk, 1, true)

        -- Re-loading the rewritten file reproduces the same data.
        local msgs2 = {}
        local bad2 = error_reporting.badValGen(function(_s, m) msgs2[#msgs2 + 1] = m end)
        bad2.logger = error_reporting.nullLogger
        local result = manifest_loader.processFiles({pkg_dir}, bad2)
        assert.is_not_nil(result)
        assert.equals(0, bad2.errors, table.concat(msgs2, " | "))
        local tsv = findTsv(result, "data.lua")
        assert.is_not_nil(tsv)
        local header = tsv[1]
        assert.equals("sword", tsv[2][header.name.idx].parsed)
        assert.same({"gem", "coin"}, tsv[2][header.loot.idx].parsed)

        -- Reformatting is stable on a second pass.
        local before = file_util.readFile(data_path)
        reformatter.processFiles({pkg_dir})
        assert.equals(before, file_util.readFile(data_path))
    end)
end)
