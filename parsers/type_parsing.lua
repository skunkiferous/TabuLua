-- parsers/type_parsing.lua
-- Core type specification parsing logic

local state = require("parsers.state")
local utils = require("parsers.utils")
local lpeg_parser = require("parsers.lpeg_parser")
local generators = require("parsers.generators")

local comparators = require("comparators")
local genSeqComparator = comparators.genSeqComparator
local genTableComparator = comparators.genTableComparator
local composeComparator = comparators.composeComparator

local table_utils = require("table_utils")
local keys = table_utils.keys

local predicates = require("predicates")
local isIdentifier = predicates.isIdentifier
local isValueKeyword = predicates.isValueKeyword
local isReservedName = predicates.isReservedName
local isTupleFieldName = predicates.isTupleFieldName

local error_reporting = require("error_reporting")
local nullBadVal = error_reporting.nullBadVal

local serialization = require("serialization")
local serialize = serialization.serialize

local M = {}

-- Forward declaration for mutual recursion
local parse_type

-- Parses a "array" type specification, and returns a parser, or nil if invalid
local function parse_type_array(badVal, xparsed, type_spec)
    local result = nil
    local elem_type = xparsed.value
    local parser = parse_type(badVal, elem_type)
    if parser then
        local et = utils.serializeType(elem_type)
        result = generators.get_array_parser(et, parser)
        generators.registerComparator(type_spec,
            genSeqComparator(generators.getCompInternal(et)))
    end
    return result
end

-- Parses a "tuple" type specification, and returns a parser, or nil if invalid
local function parse_type_tuple(badVal, xparsed, type_spec)
    local parsed = xparsed.value
    local result = nil
    local errors_before = badVal.errors
    local fields_parsers = {}
    local copy = {}
    local comps = {}
    local start_index = 1
    if #parsed >= 1 and type(parsed[1]) == "table" and parsed[1].tag == "name"
        and parsed[1].value == "extends" then
        if #parsed == 2 then
            -- Bare extends: {extends,<ancestor>}
            -- Values must be type names extending the ancestor
            local ancestor_spec = utils.serializeType(parsed[2])
            local type_spec_parser = state.refs.parseType(badVal, 'type_spec')
            if not type_spec_parser then return nil end
            local ancestor_parser = state.refs.parseType(badVal, ancestor_spec)
            if not ancestor_parser then
                utils.log(badVal, 'extends', type_spec,
                    "ancestor type does not exist: " .. ancestor_spec)
                return nil
            end
            result = function(badVal2, value, context)
                local parsed_val, reformatted = generators.callParser(
                    type_spec_parser, badVal2, value, context)
                if parsed_val == nil then return nil, reformatted end
                if parsed_val ~= ancestor_spec
                    and not state.refs.extendsOrRestrict(parsed_val, ancestor_spec) then
                    utils.log(badVal2, type_spec, value,
                        "'" .. tostring(parsed_val)
                        .. "' is not a type that extends " .. ancestor_spec)
                    return nil, reformatted
                end
                return parsed_val, reformatted
            end
            generators.registerComparator(type_spec,
                generators.getCompInternal('type_spec'))
            state.NEVER_TABLE[type_spec] = true
            return result, type_spec, xparsed
        elseif #parsed < 3 then
            utils.log(badVal, 'extends', type_spec,
            "extends in tuple requires length of at least 3")
            return nil
        end
        local parsed_parent = parsed[2]
        local parent_spec = utils.serializeType(parsed_parent)
        if state.refs.getTypeKind(parent_spec) ~= "tuple" then
            utils.log(badVal, 'extends', type_spec,
            "extends in tuple requires a tuple parent")
            return nil
        end
        -- Get parent tuple field types
        local parent_field_types = state.refs.tupleFieldTypes(parent_spec)
        if not parent_field_types then
            utils.log(badVal, 'extends', type_spec,
            "failed to get parent tuple field types")
            return nil
        end
        -- Add parent fields first
        for i, parent_type in ipairs(parent_field_types) do
            fields_parsers[i] = state.refs.parseType(badVal, parent_type)
            copy[i] = parent_type
            comps[i] = generators.getCompInternal(parent_type)
        end
        -- Skip the "extends" keyword and parent type
        start_index = 3
    end
    -- Process remaining types (starting from start_index)
    for i = start_index, #parsed do
        local field_index = #fields_parsers + 1
        local ti = parsed[i]
        copy[field_index] = utils.serializeType(ti)
        fields_parsers[field_index] = parse_type(badVal, ti, false)
        if fields_parsers[field_index] == nil then
            utils.log(badVal, 'type', copy[field_index], "unknown/bad type")
            return nil
        end
        comps[field_index] = generators.getCompInternal(copy[field_index])
    end
    if errors_before == badVal.errors then
        local orig_type_spec = type_spec
        if start_index ~= 1 then
            type_spec = '{' .. table.concat(copy, ",") .. '}'
            xparsed = lpeg_parser.type_parser(type_spec)
        end
        result = generators.get_tuple_parser(copy, fields_parsers)
        generators.registerComparator(type_spec, composeComparator(comps))
        if orig_type_spec ~= type_spec then
            state.COMPARATORS[orig_type_spec] = state.COMPARATORS[type_spec]
        end
    end
    return result, type_spec, xparsed
