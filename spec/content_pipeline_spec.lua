-- content_pipeline_spec.lua

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local content_pipeline = require("content_pipeline")
-- Requiring the seed module registers the built-in stages (normalise-eol, COG,
-- gzip) and snapshots the registry, so restoreState() returns to exactly those.
require("builtin_content_stages")
local file_util = require("file_util")
local raw_tsv = require("raw_tsv")
local stringToRawTSV = raw_tsv.stringToRawTSV
local rawTSVToString = raw_tsv.rawTSVToString
local LibDeflate = require("libdeflate")
local compression = require("compression")
local parsers = require("parsers")

-- A record type used by the JSON transcoder tests; schema drives the typed header.
parsers.registerAlias(require("error_reporting").nullBadVal,
  "CpTestItem", "{name:identifier,price:integer,tag:string|nil}")

-- A real gzip stream (produced by the system `gzip -cn`) of the exact bytes
-- "id\tvalue\nitem1\t42\nitem2\t100\n" — used to prove we interoperate with
-- genuine gzip output, not just our own round-trip.
local REAL_GZIP =
  "\031\139\008\000\000\000\000\000\000\003\203\076\225\044\075\204\041\077" ..
  "\229\202\044\073\205\053\228\052\049\002\051\140\056\013\013\012\184\000" ..
  "\089\077\045\070\028\000\000\000"
local REAL_GZIP_PLAIN = "id\tvalue\nitem1\t42\nitem2\t100\n"

-- Builds a gzip envelope around arbitrary data using libdeflate for the deflate
-- body. The CRC32 is left zero (our gunzip does not verify it). opt_isize
-- overrides the trailing ISIZE field, which lets a test forge a "bomb" whose
-- declared size is huge while the actual payload stays tiny.
local function le32(n)
  return string.char(n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff)
