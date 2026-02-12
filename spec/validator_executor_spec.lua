-- validator_executor_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local validator_executor = require("validator_executor")
local error_reporting = require("error_reporting")

-- Creates a plain value row (validators now see parsed values directly)
local function makeRow(map)
    return map
end

-- Returns a "badVal" object that stores errors in the given table
local function mockBadVal(log_messages)
    local log = function(self, msg) table.insert(log_messages, msg) end
    local badVal = error_reporting.badValGen(log)
    badVal.source_name = "test"
    badVal.line_no = 1
    return badVal
end

describe("validator_executor", function()

  -- ============================================================
  -- normalizeValidatorSpec
  -- ============================================================

  describe("normalizeValidatorSpec", function()
    it("should normalize a string to error level", function()
      local result = validator_executor.normalizeValidatorSpec("x > 0")
      assert.are.equal("x > 0", result.expr)
      assert.are.equal("error", result.level)
    end)

    it("should preserve table with expr and level", function()
      local result = validator_executor.normalizeValidatorSpec(
        {expr = "x > 0", level = "warn"})
      assert.are.equal("x > 0", result.expr)
      assert.are.equal("warn", result.level)
    end)

    it("should use positional expr from table", function()
      local result = validator_executor.normalizeValidatorSpec({"x > 0"})
      assert.are.equal("x > 0", result.expr)
      assert.are.equal("error", result.level)
    end)

    it("should default level to error for table without level", function()
      local result = validator_executor.normalizeValidatorSpec({expr = "x > 0"})
      assert.are.equal("x > 0", result.expr)
      assert.are.equal("error", result.level)
    end)

    it("should handle non-string non-table with tostring", function()
      local result = validator_executor.normalizeValidatorSpec(42)
      assert.are.equal("42", result.expr)
      assert.are.equal("error", result.level)
    end)
  end)

  -- ============================================================
  -- Result interpretation (tested via executeValidator)
  -- ============================================================

  describe("result interpretation", function()
    it("should treat true as valid", function()
      local isValid, msg = validator_executor.executeValidator(
        "true", {}, 1000)
      assert.is_true(isValid)
      assert.is_nil(msg)
    end)

    it("should treat empty string as valid", function()
      local isValid, msg = validator_executor.executeValidator(
        "''", {}, 1000)
      assert.is_true(isValid)
      assert.is_nil(msg)
    end)

    it("should treat false as invalid with default message", function()
      local isValid, msg = validator_executor.executeValidator(
        "false", {}, 1000)
      assert.is_false(isValid)
      assert.are.equal("validation failed", msg)
    end)

    it("should treat nil as invalid with default message", function()
      local isValid, msg = validator_executor.executeValidator(
        "nil", {}, 1000)
      assert.is_false(isValid)
      assert.are.equal("validation failed", msg)
    end)

    it("should treat non-empty string as invalid with custom message", function()
      local isValid, msg = validator_executor.executeValidator(
        "'price must be positive'", {}, 1000)
      assert.is_false(isValid)
      assert.are.equal("price must be positive", msg)
    end)

    it("should treat unexpected types as invalid", function()
      local isValid, msg = validator_executor.executeValidator(
        "42", {}, 1000)
      assert.is_false(isValid)
      assert.is.truthy(msg:match("unexpected value"))
    end)
  end)

  -- ============================================================
  -- executeValidator
  -- ============================================================

  describe("executeValidator", function()
    it("should pass for expression returning true", function()
      local isValid, msg = validator_executor.executeValidator(
        "true", {}, 1000)
      assert.is_true(isValid)
      assert.is_nil(msg)
    end)

    it("should fail for expression returning false", function()
      local isValid, msg = validator_executor.executeValidator(
        "false", {}, 1000)
      assert.is_false(isValid)
      assert.are.equal("validation failed", msg)
    end)

    it("should return custom error message from expression", function()
      local isValid, msg = validator_executor.executeValidator(
        "false or 'value is invalid'", {}, 1000)
      assert.is_false(isValid)
      assert.are.equal("value is invalid", msg)
    end)

    it("should pass with or-pattern returning true", function()
      local isValid, msg = validator_executor.executeValidator(
        "true or 'should not see this'", {}, 1000)
      assert.is_true(isValid)
      assert.is_nil(msg)
    end)

    it("should access context self", function()
      local row = makeRow({price = 50})
      local isValid, msg = validator_executor.executeValidator(
        "self.price > 0 or 'price must be positive'",
        {self = row}, 1000)
      assert.is_true(isValid)
    end)

    it("should fail with context self", function()
      local row = makeRow({price = -5})
      local isValid, msg = validator_executor.executeValidator(
        "self.price > 0 or 'price must be positive'",
        {self = row}, 1000)
      assert.is_false(isValid)
      assert.are.equal("price must be positive", msg)
    end)

    it("should access context rowIndex", function()
      local isValid, msg = validator_executor.executeValidator(
        "rowIndex > 0", {rowIndex = 5}, 1000)
      assert.is_true(isValid)
    end)

    it("should access context fileName", function()
      local isValid, msg = validator_executor.executeValidator(
        "fileName == 'test.tsv'", {fileName = "test.tsv"}, 1000)
      assert.is_true(isValid)
    end)

    it("should access helper functions", function()
      local rows = {
        makeRow({val = 10}),
        makeRow({val = 20}),
        makeRow({val = 30}),
      }
      local isValid, msg = validator_executor.executeValidator(
        "count(rows) == 3", {rows = rows}, 1000)
      assert.is_true(isValid)
    end)

    it("should access sum helper", function()
      local rows = {
        makeRow({val = 10}),
        makeRow({val = 20}),
      }
      local isValid, msg = validator_executor.executeValidator(
        "sum(rows, 'val') == 30", {rows = rows}, 1000)
      assert.is_true(isValid)
    end)

    it("should fail on syntax error", function()
      local isValid, msg = validator_executor.executeValidator(
        "if then", {}, 1000)
      assert.is_false(isValid)
      assert.is.truthy(msg:match("failed to compile"))
    end)

    it("should fail on runtime error", function()
      local isValid, msg = validator_executor.executeValidator(
        "nonexistent_var.field > 0", {}, 1000)
      assert.is_false(isValid)
      assert.is.truthy(msg:match("execution error"))
    end)

    it("should support extra environment variables", function()
      local isValid, msg = validator_executor.executeValidator(
        "myVar == 42", {}, 1000, {myVar = 42})
      assert.is_true(isValid)
    end)

    it("should provide math library", function()
      local isValid, msg = validator_executor.executeValidator(
        "math.floor(3.7) == 3", {}, 1000)
      assert.is_true(isValid)
    end)

    it("should provide string library", function()
      local isValid, msg = validator_executor.executeValidator(
        "string.len('hello') == 5", {}, 1000)
      assert.is_true(isValid)
    end)

    it("should provide type function", function()
      local isValid, msg = validator_executor.executeValidator(
        "type(42) == 'number'", {}, 1000)
      assert.is_true(isValid)
    end)
  end)

  -- ============================================================
  -- runRowValidators
  -- ============================================================

  describe("runRowValidators", function()
    it("should pass with empty validators", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local row = makeRow({price = 10})
      local success, warnings = validator_executor.runRowValidators(
        {}, row, 2, "test.tsv", badVal)
      assert.is_true(success)
      assert.are.equal(0, #warnings)
    end)

    it("should pass with nil validators", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local row = makeRow({price = 10})
      local success, warnings = validator_executor.runRowValidators(
        nil, row, 2, "test.tsv", badVal)
      assert.is_true(success)
      assert.are.equal(0, #warnings)
    end)

    it("should pass with a passing validator", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local row = makeRow({price = 10})
      local success, warnings = validator_executor.runRowValidators(
        {"self.price > 0 or 'price must be positive'"},
        row, 2, "test.tsv", badVal)
      assert.is_true(success)
      assert.are.equal(0, #warnings)
      assert.are.equal(0, badVal.errors)
    end)

    it("should fail with error-level validator", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local row = makeRow({price = -5})
      local success, warnings = validator_executor.runRowValidators(
        {"self.price > 0 or 'price must be positive'"},
        row, 2, "test.tsv", badVal)
      assert.is_false(success)
      assert.are.equal(1, badVal.errors)
    end)

    it("should collect warnings from warn-level validator", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local row = makeRow({price = 5000})
      local success, warnings = validator_executor.runRowValidators(
        {{expr = "self.price < 1000 or 'price seems high'", level = "warn"}},
        row, 2, "test.tsv", badVal)
      assert.is_true(success)
      assert.are.equal(1, #warnings)
      assert.are.equal("price seems high", warnings[1].message)
      assert.are.equal(2, warnings[1].rowIndex)
      assert.are.equal(0, badVal.errors)
    end)

    it("should stop on first error-level failure", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local row = makeRow({price = -5, count = -1})
      local success, warnings = validator_executor.runRowValidators(
        {
          "self.price > 0 or 'price must be positive'",
          "self.count >= 0 or 'count cannot be negative'",
        },
        row, 2, "test.tsv", badVal)
      assert.is_false(success)
      -- Only 1 error because it stops at first error
      assert.are.equal(1, badVal.errors)
    end)

    it("should accumulate warnings across validators", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local row = makeRow({price = 5000, count = 999})
      local success, warnings = validator_executor.runRowValidators(
        {
          {expr = "self.price < 1000 or 'price high'", level = "warn"},
          {expr = "self.count < 100 or 'count high'", level = "warn"},
        },
        row, 2, "test.tsv", badVal)
      assert.is_true(success)
      assert.are.equal(2, #warnings)
      assert.are.equal(0, badVal.errors)
    end)

    it("should provide correct context", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local row = makeRow({val = 1})
      local success, warnings = validator_executor.runRowValidators(
        {"rowIndex == 5 and fileName == 'data.tsv'"},
        row, 5, "data.tsv", badVal)
      assert.is_true(success)
    end)
  end)

  -- ============================================================
  -- runFileValidators
  -- ============================================================

  describe("runFileValidators", function()
    it("should pass with empty validators", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local success, warnings = validator_executor.runFileValidators(
        {}, {}, "test.tsv", badVal)
      assert.is_true(success)
      assert.are.equal(0, #warnings)
    end)

    it("should pass with nil validators", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local success, warnings = validator_executor.runFileValidators(
        nil, {}, "test.tsv", badVal)
      assert.is_true(success)
    end)

    it("should pass with count-based validator", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local rows = {
        makeRow({val = 1}),
        makeRow({val = 2}),
      }
      local success, warnings = validator_executor.runFileValidators(
        {"count(rows) <= 100 or 'too many rows'"},
        rows, "test.tsv", badVal)
      assert.is_true(success)
      assert.are.equal(0, badVal.errors)
    end)

    it("should fail with error-level file validator", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local rows = {}
      local success, warnings = validator_executor.runFileValidators(
        {"count(rows) > 0 or 'file must have rows'"},
        rows, "test.tsv", badVal)
      assert.is_false(success)
      assert.are.equal(1, badVal.errors)
    end)

    it("should collect warnings from warn-level file validator", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local rows = {
        makeRow({val = 1}),
        makeRow({val = 2}),
        makeRow({val = 3}),
      }
      local success, warnings = validator_executor.runFileValidators(
        {{expr = "count(rows) <= 2 or 'many rows'", level = "warn"}},
        rows, "test.tsv", badVal)
      assert.is_true(success)
      assert.are.equal(1, #warnings)
      assert.are.equal("many rows", warnings[1].message)
      assert.are.equal("test.tsv", warnings[1].fileName)
    end)

    it("should set source_name on badVal for errors", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local success, warnings = validator_executor.runFileValidators(
        {"false or 'always fails'"},
        {}, "myfile.tsv", badVal)
      assert.is_false(success)
      assert.are.equal("myfile.tsv", badVal.source_name)
    end)

    it("should provide rows and fileName context", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local rows = {
        makeRow({val = 10}),
        makeRow({val = 20}),
      }
      local success, warnings = validator_executor.runFileValidators(
        {"sum(rows, 'val') == 30 and fileName == 'data.tsv'"},
        rows, "data.tsv", badVal)
      assert.is_true(success)
    end)
  end)

  -- ============================================================
  -- runPackageValidators
  -- ============================================================

  describe("runPackageValidators", function()
    it("should pass with empty validators", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local success, warnings = validator_executor.runPackageValidators(
        {}, {}, "pkg.test", badVal)
      assert.is_true(success)
      assert.are.equal(0, #warnings)
    end)

    it("should pass with nil validators", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local success, warnings = validator_executor.runPackageValidators(
        nil, {}, "pkg.test", badVal)
      assert.is_true(success)
    end)

    it("should pass with files-based validator", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local files = {
        ["items.tsv"] = {makeRow({val = 1})},
        ["config.tsv"] = {makeRow({val = 2})},
      }
      local success, warnings = validator_executor.runPackageValidators(
        {"type(files) == 'table'"},
        files, "pkg.test", badVal)
      assert.is_true(success)
    end)

    it("should fail with error-level package validator", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local success, warnings = validator_executor.runPackageValidators(
        {"false or 'package is invalid'"},
        {}, "pkg.test", badVal)
      assert.is_false(success)
      assert.are.equal(1, badVal.errors)
    end)

    it("should set source_name with package prefix on errors", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local success, warnings = validator_executor.runPackageValidators(
        {"false or 'fails'"},
        {}, "my.package", badVal)
      assert.is_false(success)
      assert.are.equal("package:my.package", badVal.source_name)
    end)

    it("should collect warnings from warn-level package validator", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local success, warnings = validator_executor.runPackageValidators(
        {{expr = "false or 'check this'", level = "warn"}},
        {}, "pkg.test", badVal)
      assert.is_true(success)
      assert.are.equal(1, #warnings)
      assert.are.equal("check this", warnings[1].message)
      assert.are.equal("pkg.test", warnings[1].packageId)
    end)

    it("should provide packageId context", function()
      local log_messages = {}
      local badVal = mockBadVal(log_messages)
      local success, warnings = validator_executor.runPackageValidators(
        {"packageId == 'demo.pkg' or 'wrong package'"},
        {}, "demo.pkg", badVal)
      assert.is_true(success)
    end)
  end)

  -- ============================================================
  -- Writable ctx table
  -- ============================================================

  describe("writable ctx", function()

    describe("in row validators", function()
      it("should be available and writable", function()
        local log_messages = {}
        local badVal = mockBadVal(log_messages)
        local row = makeRow({val = 1})
        local ctx = {}
        local success, warnings = validator_executor.runRowValidators(
          {"(function() ctx.seen = true; return true end)()"},
          row, 2, "test.tsv", badVal, nil, ctx)
        assert.is_true(success)
        assert.is_true(ctx.seen)
      end)

      it("should persist across multiple rows with same ctx", function()
        local log_messages = {}
        local badVal = mockBadVal(log_messages)
        local ctx = {}

        -- First row: initialize counter
        local row1 = makeRow({val = 10})
        validator_executor.runRowValidators(
          {"(function() ctx.total = (ctx.total or 0) + self.val; return true end)()"},
          row1, 2, "test.tsv", badVal, nil, ctx)

        -- Second row: accumulate
        local row2 = makeRow({val = 20})
        validator_executor.runRowValidators(
          {"(function() ctx.total = (ctx.total or 0) + self.val; return true end)()"},
          row2, 3, "test.tsv", badVal, nil, ctx)

        assert.are.equal(30, ctx.total)
      end)

      it("should support uniqueness checking pattern", function()
        local log_messages = {}
        local badVal = mockBadVal(log_messages)
        local ctx = {}
        local validator = "(function() ctx.ids = ctx.ids or {}; if ctx.ids[self.id] then return 'duplicate id: ' .. tostring(self.id) end; ctx.ids[self.id] = true; return true end)()"

        -- First row: unique
        local row1 = makeRow({id = "a"})
        local success1 = validator_executor.runRowValidators(
          {validator}, row1, 2, "test.tsv", badVal, nil, ctx)
        assert.is_true(success1)

        -- Second row: unique
        local row2 = makeRow({id = "b"})
        local success2 = validator_executor.runRowValidators(
          {validator}, row2, 3, "test.tsv", badVal, nil, ctx)
        assert.is_true(success2)

        -- Third row: duplicate
        local row3 = makeRow({id = "a"})
        local success3 = validator_executor.runRowValidators(
          {validator}, row3, 4, "test.tsv", badVal, nil, ctx)
        assert.is_false(success3)
      end)

      it("should default to empty table when ctx not provided", function()
        local log_messages = {}
        local badVal = mockBadVal(log_messages)
        local row = makeRow({val = 1})
        -- No ctx argument - should not error
        local success, warnings = validator_executor.runRowValidators(
          {"type(ctx) == 'table'"},
          row, 2, "test.tsv", badVal)
        assert.is_true(success)
      end)
    end)

    describe("in file validators", function()
      it("should be available and writable", function()
        local log_messages = {}
        local badVal = mockBadVal(log_messages)
        local rows = {makeRow({val = 1})}
        local success, warnings = validator_executor.runFileValidators(
          {"(function() ctx.cached = sum(rows, 'val'); return true end)()"},
          rows, "test.tsv", badVal)
        assert.is_true(success)
      end)

      it("should persist across multiple file validator expressions", function()
        local log_messages = {}
        local badVal = mockBadVal(log_messages)
        local rows = {
          makeRow({val = 10}),
          makeRow({val = 20}),
        }
        local success, warnings = validator_executor.runFileValidators(
          {
            "(function() ctx.total = sum(rows, 'val'); return true end)()",
            "ctx.total == 30 or 'cached total mismatch'",
          },
          rows, "test.tsv", badVal)
        assert.is_true(success)
        assert.are.equal(0, #warnings)
      end)
    end)

    describe("in package validators", function()
      it("should be available and writable", function()
        local log_messages = {}
        local badVal = mockBadVal(log_messages)
        local files = {["items.tsv"] = {makeRow({val = 1})}}
        local success, warnings = validator_executor.runPackageValidators(
          {"(function() ctx.checked = true; return true end)()"},
          files, "pkg.test", badVal)
        assert.is_true(success)
      end)

      it("should persist across multiple package validator expressions", function()
        local log_messages = {}
        local badVal = mockBadVal(log_messages)
        local files = {
          ["items.tsv"] = {makeRow({val = 5}), makeRow({val = 15})},
        }
        local success, warnings = validator_executor.runPackageValidators(
          {
            "(function() ctx.itemCount = count(files['items.tsv']); return true end)()",
            "ctx.itemCount == 2 or 'wrong item count'",
          },
          files, "pkg.test", badVal)
        assert.is_true(success)
        assert.are.equal(0, #warnings)
      end)
    end)
  end)

  -- ============================================================
  -- Module API
  -- ============================================================

  describe("module API", function()
    it("should have a version", function()
      local version = validator_executor.getVersion()
      assert.is_not_nil(version)
      assert.is.truthy(version:match("%d+%.%d+%.%d+"))
    end)

    it("should expose quota constants", function()
      assert.are.equal(1000, validator_executor.ROW_VALIDATOR_QUOTA)
      assert.are.equal(10000, validator_executor.FILE_VALIDATOR_QUOTA)
      assert.are.equal(100000, validator_executor.PACKAGE_VALIDATOR_QUOTA)
    end)

    it("should have a tostring representation", function()
      local str = tostring(validator_executor)
      assert.is.truthy(str:match("validator_executor"))
    end)

    it("should support callable interface for version", function()
      local version = validator_executor("version")
      assert.is_not_nil(version)
    end)
  end)
end)
