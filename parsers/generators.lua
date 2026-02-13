-- parsers/generators.lua
-- Parser factory functions for creating array, map, tuple, union, and record parsers

local state = require("parsers.state")
local utils = require("parsers.utils")

local predicates = require("predicates")
local isName = predicates.isName
local isIdentifier = predicates.isIdentifier
local isValueKeyword = predicates.isValueKeyword
local isReservedName = predicates.isReservedName
local isTupleFieldName = predicates.isTupleFieldName
local isFullSeq = predicates.isFullSeq

local sparse_sequence = require("sparse_sequence")
local isSparseSequence = sparse_sequence.isSparseSequence

local table_utils = require("table_utils")
local keys = table_utils.keys
local pairsCount = table_utils.pairsCount

local error_reporting = require("error_reporting")
local nullBadVal = error_reporting.nullBadVal

local read_only = require("read_only")
local readOnlyTuple = read_only.readOnlyTuple

local M = {}

-- Returns the name or type specification of the parser, if registered
function M.findParserSpec(parser)
    for n, p in pairs(state.PARSERS) do
        if p == parser then
            return n
        end
    end
    return nil
end

-- Wraps calls to parsers, to help debugging
function M.callParser(parser, badVal, value, context)
    assert(parser, "parser is nil")
    local parsed, reformatted = parser(badVal, value, context)
    local type_spec = M.findParserSpec(parser)
    type_spec = type_spec or '?'
    assert(type(reformatted) == 'string', "Reformatted value must of "..type_spec
        .." be a string, but was: " .. type(reformatted))
    return parsed, reformatted
end

-- Returns true, if this name is acceptable as a parser name
function M.checkAcceptableParserName(badVal, name, checkUnused)
    checkUnused = checkUnused or false
    if type(name) ~= "string" then
        utils.log(badVal, 'type', name, "Parser name '" .. tostring(name) ..
            "' must be a string, but was " .. type(name))
        return false
    end
    if not isName(name) then
        utils.log(badVal, 'type', name, "Parser name '" .. tostring(name) ..
            "' format is not valid")
        return false
    end
    if isValueKeyword(name) and not state.settingUp then
        utils.log(badVal, 'type', name, "Parser name '" .. tostring(name) ..
            "' cannot be a keyword")
        return false
    end
    if isReservedName(name) then
        utils.log(badVal, 'type', name, "Parser name '" .. tostring(name) ..
            "' is a reserved name")
        return false
    end
    if isTupleFieldName(name) then
        utils.log(badVal, 'type', name, "Parser name '" .. tostring(name) ..
            "' is reserved for tuples")
        return false
    end
    if checkUnused then
        if state.PARSERS[name] or state.ALIASES[name] then
            utils.log(badVal, 'type', name, "Parser name '" .. name ..
                "' is already in use")
            return false
        end
    end
    return true
end

-- Registers a comparator
function M.registerComparator(type_spec, comp)
    type_spec = utils.resolve(type_spec)
    state.COMPARATORS[type_spec] = comp
end

-- Returns a comparator for the given type specification. Fails if not found
function M.getCompInternal(type_spec)
    return state.COMPARATORS[utils.resolve(type_spec)] or error("Comparator for " .. type_spec
        .. " not found")
end

-- Perform one update to "types parameters"
local function doTypeParamsUpdate(type_name)
    local parent_type_name = state.EXTENDS[type_name]
    if state.refs.extendsOrRestrict(type_name, 'string') then
        if state.STR_MIN_LEN[type_name] == nil then
            state.STR_MIN_LEN[type_name] = state.STR_MIN_LEN[parent_type_name]
        end
        if state.STR_MAX_LEN[type_name] == nil then
            state.STR_MAX_LEN[type_name] = state.STR_MAX_LEN[parent_type_name]
        end
        if state.STR_REGEX[type_name] == nil then
            state.STR_REGEX[type_name] = state.STR_REGEX[parent_type_name]
        end
    end
end

