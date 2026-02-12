# Internal Model Reference

This document specifies the internal Lua table structures created when TabuLua parses TSV data. It is intended for developers working on or extending the TabuLua engine itself.

For the user-facing view of this data (from the viewpoint of expressions, COG scripts, and validators), see [USER_DATA_VIEW.md](USER_DATA_VIEW.md).

## Overview

When TabuLua processes a TSV file, it creates a hierarchy of **immutable, read-only** Lua tables:

```
processFiles() result
  ├── packages          (map: package_id → manifest)
  ├── package_order     (array of package_id strings)
  ├── tsv_files         (map: file_path → dataset)
  ├── raw_files         (map: file_path → raw content string)
  ├── joinMeta          (join and validator metadata)
  ├── file2dir          (map: file_path → parent directory)
  ├── validationPassed  (boolean)
  └── validationWarnings (array of warning records)
```

Each **dataset** (parsed TSV file) contains:

```
dataset
  ├── [1]               header
  ├── [2..N]            data rows (or comment strings)
  ├── ["primaryKey"]    row by primary key (string)
  └── (callable)        dataset(line, col) → row or cell
```

Each **header** contains column definitions. Each **row** contains cells. Each **cell** stores four forms of a value.

---

## Cell

A cell is a **4-element read-only table** with a shared metatable that provides named access.

### Fields

| Index | Alias | Description |
|-------|-------|-------------|
| `[1]` | `.value` | Original TSV string. Empty string `""` if a column default was used |
| `[2]` | `.evaluated` | After expression evaluation. Same as `[1]` if the value was not an expression |
| `[3]` | `.parsed` | After type parsing. **This is the final typed value** (number, boolean, table, etc.) |
| `[4]` | `.reformatted` | Reformatted for TSV output. Preserves the original expression (with `=` prefix) if the value was an expression. Empty if a default was used (so the default is not "baked in") |

### Metatable

| Key | Value |
|-----|-------|
| `__index` | Function mapping `.value`, `.evaluated`, `.parsed`, `.reformatted` to indices 1-4 |
| `__tostring` | Returns `cell[4]` (the reformatted value) |
| `__type` | `"cell"` |

### Processing Pipeline

A cell is created by the column's `__call` metamethod. The pipeline is:

1. **Raw value**: Original TSV string
2. **Default application**: If cell is empty and column has `default_expr`, substitute it
3. **Expression evaluation**: If value starts with `=`, evaluate as Lua in sandboxed environment
4. **Type parsing**: Parse the evaluated value using the column's parser. If the value was an expression, parse in `"parsed"` mode (expecting a typed value); otherwise parse in `"tsv"` mode (expecting a string representation)
5. **Reformatting**: Convert parsed value back to TSV representation. If the original value was an expression, keep the expression. If a default was used, keep the original empty string

### Example

For a column `price:float` with raw value `=self.base * 2` where `self.base` is `50`:

```lua
cell[1]  -- "=self.base * 2"   (original expression)
cell[2]  -- 100                 (evaluated result)
cell[3]  -- 100.0              (parsed as float)
cell[4]  -- "=self.base * 2"   (preserves expression for output)
```

For a column `count:integer:1` with an empty cell:

```lua
cell[1]  -- ""     (original empty value)
cell[2]  -- 1      (evaluated from default "1")
cell[3]  -- 1      (parsed as integer)
cell[4]  -- ""     (preserves empty for output, so default isn't baked in)
```

---

## Column (Header Cell)

A column is a **read-only table** describing one column of the TSV header. Columns are created by `newHeaderColumn()`.

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | `string` | Column name (extracted before the first `:`). Options like `!` are stripped |
| `idx` | `integer` | 1-based column index in the header |
| `type_spec` | `string` | Original type specification string (after the first `:`). Defaults to `"string"` if omitted |
| `type` | `string` | Evaluated type specification. Same as `type_spec` unless the type spec was an expression |
| `parser` | `function\|nil` | Parser function for this type. `nil` if the type is not recognized |
| `default_expr` | `string\|nil` | Default value expression (after the second `:`). `nil` if no default |
| `valid_name` | `boolean` | `true` if the column name is a valid identifier or exploded path |
| `is_exploded` | `boolean` | `true` if the name contains dots (e.g., `location.level`) or brackets (e.g., `items[1]`) |
| `exploded_path` | `table\|nil` | Split path segments as an array (e.g., `{"location", "level"}`). `nil` if not exploded |
| `is_collection` | `boolean` | `true` if the name uses bracket notation (e.g., `items[1]`) |
| `collection_info` | `table\|nil` | `{base_path, index, is_map_value}` for collection columns. `nil` if not a collection |
| `subscribers` | `function\|nil` | Column subscriber function called as `subscribers(col, row, cell)` after each cell is created |

