-- lua_transcoder_spec.lua
-- Unit tests for the Lua-file <-> wide-TSV content-pipeline transcoder
-- (TODO/export_format_reimport.md, Phase 2): id-selected (lua:tabulua),
-- schema-free, reversible, reading back TabuLua's `--file=lua` export.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each

local error_reporting = require("error_reporting")
local lua_transcoder = require("lua_transcoder")

describe("lua_transcoder", function()
    local badVal, msgs

    before_each(function()
        msgs = {}
        badVal = error_reporting.badValGen(function(_self, m) msgs[#msgs + 1] = m end)
        badVal.logger = error_reporting.nullLogger
    end)

    local function joined() return table.concat(msgs, " | ") end

    local NATIVE_SIMPLE = "name:identifier\tn:integer\tnote:string|nil\n"
        .. "sword\t100\thi\nshield\t50\t\n"
    local NATIVE_COMPOSITE = "name:identifier\tstats:{attack:integer,defense:integer}\n"
        .. "boss\tattack=80,defense=40\n"

    describe("luaToTSV (forward)", function()
        it("loads the return-table and rebuilds the typed wide TSV (schema-free)", function()
            local lua = 'return {\n'
                .. '{"name:identifier","n:integer","note:string|nil"},\n'
                .. '{"sword",100,"hi"},\n'
                .. '{"shield",50,nil}\n}'
            local out = lua_transcoder.luaToTSV("R.lua", lua, {}, badVal)
            assert.equal(NATIVE_SIMPLE, out)
            assert.equal(0, badVal.errors, joined())
        end)

        it("decodes a composite table cell to the native in-cell form", function()
            local lua = 'return {\n'
                .. '{"name:identifier","stats:{attack:integer,defense:integer}"},\n'
                .. '{"boss",{attack=80,defense=40}}\n}'
            local out = lua_transcoder.luaToTSV("B.lua", lua, {}, badVal)
            assert.equal(NATIVE_COMPOSITE, out)
            assert.equal(0, badVal.errors, joined())
        end)

        it("aborts via badVal when the file does not return a table", function()
            local out = lua_transcoder.luaToTSV("X.lua", "return 42", {}, badVal)
            assert.is_nil(out)
            assert.matches("must `return` a table", joined())
        end)

        it("aborts via badVal on a syntax error", function()
            local out = lua_transcoder.luaToTSV("X.lua", "return {{", {}, badVal)
            assert.is_nil(out)
            assert.matches("lua transcoder", joined())
        end)

        it("aborts (does not hang) on a file that loops instead of returning", function()
            -- The instruction quota trips well before this could hang the load.
            local out = lua_transcoder.luaToTSV("evil.lua", "while true do end", {}, badVal)
            assert.is_nil(out)
            assert.matches("lua transcoder", joined())
        end)

        it("rejects a non-string header cell", function()
            local out = lua_transcoder.luaToTSV("X.lua", "return {{1,2}}", {}, badVal)
            assert.is_nil(out)
            assert.matches("header cell", joined())
        end)
    end)

    describe("tsvToLua (reverse)", function()
        it("regenerates the return-table document", function()
            local out, reason = lua_transcoder.tsvToLua(NATIVE_SIMPLE, {}, nil)
            assert.is_nil(reason)
            assert.equal('return {\n'
                .. '{"name:identifier","n:integer","note:string|nil"},\n'
                .. '{"sword",100,"hi"},\n'
                .. '{"shield",50,nil}\n}', out)
        end)

        it("re-emits a composite cell as a Lua table literal", function()
            local out = lua_transcoder.tsvToLua(NATIVE_COMPOSITE, {}, nil)
            assert.matches("{attack=80,defense=40}", out, 1, true)
        end)
    end)

    describe("round-trip", function()
        it("native -> encode -> forward reproduces the native wide TSV", function()
            local encoded = lua_transcoder.tsvToLua(NATIVE_COMPOSITE, {}, nil)
            assert.is_not_nil(encoded)
            local back = lua_transcoder.luaToTSV("rt.lua", encoded, {}, badVal)
            assert.equal(NATIVE_COMPOSITE, back)
            assert.equal(0, badVal.errors, joined())

            -- And forward -> encode -> forward is stable.
            local back2 = lua_transcoder.luaToTSV("rt.lua",
                lua_transcoder.tsvToLua(back, {}, nil), {}, badVal)
            assert.equal(NATIVE_COMPOSITE, back2)
        end)
    end)
end)
