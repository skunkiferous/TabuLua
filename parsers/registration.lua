-- parsers/registration.lua
-- Type registration and extension API

local state = require("parsers.state")
local utils = require("parsers.utils")
local lpeg_parser = require("parsers.lpeg_parser")
local generators = require("parsers.generators")

local predicates = require("predicates")
local isName = predicates.isName
local isFullSeq = predicates.isFullSeq
local isIntegerValue = predicates.isIntegerValue

local number_identifiers = require("number_identifiers")
local rangeToIdentifier = number_identifiers.rangeToIdentifier

local string_utils = require("string_utils")
local stringToIdentifier = string_utils.stringToIdentifier

local regex_utils = require("regex_utils")
local table_utils = require("table_utils")
local comparators = require("comparators")
local sandbox = require("sandbox")
local serialization = require("serialization")

local error_reporting = require("error_reporting")
local nullBadVal = error_reporting.nullBadVal

-- Safe integer range constants (IEEE 754 double precision)
local SAFE_INTEGER_MIN = -9007199254740992  -- -(2^53)
local SAFE_INTEGER_MAX = 9007199254740992   -- 2^53

local M = {}

-- Forward declarations (set by init.lua)
local parse_type
local parseType
local introspection  -- Will hold the introspection module reference

-- Set references (called by init.lua)
function M.setReferences(pt, pT, intro)
    parse_type = pt
    parseType = pT
    introspection = intro
end

-- Registers a new type alias. It must map to a valid type specification.
-- Returns true if successful
function M.registerAlias(badVal, name, type_spec)
    if not generators.checkAcceptableParserName(badVal, name, false) then
        return false
    end
    local parsed = lpeg_parser.type_parser(type_spec)
    if not parsed then
        utils.log(badVal, 'type', type_spec,
            "Cannot parse type specification: " .. tostring(type_spec))
        return false
    end
    local parser
    parser, type_spec = parse_type(badVal, parsed)
    if not parser then
        return false
    end
    assert(type_spec, "type_spec is nil")
    local already = state.ALIASES[name]
    if already then
        if already == type_spec then
            -- Already registered to same type
            -- Validate that registration worked ...
            assert(parseType(badVal, name, false),
                "Parser "..type_spec.." aliased to name '" .. name .. "' not found!")
            return true
        end
        utils.log(badVal, 'type', type_spec, "Alias '" .. name ..
            "' is already registered to a different type: "..already)
        return false
    end
    if parseType(nullBadVal, name, false) then
        utils.log(badVal, 'type', name, "Parser with name '" .. name ..
            "' is already exists")
        return false
    end
    local resolved = utils.resolve(type_spec)
    assert(resolved:sub(1, 8) ~= '{extends',
        "Parser "..type_spec.." still contains 'extends'")
    state.ALIASES[name] = utils.resolve(type_spec)
    -- Validate that registration worked ...
    assert(parseType(badVal, name, false),
        "Parser "..type_spec.." aliased to name '" .. name .. "' not found!")
    state.logger:info("Registered alias: " .. name .. " -> " .. type_spec)
    return true
end

-- Registers an enum parser. Takes a list of labels, which must be case-insensitive-unique,
-- and optionally, an alias to be registered, and returns the parser and type_spec if successful.
function M.registerEnumParser(badVal, enum_labels, enum_name)
    local type_spec = generators.registerEnumParserInternal(badVal, enum_labels)
    if type_spec then
        if enum_name then
            local registered = M.registerAlias(badVal, enum_name, type_spec)
            if not registered then
                return nil
            end
            generators.extendsOrRestrictsType(enum_name, "enum")
        end
        return state.PARSERS[type_spec], type_spec
    end
    return nil
end

