-- parsers/introspection.lua
-- Type introspection and relationship analysis functions

local state = require("parsers.state")
local utils = require("parsers.utils")
local lpeg_parser = require("parsers.lpeg_parser")

local table_utils = require("table_utils")
local keys = table_utils.keys

local sparse_sequence = require("sparse_sequence")
local isSubSetSequence = sparse_sequence.isSubSetSequence

local error_reporting = require("error_reporting")
local nullBadVal = error_reporting.nullBadVal

local M = {}

-- Forward declarations (set by init.lua after type_parsing loads)
local parse_type
local parseType

-- Set parse_type reference (called by init.lua)
function M.setParseType(pt, pT)
    parse_type = pt
    parseType = pT
end

-- Returns the names of the fields of a record type. Returns nil if not a record type
function M.recordFieldNames(type_spec)
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

-- Returns the names of the *optional* fields of a record type. Returns an empty table if all
-- fields are required. Returns nil if not a record type
function M.recordOptionalFieldNames(type_spec)
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
    parse_type(nullBadVal, parsed)
    local result = {}
    for _, f in ipairs(parsed.value) do
        local ts = lpeg_parser.parsedTypeSpecToStr(f.value)
        if state.OPTIONAL[ts] then
            table.insert(result, f.key.value)
        end
    end
    table.sort(result)
    return result
end

-- Maps the fields of a record type to their type specs. Returns nil if not a (valid) record type
function M.recordFieldTypes(type_spec)
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

-- Breaks a "tuple" type specification, into a list of types, or nil if not a valid tuple type
function M.tupleFieldTypes(type_spec)
    if type(type_spec) ~= "string" then
        return nil
    end
    type_spec = utils.resolve(type_spec)
    local parsed = lpeg_parser.type_parser(type_spec)
    if not parsed or parsed.tag ~= "tuple" then
        return nil
    end
    -- Uses side-effect of type validation
    local parser, _ = parse_type(nullBadVal, parsed)
    if parser == nil then
        -- Bad type_spec
        return nil
    end
    local result = {}
    for i, f in ipairs(parsed.value) do
        local fts = lpeg_parser.parsedTypeSpecToStr(f)
        result[i] = fts
    end
    return result
end

-- Looks at an "array" type specification, and returns the element type, or nil if not a valid
-- array type
function M.arrayElementType(type_spec)
    if type(type_spec) ~= "string" then
        return nil
    end
    type_spec = utils.resolve(type_spec)
    local parsed = lpeg_parser.type_parser(type_spec)
    if not parsed or parsed.tag ~= "array" then
        return nil
    end
    -- Uses side-effect of type validation
    local parser, _ = parse_type(nullBadVal, parsed)
    if parser == nil then
        -- Bad type_spec
        return nil
    end
    return lpeg_parser.parsedTypeSpecToStr(parsed.value)
end

-- Looks at a "map" type specification, and returns the key and value types, or nil if not a valid
-- map type
function M.mapKVType(type_spec)
    if type(type_spec) ~= "string" then
        return nil
    end
    type_spec = utils.resolve(type_spec)
    local parsed = lpeg_parser.type_parser(type_spec)
    if not parsed or parsed.tag ~= "map" then
        return nil
    end
    -- Uses side-effect of type validation
    local parser, _ = parse_type(nullBadVal, parsed)
    if parser == nil then
        -- Bad type_spec
        return nil
    end
    local i = 1
    for key_type, value_type in pairs(parsed.value) do
        if i == 1 then
            i = i + 1
            local kt = lpeg_parser.parsedTypeSpecToStr(key_type)
            local vt = lpeg_parser.parsedTypeSpecToStr(value_type)
            return kt, vt
        end
    end
    error("Map type_spec " .. type_spec .. " not exactly parsed to one KV pair")
end

-- Returns true, if this type never parses to a table.
function M.isNeverTable(type_spec)
    local parsed = lpeg_parser.type_parser(type_spec)
    if not parsed then
        return false
    end
    -- Uses side-effect of type validation
    parse_type(nullBadVal, parsed)
    type_spec = utils.resolve(lpeg_parser.parsedTypeSpecToStr(parsed))
    return state.NEVER_TABLE[type_spec] or false
end

-- Returns the "parent" of a type, if it extends another one.
function M.typeParent(type_spec)
    if type(type_spec) ~= "string" then
        return nil
    end
    local result = state.ALIASES[type_spec]
    if not result then
        result = state.EXTENDS[type_spec]
        if not result then
            local parsed = lpeg_parser.type_parser(type_spec)
            if parsed then
                local t = parsed.tag
                if t == "map" then
                    for key_type in pairs(parsed.value) do
                        local kt = utils.serializeType(key_type)
                        if kt == "enum" then
                            return "enum"
                        end
                    end
                    return t
                end
                if t == "array" or t == "tuple" or t == "record" or t == "union" or t == "table" then
                    return t
                end
            end
        end
    end
    return result
end

