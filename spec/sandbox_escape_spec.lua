-- sandbox_escape_spec.lua
--
-- Regression coverage for the cell-expression / COG sandbox escape: their
-- environments must NOT chain through to the real _G. Before the fix,
-- `loadEnv` used `{__index = _G}`, so any global the user named (require,
-- debug, io, os.*, raw{get,set}, {set,get}metatable, ...) fell through and
-- defeated both the sandbox and the read-only layer.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it

local tsv_model = require("tsv.tsv_model")
local lua_cog = require("content.lua_cog")
local sandbox_env = require("infra.sandbox_env")
local error_reporting = require("infra.error_reporting")
local deserialization = require("serde.deserialization")
local sandbox = require("sandbox")

-- Quota-escape tests need the sandbox instruction quota, which the sandbox
-- library cannot enforce on LuaJIT (no debug count hooks) — there the looping
-- code would genuinely run to completion, so they are pending rather than red.
local it_quota = sandbox.quota_supported and it or busted.pending

-- Iterations for the "escaped the quota" loops: far above every quota used
-- below, but still only a fraction of a second if an escape does happen.
local BIG = "5e6"

-- Compiles and runs `code` the way every TabuLua call site does.
local function runProtected(code, quota)
    local fn = sandbox.protect(code,
        sandbox_env.protectOptions(quota or 10000, sandbox_env.new()))
    return pcall(fn)
end

-- Builds a loadEnv exactly the way manifest_loader.processFiles does.
local function makeLoadEnv()
    return setmetatable({}, {__index = sandbox_env.cogGlobals()})
end

-- Names that previously leaked through `{__index = _G}` and must now be nil.
-- `os` is deliberately excluded: the stock sandbox keeps a safe os subset
-- (clock/difftime/time); the dangerous os members are checked separately.
local ESCAPE_NAMES = {
    "require", "debug", "io", "rawget", "rawset", "rawequal",
    "setmetatable", "getmetatable", "load", "loadstring", "dofile",
    "collectgarbage", "print",
}

