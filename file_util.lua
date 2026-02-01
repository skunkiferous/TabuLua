-- Module name
local NAME = "file_util"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 3, 0)

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

local lfs = require("lfs")

-- Pattern to extract the parent directory of a path in Unix
local UNIX_PARENT_DIR = "^(.+)/"
-- Pattern to extract the parent directory of a path in Windows
local WIN_PARENT_DIR = "^(.+)\\"

local read_only = require("read_only")
local readOnly = read_only.readOnly
local table_utils = require("table_utils")
local setToSeq = table_utils.setToSeq

--- Checks if a path is a root directory (/, \, or drive letter like C:\).
--- @param path any The value to check
--- @return boolean True if path is a root directory, false otherwise
local function isRootDir(path)
    if (type(path) == "string") and (path == "/" or path == "\\" or path:match("^%a:\\$")) then
        return true
    end
    return false
end

--- Checks if a path is absolute (starts with /, \, or drive letter).
--- @param path any The value to check
--- @return boolean True if path is absolute, false otherwise
local function isAbsolutePath(path)
    if type(path) == "string" then
        local first = path:sub(1, 1)
        if first == "/" or first == "\\" or path:match("^%a:[/\\]") then
            return true
        end
    end
    return false
end

--- Checks if a path points to an existing directory.
--- @param path any The value to check
--- @return boolean True if path is an existing directory, false otherwise
local function isDir(path)
    if type(path) == "string" and path ~= "" then
        local last = path:sub(-1)
        -- lfs.attributes will error on a filename ending in '/'
        if last == "/" or last == "\\" then
            path = path:sub(1, -2)
        end
        if lfs.attributes(path, "mode") == "directory" then
            return true
        end
    end
    return false
end

--- Normalizes a path: converts backslashes to forward slashes, removes duplicate slashes,
--- resolves . and .. components, and removes trailing slashes (except for root).
--- @param path string|nil The path to normalize
--- @return string|nil Normalized path, or nil if path is nil/empty
--- @error Throws if path is not a string (when not nil/empty)
local function normalizePath(path)
    if path == nil or path == "" then
        return nil
    end
    if type(path) ~= "string" then
        error("normalizePath: path not a string: "..type(path))
    end

    -- Convert Windows-style backslashes to forward slashes
    path = path:gsub("\\", "/")
    
    local absolute = isAbsolutePath(path)

    -- Remove duplicate slashes
    path = path:gsub("//+", "/")
    
    -- Remove trailing slash, except for root path
    if path ~= "/" then
        path = path:gsub("/$", "")
    end
    
    -- Handle relative path components
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                table.remove(parts)
            else
                table.insert(parts, part)
            end
        elseif part ~= "." then
            table.insert(parts, part)
        end
    end
    
    -- Reconstruct the path
    path = table.concat(parts, "/")
    
    -- Ensure absolute paths start with "/"
    if absolute and path:sub(1, 1) ~= "/" and not path:match("^%a:/") then
        path = "/" .. path
    end
    
    return path
end

--- Joins path components into a single normalized path.
--- @param ... string Path components to join
--- @return string|nil The joined and normalized path
local function pathJoin(...)
    return normalizePath(table.concat({...}, "/"))
end

-- Computes the name of the system temporary directory
local function findSystemTempDir()
    -- Try using Lua 5.3+ os.tmpname() to get the temp directory
    local tmpname = os.tmpname()
    os.remove(tmpname)  -- Clean up the temporary file
    local tempdir = tmpname:match("^(.*)[/\\]")
    if tempdir and lfs.attributes(tempdir, "mode") == "directory" then
        return tempdir
    end

    -- Try environment variables
    local env_vars = {"TMPDIR", "TMP", "TEMP"}
    for _, var in ipairs(env_vars) do
        local path = os.getenv(var)
        if path and lfs.attributes(path, "mode") == "directory" then
            return path
        end
        path = os.getenv(var:lower())
        if path and lfs.attributes(path, "mode") == "directory" then
            return path
        end
    end

    -- Fallbacks for different OS types
    if package.config:sub(1,1) == '\\' then
        -- Windows
        return "C:\\Windows\\Temp"
    else
        -- Unix-like
        return "/tmp"
    end
end

