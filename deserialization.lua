-- Module name
local NAME = "deserialization"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 9, 0)

-- Dependencies
local read_only = require("read_only")
local readOnly = read_only.readOnly
local dkjson = require("dkjson")

-- lua-MessagePack
local mpk = require("MessagePack")
-- Modify MessagePack global configuration for sparse arrays
mpk.set_array('with_hole')

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

--- Deserializes a Lua literal string back to a Lua value.
--- Uses Lua's load() with a sandboxed environment for safety.
--- @param s string The serialized Lua literal string
--- @return any The deserialized Lua value
--- @return string|nil Error message if deserialization failed
local function deserialize(s)
    if s == nil then
        return nil, nil
    end
    if type(s) ~= "string" then
        return nil, "deserialize: argument not a string: " .. type(s)
    end
    if s == "" then
        return nil, nil
    end

    -- Handle literal nil
    if s == "nil" then
        return nil, nil
    end

    -- Create a sandboxed environment with only math constants needed for special values
    local sandbox = {
        math = { huge = math.huge }
    }

    -- Wrap the string in a return statement so we can get the value
    local code = "return " .. s
    local fn, err = load(code, "deserialize", "t", sandbox)
    if not fn then
        return nil, "Failed to parse Lua: " .. tostring(err)
    end

    local ok, result = pcall(fn)
    if not ok then
        return nil, "Failed to execute Lua: " .. tostring(result)
    end

    return result, nil
end

