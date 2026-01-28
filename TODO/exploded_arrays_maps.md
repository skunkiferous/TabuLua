# TODO: Exploded Array and Map Columns

## Background

We want to extend the "exploded columns" feature (currently supporting records and tuples) to also support arrays and maps. This allows users to represent variable-length collections in a TSV-friendly format where each element occupies its own column, making the data easy to edit and diff in version control.

### Use Cases

This feature is intended for the case where *small* arrays/maps are used. Otherwise, the files would become too wide.

### Current Exploded Columns (Records/Tuples)

Currently, exploded columns use dot notation for nested structures:
- `location.level:name` - record field
- `position._1:integer`, `position._2:integer` - tuple elements

### New Feature: Exploded Arrays and Maps

**Exploded Array Column Header:**
```
<name>[<index>]:<element-type-spec>
```

Example:
```
tags[1]:string    tags[2]:string    tags[3]:string
```
With values: `fire`, `rare`, `weapon`
This would parse into an array: `{"fire", "rare", "weapon"}`

**Exploded Map Column Headers:**
```
<name>[<index>]:<key-type-spec>      (key column)
<name>[<index>]=:<value-type-spec>   (value column)
```

Example:
```
stats[1]:name    stats[1]=:integer    stats[2]:name    stats[2]=:integer
```
With values: `attack`, `50`, `defense`, `30`
This would parse into a map: `{attack=50, defense=30}`

### Key Design Decision

The difference between array and map columns is detected by the presence of `=` before the colon in the column name:
- `items[1]:string` → array element (no `=`)
- `items[1]=:integer` → map value (has `=` before `:`)

When a `=` column exists for an index, the non-`=` column becomes the key.

## Header Syntax Specification

### Array Columns

```
<name>[<index>]:<element-type-spec>
```

- `<name>` - Valid identifier (letters, digits, underscores; starting with letter or underscore)
- `<index>` - Positive integer (1, 2, 3, ...)
- `<element-type-spec>` - Any valid type specification

**Examples:**
```
items[1]:string
scores[1]:integer
positions[1]:{number,number}
nested[1]:{x:integer,y:integer}
```

### Map Columns

Maps require two columns per entry:

```
<name>[<index>]:<key-type-spec>     (key)
<name>[<index>]=:<value-type-spec>  (value)
```

**Examples:**
```
attributes[1]:name    attributes[1]=:integer
settings[1]:string    settings[1]=:boolean
complex[1]:name       complex[1]=:{min:integer,max:integer}
```

### Nested Exploded Arrays/Maps

Arrays and maps can be nested within exploded records/tuples using combined notation:

```
player.inventory[1]:string
player.stats[1]:name    player.stats[1]=:integer
position._1.tags[1]:string
```

## Validation Rules

### Index Validation

1. **Indices must be positive integers** (1, 2, 3, ...) - zero and negative indices are invalid
2. **Indices must start at 1** - cannot have `items[2]` without `items[1]`
3. **Indices must be consecutive** - cannot have gaps (e.g., `items[1]`, `items[3]` without `items[2]`)
4. **Indices should be in ascending order** in the header (recommended but not strictly required)

### Map Validation

1. **Key and value columns must have matching indices** - if `stats[1]:name` exists, `stats[1]=:integer` must also exist (and vice versa)
2. **Cannot mix array and map notation** for the same root name - either all indices have `=` columns (map) or none do (array)
3. **Key columns must come before value columns** for the same index (recommended for readability)

### Consistency Validation

1. **All elements must have consistent type specs** within an array column group (they define the same element type)
2. **All keys must have consistent type specs** within a map column group
3. **All values must have consistent type specs** within a map column group
4. **Cannot have both exploded and non-exploded columns** with the same root name

### Error Examples

```
# Invalid: Index starts at 2
items[2]:string

# Invalid: Gap in indices
items[1]:string    items[3]:string

# Invalid: Missing value column for map
stats[1]:name    stats[2]:name    stats[2]=:integer

# Invalid: Missing key column for map
stats[1]=:integer

# Invalid: Mixed array/map notation
items[1]:string    items[2]:string    items[2]=:integer

# Invalid: Inconsistent element types (should all be the same)
# Actually, this might be valid if we want heterogeneous arrays - TBD
items[1]:string    items[2]:integer
```

## Implementation Steps

### 1. Update Header Parsing

Modify `tsv_model.lua` (or relevant module) to recognize the new bracket notation:

```lua
-- Pattern for array/map columns
local ARRAY_PATTERN = "^([%w_]+)%[(%d+)%]:(.+)$"        -- name[index]:type
local MAP_VALUE_PATTERN = "^([%w_]+)%[(%d+)%]=:(.+)$"   -- name[index]=:type

local function parseColumnHeader(header_text)
    -- Try map value pattern first (more specific)
    local name, idx, type_spec = header_text:match(MAP_VALUE_PATTERN)
    if name then
        return {
            name = name,
            index = tonumber(idx),
            type_spec = type_spec,
            is_map_value = true,
            is_exploded_collection = true
        }
    end

    -- Try array/map-key pattern
    name, idx, type_spec = header_text:match(ARRAY_PATTERN)
    if name then
        return {
            name = name,
            index = tonumber(idx),
            type_spec = type_spec,
            is_map_value = false,
            is_exploded_collection = true
        }
    end

    -- Fall through to existing parsing...
end
```

### 2. Add Validation Function

Create a validation function similar to existing exploded column validation:

