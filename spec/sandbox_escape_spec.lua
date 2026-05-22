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

local tsv_model = require("tsv_model")
local lua_cog = require("lua_cog")
local sandbox_env = require("sandbox_env")
local error_reporting = require("error_reporting")

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
            local result, err = eval({}, "=require('read_only').unwrap(self)")
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
end)
