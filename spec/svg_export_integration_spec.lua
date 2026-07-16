-- svg_export_integration_spec.lua
-- End-to-end for `--file=svg` (Phase 3 of TODO/graph_svg_export.md): a
-- graph_node file is drawn to exported/svg-svg/<name>.svg with one box per node
-- and one edge per parent link, while non-graph files in the same package are
-- skipped (no .svg emitted for them).

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

local function countOccur(haystack, needle)
    local count, pos = 0, 1
    while true do
        local s = haystack:find(needle, pos, true)
        if not s then break end
        count = count + 1
        pos = s + 1
    end
    return count
end

local MANIFEST = table.concat({
    "package_id:package_id\tGraphPkg",
    "name:string\tGraph Package",
    "version:version\t0.1.0",
    "description:markdown\tTest package",
}, "\n") .. "\n"

local FILES = table.concat({
    "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
        .. "\tbaseType:boolean\tloadOrder:number\tdescription:text",
    "Skill.tsv\tSkill\tgraph_node\tfalse\t1\tSkill DAG",
    "Item.tsv\tItem\t\tfalse\t2\tPlain items (not a graph)",
}, "\n") .. "\n"

-- A small DAG: roots a, b; c depends on both a and b (multi-parent); d on a.
-- Authors declare prerequisites on graphParents; the engine fills graphChildren.
local SKILL_TSV = table.concat({
    "name:node_name\tgraphParents:{node_name}|nil\tgraphChildren:{node_name}|nil\tdescription:text",
    "a\t\t\tRoot A",
    "b\t\t\tRoot B",
    'c\t"a","b"\t\tChild of A and B',
    "d\ta\t\tChild of A",
}, "\n") .. "\n"

local ITEM_TSV = "name:identifier\tprice:integer\nsword\t100\nshield\t50\n"

