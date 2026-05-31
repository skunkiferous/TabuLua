-- content_pipeline_bootstrap_spec.lua
-- Phase 4 Part A: a package `bootstrap` can register custom content-pipeline
-- stages (e.g. a transcoder) via the shared bootstrap api.

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local content_pipeline = require("content_pipeline")
require("builtin_content_stages")
local manifest_loader = require("manifest_loader")
local file_util = require("file_util")
local error_reporting = require("error_reporting")
local global_reset = require("global_reset")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local function newBadVal()
    local bv = {messages = {}}
    return setmetatable(bv, {__call = function(self, _val, msg)
        self.messages[#self.messages + 1] = msg
    end})
end

describe("content_pipeline.makeBootstrapAPI", function()
    after_each(function() content_pipeline.restoreState() end)

    it("returns a registerStage function and a seal function", function()
        local reg, seal = content_pipeline.makeBootstrapAPI()
        assert.is_function(reg)
        assert.is_function(seal)
    end)

    it("registers a stage that the pipeline then dispatches", function()
        local reg = content_pipeline.makeBootstrapAPI()
        reg("boot_test", {
            phase = "transcode", id = "semi:tsv",
            transform = function(_n, c) return (c:gsub(";", "\t")) end,
        })
        local out = content_pipeline.run("d.txt", "a:string;b:integer\nx;1\n", {},
            newBadVal(), {transcoder = "semi:tsv"})
        assert.equals("a:string\tb:integer\nx\t1\n", out)
    end)

    it("errors when used after seal()", function()
        local reg, seal = content_pipeline.makeBootstrapAPI()
        seal()
        local ok, err = pcall(reg, "late", {
            phase = "macro", matches = function() return true end,
            transform = function() end,
        })
        assert.is_false(ok)
        assert.is_not_nil(tostring(err):find("bootstrap phase has ended", 1, true))
    end)

    it("validates the spec (a bad phase is rejected)", function()
        local reg = content_pipeline.makeBootstrapAPI()
        assert.has_error(function()
            reg("bad", {phase = "nope", matches = function() return true end,
                transform = function() end})
        end)
    end)
end)

describe("manifest_loader - bootstrap-registered transcoder", function()
    local temp_dir = ""
    local log_messages = {}
    local badVal = error_reporting.badValGen()

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "no system temp dir")
        local td = path_join(system_temp, "cpboot_test_" .. tostring(os.time())
            .. "_" .. tostring(math.random(1000000)))
        assert(lfs.mkdir(td))
        temp_dir = td
        log_messages = {}
        badVal = error_reporting.badValGen(function(_self, msg)
            log_messages[#log_messages + 1] = msg
        end)
        badVal.logger = error_reporting.nullLogger
    end)

    after_each(function()
        -- Clears parser types, type wiring, AND the bootstrap-registered stage.
        global_reset.reset()
        if temp_dir ~= "" then
            file_util.deleteTempDir(temp_dir)
            temp_dir = ""
        end
    end)

    -- A package whose code library's bootstrap registers a `semi:tsv` transcoder
    -- (semicolons -> tabs), used by a .txt data file via the Files.tsv transcoder
    -- column. The header lives in the file, so no schema/typeName lookup is needed.
    local function makePkg()
        local pkg_dir = path_join(temp_dir, "BootPkg")
        assert(lfs.mkdir(pkg_dir))
        assert(lfs.mkdir(path_join(pkg_dir, "libs")))

        local manifest = table.concat({
            "package_id:package_id\tBootPkg",
            "name:string\tBootPkg Package",
            "version:version\t0.1.0",
            "description:markdown\tTest package",
            'code_libraries:{{name,string}}|nil\t{"semilib","libs/semilib.lua"}',
            'bootstrap:{{fn:name,library:name}}|nil\t{fn="bootstrap",library="semilib"}',
        }, "\n") .. "\n"
        assert(file_util.writeFile(path_join(pkg_dir, "Manifest.transposed.tsv"), manifest))

        assert(file_util.writeFile(path_join(pkg_dir, "libs", "semilib.lua"), [[
local M = {}
function M.bootstrap(api)
    api.registerContentStage("semilib", {
        phase = "transcode",
        id = "semi:tsv",
        transform = function(name, content, env, badVal, ctx)
            return (content:gsub(";", "\t"))
        end,
    })
end
return M
]]))

        local files = table.concat({
            "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
                .. "\tbaseType:boolean\tloadOrder:number\tdescription:text\ttranscoder:string|nil",
            "data.txt\tSemiItem\t\tfalse\t1\tSemi data\tsemi:tsv",
        }, "\n") .. "\n"
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), files))

        assert(file_util.writeFile(path_join(pkg_dir, "data.txt"),
            "name:identifier;price:integer\nsword;100\nshield;50\n"))
        return pkg_dir
    end

    it("loads a .txt file through a transcoder registered by a bootstrap", function()
        local pkg_dir = makePkg()
        local result = manifest_loader.processFiles({pkg_dir}, badVal)
        assert.is_not_nil(result)
        assert.equals(0, badVal.errors, table.concat(log_messages, " | "))

        local tsv, path
        for p, t in pairs(result.tsv_files) do
            if p:sub(-#"data.txt") == "data.txt" then tsv, path = t, p end
        end
        assert.is_not_nil(tsv, "data.txt was not parsed")
        assert.equals(3, #tsv)   -- header + 2 rows
        local header = tsv[1]
        assert.equals("sword", tsv[2][header.name.idx].parsed)
        assert.equals(100, tsv[2][header.price.idx].parsed)
        assert.equals("shield", tsv[3][header.name.idx].parsed)
    end)
end)
