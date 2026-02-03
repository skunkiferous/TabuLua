#!/usr/bin/env lua

-- Inspired by Cog : https://nedbatchelder.com/code/cog/

-- Module name
local NAME = "lua_cog"

-- Module logger
local logger = require( "named_logger").getLogger(NAME)

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 5, 0)

-- Returns the module version
local function getVersion()
    return tostring(VERSION)
end

local sandbox = require("sandbox")

local read_only = require("read_only")
local readOnly = read_only.readOnly
local string_utils = require("string_utils")
local split = string_utils.split

local file_util = require("file_util")
local readFile = file_util.readFile
local writeFile = file_util.writeFile
local unixEOL = file_util.unixEOL
local isSamePath = file_util.isSamePath

-- This module implements a functionality similar to Cog: https://nedbatchelder.com/code/cog/
-- Basically, it scans text files for a "comment pattern" and executes a code block when it finds it,
-- replacing part of the "comment block" with the output of the code block. The "comment block" is
-- built in 5 parts. The "idea" is that whenever required, you run this on all your (text) files,
-- and it will replace (update) the parts of the files that need to be replaced. It's basically a
-- very generic "template engine", that can be used inside any file that uses one of the 3
-- "comment styles" (-- or ## or //) The code block is executed in a sandbox, and the output of the
-- code block is inserted into the file. The code can make use of many functions, like those from the
-- predicates module, that have been added to the sandbox environment. User code in "code libraries"
-- can also be (re)used.

-- First, the comment "start marker". It can be one of those 3 strings:
-- 1) ---[[[
-- 2) ###[[[
-- 3) ///[[[
-- Then comes the Lua code block, to be executed. Each line must be prefixed with the appropriate
-- comment pattern. It look like one of those 3 examples, and can be spread over multiple lines:
-- 1) ---return "--Hello, world!"
-- 2) ###return "--Hello, world!"
-- 3) ///return "--Hello, world!"
-- Then comes the comment "code block end marker". It can be one of those 3 strings:
-- 1) ---]]]
-- 2) ###]]]
-- 3) ///]]]
-- Then comes the block of text that gets replaced by the output of the code block. It could be anything.
-- And finally comes the comment "replaced block end marker". It can be one of those 3 strings:
-- 1) ---[[[end]]]
-- 2) ###[[end]]]
-- 3) ///[[[end]]]

-- Here we can test the script on itself. "---XXXX", "###XXXX", and "///XXXX" will be replaced with "--Hello, world!"

---[[[
---return "--Hello, world!"
---]]]
---XXXX
---[[[end]]]

--[=[
###[[[
###return "--Hello, world!"
###]]]
###XXXX
###[[[end]]]
--]=]

--[=[
///[[[
///return "--Hello, world!"
///]]]
///XXXX
///[[[end]]]
--]=]