```lua
local function validateExplodedCollections(header)
    local collections = {}  -- name -> { indices = {}, is_map = bool, ... }

    -- First pass: gather all collection columns
    for i, col in ipairs(header) do
        if col.is_exploded_collection then
            local name = col.name
            if not collections[name] then
                collections[name] = {
                    indices = {},
                    has_keys = {},
                    has_values = {},
                    is_map = nil
                }
            end
            local coll = collections[name]
            coll.indices[col.index] = true
            if col.is_map_value then
                coll.has_values[col.index] = true
                coll.is_map = true
            else
                coll.has_keys[col.index] = true
            end
        end
    end

    -- Second pass: validate each collection
    for name, coll in pairs(collections) do
        -- Check indices are consecutive starting at 1
        local max_idx = 0
        for idx in pairs(coll.indices) do
            max_idx = math.max(max_idx, idx)
        end
        for i = 1, max_idx do
            if not coll.indices[i] then
                return nil, string.format(
                    "Collection '%s' has gap at index %d", name, i)
            end
        end

        -- Validate map consistency
        if coll.is_map then
            for i = 1, max_idx do
                if not coll.has_keys[i] then
                    return nil, string.format(
                        "Map '%s' missing key column for index %d", name, i)
                end
                if not coll.has_values[i] then
                    return nil, string.format(
                        "Map '%s' missing value column for index %d", name, i)
                end
            end
        end
    end

    return true
end
```

### 3. Update `exploded_columns.lua`

Extend `analyzeExplodedColumns` to handle the new collection types:

```lua
local function analyzeExplodedColumns(header)
    -- ... existing code for records/tuples ...

    -- Additional handling for arrays and maps
    local collections = {}

    for i, col in ipairs(header) do
        if col.is_exploded_collection then
            local name = col.name
            if not collections[name] then
                collections[name] = {
                    type = nil,  -- "array" or "map"
                    element_type = nil,
                    key_type = nil,
                    value_type = nil,
                    max_index = 0,
                    columns = {}
                }
            end
            -- ... build collection structure ...
        end
    end

    return result
end
```

### 4. Update Assembly Function

Extend `assembleExplodedValue` to construct arrays and maps:

```lua
local function assembleExplodedValue(row, structure)
    if structure.type == "array" then
        local result = {}
        for i = 1, structure.max_index do
            local col_idx = structure.columns[i]
            local cell = row[col_idx]
            result[i] = cell and cell.parsed
        end
        return readOnlyArray(result)  -- or just readOnly

    elseif structure.type == "map" then
        local result = {}
        for i = 1, structure.max_index do
            local key_col = structure.key_columns[i]
            local val_col = structure.value_columns[i]
            local key = row[key_col] and row[key_col].parsed
            local val = row[val_col] and row[val_col].parsed
            if key ~= nil then
                result[key] = val
            end
        end
        return readOnly(result)
    end

    -- ... existing record/tuple handling ...
end
```

### 5. Update Documentation

Add section to `DATA_FORMAT_README.md`:

```markdown
## Exploded Arrays and Maps

### Arrays
Arrays can be "exploded" into separate columns using bracket notation:

| items[1]:string | items[2]:string | items[3]:string |
|-----------------|-----------------|-----------------|
| sword           | shield          | potion          |

Parses to: `{"sword", "shield", "potion"}`

### Maps
Maps use paired columns for keys and values. Value columns have `=` before the colon:

| stats[1]:name | stats[1]=:integer | stats[2]:name | stats[2]=:integer |
|---------------|-------------------|---------------|-------------------|
| attack        | 50                | defense       | 30                |

Parses to: `{attack = 50, defense = 30}`
```

### 6. Add Tests

Create comprehensive tests in `spec/exploded_collections_spec.lua`:

- Valid array headers parse correctly
- Valid map headers parse correctly
- Validation rejects gaps in indices
- Validation rejects mixed array/map notation
- Validation rejects incomplete map pairs
- Assembly creates correct array values
- Assembly creates correct map values
- Nested collections work with records/tuples

## Design Considerations

### Empty/Nil Elements

How should empty cells be handled?

**Option A: Skip nil values**
- Empty array cells create gaps (sparse array)
- Empty map keys skip that entry entirely

**Option B: Preserve nil values**
- Arrays maintain their length even with nil elements
- Map entries with nil keys are skipped, nil values are preserved

**Recommendation:** Option A (skip nils) - simpler and matches typical Lua semantics.

### Maximum Index Limit

Should there be a maximum number of elements?

**Recommendation:** No hard limit, but documentation should note that very wide tables (many columns) may impact readability and performance.

### Interaction with Existing Exploded Columns

Can arrays/maps nest inside exploded records?

```
player.inventory[1]:string
player.inventory[2]:string
```

**Recommendation:** Yes, support this. The path parsing should handle both dot notation (records/tuples) and bracket notation (arrays/maps) in combination.

## Open Questions

1. **Integration with reformatter:** How should the reformatter handle converting inline arrays/maps to exploded format?

2. **Empty collections:** How do we represent an empty array/map? Perhaps by having columns but all cells empty?

3. **Key uniqueness:** For maps, should we validate that keys are unique within a row? What happens if two key columns have the same value?

4. **Order preservation:** Should we guarantee that map entries are returned in index order, or is the order undefined?

5. **Nested collections:** Should we support `items[1][1]:string` for arrays of arrays? This could get complex.

## Example TSV Files

### Simple Array

```tsv
id:integer	tags[1]:string	tags[2]:string	tags[3]:string
1	fire	rare	weapon
2	ice	common	armor
3	lightning		shield
```

### Simple Map

```tsv
id:integer	stats[1]:name	stats[1]=:integer	stats[2]:name	stats[2]=:integer
1	attack	50	defense	30
2	speed	75	luck	10
```

### Mixed with Records

```tsv
id:integer	player.name:string	player.items[1]:string	player.items[2]:string
1	Alice	sword	shield
2	Bob	staff	robe
```