-- Returns the fundamental structural kind of a given type specification
-- after resolving all type aliases and parent relationships.
function M.getTypeKind(type_spec)
    if type(type_spec) ~= "string" then
        return nil
    end

    -- Handle obvious special cases
    if type_spec == "{}" or type_spec == "table" then
        return "table"
    end

    -- Try to parse the type specification
    local parsed = lpeg_parser.type_parser(type_spec)
    if not parsed then
        return nil
    end

    -- If it's a name, try to resolve it to a more specific category
    if parsed.tag == "name" then
        local name = parsed.value
        -- Check if it's an alias
        local alias = state.ALIASES[name]
        if alias then
            -- Recursively resolve alias
            return M.getTypeKind(alias)
        end

        -- Check if it extends something
        local parent = M.typeParent(name)
        if parent and parent ~= name then
            -- Recursively resolve parent
            return M.getTypeKind(parent)
        end

        if state.PARSERS[name] ~= nil then
            -- Cannot resolve further - it's a basic type
            return "name", name
        end

        return nil
    end

    -- For maps, check if it's actually an enum
    if parsed.tag == "map" then
        for key_type, value_type in pairs(parsed.value) do
            local kt = lpeg_parser.parsedTypeSpecToStr(key_type)
            if kt == "enum" and value_type.tag == "union" then
                return "enum"
            end
            break  -- Only need to check the first (and only) key-value pair
        end
    end

    -- For other non-name types, the tag directly indicates the category
    return parsed.tag
end

-- Breaks an "enum" type specification, into a sorted list of labels, or nil if not a valid enum
-- type
function M.enumLabels(type_spec)
    if type(type_spec) ~= "string" then
        return nil
    end
    type_spec = utils.resolve(type_spec)
    local originalParser = parseType(nullBadVal, type_spec)
    if not originalParser then
        return nil
    end
    local parsed = lpeg_parser.type_parser(type_spec)
    if parsed and parsed.tag == "map" then
        for key_type, value_type in pairs(parsed.value) do
            local kt = utils.serializeType(key_type)
            if kt == "enum" then
                if value_type.tag == "union" then
                    local labels = {}
                    for i, ti in ipairs(value_type.value) do
                        if ti.tag == "name" then
                            labels[i] = ti.value
                        else
                            return nil
                        end
                    end
                    local copy = {}
                    for _, el in ipairs(labels) do
                        copy[el:lower()] = true
                    end
                    copy = keys(copy)
                    return copy
                end
            end
            break
        end
    end
    return nil
end

-- Breaks an "union" type specification, into a list of types, or nil if not a valid union type
function M.unionTypes(type_spec)
    if type(type_spec) ~= "string" then
        return nil
    end
    type_spec = utils.resolve(type_spec)
    local originalParser = parseType(nullBadVal, type_spec)
    if not originalParser then
        return nil
    end
    local parsed = lpeg_parser.type_parser(type_spec)
    if parsed and parsed.tag == "union" then
        local types = {}
        for i, ti in ipairs(parsed.value) do
            types[i] = lpeg_parser.parsedTypeSpecToStr(ti)
        end
        return types
    end
    return nil
end

-- Returns the name or type specification of all currently registered parsers
function M.getRegisteredParsers()
    return keys(state.PARSERS)
end

-- Returns true, if the given type specification is a built-in type
function M.isBuiltInType(type_spec)
    return state.BUILT_IN[type_spec] or false
end

-- Returns true, if the child field type is "compatible" with the parent field type.
local function typeSameOrExtends(child, parent)
    return (child == parent) or state.refs.extendsOrRestrict(child, parent)
end

-- Resolves the effective base type of a self-ref field for subtype checking.
-- containerFields is the full field types table of the child (tuple array or record map).
-- Returns the ancestor type, or nil if unresolvable.
local function resolveSelfRefForExtends(selfRefSpec, containerFields)
    local ref_field = selfRefSpec:match("^self%.(.+)$")
    if not ref_field then return nil end
    local ref_type
    -- For tuples: _N -> index N
    local idx = ref_field:match("^_(%d+)$")
    if idx then
        ref_type = containerFields[tonumber(idx)]
    else
        -- For records
        ref_type = containerFields[ref_field]
    end
    if not ref_type then return nil end
    -- Extract ancestor from {extends,X} or {extends:X}
    local resolved = utils.resolve(ref_type)
    local ancestor = resolved:match("^{extends[,:](.+)}$")
    if ancestor then return ancestor end
    -- type/type_spec -> string (type names are strings; used as comparator fallback)
    if resolved == 'type' or resolved == 'type_spec' or resolved == 'name' then
        return 'string'
    end
    -- Type tags
    if state.TAG_ANCESTOR[resolved] then
        return state.TAG_ANCESTOR[resolved]
    end
    return nil
end

-- Returns true, if childFields contains all the fields of parentFields,
-- with the same types as in parentFields
local function childRecordExtendsParent(childFields, parentFields)
    if not childFields or not parentFields then
        return false
    end
    for k, v in pairs(parentFields) do
        local childType = childFields[k]
        if not childType then
            return false
        end
        if childType:sub(1, 5) == "self." then
            local baseType = resolveSelfRefForExtends(childType, childFields)
            if not baseType or not typeSameOrExtends(baseType, v) then
                return false
            end
        elseif not typeSameOrExtends(childType, v) then
            return false
        end
    end
    return true