### Options

If the `defaultOptionsExtractor` is used, the column name may end with `!` to mark it as **published**. The `!` is stripped from `name` and `options.published = true` is set.

### Metatable

| Key | Value |
|-----|-------|
| `__tostring` | Returns `"name:type_spec"` or `"name:type_spec:default_expr"` |
| `__call` | `col(eval_row, raw_value)` → creates and returns a cell |
| `__type` | `"column"` |
| `__index` | Function: `.value`, `.evaluated`, `.parsed`, `.reformatted` all return the same string `"name:type_spec[:default_expr]"` |
| `header` | Reference to the containing header table |

### Cell-like Access

A column supports the same named accessors as a cell (`.value`, `.evaluated`, `.parsed`, `.reformatted`), but they all return the column's string representation. This allows code that generically accesses "any table element" to work uniformly with both data rows and the header row.

---

## Header

The header is a **read-only table** containing all column definitions for a TSV file. It is always stored at `dataset[1]`.

### Index Access

| Key | Returns |
|-----|---------|
| `header[i]` (integer) | Column at index `i` |
| `header["colName"]` (string) | Column by name |
| `header.__dataset` | Reference to the containing dataset |
| `header.__source` | Source file name/path (string) |

### Metatable

| Key | Value |
|-----|-------|
| `__tostring` | Returns the reformatted header line (tab-separated column specs) |
| `__type` | `"header"` |
| `__type_spec` | Generated record type spec for the row type, e.g., `"{count:integer,name:string,price:float}"`. Column names are sorted alphabetically. Exploded columns are collapsed to their root name with the analyzed structure type |
| `__exploded_map` | Map of root names to their exploded structure definitions (see [Exploded Structure Definitions](#exploded-structure-definitions)) |

### Duplicate Detection

Column names must be unique within a header. Duplicate names cause an error and abort header creation.

---

## Row

A data row is a **read-only table** containing cells indexed both by position and by column name.

### Index Access

| Key | Returns |
|-----|---------|
| `row[i]` (integer) | Cell at column index `i` |
| `row["colName"]` (string) | Cell by column name (via header lookup) |
| `row["explodedRoot"]` (string) | Assembled exploded value (computed lazily via `assembleExplodedValue`) |
| `row.__idx` | 1-based index of this row in the dataset (integer). Row 1 is the header, so `__idx` ≥ 2 for data rows |
| `row.__dataset` | Reference to the containing dataset |

### Metatable

| Key | Value |
|-----|-------|
| `__tostring` | Returns the reformatted row (tab-separated cell values) |
| `__index` | Custom function that resolves string keys through the header, then checks the exploded map |

### Primary Key

The **first column** (`row[1]`) is the primary key. Its `.evaluated` value is used as the key for dataset lookup. The primary key must be a basic type (string, number, boolean). If it is a number, it is converted to a string for the dataset key to avoid conflicts with integer indices.

### Expression Evaluation Row (eval_row)

During cell processing, a separate mutable `eval_row` table is maintained alongside the read-only `new_row`. The `eval_row` stores **parsed values directly** (not cells), keyed by both index and column name. This is the table that becomes `self` in cell expressions, which is why `self.colName` returns the parsed value directly rather than a cell object.

```lua
-- During processing, for each cell:
eval_row[ci] = value.parsed       -- by index
eval_row[col.name] = value.parsed -- by name
```

### Cell Processing Order

Cells within a row are processed in **dependency order**, not left-to-right. The `canProcessCell()` function analyzes expression references to `self.colName` or `self[idx]` to determine which cells can be processed based on which columns have already been completed. This ensures expressions can reference columns that appear later in the header.

---

## Dataset

A dataset is a **read-only table** representing a fully parsed TSV file.

### Index Access

| Key | Returns |
|-----|---------|
| `dataset[1]` | The header (always present) |
| `dataset[i]` (integer, i > 1) | Data row, or a raw string for comment/blank lines |
| `dataset["primaryKey"]` (string) | Row by primary key value (string form of `row[1].evaluated`) |

### Callable

The dataset is callable: `dataset(line, col)`
- `dataset(line)` → returns the row at `line` (by index or primary key)
- `dataset(line, col)` → returns the cell at `(line, col)` where `col` is a column index or name

### Metatable

| Key | Value |
|-----|-------|
| `__tostring` | Returns the full TSV content. For transposed files, re-transposes before output, converting `__comment` placeholder columns back to comment lines |
| `__type` | `"tsv"` |
| `__transposed` | `true` if this file was loaded from a `.transposed.tsv` file |
| `__call` | The callable access function described above |
| `["primaryKey"]` | Direct primary key → row mappings are stored in the metatable's own table |

### Comments and Blank Lines

Non-table entries in the dataset (at indices > 1) are raw strings representing comment lines (`# ...`) or blank lines from the original TSV. They are preserved as-is for round-trip fidelity.

---

## Package Manifest

A manifest is a **read-only table** created from `Manifest.transposed.tsv`.

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `path` | `string` | Full file path of the manifest file |
| `package_id` | `string` | Package identifier (e.g., `"tutorial.core"`) |
| `name` | `string` | Human-readable package name |
| `version` | `string` | Semantic version string |
| `description` | `string` | Markdown description |
| `url` | `string\|nil` | Source URL |
| `custom_types` | `table\|nil` | Read-only array of custom type definition records |
| `code_libraries` | `table\|nil` | Read-only array of `{name, path}` tuples |
| `dependencies` | `table\|nil` | Read-only array of dependency records (see below) |
| `load_after` | `table\|nil` | Read-only array of package ID strings |
| `package_validators` | `table\|nil` | Read-only array of validator specs |

### Dependency Records

Each dependency in `manifest.dependencies` is a read-only table:

| Field | Type | Description |
|-------|------|-------------|
| `package_id` | `string` | The required package ID |
| `req_op` | `string` | Version comparison operator (`=`, `>`, `>=`, `<`, `<=`, `~`, `^`) |
| `req_version` | `string` | Required version string |

### Custom Type Definition Records

Each entry in `manifest.custom_types` has:

| Field | Type | Description |
|-------|------|-------------|
| `name` | `string` | Type name |
| `parent` | `string` | Parent type spec |
| `min` | `number\|nil` | Minimum value (numeric types) |
| `max` | `number\|nil` | Maximum value (numeric types) |
| `minLen` | `integer\|nil` | Minimum string length |
| `maxLen` | `integer\|nil` | Maximum string length |
| `pattern` | `string\|nil` | Lua pattern constraint |
| `values` | `table\|nil` | Allowed enum values |
| `validate` | `string\|nil` | Expression-based validator |

---

## Exploded Structure Definitions

The `__exploded_map` in the header metatable maps root names to structure definitions. These are produced by `analyzeExplodedColumns()`.

### Structure Types

Each structure definition is a table with a `type` field:

#### Leaf

```lua
{
    type = "leaf",
    col_idx = 3,           -- Column index in the header
    type_spec = "integer"  -- Type of this leaf column
}
```

#### Record

```lua
{
    type = "record",
    type_spec = "{level:name,position:{integer,integer}}",
    fields = {
        level = { type = "leaf", col_idx = 2, type_spec = "name" },
        position = { type = "tuple", ... }
    }
}
```

#### Tuple

```lua
{
    type = "tuple",
    type_spec = "{integer,integer,integer}",
    fields = {
        [1] = { type = "leaf", col_idx = 4, type_spec = "integer" },
        [2] = { type = "leaf", col_idx = 5, type_spec = "integer" },
        [3] = { type = "leaf", col_idx = 6, type_spec = "integer" }
    }
}
```

#### Array

```lua
{
    type = "array",
    type_spec = "{string}",
    element_type = "string",
    max_index = 3,
    element_columns = {
        [1] = 7,   -- Column index for items[1]
        [2] = 8,   -- Column index for items[2]
        [3] = 9    -- Column index for items[3]
    }
}
```

#### Map

```lua
{
    type = "map",
    type_spec = "{string:integer}",
    key_type = "string",
    value_type = "integer",
    max_index = 2,
    key_columns = {
        [1] = 10,  -- Column index for stats[1]  (key)
        [2] = 12   -- Column index for stats[2]  (key)
    },
    value_columns = {
        [1] = 11,  -- Column index for stats[1]= (value)
        [2] = 13   -- Column index for stats[2]= (value)
    }
}
```

### Assembly

When a row is accessed with an exploded root name (e.g., `row.location`), `assembleExplodedValue()` recursively builds the nested value from the individual cells. The result is a read-only table matching the structure type:

- **Leaf**: Returns `cell.parsed`
- **Record**: Returns a read-only table with named fields
- **Tuple**: Returns a read-only tuple (sequence)
- **Array**: Returns a read-only array
- **Map**: Returns a read-only map (skipping nil keys)

---

## processFiles() Result

The top-level `processFiles(directories, badVal)` function returns a result table (or `nil` on fatal error):

| Field | Type | Description |
|-------|------|-------------|
| `raw_files` | `table` | Map of absolute file path → raw file content string |
| `tsv_files` | `table` | Map of absolute file path → dataset (parsed TSV). Includes both data files and manifest/descriptor files |
| `package_order` | `table` | Array of package ID strings in dependency-resolved load order |
| `packages` | `table` | Map of package ID → manifest (read-only) |
| `joinMeta` | `table` | Join and validator metadata (see below) |
| `file2dir` | `table` | Map of absolute file path → parent directory path |
| `validationPassed` | `boolean` | `true` if all error-level validators passed |
| `validationWarnings` | `table` | Array of warning records |

### joinMeta

| Field | Type | Description |
|-------|------|-------------|
| `lcFn2JoinInto` | `table` | Map of lowercase filename → lowercase target filename |
| `lcFn2JoinColumn` | `table` | Map of lowercase filename → join column name |
| `lcFn2Export` | `table` | Map of lowercase filename → export flag (boolean) |
| `lcFn2JoinedTypeName` | `table` | Map of lowercase filename → joined type name |
| `lcFn2RowValidators` | `table` | Map of lowercase filename → array of row validator specs |
| `lcFn2FileValidators` | `table` | Map of lowercase filename → array of file validator specs |

### Validation Warning Records

Each warning in `validationWarnings` has:

| Field | Type | Description |
|-------|------|-------------|
| `validator` | `string` | The validator expression |
| `message` | `string` | The warning message |
| `rowIndex` | `integer\|nil` | Row index (for row validators) |
| `fileName` | `string\|nil` | File name (for file validators) |
| `packageId` | `string\|nil` | Package ID (for package validators) |

---

## Processing Pipeline

The complete processing pipeline, in order:

1. **Collect files** from directories (filtered by supported extensions)
2. **Extract and load manifest files** (`Manifest.transposed.tsv`)
3. **Register custom types** from manifests
4. **Load code libraries** from manifests into `loadEnv`
5. **Resolve package dependencies** (topological sort)
6. **Load file descriptors** (`Files.tsv`) in package dependency order
7. **Process data files** in `loadOrder` within each package:
   a. Run COG processing on raw content
   b. Parse raw TSV into `raw_tsv` structure
   c. Build header (column definitions)
   d. For each row, process cells in dependency order
   e. Publish data if `publishContext`/`publishColumn` configured
   f. Register enum parsers for enum-type files
   g. Register type aliases for type-definition files
   h. Register file column structure as a record type
8. **Run validators** (row → file → package)
9. **Return result** with all parsed data and metadata

### Read-Only Enforcement

All returned structures (cells, columns, headers, rows, datasets, manifests) are wrapped with `readOnly()`, which creates a proxy table with a metatable that:
- Allows read access via `__index`
- Throws an error on any write attempt via `__newindex`
- Preserves `ipairs`, `pairs`, `#` via `__len` and `__pairs`/`__ipairs`

This immutability ensures data integrity across expression evaluation, validators, and exports.
