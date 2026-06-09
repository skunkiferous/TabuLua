-- tsv_transcoder_spec.lua
-- Unit tests for the TSV-with-alternate-cell-encoding content-pipeline transcoders
-- (TODO/export_format_reimport.md): tsv:lua / tsv:json-typed / tsv:json-natural.
-- They are id-selected and schema-free (column types come from the file's own
-- header), reading the three TSV export variants back to the native wide TSV.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each

local error_reporting = require("error_reporting")
local tsv_transcoders = require("tsv_transcoders")

describe("tsv_transcoders", function()
    local badVal, msgs

    before_each(function()
        msgs = {}
        badVal = error_reporting.badValGen(function(_self, m) msgs[#msgs + 1] = m end)
        badVal.logger = error_reporting.nullLogger
    end)

    local function joined() return table.concat(msgs, " | ") end

    -- The native wide TSV every variant decodes back to (shared expectation).
    local NATIVE_SIMPLE = "name:identifier\tn:integer\tnote:string|nil\n"
        .. "sword\t100\thi\nshield\t50\t\n"
    local NATIVE_COMPOSITE = "name:identifier\tstats:{attack:integer,defense:integer}\n"
        .. "boss\tattack=80,defense=40\n"

    describe("tsv:lua forward (luaToTSV)", function()
        it("decodes Lua-literal cells (and the quoted name:type header)", function()
            local lua = '"name:identifier"\t"n:integer"\t"note:string|nil"\n'
                .. '"sword"\t100\t"hi"\n"shield"\t50\t\n'
            local out = tsv_transcoders.luaToTSV("R.tsv", lua, {}, badVal)
            assert.equal(NATIVE_SIMPLE, out)
            assert.equal(0, badVal.errors, joined())
        end)

        it("decodes a composite Lua-literal cell to the native in-cell form", function()
            local lua = '"name:identifier"\t"stats:{attack:integer,defense:integer}"\n'
                .. '"boss"\t{attack=80,defense=40}\n'
            local out = tsv_transcoders.luaToTSV("B.tsv", lua, {}, badVal)
            assert.equal(NATIVE_COMPOSITE, out)
            assert.equal(0, badVal.errors, joined())
        end)

        it("aborts via badVal on a malformed Lua cell", function()
            local lua = '"a:integer"\n{this is not lua\n'
            local out = tsv_transcoders.luaToTSV("X.tsv", lua, {}, badVal)
            assert.is_nil(out)
            assert.matches("tsv transcoder", joined())
        end)
    end)

    describe("tsv:json-typed forward (jsonTypedToTSV)", function()
        it("decodes typed-JSON cells", function()
            local jt = '"a:integer"\t"b:string"\n{"int":"5"}\t"x"\n'
            local out = tsv_transcoders.jsonTypedToTSV("T.tsv", jt, {}, badVal)
            assert.equal("a:integer\tb:string\n5\tx\n", out)
            assert.equal(0, badVal.errors, joined())
        end)

        it("decodes a composite typed-JSON cell", function()
            local jt = '"name:identifier"\t"stats:{attack:integer,defense:integer}"\n'
                .. '"boss"\t[0,["attack",{"int":"80"}],["defense",{"int":"40"}]]\n'
            local out = tsv_transcoders.jsonTypedToTSV("B.tsv", jt, {}, badVal)
            assert.equal(NATIVE_COMPOSITE, out)
            assert.equal(0, badVal.errors, joined())
        end)
    end)

    describe("tsv:json-natural forward (jsonNaturalToTSV)", function()
        it("decodes natural-JSON cells", function()
            local jn = '"a:integer"\t"b:string"\n5\t"x"\n'
            local out = tsv_transcoders.jsonNaturalToTSV("N.tsv", jn, {}, badVal)
            assert.equal("a:integer\tb:string\n5\tx\n", out)
            assert.equal(0, badVal.errors, joined())
        end)

        it("decodes a composite natural-JSON cell", function()
            local jn = '"name:identifier"\t"stats:{attack:integer,defense:integer}"\n'
                .. '"boss"\t{"attack":80,"defense":40}\n'
            local out = tsv_transcoders.jsonNaturalToTSV("B.tsv", jn, {}, badVal)
            assert.equal(NATIVE_COMPOSITE, out)
            assert.equal(0, badVal.errors, joined())
        end)
    end)

    describe("reverse encoders", function()
        it("tsvToLua re-quotes the header and emits Lua-literal cells", function()
            local out, reason = tsv_transcoders.tsvToLua(NATIVE_SIMPLE, {}, nil)
            assert.is_nil(reason)
            assert.equal('"name:identifier"\t"n:integer"\t"note:string|nil"\n'
                .. '"sword"\t100\t"hi"\n"shield"\t50\t\n', out)
        end)

        it("tsvToJsonTyped emits typed-JSON cells", function()
            local out = tsv_transcoders.tsvToJsonTyped("a:integer\tb:string\n5\tx\n", {}, nil)
            assert.equal('"a:integer"\t"b:string"\n{"int":"5"}\t"x"\n', out)
        end)

        it("tsvToJsonNatural emits natural-JSON cells", function()
            local out = tsv_transcoders.tsvToJsonNatural("a:integer\tb:string\n5\tx\n", {}, nil)
            assert.equal('"a:integer"\t"b:string"\n5\t"x"\n', out)
        end)
    end)

    describe("round-trip (native -> encode -> forward -> native)", function()
        local cases = {
            {"tsv:lua", tsv_transcoders.tsvToLua, tsv_transcoders.luaToTSV},
            {"tsv:json-typed", tsv_transcoders.tsvToJsonTyped, tsv_transcoders.jsonTypedToTSV},
            {"tsv:json-natural", tsv_transcoders.tsvToJsonNatural, tsv_transcoders.jsonNaturalToTSV},
        }
        for _, c in ipairs(cases) do
            local id, encode, transform = c[1], c[2], c[3]
            it(id .. " round-trips a composite table value", function()
                local encoded = encode(NATIVE_COMPOSITE, {}, nil)
                assert.is_not_nil(encoded)
                local back = transform(id .. ".tsv", encoded, {}, badVal)
                assert.equal(NATIVE_COMPOSITE, back)
                assert.equal(0, badVal.errors, joined())
            end)
        end
    end)
end)
