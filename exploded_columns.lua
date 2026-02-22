-- Module name
local NAME = "exploded_columns"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 11, 0)

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- Dependencies
local read_only = require("read_only")
local readOnly = read_only.readOnly
local readOnlyTuple = read_only.readOnlyTuple
local table_utils = require("table_utils")
local keys = table_utils.keys
local predicates = require("predicates")
local isName = predicates.isName
local isIdentifier = predicates.isIdentifier
local isTupleFieldName = predicates.isTupleFieldName

--- Checks if a value is a valid exploded column name (dot-separated path).
--- An exploded column name is a valid "name" (dot-separated identifiers) that
--- contains at least one dot. Tuple indices like _1, _2 are valid identifiers.
--- Examples: "location.level", "position._1", "data.nested._2"
--- @param s any The value to check
--- @return boolean True if s is a valid exploded column name, false otherwise
local function isExplodedColumnName(s)
    return isName(s) and not isIdentifier(s)
end

--- Parses an exploded collection column name (bracket notation).
--- Returns nil if the string is not a valid collection column name.
--- Examples:
---   "items[1]" -> {base_path="items", index=1, is_map_value=false}
---   "stats[1]=" -> {base_path="stats", index=1, is_map_value=true}
---   "player.inventory[2]" -> {base_path="player.inventory", index=2, is_map_value=false}
--- @param s string The column name to parse
--- @return table|nil Parsed info: {base_path, index, is_map_value} if valid, nil otherwise
local function parseExplodedCollectionName(s)
    if type(s) ~= "string" then
        return nil
    end

    -- Pattern for collection columns (with optional map value indicator)
    -- Matches: name[N] or name[N]= or prefix.name[N] or prefix.name[N]=
    local base, idx_str, eq = s:match("^(.-)%[(%d+)%](=?)$")

    if not base or base == "" then
        return nil
    end

    local idx = tonumber(idx_str)
    if not idx or idx < 1 then
        return nil
    end

    -- Validate the base path (must be valid identifier or dot-path name)
    if not isName(base) then
        return nil
    end

    return {
        base_path = base,
        index = idx,
        is_map_value = (eq == "=")
    }
end

--- Checks if a value is a valid exploded collection column name (bracket notation).
--- Collection columns use bracket notation for arrays and maps:
--- - Array element: "items[1]", "items[2]", "player.items[1]"
--- - Map value: "stats[1]=", "player.stats[1]="
--- @param s any The value to check
--- @return boolean True if s is a valid exploded collection column name, false otherwise
local function isExplodedCollectionName(s)
    return parseExplodedCollectionName(s) ~= nil
end

--- Validates exploded collection columns for consistency.
--- Rules:
--- 1. Indices must be positive integers starting at 1
--- 2. Indices must be consecutive (no gaps)
--- 3. Maps need both key and value columns for each index
--- 4. Cannot mix array/map notation for same root name
--- @param header table The parsed header
--- @return boolean True if valid
--- @return string|nil Error message if invalid
local function validateExplodedCollections(header)
    -- Group collections by their full base path
    local collections = {}  -- base_path -> collection_data

    -- First pass: collect all collection columns
    for i = 1, #header do
        local col = header[i]
        if col.is_collection and col.collection_info then
            local info = col.collection_info
            local base = info.base_path

            if not collections[base] then
                collections[base] = {
                    indices = {},       -- index -> true
                    has_keys = {},      -- index -> col_idx
                    has_values = {},    -- index -> col_idx
                    key_types = {},     -- index -> type_spec
                    value_types = {},   -- index -> type_spec
                    max_index = 0
                }
            end

            local coll = collections[base]
            local idx = info.index
            coll.indices[idx] = true
            coll.max_index = math.max(coll.max_index, idx)

            if info.is_map_value then
                if coll.has_values[idx] then
                    return false, string.format(
                        "Duplicate map value column for '%s[%d]='", base, idx)
                end
                coll.has_values[idx] = col.idx
                coll.value_types[idx] = col.type
            else
                if coll.has_keys[idx] then
                    return false, string.format(
                        "Duplicate key/element column for '%s[%d]'", base, idx)
                end
                coll.has_keys[idx] = col.idx
                coll.key_types[idx] = col.type
            end
        end
    end

    -- Second pass: validate each collection
    for base, coll in pairs(collections) do
        -- Check consecutive indices starting at 1
        for i = 1, coll.max_index do
            if not coll.indices[i] then
                return false, string.format(
                    "Collection '%s' missing index %d (indices must be consecutive from 1)",
                    base, i)
            end
        end

        -- Determine if this is a map (has any value columns)
        local is_map = false
        for _ in pairs(coll.has_values) do
            is_map = true
            break
        end

        -- Validate map consistency
        if is_map then
            for i = 1, coll.max_index do
                if not coll.has_keys[i] then
                    return false, string.format(
                        "Map '%s' missing key column for index %d", base, i)
                end
                if not coll.has_values[i] then
                    return false, string.format(
                        "Map '%s' missing value column for index %d", base, i)
                end
            end
        end
        -- Note: Pure arrays don't need special validation beyond consecutive indices
    end

    return true, nil