end

-- Returns true, if childFields contains all the fields of parentFields,
-- with the same types as in parentFields
local function childTupleExtendsParent(childFields, parentFields)
    if not childFields or not parentFields then
        return false
    end
    if #childFields < #parentFields then
        return false
    end
    for i, t in pairs(parentFields) do
        local childType = childFields[i]
        if childType:sub(1, 5) == "self." then
            local baseType = resolveSelfRefForExtends(childType, childFields)
            if not baseType or not typeSameOrExtends(baseType, t) then
                return false
            end
        elseif not typeSameOrExtends(childType, t) then
            return false
        end
    end
    return true
end

-- Returns true, if childUTypes only contains types in parentUTypes,
-- or child is a single type equal to one of the parent types,
-- or all child union members extend the (non-union) parent type,
-- or child (non-union) extends one of the non-nil members of a parent union.
local function childUnionExtendsParent(childUTypes, parentUTypes, child, parent)
    if childUTypes then
        if parentUTypes then
            if isSubSetSequence(parentUTypes, childUTypes, true) then
                return true
            end
        else
            -- Union extends a non-union parent if ALL members extend that parent
            local allExtend = true
            for i = 1, #childUTypes do
                if not typeSameOrExtends(childUTypes[i], parent) then
                    allExtend = false
                    break
                end
            end
            if allExtend then return true end
        end
    end
    if parentUTypes then
        -- child (non-union) is compatible with a parent union if it equals or extends
        -- any member of that union. This handles cases like float extending number|nil,
        -- or a child narrowing an optional field (T|nil) to a required subtype (T).
        for i = 1, #parentUTypes do
            if typeSameOrExtends(child, parentUTypes[i]) then
                return true
            end
        end
    end
    return false
end

-- Checks if child is a transitive member of parent tag (following nested tag memberships).
-- Uses a visited set to prevent infinite loops in case of cycles.
local function isTransitiveTagMember(parent, child, visited)
    local members = state.TAG_MEMBERS[parent]
    if not members then return false end
    if members[child] then return true end
    if not visited then visited = {} end
    visited[parent] = true
    for member, _ in pairs(members) do
        if state.TAG_MEMBERS[member] and not visited[member]
            and isTransitiveTagMember(member, child, visited) then
            return true
        end
    end
    return false
end

-- Returns true, if the child type extends the parent type.
function M.extendsOrRestrict(child, parent)
    local pc = M.typeParent(child)
    if pc then
        if pc == parent or pc == state.ALIASES[parent] then
            return true
        end
        if pc == child then
            error("Type cannot extend itself: " .. child)
        end
    end
    -- Check type tag membership (child is a member of parent tag, directly or transitively)
    if isTransitiveTagMember(parent, child) then
        return true
    end
    local childRFields = M.recordFieldTypes(child)
    local parentRFields = M.recordFieldTypes(parent)
    if childRecordExtendsParent(childRFields, parentRFields) then
        return true
    end
    local childTFields = M.tupleFieldTypes(child)
    local parentTFields = M.tupleFieldTypes(parent)
    if childTupleExtendsParent(childTFields, parentTFields) then
        return true
    end
    local childELabels = M.enumLabels(child)
    local parentELabels = M.enumLabels(parent)
    if childELabels then
        if isSubSetSequence(parentELabels, childELabels) then
            return true
        end
    end
    local childUTypes = M.unionTypes(child)
    local parentUTypes = M.unionTypes(parent)
    if childUnionExtendsParent(childUTypes, parentUTypes, child, parent) then
        return true
    end
    if pc then
        return M.extendsOrRestrict(pc, parent)
    end
    return false
end

-- Returns a sorted array of member type names for a type tag, or nil if not a tag.
function M.listMembersOfTag(tagName)
    local members = state.TAG_MEMBERS[tagName]
    if not members then return nil end
    local result = {}
    for name, _ in pairs(members) do
        result[#result + 1] = name
    end
    table.sort(result)
    return result
end

-- Returns true if typeName is a member of the type tag tagName.
-- Checks direct membership, subtype membership (e.g., ubyte via integer),
-- and transitive tag membership (e.g., kilogram via MassUnit which is a member of Unit).
-- Returns false if tagName is not a tag, or if typeName is not a member.
function M.isMemberOfTag(tagName, typeName)
    if type(tagName) ~= "string" or type(typeName) ~= "string" then
        return false
    end
    local members = state.TAG_MEMBERS[tagName]
    if not members then return false end
    if members[typeName] then return true end
    -- Check if typeName extends any member (subtype check),
    -- or is a member of a nested tag (transitive tag membership via extendsOrRestrict)
    for member, _ in pairs(members) do
        if typeSameOrExtends(typeName, member) then
            return true
        end
    end
    return false
end

-- Export typeSameOrExtends for use by registration
M.typeSameOrExtends = typeSameOrExtends

return M
