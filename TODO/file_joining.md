# TODO: File Joining for Wide Table Management

## Background

With the addition of "exploded" arrays and maps (see `TODO_exploded_arrays_maps.md`), and the need to support multi-language translations for text columns, TSV files can become impractically wide. Wide files are difficult to edit, review in version control diffs, and manage collaboratively.

### Problem Cases

1. **Exploded Collections**: When rows contain multiple exploded arrays or maps, each element adds columns, quickly expanding file width.

2. **Multi-Language Translations**: Text columns (like `description:markdown`) that need translations into multiple languages (e.g., `description_en`, `description_de`, `description_fr`, `description_ja`) multiply the width significantly. Long-form text exacerbates this issue.

3. **Collaborative Translation**: Having all translations in a single file prevents parallel work—translators cannot independently work on their language without merge conflicts.

### Current Workarounds and Their Limitations

One could use "default expressions" to import content from other files:
```
description:markdown=Items_en[id].description
```

**Drawbacks**:
- The "main file" has empty columns where content is imported
- Secondary files are still exported separately, duplicating data
- Expression evaluation overhead on every row
- No clear semantic relationship between files

## Proposed Solution: File Joining

Introduce a "joining" mechanism where secondary files can be joined into a primary file at export time, using a shared primary key column. This keeps source files separate (enabling parallel editing) while producing a unified export.

### Core Concepts

1. **Primary File**: The main file that other files join into
2. **Secondary File(s)**: Files that are joined into a primary file via a shared key
3. **Join Column**: The column(s) used to match rows between files (typically the primary key)
4. **Export Suppression**: Secondary files should not be exported independently by default

### Example Use Case: Translations

**Primary file** (`Items.tsv`):
```tsv
id:name	baseValue:integer	weight:number
sword	100	2.5
shield	75	5.0
```

**Secondary file** (`Items.en.tsv`):
```tsv
id:name	description:markdown
sword	A sharp blade for combat.
shield	A sturdy defense tool.
```

**Secondary file** (`Items.de.tsv`):
```tsv
id:name	description:markdown
sword	Eine scharfe Klinge für den Kampf.
shield	Ein robustes Verteidigungswerkzeug.
```

**Exported result** (when configured for `en` locale):
```lua
{
    sword = { id = "sword", baseValue = 100, weight = 2.5, description = "A sharp blade for combat." },
    shield = { id = "shield", baseValue = 75, weight = 5.0, description = "A sturdy defense tool." }
}
```

### Example Use Case: Exploded Columns

**Primary file** (`Enemies.tsv`):
```tsv
id:name	health:integer	damage:integer
goblin	50	10
dragon	500	75
```

**Secondary file** (`Enemies.drops.tsv`):
```tsv
id:name	drops[1]:name	drops[1]=:integer	drops[2]:name	drops[2]=:integer
goblin	gold	5	cloth	2
dragon	gold	100	scale	1
```

**Exported result**:
```lua
{
    goblin = { id = "goblin", health = 50, damage = 10, drops = { gold = 5, cloth = 2 } },
    dragon = { id = "dragon", health = 500, damage = 75, drops = { gold = 100, scale = 1 } }
}
```

## Files.tsv Schema Extension

### New Columns

Add the following columns to `Files.tsv`:

| Column | Type | Description |
|--------|------|-------------|
| `joinInto` | `name\|nil` | The fileName of the primary file this file joins into |
| `joinColumn` | `name\|nil` | The column name used for joining (defaults to primary key if nil) |
| `export` | `boolean\|nil` | Whether to export this file independently (defaults based on joinInto) |

### Default Behavior

- `export` defaults to `true` for files without `joinInto`
- `export` defaults to `false` for files with `joinInto` specified
- Users can override the default by explicitly setting `export`

### Example Files.tsv Entries

```tsv
fileName:string	typeName:type_spec	...	joinInto:name|nil	joinColumn:name|nil	export:boolean|nil
Items.tsv	Item	...
Items.en.tsv	Item.en	...	Items.tsv	id
Items.de.tsv	Item.de	...	Items.tsv	id
Enemies.tsv	Enemy	...
Enemies.drops.tsv	Enemy.drops	...	Enemies.tsv	id
Debug.tsv	Debug	...			false
```

## Join Semantics

### Join Type

Use **LEFT JOIN** semantics from the primary file's perspective:
- All rows from the primary file are included
- Matching rows from secondary files add their columns
- Non-matching rows in secondary files generate a warning
- Missing matches in secondary files result in `nil` values for those columns

### Column Name Conflicts

When the same column name exists in multiple joined files:
- The join column itself is merged (must have identical values)
- Other duplicate column names are an error (detected at load time)
- Consider supporting column renaming/prefixing in the future