-- Extends an existing parser. Instead of the normal parser parameters, the provided function will
-- be called with the parsed value, and can either return nil or true to signify that the value is
-- valid, or return a non-empty string to specify an error message, which will be logged into badVal
-- or empty-string or false for invalid values, if no specific error message is required.
-- A "predicate" function can therefore be used to check the validity of the parsed value.
-- The provided function is only called, if the parent parser was successful.
-- Returns the new parser, if the input is valid, otherwise nil
function M.restrictWithValidator(badVal, parentName, newParserName, validator)
    if not generators.checkAcceptableParserName(badVal, newParserName, true) then
        return nil
    end
    local parent = parseType(badVal, parentName)
    if not parent then
        return nil
    end
    state.PARSERS[newParserName] = function (badVal2, value, context)
        badVal2.col_types[#badVal2.col_types+1] = newParserName
        local parsed, reformatted = generators.callParser(parent, badVal2, value, context)
        badVal2.col_types[#badVal2.col_types] = nil
        if parsed == nil then
            return nil, reformatted
        end
        local err = validator(parsed)
        if err == nil or err == true then
            return parsed, reformatted
        end
        if err == false then
            err = ''
        end
        utils.log(badVal2, newParserName, value, err)
        return nil, reformatted
    end
    generators.extendsOrRestrictsType(newParserName, parentName)
    generators.registerComparator(newParserName, generators.getCompInternal(parentName))
    return state.PARSERS[newParserName]
end

-- Extends an existing parser. Instead of the normal parser parameters, the provided function will
-- be called with badVal, the parsed value, the reformatted value, from the parent parser (if
-- successful) and the context, and can either return nil, and the reformatted value, if the
-- validation fails, or the (potentially modified) parsed value, and the reformatted value, if
-- valid. The provided function is only called, if the parent parser was successful.
-- Returns the new parser, if the input is valid, otherwise nil
function M.extendParser(badVal, parentName, newParserName, parser)
    if not generators.checkAcceptableParserName(badVal, newParserName, true) then
        return nil
    end
    local parent = parseType(badVal, parentName)
    if not parent then
        return nil
    end
    state.PARSERS[newParserName] = function (badVal2, value, context)
        badVal2.col_types[#badVal2.col_types+1] = newParserName
        local parsed, reformatted = generators.callParser(parent, badVal2, value, context)
        badVal2.col_types[#badVal2.col_types] = nil
        if parsed == nil then
            return nil, reformatted
        end
        return parser(badVal2, parsed, reformatted, context)
    end
    generators.extendsOrRestrictsType(newParserName, parentName)
    generators.registerComparator(newParserName, generators.getCompInternal(parentName))
    return state.PARSERS[newParserName]
end

-- Creates a new number/integer parser that is restricted to the given range.
-- numberType must extend "number"
-- min and max must be nil or a number, but min and max cannot both be nil, and min <= max
-- The range is always "inclusive" aka [min,max]
-- The parser name is generated using rangeToIdentifier()
-- If newName is specified, it is aliased to the generated name
-- Returns the parser and its generated name on success, otherwise nil
function M.restrictNumber(badVal, numberType, min, max, newName)
    if not introspection.typeSameOrExtends(numberType, "number") then
        utils.log(badVal, 'type', numberType, 'numberType must extend number')
        return nil
    end
    numberType = utils.resolve(numberType)
    if min == nil and max == nil then
        utils.log(badVal, 'range', "nil,nil", 'min and max cannot both be nil')
        return nil
    end
    -- rangeToIdentifier() will validate the following:
    -- * min and max are either number or nil, but not both nil
    -- * Neither is NaN or infinity
    -- * min is not greater than max
    local newParserName = rangeToIdentifier(badVal, min, max)
    if not newParserName then
        -- Error already logged
        return nil
    end
    local t_min = type(min)
    local t_max = type(max)
    -- "integer" ranges should use actual integer values as min and max
    local parentInteger = introspection.typeSameOrExtends(numberType, "integer")
    -- Replace nil values with non-nil, so we don't need to check for nil when comparing
    local updateName = false
    if parentInteger then
        -- For "integer" type, use safe integer range as default bounds (±2^53)
        -- This ensures compatibility with JSON and LuaJIT
        if t_min ~= 'nil' then
            if not isIntegerValue(min) then
                utils.log(badVal, 'number', min,
                    'min must be an integer or nil, to extend ' .. numberType)
                return nil, newParserName
            end
            if math.type and math.type(min) ~= "integer" then
                min = math.floor(min)
                updateName = true
            end
        else
            min = SAFE_INTEGER_MIN
        end
        if t_max ~= 'nil' then
            if not isIntegerValue(max) then
                utils.log(badVal, 'number', max,
                    'max must be an integer or nil to extend ' .. numberType)
                return nil
            end
            if math.type and math.type(max) ~= "integer" then
                max = math.floor(max)
                updateName = true
            end
        else
            max = SAFE_INTEGER_MAX
        end
    end
    if updateName then
        newParserName = rangeToIdentifier(badVal, min, max)
        if not newParserName then
            -- Error already logged
            return nil
        end
    end
    -- The parser is dependent on the range and the parent number type
    newParserName = numberType .. '.' .. newParserName
    if newName == '' then
        newName = nil
    end
    if newName ~= nil and not isName(newName) then
        utils.log(badVal, 'name', newName, 'newName must be a name or nil')
        return nil, newParserName
    end
    if state.NUMBER_LIMITS[newParserName] then
        -- Already registered!
        local parser = state.PARSERS[newParserName]
        if not parser then
            error("Limits for parser " .. newParserName .. " defined, but parser not found")
        end
        if newName then
            -- It's possible that the "range" is already registered to a different name
            local previous = state.ALIASES[newName]
            if previous then
                if previous ~= newParserName then
                    utils.log(badVal, 'name', newName,
                        'Alias ' .. newName .. ' is already registered to a different type: '
                        .. newParserName)
                    -- newParserName is valid, and was already registered, so return it anyway
                    return nil, newParserName
                end
            else
                -- It's possible that the "range" is already registered without an alias
                if not M.registerAlias(badVal, newName, newParserName) then
                    -- newParserName is valid, and was already registered, so return it anyway
                    return nil, newParserName
                end
            end
        end
        generators.extendsOrRestrictsType(newParserName, numberType)
        return parser, newParserName
    end
    -- Check if base type has limits
    local baseType = numberType
    while baseType do
        local limits = state.NUMBER_LIMITS[baseType]
        if limits then
            -- Validate new range is within old range
            -- Only error if the user explicitly specified a value (t_min/t_max ~= 'nil').
            -- When the value was defaulted (nil -> SAFE_INTEGER), silently inherit parent's limit.
            if limits.min and min and min < limits.min then
                if t_min ~= 'nil' then
                    utils.log(badVal, 'number', min,
                        'cannot be less than existing min ' .. limits.min)
                    return nil, newParserName
                end
            end
            if limits.max and max and max > limits.max then
                if t_max ~= 'nil' then
                    utils.log(badVal, 'number', max,
                        'cannot be greater than existing max ' .. limits.max)
                    return nil, newParserName
                end
            end
            -- Take most restrictive bounds
            min = math.max(min or -math.huge, limits.min or -math.huge)
            max = math.min(max or math.huge, limits.max or math.huge)
        end
        baseType = introspection.typeParent(baseType)
    end
    min = min or -math.huge
    max = max or math.huge
    local result = M.restrictWithValidator(badVal, numberType,
        newParserName, function (num)
            return num >= min and num <= max
        end)
    if result then
        state.NUMBER_LIMITS[newParserName] = {min=min, max=max}
        if newName and not M.registerAlias(badVal, newName, newParserName) then
            -- newParserName is valid, and was already registered, so return it anyway
            return nil, newParserName
        end
        return result, newParserName
    end
    return nil, newParserName
end

-- Returns a new string parser that is restricted to strings of length between min and max
-- strType must extend "string"
-- min and max must be nil or a non-negative integer, but both cannot be nil
-- regex is an optional string; if not nil or "", the string must match regex
-- newName is optional; if provided, the new parser is aliased to newName
-- Returns the parser and its generated name on success, otherwise nil
function M.restrictString(badVal, strType, min, max, regex, newName)
    if not introspection.typeSameOrExtends(strType, "string") then
        utils.log(badVal, 'type', strType, 'strType must extend string')
        return nil
    end
    strType = utils.resolve(strType)

    if min == nil and max == nil and (regex == nil or regex == "") then
        utils.log(badVal, 'range', "nil,nil.nil",
            'min, max and regex cannot be all nil')
        return nil
    end

    local t_min = type(min)
    local t_max = type(max)
    if min ~= nil then
        if t_min ~= "number" then
            utils.log(badVal, 'number', min, 'min must be a number or nil')
            return nil
        end
        if not isIntegerValue(min) then
            utils.log(badVal, 'number', min, 'min must be an integer')
            return nil
        end
        if min < 0 then
            utils.log(badVal, 'number', min, 'min cannot be negative')
            return nil
        end
        min = math.floor(min)
    end
    if max ~= nil then
        if t_max ~= "number" then
            utils.log(badVal, 'number', max, 'max must be a number or nil')
            return nil
        end
        if not isIntegerValue(max) then
            utils.log(badVal, 'number', max, 'max must be an integer')
            return nil
        end
        if max < 0 then
            utils.log(badVal, 'number', max, 'max cannot be negative')
            return nil
        end
        max = math.floor(max)
    end
    if min ~= nil and max ~= nil and min > max then
        utils.log(badVal, 'range', string.format("[%s,%s]", min, max),
            '(ORIGINAL)min must be <= max')
        return nil
    end
    local parentMin = state.STR_MIN_LEN[strType]
    local parentMax = state.STR_MAX_LEN[strType]
    if parentMin ~= nil and min ~= nil and min < parentMin then
        min = parentMin
    end
    if parentMax ~= nil and max ~= nil and max > parentMax then
        max = parentMax
    end
    if min ~= nil and max ~= nil and min > max then
        utils.log(badVal, 'range', string.format("[%s,%s]", min, max),
            '(INHERITED)min must be <= max')
        return nil
    end

    -- Generate unique parser name based on constraints
    local newParserName = rangeToIdentifier(badVal, min, max)
    if not newParserName then
        -- Error already logged
        return nil
    end
    newParserName = "_RS" .. newParserName -- 'RS' for Restricted String
    if regex and #regex > 0 then
        -- Append the regex itself to the name to ensure uniqueness
        newParserName = newParserName .. "_RE_" .. stringToIdentifier(regex)
    end

    -- The parser name depends on both the constraints and the parent type
    newParserName = strType .. "." .. newParserName

    if newName == '' then
        newName = nil
    end
    if newName ~= nil and not isName(newName) then
        utils.log(badVal, 'name', newName, 'newName must be a name or nil')
        return nil, newParserName
    end

    -- We'll just assume if the generated name exists, it was defined the same way
    local result = state.PARSERS[newParserName]
    if result == nil then
        -- Create validator function
        local validator
        if regex and #regex > 0 then
            -- Create regex matcher
            local matcher, err = regex_utils.multiMatcher(regex)
            if not matcher then
                utils.log(badVal, 'regex', regex, err)
                return nil, newParserName
            end
            -- Validate both length and regex
            validator = function(str)
                local len = #str
                if min and len < min then
                    return string.format("string length %d below minimum %d", len, min)
                end
                if max and len > max then
                    return string.format("string length %d above maximum %d", len, max)
                end
                if not matcher(str) then
                    return string.format("string does not match pattern '%s'", regex)
                end
                return true
            end
        else
            -- Only validate length
            validator = function(str)
                local len = #str
                if min and len < min then
                    return string.format("string length %d below minimum %d", len, min)
                end
                if max and len > max then
                    return string.format("string length %d above maximum %d", len, max)
                end
                return true
            end
        end

        result = M.restrictWithValidator(badVal, strType, newParserName, validator)
    end
    if result then
        -- Update STR_MIN_LEN, STR_MAX_LEN, STR_REGEX
        state.STR_MIN_LEN[newParserName] = min
        state.STR_MAX_LEN[newParserName] = max
        state.STR_REGEX[newParserName] = regex
        if newName and not M.registerAlias(badVal, newName, newParserName) then
            -- newParserName is valid and was already registered, so return it anyway
            return nil, newParserName
        end
        return result, newParserName
    end
    return nil, newParserName
end

-- Creates a new enum parser that is restricted to the given labels
-- enumType must extend some enum type
-- labels must be a table of strings, all of which are accepted by enumType
-- Returns the parser on success, otherwise nil
function M.restrictEnum(badVal, enumType, labels, newName)
    -- Validate that enumType extends enum
    if not introspection.extendsOrRestrict(enumType, "enum") then
        utils.log(badVal, 'type', enumType, 'enumType must extend enum')
        return nil
    end

    -- Validate labels is a table
    if type(labels) ~= "table" then
        utils.log(badVal, 'table', labels, 'labels must be a table')
        return nil
    end
    if not isFullSeq(labels) then
        utils.log(badVal, 'table', labels, 'labels must be a sequence')
        return nil
    end

    -- Get original parser to validate against
    local originalParser = parseType(badVal, enumType)
    if not originalParser then
        return nil
    end

    -- Verify each label and collect them for the new type name
    local validLabels = {}
    local labelSet = {}
    local fail = false
    for _, label in ipairs(labels) do
        -- Check each label is valid for the parent enum
        local parsed = generators.callParser(originalParser, nullBadVal, label, "parsed")
        if parsed == nil then
            utils.log(badVal, 'label', label, 'label is not valid for enum type ' .. enumType)
            fail = true
        else
            if not labelSet[parsed] then
                labelSet[parsed] = true
                validLabels[#validLabels+1] = parsed
            end
        end
    end

    if fail then
        return nil
    end

    if #validLabels == 0 then
        utils.log(badVal, 'table', labels, 'no valid label')
        return nil
    end

    local parser, type_spec = M.registerEnumParser(badVal, validLabels)
    if parser == nil or type_spec == nil then
        return nil
    end

    if newName == '' then
        newName = nil
    end
    if newName ~= nil and not isName(newName) then
        utils.log(badVal, 'name', newName, 'newName must be a name or nil')
        return nil, type_spec
    end

    generators.extendsOrRestrictsType(type_spec, enumType)

    if newName and not M.registerAlias(badVal, newName, type_spec) then
        -- newParserName is valid and was already registered, so return it anyway
        return nil, type_spec
    end

    return parser, type_spec
end

-- Creates a new union parser that is restricted to specific allowed types from the original union
-- unionType must be a union type
-- allowedTypes must be a table of type specifications that are valid members of the original union
-- newName is optional; if provided, the new parser is aliased to newName
-- Returns the parser and its generated name on success, otherwise nil
function M.restrictUnion(badVal, unionType, allowedTypes, newName)
    -- Validate that unionType is a union type
    if not introspection.extendsOrRestrict(unionType, "union") then
        utils.log(badVal, 'type', unionType, 'unionType must be a union type')
        return nil
    end
    unionType = utils.resolve(unionType)

    -- Get original parser to validate against
    local originalParser = parseType(badVal, unionType)
    if not originalParser then
        return nil
    end

    -- Validate allowedTypes is a table
    if type(allowedTypes) ~= "table" then
        utils.log(badVal, 'table', allowedTypes, 'allowedTypes must be a table')
        return nil
    end
    if not isFullSeq(allowedTypes) then
        utils.log(badVal, 'table', allowedTypes, 'allowedTypes must be a sequence')
        return nil
    end

    -- Convert allowedTypes into a lookup set for quick membership testing
    local allowedSet = {}
    for _, typeSpec in ipairs(allowedTypes) do
        if type(typeSpec) ~= "string" then
            utils.log(badVal, 'string', typeSpec, 'each allowed type must be a string')
            return nil
        end
        allowedSet[utils.resolve(typeSpec)] = true
    end

    -- Collect valid types in the same order as the original union
    local validTypes = {}
    local hasNil = false  -- Track if nil type is present (must remain last)
    local parsed = lpeg_parser.type_parser(unionType)
    for _, typeSpec in ipairs(parsed.value) do
        local resolvedType = lpeg_parser.parsedTypeSpecToStr(typeSpec)
        if allowedSet[resolvedType] then
            if resolvedType == "nil" then
                hasNil = true  -- Remember to add nil last
            else
                validTypes[#validTypes + 1] = resolvedType
            end
            allowedSet[resolvedType] = nil  -- Mark as used
        end
    end

    -- Add nil type last if it was allowed
    if hasNil then
        validTypes[#validTypes + 1] = "nil"
    end

    -- Check if any allowed types weren't found in the original union
    for typeSpec in pairs(allowedSet) do
        utils.log(badVal, 'type', typeSpec, 'type is not part of union ' .. unionType)
        return nil
    end

    if #validTypes == 0 then
        utils.log(badVal, 'table', allowedTypes, 'no valid types')
        return nil
    end

    -- Generate the new union type specification
    local newTypeSpec = table.concat(validTypes, "|")

    -- Parse the new union type to get its parser
    local parser = parseType(badVal, newTypeSpec)
    if not parser then
        return nil
    end

    if newName == '' then
        newName = nil
    end
    if newName ~= nil and not isName(newName) then
        utils.log(badVal, 'name', newName, 'newName must be a name or nil')
        return nil, newTypeSpec
    end

    if #validTypes == 1 and newName == nil then
        utils.log(badVal, 'table', allowedTypes,
        'union requires multiple valid types OR a new name')
        return nil
    end

    if #validTypes == 1 then
        -- A single type is not a union. But if we have a newName, we can still register it
        generators.extendsOrRestrictsType(newName, unionType)
        return parser, nil
    else
        -- Register that this new union extends the original union type
        generators.extendsOrRestrictsType(newTypeSpec, unionType)

        if newName and not M.registerAlias(badVal, newName, newTypeSpec) then
            -- Type spec is valid and was already registered, so return it anyway
            return nil, newTypeSpec
        end

        return parser, newTypeSpec
    end
end

-- Maximum operations allowed when evaluating a validate expression
local VALIDATE_EXPR_MAX_OPERATIONS = 1000

-- Restricts a type using a sandboxed expression validator.
-- The expression is evaluated with 'value' bound to the parsed value.
-- Returns the parser function if successful, nil otherwise.
function M.restrictWithExpression(badVal, parentName, newParserName, exprString)
    local parent = parseType(badVal, parentName)
    if not parent then return nil end

    -- Validate that the expression compiles
    local code = "return (" .. exprString .. ")"
    local compile_env = {
        value = 0,  -- Dummy value for compilation check
        math = math,
        string = string,
        table = table,
        pairs = pairs,
        ipairs = ipairs,
        type = type,
        tostring = tostring,
        tonumber = tonumber,
        predicates = predicates,
        stringUtils = {
            trim = string_utils.trim,
            split = string_utils.split,
            parseVersion = string_utils.parseVersion,
        },
        tableUtils = {
            keys = table_utils.keys,
            values = table_utils.values,
            pairsCount = table_utils.pairsCount,
        },
        equals = comparators.equals,
    }
    local compile_opt = {quota = 100, env = compile_env}
    local compile_ok, compile_result = pcall(sandbox.protect, code, compile_opt)
    if not compile_ok then
        utils.log(badVal, newParserName, exprString, "failed to compile validate expression: " .. tostring(compile_result))
        return nil
    end

    -- Create the new parser that validates using the expression
    local newParser = function(badVal2, value, context)
        local parsed, reformatted = generators.callParser(parent, badVal2, value, context)
        if parsed == nil then return nil, reformatted end

        -- Create sandboxed environment with the parsed value
        local expr_env = {
            value = parsed,
            math = math,
            string = string,
            table = table,
            pairs = pairs,
            ipairs = ipairs,
            type = type,
            tostring = tostring,
            tonumber = tonumber,
            predicates = predicates,
            stringUtils = {
                trim = string_utils.trim,
                split = string_utils.split,
                parseVersion = string_utils.parseVersion,
            },
            tableUtils = {
                keys = table_utils.keys,
                values = table_utils.values,
                pairsCount = table_utils.pairsCount,
            },
            equals = comparators.equals,
        }
        local opt = {quota = VALIDATE_EXPR_MAX_OPERATIONS, env = expr_env}
        local ok, protected_func = pcall(sandbox.protect, code, opt)
        if not ok then
            utils.log(badVal2, newParserName, value, "validate expression error: " .. tostring(protected_func))
            return nil, reformatted
        end

        local exec_ok, result = pcall(protected_func)
        if not exec_ok then
            utils.log(badVal2, newParserName, value, "validate expression failed: " .. tostring(result))
            return nil, reformatted
        end

        -- Interpret the result:
        -- true or "" (empty string) -> valid
        -- false or nil -> invalid with default error message
        -- non-empty string -> invalid with custom error message
        -- number -> invalid with number as error message
        -- anything else -> invalid, serialize to get error message
        if result == true or result == "" then
            -- Valid
            return parsed, reformatted
        elseif result == false or result == nil then
            -- Invalid with default message
            utils.log(badVal2, newParserName, value, "validation failed")
            return nil, reformatted
        else
            -- Invalid with custom error message
            -- Use serializeInSandbox for safe serialization of any result type
            local errorMsg = serialization.serializeInSandbox(result)
            utils.log(badVal2, newParserName, value, errorMsg)
            return nil, reformatted
        end
    end

    -- Register the new parser
    state.PARSERS[newParserName] = newParser

    -- Register type relationship and comparator
    generators.extendsOrRestrictsType(newParserName, parentName)
    generators.registerComparator(newParserName, generators.getCompInternal(parentName))

    return newParser
end

-- Restricts a type so that its values must be names of types extending a specified ancestor.
-- parentName must be a string-based type (e.g., "name", "type_spec").
-- ancestorSpec is the type specification that values must extend (or be equal to).
-- Returns the parser function if successful, nil otherwise.
function M.restrictToTypeExtending(badVal, parentName, newParserName, ancestorSpec)
    local parent = parseType(badVal, parentName)
    if not parent then return nil end

    -- Validate that ancestorSpec is a known type
    local ancestorParser = parseType(badVal, ancestorSpec)
    if not ancestorParser then
        utils.log(badVal, 'type', ancestorSpec,
            'ancestor must be a valid, registered type specification')
        return nil
    end

    -- Create the new parser that validates the value is a type name extending the ancestor
    local newParser = function(badVal2, value, context)
        local parsed, reformatted = generators.callParser(parent, badVal2, value, context)
        if parsed == nil then return nil, reformatted end

        -- Check that the parsed value names a type that extends (or is) the ancestor
        if not introspection.typeSameOrExtends(parsed, ancestorSpec) then
            utils.log(badVal2, newParserName, value,
                "'" .. tostring(parsed) .. "' is not a type that extends " .. ancestorSpec)
            return nil, reformatted
        end

        return parsed, reformatted
    end

    -- Register the new parser
    state.PARSERS[newParserName] = newParser

    -- Register type relationship and comparator
    generators.extendsOrRestrictsType(newParserName, parentName)
    generators.registerComparator(newParserName, generators.getCompInternal(parentName))

    return newParser
end

-- Registers custom types from a data-driven specification.
-- typeSpecs is a sequence of records with fields:
--   name: string - the name of the new type
--   parent: string|nil - the parent type specification (defaults to "type_spec" when ancestor is set)
--   ancestor: string|nil - value must be a type name extending this ancestor
--   min: number|nil - minimum value (for number types)
--   max: number|nil - maximum value (for number types)
--   minLen: integer|nil - minimum string length (for string types)
--   maxLen: integer|nil - maximum string length (for string types)
--   pattern: string|nil - regex pattern (for string types)
--   validate: string|nil - expression-based validator (mutually exclusive with other constraints)
--   values: {string}|nil - allowed values (for enum types)
-- Returns true if all types were registered successfully, false otherwise.
function M.registerTypesFromSpec(badVal, typeSpecs)
    if type(typeSpecs) ~= "table" then
        utils.log(badVal, 'table', typeSpecs, 'typeSpecs must be a table')
        return false
    end

    local success = true
    for _, spec in ipairs(typeSpecs) do
        local name = spec.name
        local parent = spec.parent
        local hasAncestorConstraint = spec.ancestor ~= nil

        -- Default parent to "type_spec" when ancestor is set
        if hasAncestorConstraint and (parent == nil or parent == "") then
            parent = "type_spec"
        end

        if type(name) ~= "string" or name == "" then
            utils.log(badVal, 'name', name, 'type name must be a non-empty string')
            success = false
        elseif type(parent) ~= "string" or parent == "" then
            utils.log(badVal, 'type', parent, 'parent must be a non-empty type specification')
            success = false
        else
            -- Determine what kind of restriction to apply based on the parent type and spec fields
            local hasNumericConstraints = spec.min ~= nil or spec.max ~= nil
            local hasStringConstraints = spec.minLen ~= nil or spec.maxLen ~= nil or spec.pattern ~= nil
            local hasEnumConstraints = spec.values ~= nil
            local hasExpressionConstraint = spec.validate ~= nil

            -- Count how many constraint types are specified
            local constraintCount = 0
            if hasNumericConstraints then constraintCount = constraintCount + 1 end
            if hasStringConstraints then constraintCount = constraintCount + 1 end
            if hasEnumConstraints then constraintCount = constraintCount + 1 end
            if hasExpressionConstraint then constraintCount = constraintCount + 1 end
            if hasAncestorConstraint then constraintCount = constraintCount + 1 end

            if constraintCount == 0 then
                -- No constraints - just register as an alias
                if not M.registerAlias(badVal, name, parent) then
                    success = false
                end
            elseif constraintCount > 1 then
                utils.log(badVal, 'spec', name,
                    'cannot mix constraint types (numeric, string, enum, expression, ancestor) in the same type definition')
                success = false
            elseif hasAncestorConstraint then
                -- Ancestor constraint - value must be a type name extending the ancestor
                if not introspection.typeSameOrExtends(parent, "string") then
                    utils.log(badVal, 'type', parent,
                        'ancestor constraint requires a parent type that extends string')
                    success = false
                else
                    local parser = M.restrictToTypeExtending(badVal, parent, name, spec.ancestor)
                    if not parser then
                        success = false
                    end
                end
            elseif hasExpressionConstraint then
                -- Expression-based validator
                local parser = M.restrictWithExpression(badVal, parent, name, spec.validate)
                if not parser then
                    success = false
                end
            elseif hasNumericConstraints then
                -- Numeric type with range constraints
                if not introspection.typeSameOrExtends(parent, "number") then
                    utils.log(badVal, 'type', parent,
                        'min/max constraints require a type that extends number')
                    success = false
                else
                    local parser = M.restrictNumber(badVal, parent, spec.min, spec.max, name)
                    if not parser then
                        success = false
                    end
                end
            elseif hasStringConstraints then
                -- String type with length/pattern constraints
                if not introspection.typeSameOrExtends(parent, "string") then
                    utils.log(badVal, 'type', parent,
                        'minLen/maxLen/pattern constraints require a type that extends string')
                    success = false
                else
                    local parser = M.restrictString(badVal, parent, spec.minLen, spec.maxLen,
                        spec.pattern, name)
                    if not parser then
                        success = false
                    end
                end
            elseif hasEnumConstraints then
                -- Enum type with restricted values
                if not introspection.extendsOrRestrict(parent, "enum") then
                    utils.log(badVal, 'type', parent,
                        'values constraint requires a type that extends enum')
                    success = false
                else
                    local parser = M.restrictEnum(badVal, parent, spec.values, name)
                    if not parser then
                        success = false
                    end
                end
            end
        end
    end

    return success
end

-- Returns a comparator for the given type specification, if valid.
function M.getComparator(type_spec)
    local parsed = lpeg_parser.type_parser(type_spec)
    if not parsed then
        return nil
    end
    local parser
    parser, type_spec = parse_type(nullBadVal, parsed)
    if not parser then
        return nil
    end
    return state.COMPARATORS[utils.resolve(type_spec)]
end

-- Creates and returns an appropriate default value for the given type
function M.createDefaultValue(type_spec)
    -- Check the format
    if not type_spec then
        return nil
    end
    local parsed = lpeg_parser.type_parser(type_spec)
    if not parsed then
        return nil
    end
    -- Check the type is actually valid/known
    local parser
    parser, type_spec = parse_type(nullBadVal, parsed)
    if not parser then
        return nil
    end
    if introspection.typeSameOrExtends(type_spec, 'boolean') then
        return false
    end
    if introspection.typeSameOrExtends(type_spec, 'number') then
        return 0
    end
    if introspection.typeSameOrExtends(type_spec, 'string') then
        return ''
    end
    if introspection.typeSameOrExtends(type_spec, 'table') then
        return {}
    end
    local unionFirst = state.UNION_FIRST_TYPE[type_spec]
    if unionFirst then
        -- Union types should default based on their first type
        return M.createDefaultValue(unionFirst)
    end
    -- Unknown/bad type; default to nil
    return nil
end

return M
