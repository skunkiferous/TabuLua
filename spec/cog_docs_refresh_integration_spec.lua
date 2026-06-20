-- cog_docs_refresh_integration_spec.lua
-- cog_markdown Phase 3: reformatter.refreshDocs (the --cog-docs mode) rewrites a
-- checked-in COG doc template in place against the loaded data, keeping markers.

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local file_util = require("infra.file_util")
local reformatter = require("reformatter")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local MANIFEST = table.concat({
    "package_id:package_id\tP",
    "name:string\tP Package",
    "version:version\t0.1.0",
    "description:markdown\tt",
}, "\n") .. "\n"

local FILES = table.concat({
    "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
        .. "\tbaseType:boolean\tloadOrder:number\tdescription:text",
    "Item.tsv\tItem\t\tfalse\t1\tItems",
}, "\n") .. "\n"

local ITEM_TSV = "name:identifier\tprice:integer\nsword\t100\nshield\t50\n"

-- A checked-in README with a COG block and a STALE generated region.
local README = table.concat({
    "# Project",
    "<!---[[[",
    "return \"item count: \" .. tostring(#files[\"Item\"] - 1)",
    "]]]--->",
    "STALE",
    "<!---[[[end]]]--->",
    "trailing prose",
    "",
}, "\n")

describe("reformatter.refreshDocs (--cog-docs)", function()
    local temp_dir = ""

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "no system temp dir")
        local td = path_join(system_temp, "cogdocs_test_" .. tostring(os.time())
            .. "_" .. tostring(math.random(1000000)))
        assert(lfs.mkdir(td))
        temp_dir = td
    end)

    after_each(function()
        if temp_dir ~= "" then
            file_util.deleteTempDir(temp_dir)
            temp_dir = ""
        end
    end)

    local function makePkg()
        local pkg_dir = path_join(temp_dir, "P")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, "Manifest.transposed.tsv"), MANIFEST))
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), FILES))
        assert(file_util.writeFile(path_join(pkg_dir, "Item.tsv"), ITEM_TSV))
        assert(file_util.writeFile(path_join(pkg_dir, "README.md"), README))
        return pkg_dir
    end

    it("rewrites the source template in place, regenerating the COG region", function()
        local pkg_dir = makePkg()
        local readme = path_join(pkg_dir, "README.md")

        reformatter.refreshDocs({pkg_dir})

        local refreshed = file_util.readFile(readme)
        assert.is_not_nil(refreshed)
        assert.matches("item count: 2", refreshed)   -- regenerated from the data
        assert.is_nil(refreshed:find("STALE"))        -- the stale region was replaced
        -- Markers are KEPT so the file stays re-runnable.
        assert.is_not_nil(refreshed:find("<!%-%-%-%[%[%["))
        assert.is_not_nil(refreshed:find("<!%-%-%-%[%[%[end%]%]%]%-%-%->"))
        -- Surrounding prose is preserved.
        assert.matches("# Project", refreshed)
        assert.matches("trailing prose", refreshed)
    end)

    it("is idempotent: a second refresh changes nothing", function()
        local pkg_dir = makePkg()
        local readme = path_join(pkg_dir, "README.md")

        reformatter.refreshDocs({pkg_dir})
        local after1 = file_util.readFile(readme)
        reformatter.refreshDocs({pkg_dir})
        local after2 = file_util.readFile(readme)
        assert.equals(after1, after2)
    end)

    it("leaves a COG-less doc untouched", function()
        local pkg_dir = makePkg()
        local plain = path_join(pkg_dir, "NOTES.md")
        local original = "# Notes\njust prose, no cog\n"
        assert(file_util.writeFile(plain, original))

        reformatter.refreshDocs({pkg_dir})

        assert.equals(original, file_util.readFile(plain))
    end)
end)