-- Records that a type explicitly extends or restricts another type
function M.extendsOrRestrictsType(type_name, parent_type_name)
    state.EXTENDS[type_name] = parent_type_name
    if state.refs.extendsOrRestrict == nil then
        state.TYPES_PARAMS_TODO[#state.TYPES_PARAMS_TODO + 1] = type_name
    else
        if #state.TYPES_PARAMS_TODO > 0 then
            for _, tn in pairs(state.TYPES_PARAMS_TODO) do
                doTypeParamsUpdate(tn)
            end
            state.TYPES_PARAMS_TODO = {}
        end
        doTypeParamsUpdate(type_name)
    end
end

-- Returns an array parser, for the desired element type
function M.get_array_parser(elem_type, elem_parser)
    if not state.ARRAY_PARSERS[elem_type] then
        if type(elem_type) ~= 'string' then
            error('elem_type must be a string: '..type(elem_type))
        end
        if type(elem_parser) ~= 'function' then
            error('elem_parser must be a function: '..type(elem_parser))
        end
        utils.notNilParser(elem_parser, 'elem_type')
        local isNilUnion = state.nilUnions[elem_parser]
        local pretendString = state.FORCE_REFORMATTED_AS_STRING[utils.resolve(elem_type)]
        state.ARRAY_PARSERS[elem_type] = function (badVal, value, context)
            -- If context is 'tsv' AND elem_type extends 'string' AND value is not empty AND
            -- value does not start with " or ' then assume value is a single unquoted string
            if  utils.expectTSV(context) and state.refs.extendsOrRestrict(elem_type, 'string') and
                value ~= nil and value ~= '' and value:sub(1,1) ~= '"' and value:sub(1,1) ~= "'"
                then
                if value:sub(1,1) == '{' and value:sub(-1) == '}' then
                    state.logger:warn("Value " .. value
                        .. " is wrapped in {} but array braces are added automatically;"
                        .. " remove the outer {}")
                else
                    state.logger:warn("Assuming " .. value .. " is a single unquoted string")
                end
                return {value}, value
            end
            --{<type>}
            local parsed, str = utils.table_parser(badVal, 'array', value)
            if not parsed then
                return nil, str
            end
            if isNilUnion then
                if not isSparseSequence(parsed) then
                    utils.log(badVal, 'array', value, 'not a (sparse?) sequence')
                    return nil, str
                end
            elseif not isFullSeq(parsed) then
                utils.log(badVal, 'array', value, 'not a sequence')
                return nil, str
            end
            local before = badVal.errors
            local parsed_copy = {}
            local ref_copy = {}
            local fail = false
            for i, v in ipairs(parsed) do
                local parsed_v, reformatted_v = M.callParser(elem_parser, badVal,
                    v, 'parsed')
                if badVal.errors == before then
                    parsed_copy[i] = parsed_v
                    ref_copy[i] = utils.quoteIfNeeded(parsed_v, reformatted_v,
                        pretendString)
                else
                    fail = true
                end
            end
            if fail then
                return nil, str
            end
            return parsed_copy, utils.serializeTableWithoutCB(ref_copy)
        end
    end
    return state.ARRAY_PARSERS[elem_type]
end

-- Returns a map parser, for the desired key and value type
function M.get_map_parser(key_type, value_type, key_parser, value_parser)
    local cache_key = key_type .. "," .. value_type
    if not state.MAP_PARSERS[cache_key] then
        if type(key_type) ~= 'string' then
            error('key_type must be a string: '..type(key_type))
        end
        if type(key_parser) ~= 'function' then
            error('key_parser must be a function: '..type(key_parser))
        end
        if type(value_type) ~= 'string' then
            error('value_type must be a string: '..type(value_type))
        end
        if type(value_parser) ~= 'function' then
            error('value_parser must be a function: '..type(value_parser))
        end
        local pretendKeyString = state.FORCE_REFORMATTED_AS_STRING[utils.resolve(key_type)]
        local pretendValString = state.FORCE_REFORMATTED_AS_STRING[utils.resolve(value_type)]
        state.MAP_PARSERS[cache_key] = function (badVal, value, context)
            --{<type1>:<type2>}
            local parsed, str = utils.table_parser(badVal, 'map', value)
            if not parsed then
                return nil, str
            end
            local before = badVal.errors
            local parsed_copy = {}
            local ref_copy = {}
            for k, v in pairs(parsed) do
                local parsed_k, reformatted_k = M.callParser(key_parser, badVal,
                    k, 'parsed')
                local parsed_v, reformatted_v = M.callParser(value_parser, badVal,
                    v, 'parsed')
                if badVal.errors == before then
                    -- if key or value is nil, then no point if "storing" the pair
                    if parsed_k ~= nil and parsed_v ~= nil then
                        parsed_copy[parsed_k] = parsed_v
                    end
                    local ref_key = utils.quoteIfNeeded(parsed_k, reformatted_k,
                        pretendKeyString)
                    ref_copy[ref_key] = utils.quoteIfNeeded(parsed_v, reformatted_v,
                        pretendValString)
                else
                    return nil, str
                end
            end
            return parsed_copy, utils.serializeTableWithoutCB(ref_copy)
        end
    end
    return state.MAP_PARSERS[cache_key]
end

-- Returns a tuple parser, for the desired field types
function M.get_tuple_parser(types, fields_parsers)
    local cache_key = table.concat(types, ",")
    if not state.TUPLE_PARSERS[cache_key] then
        if #types ~= #fields_parsers then
            error('#types('..#types..') ~= #fields_parsers('..#fields_parsers..')')
        end
        local pretendString = {}
        for i, elem_type in ipairs(types) do
            local elem_parser = fields_parsers[i]
            if type(elem_type) ~= 'string' then
                error('elem_type['..i..'] must be a string: '..type(elem_type))
            end
            if type(elem_parser) ~= 'function' then
                error('elem_parser['..i..'] must be a function: '..type(elem_parser))
            end
            utils.notNilParser(elem_parser, 'elem_type['..i..']')
            pretendString[i] = state.FORCE_REFORMATTED_AS_STRING[utils.resolve(elem_type)]
        end
        state.TUPLE_PARSERS[cache_key] = function (badVal, value, context)
            --{<type1>,<type2>,...}
            local parsed, str = utils.table_parser(badVal, 'tuple', value)
            if not parsed then
                return nil, str
            end
            local before = badVal.errors
            local parsed_copy = {}
            local ref_copy = {}
            local fail = false
            for i, v in ipairs(parsed) do
                local parsed_v, reformatted_v = M.callParser(fields_parsers[i], badVal,
                    v, 'parsed')
                if badVal.errors == before then
                    parsed_copy[i] = parsed_v
                    ref_copy[i] = utils.quoteIfNeeded(parsed_v, reformatted_v,
                        pretendString[i])
                else
                    fail = true
                end
            end
            if fail then
                return nil, str
            end
            return readOnlyTuple(parsed_copy), utils.serializeTableWithoutCB(ref_copy)
        end
    end
    return state.TUPLE_PARSERS[cache_key]
end

-- Returns a union parser
function M.get_union_parser(types, fields_parsers)
    local cache_key = table.concat(types, "|")
    if not state.UNION_PARSERS[cache_key] then
        if #types ~= #fields_parsers then
            error('#types('..#types..') ~= #fields_parsers('..#fields_parsers..')')
        end
        local nilParser = state.PARSERS['nil']
        local canBeNil = false
        for i, elem_type in ipairs(types) do
            local elem_parser = fields_parsers[i]
            if type(elem_type) ~= 'string' then
                error('elem_type['..i..'] must be a string: '..type(elem_type))
            end
            if type(elem_parser) ~= 'function' then
                error('elem_parser['..i..'] must be a function: '..type(elem_parser))
            end
            if elem_parser == nilParser then
                canBeNil = true
            end
        end
        local new_parser = function (badVal, value, context)
            --<type1>|<type2>|...
            -- We don't want to give priority to anything that can match '', like tables ...
            -- Handle both nil and empty string for optional (union with nil) types
            if canBeNil and (value == nil or value == '') then
                return nil, ''
            end
            -- Save and restore nullBadVal.errors around each trial to prevent accumulated
            -- errors from failed trials affecting parsers that check error counts (like
            -- the array parser's element-by-element error checking)
            local saved_errors = nullBadVal.errors
            for i, p in ipairs(fields_parsers) do
                local parsed_v, reformatted_v = M.callParser(p, nullBadVal,
                    value, context)
                if parsed_v ~= nil then
                    nullBadVal.errors = saved_errors
                    return parsed_v, reformatted_v
                end
                nullBadVal.errors = saved_errors
            end
            utils.log(badVal, cache_key, value)
            if type(value) == "function" then
                return nil, "function"
            end
            return nil, tostring(value)
        end
        state.UNION_PARSERS[cache_key] = new_parser
        state.UNION_FIRST_TYPE[cache_key] = types[1]
        -- nil is only allowed as the last parser. If so, we record the new parser as "optional
        -- value parser"
        if fields_parsers[#fields_parsers] == nilParser then
            state.nilUnions[new_parser] = true
        end
    end
    return state.UNION_PARSERS[cache_key]
end

-- Returns a record parser, for the desired key and value type
-- fields_types maps field names to their types
-- fields_parsers maps field names to their parsers
-- type_spec, the type specification, has the field names *sorted*
function M.get_record_parser(fields_types, fields_parsers, type_spec)
    local cache_key = type_spec
    if not state.RECORD_PARSERS[cache_key] then
        local serialization = require("serialization")
        local serializeTable = serialization.serializeTable
        local typesKeys = serializeTable(keys(fields_types))
        local fieldsKeys = serializeTable(keys(fields_parsers))
        if typesKeys ~= fieldsKeys then
            error('fields_types('..typesKeys..') ~= fields_parsers('..fieldsKeys..')')
        end
        local pretendString = {}
        for fName, fType in pairs(fields_types) do
            local elem_parser = fields_parsers[fName]
            if type(fType) ~= 'string' then
                error('fields_types['..fName..'] must be a string: '..type(fType))
            end
            if type(elem_parser) ~= 'function' then
                error('fields_parsers['..fName..'] must be a function: '..
                    type(elem_parser))
            end
            pretendString[fName] = state.FORCE_REFORMATTED_AS_STRING[utils.resolve(fType)]
        end
        state.RECORD_PARSERS[cache_key] = function (badVal, value, context)
            --{<name1>:<type1>,<name2>:<type2>,...}
            local parsed, str = utils.table_parser(badVal, 'record', value)
            if not parsed then
                utils.log(badVal, 'record', value, "value cannot be parsed")
                return nil, str
            end
            local before = badVal.errors
            local parsed_copy = {}
            local ref_copy = {}
            local fail = false
            for k, v in pairs(parsed) do
                local fp = fields_parsers[k]
                if fp then
                    if parsed_copy[k] ~= nil then
                        utils.log(badVal, 'record', value, "Duplicate field: "..k)
                        fail = true
                    else
                        local parsed_v, reformatted_v = M.callParser(fp, badVal,
                            v, 'parsed')
                        if badVal.errors == before then
                            parsed_copy[k] = parsed_v
                            ref_copy[k] = utils.quoteIfNeeded(parsed_v, reformatted_v,
                                pretendString[k])
                        else
                            fail = true
                        end
                    end
                else
                    utils.log(badVal, 'record', value, "Unknown field: "..k)
                    fail = true
                end
            end
            if fail then
                return nil, str
            end
            return parsed_copy, utils.serializeTableWithoutCB(ref_copy)
        end
    end
    return state.RECORD_PARSERS[cache_key]
end

-- Registers an enum parser. Takes a list of labels,
-- which must be case-insensitive-unique, and returns the parser.
function M.registerEnumParserInternal(badVal, enum_labels)
    if type(enum_labels) ~= 'table' then
        utils.log(badVal, 'enum_labels',
        enum_labels, 'enum_labels must be a table string: '..type(enum_labels))
        return nil
    end
    local lower_2_enum = {}
    local fail = false
    for _, e in ipairs(enum_labels) do
        if type(e) ~= 'string' then
            utils.log(badVal, 'enum_label', e,
                'enum_labels[i] must be a string: '..type(e))
            fail = true
        elseif not isIdentifier(e) then
            utils.log(badVal, 'enum_label', e,
                'enum_labels[i] must be an identifier: '..e)
            fail = true
        else
            local l = e:lower()
            if isValueKeyword(l) then
                utils.log(badVal, 'enum_label', e,
                    'enum_labels[i] cannot be a keyword: '..e)
                fail = true
            elseif isReservedName(l) then
                utils.log(badVal, 'enum_label', e,
                    'enum_labels[i] cannot be a reserved name: '..e)
                fail = true
            elseif isTupleFieldName(l) then
                utils.log(badVal, 'enum_label', e,
                    'enum_labels[i] is reserved for tuples: '..e)
                fail = true
            elseif lower_2_enum[l] then
                utils.log(badVal, 'enum_label', e,
                    'enum_labels[i] must be unique: '..e)
                fail = true
            else
                lower_2_enum[l] = e
            end
        end
    end
    if fail then
        return nil
    end
    -- keys() sort, and since it's all lower-case, sortCaseInsensitive is not needed
    local copy = keys(lower_2_enum)
    local labels = '{enum:' .. table.concat(copy, "|")..'}'
    if state.PARSERS[labels] then
        -- Since we start labels with enum: we assume any parser with that name
        -- is the same as this one
        return labels
    end
    local lc = pairsCount(lower_2_enum)
    if #copy ~= lc then
        utils.log(badVal, 'enum_labels', enum_labels,
            '#enum_labels('..#enum_labels..') ~= #lower_2_enum('..lc..')')
        return nil
    end
    state.PARSERS[labels] = function (badVal2, value, context)
        utils.expectTSV(context) -- Just for side-effects
        if type(value) == 'string' then
            local mapped = lower_2_enum[value:lower()]
            if mapped then
                return mapped, mapped
            end
        end
        utils.log(badVal2, labels, value)
        return nil, tostring(value)
    end
    state.NEVER_TABLE[labels] = true
    M.registerComparator(labels, state.COMPARATORS.string)
    return labels
end

return M
