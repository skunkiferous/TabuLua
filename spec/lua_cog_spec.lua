-- lua_cog_spec.lua

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

-- Import busted functions
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local lua_cog = require("lua_cog")
local file_util = require("file_util")

-- Prefix for snippet file name
local PREFIX = 'lua_cog_spec_snippet_'

-- Sub-dir for the snippets files
local SNIPPETS_DIR = 'cog_snippets'

-- Helper to join paths consistently
local function path_join(...)
  return (table.concat({...}, "/"):gsub("//+", "/"))
end

local function snippet(num)
  num = tostring(num)
  if #num == 1 then
    num = "0" .. num
  end
  local file_name = PREFIX .. num .. ".txt"
  local path = path_join('spec', SNIPPETS_DIR,file_name)
  local content, err = file_util.readFile(path)
  assert(content, err)
  return content
end

describe("lua_cog", function()
  local temp_dir

  -- Setup: Create a temporary directory for testing
  before_each(function()
    local system_temp = file_util.getSystemTempDir()
    assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
    local td = path_join(system_temp, "lua_cog_test_" .. os.time())
    assert(lfs.mkdir(td))
    temp_dir = td
  end)

  -- Cleanup: Remove temporary directory after tests
  after_each(function()
    if temp_dir then
      local td = temp_dir
      temp_dir = nil
      file_util.deleteTempDir(td)
    end
  end)

  describe("needsCog", function()
    it("should return true for content with code blocks", function()
      local content = snippet(1)
      assert.is_true(lua_cog.needsCog(content))
    end)

    it("should return false for content without code blocks", function()
      local content = "Normal content\nwithout any code blocks"
      assert.is_false(lua_cog.needsCog(content))
    end)

    it("should handle all comment styles", function()
      local styles = {
        snippet(2),
        snippet(3)
      }
      for _, content in ipairs(styles) do
        assert.is_true(lua_cog.needsCog(content))
      end
    end)
  end)

  describe("processContent", function()
    it("should process simple code blocks", function()
      local content = snippet(4)

      local result = lua_cog.processContent(content, {}, {})
      assert.is_not_nil(result)
      local output = table.concat(result, "\n")
      assert.matches("Header", output)
      assert.matches("Generated content", output)
      assert.matches("Footer", output)
      assert.not_matches("Old content", output)
    end)

    it("should handle multiple code blocks", function()
      local content = snippet(5)

      local result = lua_cog.processContent(content, {}, {})
      assert.is_not_nil(result)
      local output = table.concat(result, "\n")
      assert.matches("First", output)
      assert.matches("Second", output)
      assert.matches("Middle", output)
      assert.not_matches("Old1", output)
      assert.not_matches("Old2", output)
    end)

    it("should use provided environment", function()
      local content = snippet(6)

      local env = {test_var = "Environment value"}
      local result = lua_cog.processContent(content, env, {})
      assert.is_not_nil(result)
      local output = table.concat(result, "\n")
      assert.matches("Environment value", output)
    end)

    it("should collect errors for invalid code", function()
      local content = snippet(7)

      local errors = {}
      local result = lua_cog.processContent(content, {}, errors)
      assert.is_not_nil(result)
      assert.is_true(#errors > 0)
      assert.matches("Error executing", errors[1])
    end)
  end)

  describe("file operations", function()
    it("should process a file correctly", function()
      local input_path = path_join(temp_dir, "input.txt")
      local output_path = path_join(temp_dir, "output.txt")
      
      local content = snippet(8)

      assert.is_true(file_util.writeFile(input_path, content))
      
      local errors = {}
      local success = lua_cog.rewriteFile(input_path, output_path, {}, errors)
      assert.is_true(success)
      assert.equals(0, #errors)

      local result = file_util.readFile(output_path)
      assert.matches("Header", result)
      assert.matches("GENERATED", result)
      assert.matches("Footer", result)
      assert.not_matches("old content", result)
    end)

    it("should prevent overwriting input file", function()
      local file_path = path_join(temp_dir, "test.txt")
      local content = "Test content"
      
      assert.is_true(file_util.writeFile(file_path, content))

      local errors = {}
      local success = lua_cog.rewriteFile(file_path, file_path, {}, errors)
      assert.is_false(success)
      assert.equals(1, #errors)
      assert.matches("must be different", errors[1])
    end)
  end)

  describe("error handling", function()
    it("should handle nested code blocks properly", function()
      local content = snippet(9)

      local errors = {}
      local result = lua_cog.processContent(content, {}, errors)
      assert.is_nil(result)
      assert.equals(1, #errors)
      assert.matches("cannot be nested", errors[1])
    end)

    it("should handle missing end markers", function()
      local content = snippet(10) -- Missing end marker

      local errors = {}
      local result = lua_cog.processContent(content, {}, errors)
      assert.is_not_nil(result) -- Should still process what it can
      local output = table.concat(result, "\n")
      assert.matches("test", output)
    end)

    it("should handle empty code blocks", function()
      local content = snippet(11)

      local errors = {}
      local result = lua_cog.processContent(content, {}, errors)
      assert.is_not_nil(result)
      assert.equals(0, #errors) -- Empty blocks are allowed
    end)
  end)

  describe("processLines", function()
    it("should process lines directly without EOL conversion", function()
      local lines = {
        "Header",
        "---[[[",
        "---return 'Generated'",
        "---]]]",
        "Old content",
        "---[[[end]]]",
        "Footer"
      }
      local errors = {}
      local result = lua_cog.processLines(lines, {}, errors)
      assert.is_not_nil(result)
      assert.equals(0, #errors)
      local output = table.concat(result, "\n")
      assert.matches("Header", output)
      assert.matches("Generated", output)
      assert.matches("Footer", output)
      assert.not_matches("Old content", output)
    end)

    it("should handle ### comment style", function()
      local lines = {
        "Header",
        "###[[[",
        "###return 'Hash style'",
        "###]]]",
        "Old",
        "###[[[end]]]"
      }
      local errors = {}
      local result = lua_cog.processLines(lines, {}, errors)
      assert.is_not_nil(result)
      assert.equals(0, #errors)
      local output = table.concat(result, "\n")
      assert.matches("Hash style", output)
      assert.not_matches("Old", output)
    end)

    it("should handle /// comment style", function()
      local lines = {
        "Header",
        "///[[[",
        "///return 'Slash style'",
        "///]]]",
        "Old",
        "///[[[end]]]"
      }
      local errors = {}
      local result = lua_cog.processLines(lines, {}, errors)
      assert.is_not_nil(result)
      assert.equals(0, #errors)
      local output = table.concat(result, "\n")
      assert.matches("Slash style", output)
      assert.not_matches("Old", output)
    end)

    it("should error on lines without proper comment prefix in code block", function()
      local lines = {
        "---[[[",
        "return 'No prefix'",  -- Missing --- prefix
        "---]]]",
        "Old",
        "---[[[end]]]"
      }
      local errors = {}
      local result = lua_cog.processLines(lines, {}, errors)
      assert.is_not_nil(result)
      assert.is_true(#errors > 0)
      assert.matches("line must start with", errors[1])
    end)
  end)

  describe("processFile", function()
    it("should return error for non-existent file", function()
      local errors = {}
      local result = lua_cog.processFile("non_existent_file_12345.txt", {}, errors)
      assert.is_nil(result)
      assert.equals(1, #errors)
      -- Error message should indicate file not found or cannot be read
      assert.is_true(#errors[1] > 0)
    end)

    it("should process an existing file", function()
      local input_path = path_join(temp_dir, "test_input.txt")
      local content = "Header\n---[[[\n---return 'Test'\n---]]]\nOld\n---[[[end]]]\nFooter"
      assert.is_true(file_util.writeFile(input_path, content))

      local errors = {}
      local result = lua_cog.processFile(input_path, {}, errors)
      assert.is_not_nil(result)
      assert.equals(0, #errors)
      local output = table.concat(result, "\n")
      assert.matches("Test", output)
    end)
  end)

  describe("tryProcessContent", function()
    it("should return original content when no COG markers present", function()
      local content = "Just plain text\nwith no markers"
      local result, err = lua_cog.tryProcessContent(content, {})
      assert.is_nil(err)
      assert.equals(content, result)
    end)

    it("should process content with COG markers", function()
      local content = snippet(4)
      local result, err = lua_cog.tryProcessContent(content, {})
      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.matches("Generated content", result)
      assert.not_matches("Old content", result)
    end)

    it("should return error message on processing failure", function()
      local content = snippet(7)  -- Contains invalid code
      local result, err = lua_cog.tryProcessContent(content, {})
      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.matches("Problems with COG processing", err)
    end)

    it("should use provided environment", function()
      local content = snippet(6)
      local env = {test_var = "Env value from tryProcessContent"}
      local result, err = lua_cog.tryProcessContent(content, env)
      assert.is_nil(err)
      assert.matches("Env value from tryProcessContent", result)
    end)

    it("should return error for nested blocks", function()
      local content = snippet(9)  -- Nested blocks
      local result, err = lua_cog.tryProcessContent(content, {})
      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.matches("Problems with COG processing", err)
      assert.matches("cannot be nested", err)
    end)
  end)

  describe("processContentBV", function()
    it("should return original content when no COG markers present", function()
      local content = "Plain text without markers"
      local badVal_called = false
      local mock_badVal = function() badVal_called = true end

      local result = lua_cog.processContentBV("test.txt", content, {}, mock_badVal)
      assert.equals(content, result)
      assert.is_false(badVal_called)
    end)

    it("should process content and return result on success", function()
      local content = snippet(4)
      local badVal_called = false
      local mock_badVal = function() badVal_called = true end

      local result = lua_cog.processContentBV("test.txt", content, {}, mock_badVal)
      assert.is_not_nil(result)
      assert.matches("Generated content", result)
      assert.is_false(badVal_called)
    end)

    it("should call badVal and return original content on error", function()
      local content = snippet(7)  -- Contains invalid code
      local badVal_called = false
      local badVal_message = nil
      local mock_badVal = function(_, msg)
        badVal_called = true
        badVal_message = msg
      end

      local result = lua_cog.processContentBV("test.txt", content, {}, mock_badVal)
      assert.is_true(badVal_called)
      assert.is_not_nil(badVal_message)
      assert.matches("Problems with COG processing", badVal_message)
      -- Should return original content on error
      assert.equals(content, result)
    end)

    it("should call badVal for nested block errors", function()
      local content = snippet(9)  -- Nested blocks
      local badVal_message = nil
      local mock_badVal = function(_, msg) badVal_message = msg end

      local result = lua_cog.processContentBV("test.txt", content, {}, mock_badVal)
      assert.is_not_nil(badVal_message)
      assert.matches("cannot be nested", badVal_message)
      assert.equals(content, result)
    end)

    it("should use provided environment", function()
      local content = snippet(6)
      local env = {test_var = "BV environment value"}
      local mock_badVal = function() end

      local result = lua_cog.processContentBV("test.txt", content, env, mock_badVal)
      assert.matches("BV environment value", result)
    end)
  end)
end)