end

--- Determines if a set of field names represents a tuple structure.
--- A tuple structure has all keys matching the pattern _1, _2, _3, etc.
--- and the indices must be consecutive starting from 1.
--- @param fields table Map of field names to their definitions
--- @return boolean True if this is a tuple structure
--- @return table|nil Sorted numeric indices if tuple, nil otherwise
local function isTupleStructure(fields)
    if type(fields) ~= "table" then
        return false, nil
    end
    local indices = {}
    for name in pairs(fields) do
        if type(name) ~= "string" then
            return false, nil
        end
        if not isTupleFieldName(name) then
            return false, nil
        end
        indices[#indices + 1] = tonumber(name:sub(2))
    end
    if #indices == 0 then
        return false, nil
    end
    table.sort(indices)
    -- Check for consecutive indices starting at 1
    for i, idx in ipairs(indices) do
        if idx ~= i then
            return false, nil
        end
    end
    return true, indices
end

--- Builds a structure definition for an array or map collection.
--- @param coll table Collection data from analysis
--- @return table Structure definition
local function buildCollectionStructure(coll)
    if coll.is_map then
        return {
            type = "map",
            type_spec = "{" .. (coll.key_type or "any") .. ":" .. (coll.value_type or "any") .. "}",
            key_type = coll.key_type,
            value_type = coll.value_type,
            max_index = coll.max_index,
            key_columns = coll.key_columns,
            value_columns = coll.value_columns
        }
    else
        return {
            type = "array",
            type_spec = "{" .. (coll.element_type or "any") .. "}",
            element_type = coll.element_type,
            max_index = coll.max_index,
            element_columns = coll.element_columns
        }
    end
end

--- Gets the type spec for a collection node.
--- @param coll table Collection data
--- @return string The type specification
local function getCollectionTypeSpec(coll)
    if coll.is_map then
        return "{" .. (coll.key_type or "any") .. ":" .. (coll.value_type or "any") .. "}"
    else
        return "{" .. (coll.element_type or "any") .. "}"
    end
end

--- Recursively determines the structure type (record or tuple) and builds the type_spec.
--- @param node table A node in the path tree with child fields
--- @param collections table|nil Optional map of collection data for nested collections
--- @return string The structure type: "record" or "tuple"
--- @return string The generated type specification
local function determineStructureType(node, collections)
    local is_tuple, indices = isTupleStructure(node.children)
    if is_tuple then
        -- Build tuple type_spec: {type1,type2,type3}
        local types = {}
        for _, idx in ipairs(indices) do
            local child = node.children["_" .. idx]
            if child.is_collection_node and collections then
                -- Collection node
                local coll = collections[child.collection_base]
                types[#types + 1] = getCollectionTypeSpec(coll)
            elseif child.children then
                -- Nested structure
                local _, nested_spec = determineStructureType(child, collections)
                types[#types + 1] = nested_spec
            else
                -- Leaf node
                types[#types + 1] = child.type_spec
            end
        end
        return "tuple", "{" .. table.concat(types, ",") .. "}"
    else
        -- Build record type_spec: {field1:type1,field2:type2}
        local sorted_names = keys(node.children)
        table.sort(sorted_names)
        local parts = {}
        for _, name in ipairs(sorted_names) do
            local child = node.children[name]
            if child.is_collection_node and collections then
                -- Collection node
                local coll = collections[child.collection_base]
                parts[#parts + 1] = name .. ":" .. getCollectionTypeSpec(coll)
            elseif child.children then
                -- Nested structure
                local _, nested_spec = determineStructureType(child, collections)
                parts[#parts + 1] = name .. ":" .. nested_spec
            else
                -- Leaf node
                parts[#parts + 1] = name .. ":" .. child.type_spec
            end
        end
        return "record", "{" .. table.concat(parts, ",") .. "}"
    end
end

--- Recursively builds the structure definition from a path tree node.
--- @param node table A node in the path tree
--- @param collections table|nil Optional map of collection data for nested collections
--- @return table The structure definition with type, fields, type_spec, etc.
local function buildStructureFromNode(node, collections)
    -- Check for collection node marker
    if node.is_collection_node and collections then
        local coll = collections[node.collection_base]
        if coll then
            -- For maps, move element_columns to key_columns
            if coll.is_map then
                for idx, col_idx in pairs(coll.element_columns or {}) do
                    coll.key_columns[idx] = col_idx
                end
                coll.element_columns = nil
            end
            return buildCollectionStructure(coll)
        end
    end

    if not node.children then
        -- Leaf node
        return {
            type = "leaf",
            col_idx = node.col_idx,
            type_spec = node.type_spec
        }
    end

    local struct_type, type_spec = determineStructureType(node, collections)
    local fields = {}

    if struct_type == "tuple" then
        -- For tuples, fields is an array indexed by position
        local _, indices = isTupleStructure(node.children)
        for _, idx in ipairs(indices) do
            local child = node.children["_" .. idx]
            fields[idx] = buildStructureFromNode(child, collections)
        end
    else
        -- For records, fields is a map of name -> structure
        for name, child in pairs(node.children) do
            fields[name] = buildStructureFromNode(child, collections)
        end
    end

    return {
        type = struct_type,
        type_spec = type_spec,
        fields = fields
    }
end

--- Analyzes header columns and builds a map of exploded structures.
--- @param header table The parsed header containing column definitions
--- @return table Map of root names to their structure definitions
--- Example: For columns "location.level:name", "location.position._1:integer", "location.position._2:integer"
--- Returns: {
---   location = {
---     type = "record",
---     type_spec = "{level:name,position:{integer,integer}}",
---     fields = {
---       level = { type = "leaf", col_idx = 2, type_spec = "name" },
---       position = {
---         type = "tuple",
---         type_spec = "{integer,integer}",
---         fields = { [1] = {...}, [2] = {...} }
---       }
---     }
---   }
--- }
--- Also handles arrays: "items[1]:string", "items[2]:string"
--- And maps: "stats[1]:name", "stats[1]=:integer"
local function analyzeExplodedColumns(header)
    assert(type(header) == "table", "Invalid argument")

    -- First pass: build a path tree from exploded columns AND track collections
    local roots = {}
    local collections = {}  -- base_path -> collection_data

    for i = 1, #header do
        local col = header[i]

        if col.is_collection and col.collection_info then
            -- Handle collection columns (arrays/maps)
            local info = col.collection_info
            local base = info.base_path

            if not collections[base] then
                collections[base] = {
                    is_map = false,
                    element_type = nil,
                    key_type = nil,
                    value_type = nil,
                    max_index = 0,
                    key_columns = {},    -- index -> col_idx
                    value_columns = {},  -- index -> col_idx
                    element_columns = {} -- index -> col_idx (for arrays)
                }
            end

            local coll = collections[base]
            local idx = info.index
            coll.max_index = math.max(coll.max_index, idx)

            if info.is_map_value then
                coll.is_map = true
                coll.value_columns[idx] = col.idx
                coll.value_type = coll.value_type or col.type
            else
                if coll.is_map then
                    coll.key_columns[idx] = col.idx
                    coll.key_type = coll.key_type or col.type
                else
                    coll.element_columns[idx] = col.idx
                    coll.element_type = coll.element_type or col.type
                end
            end

            -- For nested collections (e.g., "player.inventory[1]"), add to path tree
            local path_parts = {}
            for part in base:gmatch("[^%.]+") do
                path_parts[#path_parts + 1] = part
            end

            if #path_parts > 1 then
                -- Nested collection: root is first part, collection at last part
                local root_name = path_parts[1]
                if not roots[root_name] then
                    roots[root_name] = { children = {} }
                end

                -- Navigate to parent, mark leaf as collection
                local current = roots[root_name]
                for j = 2, #path_parts - 1 do
                    local segment = path_parts[j]
                    if not current.children then
                        current.children = {}
                    end
                    if not current.children[segment] then
                        current.children[segment] = {}
                    end
                    current = current.children[segment]
                end

                -- Mark final segment as collection node
                local final_segment = path_parts[#path_parts]
                if not current.children then
                    current.children = {}
                end
                current.children[final_segment] = {
                    is_collection_node = true,
                    collection_base = base
                }
            end

        elseif col.is_exploded and col.exploded_path then
            -- Handle standard record/tuple columns
            local path = col.exploded_path
            local root_name = path[1]

            -- Initialize root if needed
            if not roots[root_name] then
                roots[root_name] = { children = {} }
            end

            -- Navigate/build the path tree
            local current = roots[root_name]
            for j = 2, #path do
                local segment = path[j]
                if not current.children then
                    current.children = {}
                end
                if not current.children[segment] then
                    current.children[segment] = {}
                end
                current = current.children[segment]
            end

            -- Mark the leaf with column info
            current.col_idx = col.idx
            current.type_spec = col.type
        end
    end

    -- Second pass: convert path tree to structure definitions
    local result = {}

    -- Handle top-level collections (not nested in records)
    for base, coll in pairs(collections) do
        local path_parts = {}
        for part in base:gmatch("[^%.]+") do
            path_parts[#path_parts + 1] = part
        end

        if #path_parts == 1 then
            -- Top-level collection
            -- For maps, we need to also store the key columns
            if coll.is_map then
                -- When we see a value column, the corresponding key column was already stored
                -- but we need to move element_columns to key_columns
                for idx, col_idx in pairs(coll.element_columns) do
                    coll.key_columns[idx] = col_idx
                end
                coll.element_columns = nil
            end
            result[base] = buildCollectionStructure(coll)
        end
    end

    -- Handle records/tuples (may contain nested collections)
    for root_name, root_node in pairs(roots) do
        if root_node.children and not result[root_name] then
            result[root_name] = buildStructureFromNode(root_node, collections)
        end
    end

    return result
end

--- Assembles a nested value from exploded columns in a row.
--- @param row table The row data (cells indexed by column index)
--- @param structure table The structure definition from analyzeExplodedColumns
--- @return any The assembled nested value (record, tuple, array, map, or leaf value)
local function assembleExplodedValue(row, structure)
    assert(type(row) == "table" and type(structure) == "table", "Invalid arguments")
    if structure.type == "leaf" then
        local cell = row[structure.col_idx]
        return cell and cell.parsed

    elseif structure.type == "array" then
        -- Assemble array from element columns, preserving nil values
        local result = {}
        for i = 1, structure.max_index do
            local col_idx = structure.element_columns[i]
            local cell = row[col_idx]
            result[i] = cell and cell.parsed
        end
        return readOnly(result)

    elseif structure.type == "map" then
        -- Assemble map from key/value column pairs
        local result = {}
        for i = 1, structure.max_index do
            local key_col = structure.key_columns[i]
            local val_col = structure.value_columns[i]
            local key_cell = row[key_col]
            local val_cell = row[val_col]
            local key = key_cell and key_cell.parsed
            local val = val_cell and val_cell.parsed
            -- Skip entries with nil keys
            if key ~= nil then
                result[key] = val  -- val can be nil
            end
        end
        return readOnly(result)

    elseif structure.type == "tuple" then
        local result = {}
        for i, field_def in ipairs(structure.fields) do
            result[i] = assembleExplodedValue(row, field_def)
        end
        return readOnlyTuple(result)

    elseif structure.type == "record" then
        local result = {}
        for name, field_def in pairs(structure.fields) do
            result[name] = assembleExplodedValue(row, field_def)
        end
        return readOnly(result)
    end
    return nil
end

--- Generates a collapsed header column specification for an exploded structure.
--- @param root_name string The root name (e.g., "location")
--- @param structure table The structure definition
--- @return string The collapsed column spec (e.g., "location:{level:name,position:{integer,integer}}")
local function generateCollapsedColumnSpec(root_name, structure)
    assert(type(root_name) == "string" and type(structure) == "table", "Invalid arguments")
    assert(type(structure.type_spec) == "string", "Invalid structure")
    return root_name .. ":" .. structure.type_spec
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    analyzeExplodedColumns = analyzeExplodedColumns,
    assembleExplodedValue = assembleExplodedValue,
    isExplodedColumnName = isExplodedColumnName,
    isExplodedCollectionName = isExplodedCollectionName,
    isTupleStructure = isTupleStructure,
    generateCollapsedColumnSpec = generateCollapsedColumnSpec,
    parseExplodedCollectionName = parseExplodedCollectionName,
    validateExplodedCollections = validateExplodedCollections,
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