-- Safely iterate over directory contents
local function safe_dir_iter(dir)
    local ok, iter, dir_obj, next_entry = pcall(lfs.dir, dir)
    if not ok then
        return nil, string.format("Failed to open directory %s: %s", dir, iter)
    end
    if not iter then
        -- dir_obj contains the error message in this case
        return nil, dir_obj
    end

    return function()
        local entry
        repeat
            local success, err
            success, entry, err = pcall(function() return iter(dir_obj, next_entry) end)
            next_entry = entry
            if not success then
                -- entry contains the error message
                return nil, "Error while iterating directory: " .. entry
            end
            if not entry and err then
                return nil, "Error while iterating directory: " .. err
            end
        until not entry or (entry ~= "." and entry ~= "..")
        return entry
    end
end

-- Safely get directory contents, using lfs.dir
-- On error, returns nil and the error message
local function safeDir(dir)
    if dir == nil then
        return nil, "dir is nil"
    end
    if dir == "" then
        return nil, "dir is empty-string"
    end
    if type(dir) ~= "string" then
        return nil, "dir not a string: "..type(dir)
    end
    local entries = {}
    local iter, init_err = safe_dir_iter(dir)
    
    if not iter then
        return nil, "Failed to open directory: " .. init_err
    end

    while true do
        local entry, err = iter()
        if err then
            return nil, err
        end
        if not entry then
            break
        end
        table.insert(entries, entry)
    end

    return entries
end

-- Function to get all files and sub-directories in a directory
-- Search is recursive, only if recursively is true
-- On error, returns nil and the error message
local function getFilesAndDirs(directory, recursively)
    recursively = recursively or false
    if directory == nil or directory == "" then
        return nil, "directory is nil/empty-string"
    end
    if type(directory) ~= "string" then
        return nil, "directory not a string: "..type(directory)
    end
    directory = normalizePath(directory)
    local files_set = {}
    local dirs_set = {}
    local dir_content, err = safeDir(directory)
    if not dir_content then
        return nil, err
    end
    for _,file in ipairs(dir_content) do
        if file ~= "." and file ~= ".." then
            local path = directory .. "/" .. file
            if isDir(path) then
                dirs_set[path] = true
            else
                files_set[path] = true
            end
        end
    end
    if recursively then
        for _,dir in ipairs(setToSeq(dirs_set)) do
            local new_files, new_dirs = getFilesAndDirs(dir, true)
            if not new_files then
                -- new_dirs contains the error message
                return nil, new_dirs
            end
            for _, new_file in ipairs(new_files) do
                files_set[new_file] = true
            end
            for _, new_dir in ipairs(new_dirs) do
                dirs_set[new_dir] = true
            end
        end 
    end
    local files = setToSeq(files_set)
    table.sort(files)
    local dirs = setToSeq(dirs_set)
    table.sort(dirs)
    return files, dirs
end

-- Function to check if a file has a specific extension
local function hasExtension(file, extension)
    if type(file) ~= "string" then
        error("hasExtension: file not a string: "..type(file))
    end
    if type(extension) ~= "string" then
        error("hasExtension: extension not a string: "..type(extension))
    end
    return file:match("%.(" .. extension .. ")$") ~= nil
end

-- Function takes a file name and replaces the extension
local function changeExtension(file, extension)
    if type(file) ~= "string" then
        error("changeExtension: file not a string: "..type(file))
    end
    if type(extension) ~= "string" then
        error("changeExtension: extension not a string: "..type(extension))
    end
    local idx = file:find("%.[^%.]*$")
    if idx == nil then
        return file .. "." .. extension
    end
    return file:sub(1, idx - 1) .. "." .. extension
end

--- Reads the entire contents of a file.
--- @param file_path string The path to the file to read
--- @return string|nil The file contents, or nil on error
--- @return string|nil Error message if read failed, nil on success
local function readFile(file_path)
    if type(file_path) ~= "string" then
        return nil, "file_path not a string: "..type(file_path)
    end
    local ok, file, err = pcall(io.open, file_path, "r")
    if not ok then return nil, file end
    if not file then return nil, err end
    local content = file:read("*all")
    file:close()
    return content, nil
end

--- Writes content to a file (overwrites if exists).
--- @param file_path string The path to the file to write
--- @param content string The content to write
--- @return boolean|nil True on success, nil on error
--- @return string|nil Error message if write failed, nil on success
--- @side_effect Creates or overwrites the file
local function writeFile(file_path, content)
    if type(file_path) ~= "string" then
        return nil, "file_path not a string: "..type(file_path)
    end
    if type(content) ~= "string" then
        return nil, "content not a string: "..type(content)
    end
    local success, file, err = pcall(io.open, file_path, "w")
    if not success then return nil, file end
    if not file then return nil, err end
    local ok
    ok, err = file:write(content)
    file:close()
    if not ok then return nil, err end
    return true
