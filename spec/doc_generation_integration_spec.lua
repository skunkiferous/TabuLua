-- doc_generation_integration_spec.lua
-- End-to-end CP Phase 5b: a .md COG template is expanded against the loaded data
-- at export time and written to the export dir; it is NOT copied verbatim by the
-- per-format exporters; the source template is never modified.

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local file_util = require("infra.file_util")
local reformatter = require("reformatter")
local exporter = require("serde.exporter")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local MANIFEST = table.concat({
    "package_id:package_id\tDocPkg",
    "name:string\tDocPkg Package",
    "version:version\t0.1.0",
    "description:markdown\tTest package",
}, "\n") .. "\n"

local FILES = table.concat({
    "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
        .. "\tbaseType:boolean\tloadOrder:number\tdescription:text",
    "Item.tsv\tItem\t\tfalse\t1\tItems",
}, "\n") .. "\n"

local ITEM_TSV = "name:identifier\tprice:integer\nsword\t100\nshield\t50\n"

-- A doc template that lists item names — reads data by BOTH typeName and filename
-- to exercise the combined env. (Builds its string with `..` in a loop; the COG
-- sandbox does have table.concat, this just keeps the fixture self-contained.)
local REPORT_MD = table.concat({
    "# Item Report",
    "<!---[[[",
    "local rows = files[\"Item\"]",
    "local also = files[\"Item.tsv\"]   -- filename key resolves to the same data",
    "local s = \"count=\" .. tostring(#also - 1) .. \": \"",
    "local first = true",
    "for i = 2, #rows do",
    "  if type(rows[i]) == \"table\" then",
    "    if not first then s = s .. \", \" end",
    "    first = false",
    "    s = s .. tostring(rows[i][1].parsed)",
    "  end",
    "end",
    "return s",
    "]]]--->",
    "OLD CONTENT",
    "<!---[[[end]]]--->",
    "",
}, "\n")

describe("doc generation (CP Phase 5b)", function()
    local temp_dir = ""

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "no system temp dir")
        local td = path_join(system_temp, "docgen_test_" .. tostring(os.time())
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
        local pkg_dir = path_join(temp_dir, "DocPkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, "Manifest.transposed.tsv"), MANIFEST))
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), FILES))
        assert(file_util.writeFile(path_join(pkg_dir, "Item.tsv"), ITEM_TSV))
        assert(file_util.writeFile(path_join(pkg_dir, "report.md"), REPORT_MD))
        return pkg_dir
    end

    it("expands a doc template against the loaded data at export time", function()
        local pkg_dir = makePkg()
        local export_dir = path_join(temp_dir, "out")
        reformatter.processFiles({pkg_dir},
            {{fn = exporter.exportLuaTSV, subdir = "tsv-lua"}},
            {exportDir = export_dir})

        -- The generated doc is at the export root (mirrors source layout), expanded.
        local generated = file_util.readFile(path_join(export_dir, "report.md"))
        assert.is_not_nil(generated, "report.md was not generated")
        assert.matches("count=2: sword, shield", generated)
        assert.is_nil(generated:find("OLD CONTENT"))   -- the old output was replaced
        -- The COG markers are kept (stripCog was not requested).
        assert.is_not_nil(generated:find("<!%-%-%-%[%[%[end%]%]%]%-%-%->"))

        -- The template is NOT copied verbatim into the per-format export subdir.
        assert.is_nil(file_util.readFile(path_join(export_dir, "tsv-lua", "report.md")))

        -- The source template on disk is unchanged.
        local src = file_util.readFile(path_join(pkg_dir, "report.md"))
        assert.matches("OLD CONTENT", src)
    end)

    it("strips COG scaffolding from the generated doc when stripCog is set", function()
        local pkg_dir = makePkg()
        local export_dir = path_join(temp_dir, "out")
        reformatter.processFiles({pkg_dir},
            {{fn = exporter.exportLuaTSV, subdir = "tsv-lua"}},
            {exportDir = export_dir, stripCog = true})

        local generated = file_util.readFile(path_join(export_dir, "report.md"))
        assert.is_not_nil(generated)
        assert.matches("count=2: sword, shield", generated)
        -- No COG scaffolding left in the published doc.
        assert.is_nil(generated:find("%[%[%["))
        assert.matches("# Item Report", generated)
    end)
end)