describe("--file=svg export (graph_svg_export Phase 3)", function()
    local temp_dir = ""

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "", "no system temp dir")
        local td = path_join(system_temp, "svgexp_test_" .. tostring(os.time())
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
        local pkg_dir = path_join(temp_dir, "GraphPkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, "Manifest.transposed.tsv"), MANIFEST))
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), FILES))
        assert(file_util.writeFile(path_join(pkg_dir, "Skill.tsv"), SKILL_TSV))
        assert(file_util.writeFile(path_join(pkg_dir, "Item.tsv"), ITEM_TSV))
        return pkg_dir
    end

    it("draws the graph_node file and skips the non-graph file", function()
        local pkg_dir = makePkg()
        local export_dir = path_join(temp_dir, "out")
        reformatter.processFiles({pkg_dir},
            {{fn = exporter.exportSVG, subdir = "svg-svg"}},
            {exportDir = export_dir})

        -- The graph file is drawn; the plain file gets no .svg.
        local svg = file_util.readFile(path_join(export_dir, "svg-svg", "Skill.svg"))
        assert.is_not_nil(svg, "Skill.svg was not generated")
        assert.is_nil(file_util.readFile(path_join(export_dir, "svg-svg", "Item.svg")),
            "Item.svg should not exist — Item is not a graph")

        -- One box per node (a, b, c, d).
        assert.equal(4, countOccur(svg, "<rect "))
        -- One edge per parent link: a->c, b->c, a->d.
        assert.equal(3, countOccur(svg, "<polyline "))
        -- Directed family → arrowhead marker present.
        assert.is_truthy(svg:find("<marker ", 1, true))
        -- Crossing count is surfaced.
        assert.is_truthy(svg:find("<!-- crossings:", 1, true))
        -- Every node label appears.
        for _, n in ipairs({"a", "b", "c", "d"}) do
            assert.is_truthy(svg:find(">" .. n .. "</text>", 1, true),
                "missing label for node " .. n)
        end
    end)

    it("colours edges by source node when an edge palette is given", function()
        local pkg_dir = makePkg()
        local export_dir = path_join(temp_dir, "pal")
        reformatter.processFiles({pkg_dir},
            {{fn = exporter.exportSVG, subdir = "svg-svg"}},
            {exportDir = export_dir, svgEdgePalette = {"#111111", "#222222"}})

        local svg = file_util.readFile(path_join(export_dir, "svg-svg", "Skill.svg"))
        assert.is_not_nil(svg)
        -- Roots a and b are different sources → different palette colours,
        -- each with its own matching arrowhead marker; the single-colour
        -- default is not used.
        assert.is_truthy(svg:find('stroke="#111111"', 1, true))
        assert.is_truthy(svg:find('stroke="#222222"', 1, true))
        assert.is_truthy(svg:find('id="arrow1"', 1, true))
        assert.is_truthy(svg:find('id="arrow2"', 1, true))
        assert.is_nil(svg:find('stroke="#888888"', 1, true))
    end)

    it("draws an undirected (basic_graph_node) file without arrowheads", function()
        -- A basic graph with a triangle cycle (a-b-c) and a disconnected
        -- component (x-y) — both legal for basic graphs.
        local files = table.concat({
            "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
                .. "\tbaseType:boolean\tloadOrder:number\tdescription:text",
            "Net.tsv\tNet\tbasic_graph_node\tfalse\t1\tPeer network",
        }, "\n") .. "\n"
        local net = table.concat({
            "name:node_name\tgraphLinks:{node_name}|nil\tdescription:text",
            'a\t"b","c"\tHub',
            'b\t"a","c"\tPeer',
            'c\t"a","b"\tPeer',
            'x\t"y"\tOther component',
            'y\t"x"\tOther component',
        }, "\n") .. "\n"

        local pkg_dir = path_join(temp_dir, "NetPkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, "Manifest.transposed.tsv"),
            MANIFEST:gsub("GraphPkg", "NetPkg")))
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), files))
        assert(file_util.writeFile(path_join(pkg_dir, "Net.tsv"), net))

        local export_dir = path_join(temp_dir, "netout")
        reformatter.processFiles({pkg_dir},
            {{fn = exporter.exportSVG, subdir = "svg-svg"}},
            {exportDir = export_dir})

        local svg = file_util.readFile(path_join(export_dir, "svg-svg", "Net.svg"))
        assert.is_not_nil(svg, "Net.svg was not generated")
        assert.equal(5, countOccur(svg, "<rect "))       -- a,b,c,x,y
        assert.is_nil(svg:find("<marker ", 1, true))     -- undirected: no arrows
        assert.is_nil(svg:find("marker-end", 1, true))
        for _, n in ipairs({"a", "b", "c", "x", "y"}) do
            assert.is_truthy(svg:find(">" .. n .. "</text>", 1, true),
                "missing label for node " .. n)
        end
    end)

    it("labels edges from the attached edgesFor edge file", function()
        local files = table.concat({
            "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
                .. "\tbaseType:boolean\tloadOrder:number\tedgesFor:filepath|nil"
                .. "\tdescription:text",
            "Skill.tsv\tSkill\tgraph_node\tfalse\t1\t\tSkill DAG",
            "SkillEdge.tsv\tSkillEdge\tgraph_edge\tfalse\t2\tSkill.tsv\tPer-edge data",
        }, "\n") .. "\n"
        -- Edge keys are "<parent>__<child>"; every one must match a declared link.
        local edges = table.concat({
            "name:directed_edge_key\tweight:ubyte\tcomment:comment|nil",
            "a__c\t5\tedge a-c",
            "b__c\t3\tedge b-c",
            "a__d\t1\tedge a-d",
        }, "\n") .. "\n"

        local pkg_dir = path_join(temp_dir, "EdgePkg")
        assert(lfs.mkdir(pkg_dir))
        assert(file_util.writeFile(path_join(pkg_dir, "Manifest.transposed.tsv"),
            MANIFEST:gsub("GraphPkg", "EdgePkg")))
        assert(file_util.writeFile(path_join(pkg_dir, "files.tsv"), files))
        assert(file_util.writeFile(path_join(pkg_dir, "Skill.tsv"), SKILL_TSV))
        assert(file_util.writeFile(path_join(pkg_dir, "SkillEdge.tsv"), edges))

        -- Default (labels on): the weight of each edge appears in the diagram.
        local on_dir = path_join(temp_dir, "labels_on")
        reformatter.processFiles({pkg_dir},
            {{fn = exporter.exportSVG, subdir = "svg-svg"}}, {exportDir = on_dir})
        local svg = file_util.readFile(path_join(on_dir, "svg-svg", "Skill.svg"))
        assert.is_not_nil(svg)
        for _, w in ipairs({"5", "3", "1"}) do
            assert.is_truthy(svg:find(">" .. w .. "</text>", 1, true),
                "missing edge label " .. w)
        end
        -- The edge file itself is not drawn.
        assert.is_nil(file_util.readFile(path_join(on_dir, "svg-svg", "SkillEdge.svg")))

        -- Labels off: the weights are gone.
        local off_dir = path_join(temp_dir, "labels_off")
        reformatter.processFiles({pkg_dir},
            {{fn = exporter.exportSVG, subdir = "svg-svg"}},
            {exportDir = off_dir, svgLabelEdges = false})
        local svg2 = file_util.readFile(path_join(off_dir, "svg-svg", "Skill.svg"))
        assert.is_not_nil(svg2)
        assert.is_nil(svg2:find(">5</text>", 1, true))
    end)

    it("is byte-identical across two exports of the same data", function()
        local pkg_dir = makePkg()
        local a_dir = path_join(temp_dir, "a")
        local b_dir = path_join(temp_dir, "b")
        reformatter.processFiles({pkg_dir},
            {{fn = exporter.exportSVG, subdir = "svg-svg"}}, {exportDir = a_dir})
        reformatter.processFiles({pkg_dir},
            {{fn = exporter.exportSVG, subdir = "svg-svg"}}, {exportDir = b_dir})
        local a = file_util.readFile(path_join(a_dir, "svg-svg", "Skill.svg"))
        local b = file_util.readFile(path_join(b_dir, "svg-svg", "Skill.svg"))
        assert.is_not_nil(a)
        assert.equal(a, b)
    end)
end)
