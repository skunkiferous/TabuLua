-- skillDoc.lua - Documentation-rendering library for the Shadow Realm expansion.
-- Registered in the expansion's Manifest.transposed.tsv and used by the COG block
-- in SkillTree.md to render the skill DAG as an ASCII graph (v0.22.0).
--
-- WHY A CODE LIBRARY (and not the COG block itself)?
--   For organisation and reuse, not capability. As of v0.22.0 COG doc blocks
--   and code libraries share the SAME safe sandbox (math, the curated
--   string/table libraries incl. table.concat, and the predicates / stringUtils
--   / tableUtils / equals helpers), so this logic could just as well run inline.
--   Keeping it in a library makes the COG block a readable one-liner
--   (`return skillDoc.skillTreeAscii(files)`) and lets the renderer be reused
--   and unit-tested independently of the document.
--
-- It reads the already-loaded datasets passed in as `files`, keyed by file name
-- (files["SkillTree.tsv"]) or type name (files["SkillTree"]). Each dataset is a
-- list whose row 1 is the header descriptor (column name -> {idx=...}); data rows
-- are tables whose cells carry a `.parsed` value. Array cells (graphParents /
-- graphChildren) parse to a plain Lua list of strings, or nil when empty. By the
-- time docs are generated the graph completion pre-processor has already filled in
-- graphChildren in memory, so the tree can be walked top-down from the roots.
local M = {}

-- Returns a dataset by file name or type name, or nil.
local function dataset(files, fileName, typeName)
    return files[fileName] or files[typeName]
end

-- A cell's parsed array, or an empty list when the cell is nil/empty.
local function listOf(cell)
    if cell and type(cell.parsed) == "table" then
        return cell.parsed
    end
    return {}
end

-- Renders the SkillTree DAG (with per-edge required levels from SkillEdges) as an
-- ASCII tree inside a fenced ```text block. Multi-parent skills appear under each
-- of their parents — the natural way to draw a DAG, and a visible reminder that
-- `tracking` and `huntersMark` each have more than one prerequisite.
function M.skillTreeAscii(files)
    local nodes = dataset(files, "SkillTree.tsv", "SkillTree")
    local edges = dataset(files, "SkillEdges.tsv", "SkillEdge")
    if not nodes or type(nodes[1]) ~= "table" then
        return "_(SkillTree data not available)_"
    end

    -- Collect node info, preserving file order for stable, author-meaningful output.
    local h = nodes[1]
    local info, order = {}, {}
    for i = 2, #nodes do
        local row = nodes[i]
        if type(row) == "table" then
            local name = row[h.name.idx].parsed
            info[name] = {
                maxLevel = row[h.maxLevel.idx].parsed,
                parents  = listOf(row[h.graphParents.idx]),
                children = listOf(row[h.graphChildren.idx]),
            }
            order[#order + 1] = name
        end
    end

    -- Per-edge required parent level, keyed "<parent>__<child>" (directed_edge_key).
    local req = {}
    if edges and type(edges[1]) == "table" then
        local eh = edges[1]
        for i = 2, #edges do
            local row = edges[i]
            if type(row) == "table" then
                req[row[eh.name.idx].parsed] = row[eh.requiredLevel.idx].parsed
            end
        end
    end

    local out = {}
    ---@param name string
    ---@param parent string|nil
    local function label(name, parent)
        local node = info[name] or {}
        local s = string.format("%s (max %s)", name, tostring(node.maxLevel or "?"))
        if parent then
            local rl = req[parent .. "__" .. name]
            if rl then
                s = s .. string.format("  -- needs %s lvl %s", parent, tostring(rl))
            end
        end
        return s
    end
    -- Print the children of `name`, each child line prefixed by `prefix`.
    local function walk(name, prefix)
        local kids = (info[name] or {}).children or {}
        for i, child in ipairs(kids) do
            local last = (i == #kids)
            out[#out + 1] = prefix .. (last and "`-- " or "|-- ") .. label(child, name)
            walk(child, prefix .. (last and "    " or "|   "))
        end
    end

    out[#out + 1] = "```text"
    for _, name in ipairs(order) do
        if #info[name].parents == 0 then
            out[#out + 1] = label(name)
            walk(name, "")
        end
    end
    out[#out + 1] = "```"
    return table.concat(out, "\n")
end

return M
