-- type_wiring_register_module_spec.lua
-- Tests for type_wiring.registerModule and its three module-level slots
-- (descriptorColumns, sandboxHelpers, enginePostPasses). See Phase 2a of
-- TODO/type_wiring.md.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local after_each = busted.after_each

local type_wiring = require("type_wiring")
require("builtin_wiring")

describe("type_wiring.registerModule", function()

    after_each(function() type_wiring.restoreState() end)

    describe("validation", function()
        it("rejects non-string moduleName", function()
            assert.has_error(function()
                type_wiring.registerModule(nil, {})
            end)
            assert.has_error(function()
                type_wiring.registerModule("", {})
            end)
            assert.has_error(function()
                type_wiring.registerModule(42, {})
            end)
        end)

        it("rejects non-table declarations", function()
            assert.has_error(function()
                type_wiring.registerModule("mod", nil)
            end)
            assert.has_error(function()
                type_wiring.registerModule("mod", "bad")
            end)
        end)

        it("rejects unknown declaration keys", function()
            assert.has_error(function()
                type_wiring.registerModule("mod", {someUnknownKey = {}})
            end)
        end)

        it("rejects per-typeName slots (use register instead)", function()
            assert.has_error(function()
                type_wiring.registerModule("mod", {onLoad = function() end})
            end)
            assert.has_error(function()
                type_wiring.registerModule("mod", {preProcessors = {}})
            end)
            assert.has_error(function()
                type_wiring.registerModule("mod", {fileValidators = {}})
            end)
        end)
    end)

    describe("descriptorColumns", function()
        it("merges identical re-declarations silently", function()
            local parseFn = function(v) return v end
            local decl = {name = "weight", type = "number|nil",
                fieldOnMeta = "lcFn2Weight", parse = parseFn}
            type_wiring.registerModule("modA", {descriptorColumns = {decl}})
            assert.has_no_error(function()
                type_wiring.registerModule("modB", {descriptorColumns = {decl}})
            end)
            local cols = type_wiring.descriptorColumnsByName()
            assert.is_not_nil(cols.weight)
        end)

        it("rejects conflicting redeclaration of the same column name", function()
            type_wiring.registerModule("modA", {descriptorColumns = {
                {name = "weight", type = "number|nil", fieldOnMeta = "lcFn2Weight"},
            }})
            type_wiring.registerModule("modB", {descriptorColumns = {
                {name = "weight", type = "string|nil", fieldOnMeta = "lcFn2Weight"},
            }})
            -- Conflict is surfaced when the union cache is built (accessor call).
            local ok, err = pcall(type_wiring.descriptorColumnsByName)
            assert.is_false(ok)
            assert.is_string(err)
            assert.is_not_nil(err:find("modA", 1, true))
            assert.is_not_nil(err:find("modB", 1, true))
        end)

        it("rejects descriptor columns with missing required fields", function()
            assert.has_error(function()
                type_wiring.registerModule("modA", {descriptorColumns = {
                    {type = "name|nil", fieldOnMeta = "x"},
                }})
            end)
            assert.has_error(function()
                type_wiring.registerModule("modA", {descriptorColumns = {
                    {name = "x", fieldOnMeta = "lcFn2X"},
                }})
            end)
            assert.has_error(function()
                type_wiring.registerModule("modA", {descriptorColumns = {
                    {name = "x", type = "name|nil"},
                }})
            end)
        end)

        it("registers all ten optional Files.tsv columns at engine init", function()
            local cols = type_wiring.descriptorColumnsByName()
            -- Each name maps to the same fieldOnMeta the loader has always used
            -- so downstream consumers of joinMeta keep working unchanged.
            assert.equals("lcFn2Ctx",            cols.publishContext.fieldOnMeta)
            assert.equals("lcFn2Col",            cols.publishColumn.fieldOnMeta)
            assert.equals("lcFn2JoinInto",       cols.joinInto.fieldOnMeta)
            assert.equals("lcFn2JoinColumn",     cols.joinColumn.fieldOnMeta)
            assert.equals("lcFn2Export",         cols.export.fieldOnMeta)
            assert.equals("lcFn2JoinedTypeName", cols.joinedTypeName.fieldOnMeta)
            assert.equals("lcFn2Variant",        cols.variant.fieldOnMeta)
            assert.equals("lcFn2RowValidators",  cols.rowValidators.fieldOnMeta)
            assert.equals("lcFn2FileValidators", cols.fileValidators.fieldOnMeta)
            assert.equals("lcFn2PreProcessors",  cols.preProcessors.fieldOnMeta)
            assert.equals("lcFn2EdgesFor",       cols.edgesFor.fieldOnMeta)
        end)

        it("returns an array via descriptorColumns()", function()
            local cols = type_wiring.descriptorColumns()
            assert.is_table(cols)
            assert.is_true(#cols > 0)
        end)
    end)

    describe("sandboxHelpers", function()
        it("merges processor helpers into sandboxAdditions().processor", function()
            local fn = function() return 42 end
            type_wiring.registerModule("mod", {
                sandboxHelpers = {processor = {myHelper = fn}},
            })
            assert.equals(fn, type_wiring.sandboxAdditions().processor.myHelper)
        end)

        it("merges validator helpers into sandboxAdditions().validator", function()
            local fn = function() return 42 end
            type_wiring.registerModule("mod", {
                sandboxHelpers = {validator = {myHelper = fn}},
            })
            assert.equals(fn, type_wiring.sandboxAdditions().validator.myHelper)
        end)

        it("'both' sugar adds the helper to processor AND validator", function()
            local fn = function() return 42 end
            type_wiring.registerModule("mod", {
                sandboxHelpers = {both = {myHelper = fn}},
            })
            local additions = type_wiring.sandboxAdditions()
            assert.equals(fn, additions.processor.myHelper)
            assert.equals(fn, additions.validator.myHelper)
        end)

        it("treats identical (name, function) pairs as a silent merge", function()
            local fn = function() return 42 end
            type_wiring.registerModule("modA", {
                sandboxHelpers = {processor = {shared = fn}},
            })
            assert.has_no_error(function()
                type_wiring.registerModule("modB", {
                    sandboxHelpers = {processor = {shared = fn}},
                })
                type_wiring.sandboxAdditions()
            end)
        end)

        it("rejects same name with a different function (collision)", function()
            type_wiring.registerModule("modA", {
                sandboxHelpers = {processor = {shared = function() return 1 end}},
            })
            type_wiring.registerModule("modB", {
                sandboxHelpers = {processor = {shared = function() return 2 end}},
            })
            local ok, err = pcall(type_wiring.sandboxAdditions)
            assert.is_false(ok)
            assert.is_string(err)
            assert.is_not_nil(err:find("modA", 1, true))
            assert.is_not_nil(err:find("modB", 1, true))
        end)

        it("rejects non-function helper values", function()
            assert.has_error(function()
                type_wiring.registerModule("mod", {
                    sandboxHelpers = {processor = {bad = "not a function"}},
                })
                type_wiring.sandboxAdditions()
            end)
        end)
    end)

    describe("enginePostPasses", function()
        it("runs every registered pass against (tsv_files, joinMeta, badVal)", function()
            local calls = {}
            type_wiring.registerModule("mod", {
                enginePostPasses = {
                    function(tf, jm, bv)
                        calls[#calls + 1] = {tf = tf, jm = jm, bv = bv}
                        return true
                    end,
                },
            })
            local tsv_files = {a = 1}
            local joinMeta = {b = 2}
            local badVal = {c = 3}
            local ok = type_wiring.runEnginePostPasses(tsv_files, joinMeta, badVal)
            assert.is_true(ok)
            assert.equals(1, #calls)
            assert.equals(tsv_files, calls[1].tf)
            assert.equals(joinMeta, calls[1].jm)
            assert.equals(badVal, calls[1].bv)
        end)

        it("returns false if any pass returns false", function()
            type_wiring.registerModule("mod1", {
                enginePostPasses = {function() return true end},
            })
            type_wiring.registerModule("mod2", {
                enginePostPasses = {function() return false end},
            })
            type_wiring.registerModule("mod3", {
                enginePostPasses = {function() return true end},
            })
            assert.is_false(type_wiring.runEnginePostPasses({}, {}, {}))
        end)

        it("dedups callbacks by function identity", function()
            local fn = function() return true end
            local calls = 0
            type_wiring.registerModule("modA", {enginePostPasses = {fn}})
            type_wiring.registerModule("modB", {enginePostPasses = {fn}})
            -- Wrap fn for counting via a single shared closure
            local realFn = fn
            type_wiring.registerModule("modC", {
                enginePostPasses = {
                    function(...) calls = calls + 1; return realFn(...) end,
                },
            })
            type_wiring.runEnginePostPasses({}, {}, {})
            assert.equals(1, calls)
        end)

        it("rejects non-function entries", function()
            assert.has_error(function()
                type_wiring.registerModule("mod", {
                    enginePostPasses = {"not a function"},
                })
            end)
        end)

        it("is a no-op (true) when no modules register a pass", function()
            -- restoreState (in after_each) drops test additions; built-in
            -- modules in Phase 2a contribute no post-passes either.
            type_wiring.restoreState()
            assert.is_true(type_wiring.runEnginePostPasses({}, {}, {}))
        end)
    end)

    describe("module registration tracking", function()
        it("lists registered modules in insertion order", function()
            type_wiring.registerModule("aModuleA", {
                descriptorColumns = {{name = "colA", type = "name|nil", fieldOnMeta = "lcFn2A"}},
            })
            type_wiring.registerModule("aModuleB", {
                descriptorColumns = {{name = "colB", type = "name|nil", fieldOnMeta = "lcFn2B"}},
            })
            local mods = type_wiring._getRegisteredModules()
            -- The built-in feature modules from builtin_wiring come first; our
            -- two test modules should appear and be ordered after them.
            local positions = {}
            for i, m in ipairs(mods) do positions[m] = i end
            assert.is_not_nil(positions["aModuleA"])
            assert.is_not_nil(positions["aModuleB"])
            assert.is_true(positions["aModuleA"] < positions["aModuleB"])
        end)
    end)
end)
