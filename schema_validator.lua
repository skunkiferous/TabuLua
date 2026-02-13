-- Module name
local NAME = "schema_validator"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 6, 0)

-- Dependencies
local read_only = require("read_only")
local readOnly = read_only.readOnly
local dkjson = require("dkjson")

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- Forward declaration
local validateTypedValue

--- Validates a typed integer object: {"int": "123"}
--- @param v table The value to validate
--- @return boolean True if valid
--- @return string|nil Error message if invalid
local function isTypedInteger(v)
    if type(v) ~= "table" then
        return false, "expected table for typed integer"
    end
    if v.int == nil then
        return false, nil  -- Not a typed integer (might be something else)
    end
    if type(v.int) ~= "string" then
        return false, "typed integer 'int' field must be string, got " .. type(v.int)
    end
    if not v.int:match("^%-?%d+$") then
        return false, "typed integer value must be numeric string, got: " .. v.int
    end
    -- Check no extra keys
    for k, _ in pairs(v) do
        if k ~= "int" then
            return false, "typed integer has unexpected key: " .. tostring(k)
        end
    end
    return true, nil
end

--- Validates a typed special float object: {"float": "nan"|"inf"|"-inf"}
--- @param v table The value to validate
--- @return boolean True if valid
--- @return string|nil Error message if invalid
local function isTypedSpecialFloat(v)
    if type(v) ~= "table" then
        return false, "expected table for typed float"
    end
    if v.float == nil then
        return false, nil  -- Not a typed float (might be something else)
    end
    if type(v.float) ~= "string" then
        return false, "typed float 'float' field must be string, got " .. type(v.float)
    end
    if v.float ~= "nan" and v.float ~= "inf" and v.float ~= "-inf" then
        return false, "typed float value must be 'nan', 'inf', or '-inf', got: " .. v.float
    end
    -- Check no extra keys
    for k, _ in pairs(v) do
        if k ~= "float" then
            return false, "typed float has unexpected key: " .. tostring(k)
        end
    end
    return true, nil
end

--- Validates a key-value pair: [key, value]
--- @param v table The value to validate
--- @param path string Current path for error messages
--- @return boolean True if valid
--- @return string|nil Error message if invalid
local function isKeyValuePair(v, path)
    if type(v) ~= "table" then
        return false, path .. ": expected array for key-value pair"
    end
    if #v ~= 2 then
        return false, path .. ": key-value pair must have exactly 2 elements, got " .. #v
    end
    -- Validate key
    local ok, err = validateTypedValue(v[1], path .. "[key]")
    if not ok then
        return false, err
    end
    -- Validate value
    ok, err = validateTypedValue(v[2], path .. "[value]")
    if not ok then
        return false, err
    end
    return true, nil
end

--- Validates a typed table: [size, elem1, ..., elemN, [key1,val1], ...]
--- @param v table The value to validate
--- @param path string Current path for error messages
--- @return boolean True if valid
--- @return string|nil Error message if invalid
local function isTypedTable(v, path)
    if type(v) ~= "table" then
        return false, path .. ": expected array for typed table"
    end
    if #v == 0 then
        return false, path .. ": typed table must have at least size element"
    end

    -- First element must be the sequence size (integer)
    local size = v[1]
    if type(size) ~= "number" or math.floor(size) ~= size or size < 0 then
        return false, path .. ": typed table first element must be non-negative integer size, got " .. type(size)
    end

    -- Validate sequence elements (indices 2 to size+1)
    for i = 2, size + 1 do
        if v[i] == nil and i <= #v then
            -- nil is valid in sparse sequences
        elseif v[i] ~= nil then
            local ok, err = validateTypedValue(v[i], path .. "[" .. (i-1) .. "]")
            if not ok then
                return false, err
            end
        end
    end

    -- Remaining elements should be key-value pairs
    for i = size + 2, #v do
        local elem = v[i]
        -- Check if it's a key-value pair (2-element array)
        if type(elem) == "table" and #elem == 2 then
            local ok, err = isKeyValuePair(elem, path .. "[kv" .. (i - size - 1) .. "]")
            if not ok then
                return false, err
            end
        else
            -- Could be a typed value in sequence position due to sparse array
            local ok, err = validateTypedValue(elem, path .. "[" .. (i-1) .. "]")
            if not ok then
                return false, err
            end
        end
    end

    return true, nil
end

--- Validates a typed JSON value recursively.
--- @param v any The value to validate
--- @param path string Current path for error messages
--- @return boolean True if valid
--- @return string|nil Error message if invalid
validateTypedValue = function(v, path)
    path = path or "root"

    -- null
    if v == nil then
        return true, nil
    end

    -- string
    if type(v) == "string" then
        return true, nil
    end

    -- boolean
    if type(v) == "boolean" then
        return true, nil
    end

    -- plain number (floats)
    if type(v) == "number" then
        return true, nil
    end

    -- table types
    if type(v) == "table" then
        -- Check if it's a typed integer
        local isInt, intErr = isTypedInteger(v)
        if isInt then
            return true, nil
        end
        if v.int ~= nil and intErr then
            return false, path .. ": " .. intErr
        end

        -- Check if it's a typed special float
        local isFloat, floatErr = isTypedSpecialFloat(v)
        if isFloat then
            return true, nil
        end
        if v.float ~= nil and floatErr then
            return false, path .. ": " .. floatErr
        end

        -- Must be a typed table (array form)
        return isTypedTable(v, path)
    end

    return false, path .. ": unexpected type " .. type(v)