-- processLines() takes a sequence of lines (without EOL), process them using the Cog logic, and
-- returns the processed lines. The code blocks are executed in a sandbox, to be safer. Any error
-- is "recorded" in the errors table. "env" is used to execute the code block. It could, for example
-- contain a copy of all already processed files.
local function processLines(lines, env, errors)
    local inCodeBlock = false
    local inOutputBlock = false
    local codeBuffer = ""
    local outputBuffer = {}
    local lineNo = 0

    for _,line in ipairs(lines) do
        lineNo = lineNo + 1
        -- match() is better than find "plain" because match() will only search at the start if we
        --use ^
        local isEnd = line:match("^%-%-%-%[%[%[end%]%]%]") or line:match("^%#%#%#%[%[%[end%]%]%]")
            or line:match("^%/%/%/%[%[%[end%]%]%]")
        if isEnd or not inOutputBlock then
            outputBuffer[#outputBuffer+1] = line
        end
        if isEnd then
            if not (not inCodeBlock and inOutputBlock) then
                errors[#errors+1] = "Code blocks cannot be nested(1) at line " .. lineNo
                    .. "! Aborting!"
                return nil
            end
            inOutputBlock = false
        elseif line:match("^%-%-%-%[%[%[") or line:match("^%#%#%#%[%[%[") or
             line:match("^%/%/%/%[%[%[") then
            if inCodeBlock or inOutputBlock then
                errors[#errors+1] = "Code blocks cannot be nested(2) at line " .. lineNo
                    .. "! Aborting!"
                return nil
            end
            inCodeBlock = true
        elseif line:match("^%-%-%-%]%]%]") or line:match("^%#%#%#%]%]%]")
             or line:match("^%/%/%/%]%]%]") then
            if not (inCodeBlock and not inOutputBlock) then
                errors[#errors+1] = "Code blocks cannot be nested(3) at line " .. lineNo
                    .. "! Aborting!"
                return nil
            end
            inCodeBlock = false
            inOutputBlock = true
            
            -- Execute the code block, using th provided environment, "env"
            local opt = {quota = 10000, env = env or {}}
            local success, protected_func = pcall(sandbox.protect, codeBuffer, opt)
            local result
            if success then
                -- Second pcall to execute the protected function
                success, result = pcall(protected_func)
            else
                errors[#errors+1] = "Error executing code block at line " .. lineNo .. ": "
                    .. tostring(result)
            end
            if success then
                outputBuffer[#outputBuffer+1] =  tostring(result)
            else
                errors[#errors+1] = "Error executing code block at line " .. lineNo .. ": "
                    .. tostring(result)
            end
            codeBuffer = ""
        elseif inCodeBlock then
            if line:match("^%-%-%-") or line:match("^%#%#%#") or line:match("^%/%/%/") then
                codeBuffer = codeBuffer .. line:sub(4) .. "\n"
            else
                errors[#errors+1] = "Error parsing code block at line " .. lineNo
                    .. ": line must start with \"---\". or \"###\" or \"///\". Aborting!"
            end
        end
    end

    return outputBuffer
end

-- Processes the content of a file, using the Cog logic. Returns nil on error. All error messages
-- are stored in the "errors" table. "env" is used to execute the code block.
local function processContent(content, env, errors)
    return processLines(split(unixEOL(content), '\n'), env, errors)
end

-- Processes a file, using the Cog logic. Returns nil on error. All error messages are stored in
-- the "errors" table. "env" is used to execute the code block.
local function processFile(fileName, env, errors)
    local content, err = readFile(fileName)
    if content == nil then
        errors[#errors+1] = err
        return nil
    end
    return processContent(content, env, errors)
end

-- Reads the inputFile, processes it using Cog, and writes the result to outputFile. Returns false
-- on error, otherwise true. All error messages are stored in the "errors" table. "env" is used
-- to execute the code block.
local function rewriteFile(inputFile, outputFile, env, errors)
    if isSamePath(inputFile, outputFile) then
        errors[#errors+1] = "<input_file> and <output_file> must be different! ".. inputFile
        return false
    end
    local outputBuffer = processFile(inputFile, env, errors)
    if not outputBuffer then
        return false
    end

    local ok, err = writeFile(outputFile, table.concat(outputBuffer, "\n"))
    if not ok then
        errors[#errors+1] = err
        return false
    end
    return true
end

-- Returns true, if the *string* content needs processing using Cog.
local function needsCog(content)
    -- The [[[end]]] tag can never be on the first line, so we match with \n instead of ^
    return (content:match("\n%-%-%-%[%[%[end%]%]%]") or content:match("\n%#%#%#%[%[%[end%]%]%]")
        or content:match("\n%/%/%/%[%[%[end%]%]%]")) ~= nil
end

-- Pure function to process content with COG.
-- Returns: processed_content, error_message
-- If content doesn't need COG processing, returns the original content with nil error.
-- If processing fails, returns nil and an error message.
local function tryProcessContent(content, cog_env)
    if not needsCog(content) then
        return content, nil
    end

    local errors = {}
    local lines = processContent(content, cog_env, errors)

    if #errors > 0 then
        return nil, "Problems with COG processing: " .. table.concat(errors, ", ")
    end

    if not lines then
        return nil, "COG processing failed"
    end

    return table.concat(lines, "\n"), nil
end

-- Process content with COG, logging progress and reporting errors via badVal.
-- Returns the processed content, or the original content if processing fails.
local function processContentBV(file_name, content, cog_env, badVal)
    if needsCog(content) then
        logger:info("Processing file " .. file_name .. " with COG")
    end

    local result, err = tryProcessContent(content, cog_env)

    if err then
        badVal(nil, err)
        return content
    end

    return result
end

-- Check if we are run directly, or loaded as a Lua module
if not pcall(debug.getlocal, 4, 1) then
    -- Main execution
    if #arg < 2 or #arg > 2 then
        print("Usage: lua lua_cog.lua <input_file> <output_file>")
        os.exit(false, true)
    end
    
    local inputFile = arg[1]
    local outputFile = arg[2]
    local errors = {}
    local ok = rewriteFile(inputFile, outputFile, {}, errors)
    for _, err in ipairs(errors) do
        logger:error(err)
    end
    if ok then
        logger:info("Processing complete. Output written to " .. outputFile)
    end
else
    -- Provides a tostring() function for the API
    local function apiToString()
        return NAME .. " version " .. tostring(VERSION)
    end
    
    -- The public, versioned, API of this module
    local API = {
        getVersion=getVersion,
        needsCog=needsCog,
        processContent=processContent,
        processContentBV=processContentBV,
        processFile=processFile,
        processLines=processLines,
        rewriteFile=rewriteFile,
        tryProcessContent=tryProcessContent,
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
end
