-- cog_discovery_spec.lua

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local content_pipeline = require("content_pipeline")
-- Requiring the seed module registers the COG-scan-eligible extensions
-- (md/markdown/html/txt) that cog_discovery reads.
require("builtin_content_stages")
local cog_discovery = require("cog_discovery")
local file_util = require("file_util")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- A file containing a (HTML-style) COG block, so needsCog returns true.
local WITH_BLOCK = table.concat({
    "# Doc",
    "<!---[[[",
    "return 'x'",
    "]]]--->",
    "generated",
    "<!---[[[end]]]--->",
    "",
}, "\n")

-- A file with no COG block.
local NO_BLOCK = "# Just documentation\nnothing to generate here\n"

-- A TSV that *does* contain COG markers (--- style). It must still be ignored by
-- the scan: data files are COG-processed on read, not by this discovery.
local TSV_WITH_BLOCK = table.concat({
    "a:string",
    "---[[[",
    "---return 'x'",
    "---]]]",
    "old",
    "---[[[end]]]",
    "",
}, "\n")

describe("cog_discovery", function()
    local temp_dir

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "no system temp dir")
        local td = path_join(system_temp, "cogdisc_test_" .. os.time()
            .. "_" .. math.random(1000000))
        assert(lfs.mkdir(td))
        temp_dir = td
    end)

    after_each(function()
        content_pipeline.restoreState()
        if temp_dir then
            local td = temp_dir
            temp_dir = nil
            file_util.deleteTempDir(td)
        end
    end)

    local function write(rel, content)
        local full = path_join(temp_dir, rel)
        local parent = file_util.getParentPath(full)
        if parent and not file_util.isDir(parent) then
            assert(file_util.mkdir(parent))
        end
        assert(file_util.writeFile(full, content))
        return full
    end

    -- Returns a set of basenames from a discovery result list.
    local function basenames(list)
        local set = {}
        for _, p in ipairs(list) do
            set[p:match("[^/\\]+$")] = true
        end
        return set
    end

    describe("scan eligibility", function()
        it("includes the registered doc extensions and excludes data ones", function()
            assert.is_true(content_pipeline.isScanEligible("a.md"))
            assert.is_true(content_pipeline.isScanEligible("a.markdown"))
            assert.is_true(content_pipeline.isScanEligible("a.html"))
            assert.is_true(content_pipeline.isScanEligible("a.txt"))
            assert.is_false(content_pipeline.isScanEligible("a.tsv"))
            assert.is_false(content_pipeline.isScanEligible("a.csv"))
            assert.is_false(content_pipeline.isScanEligible("a.json"))
        end)

        it("exposes the eligible extensions sorted", function()
            assert.same({"html", "markdown", "md", "txt"}, content_pipeline.scanExtensions())
        end)
    end)

    describe("discover", function()
        it("finds an eligible file that contains a COG block", function()
            write("withblock.md", WITH_BLOCK)
            local found = cog_discovery.discover({temp_dir})
            assert.equals(1, #found)
            assert.is_true(basenames(found)["withblock.md"])
        end)

        it("skips an eligible file with no COG block", function()
            write("noblock.md", NO_BLOCK)
            assert.equals(0, #cog_discovery.discover({temp_dir}))
        end)

        it("does not double-process a .tsv even when it has COG markers", function()
            write("data.tsv", TSV_WITH_BLOCK)
            assert.equals(0, #cog_discovery.discover({temp_dir}))
        end)

        it("finds .txt and .html templates too", function()
            write("notes.txt", WITH_BLOCK)
            write("page.html", WITH_BLOCK)
            write("plain.md", NO_BLOCK)
            local names = basenames(cog_discovery.discover({temp_dir}))
            assert.is_true(names["notes.txt"])
            assert.is_true(names["page.html"])
            assert.is_nil(names["plain.md"])
        end)

        it("skips files under a .cogignore'd directory subtree", function()
            write("keep.md", WITH_BLOCK)
            write("vendor/skip.md", WITH_BLOCK)
            write("vendor/nested/deep.md", WITH_BLOCK)
            write("vendor/.cogignore", "")
            local names = basenames(cog_discovery.discover({temp_dir}))
            assert.is_true(names["keep.md"])
            assert.is_nil(names["skip.md"])
            assert.is_nil(names["deep.md"])   -- nested under the ignored dir
        end)

        it("respects opt_excludeDirs", function()
            write("keep.md", WITH_BLOCK)
            write("exported/gen.md", WITH_BLOCK)
            local excluded = { [file_util.normalizePath(path_join(temp_dir, "exported"))] = true }
            local names = basenames(cog_discovery.discover({temp_dir}, excluded))
            assert.is_true(names["keep.md"])
            assert.is_nil(names["gen.md"])
        end)

        it("returns an empty list for a directory with no templates", function()
            assert.same({}, cog_discovery.discover({temp_dir}))
        end)
    end)
end)