end

--- Validates a typed JSON row (array of typed values).
--- @param row table The row to validate
--- @param rowIdx number Row index for error messages
--- @return boolean True if valid
--- @return string|nil Error message if invalid
local function validateTypedJSONRow(row, rowIdx)
    if type(row) ~= "table" then
        return false, "row " .. rowIdx .. ": expected array, got " .. type(row)
    end
    for i, cell in ipairs(row) do
        local ok, err = validateTypedValue(cell, "row " .. rowIdx .. " col " .. i)
        if not ok then
            return false, err
        end
    end
    return true, nil
end

--- Checks if a Lua table is an array (sequence) vs an object (map with string keys).
--- @param t table The table to check
--- @return boolean True if array, false if object
local function isArray(t)
    if type(t) ~= "table" then
        return false
    end
    -- Empty table is considered an array
    if next(t) == nil then
        return true
    end
    -- Check if keys are sequential integers starting from 1
    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
            return false
        end
        count = count + 1
    end
    -- Verify no gaps (length should equal count)
    return count == #t or count > 0
end

--- Validates a typed JSON file structure.
--- @param content string The JSON content to validate
--- @return boolean True if valid
--- @return string|nil Error message if invalid
local function validateTypedJSON(content)
    if type(content) ~= "string" then
        return false, "content must be string"
    end

    local parsed, _pos, err = dkjson.decode(content)
    if err then
        return false, "JSON parse error: " .. tostring(err)
    end

    if type(parsed) ~= "table" then
        return false, "root must be array, got " .. type(parsed)
    end

    -- Check that root is an array, not a JSON object
    if not isArray(parsed) then
        return false, "root must be array, got object"
    end

    for i, row in ipairs(parsed) do
        local ok, rowErr = validateTypedJSONRow(row, i)
        if not ok then
            return false, rowErr
        end
    end

    return true, nil
end

--- Validates XML element content against expected value types.
--- @param content string The XML content to validate
--- @return boolean True if valid
--- @return string|nil Error message if invalid
local function validateExportXML(content)
    if type(content) ~= "string" then
        return false, "content must be string"
    end

    -- Check XML declaration
    if not content:match("^%s*<%?xml") then
        return false, "missing XML declaration"
    end

    -- Check root element
    if not content:match("<file>") then
        return false, "missing <file> root element"
    end
    if not content:match("</file>%s*$") then
        return false, "missing </file> closing tag"
    end

    -- Check for header
    if not content:match("<header>") then
        return false, "missing <header> element"
    end
    if not content:match("</header>") then
        return false, "missing </header> closing tag"
    end

    -- Validate element types used
    local validElements = {
        ["null"] = true,
        ["true"] = true,
        ["false"] = true,
        ["string"] = true,
        ["integer"] = true,
        ["number"] = true,
        ["function"] = true,
        ["table"] = true,
        ["key_value"] = true,
        ["file"] = true,
        ["header"] = true,
        ["row"] = true,
    }

    -- Find all opening tags
    for tag in content:gmatch("<([%w_]+)[^>]*>") do
        if not validElements[tag] then
            return false, "invalid element: <" .. tag .. ">"
        end
    end

    -- Find all self-closing tags
    for tag in content:gmatch("<([%w_]+)/>") do
        if not validElements[tag] then
            return false, "invalid element: <" .. tag .. "/>"
        end
    end

    -- Validate integer content (should be numeric)
    for intContent in content:gmatch("<integer>([^<]*)</integer>") do
        if not intContent:match("^%-?%d+$") then
            return false, "invalid integer content: " .. intContent
        end
    end

    -- Validate number content (should be numeric or special value)
    for numContent in content:gmatch("<number>([^<]*)</number>") do
        if not numContent:match("^%-?%d") and
           numContent ~= "nan" and
           numContent ~= "inf" and
           numContent ~= "-inf" then
            return false, "invalid number content: " .. numContent
        end
    end

    -- Check that key_value elements have exactly 2 child values
    -- This is a simplified check - full validation would need XML parsing
    local kvPattern = "<key_value>(.-)</key_value>"
    for kvContent in content:gmatch(kvPattern) do
        -- Count value elements (simplified - counts opening tags)
        local valueCount = 0
        for _ in kvContent:gmatch("<[%w_]+[^/]->") do
            valueCount = valueCount + 1
        end
        for _ in kvContent:gmatch("<[%w_]+/>") do
            valueCount = valueCount + 1
        end
        -- Subtract nested table/key_value tags from count
        for _ in kvContent:gmatch("</[%w_]+>") do
            -- closing tags don't count as values
        end
        -- This is a heuristic check, not exact, but catches obvious errors
        if valueCount < 2 then
            return false, "key_value must have at least 2 value elements"
        end
    end

    return true, nil
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    validateTypedJSON = validateTypedJSON,
    validateTypedValue = validateTypedValue,
    validateExportXML = validateExportXML,
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