### Multiple Joins

A primary file can have multiple secondary files joining into it:
```tsv
Items.en.tsv → Items.tsv
Items.de.tsv → Items.tsv
Items.stats.tsv → Items.tsv
```

All secondary files must use the same join column for a given primary file.

### Chained Joins

Secondary files should NOT support chaining (joining into another secondary file):
- `A.tsv ← B.tsv ← C.tsv` is NOT allowed
- This keeps the join logic simple and predictable
- Validation should reject such configurations

## Implementation Steps

### 1. Extend Files.tsv Schema

Update `Files.tsv` and `files_desc.lua` to include the new columns:
- `joinInto:name|nil`
- `joinColumn:name|nil`
- `export:boolean|nil`

### 2. Update Manifest Loading

Modify `manifest_loader.lua` to:
- Parse and validate the new columns
- Build a join dependency graph
- Detect invalid configurations (cycles, chain joins)
- Determine load order (secondary files must load after their primary)

### 3. Implement Join Logic

Create a new module (e.g., `file_joining.lua`) or extend `exporter.lua`:

```lua
local function joinFiles(primaryData, secondaryDataList, joinColumn)
    local result = {}
    for _, row in ipairs(primaryData.rows) do
        local joinKey = row[joinColumn]
        local merged = table_utils.shallowCopy(row)

        for _, secondary in ipairs(secondaryDataList) do
            local secondaryRow = secondary.index[joinKey]
            if secondaryRow then
                for col, value in pairs(secondaryRow) do
                    if col ~= joinColumn then
                        if merged[col] ~= nil then
                            error("Column conflict: " .. col)
                        end
                        merged[col] = value
                    end
                end
            end
        end

        table.insert(result, merged)
    end
    return result
end
```

### 4. Update Exporter

Modify `exporter.lua` to:
- Respect the `export` flag (skip files where `export == false`)
- Perform joins before exporting when `joinInto` relationships exist
- Index secondary files by join column for efficient lookup

### 5. Update Validation

Add validation rules:
- Join column must exist in both primary and secondary files
- Join column should be unique in primary file (typically the primary key)
- No column name conflicts between joined files (except join column)
- No circular or chained join dependencies

### 6. Update Reformatter

Ensure `reformatter.lua` handles joined files correctly:
- Preserve file separation when reformatting
- Validate cross-file consistency

### 7. Documentation

Update `DATA_FORMAT_README.md` with:
- File joining concept and use cases
- Files.tsv new columns documentation
- Examples for translations and exploded columns

### 8. Tests

Create `spec/file_joining_spec.lua`:
- Basic join with single secondary file
- Multiple secondary files joining same primary
- Missing rows in secondary file (NULL handling)
- Column conflict detection
- Invalid join configurations (cycles, chains)
- Export flag behavior

## Design Considerations

### Naming Convention for Secondary Files

Recommend a consistent naming pattern:
- `<Primary>.<purpose>.tsv` for feature splits (e.g., `Items.drops.tsv`)
- `<Primary>.<locale>.tsv` for translations (e.g., `Items.en.tsv`, `Items.de.tsv`)

### Locale-Aware Export

For translation files, the exporter could accept a locale parameter:
```lua
exporter.export(manifest, { locale = "de" })
```

This would:
- Join `Items.de.tsv` into `Items.tsv` (if `de` locale)
- Ignore `Items.en.tsv`, `Items.fr.tsv`, etc.
- Fall back to a default locale if specified locale file doesn't exist

### Lazy vs Eager Joining

**Option A: Eager (at load time)**
- Join files immediately when loading
- Simpler export logic
- Memory overhead if joins aren't always needed

**Option B: Lazy (at export time)** *(Recommended)*
- Keep files separate in memory
- Join only when exporting
- Allows selective joining based on export configuration

### Row Order Preservation

The joined result should preserve the row order of the primary file. Secondary file row order is irrelevant since rows are matched by key.

## Open Questions

1. **Should we support composite join keys?** (Multiple columns as the join key)

2. **How to handle optional secondary files?** (e.g., a locale file that doesn't exist yet)

3. **Should secondary files be allowed to define new rows?** (Currently only matching rows are considered)

4. **How does this interact with type inheritance?** (Secondary files might need a different type than the primary)

5. **Version compatibility**: Should we support files with different schema versions being joined?

6. **Editor integration**: How should editors (if any) handle joined files? Show them separately or merged?

## Future Enhancements

- **Column aliasing**: Allow renaming columns during join to avoid conflicts
- **Conditional joins**: Join based on criteria other than exact key match
- **Virtual columns**: Computed columns that combine data from multiple joined files
- **Join statistics**: Report on unmatched rows, coverage percentage, etc.
