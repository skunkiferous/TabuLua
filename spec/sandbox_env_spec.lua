-- sandbox_env_spec.lua

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it

local sandbox_env = require("infra.sandbox_env")

-- Globals that must NEVER be reachable from a sandbox environment table.
local DANGEROUS = {
    "require", "module", "load", "loadstring", "loadfile", "dofile",
    "collectgarbage", "rawget", "rawset", "rawequal", "rawlen",
    "setmetatable", "getmetatable", "debug", "io", "os", "_G", "print",
}

-- The exact key set sandbox_env.new() must expose (besides any extras).
local NEW_KEYS = {
    -- safe builtins
    assert = true, error = true, ipairs = true, next = true, pairs = true,
    pcall = true, select = true, tonumber = true, tostring = true,
    type = true, unpack = true, xpcall = true,
    -- libraries
    math = true, string = true, table = true,
    -- TabuLua helper block
    predicates = true, stringUtils = true, tableUtils = true, equals = true,
}

describe("sandbox_env", function()

    describe("new()", function()
        it("returns a fresh table on every call", function()
            local a = sandbox_env.new()
            local b = sandbox_env.new()
            assert.are_not.equal(a, b)
            a.injected = "x"
            assert.is_nil(b.injected)
        end)

        it("does not mutate the extras table passed in", function()
            local extras = {foo = 1}
            local env = sandbox_env.new(extras)
            env.bar = 2
            assert.is_nil(extras.bar)
            assert.are.equal(1, env.foo)
        end)

        it("exposes the safe builtins", function()
            local env = sandbox_env.new()
            for _, name in ipairs({"assert", "error", "ipairs", "next", "pairs",
                "pcall", "select", "tonumber", "tostring", "type", "unpack",
                "xpcall"}) do
                assert.is_function(env[name], name .. " should be present")
            end
        end)

        it("exposes math and the curated string/table subsets", function()
            local env = sandbox_env.new()
            assert.are.equal(math, env.math)
            assert.is_function(env.string.upper)
            assert.is_function(env.string.format)
            assert.is_function(env.table.insert)
            assert.is_function(env.table.sort)
            -- table.concat is included (the stock sandbox BASE_ENV omits it)
            assert.is_function(env.table.concat)
        end)

        it("omits string.dump and string.rep from the string subset", function()
            local env = sandbox_env.new()
            assert.is_nil(env.string.dump)
            assert.is_nil(env.string.rep)
        end)

        it("exposes the TabuLua helper block", function()
            local env = sandbox_env.new()
            assert.is_not_nil(env.predicates)
            assert.is_function(env.stringUtils.trim)
            assert.is_function(env.tableUtils.keys)
            assert.is_function(env.tableUtils.longestMatchingPrefix)
            assert.is_function(env.equals)
        end)

        it("does not expose any dangerous global", function()
            local env = sandbox_env.new()
            for _, name in ipairs(DANGEROUS) do
                assert.is_nil(env[name], name .. " must be absent")
            end
        end)

        it("exposes exactly the expected key set", function()
            local env = sandbox_env.new()
            for k in pairs(env) do
                assert.is_true(NEW_KEYS[k] == true,
                    "unexpected key in new(): " .. tostring(k))
            end
            for k in pairs(NEW_KEYS) do
                assert.is_not_nil(env[k], "missing key in new(): " .. k)
            end
        end)

        it("merges extras on top and lets them override shared keys", function()
            local env = sandbox_env.new({type = "shadowed", custom = 42})
            assert.are.equal("shadowed", env.type)
            assert.are.equal(42, env.custom)
        end)
    end)

    describe("cogGlobals()", function()
        it("returns a fresh table on every call", function()
            local a = sandbox_env.cogGlobals()
            local b = sandbox_env.cogGlobals()
            assert.are_not.equal(a, b)
        end)

        it("exposes safe builtins, math and the curated string/table subsets", function()
            local env = sandbox_env.cogGlobals()
            assert.is_function(env.pairs)
            assert.is_function(env.pcall)
            assert.are.equal(math, env.math)
            assert.is_function(env.table.concat)
            assert.is_function(env.string.upper)
        end)

        it("exposes the TabuLua helper block (unified with code libraries, v0.22.0)", function()
            local env = sandbox_env.cogGlobals()
            assert.is_table(env.predicates)
            assert.is_table(env.stringUtils)
            assert.is_table(env.tableUtils)
            assert.is_function(env.equals)
        end)

        it("provides the same safe surface as new()", function()
            local cog = sandbox_env.cogGlobals()
            local lib = sandbox_env.new()
            for k in pairs(lib) do
                assert.is_not_nil(cog[k], "cogGlobals missing key present in new(): " .. tostring(k))
            end
            for k in pairs(cog) do
                assert.is_not_nil(lib[k], "cogGlobals has key absent from new(): " .. tostring(k))
            end
        end)

        it("does not expose any dangerous global", function()
            local env = sandbox_env.cogGlobals()
            for _, name in ipairs(DANGEROUS) do
                assert.is_nil(env[name], name .. " must be absent")
            end
        end)
    end)

    describe("module API", function()
        it("has a version", function()
            local v = sandbox_env.getVersion()
            assert.is_not_nil(v)
            assert.is.truthy(v:match("%d+%.%d+%.%d+"))
        end)

        it("has a tostring representation", function()
            assert.is.truthy(tostring(sandbox_env):match("sandbox_env"))
        end)

        it("supports the callable version interface", function()
            assert.is_not_nil(sandbox_env("version"))
        end)
    end)
end)
