-- file_util_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

local lfs = require("lfs")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each
local pending = busted.pending

local file_util = require("file_util")

-- Simple path join function
local function path_join(...)
  return (table.concat({...}, "/"):gsub("//+", "/"))
end

describe("file_util", function()
  local temp_dir

  -- Setup: Create a temporary directory for testing
  before_each(function()
      local system_temp = file_util.getSystemTempDir()
      assert(system_temp ~= nil and system_temp ~= "", "Could not find system temp directory")
      local td = path_join(system_temp, "lua_file_util_test_" .. os.time())
      assert(lfs.mkdir(td))
      temp_dir = td
  end)

  -- Teardown: Remove the temporary directory after tests
  after_each(function()
      if temp_dir then
        local td = temp_dir
        temp_dir = nil
        file_util.deleteTempDir(td)
      end
  end)

  describe("getSystemTempDir", function()
    it("should return a non-empty string", function()
      local temp = file_util.getSystemTempDir()
      assert.is_string(temp)
      assert.is_truthy(temp ~= "")
    end)

    it("should return an existing directory", function()
      local temp = file_util.getSystemTempDir()
      assert.is_true(file_util.isDir(temp))
    end)

    it("should return a normalized path (forward slashes)", function()
      local temp = file_util.getSystemTempDir()
      -- Normalized paths use forward slashes, not backslashes
      assert.is_nil(temp:find("\\"))
    end)

    it("should return consistent results (cached)", function()
      local temp1 = file_util.getSystemTempDir()
      local temp2 = file_util.getSystemTempDir()
      assert.equal(temp1, temp2)
    end)

    it("should return platform-appropriate path", function()
      local temp = file_util.getSystemTempDir()
      if package.config:sub(1,1) == '\\' then
        -- Windows: expect drive letter or UNC path
        assert.is_truthy(temp:match("^%a:") or temp:match("^//"))
      else
        -- Unix: expect path starting with /
        assert.is_truthy(temp:match("^/"))
      end
    end)
  end)

  describe("normalizePath", function()
    it("should handle nil input", function()
      assert.is_nil(file_util.normalizePath(nil))
    end)

    it("should normalize Unix paths", function()
      assert.equal("/usr/local/bin", file_util.normalizePath("/usr/local/bin"))
      assert.equal("/usr/local/bin", file_util.normalizePath("/usr/local//bin"))
      assert.equal("/usr/local/bin", file_util.normalizePath("/usr/local/./bin"))
      assert.equal("/usr/bin", file_util.normalizePath("/usr/local/../bin"))
    end)

    it("should normalize Windows paths", function()
      assert.equal("C:/Users/John", file_util.normalizePath("C:\\Users\\John"))
      assert.equal("C:/Users/John", file_util.normalizePath("C:\\Users\\\\John"))
    end)

    it("should handle relative paths", function()
      assert.equal("../bin", file_util.normalizePath("../bin"))
      assert.equal("bin", file_util.normalizePath("./bin"))
    end)

    it("should return '.' for paths that resolve to the current directory", function()
      assert.equal(".", file_util.normalizePath("."))
      assert.equal(".", file_util.normalizePath("./"))
      assert.equal(".", file_util.normalizePath("a/.."))
      assert.equal(".", file_util.normalizePath("a/b/../.."))
    end)
  end)

  describe("hasExtension", function()
    it("should return true for matching extensions", function()
      assert.is_true(file_util.hasExtension("file.txt", "txt"))
      assert.is_true(file_util.hasExtension("file.tar.gz", "gz"))
    end)

    it("should return false for non-matching extensions", function()
      assert.is_false(file_util.hasExtension("file.txt", "doc"))
      assert.is_false(file_util.hasExtension("file", "txt"))
    end)
  end)

  describe("changeExtension", function()
    it("should replace the file extension", function()
      assert.equal("file.lua", file_util.changeExtension("file.txt", "lua"))
      assert.equal("document.md", file_util.changeExtension("document.txt", "md"))
    end)

    it("should add extension to files without one", function()
      assert.equal("file.lua", file_util.changeExtension("file", "lua"))
    end)

    it("should only replace the last extension for multi-dot files", function()
      assert.equal("file.tar.lua", file_util.changeExtension("file.tar.gz", "lua"))
      assert.equal("my.file.name.md", file_util.changeExtension("my.file.name.txt", "md"))
    end)

    it("should preserve the path", function()
      assert.equal("/path/to/file.lua", file_util.changeExtension("/path/to/file.txt", "lua"))
      assert.equal("C:/Users/file.md", file_util.changeExtension("C:/Users/file.doc", "md"))
    end)

    it("should error for non-string file argument", function()
      assert.has_error(function() file_util.changeExtension(123, "txt") end)
      assert.has_error(function() file_util.changeExtension({}, "txt") end)
      assert.has_error(function() file_util.changeExtension(nil, "txt") end)
    end)

    it("should error for non-string extension argument", function()
      assert.has_error(function() file_util.changeExtension("file.txt", 123) end)
      assert.has_error(function() file_util.changeExtension("file.txt", {}) end)
      assert.has_error(function() file_util.changeExtension("file.txt", nil) end)
    end)
  end)

  describe("unixEOL", function()
    it("should convert Windows and Mac line endings to Unix", function()
      assert.equal("line1\nline2\nline3", file_util.unixEOL("line1\r\nline2\rline3"))
    end)
  end)

  describe("splitPath", function()
    it("should split paths into components", function()
      assert.same({"usr", "local", "bin"}, file_util.splitPath("/usr/local/bin"))
      assert.same({"C:", "Users", "John"}, file_util.splitPath("C:\\Users\\John"))
    end)
  end)

  describe("getParentPath", function()
    it("should return the parent directory", function()
      assert.equal("/usr/local", file_util.getParentPath("/usr/local/bin"))
      assert.equal("C:/Users", file_util.getParentPath("C:\\Users\\John"))
    end)

    it("should return empty string for root", function()
      assert.is_nil(file_util.getParentPath("/"))
      assert.is_nil(file_util.getParentPath("C:\\"))
    end)
  end)

  describe("isDir", function()
      it("should return true for directories", function()
          assert.is_true(file_util.isDir(temp_dir))
      end)

      it("should return false for files", function()
          local file_path = path_join(temp_dir, "test_file.txt")
          file_util.writeFile(file_path, "test content")
          assert.is_false(file_util.isDir(file_path))
      end)
  end)

  describe("getFilesAndDirs", function()
      it("should return files and directories separately", function()
          local sub_dir = path_join(temp_dir, "sub_dir")
          lfs.mkdir(sub_dir)
          local file1 = path_join(temp_dir, "file1.txt")
          local file2 = path_join(temp_dir, "file2.txt")
          local file3 = path_join(sub_dir, "file3.txt")
          file_util.writeFile(file1, "content1")
          file_util.writeFile(file2, "content2")
          file_util.writeFile(file3, "content3")

          local files, dirs = file_util.getFilesAndDirs(temp_dir)
          -- file3 excluded because it's in a sub-directory
          assert.same({file1, file2}, files)
          assert.same({sub_dir}, dirs)
      end)
      it("should recurse if specified", function()
          local sub_dir = path_join(temp_dir, "sub_dir")
          lfs.mkdir(sub_dir)
          local file1 = path_join(temp_dir, "file1.txt")
          local file2 = path_join(sub_dir, "file2.txt")
          file_util.writeFile(file1, "content1")
          file_util.writeFile(file2, "content2")

          local files, dirs = file_util.getFilesAndDirs(temp_dir, true)
          assert.same({file1, file2}, files)
          assert.same({sub_dir}, dirs)
      end)
  end)

  describe("readFile and writeFile", function()
      it("should write and read file content correctly", function()
          local file_path = path_join(temp_dir, "test_file.txt")
          local content = "Hello, World!"
          
          assert.is_true(file_util.writeFile(file_path, content))
          
          local read_content = file_util.readFile(file_path)
          assert.equal(content, read_content)
      end)
  end)

  describe("safeReplaceFile", function()
      it("should safely replace file content", function()
          local file_path = path_join(temp_dir, "safe_replace_test.txt")
          local original_content = "Original content"
          local new_content = "New content"
          
          file_util.writeFile(file_path, original_content)
          assert.is_true(file_util.safeReplaceFile(file_path, new_content))
          
          local final_content = file_util.readFile(file_path)
          assert.equal(new_content, final_content)
      end)
  end)

  describe("collectFiles", function()
      it("should collect files with specified extensions", function()
          local sub_dir = path_join(temp_dir, "sub_dir")
          lfs.mkdir(sub_dir)
          file_util.writeFile(path_join(temp_dir, "file1.txt"), "content1")
          file_util.writeFile(path_join(temp_dir, "file2.lua"), "content2")
          file_util.writeFile(path_join(sub_dir, "file3.txt"), "content3")

          local files, errors = file_util.collectFiles({temp_dir}, {"txt"})
          assert.is_nil(errors)
          assert.same(2, #files)
          assert.is_true(table.concat(files, ","):find("file1.txt") ~= nil)
          assert.is_true(table.concat(files, ","):find("file3.txt") ~= nil)
      end)
  end)

  describe("deleteTempDir", function()
      it("should delete directory and its contents recursively", function()
          local sub_dir = path_join(temp_dir, "sub_dir")
          lfs.mkdir(sub_dir)
          file_util.writeFile(path_join(temp_dir, "file1.txt"), "content1")
          file_util.writeFile(path_join(sub_dir, "file2.txt"), "content2")

          assert.is_true(file_util.isDir(temp_dir))
          assert.is_true(file_util.deleteTempDir(temp_dir))
          assert.is_false(file_util.isDir(temp_dir))
      end)

      it("should return an error for non-existent directory", function()
          local non_existent_dir = path_join(temp_dir, "non_existent")
          local ok, err = file_util.deleteTempDir(non_existent_dir)
          assert.is_nil(ok)
          assert.is_not_nil(err)
      end)

      -- Security edge cases
      it("should refuse to delete directories outside of temp", function()
          -- Try to delete the current working directory (not in temp)
          local cwd = lfs.currentdir()
          -- Create a subdirectory in temp, then try to escape via ..
          local sub_dir = path_join(cwd, "tmp_delete_subdir")
          lfs.mkdir(sub_dir)

          local ok, err = file_util.deleteTempDir(sub_dir)
          assert.is_nil(ok)
          assert.is_not_nil(err)
          assert.is_truthy(err:find("Not a TEMP directory"))
      end)

      -- ONLY RUN THOSE TESTS IN A "THROW-AWAY" ENVIRONMENT!
      -- THEY COULD DESTROY YOUR FILES IF deleteTempDir() FAILS...
      if false then
        it("should refuse to delete root directory", function()
            local root
            if package.config:sub(1,1) == '\\' then
                root = "C:\\"
            else
                root = "/"
            end
            local ok, err = file_util.deleteTempDir(root)
            assert.is_nil(ok)
            assert.is_not_nil(err)
        end)

        it("should refuse path traversal attempts", function()
            -- Create a subdirectory in temp, then try to escape via ..
            local sub_dir = path_join(temp_dir, "subdir")
            lfs.mkdir(sub_dir)

            -- Attempt to traverse up and out of temp
            local traversal_path = path_join(sub_dir, "..", "..", "..")
            local ok, err = file_util.deleteTempDir(traversal_path)
            assert.is_nil(ok)
            assert.is_not_nil(err)
        end)

        it("should handle nil input", function()
            local ok, err = file_util.deleteTempDir(nil)
            assert.is_nil(ok)
            assert.is_not_nil(err)
        end)

        it("should handle empty string input", function()
            local ok, err = file_util.deleteTempDir("")
            assert.is_nil(ok)
            assert.is_not_nil(err)
        end)
      end
  end)

  describe("emptyDir", function()
      it("should remove all contents but keep the directory", function()
          local sub_dir = path_join(temp_dir, "sub_dir")
          lfs.mkdir(sub_dir)
          file_util.writeFile(path_join(temp_dir, "file1.txt"), "content1")
          file_util.writeFile(path_join(sub_dir, "file2.txt"), "content2")

          assert.is_true(file_util.isDir(temp_dir))
          assert.is_true(file_util.isDir(sub_dir))

          local ok, err = file_util.emptyDir(temp_dir)
          assert.is_nil(err)
          assert.is_true(ok)

          -- Directory should still exist
          assert.is_true(file_util.isDir(temp_dir))
          -- But should be empty
          local contents = file_util.safeDir(temp_dir)
          assert.same({}, contents)
      end)

      it("should handle already empty directory", function()
          assert.is_true(file_util.isDir(temp_dir))
          local contents_before = file_util.safeDir(temp_dir)
          assert.same({}, contents_before)

          local ok, err = file_util.emptyDir(temp_dir)
          assert.is_nil(err)
          assert.is_true(ok)

          assert.is_true(file_util.isDir(temp_dir))
      end)

      it("should handle deeply nested directories", function()
          local deep_dir = path_join(temp_dir, "a/b/c/d")
          file_util.mkdir(deep_dir)
          file_util.writeFile(path_join(deep_dir, "deep_file.txt"), "deep content")
          file_util.writeFile(path_join(temp_dir, "a/shallow.txt"), "shallow")

          local ok, err = file_util.emptyDir(temp_dir)
          assert.is_nil(err)
          assert.is_true(ok)

          assert.is_true(file_util.isDir(temp_dir))
          local contents = file_util.safeDir(temp_dir)
          assert.same({}, contents)
      end)

      it("should return an error for non-existent directory", function()
          local non_existent_dir = path_join(temp_dir, "non_existent")
          local ok, err = file_util.emptyDir(non_existent_dir)
          assert.is_nil(ok)
          assert.is_not_nil(err)
          assert.is_truthy(err:find("Not a directory"))
      end)

      it("should return an error for a file path", function()
          local file_path = path_join(temp_dir, "test_file.txt")
          file_util.writeFile(file_path, "content")

          local ok, err = file_util.emptyDir(file_path)
          assert.is_nil(ok)
          assert.is_not_nil(err)
          assert.is_truthy(err:find("Not a directory"))
      end)
  end)

  describe("sortFilesBreadthFirst", function()
      it("should sort files breadth-first", function()
          local files = {
              path_join(temp_dir, "deep/path/file.txt"),
              path_join(temp_dir, "file.txt"),
              path_join(temp_dir, "another/file.txt"),
              path_join(temp_dir, "deep/file.txt")
          }
          file_util.sortFilesBreadthFirst(files)
          assert.same({
              path_join(temp_dir, "file.txt"),
              path_join(temp_dir, "another/file.txt"),
              path_join(temp_dir, "deep/file.txt"),
              path_join(temp_dir, "deep/path/file.txt")
          }, files)
      end)
  end)

  describe("sortFilesBreadthFirst", function()
    it("should sort files breadth-first", function()
      local files = {
        "/deep/path/file.txt",
        "/file.txt",
        "/another/file.txt",
        "/deep/file.txt"
      }
      file_util.sortFilesBreadthFirst(files)
      assert.same({
        "/file.txt",
        "/another/file.txt",
        "/deep/file.txt",
        "/deep/path/file.txt"
      }, files)
    end)
  end)

  describe("isAbsolutePath", function()
    it("should return true for absolute paths", function()
      assert.is_true(file_util.isAbsolutePath("/usr/local/bin"))
      assert.is_true(file_util.isAbsolutePath("C:\\Windows\\System32"))
    end)

    it("should return false for relative paths", function()
      assert.is_false(file_util.isAbsolutePath("relative/path"))
      assert.is_false(file_util.isAbsolutePath("./current/directory"))
      assert.is_false(file_util.isAbsolutePath("../parent/directory"))
    end)
  end)

  describe("isRootDir", function()
    it("should return true for root directories", function()
      assert.is_true(file_util.isRootDir("/"))
      assert.is_true(file_util.isRootDir("C:\\"))
    end)

    it("should return false for non-root directories", function()
      assert.is_false(file_util.isRootDir("/usr/local"))
      assert.is_false(file_util.isRootDir("C:\\Users"))
      assert.is_false(file_util.isRootDir("relative/path"))
    end)
  end)

  describe("isSamePath", function()
    it("should return true for identical paths", function()
      assert.is_true(file_util.isSamePath("/usr/local/bin", "/usr/local/bin"))
      assert.is_true(file_util.isSamePath("C:\\Windows\\System32", "c:\\windows\\system32"))
    end)

    it("should return true for normalized equivalent paths", function()
      assert.is_true(file_util.isSamePath("/usr/local/bin", "/usr/local//bin"))
      assert.is_true(file_util.isSamePath("C:\\Windows\\System32", "C:\\Windows\\System32\\"))
    end)

    it("should return false for different paths", function()
      assert.is_false(file_util.isSamePath("/usr/local/bin", "/usr/local/lib"))
      assert.is_false(file_util.isSamePath("C:\\Windows\\System32", "C:\\Windows\\System"))
    end)

    it("should handle nil and empty string inputs", function()
      assert.is_true(file_util.isSamePath(nil, nil))
      assert.is_true(file_util.isSamePath("", ""))
      assert.is_true(file_util.isSamePath(nil, ""))
      assert.is_false(file_util.isSamePath("/some/path", nil))
    end)
  end)

  describe("pathJoin", function()
    it("should join path components correctly", function()
      assert.equal("/usr/local/bin", file_util.pathJoin("/usr", "local", "bin"))
      assert.equal("C:/Windows/System32", file_util.pathJoin("C:", "Windows", "System32"))
    end)

    it("should handle trailing slashes correctly", function()
      assert.equal("/usr/local/bin", file_util.pathJoin("/usr/", "local/", "bin"))
    end)

    it("should handle empty components", function()
      assert.equal("/usr/bin", file_util.pathJoin("/usr", "", "bin"))
    end)
  end)

  describe("safeDir", function()
    it("should return a list of directory contents", function()
      local dir_contents, err = file_util.safeDir(temp_dir)
      assert.is_nil(err)
      assert.is_table(dir_contents)
    end)

    it("should return an error for non-existent directory", function()
      local non_existent_dir = path_join(temp_dir, "non_existent")
      local dir_contents, err = file_util.safeDir(non_existent_dir)
      assert.is_nil(dir_contents)
      assert.is_not_nil(err)
    end)

    it("should handle nil input", function()
      local dir_contents, err = file_util.safeDir(nil)
      assert.is_nil(dir_contents)
      assert.is_not_nil(err)
    end)

    it("should handle empty string input", function()
      local dir_contents, err = file_util.safeDir("")
      assert.is_nil(dir_contents)
      assert.is_not_nil(err)
    end)
  end)

  describe("toOSPath", function()
    it("should handle nil input", function()
      assert.is_nil(file_util.toOSPath(nil))
    end)

    it("should handle empty string input", function()
      assert.is_nil(file_util.toOSPath(""))
    end)

    it("should error for non-string input", function()
      assert.has_error(function() file_util.toOSPath(123) end)
      assert.has_error(function() file_util.toOSPath({}) end)
    end)

    it("should convert normalized paths to OS-specific format", function()
      local result = file_util.toOSPath("/usr/local/bin")
      -- On Windows, should convert to backslashes; on Unix, stays the same
      if package.config:sub(1,1) == '\\' then
        assert.equal("\\usr\\local\\bin", result)
      else
        assert.equal("/usr/local/bin", result)
      end
    end)

    it("should convert Windows-style normalized paths", function()
      local result = file_util.toOSPath("C:/Users/John")
      if package.config:sub(1,1) == '\\' then
        assert.equal("C:\\Users\\John", result)
      else
        assert.equal("C:/Users/John", result)
      end
    end)

    it("should handle paths without slashes", function()
      assert.equal("filename.txt", file_util.toOSPath("filename.txt"))
    end)
  end)

  describe("mkdir", function()
    it("should create a new directory", function()
      local new_dir = path_join(temp_dir, "new_subdir")
      assert.is_false(file_util.isDir(new_dir))
      assert.is_true(file_util.mkdir(new_dir))
      assert.is_true(file_util.isDir(new_dir))
    end)

    it("should create nested directories recursively", function()
      local nested_dir = path_join(temp_dir, "parent/child/grandchild")
      assert.is_false(file_util.isDir(path_join(temp_dir, "parent")))
      assert.is_false(file_util.isDir(path_join(temp_dir, "parent/child")))
      assert.is_false(file_util.isDir(nested_dir))

      assert.is_true(file_util.mkdir(nested_dir))

      assert.is_true(file_util.isDir(path_join(temp_dir, "parent")))
      assert.is_true(file_util.isDir(path_join(temp_dir, "parent/child")))
      assert.is_true(file_util.isDir(nested_dir))
    end)

    it("should return true for existing directory", function()
      assert.is_true(file_util.isDir(temp_dir))
      assert.is_true(file_util.mkdir(temp_dir))
    end)

    it("should return error for non-string path", function()
      local ok, err = file_util.mkdir(123)
      assert.is_nil(ok)
      assert.is_not_nil(err)
    end)

    it("should return error for nil path", function()
      local ok, err = file_util.mkdir(nil)
      assert.is_nil(ok)
      assert.is_not_nil(err)
    end)

    it("should return error for empty string path", function()
      local ok, err = file_util.mkdir("")
      assert.is_nil(ok)
      assert.is_not_nil(err)
    end)
  end)

end)
