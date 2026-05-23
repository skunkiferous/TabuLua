-- graph_wiring_spec.lua
-- Tests for graph_wiring module (Phase A3 of TODO/graph_types.md).

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it

local graph_wiring = require("graph_wiring")

describe("graph_wiring", function()

  describe("detectFamily", function()
    it("recognises the three direct family names", function()
      assert.equals("basic",    graph_wiring.detectFamily("basic_graph_node", {}))
      assert.equals("directed", graph_wiring.detectFamily("graph_node",       {}))
      assert.equals("directed", graph_wiring.detectFamily("tree_node",        {}))
    end)

    it("returns nil for unknown / nil typeNames", function()
      assert.is_nil(graph_wiring.detectFamily("not_a_graph_type", {}))
      assert.is_nil(graph_wiring.detectFamily(nil, {}))
      assert.is_nil(graph_wiring.detectFamily("", {}))
    end)

    it("walks the extends chain transitively", function()
      local extends = {Quest = "graph_node"}
      assert.equals("directed", graph_wiring.detectFamily("Quest", extends))
    end)

    it("walks deep extends chains", function()
      local extends = {A = "B", B = "C", C = "tree_node"}
      assert.equals("directed", graph_wiring.detectFamily("A", extends))
    end)

    it("returns nil when no ancestor is a graph family", function()
      local extends = {A = "B", B = "Custom"}
      assert.is_nil(graph_wiring.detectFamily("A", extends))
    end)

    it("is safe against cycles in the extends map", function()
      local extends = {A = "B", B = "A"}
      assert.is_nil(graph_wiring.detectFamily("A", extends))
    end)

    it("is safe against a self-loop in extends", function()
      assert.is_nil(graph_wiring.detectFamily("A", {A = "A"}))
    end)

    it("honours maxDepth", function()
      -- Without bound, this chain still terminates because graph_node has
      -- no extends entry. The bound is a defensive guard.
      local extends = {}
      for i = 1, 100 do extends["T" .. i] = "T" .. (i + 1) end
      extends.T101 = "graph_node"
      assert.equals("directed",
        graph_wiring.detectFamily("T1", extends, 200))
      -- With a short bound, the search bails out before reaching graph_node.
      assert.is_nil(graph_wiring.detectFamily("T1", extends, 5))
    end)
  end)

  describe("applyAutoWiring", function()
    -- Convenience: collect all validator expression strings attached to a lcfn.
    local function valExprs(fileValidators, lcfn)
      local out = {}
      for _, v in ipairs(fileValidators[lcfn] or {}) do
        out[#out + 1] = (type(v) == "string") and v or v.expr
      end
      return out
    end

    it("attaches basic completion + refs validator for basic_graph_node files", function()
      local pre, fv = {}, {}
      local lcFn2Type = {["skills.tsv"] = "Skill"}
      local extends = {Skill = "basic_graph_node"}
      graph_wiring.applyAutoWiring(pre, fv, lcFn2Type, extends)
      assert.equals(1, #pre["skills.tsv"])
      assert.equals("completeBasicGraph(rows)", pre["skills.tsv"][1].expr)
      assert.equals(50, pre["skills.tsv"][1].priority)
      assert.is_true(pre["skills.tsv"][1].rerunAfterPatches)
      assert.same({"graphRefsExist(rows, 'basic')"}, valExprs(fv, "skills.tsv"))
    end)

    it("attaches directed completion + refs + acyclic for graph_node files", function()
      local pre, fv = {}, {}
      local lcFn2Type = {["quests.tsv"] = "Quest"}
      local extends = {Quest = "graph_node"}
      graph_wiring.applyAutoWiring(pre, fv, lcFn2Type, extends)
      assert.equals("completeDirectedGraph(rows)", pre["quests.tsv"][1].expr)
      assert.same({
        "graphRefsExist(rows, 'directed')",
        "graphAcyclic(rows)",
      }, valExprs(fv, "quests.tsv"))
    end)

    it("attaches directed completion + refs + acyclic + tree-shape for tree_node", function()
      local pre, fv = {}, {}
      local lcFn2Type = {["dialog.tsv"] = "DialogNode"}
      local extends = {DialogNode = "tree_node"}
      graph_wiring.applyAutoWiring(pre, fv, lcFn2Type, extends)
      assert.equals("completeDirectedGraph(rows)", pre["dialog.tsv"][1].expr)
      assert.same({
        "graphRefsExist(rows, 'directed')",
        "graphAcyclic(rows)",
        "graphTreeShape(rows)",
      }, valExprs(fv, "dialog.tsv"))
    end)

    it("leaves non-graph files alone", function()
      local pre, fv = {}, {}
      local lcFn2Type = {["plain.tsv"] = "PlainRecord"}
      local extends = {PlainRecord = "Type"}
      graph_wiring.applyAutoWiring(pre, fv, lcFn2Type, extends)
      assert.is_nil(pre["plain.tsv"])
      assert.is_nil(fv["plain.tsv"])
    end)

    it("prepends the auto-wired entry before user pre-processors", function()
      local userProc = "self.x = self.x or 0"
      local pre = {["quests.tsv"] = {userProc}}
      local fv = {}
      local lcFn2Type = {["quests.tsv"] = "Quest"}
      local extends = {Quest = "graph_node"}
      graph_wiring.applyAutoWiring(pre, fv, lcFn2Type, extends)
      assert.equals(2, #pre["quests.tsv"])
      -- Auto-wired entry must come first so it runs before user processors.
      assert.equals("completeDirectedGraph(rows)", pre["quests.tsv"][1].expr)
      assert.equals(userProc, pre["quests.tsv"][2])
    end)

    it("appends validators AFTER user validators", function()
      local userVal = "self.x > 0 or 'x must be positive'"
      local pre = {}
      local fv = {["quests.tsv"] = {userVal}}
      local lcFn2Type = {["quests.tsv"] = "Quest"}
      local extends = {Quest = "graph_node"}
      graph_wiring.applyAutoWiring(pre, fv, lcFn2Type, extends)
      -- User validator runs first; auto-wired structural checks come after.
      assert.equals(userVal, fv["quests.tsv"][1])
      assert.equals("graphRefsExist(rows, 'directed')", fv["quests.tsv"][2].expr)
      assert.equals("graphAcyclic(rows)",               fv["quests.tsv"][3].expr)
    end)

    it("is idempotent across repeated calls", function()
      local pre, fv = {}, {}
      local lcFn2Type = {["quests.tsv"] = "Quest"}
      local extends = {Quest = "graph_node"}
      graph_wiring.applyAutoWiring(pre, fv, lcFn2Type, extends)
      graph_wiring.applyAutoWiring(pre, fv, lcFn2Type, extends)
      graph_wiring.applyAutoWiring(pre, fv, lcFn2Type, extends)
      assert.equals(1, #pre["quests.tsv"])
      assert.equals(2, #fv["quests.tsv"])
    end)

    it("walks transitive extends to attach to derived types", function()
      local pre, fv = {}, {}
      local lcFn2Type = {["sub_quests.tsv"] = "SubQuest"}
      local extends = {SubQuest = "Quest", Quest = "graph_node"}
      graph_wiring.applyAutoWiring(pre, fv, lcFn2Type, extends)
      assert.equals("completeDirectedGraph(rows)", pre["sub_quests.tsv"][1].expr)
      assert.same({
        "graphRefsExist(rows, 'directed')",
        "graphAcyclic(rows)",
      }, valExprs(fv, "sub_quests.tsv"))
    end)

    it("distinguishes tree_node from graph_node via transitive extends", function()
      -- Two derived types pointing at different family ancestors.
      local pre, fv = {}, {}
      local lcFn2Type = {
        ["tree_kids.tsv"]  = "MyTree",
        ["graph_kids.tsv"] = "MyDag",
      }
      local extends = {MyTree = "tree_node", MyDag = "graph_node"}
      graph_wiring.applyAutoWiring(pre, fv, lcFn2Type, extends)
      assert.same({
        "graphRefsExist(rows, 'directed')",
        "graphAcyclic(rows)",
        "graphTreeShape(rows)",
      }, valExprs(fv, "tree_kids.tsv"))
      assert.same({
        "graphRefsExist(rows, 'directed')",
        "graphAcyclic(rows)",
      }, valExprs(fv, "graph_kids.tsv"))
    end)

    it("errors on non-table arguments", function()
      assert.has_error(function()
        graph_wiring.applyAutoWiring(nil, {}, {}, {})
      end)
      assert.has_error(function()
        graph_wiring.applyAutoWiring({}, nil, {}, {})
      end)
      assert.has_error(function()
        graph_wiring.applyAutoWiring({}, {}, "bad", {})
      end)
      assert.has_error(function()
        graph_wiring.applyAutoWiring({}, {}, {}, "bad")
      end)
    end)
  end)
end)