end

--- Safely replaces a file's content using atomic rename pattern.
--- Writes to .new file, renames original to .old, renames .new to original, removes .old.
--- @param file_path string The path to the file to replace
--- @param new_content string The new content
--- @return boolean|nil True on success, nil on error
--- @return string|nil Error message if operation failed, nil on success
--- @side_effect Creates temporary files, modifies filesystem
local function safeReplaceFile(file_path, new_content)
    if type(file_path) ~= "string" then
        return nil, "file_path not a string: "..type(file_path)
    end
    if type(new_content) ~= "string" then
        return nil, "new_content not a string: "..type(new_content)
    end
    local new_file = file_path .. ".new"
    local old_file = file_path .. ".old"
    
    -- Write new content to .new file
    local ok, err = writeFile(new_file, new_content)
    if not ok then
        return nil, string.format("Unable to write to %s: %s", new_file, err)
    end
    
    -- Rename original file to .old
    ok, err = os.rename(file_path, old_file)
    if not ok then
        os.remove(new_file)
        return nil, string.format("Unable to rename %s to %s: %s", file_path, old_file, err)
    end
    
    -- Rename .new file to original filename
    ok, err = os.rename(new_file, file_path)
    if not ok then
        os.rename(old_file, file_path)
        os.remove(new_file)
        return nil, string.format("Unable to rename %s to %s: %s", new_file, file_path, err)
    end
    
    -- Remove .old file
    ok, err = os.remove(old_file)
    if not ok then
        return nil, string.format("Unable to remove %s: %s", old_file, err)
    end
    
    return true
end

--- Converts all line endings to Unix style (\n).
--- Handles both \r\n (Windows) and \r (old Mac) line endings.
--- @param s string|nil The string to convert
--- @return string|nil The converted string, or nil if input is nil
--- @error Throws if s is not a string (when not nil)
local function unixEOL(s)
    if s == nil then
        return nil
    end
    if type(s) ~= "string" then
        error("unixEOL: s not a string: "..type(s))
    end
    return (s:gsub('\r\n?', '\n'))
end

