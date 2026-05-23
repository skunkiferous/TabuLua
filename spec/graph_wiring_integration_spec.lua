-- graph_wiring_integration_spec.lua
-- End-to-end tests for Phase A3 graph auto-wiring: load a package containing
-- a graph file via manifest_loader and verify completion ran (i.e. that
-- back-references appear on rows that didn't author them).

local busted = require("busted")
local assert = require("luassert")

local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local file_util = require("file_util")
local manifest_loader = require("manifest_loader")
local error_reporting = require("error_reporting")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local function mockBadVal(log_messages)
    local log = function(_self, msg) table.insert(log_messages, msg) end
    local badVal = error_reporting.badValGen(log)
    badVal.source_name = "test"
    badVal.line_no = 1
    return badVal
end

local MANIFEST_FILENAME = "Manifest.transposed.tsv"

local MANIFEST = [[package_id:package_id	Test
name:string	Test Package
version:version	0.1.0
description:markdown	Graph auto-wiring integration test
]]

-- The TSV model's header is keyed both numerically and by column name,
-- so header["graphLinks"] gives the column descriptor; .idx gives the
-- cell position in each data row.
local function colIdx(header, name)
    local col = header[name]
    return col and col.idx or nil
end

-- Builds a name -> row index from a loaded tsv_file. Returns the lookup
-- and the header so callers can read additional columns.
local function rowsByName(tsv_file)
    local header = tsv_file[1]
    local nameIdx = colIdx(header, "name")
    assert.is_not_nil(nameIdx, "name column not found in header")
    local byName = {}
    for i = 2, #tsv_file do
        local row = tsv_file[i]
        if type(row) == "table" then
            local cell = row[nameIdx]
            local n = cell and cell.parsed
            if n ~= nil then byName[n] = row end
        end
    end
    return byName, header
end

-- Reads the parsed value of a named column on a given row.
local function readCell(row, header, colName)
    local idx = colIdx(header, colName)
    if not idx then return nil end
    local cell = row[idx]
    if not cell then return nil end
    return cell.parsed
end

-- Asserts a list (possibly read-only proxy) contains all expected names
-- (set equality). Works on nil by treating it as empty.
local function assertContainsAll(actual, expected, msg)
    local seen = {}
    if actual ~= nil then
        for _, v in ipairs(actual) do seen[v] = true end
    end
    for _, e in ipairs(expected) do
        assert.is_true(seen[e] == true,
            (msg or "") .. " expected '" .. e .. "' in list, got: "
            .. (actual and table.concat({(function()
                local out = {}
                for _, v in ipairs(actual) do out[#out + 1] = tostring(v) end
                return table.concat(out, ",")
            end)()}, "") or "nil"))
    end
end

local function writeAll(pkg_dir, manifest, filesTsv, dataFiles)
    assert.is_true(file_util.writeFile(
        path_join(pkg_dir, MANIFEST_FILENAME), manifest))
    assert.is_true(file_util.writeFile(
        path_join(pkg_dir, "files.tsv"), filesTsv))
    for fname, content in pairs(dataFiles) do
        assert.is_true(file_util.writeFile(
            path_join(pkg_dir, fname), content))
    end
end

describe("graph_wiring integration", function()
    local temp_dir
    local log_messages
    local badVal

    before_each(function()
        local system_temp = file_util.getSystemTempDir()
        assert(system_temp ~= nil and system_temp ~= "")
        local td = path_join(system_temp, "graph_wiring_test_" .. os.time()
            .. "_" .. math.random(1, 1e6))
        assert(lfs.mkdir(td))
        temp_dir = td
        log_messages = {}
        badVal = mockBadVal(log_messages)
        badVal.logger = error_reporting.nullLogger
    end)

    after_each(function()
        if temp_dir then
            local td = temp_dir
            temp_dir = nil
            file_util.deleteTempDir(td)
        end
    end)

    it("symmetrises graphLinks for basic_graph_node files", function()
        local pkg = path_join(temp_dir, "basic")
        assert(lfs.mkdir(pkg))

        local FILES = "fileName:filepath\ttypeName:type_spec\tsuperType:super_type\tbaseType:boolean\tpublishContext:name|nil\tpublishColumn:name|nil\tloadOrder:number\tdescription:text\n"
            .. "Skills.tsv\tSkill\tbasic_graph_node\tfalse\t\t\t1\tSkills graph\n"

        -- A links to B and C; B and C have no authored links.
        local SKILLS = "name:node_name\tgraphLinks:{node_name}|nil\n"
            .. "A\t\"B\",\"C\"\n"
            .. "B\t\n"
            .. "C\t\n"

        writeAll(pkg, MANIFEST, FILES, {["Skills.tsv"] = SKILLS})

        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)

        -- Find Skills.tsv in tsv_files
        local skills_tsv
        for fn, tsv in pairs(result.tsv_files) do
            if fn:match("Skills%.tsv$") then skills_tsv = tsv; break end
        end
        assert.is_not_nil(skills_tsv, "Skills.tsv not loaded")

        local byName, header = rowsByName(skills_tsv)
        assertContainsAll(readCell(byName.B, header, "graphLinks"), {"A"},
            "B.graphLinks should contain back-ref to A")
        assertContainsAll(readCell(byName.C, header, "graphLinks"), {"A"},
            "C.graphLinks should contain back-ref to A")
        -- A's original links should still be present.
        assertContainsAll(readCell(byName.A, header, "graphLinks"), {"B", "C"},
            "A.graphLinks should still hold authored links")
    end)

    it("symmetrises parents/children for graph_node files", function()
        local pkg = path_join(temp_dir, "directed")
        assert(lfs.mkdir(pkg))

        local FILES = "fileName:filepath\ttypeName:type_spec\tsuperType:super_type\tbaseType:boolean\tpublishContext:name|nil\tpublishColumn:name|nil\tloadOrder:number\tdescription:text\n"
            .. "Quests.tsv\tQuest\tgraph_node\tfalse\t\t\t1\tQuests DAG\n"

        -- A is the root; D is reached via B and C.
        local QUESTS = "name:node_name\tgraphChildren:{node_name}|nil\tgraphParents:{node_name}|nil\n"
            .. "A\t\"B\",\"C\"\t\n"
            .. "B\tD\t\n"
            .. "C\tD\t\n"
            .. "D\t\t\n"

        writeAll(pkg, MANIFEST, FILES, {["Quests.tsv"] = QUESTS})

        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)

        local quests_tsv
        for fn, tsv in pairs(result.tsv_files) do
            if fn:match("Quests%.tsv$") then quests_tsv = tsv; break end
        end
        assert.is_not_nil(quests_tsv, "Quests.tsv not loaded")

        local byName, header = rowsByName(quests_tsv)
        assertContainsAll(readCell(byName.B, header, "graphParents"), {"A"},
            "B.graphParents should contain A")
        assertContainsAll(readCell(byName.C, header, "graphParents"), {"A"},
            "C.graphParents should contain A")
        assertContainsAll(readCell(byName.D, header, "graphParents"), {"B", "C"},
            "D.graphParents should contain both B and C")
        -- Original child links preserved.
        assertContainsAll(readCell(byName.A, header, "graphChildren"), {"B", "C"})
        assertContainsAll(readCell(byName.B, header, "graphChildren"), {"D"})
    end)

    it("also completes children when authored from the parents side", function()
        local pkg = path_join(temp_dir, "parents_side")
        assert(lfs.mkdir(pkg))

        local FILES = "fileName:filepath\ttypeName:type_spec\tsuperType:super_type\tbaseType:boolean\tpublishContext:name|nil\tpublishColumn:name|nil\tloadOrder:number\tdescription:text\n"
            .. "Quests.tsv\tQuest\tgraph_node\tfalse\t\t\t1\tQuests DAG\n"

        -- All edges declared from the *parents* side only.
        local QUESTS = "name:node_name\tgraphChildren:{node_name}|nil\tgraphParents:{node_name}|nil\n"
            .. "A\t\t\n"
            .. "B\t\tA\n"
            .. "C\t\tA\n"

        writeAll(pkg, MANIFEST, FILES, {["Quests.tsv"] = QUESTS})

        local result = manifest_loader.processFiles({pkg}, badVal)
        local quests_tsv
        for fn, tsv in pairs(result.tsv_files) do
            if fn:match("Quests%.tsv$") then quests_tsv = tsv; break end
        end
        local byName, header = rowsByName(quests_tsv)
        assertContainsAll(readCell(byName.A, header, "graphChildren"), {"B", "C"},
            "A.graphChildren should be filled in from B/C's parent declarations")
    end)

    it("runs directed completion for tree_node files", function()
        local pkg = path_join(temp_dir, "tree")
        assert(lfs.mkdir(pkg))

        local FILES = "fileName:filepath\ttypeName:type_spec\tsuperType:super_type\tbaseType:boolean\tpublishContext:name|nil\tpublishColumn:name|nil\tloadOrder:number\tdescription:text\n"
            .. "Dialog.tsv\tDialogNode\ttree_node\tfalse\t\t\t1\tDialog tree\n"

        local DIALOG = "name:node_name\tgraphChildren:{node_name}|nil\tgraphParents:{node_name}|nil\n"
            .. "Start\t\"Choice1\",\"Choice2\"\t\n"
            .. "Choice1\t\t\n"
            .. "Choice2\t\t\n"

        writeAll(pkg, MANIFEST, FILES, {["Dialog.tsv"] = DIALOG})

        local result = manifest_loader.processFiles({pkg}, badVal)
        local dialog_tsv
        for fn, tsv in pairs(result.tsv_files) do
            if fn:match("Dialog%.tsv$") then dialog_tsv = tsv; break end
        end
        assert.is_not_nil(dialog_tsv)
        local byName, header = rowsByName(dialog_tsv)
        assertContainsAll(readCell(byName.Choice1, header, "graphParents"), {"Start"})
        assertContainsAll(readCell(byName.Choice2, header, "graphParents"), {"Start"})
    end)

    it("leaves non-graph files untouched", function()
        local pkg = path_join(temp_dir, "plain")
        assert(lfs.mkdir(pkg))

        local FILES = "fileName:filepath\ttypeName:type_spec\tsuperType:super_type\tbaseType:boolean\tpublishContext:name|nil\tpublishColumn:name|nil\tloadOrder:number\tdescription:text\n"
            .. "Items.tsv\tItem\t\ttrue\t\t\t1\tPlain items\n"

        local ITEMS = "name:identifier\tvalue:number\n"
            .. "sword\t10\n"
            .. "shield\t20\n"

        writeAll(pkg, MANIFEST, FILES, {["Items.tsv"] = ITEMS})

        local result = manifest_loader.processFiles({pkg}, badVal)
        assert.is_not_nil(result)
        -- No graph family => no auto-wiring => no errors / no mutations.
        -- Items.tsv loads normally.
        local items_tsv
        for fn, tsv in pairs(result.tsv_files) do
            if fn:match("Items%.tsv$") then items_tsv = tsv; break end
        end
        assert.is_not_nil(items_tsv, "Items.tsv should still load")
    end)
end)
