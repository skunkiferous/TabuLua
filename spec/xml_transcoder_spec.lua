-- xml_transcoder_spec.lua
-- Unit tests for the XML <-> wide-TSV content-pipeline transcoder
-- (TODO/xml_input_round_trip.md): id-selected, schema-free, namespaced.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each

local parsers = require("parsers")
local error_reporting = require("error_reporting")
local xml_transcoder = require("xml_transcoder")

local NS = "urn:tabulua:table:1"

-- Wraps a body (header + rows markup) in the namespaced <file> document.
local function doc(body)
    return '<?xml version="1.0" encoding="UTF-8"?>\n<file xmlns="' .. NS .. '">\n'
        .. body .. '\n</file>'
end

describe("xml_transcoder", function()
    local badVal, msgs

    before_each(function()
        msgs = {}
        badVal = error_reporting.badValGen(function(_self, m) msgs[#msgs + 1] = m end)
        badVal.logger = error_reporting.nullLogger
        -- A distinctive named record type, for the composite round-trip that uses
        -- a registered type (not just an inline structural one).
        parsers.registerAlias(badVal, "XmlStats", "{attack:integer,defense:integer}")
    end)

    local function joined() return table.concat(msgs, " | ") end

    describe("xmlToTSV (forward)", function()
        it("rebuilds a schema-free, typed wide TSV from <header>/<row>", function()
            local xml = doc(
                '<header><string>name:identifier</string><string>displayName:text</string>'
                .. '<string>dropWeight:float</string></header>\n'
                .. '<row><string>Common</string><string>Common</string><number>0.5</number></row>\n'
                .. '<row><string>Rare</string><string>Rare</string><number>0.15</number></row>')
            -- No ctx.typeName supplied: types come from the file's own <header>.
            local out = xml_transcoder.xmlToTSV("R.xml", xml, {}, badVal, {})
            assert.equal(
                "name:identifier\tdisplayName:text\tdropWeight:float\n"
                .. "Common\tCommon\t0.5\nRare\tRare\t0.15\n", out)
            assert.equal(0, badVal.errors, joined())
        end)

        it("decodes the typed primitives (integer/number/string/true/false/null)", function()
            local xml = doc(
                '<header><string>a:integer</string><string>b:float</string>'
                .. '<string>c:string</string><string>d:boolean</string>'
                .. '<string>e:boolean</string><string>f:string|nil</string></header>\n'
                .. '<row><integer>42</integer><number>-1.5</number><string>hi</string>'
                .. '<true/><false/><null/></row>')
            local out = xml_transcoder.xmlToTSV("P.xml", xml, {}, badVal, {})
            assert.equal(
                "a:integer\tb:float\tc:string\td:boolean\te:boolean\tf:string|nil\n"
                .. "42\t-1.5\thi\ttrue\tfalse\t\n", out)
            assert.equal(0, badVal.errors, joined())
        end)

        it("decodes composite <table> cells to the native in-cell form (inline type)", function()
            local xml = doc(
                '<header><string>name:identifier</string>'
                .. '<string>stats:{attack:integer,defense:integer}</string>'
                .. '<string>pos:{float,float,float}</string>'
                .. '<string>loot:{name}</string></header>\n'
                .. '<row><string>boss</string>'
                .. '<table><key_value><string>attack</string><integer>80</integer></key_value>'
                .. '<key_value><string>defense</string><integer>40</integer></key_value></table>'
                .. '<table><number>-20.0</number><number>50.0</number><number>10.0</number></table>'
                .. '<table><string>shadowCloak</string><string>manaPotion</string></table></row>')
            local out = xml_transcoder.xmlToTSV("B.xml", xml, {}, badVal, {})
            -- The native cell form matches what a source .tsv uses for these columns.
            assert.equal(
                "name:identifier\tstats:{attack:integer,defense:integer}\t"
                .. "pos:{float,float,float}\tloot:{name}\n"
                .. 'boss\tattack=80,defense=40\t-20.0,50.0,10.0\t"shadowCloak","manaPotion"\n',
                out)
            assert.equal(0, badVal.errors, joined())
        end)

        it("decodes a composite cell typed by a registered named record type", function()
            local xml = doc(
                '<header><string>name:identifier</string><string>stats:XmlStats</string></header>\n'
                .. '<row><string>boss</string>'
                .. '<table><key_value><string>attack</string><integer>7</integer></key_value>'
                .. '<key_value><string>defense</string><integer>3</integer></key_value></table></row>')
            local out = xml_transcoder.xmlToTSV("N.xml", xml, {}, badVal, {})
            assert.equal(
                "name:identifier\tstats:XmlStats\nboss\tattack=7,defense=3\n", out)
            assert.equal(0, badVal.errors, joined())
        end)

        it("rejects a root that is not in the TabuLua namespace (bare <file>)", function()
            local bare = '<?xml version="1.0"?>\n<file>\n'
                .. '<header><string>a:integer</string></header>\n'
                .. '<row><integer>1</integer></row>\n</file>'
            local out = xml_transcoder.xmlToTSV("foreign.xml", bare, {}, badVal, {})
            assert.is_nil(out)
            assert.matches("not in the TabuLua namespace", joined())
        end)

        it("rejects a root in a foreign namespace", function()
            local foreign = '<?xml version="1.0"?>\n<file xmlns="urn:someone:else">\n'
                .. '<header><string>a:integer</string></header>\n</file>'
            local out = xml_transcoder.xmlToTSV("foreign.xml", foreign, {}, badVal, {})
            assert.is_nil(out)
            assert.matches("not in the TabuLua namespace", joined())
        end)

        it("reports a missing <file> root", function()
            local out = xml_transcoder.xmlToTSV("x.xml", "<data/>", {}, badVal, {})
            assert.is_nil(out)
            assert.matches("missing <file>", joined())
        end)

        it("reports a malformed cell", function()
            local xml = doc('<header><string>a:integer</string></header>\n'
                .. '<row><integer>1</row>')   -- unclosed <integer>
            local out = xml_transcoder.xmlToTSV("x.xml", xml, {}, badVal, {})
            assert.is_nil(out)
            assert.matches("xml transcoder", joined())
        end)
    end)

    describe("tsvToXml (reverse)", function()
        it("regenerates the namespaced document from a wide TSV", function()
            local tsv = "name:identifier\tn:integer\nsword\t100\nshield\t50\n"
            local out, reason = xml_transcoder.tsvToXml(tsv, {}, nil)
            assert.is_nil(reason)
            assert.equal(doc(
                '<header><string>name:identifier</string><string>n:integer</string></header>\n'
                .. '<row><string>sword</string><integer>100</integer></row>\n'
                .. '<row><string>shield</string><integer>50</integer></row>'), out)
        end)

        it("re-emits composite cells as <table> (symmetric with export)", function()
            local tsv = "name:identifier\tstats:XmlStats\nboss\tattack=7,defense=3\n"
            local out = xml_transcoder.tsvToXml(tsv, {}, nil)
            assert.matches(
                '<table><key_value><string>attack</string><integer>7</integer></key_value>'
                .. '<key_value><string>defense</string><integer>3</integer></key_value></table>',
                out, 1, true)
        end)
    end)

    describe("round-trip", function()
        it("XML -> wide TSV -> XML is byte-identical for a canonical document", function()
            local xml = doc(
                '<header><string>name:identifier</string><string>stats:XmlStats</string>'
                .. '<string>w:float</string></header>\n'
                .. '<row><string>boss</string>'
                .. '<table><key_value><string>attack</string><integer>7</integer></key_value>'
                .. '<key_value><string>defense</string><integer>3</integer></key_value></table>'
                .. '<number>0.5</number></row>')
            local tsv = xml_transcoder.xmlToTSV("B.xml", xml, {}, badVal, {})
            assert.is_not_nil(tsv)
            local xml2 = xml_transcoder.tsvToXml(tsv, {}, nil)
            assert.equal(xml, xml2)
            -- And the TSV is stable across a second pass.
            local tsv2 = xml_transcoder.xmlToTSV("B.xml", xml2, {}, badVal, {})
            assert.equal(tsv, tsv2)
            assert.equal(0, badVal.errors, joined())
        end)
    end)
end)