-- Find all files in all directories, that have the desired extensions
-- Directories should not overlap, for optimal performance
-- Optionally takes a file2dir table to map files to (one) source directory
-- Optionally takes a logger, to log progress
-- Returns a list of files, and a list of errors
local function collectFiles(directories, extensions, file2dir, opt_logger)
    if type(directories) ~= "table" then
        error("collectFiles: directories not a table: "..type(directories))
    end
    if type(extensions) ~= "table" then
        error("collectFiles: extensions not a table: "..type(extensions))
    end
    if (file2dir ~= nil) and (type(file2dir) ~= "table") then
        error("collectFiles: file2dir not a table: "..type(file2dir))
    end
    local found = {}
    local errors = {}
    for _, directory in ipairs(directories) do
        -- We simply ignore nil and "", without logging an error
        if directory and directory ~= "" then
            if isDir(directory) then
                if opt_logger then
                    opt_logger:info("Checking files in directory: " .. directory)
                end
                local files, err = getFilesAndDirs(directory, true)
                if files then
                    for _, file in ipairs(files) do
                        for _, ext in ipairs(extensions) do
                            if hasExtension(file, ext) then
                                -- In case directories overlap, only output files once
                                found[file] = true
                                if file2dir then
                                    file2dir[file] = directory
                                end
                                break
                            end
                        end
                    end
                else
                    errors[#errors+1] = err
                end
            else
                errors[#errors+1] = tostring(directory) .. " is not a directory"
            end
        end
    end
    if #errors == 0 then
        errors = nil
    end
    -- Collect and sort the found files
    local result = setToSeq(found)
    table.sort(result)
    return result, errors
end

-- Returns the parent directory of a path
local function getParentPath(path)
    -- Handle root directories
    if path == nil or isRootDir(path) then
        return nil
    end
    if type(path) ~= "string" then
        error("getParentPath: path not a string: "..type(path))
    end
    local normalized = normalizePath(path)
    if normalized == nil then
        return nil
    end
    return string.match(normalized,UNIX_PARENT_DIR)
end

-- Take a file path, and split it into its "components"
local function splitPath(path)
    local normalized = normalizePath(path)
    local components = {}
    if normalized ~= nil then
        for component in normalized:gmatch("[^/\\]+") do
            components[#components+1] = component
        end
        if components[#components] == "" then
            components[#components] = nil
        end
    end
    return components
end

-- Sort files, first by shortest parent, and then alphabetically
local function sortFilesBreadthFirst(files)
    local normalized = {}
    for _, file in ipairs(files) do
        local n = normalizePath(file):lower()
        local _, d = string.gsub(n, "/", "")
        normalized[file] = {n,d}
    end
    table.sort(files, function(a, b)
        local nada = normalized[a]
        local nbdb = normalized[b]
        if nada[1] == nbdb[1] then
            return false
        end
        if nada[2] == nbdb[2] then
            return nada[1] < nbdb[1]
        end
        return nada[2] < nbdb[2]
    end)
end

local cached_system_temp_dir = nil
-- Returns the name of the system temporary directory
local function getSystemTempDir()
    if not cached_system_temp_dir then
        cached_system_temp_dir = normalizePath(findSystemTempDir())
    end
    return cached_system_temp_dir
end

-- Recursively deletes all contents of a directory, but keeps the directory itself
-- Optionally takes a logger, to log progress
local emptyDirRef
local function emptyDir(dir, opt_logger)
    if not isDir(dir) then
        return nil, string.format("Not a directory: %s", dir)
    end
    local normalized_dir = normalizePath(dir)
    if normalized_dir == nil then
        return nil, string.format("Bad directory: %s", dir)
    end

    local files, err = safeDir(normalized_dir)
    if not files then
        return nil, string.format("Failed to open directory %s: %s", dir, err)
    end

    local ok, attr
    for _,file in ipairs(files) do
        if file ~= "." and file ~= ".." then
            local file_path = normalized_dir .. '/' .. file
            attr, err = lfs.attributes(file_path)

            if not attr then
                return nil, string.format("Failed to get attributes for %s: %s",
                    file_path, err)
            end

            if attr.mode == 'file' then
                ok, err = os.remove(file_path)
                if not ok then
                    return nil, string.format("Unable to remove file %s: %s",
                        file_path, err)
                end
                if opt_logger then
                    opt_logger:info("Removed file: " .. file_path)
                end
            elseif attr.mode == 'directory' then
                -- First empty the subdirectory
                ok, err = emptyDirRef(file_path, opt_logger)
                if not ok then
                    return nil, err
                end
                -- Then remove the empty subdirectory
                ok, err = lfs.rmdir(file_path)
                if not ok then
                    return nil, string.format("Unable to remove directory %s: %s", file_path, err)
                end
                if opt_logger then
                    opt_logger:info("Removed directory: " .. file_path)
                end
            else
                if opt_logger then
                    opt_logger:warn(string.format("Skipping unsupported file type %s: %s",
                        attr.mode, file_path))
                end
            end
        end
    end

    return true
end
emptyDirRef = emptyDir

-- Deletes a temporary directory recursive
-- Optionally takes a logger, to log progress
local deletedirRef
local function deleteTempDir(dir, opt_logger)
    if not isDir(dir) then
        return nil, string.format("Not a directory: %s", dir)
    end
    local td = getSystemTempDir()
    local normalized_dir = normalizePath(dir)
    if normalized_dir == nil then
        return nil, string.format("Bad directory: %s", dir)
    end
    if normalized_dir:sub(1, #td) ~= td then
        return nil, string.format("Not a TEMP directory: %s", dir)
    end

    local files, err = safeDir(normalized_dir)
    if not files then
        return nil, string.format("Failed to open directory %s: %s", dir, err)
    end

    local ok, attr
    for _,file in ipairs(files) do
        if file ~= "." and file ~= ".." then
            local file_path = normalized_dir .. '/' .. file
            attr, err = lfs.attributes(file_path)
            
            if not attr then
                return nil, string.format("Failed to get attributes for %s: %s",
                    file_path, err)
            end

            if attr.mode == 'file' then
                ok, err = os.remove(file_path)
                if not ok then
                    return nil, string.format("Unable to remove file %s: %s",
                        file_path, err)
                end
                if opt_logger then
                    opt_logger:info("Removed file: " .. file_path)
                end
            elseif attr.mode == 'directory' then
                ok, err = deletedirRef(file_path, opt_logger)
                if not ok then
                    return nil, err
                end
            else
                if opt_logger then
                    opt_logger:warn(string.format("Skipping unsupported file type %s: %s",
                        attr.mode, file_path))
                end
            end
        end
    end

    ok, err = lfs.rmdir(normalized_dir)
    if not ok then
        return nil, string.format("Unable to remove directory %s: %s", dir, err)
    end
    if opt_logger then
        opt_logger:info("Removed directory: " .. dir)
    end

    return true
end
deletedirRef = deleteTempDir

-- Returns true if a path looks like a Windows path (has backslashes or drive letter)
local function isWindowsPath(path)
    if not path or path == "" then
        return false
    end
    -- Check for backslashes or drive letter (e.g., "C:" or "D:")
    return path:find("\\") ~= nil or path:match("^%a:") ~= nil
end

-- Returns true, if both path represent the same file/directory
local function isSamePath(path1, path2)
    local empty1 = path1 == nil or path1 == ""
    local empty2 = path2 == nil or path2 == ""
    if empty1 and empty2 then
        return true
    end
    if empty1 or empty2 then
        return false
    end
    local p1 = normalizePath(path1) or ""
    local p2 = normalizePath(path2) or ""
    -- Use case-insensitive comparison if either path looks like a Windows path,
    -- or if we're running on Windows. This ensures Windows paths are compared
    -- correctly even when running tests on Linux.
    local isWindows = package.config:sub(1,1) == '\\'
    if isWindows or isWindowsPath(path1) or isWindowsPath(path2) then
        return p1:lower() == p2:lower()
    else
        return p1 == p2
    end
end

-- Convert a normalized path to an OS-specific path
local function toOSPath(path)
    if path == nil or path == "" then
        return nil
    end
    if type(path) ~= "string" then
        error("toOSPath: path not a string: "..type(path))
    end
    
    -- Check if we're on Windows
    if package.config:sub(1,1) == '\\' then
        -- Convert forward slashes to backslashes for Windows
        return (path:gsub("/", "\\"))
    end
    
    -- On Unix-like systems, normalized paths are already native
    return path
end

--- Creates a directory, including parent directories if needed (like mkdir -p).
--- @param path string The directory path to create
--- @return boolean|nil True on success (or if directory already exists), nil on error
--- @return string|nil Error message if creation failed, nil on success
--- @side_effect Creates directories on the filesystem
local function mkdir(path)
    if type(path) ~= "string" then
        return nil, "path not a string: "..type(path)
    end
    if path == "" then
        return nil, "path is empty"
    end

    -- Normalize the path for consistent handling
    path = normalizePath(path)

    if isDir(path) then
        -- directory already exists
        return true
    end

    -- Check if parent directory exists, create it recursively if not
    local parent = getParentPath(path)
    if parent ~= nil and not isDir(parent) then
        local ok, err = mkdir(parent)
        if not ok then
            return nil, err
        end
    end

    -- Convert to OS-specific path for lfs.mkdir
    local os_path = toOSPath(path)
    local success, created, err = pcall(lfs.mkdir, os_path)
    if not success then return nil, created end
    if not created then return nil, err end
    return true
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    changeExtension = changeExtension,
    collectFiles = collectFiles,
    deleteTempDir = deleteTempDir,
    emptyDir = emptyDir,
    getFilesAndDirs = getFilesAndDirs,
    getParentPath = getParentPath,
    getSystemTempDir = getSystemTempDir,
    getVersion = getVersion,
    hasExtension = hasExtension,
    isAbsolutePath = isAbsolutePath,
    isDir = isDir,
    isRootDir = isRootDir,
    isSamePath = isSamePath,
    mkdir = mkdir,
    normalizePath = normalizePath,
    pathJoin = pathJoin,
    readFile = readFile,
    safeDir = safeDir,
    safeReplaceFile = safeReplaceFile,
    sortFilesBreadthFirst = sortFilesBreadthFirst,
    splitPath = splitPath,
    toOSPath = toOSPath,
    unixEOL = unixEOL,
    writeFile = writeFile,
}

-- Enables the module to be called as a function
local function apiCall(_, operation, ...)
    if operation == "version" then
        return VERSION
    elseif API[operation] then
        return API[operation](...)
    else
        error("Unknown operation: " .. tostring(operation), 2)
    end
end

return readOnly(API, {__tostring = apiToString, __call = apiCall, __type = NAME})
