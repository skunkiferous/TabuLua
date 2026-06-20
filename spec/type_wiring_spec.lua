-- type_wiring_spec.lua
-- Tests for the type_wiring registry (Phase 1 of TODO/type_wiring.md).

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local after_each = busted.after_each

local type_wiring = require("wiring.type_wiring")
-- Loading builtin_wiring registers the three built-in onLoad handlers
-- (Type, enum, custom_type_def) and snapshots the registry, so after each
-- test we can call restoreState() to drop test-only additions and get
-- back to the built-in baseline.
require("wiring.builtin_wiring")

describe("type_wiring", function()

    after_each(function()
        -- Drop any test-registered entries, keep built-ins.
        type_wiring.restoreState()
    end)

    describe("register", function()
        it("accepts an onLoad function", function()
            type_wiring.register("MyType", {onLoad = function() end})
            assert.is_true(type_wiring.hasOnLoad("MyType", {}))
        end)

        it("is case-insensitive on lookup but preserves casing", function()
            type_wiring.register("MyType", {onLoad = function() end})
            assert.is_true(type_wiring.hasOnLoad("mytype", {}))
            assert.is_true(type_wiring.hasOnLoad("MYTYPE", {}))
        end)

        it("rejects empty / non-string typeName", function()
            assert.has_error(function() type_wiring.register("", {}) end)
            assert.has_error(function() type_wiring.register(nil, {}) end)
            assert.has_error(function() type_wiring.register(42, {}) end)
        end)

        it("rejects non-table contributions", function()
            assert.has_error(function() type_wiring.register("X", nil) end)
            assert.has_error(function() type_wiring.register("X", "not a table") end)
        end)

        it("rejects unknown contribution keys", function()
            assert.has_error(function()
                type_wiring.register("X", {someUnknownKey = function() end})
            end)
            -- Common typo of onLoad
            assert.has_error(function()
                type_wiring.register("X", {OnLoad = function() end})
            end)
        end)

        it("rejects non-function onLoad", function()
            assert.has_error(function()
                type_wiring.register("X", {onLoad = "not a function"})
            end)
        end)

        it("treats re-registration of the same function as a no-op", function()
            local fn = function() end
            type_wiring.register("X", {onLoad = fn})
            assert.has_no_error(function()
                type_wiring.register("X", {onLoad = fn})
            end)
            assert.is_true(type_wiring.hasOnLoad("X", {}))
        end)

        it("rejects re-registration of a *different* onLoad for the same type", function()
            type_wiring.register("X", {onLoad = function() end})
            assert.has_error(function()
                type_wiring.register("X", {onLoad = function() end})
            end)
        end)
    end)

    describe("hasOnLoad", function()
        it("returns false for unknown typeNames", function()
            assert.is_false(type_wiring.hasOnLoad("UnknownType", {}))
        end)

        it("returns true for the built-in Type / enum / custom_type_def", function()
            assert.is_true(type_wiring.hasOnLoad("Type", {}))
            assert.is_true(type_wiring.hasOnLoad("enum", {}))
            assert.is_true(type_wiring.hasOnLoad("custom_type_def", {}))
        end)

        it("walks the extends chain", function()
            local extends = {MyEnum = "enum"}
            assert.is_true(type_wiring.hasOnLoad("MyEnum", extends))
        end)

        it("walks deep extends chains", function()
            local extends = {A = "B", B = "C", C = "Type"}
            assert.is_true(type_wiring.hasOnLoad("A", extends))
        end)

        it("returns false when nothing in the chain is registered", function()
            local extends = {A = "B", B = "Custom"}
            assert.is_false(type_wiring.hasOnLoad("A", extends))
        end)

        it("is safe against cycles in extends", function()
            local extends = {A = "B", B = "A"}
            assert.is_false(type_wiring.hasOnLoad("A", extends))
        end)

        it("returns false for nil typeName", function()
            assert.is_false(type_wiring.hasOnLoad(nil, {}))
        end)
    end)

    describe("hasOnLoadFor", function()
        it("returns true when ancestorTypeName is the file's own type", function()
            assert.is_true(type_wiring.hasOnLoadFor("Type", {}, "Type"))
        end)

        it("returns true when ancestorTypeName is reached transitively", function()
            local extends = {MyEnum = "enum"}
            assert.is_true(type_wiring.hasOnLoadFor("MyEnum", extends, "enum"))
        end)

        it("returns false when the ancestor isn't in the chain", function()
            local extends = {MyEnum = "enum"}
            assert.is_false(type_wiring.hasOnLoadFor("MyEnum", extends, "Type"))
        end)

        it("returns false when the ancestor isn't registered", function()
            local extends = {MyType = "NotRegistered"}
            assert.is_false(type_wiring.hasOnLoadFor("MyType", extends, "NotRegistered"))
        end)

        it("matches the ancestor name case-insensitively", function()
            -- The extends chain preserves the casing the user wrote; the
            -- *target* ancestor name we pass in compares case-insensitively
            -- against the registered name (e.g. "enum") and against the
            -- ancestor in the chain ("ENUM").
            local extends = {MyEnum = "ENUM"}
            assert.is_true(type_wiring.hasOnLoadFor("MyEnum", extends, "Enum"))
            assert.is_true(type_wiring.hasOnLoadFor("MyEnum", extends, "enum"))
            assert.is_true(type_wiring.hasOnLoadFor("MyEnum", extends, "ENUM"))
        end)

        it("is safe against extends cycles", function()
            local extends = {A = "B", B = "A"}
            assert.is_false(type_wiring.hasOnLoadFor("A", extends, "Type"))
        end)
    end)

    describe("applyWiring", function()
        it("invokes a registered onLoad with the expected arguments", function()
            local captured = nil
            type_wiring.register("MyType", {
                onLoad = function(file, fileType, extends, badVal, loadEnv)
                    captured = {
                        file = file, fileType = fileType,
                        extends = extends, badVal = badVal, loadEnv = loadEnv,
                    }
                end,
            })
            local file = {[1] = {"header"}}
            local extends = {}
            local badVal = {}
            local loadEnv = {}
            type_wiring.applyWiring("MyType", extends,
                {file = file, badVal = badVal, loadEnv = loadEnv})
            assert.is_not_nil(captured)
            assert.equals(file, captured.file)
            assert.equals("MyType", captured.fileType)
            assert.equals(extends, captured.extends)
            assert.equals(badVal, captured.badVal)
            assert.equals(loadEnv, captured.loadEnv)
        end)

        it("fires for transitively-extending types", function()
            local calls = 0
            type_wiring.register("MyType", {
                onLoad = function() calls = calls + 1 end,
            })
            local extends = {Child = "Mid", Mid = "MyType"}
            type_wiring.applyWiring("Child", extends, {file = {}, badVal = {}})
            assert.equals(1, calls)
        end)

        it("fires shallow-to-deep when multiple ancestors are registered", function()
            local order = {}
            type_wiring.register("Parent", {
                onLoad = function() order[#order + 1] = "Parent" end,
            })
            type_wiring.register("Child", {
                onLoad = function() order[#order + 1] = "Child" end,
            })
            local extends = {Child = "Parent"}
            type_wiring.applyWiring("Child", extends, {file = {}, badVal = {}})
            assert.same({"Child", "Parent"}, order)
        end)

        it("fires each ancestor at most once per invocation", function()
            local calls = 0
            type_wiring.register("MyType", {
                onLoad = function() calls = calls + 1 end,
            })
            type_wiring.applyWiring("MyType", {}, {file = {}, badVal = {}})
            assert.equals(1, calls)
        end)

        it("is a no-op when fileType is nil", function()
            assert.has_no_error(function()
                type_wiring.applyWiring(nil, {}, {file = {}, badVal = {}})
            end)
        end)

        it("is a no-op when no ancestor is registered", function()
            assert.has_no_error(function()
                type_wiring.applyWiring("Unknown", {Unknown = "Stranger"},
                    {file = {}, badVal = {}})
            end)
        end)

        it("is safe against cycles in extends", function()
            local extends = {A = "B", B = "A"}
            assert.has_no_error(function()
                type_wiring.applyWiring("A", extends, {file = {}, badVal = {}})
            end)
        end)

        it("errors with a clear message when extends is missing", function()
            assert.has_error(function()
                type_wiring.applyWiring("MyType", nil, {file = {}, badVal = {}})
            end)
        end)

        it("errors when ctx is missing", function()
            assert.has_error(function()
                type_wiring.applyWiring("MyType", {})
            end)
        end)

        it("accumulates preProcessors with default prepend position", function()
            type_wiring.register("MyType", {
                preProcessors = {{expr = "completeMyType(rows)", priority = 50}},
            })
            local pre = {"userProc"}
            type_wiring.applyWiring("MyType", {}, {preProcessors = pre})
            assert.equals(2, #pre)
            assert.equals("completeMyType(rows)", pre[1].expr)
            assert.equals("userProc", pre[2])
        end)

        it("accumulates fileValidators with default append position", function()
            type_wiring.register("MyType", {
                fileValidators = {{expr = "checkShape(rows)"}},
            })
            local fv = {"userValidator"}
            type_wiring.applyWiring("MyType", {}, {fileValidators = fv})
            assert.equals("userValidator", fv[1])
            assert.equals("checkShape(rows)", fv[2].expr)
        end)

        it("honours per-entry position override", function()
            type_wiring.register("MyType", {
                preProcessors = {{expr = "lateProc(rows)", position = "append"}},
            })
            local pre = {"userProc"}
            type_wiring.applyWiring("MyType", {}, {preProcessors = pre})
            assert.equals("userProc", pre[1])
            assert.equals("lateProc(rows)", pre[2].expr)
        end)

        it("does not insert a duplicate-expression wired entry", function()
            type_wiring.register("MyType", {
                fileValidators = {{expr = "checkX(rows)"}},
            })
            local fv = {}
            type_wiring.applyWiring("MyType", {}, {fileValidators = fv})
            type_wiring.applyWiring("MyType", {}, {fileValidators = fv})
            type_wiring.applyWiring("MyType", {}, {fileValidators = fv})
            assert.equals(1, #fv)
        end)
    end)

    describe("restoreState", function()
        it("drops test-registered entries but keeps the built-ins", function()
            type_wiring.register("MyTestType", {onLoad = function() end})
            assert.is_true(type_wiring.hasOnLoad("MyTestType", {}))
            type_wiring.restoreState()
            assert.is_false(type_wiring.hasOnLoad("MyTestType", {}))
            -- Built-ins survive.
            assert.is_true(type_wiring.hasOnLoad("Type", {}))
            assert.is_true(type_wiring.hasOnLoad("enum", {}))
            assert.is_true(type_wiring.hasOnLoad("custom_type_def", {}))
        end)
    end)

    describe("built-in registrations", function()
        it("exposes Type / enum / custom_type_def after builtin_wiring loads", function()
            local registered = type_wiring._getRegisteredTypes()
            local seen = {}
            for _, t in ipairs(registered) do seen[t:lower()] = true end
            assert.is_true(seen["type"])
            assert.is_true(seen["enum"])
            assert.is_true(seen["custom_type_def"])
        end)
    end)

    describe("getVersion", function()
        it("returns a non-empty string", function()
            local v = type_wiring.getVersion()
            assert.is_string(v)
            assert.is_true(#v > 0)
        end)
    end)
end)