--- Deserializes a typed JSON string back to a Lua value.
--- Handles {"int":"123"} and {"float":"nan"/"inf"/"-inf"} type wrappers.
--- Tables are encoded as: [size, elem1, ..., elemN, [key1,val1], ...]
--- @param s string The serialized typed JSON string
--- @return any The deserialized Lua value
--- @return string|nil Error message if deserialization failed
local function deserializeJSON(s)
    if s == nil then
        return nil, nil
    end
    if type(s) ~= "string" then
        return nil, "deserializeJSON: argument not a string: " .. type(s)
    end
    if s == "" then
        return nil, nil
    end

    -- Parse JSON
    local parsed, _pos, err = dkjson.decode(s)
    if err then
        return nil, "Failed to parse JSON: " .. tostring(err)
    end

    -- Recursive function to handle type wrappers and table encoding
    local processValue
    processValue = function(v)
        if v == nil then
            return nil, nil
        end

        local t = type(v)
        if t ~= "table" then
            return v, nil
        end

        -- Check for type wrappers: {"int":"123"} or {"float":"nan"}
        if v.int ~= nil then
            local num = tonumber(v.int)
            if num == nil then
                return nil, "Failed to parse int: " .. tostring(v.int)
            end
            if math.type(num) == "float" then
                -- Force to integer
                num = math.floor(num)
            end
            return num, nil
        end
        if v.float ~= nil then
            local f = v.float
            if f == "nan" then
                return 0/0, nil
            elseif f == "inf" then
                return math.huge, nil
            elseif f == "-inf" then
                return -math.huge, nil
            end
            local num = tonumber(f)
            if num == nil then
                return nil, "Failed to parse float: " .. tostring(v.float)
            end
            return num, nil
        end

        -- Check if this is our table encoding: [size, elem1, ..., elemN, [key,val], ...]
        if #v > 0 then
            local size = v[1]
            if type(size) == "number" then
                local result = {}
                -- Process sequence elements (indices 2 to size+1)
                for i = 2, size + 1 do
                    local elem = v[i]
                    result[i - 1], err = processValue(elem)
                    if err then
                        return nil, err
                    end
                end
                -- Process key-value pairs (remaining elements)
                for i = size + 2, #v do
                    local kv = v[i]
                    if type(kv) == "table" and #kv == 2 then
                        local key, err = processValue(kv[1])
                        if err then
                            return nil, err
                        end
                        local val, err = processValue(kv[2])
                        if err then
                            return nil, err
                        end
                        result[key] = val
                    else
                        return nil, "Bad JSON format: expected key-value pair, " .. tostring(kv)
                    end
                end
                return result, nil
            end
        end

        -- Regular table (shouldn't happen in our format, but handle it)
        local result = {}
        for k, val in pairs(v) do
            local key, err = processValue(k)
            if err then
                return nil, err
            end
            result[key], err = processValue(val)
            if err then
                return nil, err
            end
        end
        return result, nil
    end

    return processValue(parsed)
end

--- Deserializes a natural JSON string back to a Lua value.
--- Handles "NAN", "INF", "-INF" strings as special float values.
--- Note: integers cannot be distinguished from floats in natural JSON.
--- @param s string The serialized natural JSON string
--- @return any The deserialized Lua value
--- @return string|nil Error message if deserialization failed
local function deserializeNaturalJSON(s)
    if s == nil then
        return nil, nil
    end
    if type(s) ~= "string" then
        return nil, "deserializeNaturalJSON: argument not a string: " .. type(s)
    end
    if s == "" then
        return nil, nil
    end

    -- Parse JSON
    local parsed, _pos, err = dkjson.decode(s)
    if err then
        return nil, "Failed to parse JSON: " .. tostring(err)
    end

    -- Recursive function to handle special string values
    local processValue
    processValue = function(v)
        if v == nil then
            return nil, nil
        end

        local t = type(v)
        if t == "string" then
            -- Check for special float values
            if v == "NAN" then
                return 0/0, nil
            elseif v == "INF" then
                return math.huge, nil
            elseif v == "-INF" then
                return -math.huge, nil
            elseif v == "<FUNCTION>" then
                return nil, nil  -- Functions can't be deserialized
            end
            return v
        end
        if t ~= "table" then
            return v, nil
        end

        -- Process table
        local result = {}
        for k, val in pairs(v) do
            -- Natural JSON uses string keys for objects
            local key = k
            if type(k) == "string" then
                -- Try to convert numeric string keys back to numbers
                local numKey = tonumber(k)
                if numKey then
                    key = numKey
                elseif k == "true" then
                    key = true
                elseif k == "false" then
                    key = false
                elseif k == "NAN" then
                    key = 0/0
                elseif k == "INF" then
                    key = math.huge
                elseif k == "-INF" then
                    key = -math.huge
                end
            end
            result[key], err = processValue(val)
            if err then
                return nil, err
            end
        end
        return result, nil
    end

    return processValue(parsed)
end

-- XML parsing helpers
local function parseXMLContent(xml, pos)
    -- Skip whitespace
    pos = xml:match("^%s*()", pos)

    if pos > #xml then
        return nil, pos, "Unexpected end of XML"
    end

    -- Check for start of tag
    if xml:sub(pos, pos) ~= "<" then
        return nil, pos, "Expected '<' at position " .. pos
    end

    -- Get tag name
    local tagEnd = xml:find("[>/%s]", pos + 1)
    if not tagEnd then
        return nil, pos, "Malformed tag at position " .. pos
    end
    local tagName = xml:sub(pos + 1, tagEnd - 1)

    -- Self-closing tag
    if xml:sub(tagEnd, tagEnd + 1) == "/>" then
        pos = tagEnd + 2
        if tagName == "null" then
            return nil, pos, nil
        elseif tagName == "true" then
            return true, pos, nil
        elseif tagName == "false" then
            return false, pos, nil
        elseif tagName == "string" then
            return "", pos, nil
        elseif tagName == "function" then
            return nil, pos, nil  -- Functions can't be deserialized
        else
            return nil, pos, "Unknown self-closing tag: " .. tagName
        end
    end

    -- Find end of opening tag
    local closeStart = xml:find(">", pos)
    if not closeStart then
        return nil, pos, "Unclosed tag at position " .. pos
    end
    pos = closeStart + 1

    -- Find closing tag
    local closingTag = "</" .. tagName .. ">"

    if tagName == "null" then
        local endPos = xml:find(closingTag, pos, true)
        if not endPos then
            return nil, pos, "Missing closing tag for null"
        end
        return nil, endPos + #closingTag, nil

    elseif tagName == "true" then
        local endPos = xml:find(closingTag, pos, true)
        if not endPos then
            return nil, pos, "Missing closing tag for true"
        end
        return true, endPos + #closingTag, nil

    elseif tagName == "false" then
        local endPos = xml:find(closingTag, pos, true)
        if not endPos then
            return nil, pos, "Missing closing tag for false"
        end
        return false, endPos + #closingTag, nil

    elseif tagName == "integer" then
        local endPos = xml:find(closingTag, pos, true)
        if not endPos then
            return nil, pos, "Missing closing tag for integer"
        end
        local content = xml:sub(pos, endPos - 1)
        local num = tonumber(content)
        if num and math.type(num) == "float" then
            num = math.floor(num)
        end
        return num, endPos + #closingTag, nil

    elseif tagName == "number" then
        local endPos = xml:find(closingTag, pos, true)
        if not endPos then
            return nil, pos, "Missing closing tag for number"
        end
        local content = xml:sub(pos, endPos - 1)
        if content == "nan" then
            return 0/0, endPos + #closingTag, nil
        elseif content == "inf" then
            return math.huge, endPos + #closingTag, nil
        elseif content == "-inf" then
            return -math.huge, endPos + #closingTag, nil
        end
        return tonumber(content), endPos + #closingTag, nil

    elseif tagName == "string" then
        local endPos = xml:find(closingTag, pos, true)
        if not endPos then
            return nil, pos, "Missing closing tag for string"
        end
        local content = xml:sub(pos, endPos - 1)
        -- Unescape XML entities
        content = content:gsub("&apos;", "'")
                        :gsub("&quot;", '"')
                        :gsub("&gt;", ">")
                        :gsub("&lt;", "<")
                        :gsub("&amp;", "&")
        return content, endPos + #closingTag, nil

    elseif tagName == "function" then
        local endPos = xml:find(closingTag, pos, true)
        if not endPos then
            return nil, pos, "Missing closing tag for function"
        end
        return nil, endPos + #closingTag, nil  -- Functions can't be deserialized

    elseif tagName == "table" then
        local result = {}
        local seqIdx = 1

        while true do
            -- Skip whitespace
            pos = xml:match("^%s*()", pos)

            -- Check for closing tag
            if xml:sub(pos, pos + #closingTag - 1) == closingTag then
                return result, pos + #closingTag, nil
            end

            -- Check for key_value tag
            if xml:sub(pos, pos + 10) == "<key_value>" then
                pos = pos + 11
                -- Parse key
                local key, err
                key, pos, err = parseXMLContent(xml, pos)
                if err then
                    return nil, pos, err
                end
                -- Parse value
                local value
                value, pos, err = parseXMLContent(xml, pos)
                if err then
                    return nil, pos, err
                end
                -- Find closing </key_value>
                pos = xml:match("^%s*()", pos)
                if xml:sub(pos, pos + 11) ~= "</key_value>" then
                    return nil, pos, "Expected </key_value>"
                end
                pos = pos + 12
                result[key] = value
            else
                -- Sequence element
                local value, err
                value, pos, err = parseXMLContent(xml, pos)
                if err then
                    return nil, pos, err
                end
                result[seqIdx] = value
                seqIdx = seqIdx + 1
            end
        end
    else
        return nil, pos, "Unknown tag: " .. tagName
    end
end

--- Deserializes an XML string back to a Lua value.
--- Handles our specific XML format with <table>, <integer>, <string>, etc. tags.
--- @param s string The serialized XML string
--- @return any The deserialized Lua value
--- @return number|nil The position after parsing (for streaming), or nil on error
--- @return string|nil Error message if deserialization failed
local function deserializeXML(s)
    if s == nil then
        return nil, nil, nil
    end
    if type(s) ~= "string" then
        return nil, nil, "deserializeXML: argument not a string: " .. type(s)
    end
    if s == "" then
        return nil, nil, nil
    end

    local value, pos, err = parseXMLContent(s, 1)
    return value, pos, err
end

--- Deserializes a MessagePack binary string back to a Lua value.
--- Wrapper around MessagePack.unpack().
--- @param s string The binary MessagePack data
--- @return any The deserialized Lua value
--- @return string|nil Error message if deserialization failed
local function deserializeMessagePack(s)
    if s == nil then
        return nil, nil
    end
    if type(s) ~= "string" then
        return nil, "deserializeMessagePack: argument not a string: " .. type(s)
    end
    if s == "" then
        return nil, nil
    end

    local ok, result = pcall(mpk.unpack, s)
    if not ok then
        return nil, "Failed to unpack MessagePack: " .. tostring(result)
    end

    return result, nil
end

--- Deserializes an SQL BLOB literal back to binary data.
--- Converts X'...' hex format to binary string.
--- @param s string The SQL BLOB literal (X'...' format)
--- @return string|nil The binary data, or nil on error
--- @return string|nil Error message if deserialization failed
local function deserializeSQLBlob(s)
    if s == nil then
        return nil, nil
    end
    if type(s) ~= "string" then
        return nil, "deserializeSQLBlob: argument not a string: " .. type(s)
    end

    -- Check for X'...' format
    if not s:match("^X'.*'$") then
        return nil, "Invalid SQL BLOB format: expected X'...'"
    end

    -- Extract hex string
    local hex = s:sub(3, -2)

    -- Convert hex to binary
    local binary = hex:gsub("..", function(h)
        return string.char(tonumber(h, 16))
    end)

    return binary, nil
end

--- Deserializes an SQL BLOB containing MessagePack data.
--- Combines deserializeSQLBlob and deserializeMessagePack.
--- @param s string The SQL BLOB literal containing MessagePack data
--- @return any The deserialized Lua value
--- @return string|nil Error message if deserialization failed
local function deserializeMessagePackSQLBlob(s)
    local binary, err = deserializeSQLBlob(s)
    if err then
        return nil, err
    end
    return deserializeMessagePack(binary)
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    deserialize = deserialize,
    deserializeJSON = deserializeJSON,
    deserializeMessagePack = deserializeMessagePack,
    deserializeMessagePackSQLBlob = deserializeMessagePackSQLBlob,
    deserializeNaturalJSON = deserializeNaturalJSON,
    deserializeSQLBlob = deserializeSQLBlob,
    deserializeXML = deserializeXML,
    getVersion = getVersion,
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
