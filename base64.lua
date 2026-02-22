-- Module name
local NAME = "base64"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 10, 0)

-- Dependencies
local read_only = require("read_only")
local readOnly = read_only.readOnly

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.5.3")
local function getVersion()
    return tostring(VERSION)
end

-- Standard Base64 alphabet (RFC 4648 §4)
local ENCODE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Build decode lookup table
local DECODE = {}
for i = 1, 64 do
    DECODE[ENCODE:byte(i)] = i - 1
end
DECODE[string.byte("=")] = 0 -- padding

--- Encodes a binary string to base64.
--- @param data string The binary data to encode
--- @return string The base64-encoded string with '=' padding
local function encode(data)
    if data == nil or data == "" then
        return ""
    end
    local result = {}
    local len = #data
    for i = 1, len, 3 do
        local b1 = data:byte(i)
        local b2 = data:byte(i + 1) or 0
        local b3 = data:byte(i + 2) or 0
        local n = b1 * 65536 + b2 * 256 + b3

        result[#result + 1] = ENCODE:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
        result[#result + 1] = ENCODE:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)

        if i + 1 <= len then
            result[#result + 1] = ENCODE:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
        else
            result[#result + 1] = "="
        end
        if i + 2 <= len then
            result[#result + 1] = ENCODE:sub(n % 64 + 1, n % 64 + 1)
        else
            result[#result + 1] = "="
        end
    end
    return table.concat(result)
end

--- Decodes a base64 string to binary data.
--- @param data string The base64-encoded string
--- @return string|nil The decoded binary data, or nil on invalid input
--- @return string|nil Error message if decoding failed
local function decode(data)
    if data == nil or data == "" then
        return ""
    end
    if type(data) ~= "string" then
        return nil, "base64.decode: argument not a string"
    end
    if #data % 4 ~= 0 then
        return nil, "base64.decode: invalid length (must be multiple of 4)"
    end
    local result = {}
    for i = 1, #data, 4 do
        local c1, c2, c3, c4 = data:byte(i, i + 3)
        local d1 = DECODE[c1]
        local d2 = DECODE[c2]
        local d3 = DECODE[c3]
        local d4 = DECODE[c4]
        if not (d1 and d2 and d3 and d4) then
            return nil, "base64.decode: invalid character at position " .. i
        end
        local n = d1 * 262144 + d2 * 4096 + d3 * 64 + d4
        result[#result + 1] = string.char(math.floor(n / 65536) % 256)
        if data:sub(i + 2, i + 2) ~= "=" then
            result[#result + 1] = string.char(math.floor(n / 256) % 256)
        end
        if data:sub(i + 3, i + 3) ~= "=" then
            result[#result + 1] = string.char(n % 256)
        end
    end
    return table.concat(result)
end

--- Validates whether a string is valid base64 encoding.
--- @param str string The string to validate
--- @return boolean True if the string is valid base64
local function isValid(str)
    if type(str) ~= "string" then
        return false
    end
    if str == "" then
        return true
    end
    if #str % 4 ~= 0 then
        return false
    end
    -- Check all characters are valid base64
    if str:find("[^A-Za-z0-9+/=]") then
        return false
    end
    -- Check padding: only at the end, at most 2 '=' characters
    local pad_start = str:find("=")
    if pad_start then
        local padding = str:sub(pad_start)
        if padding ~= "=" and padding ~= "==" then
            return false
        end
        -- Padding must be at the end
        if pad_start + #padding - 1 ~= #str then
            return false
        end
    end
    return true
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    decode=decode,
    encode=encode,
    getVersion=getVersion,
    isValid=isValid,
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
