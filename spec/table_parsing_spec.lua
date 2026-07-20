-- table_depth_parsing_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local table_parsing = require("util.table_parsing")
local error_reporting = require("infra.error_reporting")

describe("table_parsing", function()
  describe("parseTableStr", function()
    it("should be able to parse a table as a string", function()
      local log_messages = {}
      local log = function(self, msg) table.insert(log_messages, msg) end
      local badVal = error_reporting.badValGen(log)
      badVal.source_name = "test"
      badVal.line_no = 1
      local t = table_parsing.parseTableStr(badVal,'?',"{}")
      assert.are.same({}, t)
      t = table_parsing.parseTableStr(badVal,'?',"{42}")
      assert.are.same({42}, t)
      t = table_parsing.parseTableStr(badVal,'?',"{'a',{42}}")
      assert.are.same({'a',{42}}, t)
      t = table_parsing.parseTableStr(badVal,'?',"{a=42}")
      assert.are.same({a=42}, t)

      assert.are.same({}, log_messages)
      --assert.are.equal("test on line 1: 'bad value'", log_messages[1])
    end)

    it("should convert an {__int64=...} wrapper into a box", function()
      local log_messages = {}
      local log = function(self, msg) table.insert(log_messages, msg) end
      local badVal = error_reporting.badValGen(log)
      badVal.source_name = "test"
      badVal.line_no = 1
      local int64 = require("util.int64")

      -- ltcn lexes a bare number before any int64 code runs, so the wrapper is
      -- the only way an int64 survives inside a table cell.
      local t = table_parsing.parseTableStr(badVal, 'raw',
          [[{{__int64="9007199254740993"},k={__int64="-9223372036854775808"}}]])
      assert.is_true(int64.is(t[1]))
      assert.is_true(int64.is(t.k))
      assert.are.equal("9007199254740993", int64.tostring(t[1]))
      assert.are.equal("-9223372036854775808", int64.tostring(t.k))

      -- Narrow on purpose, exactly like the typed-JSON tag: a lone __int64 key
      -- with a canonical int64 string, and nothing else. Everything else is
      -- left as the plain table the author wrote.
      local notATag = table_parsing.parseTableStr(badVal, 'raw',
          [[{{__int64="nope"},{__int64="5",other=1},{__int64=5}}]])
      assert.are.same({{__int64 = "nope"}, {__int64 = "5", other = 1},
                       {__int64 = 5}}, notATag)
      assert.are.same({}, log_messages)
    end)

    it("should reject a bare literal a double cannot hold exactly", function()
      local log_messages = {}
      local log = function(self, msg) table.insert(log_messages, msg) end
      local badVal = error_reporting.badValGen(log)
      badVal.source_name = "test"
      badVal.line_no = 1

      -- On LuaJIT this rounded SILENTLY (9007199254740993 -> ...992); on Lua
      -- 5.3+ it was exact. Same file, two meanings. Now both reject it, and
      -- the check is textual so the two runtimes cannot diverge.
      assert.is_nil(table_parsing.parseTableStr(badVal, 'raw',
          "{9007199254740993}"))
      assert.matches("cannot be represented exactly", log_messages[1])
      assert.is_nil(table_parsing.parseTableStr(badVal, 'raw',
          "{9007199254740992}"))    -- 2^53 itself: indistinguishable from a
                                    -- rounded 2^53+1, so also refused

      -- Everything a double DOES hold exactly is untouched...
      log_messages = {}
      assert.are.same({9007199254740991, -1, 42},
          table_parsing.parseTableStr(badVal, 'raw',
              "{9007199254740991,-1,42}"))
      -- ...as are floats, hex, digits inside strings, and the two forms the
      -- error message actually recommends
      assert.are.same({1.5e20, 0x7FFFFFFF, "id 9007199254740993"},
          table_parsing.parseTableStr(badVal, 'raw',
              [[{1.5e20,0x7FFFFFFF,"id 9007199254740993"}]]))
      assert.are.same({"9007199254740993"},
          table_parsing.parseTableStr(badVal, 'raw', [[{"9007199254740993"}]]))
      assert.are.same({}, log_messages)
    end)

    it("should report error for invalid syntax", function()
      local log_messages = {}
      local log = function(self, msg) table.insert(log_messages, msg) end
      local badVal = error_reporting.badValGen(log)
      badVal.source_name = "test"
      badVal.line_no = 1

      -- Missing closing brace
      table_parsing.parseTableStr(badVal, 'table', "{1, 2, 3")
      assert.is_true(#log_messages > 0)

      -- Reset log
      log_messages = {}

      -- Completely invalid input
      table_parsing.parseTableStr(badVal, 'table', "not a table at all")
      assert.is_true(#log_messages > 0)

      -- Reset log
      log_messages = {}

      -- Unbalanced braces
      table_parsing.parseTableStr(badVal, 'table', "{{{}}")
      assert.is_true(#log_messages > 0)
    end)

    it("should report error for tables exceeding MAX_TABLE_DEPTH", function()
      local log_messages = {}
      local log = function(self, msg) table.insert(log_messages, msg) end
      local badVal = error_reporting.badValGen(log)
      badVal.source_name = "test"
      badVal.line_no = 1

      -- Build a table string nested deeper than MAX_TABLE_DEPTH (10)
      -- This creates a table nested 11 levels deep
      local deep_table_str = string.rep("{", 11) .. string.rep("}", 11)

      table_parsing.parseTableStr(badVal, 'table', deep_table_str)
      assert.is_true(#log_messages > 0)
      assert.is_true(string.find(log_messages[1], "maximum depth") ~= nil)

      -- Reset log
      log_messages = {}

      -- Exactly at MAX_TABLE_DEPTH should be OK
      local max_depth_str = string.rep("{", 10) .. string.rep("}", 10)
      local result = table_parsing.parseTableStr(badVal, 'table', max_depth_str)
      assert.are.same({}, log_messages)
      assert.is_not_nil(result)
    end)

    it("should report error for empty string input", function()
      local log_messages = {}
      local log = function(self, msg) table.insert(log_messages, msg) end
      local badVal = error_reporting.badValGen(log)
      badVal.source_name = "test"
      badVal.line_no = 1

      -- Empty string
      table_parsing.parseTableStr(badVal, 'table', "")
      assert.is_true(#log_messages > 0)

      -- Reset log
      log_messages = {}

      -- Whitespace only
      table_parsing.parseTableStr(badVal, 'table', "   ")
      assert.is_true(#log_messages > 0)
    end)

    it("should handle non-table values parsed from string", function()
      local log_messages = {}
      local log = function(self, msg) table.insert(log_messages, msg) end
      local badVal = error_reporting.badValGen(log)
      badVal.source_name = "test"
      badVal.line_no = 1

      -- These parse successfully but aren't tables
      table_parsing.parseTableStr(badVal, 'table', "42")
      assert.is_true(#log_messages > 0)
      assert.is_true(string.find(log_messages[1], "not a table") ~= nil)

      -- Reset log
      log_messages = {}

      table_parsing.parseTableStr(badVal, 'table', "'a string'")
      assert.is_true(#log_messages > 0)
      assert.is_true(string.find(log_messages[1], "not a table") ~= nil)

      -- Reset log
      log_messages = {}

      table_parsing.parseTableStr(badVal, 'table', "true")
      assert.is_true(#log_messages > 0)
      assert.is_true(string.find(log_messages[1], "not a table") ~= nil)
    end)

    -- Note: Recursive tables cannot be created from string input since string
    -- literals cannot express self-references. The recursion check in parseTableStr
    -- is a defensive measure. The getMaxTableDepth tests below cover recursion
    -- detection for programmatically created tables.
  end)

  describe("getMaxTableDepth", function()
    it("should handle non-table values", function()
        assert.equals(0, table_parsing.getMaxTableDepth(nil))
        assert.equals(0, table_parsing.getMaxTableDepth(42))
        assert.equals(0, table_parsing.getMaxTableDepth("string"))
        assert.equals(0, table_parsing.getMaxTableDepth(true))
        assert.equals(0, table_parsing.getMaxTableDepth(function() end))
    end)

    it("should handle empty and simple tables", function()
        assert.equals(1, table_parsing.getMaxTableDepth({}))
        assert.equals(1, table_parsing.getMaxTableDepth({1, 2, 3}))
        assert.equals(1, table_parsing.getMaxTableDepth({a = 1, b = 2}))
    end)

    it("should handle nested tables", function()
        assert.equals(2, table_parsing.getMaxTableDepth({a = {}}))
        assert.equals(2, table_parsing.getMaxTableDepth({{}}))
        assert.equals(3, table_parsing.getMaxTableDepth({a = {b = {}}}))
        assert.equals(3, table_parsing.getMaxTableDepth({{{}}}, nil))
    end)

    it("should handle tables with mixed nesting", function()
        local t = {
            a = {},          -- depth 1
            b = {c = {}},    -- depth 2
            d = {           -- depth 3 through e->f
                e = {
                    f = {}
                }
            },
            g = {h = 1}     -- depth 2
        }
        assert.equals(4, table_parsing.getMaxTableDepth(t))
    end)

    it("should detect direct recursion", function()
        local t = {}
        t.a = t
        local depth, err = table_parsing.getMaxTableDepth(t)
        assert.is_nil(depth)
        assert.equals("recursive table detected", err)
    end)

    it("should detect indirect recursion", function()
        local t1 = {}
        local t2 = {t1}
        t1.a = t2
        local depth, err = table_parsing.getMaxTableDepth(t1)
        assert.is_nil(depth)
        assert.equals("recursive table detected", err)

        -- Test with longer cycle
        local t3 = {}
        local t4 = {t3}
        local t5 = {t4}
        t3.a = t5
        depth, err = table_parsing.getMaxTableDepth(t3)
        assert.is_nil(depth)
        assert.equals("recursive table detected", err)
    end)

    it("should handle shared references without recursion", function()
        local shared = {}
        local t = {
            a = shared,
            b = shared
        }
        assert.equals(2, table_parsing.getMaxTableDepth(t))

        -- More complex case with deeper sharing
        local deep_shared = {inner = {}}
        local t2 = {
            x = deep_shared,
            y = {z = deep_shared}
        }
        assert.equals(4, table_parsing.getMaxTableDepth(t2))
    end)
  end)

  describe("module API", function()
    describe("getVersion", function()
      it("should return a version string", function()
        local version = table_parsing.getVersion()
        assert.is_string(version)
        assert.matches("^%d+%.%d+%.%d+$", version)
      end)
    end)

    describe("callable API", function()
      it("should return version when called with 'version'", function()
        local version = table_parsing("version")
        assert.is_not_nil(version)
        -- Version is a semver object
        assert.are.equal(table_parsing.getVersion(), tostring(version))
      end)

      it("should call API functions when called with function name", function()
        local result = table_parsing("getMaxTableDepth", {a = {b = 1}})
        assert.are.equal(2, result)
      end)

      it("should error on unknown operation", function()
        assert.has_error(function()
          table_parsing("nonexistent_operation")
        end, "Unknown operation: nonexistent_operation")
      end)
    end)

    describe("__tostring", function()
      it("should return module name and version", function()
        local str = tostring(table_parsing)
        assert.is_string(str)
        assert.matches("^table_parsing version %d+%.%d+%.%d+$", str)
      end)
    end)
  end)

end)
