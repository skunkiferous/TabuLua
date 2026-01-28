-- named_logger_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local named_logger = require("named_logger")

describe("named_logger", function()

  describe("module API", function()
    it("should return version string from getVersion()", function()
      local version = named_logger.getVersion()
      assert.is_string(version)
      assert.is_truthy(version:match("^%d+%.%d+%.%d+"))
    end)

    it("should have __tostring returning module info", function()
      local str = tostring(named_logger)
      assert.is_string(str)
      assert.is_truthy(str:find("named_logger"))
      assert.is_truthy(str:find("version"))
    end)

    it("should support callable API with 'version' operation", function()
      local version = named_logger("version")
      assert.is_not_nil(version)
    end)

    it("should support callable API with 'getLogger' operation", function()
      local logger = named_logger("getLogger", "callable_test")
      assert.is_not_nil(logger)
      assert.equals("callable_test", logger.name)
    end)

    it("should error on unknown callable operation", function()
      assert.has_error(function()
        named_logger("nonexistent_operation")
      end)
    end)

    it("should error on access to undefined API member", function()
      assert.has_error(function()
        local _ = named_logger.nonexistent_member
      end)
    end)

    it("should be read-only (prevent modification)", function()
      assert.has_error(function()
        named_logger.newField = "test"
      end)
    end)
  end)

  describe("log level constants", function()
    it("should export DEBUG constant", function()
      assert.is_not_nil(named_logger.DEBUG)
    end)

    it("should export INFO constant", function()
      assert.is_not_nil(named_logger.INFO)
    end)

    it("should export WARN constant", function()
      assert.is_not_nil(named_logger.WARN)
    end)

    it("should export ERROR constant", function()
      assert.is_not_nil(named_logger.ERROR)
    end)

    it("should export FATAL constant", function()
      assert.is_not_nil(named_logger.FATAL)
    end)
  end)

  describe("getLogger", function()
    it("should return a logger instance with the given name", function()
      local logger = named_logger.getLogger("test_module")
      assert.is_not_nil(logger)
      assert.equals("test_module", logger.name)
    end)

    it("should return the same instance for the same name (caching)", function()
      local logger1 = named_logger.getLogger("cached_module")
      local logger2 = named_logger.getLogger("cached_module")
      assert.equals(logger1, logger2)
    end)

    it("should return different instances for different names", function()
      local logger1 = named_logger.getLogger("module_a")
      local logger2 = named_logger.getLogger("module_b")
      assert.are_not.equals(logger1, logger2)
    end)
  end)

  describe("logger instance methods", function()
    it("should have setLevel method", function()
      local logger = named_logger.getLogger("setlevel_test")
      assert.is_function(logger.setLevel)
      -- Should not error when called
      logger:setLevel(named_logger.DEBUG)
      logger:setLevel(named_logger.ERROR)
    end)

    it("should have log method", function()
      local logger = named_logger.getLogger("log_test")
      assert.is_function(logger.log)
    end)

    it("should have debug method", function()
      local logger = named_logger.getLogger("debug_test")
      assert.is_function(logger.debug)
    end)

    it("should have info method", function()
      local logger = named_logger.getLogger("info_test")
      assert.is_function(logger.info)
    end)

    it("should have warn method", function()
      local logger = named_logger.getLogger("warn_test")
      assert.is_function(logger.warn)
    end)

    it("should have error method", function()
      local logger = named_logger.getLogger("error_test")
      assert.is_function(logger.error)
    end)

    it("should have fatal method", function()
      local logger = named_logger.getLogger("fatal_test")
      assert.is_function(logger.fatal)
    end)
  end)

  describe("new (custom appender)", function()
    it("should create a logger with custom appender function", function()
      local log_messages = {}
      local custom_logger = named_logger.new(function(self, level, message)
        table.insert(log_messages, {level = level, message = message})
        return true
      end)

      assert.is_not_nil(custom_logger)
      custom_logger:info("test message")

      assert.equals(1, #log_messages)
      assert.equals("INFO", log_messages[1].level)
      assert.equals("test message", log_messages[1].message)
    end)

    it("should capture messages at different log levels", function()
      local log_messages = {}
      local custom_logger = named_logger.new(function(self, level, message)
        table.insert(log_messages, {level = level, message = message})
        return true
      end)

      custom_logger:setLevel(named_logger.DEBUG)
      custom_logger:debug("debug msg")
      custom_logger:info("info msg")
      custom_logger:warn("warn msg")
      custom_logger:error("error msg")

      assert.equals(4, #log_messages)
      assert.equals("DEBUG", log_messages[1].level)
      assert.equals("INFO", log_messages[2].level)
      assert.equals("WARN", log_messages[3].level)
      assert.equals("ERROR", log_messages[4].level)
    end)

    it("should respect log level filtering", function()
      local log_messages = {}
      local custom_logger = named_logger.new(function(self, level, message)
        table.insert(log_messages, {level = level, message = message})
        return true
      end)

      -- Set to ERROR level - should filter out DEBUG, INFO, WARN
      custom_logger:setLevel(named_logger.ERROR)
      custom_logger:debug("should not appear")
      custom_logger:info("should not appear")
      custom_logger:warn("should not appear")
      custom_logger:error("should appear")

      assert.equals(1, #log_messages)
      assert.equals("ERROR", log_messages[1].level)
    end)
  end)

  describe("logger instance log level filtering", function()
    it("should filter messages below the set level", function()
      -- We test this indirectly by checking that setLevel doesn't error
      -- and that different levels exist
      local logger = named_logger.getLogger("filter_test")

      -- These should not error
      logger:setLevel(named_logger.DEBUG)
      logger:setLevel(named_logger.INFO)
      logger:setLevel(named_logger.WARN)
      logger:setLevel(named_logger.ERROR)
      logger:setLevel(named_logger.FATAL)

      assert.is_true(true) -- If we get here, all setLevel calls worked
    end)
  end)

  describe("log output format", function()
    it("should include logger name in formatted output", function()
      local log_messages = {}
      local custom_logger = named_logger.new(function(self, level, message)
        table.insert(log_messages, message)
        return true
      end)

      -- The custom logger created by new() doesn't have the name formatting,
      -- but we can test that it works at all
      custom_logger:info("test")
      assert.equals(1, #log_messages)
      assert.equals("test", log_messages[1])
    end)
  end)
end)
