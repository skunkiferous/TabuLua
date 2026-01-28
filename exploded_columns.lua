-- Module name
local NAME = "exploded_columns"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 1, 0)

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
        local idx = name:match("^_(%d+)$")
        if not idx then
            return false, nil
        end
        indices[#indices + 1] = tonumber(idx)
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

--- Recursively determines the structure type (record or tuple) and builds the type_spec.
--- @param node table A node in the path tree with child fields
--- @return string The structure type: "record" or "tuple"
--- @return string The generated type specification
local function determineStructureType(node)
    local is_tuple, indices = isTupleStructure(node.children)
    if is_tuple then
        -- Build tuple type_spec: {type1,type2,type3}
        local types = {}
        for _, idx in ipairs(indices) do
            local child = node.children["_" .. idx]
            if child.children then
                -- Nested structure
                local _, nested_spec = determineStructureType(child)
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
            if child.children then
                -- Nested structure
                local _, nested_spec = determineStructureType(child)
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
--- @return table The structure definition with type, fields, type_spec, etc.
local function buildStructureFromNode(node)
    if not node.children then
        -- Leaf node
        return {
            type = "leaf",
            col_idx = node.col_idx,
            type_spec = node.type_spec
        }
    end

    local struct_type, type_spec = determineStructureType(node)
    local fields = {}

    if struct_type == "tuple" then
        -- For tuples, fields is an array indexed by position
        local _, indices = isTupleStructure(node.children)
        for _, idx in ipairs(indices) do
            local child = node.children["_" .. idx]
            fields[idx] = buildStructureFromNode(child)
        end
    else
        -- For records, fields is a map of name -> structure
        for name, child in pairs(node.children) do
            fields[name] = buildStructureFromNode(child)
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
local function analyzeExplodedColumns(header)
    assert(type(header) == "table", "Invalid argument")
    -- First pass: build a path tree from exploded columns
    local roots = {}

    for i = 1, #header do
        local col = header[i]
        if col.is_exploded and col.exploded_path then
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
    for root_name, root_node in pairs(roots) do
        if root_node.children then
            result[root_name] = buildStructureFromNode(root_node)
        end
    end

    return result
end

--- Assembles a nested value from exploded columns in a row.
--- @param row table The row data (cells indexed by column index)
--- @param structure table The structure definition from analyzeExplodedColumns
--- @return any The assembled nested value (record, tuple, or leaf value)
local function assembleExplodedValue(row, structure)
    assert(type(row) == "table" and type(structure) == "table", "Invalid arguments")
    if structure.type == "leaf" then
        local cell = row[structure.col_idx]
        return cell and cell.parsed
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
    isTupleStructure = isTupleStructure,
    generateCollapsedColumnSpec = generateCollapsedColumnSpec,
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