describe("sandbox escape", function()

    describe("cell expressions", function()
        local eval = tsv_model.expressionEvaluatorGenerator(
            makeLoadEnv(), error_reporting.nullLogger)

        it("resolve dangerous globals to nil", function()
            for _, name in ipairs(ESCAPE_NAMES) do
                local result = eval({}, "=tostring(" .. name .. ")")
                assert.are.equal("nil", result,
                    name .. " must not be reachable from a cell expression")
            end
        end)

        it("cannot reach os.execute / os.remove / os.getenv", function()
            assert.are.equal("nil", eval({}, "=tostring(os.execute)"))
            assert.are.equal("nil", eval({}, "=tostring(os.remove)"))
            assert.are.equal("nil", eval({}, "=tostring(os.getenv)"))
        end)

        it("see _G as the sandbox env, not the real globals", function()
            -- _G inside the sandbox is the sandbox's own env; it must not
            -- expose the real globals through it.
            assert.are.equal("nil", eval({}, "=tostring(_G.require)"))
            assert.are.equal("nil", eval({}, "=tostring(_G.io)"))
        end)

        it("close the documented read-only unwrap bypass", function()
            local result, err = eval({}, "=require('util.read_only').unwrap(self)")
            assert.is_nil(result)
            assert.is_not_nil(err)
        end)

        it("still evaluate ordinary expressions", function()
            assert.are.equal(7, eval({value = 3}, "=self.value + 4"))
            assert.are.equal("AB", eval({}, "=string.upper('ab')"))
            assert.are.equal(3, eval({}, "=math.floor(3.9)"))
        end)
    end)

    describe("COG scripts", function()
        -- A single-line COG block: the generated output is line 4 of the
        -- result (markers at 1/3/5, generated content at 4).
        local function runCog(code)
            local content = "###[[[\n###" .. code .. "\n###]]]\nOLD\n###[[[end]]]\n"
            local errors = {}
            local lines = lua_cog.processContent(content, makeLoadEnv(), errors)
            return lines, errors
        end

        it("resolve dangerous globals to nil", function()
            for _, name in ipairs(ESCAPE_NAMES) do
                local lines = runCog("return tostring(" .. name .. ")")
                assert.is_not_nil(lines)
                assert.are.equal("nil", lines[4],
                    name .. " must not be reachable from a COG script")
            end
        end)

        it("can still use table.concat", function()
            local lines, errors = runCog('return table.concat({"x","y","z"}, "-")')
            assert.are.equal(0, #errors)
            assert.are.equal("x-y-z", lines[4])
        end)

        it("can still use math and string", function()
            local lines, errors = runCog(
                'return tostring(math.floor(3.9)) .. string.upper("q")')
            assert.are.equal(0, #errors)
            assert.are.equal("3Q", lines[4])
        end)
    end)

    describe("instruction quota", function()
        it_quota("stops a plain loop", function()
            local ok, err = runProtected("while true do end")
            assert.is_false(ok)
            assert.matches("Quota exceeded", err)
        end)

        -- The quota hook removes itself when it fires; a pcall that swallowed
        -- its error would leave the rest of the code unbounded.
        it_quota("cannot be swallowed by pcall", function()
            local ok, err = runProtected([[
                pcall(function() while true do end end)
                local i = 0
                while i < ]] .. BIG .. [[ do i = i + 1 end
                return i]])
            assert.is_false(ok)
            assert.matches("Quota exceeded", err)
        end)

        it_quota("cannot be swallowed by xpcall, nor run its handler", function()
            local ok, err = runProtected([[
                xpcall(function() while true do end end,
                    function() while true do end end)
                return "escaped"]])
            assert.is_false(ok)
            assert.matches("Quota exceeded", err)
        end)

        it_quota("does not give string.rep back after a swallowed quota", function()
            local ok = runProtected([[
                pcall(function() while true do end end)
                return type(("").rep)]])
            assert.is_false(ok)
        end)

        it("pcall and xpcall still catch ordinary errors", function()
            local ok, result = runProtected([[
                local a, e1 = pcall(error, "boom", 0)
                local b, e2 = xpcall(function() error("bang", 0) end,
                    function(e) return "handled " .. e end)
                return tostring(a) .. e1 .. tostring(b) .. e2]])
            assert.is_true(ok)
            assert.are.equal("falseboomfalsehandled bang", result)
        end)
    end)

    -- Debug hooks are per-thread: a coroutine body never counted against the
    -- quota, and resume caught the quota error too.
    describe("coroutines", function()
        it("are not available", function()
            local ok, err = runProtected(
                "return coroutine.wrap(function() return 1 end)()")
            assert.is_false(ok)
            assert.matches("coroutine.wrap is not available", err)
        end)

        it("are not available in a cell expression either", function()
            local eval = tsv_model.expressionEvaluatorGenerator(
                makeLoadEnv(), error_reporting.nullLogger)
            local result, err = eval({}, "=coroutine.create(print)")
            assert.is_nil(result)
            assert.is_not_nil(err)
        end)
    end)

    -- Data chunks (a `.lua` import, a Lua-literal cell) run under their own
    -- quota via sandbox_env.runData.
    describe("data chunks", function()
        it("are compiled text-only", function()
            local bytecode = string.dump(function() return 1 end)
            local ok, err, phase = sandbox_env.runData(bytecode, "t", {})
            assert.is_false(ok)
            assert.are.equal("compile", phase)
            -- PUC: "attempt to load a binary chunk (mode is 't')";
            -- LuaJIT: "attempt to load chunk with wrong mode"
            assert.matches("mode", err)
        end)

        it_quota("stop a looping literal", function()
            local result, err = deserialization.deserialize(
                "(function() while true do end end)()")
            assert.is_nil(result)
            assert.matches("Quota exceeded", err)
        end)

        it("cannot reach string methods", function()
            local result, err = deserialization.deserialize('("x"):rep(1e9)')
            assert.is_nil(result)
            assert.is_not_nil(err)
            -- ...and string methods work again afterwards
            assert.are.equal("XY", ("xy"):upper())
        end)

        it_quota("restore an enclosing hook", function()
            -- (and put back whatever ran before, e.g. luacov's line hook)
            local before = {debug.gethook()}
            local fired = false
            local function enclosing() fired = true end
            debug.sethook(enclosing, "", 1000000000)
            deserialization.deserialize("{1, 2, 3}")
            local hook = debug.gethook()
            debug.sethook(table.unpack(before))
            assert.are.equal(enclosing, hook)
            assert.is_false(fired)
        end)

        -- The count hook also counts runData's own instructions around the
        -- chunk. Sweeping a tiny quota lands it on each of them in turn: it
        -- must abort the chunk or stay silent, never raise out of runData
        -- (which would leave string methods off and the hook installed).
        it_quota("never leak the quota out of runData", function()
            local before = {debug.gethook()}
            for quota = 1, 60 do
                local label = "quota " .. quota
                local called, ok, result, phase = pcall(sandbox_env.runData,
                    "return 1", "t", {}, quota)
                assert.is_true(called, label .. ": " .. tostring(ok))
                if ok then
                    assert.are.equal(1, result, label)
                else
                    assert.are.equal("run", phase, label)
                    assert.is_truthy(tostring(result):find("Quota exceeded", 1, true), label)
                end
                assert.are.equal("XY", ("xy"):upper(), label)
                assert.are.same(before, {debug.gethook()}, label)
            end
        end)

        it("still deserialize ordinary literals", function()
            assert.are.same({1, "a", {b = true}},
                deserialization.deserialize('{1, "a", {b = true}}'))
            assert.are.equal(math.huge, deserialization.deserialize("math.huge"))
        end)
    end)
end)