end
local function makeGzip(data, opt_isize)
  local header = string.char(0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03)
  local body = LibDeflate:CompressDeflate(data)
  return header .. body .. le32(0) .. le32(opt_isize or #data)
end

local function path_join(...)
  return (table.concat({...}, "/"):gsub("//+", "/"))
end

-- A minimal callable badVal that records reported messages.
local function newBadVal()
  local bv = {messages = {}}
  return setmetatable(bv, {__call = function(self, _val, msg)
    self.messages[#self.messages + 1] = msg
  end})
end

describe("content_pipeline", function()
  local temp_dir

  before_each(function()
    local system_temp = file_util.getSystemTempDir()
    assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
    local td = path_join(system_temp, "content_pipeline_test_" .. os.time() .. "_" .. math.random(1000000))
    assert(lfs.mkdir(td))
    temp_dir = td
  end)

  after_each(function()
    -- Drop any stages a test registered, restoring the two built-ins.
    content_pipeline.restoreState()
    if temp_dir then
      local td = temp_dir
      temp_dir = nil
      file_util.deleteTempDir(td)
    end
  end)

  describe("getVersion", function()
    it("returns a version string", function()
      assert.is_truthy(content_pipeline.getVersion():match("%d+%.%d+%.%d+"))
    end)
  end)

  describe("content-kind classification", function()
    it("classifies known text extensions as text", function()
      assert.is_true(content_pipeline.isTextFile("data.tsv"))
      assert.is_true(content_pipeline.isTextFile("doc.md"))
      assert.is_true(content_pipeline.isTextFile("lib.lua"))
    end)

    it("defaults everything else to binary", function()
      assert.is_false(content_pipeline.isTextFile("image.png"))
      assert.is_false(content_pipeline.isTextFile("noextension"))
      assert.equals("binary", content_pipeline.classifyKind("a.bin"))
      assert.equals("text", content_pipeline.classifyKind("a.TSV")) -- case-insensitive
    end)
  end)

  describe("register validation", function()
    it("rejects an unknown or missing phase", function()
      assert.has_error(function()
        content_pipeline.register("t", {phase = "nope", matches = function() return true end,
          transform = function() end})
      end)
      assert.has_error(function()
        content_pipeline.register("t", {matches = function() return true end,
          transform = function() end})
      end)
    end)

    it("rejects a stage with no matcher", function()
      assert.has_error(function()
        content_pipeline.register("t", {phase = "macro", transform = function() end})
      end)
    end)

    it("rejects a stage with neither transform nor sinkTransform", function()
      assert.has_error(function()
        content_pipeline.register("t", {phase = "macro", matches = function() return true end})
      end)
    end)
  end)

  describe("runSink (sink/export direction)", function()
    -- Regression: a source-only stage (transform, no sinkTransform) — e.g. a
    -- decode stage — must NOT be selected in the sink direction. The old
    -- `useSink and sinkTransform or transform` idiom fell through to transform
    -- when sinkTransform was nil, so runSink then tried to call a nil
    -- sinkTransform and crashed (hit by `.tsv.gz` data file + stripCog export).
    it("skips a source-only stage instead of calling its nil sinkTransform", function()
      local called = false
      content_pipeline.register("decode-only", {
        phase = "decode", extensions = {"zz"},
        transform = function(_, c) called = true; return c end,
      })
      local bv = newBadVal()
      local out = content_pipeline.runSink("file.zz", "RAW", {}, bv)
      assert.equals("RAW", out)        -- unchanged, no crash
      assert.is_false(called)          -- the source-only transform was not invoked
      assert.equals(0, #bv.messages)
    end)

    it("invokes a matching stage's sinkTransform", function()
      content_pipeline.register("sink-stage", {
        phase = "macro", extensions = {"txt"},
        sinkTransform = function(_, c) return c .. "+SINK" end,
      })
      local bv = newBadVal()
      assert.equals("X+SINK", content_pipeline.runSink("a.txt", "X", {}, bv))
    end)
  end)

  describe("run (normalize + macro)", function()
    it("normalises EOL and expands COG on a text file", function()
      local bv = newBadVal()
      local bytes = "Header\r\n---[[[\r\n---return 'GEN'\r\n---]]]\r\nold\r\n---[[[end]]]\r\nFooter"
      local out, name = content_pipeline.run("data.tsv", bytes, {}, bv)
      assert.equals("data.tsv", name)
      assert.is_nil(out:find("\r"))      -- normalised
      assert.is_truthy(out:find("GEN"))  -- COG ran
      assert.is_nil(out:find("\nold"))   -- COG replaced the old output
      assert.equals(0, #bv.messages)
    end)

    it("leaves binary content untouched (text-only stages skipped)", function()
      local bv = newBadVal()
      -- A COG-looking payload under a binary extension must NOT be expanded or
      -- EOL-normalised — it is bytes.
      local bytes = "x\r\n---[[[end]]]\r\n"
      local out = content_pipeline.run("blob.png", bytes, {}, bv)
      assert.equals(bytes, out)          -- byte-for-byte unchanged
      assert.equals(0, #bv.messages)
    end)
  end)

  describe("dispatch ordering", function()
    it("runs macro stages in ascending priority, stable by registration", function()
      content_pipeline.register("test", {phase = "macro", extensions = {"txt"},
        inputKind = "text", priority = 20,
        transform = function(_n, c) return c .. "[B]" end})
      content_pipeline.register("test", {phase = "macro", extensions = {"txt"},
        inputKind = "text", priority = 10,
        transform = function(_n, c) return c .. "[A]" end})
      local out = content_pipeline.run("note.txt", "base", {}, newBadVal())
      -- priority 10 (A) before 20 (B); the built-in COG stage (priority 100, no
      -- markers) runs last and is a no-op.
      assert.equals("base[A][B]", out)
    end)
  end)

  -- Generic peeling mechanics with a fake decoder on a private extension ("z9"),
  -- so these stay independent of the real gzip stage (which owns ".gz").
  describe("decode peeling", function()
    it("peels one extension per matching decode stage and renames", function()
      content_pipeline.register("test-z9", {phase = "decode", extensions = {"z9"},
        outputKind = "text",
        transform = function(name, content)
          return content .. "<decoded>", (name:gsub("%.z9$", ""))
        end})
      local out, name = content_pipeline.run("data.tsv.z9", "COMPRESSED", {}, newBadVal())
      assert.equals("data.tsv", name)
      assert.is_truthy(out:find("<decoded>"))
    end)

    it("loops for chained decoders (.z9.z9) and terminates", function()
      content_pipeline.register("test-z9", {phase = "decode", extensions = {"z9"},
        outputKind = "text",
        transform = function(name, content)
          return content .. "<d>", (name:gsub("%.z9$", ""))
        end})
      local out, name = content_pipeline.run("a.tsv.z9.z9", "C", {}, newBadVal())
      assert.equals("a.tsv", name)
      local _, count = out:gsub("<d>", "")
      assert.equals(2, count)
    end)
  end)

  describe("transcode", function()
    it("reports an ambiguity when two transcode stages match", function()
      content_pipeline.register("t1", {phase = "transcode", extensions = {"json"},
        transform = function(_n, c) return c end})
      content_pipeline.register("t2", {phase = "transcode", extensions = {"json"},
        transform = function(_n, c) return c end})
      local bv = newBadVal()
      content_pipeline.run("data.json", "{}", {}, bv)
      assert.is_true(#bv.messages > 0)
      assert.matches("ambiguous", bv.messages[1])
    end)
  end)

  describe("readAndRun", function()
    it("populates raw_files with the normalised, pre-COG source and returns the expansion", function()
      local path = path_join(temp_dir, "data.tsv")
      local on_disk = "Header\r\n---[[[\r\n---return 'GEN'\r\n---]]]\r\nold\r\n---[[[end]]]\r\nFooter"
      -- Write the exact bytes (binary) so the CRLFs are not doubled by text-mode.
      do
        local f = assert(io.open(path, "wb"))
        f:write(on_disk)
        f:close()
      end

      local raw_files = {}
      local bv = newBadVal()
      local content = content_pipeline.readAndRun(path, {}, bv, raw_files)
      assert.equals(0, #bv.messages)
      -- Returned content is COG-expanded: the "old" placeholder is replaced by
      -- the generated "GEN".
      assert.is_truthy(content:find("GEN"))
      assert.is_nil(content:find("old"))
      -- raw_files holds the pre-COG source: markers present, placeholder NOT yet
      -- replaced, and EOL normalised (no CR).
      local stored = raw_files[path]
      assert.is_string(stored)
      assert.is_nil(stored:find("\r"))
      assert.is_truthy(stored:find("%-%-%-%[%[%["))
      assert.is_truthy(stored:find("old"))
    end)

    it("reports a fatal read error via badVal and returns nil", function()
      local bv = newBadVal()
      local content = content_pipeline.readAndRun(
        path_join(temp_dir, "does_not_exist.tsv"), {}, bv, {})
      assert.is_nil(content)
      assert.is_true(#bv.messages > 0)
    end)
  end)

  -- Ablation: the new (binary-read + explicit normalise) pipeline must produce a
  -- rawtsv byte-for-byte identical to the pre-refactor pipeline (text-mode read
  -- → stringToRawTSV) across every EOL shape. This is the §6 Phase 1 ablation.
  describe("EOL ablation (vs pre-refactor pipeline)", function()
    local body = "id\tvalue\nitem1\t42\nitem2\t100"
    local variants = {
      lf            = body .. "\n",
      crlf          = (body:gsub("\n", "\r\n")) .. "\r\n",
      mixed         = "id\tvalue\r\nitem1\t42\nitem2\t100\r\n",
      no_trailing   = body,            -- no final newline
      cr_old_mac    = (body:gsub("\n", "\r")),
    }

    for label, on_disk in pairs(variants) do
      it("matches the old pipeline for the '" .. label .. "' variant", function()
        local path = path_join(temp_dir, label .. ".tsv")
        -- Write the exact bytes (binary) so the EOL shape is preserved on disk.
        do
          local f = assert(io.open(path, "wb"))
          f:write(on_disk)
          f:close()
        end

        -- Pre-refactor pipeline: text-mode read, then stringToRawTSV (no COG here).
        local old_content = assert(file_util.readFile(path))
        local old_rawtsv = stringToRawTSV(old_content)

        -- New pipeline.
        local bv = newBadVal()
        local new_content = content_pipeline.readAndRun(path, {}, bv, {})
        assert.equals(0, #bv.messages)
        local new_rawtsv = stringToRawTSV(new_content)

        assert.equals(rawTSVToString(old_rawtsv), rawTSVToString(new_rawtsv))
      end)
    end
  end)

  describe("gzip decode (Phase 2)", function()
    it("decodes a real gzip stream and peels the .gz extension", function()
      -- run() exposes the effective name, so we can assert the peel directly.
      local out, name = content_pipeline.run("data.tsv.gz", REAL_GZIP, {}, newBadVal())
      assert.equals("data.tsv", name)
      assert.equals(REAL_GZIP_PLAIN, out)
    end)

    it("loads data.tsv.gz identically to data.tsv (end to end)", function()
      local gz_path = path_join(temp_dir, "data.tsv.gz")
      do
        local f = assert(io.open(gz_path, "wb"))
        f:write(REAL_GZIP)
        f:close()
      end
      local raw_files = {}
      local bv = newBadVal()
      local content = content_pipeline.readAndRun(gz_path, {}, bv, raw_files)
      assert.equals(0, #bv.messages)
      -- Same parsed rawtsv as the uncompressed bytes.
      assert.equals(rawTSVToString(stringToRawTSV(REAL_GZIP_PLAIN)),
                    rawTSVToString(stringToRawTSV(content)))
      -- raw_files is keyed by the on-disk name (not the peeled name) and holds
      -- the decoded source.
      assert.is_string(raw_files[gz_path])
      assert.is_nil(raw_files[gz_path .. ".peeled"])
    end)

    it("decodes chained .gz.gz, looping until no decoder matches", function()
      local outer = makeGzip(makeGzip("hello tsv content\n"))
      local out, name = content_pipeline.run("a.tsv.gz.gz", outer, {}, newBadVal())
      assert.equals("a.tsv", name)
      assert.equals("hello tsv content\n", out)
    end)

    it("matches by magic bytes when the .gz extension is absent (renamed .dat)", function()
      local out, name = content_pipeline.run("blob.dat", REAL_GZIP, {}, newBadVal())
      -- No extension to peel: the name is unchanged but the bytes are decoded.
      assert.equals("blob.dat", name)
      assert.equals(REAL_GZIP_PLAIN, out)
    end)

    it("trips badVal and drops the file on a decompression bomb (ISIZE over cap)", function()
      -- A tiny payload whose forged ISIZE claims 200 MB — over the 64 MB cap.
      -- The cheap ISIZE pre-check rejects it without inflating anything.
      local bomb = makeGzip("tiny", 200 * 1024 * 1024)
      local bv = newBadVal()
      local out = content_pipeline.run("bomb.tsv.gz", bomb, {}, bv)
      assert.is_nil(out)
      assert.is_true(#bv.messages > 0)
      assert.matches("exceeds", bv.messages[1])
    end)

    it("aborts the file on a corrupt gzip stream", function()
      local bv = newBadVal()
      -- Valid gzip magic + header length but garbage DEFLATE body.
      local corrupt = string.char(0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03)
        .. ("\255"):rep(20)
      local out = content_pipeline.run("corrupt.tsv.gz", corrupt, {}, bv)
      assert.is_nil(out)
      assert.is_true(#bv.messages > 0)
    end)

    it("enforces a stage's maxOutputBytes generically in the dispatcher", function()
      -- A decode stage whose transform returns more than its declared cap must
      -- be aborted by the dispatcher even though the transform itself is happy.
      content_pipeline.register("test-cap", {
        phase = "decode", extensions = {"big"}, maxOutputBytes = 10,
        transform = function(_n, _c) return ("x"):rep(50), "out.tsv" end,
      })
      local bv = newBadVal()
      local out = content_pipeline.run("data.big", "anything", {}, bv)
      assert.is_nil(out)
      assert.is_true(#bv.messages > 0)
      assert.matches("maxOutputBytes", bv.messages[1])
    end)
  end)

  describe("JSON transcode (Phase 3, explicit selection)", function()
    local CTX = {transcoder = "json:objects", typeName = "CpTestItem"}

    it("transcodes object-per-row JSON to a schema-typed TSV", function()
      local json = '[{"name":"sword","price":100,"tag":"sharp"},{"name":"shield","price":50}]'
      local bv = newBadVal()
      local out = content_pipeline.run("items.json", json, {}, bv, CTX)
      assert.equals(0, #bv.messages)
      -- Header is typed, in schema (sorted) field order; missing tag -> empty cell.
      -- rawTSVToString terminates every row (incl. the last) with \n.
      local expected = table.concat({
        "name:identifier\tprice:integer\ttag:string|nil",
        "sword\t100\tsharp",
        "shield\t50\t",
        "",
      }, "\n")
      assert.equals(expected, out)
    end)

    it("maps a JSON null to an empty cell", function()
      local json = '[{"name":"a","price":1,"tag":null}]'
      local out = content_pipeline.run("x.json", json, {}, newBadVal(), CTX)
      assert.equals("name:identifier\tprice:integer\ttag:string|nil\na\t1\t\n", out)
    end)

    it("is selected only explicitly: no auto-match on the .json extension", function()
      -- Same JSON, but no transcoder in ctx -> no transcode runs; the raw JSON
      -- text passes through (it is not a transcode source by extension).
      local json = '[{"name":"a","price":1}]'
      local out = content_pipeline.run("x.json", json, {}, newBadVal())
      assert.equals(json, out)
    end)

    it("aborts on an unknown transcoder id", function()
      local bv = newBadVal()
      local out = content_pipeline.run("x.json", "[]", {}, bv,
        {transcoder = "nope", typeName = "CpTestItem"})
      assert.is_nil(out)
      assert.matches("unknown transcoder", bv.messages[1])
    end)

    it("aborts when the typeName is not a known record type", function()
      local bv = newBadVal()
      local out = content_pipeline.run("x.json", "[]", {}, bv,
        {transcoder = "json:objects", typeName = "NoSuchType"})
      assert.is_nil(out)
      assert.matches("not a known record type", bv.messages[1])
    end)

    it("aborts on malformed JSON", function()
      local bv = newBadVal()
      local out = content_pipeline.run("x.json", "{not json", {}, bv, CTX)
      assert.is_nil(out)
      assert.matches("invalid JSON", bv.messages[1])
    end)

    it("aborts when an element is not an object", function()
      local bv = newBadVal()
      local out = content_pipeline.run("x.json", '[{"name":"a","price":1}, 42]', {}, bv, CTX)
      assert.is_nil(out)
      assert.matches("not an object", bv.messages[1])
    end)

    it("composes after a decode stage (.json.gz)", function()
      local inner = '[{"name":"a","price":7}]'
      local gz = makeGzip(inner)
      local out, name = content_pipeline.run("d.json.gz", gz, {}, newBadVal(), CTX)
      assert.equals("d.json", name)   -- .gz peeled; transcoder then ran on the JSON
      assert.equals("name:identifier\tprice:integer\ttag:string|nil\na\t7\t\n", out)
    end)

    -- The same data in all three layouts must yield identical TSV. Schema field
    -- order is sorted: name, price, tag.
    local EXPECTED = table.concat({
      "name:identifier\tprice:integer\ttag:string|nil",
      "sword\t100\tsharp",
      "shield\t50\t",
      "",
    }, "\n")

    it("json:rows transcodes array-per-row (positional, schema field order)", function()
      local json = '[["sword",100,"sharp"],["shield",50]]'   -- shield omits trailing tag
      local bv = newBadVal()
      local out = content_pipeline.run("x.json", json, {}, bv,
        {transcoder = "json:rows", typeName = "CpTestItem"})
      assert.equals(0, #bv.messages)
      assert.equals(EXPECTED, out)
    end)

    it("json:columns transcodes array-per-column, null-padding a short column", function()
      -- Transpose of the rows form; the tag column's null (shield) becomes empty,
      -- and the row count comes from the longer columns (dkjson drops the null).
      local json = '[["sword","shield"],[100,50],["sharp",null]]'
      local bv = newBadVal()
      local out = content_pipeline.run("x.json", json, {}, bv,
        {transcoder = "json:columns", typeName = "CpTestItem"})
      assert.equals(0, #bv.messages)
      assert.equals(EXPECTED, out)
    end)

    it("json:rows aborts a row with more values than schema fields", function()
      local bv = newBadVal()
      local out = content_pipeline.run("x.json", '[["a",1,2,3]]', {}, bv,
        {transcoder = "json:rows", typeName = "CpTestItem"})
      assert.is_nil(out)
      assert.matches("values but the schema has", bv.messages[1])
    end)

    it("json:columns aborts on the wrong number of columns", function()
      local bv = newBadVal()
      local out = content_pipeline.run("x.json", '[["a"],[1]]', {}, bv,
        {transcoder = "json:columns", typeName = "CpTestItem"})
      assert.is_nil(out)
      assert.matches("expected 3 column", bv.messages[1])
    end)

  end)

  -- Name-only decode-extension peeling, used by the loader (routing) and the
  -- reformatter (reversible round-trip). The gzip stage (reversible) is the one
  -- registered decode stage via builtin_content_stages.
  describe("peeledName / reversibleDecode", function()
    it("peeledName strips a .gz decode extension", function()
      assert.equals("data.tsv", content_pipeline.peeledName("data.tsv.gz"))
    end)

    it("peeledName strips chained decode extensions", function()
      assert.equals("data.tsv", content_pipeline.peeledName("data.tsv.gz.gz"))
    end)

    it("peeledName leaves a plain name unchanged", function()
      assert.equals("data.tsv", content_pipeline.peeledName("data.tsv"))
      assert.equals("items.json", content_pipeline.peeledName("items.json"))
    end)

    it("reversibleDecode reports the peeled name for a reversible source", function()
      local rd = content_pipeline.reversibleDecode("data.tsv.gz")
      assert.is_not_nil(rd)
      assert.equals("data.tsv", rd.peeledName)
    end)

    it("reversibleDecode returns nil for a name with no decode extension", function()
      assert.is_nil(content_pipeline.reversibleDecode("data.tsv"))
      assert.is_nil(content_pipeline.reversibleDecode("items.json"))
    end)

    it("reversibleDecode.encode re-gzips so the bytes gunzip back to the input", function()
      local rd = content_pipeline.reversibleDecode("data.tsv.gz")
      local tsv = "id:string\tvalue:integer\nitem1\t42\n"
      local bytes = rd.encode(tsv, nil, function() end)
      assert.is_string(bytes)
      assert.equals(0x1f, bytes:byte(1))            -- gzip magic
      assert.equals(0x8b, bytes:byte(2))
      assert.equals(tsv, compression.decompress("gzip", bytes))
    end)

    it("reversibleDecode.encode re-applies a chained .gz.gz inside-out", function()
      local rd = content_pipeline.reversibleDecode("data.tsv.gz.gz")
      local tsv = "id:string\tvalue:integer\nitem1\t42\n"
      local outer = rd.encode(tsv, nil, function() end)
      -- Two gzip layers: gunzip once -> a gzip stream, gunzip twice -> the TSV.
      local once = compression.decompress("gzip", outer)
      assert.equals(0x1f, once:byte(1))
      assert.equals(tsv, compression.decompress("gzip", once))
    end)
  end)
end)
