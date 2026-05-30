-- content_pipeline_spec.lua

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local content_pipeline = require("content_pipeline")
-- Requiring the seed module registers the built-in stages (normalise-eol + COG)
-- and snapshots the registry, so restoreState() returns to exactly those two.
require("builtin_content_stages")
local file_util = require("file_util")
local raw_tsv = require("raw_tsv")
local stringToRawTSV = raw_tsv.stringToRawTSV
local rawTSVToString = raw_tsv.rawTSVToString

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

  describe("decode peeling", function()
    it("peels one extension per matching decode stage and renames", function()
      content_pipeline.register("test-gz", {phase = "decode", extensions = {"gz"},
        outputKind = "text",
        transform = function(name, content)
          return content .. "<gunzipped>", (name:gsub("%.gz$", ""))
        end})
      local out, name = content_pipeline.run("data.tsv.gz", "COMPRESSED", {}, newBadVal())
      assert.equals("data.tsv", name)
      assert.is_truthy(out:find("<gunzipped>"))
    end)

    it("loops for chained decoders (.gz.gz) and terminates", function()
      content_pipeline.register("test-gz", {phase = "decode", extensions = {"gz"},
        outputKind = "text",
        transform = function(name, content)
          return content .. "<g>", (name:gsub("%.gz$", ""))
        end})
      local out, name = content_pipeline.run("a.tsv.gz.gz", "C", {}, newBadVal())
      assert.equals("a.tsv", name)
      local _, count = out:gsub("<g>", "")
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
end)