end

-- Parses a "union" type specification, and returns a parser, or nil if invalid
-- The order of types in the union is important, because some types match more than others.
-- So, the most specific types should come first, so that it gets a chance to match first.
local function parse_type_union(badVal, xparsed, type_spec)
    local parsed = xparsed.value
    local result = nil
    local errors_before = badVal.errors
    local fields_parsers = {}
    local str_idx = -1
    local nil_idx = -1
    local neverTable = true
    local copy = {}
    for i, ti in ipairs(parsed) do
        local eb = badVal.errors
        fields_parsers[i] = parse_type(badVal, ti)
        if fields_parsers[i] == nil then
            assert(badVal.errors > eb, "on error, at least one badVal must be logged: "
                .. type_spec)
            return nil
        end
        copy[i] = lpeg_parser.parsedTypeSpecToStr(ti)
        if not state.NEVER_TABLE[copy[i]] then
            neverTable = false
        end
        if copy[i] == "string" then
            str_idx = i
        end
        if copy[i] == "nil" then
            nil_idx = i
        end
    end
    if nil_idx ~= -1 then
        if nil_idx ~= #copy then
            utils.log(badVal, 'union', type_spec, "nil must be last")
        end
    end
    if str_idx ~= -1 then
        if (nil_idx == -1 and str_idx ~= #copy) or (nil_idx ~= -1 and str_idx ~= #copy - 1) then
            utils.log(badVal, 'union', type_spec,
                "string must be last (or before nil)")
        end
    end
    if errors_before == badVal.errors then
        result = generators.get_union_parser(copy, fields_parsers)
        if neverTable then
            state.NEVER_TABLE[type_spec] = true
        end
        if nil_idx ~= -1 then
            state.OPTIONAL[type_spec] = true
        end
        if nil_idx ~= -1 and #parsed == 2 then
            -- nil or exactly one specific type; we can handle that cleanly
            local other_type = copy[3 - nil_idx]
            local other_cmp = generators.getCompInternal(other_type)
            generators.registerComparator(type_spec, function (a, b)
                if a == nil then
                    return b ~= nil
                end
                if b == nil then
                    return false
                end
                return other_cmp(a, b)
            end)
        else
            generators.registerComparator(type_spec, function (a, b)
                -- a and b could be anything
                if a == b then
                    return false
                end
                if a == nil then
                    return true
                elseif b == nil then
                    return false
                end
                return state.COMPARATORS.string(serialize(a), serialize(b))
            end)
        end
    end
    return result
end

-- Parses a "enum" type specification, and returns a parser, or nil if invalid
local function parse_type_enum_union(badVal, parsed_union)
    local labels = {}
    local fail = false
    for i, ti in ipairs(parsed_union) do
        if ti.tag == "name" then
            labels[i] = ti.value
        else
            utils.log(badVal, 'name', ti.value, "enum label must be a name")
            fail = true
        end
    end
    if fail then
        return nil
    end
    local type_spec = generators.registerEnumParserInternal(badVal, labels)
    if type_spec then
        return state.PARSERS[type_spec]
    end
    return nil
end

-- Parses a "enum" type specification, and returns a parser, or nil if invalid
local function get_enum_parser(badVal, parsed, type_spec)
    -- An enum is defined as exactly one key-value pair, where key is 'enum' and value
    -- is a 'union' of labels
    local i = 1
    local result = nil
    for key_type, value_type in pairs(parsed) do
        if i == 1 then
            local kt = utils.serializeType(key_type)
            if kt == "enum" then
                if value_type.tag == "union" then
                    result = parse_type_enum_union(badVal, value_type.value)
                else
                    utils.log(badVal, 'enum', type_spec,
                        "enum value should be a union")
                    result = nil
                    break
                end
            else
                utils.log(badVal, 'enum', type_spec,
                    "enum key should be 'enum'")
                result = nil
                break
            end
            i = i + 1
        else
            utils.log(badVal, 'enum', type_spec,
                "enum expected to be exactly one key-value pair")
            result = nil
            break
        end
    end
    return result
end

-- Forward declaration for isNeverTable (needed by parse_type_map)
local isNeverTable

-- Parses a "map" type specification, and returns a parser, or nil if invalid
local function parse_type_map(badVal, xparsed, type_spec)
    local parsed = xparsed.value
    -- A map is defined as exactly one key-value pair, where key and value are types
    local i = 1
    local result = nil
    for key_type, value_type in pairs(parsed) do
        if i == 1 then
            local kt = utils.serializeType(key_type)
            if kt == "enum" then
                return get_enum_parser(badVal, parsed, type_spec)
            elseif kt == "extends" then
                -- Bare extends in record syntax: {extends:<type>}
                -- Normalize to tuple form {extends,<type>} and delegate
                local ancestor_spec = utils.serializeType(value_type)
                local normalized = "{extends," .. ancestor_spec .. "}"
                local norm_result = state.refs.parseType(badVal, normalized)
                if norm_result then
                    state.COMPARATORS[type_spec] = state.COMPARATORS[normalized]
                    state.NEVER_TABLE[type_spec] = true
                end
                return norm_result
            else
                local key_parse, key_spec = parse_type(badVal, key_type)
                if not isNeverTable(key_spec) then
                    utils.log(badVal, 'type', key_spec,
                    "map key_type can never be a table")
                    break
                end
                local value_parse, value_spec = parse_type(badVal, value_type)
                if key_parse and value_parse then
                    local vt = utils.serializeType(value_type)
                    if key_parse == state.PARSERS['nil'] or state.nilUnions[key_parse] then
                        utils.log(badVal, 'type', key_spec,
                        "map key_type can never be nil")
                        break
                    end
                    if value_parse == state.PARSERS['nil'] or state.nilUnions[value_parse] then
                        utils.log(badVal, 'type', value_spec,
                        "map value_type can never be nil")
                        break
                    end
                    result = generators.get_map_parser(kt, vt, key_parse, value_parse)
                    generators.registerComparator(type_spec,
                        genTableComparator(generators.getCompInternal(key_spec),
                        generators.getCompInternal(value_spec)))
                end
            end
            i = i + 1
        else
            utils.log(badVal, 'map', type_spec,
                "map expected to be exactly one key-value pair")
            result = nil
            break
        end
    end
    return result
end

-- Forward declarations for record parsing
local recordFieldNames
local recordFieldTypes

-- Process the "extends" part of a "record" type specification
local function parse_type_extends_record(badVal, copy, fields_parsers, type_spec)
    local parent_spec = copy['extends']
    copy['extends'] = nil
    fields_parsers['extends'] = nil -- No need
    local parent_field_names = recordFieldNames(parent_spec)
    local parent_field_types = recordFieldTypes(parent_spec)
    if not parent_field_names or not parent_field_types then
        utils.log(badVal, 'extends', type_spec,
            "parent type is not record: "..utils.serializeType(parent_spec))
        return nil
    end
    for j = 1, #parent_field_names do
        local name = parent_field_names[j]
        local parent_type = parent_field_types[name]
        if copy[name] then
            utils.log(badVal, 'record', type_spec,
                "field name '" .. name .. "' conflicts with parent type")
            return nil
        end
        copy[name] = parent_type
        local fields_parser = state.refs.parseType(badVal, parent_type)
        fields_parsers[name] = fields_parser
    end
end

-- Parses a "record" type specification, and returns a parser, or nil if invalid
local function parse_type_record(badVal, xparsed, type_spec)
    local parsed = xparsed.value
    local result = nil
    local errors_before = badVal.errors
    local fields_parsers = {}
    local copy = {}
    local fail = false
    local extends = false
    for _, kv in ipairs(parsed) do
        if type(kv) ~= "table" then
            utils.log(badVal, 'name:type', kv,
                "record should be a list of name:type pairs")
            fail = true
        else
            local key_type = kv.key
            if type(key_type) ~= "table" or (key_type.tag ~= "name") then
                utils.log(badVal, 'name', key_type,
                    "record expected 'keys' to be a 'identifiers'")
                fail = true
            else
                local value_type = kv.value
                local be = badVal.errors
                local value_val = parse_type(badVal, value_type)
                local logged_problem = badVal.errors ~= be
                if value_val then
                    local field_name = key_type.value
                    if isIdentifier(field_name) then
                        if isValueKeyword(field_name) then
                            utils.log(badVal, 'record', type_spec,
                                "field name cannot be a keyword: "..field_name)
                            fail = true
                        elseif isReservedName(field_name) then
                            utils.log(badVal, 'record', type_spec,
                                "field name cannot be a reserved name: "..field_name)
                            fail = true
                        elseif isTupleFieldName(field_name) then
                            utils.log(badVal, 'record', type_spec,
                                "field name is reserved for tuples: "..field_name)
                            fail = true
                        else
                            fields_parsers[field_name] = value_val
                            copy[field_name] = utils.serializeType(value_type)
                            if field_name == "extends" then
                                extends = true
                            end
                        end
                    else
                        utils.log(badVal, 'record', type_spec,
                            "field name must be an identifier: "..field_name)
                        fail = true
                    end
                else
                    if not logged_problem then
                        utils.log(badVal, 'record', type_spec,
                            "field type is invalid: "..utils.serializeType(value_type))
                    end
                    fail = true
                end
            end
        end
    end
    if (errors_before == badVal.errors) and not fail then
        if extends then
            parse_type_extends_record(badVal, copy, fields_parsers, type_spec)
        end
        if errors_before == badVal.errors then
            local field_names = keys(copy)
            local comps = {}
            for i, fname in ipairs(field_names) do
                comps[i] = generators.getCompInternal(copy[fname])
            end
            local valuesCmp = composeComparator(comps)
            local orig_type_spec = type_spec
            if extends then
                local copy2 = {}
                local sep = "{"
                for key, value in pairs(copy) do
                    copy2[#copy2+1] = sep
                    sep = ","
                    copy2[#copy2+1] = key
                    copy2[#copy2+1] = ":"
                    copy2[#copy2+1] = value
                end
                copy2[#copy2+1] = "}"
                type_spec = table.concat(copy2)
                xparsed = lpeg_parser.type_parser(type_spec)
            end
            result = generators.get_record_parser(copy, fields_parsers, type_spec)
            generators.registerComparator(type_spec, function(r1, r2)
                local t1 = {}
                local t2 = {}
                for i, fname in ipairs(field_names) do
                    t1[i] = r1[fname]
                    t2[i] = r2[fname]
                end
                return valuesCmp(t1, t2)
            end)
            if orig_type_spec ~= type_spec then
                state.COMPARATORS[orig_type_spec] = state.COMPARATORS[type_spec]
            end
        end
    end
    return result, type_spec, xparsed
end

-- Informs about usage of "number" type (prefer "float" or "integer" for most cases)
local function warnDontUseNumber(badVal, type_spec, orig_type_spec)
    -- Only inform after module setup is complete (not during initialization)
    if state.settingUp then
        return
    end
    -- Only inform once per unique type specification
    if state.WARNED_TYPES[orig_type_spec] then
        return
    end
    -- Check if the resolved type is exactly "number"
    local resolved = utils.resolve(type_spec)
    if resolved == "number" then
        state.WARNED_TYPES[orig_type_spec] = true
        local source = badVal.source_name
        if not source or source == "" then source = "?" end
        state.logger:info("Using 'number' type in '" .. orig_type_spec
            .. "' in " .. source
            .. ". 'float' is preferred for decimal values (integers are formatted as N.0);"
            .. " 'number' allows mixed integer/decimal formatting.")
    end
end

-- Parses a type specification, and returns a parser, or nil if invalid
parse_type = function(badVal, parsed, log_unknown)
    if type(parsed) ~= 'table' then
        error("Bad parsed, not a table: " .. type(parsed))
    end
    if log_unknown == nil then
        log_unknown = true
    end
    local type_spec = lpeg_parser.parsedTypeSpecToStr(parsed)
    local orig_type_spec = type_spec
    local result = state.PARSERS[utils.resolve(type_spec)]
    if result then
        -- Type already exists in cache, check for deprecated usage
        warnDontUseNumber(badVal, type_spec, orig_type_spec)
    end
    if not result then
        if state.UNKNOWN_TYPES[type_spec] then
            return nil
        end
        -- Is this a collection type? "string" parsed types should already be in PARSERS
        local tmp_result = nil
        local tmp_type_spec = nil
        local tmp_parsed = nil
        local tag = parsed.tag
        local before = badVal.errors
        if tag == "name" then
            type_spec = parsed.value
            tmp_result = state.PARSERS[utils.resolve(type_spec)]
            if tmp_result then
                warnDontUseNumber(badVal, type_spec, orig_type_spec)
            end
        elseif tag == "array" then
            tmp_result = parse_type_array(badVal, parsed, type_spec)
        elseif tag == "tuple" then
            tmp_result, tmp_type_spec, tmp_parsed =
                parse_type_tuple(badVal, parsed, type_spec)
        elseif tag == "union" then
            tmp_result = parse_type_union(badVal, parsed, type_spec)
        elseif tag == "map" then
            tmp_result = parse_type_map(badVal, parsed, type_spec)
        elseif tag == "record" then
            tmp_result, tmp_type_spec, tmp_parsed =
                parse_type_record(badVal, parsed, type_spec)
        elseif tag == "table" then
            type_spec = "{}"
            tmp_result = state.PARSERS["table"]
        elseif tag then
            error("Bad type tag: " .. tostring(tag))
        else
            error("Bad parsed: " .. type_spec)
        end

        if tmp_result then
            assert(type(tmp_result) == 'function', "Bad parser: " ..
                type(tmp_result).." for "..orig_type_spec)
            result = tmp_result
            if tmp_type_spec and tmp_parsed and type_spec ~= tmp_type_spec then
                parsed = tmp_parsed
            end
            type_spec = lpeg_parser.parsedTypeSpecToStr(parsed, true)
            if state.COMPARATORS[type_spec] == nil then
                state.COMPARATORS[type_spec] = state.COMPARATORS[orig_type_spec]
            end
            state.PARSERS[type_spec] = result
            assert(state.COMPARATORS[type_spec] ~= nil, "Missing comparator: "..orig_type_spec)
        else
            if tag == "name" then
                if log_unknown then
                    utils.log(badVal, 'type', orig_type_spec, "unknown/bad type")
                end
            elseif before == badVal.errors then
                utils.log(badVal, 'type', orig_type_spec, "unknown problem")
            end
            state.UNKNOWN_TYPES[type_spec] = true
        end
    end
    -- Note: bare extends type specs like {extends,number} are valid and start with '{extends'
    return result, type_spec
end

-- Parses a type specification, and returns a parser, or nil if invalid
-- badVal is used to log the problem(s), if the specification is invalid
-- type_spec must be a string, which specifies the type of the values
function M.parseType(badVal, type_spec, log_unknown)
    if log_unknown == nil then
        log_unknown = true
    end
    if type(type_spec) ~= "string" then
        utils.log(badVal, 'type', type_spec,
            "Type specification must be a string: "..type(type_spec))
        return nil
    end
    local parsed = lpeg_parser.type_parser(type_spec)
    if not parsed then
        utils.log(badVal, 'type', type_spec, "Cannot parse type specification")
        return nil
    end
    return parse_type(badVal, parsed, log_unknown)
end

-- Returns the names of the fields of a record type. Returns nil if not a record type
recordFieldNames = function(type_spec)
    if type(type_spec) ~= "string" then
        return nil
    end
    type_spec = utils.resolve(type_spec)
    local parsed = lpeg_parser.type_parser(type_spec)
    if not parsed then
        return nil
    end
    if parsed.tag ~= "record" then
        return nil
    end
    local result = {}
    for _, f in ipairs(parsed.value) do
        table.insert(result, f.key.value)
    end
    table.sort(result)
    return result
end

-- Maps the fields of a record type to their type specs. Returns nil if not a (valid) record type
recordFieldTypes = function(type_spec)
    if type(type_spec) ~= "string" then
        return nil
    end
    type_spec = utils.resolve(type_spec)
    local parsed = lpeg_parser.type_parser(type_spec)
    if not parsed then
        return nil
    end
    if parsed.tag ~= "record" then
        return nil
    end
    -- Uses side-effect of type validation
    local parser, _ = parse_type(nullBadVal, parsed)
    if parser == nil then
        -- Bad type_spec
        return nil
    end
    local result = {}
    for _, f in ipairs(parsed.value) do
        local fts = lpeg_parser.parsedTypeSpecToStr(f.value)
        result[f.key.value] = fts
    end
    return result
end

-- Returns true, if this type never parses to a table.
isNeverTable = function(type_spec)
    local parsed = lpeg_parser.type_parser(type_spec)
    if not parsed then
        return false
    end
    -- Uses side-effect of type validation
    parse_type(nullBadVal, parsed)
    type_spec = utils.resolve(lpeg_parser.parsedTypeSpecToStr(parsed))
    return state.NEVER_TABLE[type_spec] or false
end

-- Export functions
M.parse_type = parse_type
M.recordFieldNames = recordFieldNames
M.recordFieldTypes = recordFieldTypes
M.isNeverTable = isNeverTable

return M
