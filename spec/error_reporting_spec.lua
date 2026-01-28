-- error_reporting_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local error_reporting = require("error_reporting")

describe("error_reporting", function()
  describe("badValGen", function()
    it("should generate a bad value logger", function()
      local log_messages = {}
      local log = function(self, msg) table.insert(log_messages, msg) end
      local badVal = error_reporting.badValGen(log)
      badVal.source_name = "test"
      badVal.line_no = 1
      badVal("bad value")
      assert.are.equal(1, #log_messages)
      assert.are.equal("test on line 1: 'bad value'", log_messages[1])
    end)
  end)

  describe("nullLogger", function()
    it("should silently ignore all log calls", function()
      -- Should not error or produce output
      error_reporting.nullLogger:debug("test debug")
      error_reporting.nullLogger:info("test info")
      error_reporting.nullLogger:warn("test warn")
      error_reporting.nullLogger:error("test error")
      -- If we get here without errors, it worked
      assert.is_true(true)
    end)
  end)

  describe("withColType", function()
    it("should push and pop col_type around function execution", function()
      local badVal = error_reporting.badValGen(function() end)

      assert.equals(0, #badVal.col_types)

      error_reporting.withColType(badVal, "string", function()
        assert.equals(1, #badVal.col_types)
        assert.equals("string", badVal.col_types[1])
      end)

      assert.equals(0, #badVal.col_types)
    end)

    it("should return values from the wrapped function", function()
      local badVal = error_reporting.badValGen(function() end)

      local a, b, c = error_reporting.withColType(badVal, "number", function()
        return 1, 2, 3
      end)

      assert.equals(1, a)
      assert.equals(2, b)
      assert.equals(3, c)
    end)

    it("should return nil correctly", function()
      local badVal = error_reporting.badValGen(function() end)

      local result = error_reporting.withColType(badVal, "number", function()
        return nil
      end)

      assert.is_nil(result)
    end)

    it("should pop col_type even when function errors", function()
      local badVal = error_reporting.badValGen(function() end)

      assert.equals(0, #badVal.col_types)

      pcall(function()
        error_reporting.withColType(badVal, "string", function()
          error("test error")
        end)
      end)

      -- col_type should be popped despite the error
      assert.equals(0, #badVal.col_types)
    end)

    it("should re-raise errors from the wrapped function", function()
      local badVal = error_reporting.badValGen(function() end)

      local success, err = pcall(function()
        error_reporting.withColType(badVal, "string", function()
          error("custom error message")
        end)
      end)

      assert.is_false(success)
      assert.is_truthy(err and err:find("custom error message"))
    end)

    it("should support nested withColType calls", function()
      local badVal = error_reporting.badValGen(function() end)

      error_reporting.withColType(badVal, "outer", function()
        assert.equals(1, #badVal.col_types)
        assert.equals("outer", badVal.col_types[1])

        error_reporting.withColType(badVal, "inner", function()
          assert.equals(2, #badVal.col_types)
          assert.equals("outer", badVal.col_types[1])
          assert.equals("inner", badVal.col_types[2])
        end)

        assert.equals(1, #badVal.col_types)
        assert.equals("outer", badVal.col_types[1])
      end)

      assert.equals(0, #badVal.col_types)
    end)

    it("should use col_type in error messages", function()
      local log_messages = {}
      local badVal = error_reporting.badValGen(function(_, msg)
        table.insert(log_messages, msg)
      end)
      badVal.source_name = "test"
      badVal.line_no = 1

      error_reporting.withColType(badVal, "integer", function()
        badVal("not_an_int", "expected integer")
      end)

      assert.equals(1, #log_messages)
      assert.is_truthy(log_messages[1]:find("Bad integer"))
    end)

    it("should handle table col_types", function()
      local log_messages = {}
      local badVal = error_reporting.badValGen(function(_, msg)
        table.insert(log_messages, msg)
      end)
      badVal.source_name = "test"
      badVal.line_no = 1

      error_reporting.withColType(badVal, {"string", "number"}, function()
        badVal("bad_value")
      end)

      assert.equals(1, #log_messages)
      -- Table type should be serialized in the message
      assert.is_truthy(log_messages[1]:find("Bad"))
    end)

    it("should error when badVal is nil", function()
      assert.has_error(function()
        error_reporting.withColType(nil, "string", function() end)
      end)
    end)

    it("should error when fn is not a function", function()
      local badVal = error_reporting.badValGen(function() end)

      assert.has_error(function()
        error_reporting.withColType(badVal, "string", "not a function")
      end)
    end)

    describe("opt_logger parameter", function()
      it("should use opt_logger for logging when provided", function()
        local opt_log_messages = {}

        -- Create a custom logger that captures messages
        local named_logger = require("named_logger")
        local opt_logger = named_logger.new(function(_self, level, message)
          table.insert(opt_log_messages, {level = level, message = message})
          return true
        end)

        -- badVal without a custom log function uses badVal.logger
        local badVal = error_reporting.badValGen()
        badVal.source_name = "test"
        badVal.line_no = 1

        error_reporting.withColType(badVal, "integer", function()
          badVal("bad_value")
        end, opt_logger)

        -- The opt_logger should have received the error
        assert.equals(1, #opt_log_messages)
        assert.equals("ERROR", opt_log_messages[1].level)
        assert.is_truthy(opt_log_messages[1].message:find("Bad integer"))
      end)

      it("should restore old logger after function completes", function()
        local named_logger = require("named_logger")
        local opt_logger = named_logger.new(function() return true end)

        local badVal = error_reporting.badValGen()
        local original_logger = badVal.logger

        error_reporting.withColType(badVal, "string", function()
          -- Inside, logger should be opt_logger
          assert.equals(opt_logger, badVal.logger)
        end, opt_logger)

        -- After, logger should be restored
        assert.equals(original_logger, badVal.logger)
      end)

      it("should restore old logger even when function errors", function()
        local named_logger = require("named_logger")
        local opt_logger = named_logger.new(function() return true end)

        local badVal = error_reporting.badValGen()
        local original_logger = badVal.logger

        pcall(function()
          error_reporting.withColType(badVal, "string", function()
            assert.equals(opt_logger, badVal.logger)
            error("test error")
          end, opt_logger)
        end)

        -- Logger should be restored despite the error
        assert.equals(original_logger, badVal.logger)
      end)

      it("should not change logger when opt_logger is nil", function()
        local badVal = error_reporting.badValGen()
        local original_logger = badVal.logger

        error_reporting.withColType(badVal, "string", function()
          -- Logger should remain unchanged
          assert.equals(original_logger, badVal.logger)
        end, nil)

        assert.equals(original_logger, badVal.logger)
      end)

      it("should work with nested calls using different loggers", function()
        local outer_messages = {}
        local inner_messages = {}

        local named_logger = require("named_logger")
        local outer_logger = named_logger.new(function(_self, _level, message)
          table.insert(outer_messages, message)
          return true
        end)
        local inner_logger = named_logger.new(function(_self, _level, message)
          table.insert(inner_messages, message)
          return true
        end)

        local badVal = error_reporting.badValGen()
        badVal.source_name = "test"
        badVal.line_no = 1

        error_reporting.withColType(badVal, "outer_type", function()
          badVal("outer_error")

          error_reporting.withColType(badVal, "inner_type", function()
            badVal("inner_error")
          end, inner_logger)

          -- After inner returns, should use outer_logger again
          badVal("outer_error_2")
        end, outer_logger)

        -- Outer logger should have 2 messages
        assert.equals(2, #outer_messages)
        assert.is_truthy(outer_messages[1]:find("Bad outer_type"))
        assert.is_truthy(outer_messages[2]:find("Bad outer_type"))

        -- Inner logger should have 1 message
        assert.equals(1, #inner_messages)
        -- Note: inner type is "inner_type" but col_types[1] is still "outer_type"
        -- because outer was pushed first
        assert.is_truthy(inner_messages[1]:find("Bad outer_type"))
      end)
    end)
  end)

  describe("badVal field combinations", function()
    it("should format message with col_name only", function()
      local log_messages = {}
      local badVal = error_reporting.badValGen(function(_, msg)
        table.insert(log_messages, msg)
      end)
      badVal.source_name = "test.tsv"
      badVal.line_no = 10
      badVal.col_name = "age"
      badVal.col_idx = 0  -- No index

      badVal("invalid")

      assert.equals(1, #log_messages)
      assert.is_truthy(log_messages[1]:find("age in test.tsv on line 10"))
    end)

    it("should format message with col_name and col_idx", function()
      local log_messages = {}
      local badVal = error_reporting.badValGen(function(_, msg)
        table.insert(log_messages, msg)
      end)
      badVal.source_name = "test.tsv"
      badVal.line_no = 10
      badVal.col_name = "age"
      badVal.col_idx = 3

      badVal("invalid")

      assert.equals(1, #log_messages)
      assert.is_truthy(log_messages[1]:find("age, col 3 in test.tsv on line 10"))
    end)

    it("should format message with col_idx only (no col_name)", function()
      local log_messages = {}
      local badVal = error_reporting.badValGen(function(_, msg)
        table.insert(log_messages, msg)
      end)
      badVal.source_name = "test.tsv"
      badVal.line_no = 10
      badVal.col_name = ""
      badVal.col_idx = 5

      badVal("invalid")

      assert.equals(1, #log_messages)
      assert.is_truthy(log_messages[1]:find("5 in test.tsv on line 10"))
    end)

    it("should include row_key in message when provided", function()
      local log_messages = {}
      local badVal = error_reporting.badValGen(function(_, msg)
        table.insert(log_messages, msg)
      end)
      badVal.source_name = "test.tsv"
      badVal.line_no = 10
      badVal.row_key = "user_123"

      badVal("invalid")

      assert.equals(1, #log_messages)
      assert.is_truthy(log_messages[1]:find("%(user_123%)"))
    end)

    it("should swap line_no and col_idx when transposed is true", function()
      local log_messages = {}
      local badVal = error_reporting.badValGen(function(_, msg)
        table.insert(log_messages, msg)
      end)
      badVal.source_name = "test.tsv"
      badVal.line_no = 5      -- becomes col in transposed
      badVal.col_idx = 10     -- becomes line in transposed
      badVal.col_name = "field"
      badVal.transposed = true

      badVal("invalid")

      assert.equals(1, #log_messages)
      -- In transposed mode: line becomes col_idx (5), col becomes line_no (10)
      assert.is_truthy(log_messages[1]:find("field, col 5 in test.tsv on line 10"))
    end)

    it("should handle all fields together", function()
      local log_messages = {}
      local badVal = error_reporting.badValGen(function(_, msg)
        table.insert(log_messages, msg)
      end)
      badVal.source_name = "data.tsv"
      badVal.line_no = 42
      badVal.col_name = "score"
      badVal.col_idx = 7
      badVal.row_key = "record_abc"
      badVal.col_types = {"integer"}

      badVal("not_a_number", "expected integer")

      assert.equals(1, #log_messages)
      local msg = log_messages[1]
      assert.is_truthy(msg:find("Bad integer"))
      assert.is_truthy(msg:find("score, col 7"))
      assert.is_truthy(msg:find("data.tsv on line 42"))
      assert.is_truthy(msg:find("%(record_abc%)"))
      assert.is_truthy(msg:find("'not_a_number'"))
      assert.is_truthy(msg:find("%(expected integer%)"))
    end)
  end)

  describe("error counter", function()
    it("should increment errors counter when badVal is called", function()
      local badVal = error_reporting.badValGen(function() end)
      badVal.source_name = "test"
      badVal.line_no = 1

      assert.equals(0, badVal.errors)
      badVal("bad1")
      assert.equals(1, badVal.errors)
      badVal("bad2")
      assert.equals(2, badVal.errors)
      badVal("bad3")
      assert.equals(3, badVal.errors)
    end)

    it("should still count errors for nullBadVal (needed for validation)", function()
      -- nullBadVal starts with some error count (may be non-zero from other tests)
      local initial_errors = error_reporting.nullBadVal.errors

      error_reporting.nullBadVal("bad value")
      error_reporting.nullBadVal("another bad value")

      -- errors should be incremented even though no logging occurs
      -- (validation logic depends on error counting to detect failures)
      assert.equals(initial_errors + 2, error_reporting.nullBadVal.errors)
    end)
  end)

  describe("table values and errors", function()
    it("should serialize table values in messages", function()
      local log_messages = {}
      local badVal = error_reporting.badValGen(function(_, msg)
        table.insert(log_messages, msg)
      end)
      badVal.source_name = "test"
      badVal.line_no = 1

      badVal({key = "value", num = 42})

      assert.equals(1, #log_messages)
      -- Should contain serialized table representation
      assert.is_truthy(log_messages[1]:find("key"))
      assert.is_truthy(log_messages[1]:find("value"))
    end)

    it("should serialize table error messages", function()
      local log_messages = {}
      local badVal = error_reporting.badValGen(function(_, msg)
        table.insert(log_messages, msg)
      end)
      badVal.source_name = "test"
      badVal.line_no = 1

      badVal("bad", {"error1", "error2"})

      assert.equals(1, #log_messages)
      -- Should contain serialized error table
      assert.is_truthy(log_messages[1]:find("error1"))
      assert.is_truthy(log_messages[1]:find("error2"))
    end)

    it("should serialize table col_type in messages", function()
      local log_messages = {}
      local badVal = error_reporting.badValGen(function(_, msg)
        table.insert(log_messages, msg)
      end)
      badVal.source_name = "test"
      badVal.line_no = 1
      -- col_types[1] is a table, not a string - it should be serialized
      badVal.col_types = {{"string", "number"}}

      badVal("bad")

      assert.equals(1, #log_messages)
      -- Should serialize the table {"string", "number"} into the "Bad X" prefix
      assert.is_truthy(log_messages[1]:find("Bad"))
      assert.is_truthy(log_messages[1]:find("string"))
      assert.is_truthy(log_messages[1]:find("number"))
    end)
  end)

  describe("debug field", function()
    it("should prefix message with debug value when set", function()
      local log_messages = {}
      local badVal = error_reporting.badValGen(function(_, msg)
        table.insert(log_messages, msg)
      end)
      badVal.source_name = "test"
      badVal.line_no = 1
      badVal.debug = "[DEBUG] "

      badVal("bad value")

      assert.equals(1, #log_messages)
      assert.is_truthy(log_messages[1]:find("^%[DEBUG%] "))
    end)

    it("should not prefix message when debug is nil", function()
      local log_messages = {}
      local badVal = error_reporting.badValGen(function(_, msg)
        table.insert(log_messages, msg)
      end)
      badVal.source_name = "test"
      badVal.line_no = 1
      badVal.debug = nil

      badVal("bad value")

      assert.equals(1, #log_messages)
      assert.is_truthy(log_messages[1]:find("^test on line"))
    end)

    it("should convert non-string debug to string", function()
      local log_messages = {}
      local badVal = error_reporting.badValGen(function(_, msg)
        table.insert(log_messages, msg)
      end)
      badVal.source_name = "test"
      badVal.line_no = 1
      badVal.debug = 123

      badVal("bad value")

      assert.equals(1, #log_messages)
      assert.is_truthy(log_messages[1]:find("^123"))
    end)
  end)

  describe("dumpStack", function()
    local old_print
    local captured

    before_each(function()
      captured = {}
      old_print = print
      _G.print = function(msg) table.insert(captured, msg) end
    end)

    after_each(function()
      _G.print = old_print
    end)

    it("should print stack trace information", function()
      local function testFunc()
        error_reporting.dumpStack()
      end

      testFunc()

      -- Should have printed multiple lines
      assert.is_true(#captured > 0)

      -- Should contain function name or file info
      local output = table.concat(captured, "\n")
      assert.is_true(#output > 0)
    end)
  end)

  describe("module API", function()
    describe("getVersion", function()
      it("should return a version string", function()
        local version = error_reporting.getVersion()
        assert.is_string(version)
        assert.matches("^%d+%.%d+%.%d+$", version)
      end)
    end)

    describe("callable API", function()
      it("should return version when called with 'version'", function()
        local version = error_reporting("version")
        assert.is_not_nil(version)
        -- Version is a semver object
        assert.are.equal(error_reporting.getVersion(), tostring(version))
      end)

      it("should call API functions when called with function name", function()
        local result = error_reporting("badValGen", function() end)
        assert.is_not_nil(result)
        assert.are.equal(0, result.errors)
      end)

      it("should error on unknown operation", function()
        assert.has_error(function()
          error_reporting("nonexistent_operation")
        end, "Unknown operation: nonexistent_operation")
      end)
    end)

    describe("__tostring", function()
      it("should return module name and version", function()
        local str = tostring(error_reporting)
        assert.is_string(str)
        assert.matches("^error_reporting version %d+%.%d+%.%d+$", str)
      end)
    end)
  end)
end)
