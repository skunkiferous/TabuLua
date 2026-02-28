# Migration Tool

The migration tool provides a programmatic and command-line interface for batch modifications
to TSV data files. It works at the **raw** level (no type parsing or validation) and is
designed for data migrations — adding, removing, or renaming columns, updating cell values,
reorganizing files, and similar structural changes to data packages.

## Quick Start

### Command Line

```bash
# Show usage and available commands
lua54 migration.lua

# Run a migration script
lua54 migration.lua migrate_v2.tsv ./my_package/

# Dry run (validate without writing to disk)
lua54 migration.lua migrate_v2.tsv ./my_package/ --dry-run

# Verbose output (log each step)
lua54 migration.lua migrate_v2.tsv ./my_package/ --verbose

# Set log level
lua54 migration.lua migrate_v2.tsv ./my_package/ --log-level=debug
```

### Programmatic Usage

```lua
local migration = require("migration")

local ok, err = migration.run("migrate_v2.tsv", "/path/to/data", {
    dryRun = false,    -- skip disk writes when true
    verbose = true,    -- log each step
    logger = myLogger, -- optional custom logger
})
if not ok then
    print("Migration failed: " .. err)
end
```

## CLI Arguments

| Argument | Description |
|----------|-------------|
| `<script.tsv>` | Path to the migration script file (required) |
| `<rootDir>` | Root directory containing the data files (required) |
| `--dry-run` | Execute all operations but skip saving to disk |
| `--verbose` | Log each step before execution |
| `--log-level=LEVEL` | Set log level: `debug`, `info`, `warn`, `error`, `fatal` |

## Migration Script Format

A migration script is a TSV file where each row is a command. The first data row is the
header (ignored). Comments (`# ...`) and blank lines are allowed and skipped during execution.

### Example Script

```tsv
# Migration: v1 to v2
#
command	p1	p2	p3	p4	p5
#
# Load files
loadFile	CustomType.tsv
loadFile	Unit.tsv
loadFile	Files.tsv
#
# Rename superType to parent
renameColumn	CustomType.tsv	superType	parent
setColumnType	CustomType.tsv	parent	type_spec|nil
moveColumn	CustomType.tsv	parent	name
#
# Add parent column to Unit
addColumn	Unit.tsv	parent:type_spec|nil	name
setCells	Unit.tsv	parent	number
#
# Reorganize Unit into subfolder
renameFile	Unit.tsv	CustomType/Unit.tsv
filesUpdatePath	Unit.tsv	CustomType/Unit.tsv
#
# Save everything
saveAll
```

### Column Header Format

Column specs in the script header and in commands like `addColumn` and `createFile` use the
standard TabuLua format: `name:typeSpec` or `name:typeSpec:default`. The migration tool does
not validate types — it preserves them as-is in the header cells.

## Script Commands

### File Commands

| Command | p1 | p2 | Description |
|---------|----|----|-------------|
| `loadFile` | fileName | | Load a TSV file from disk |
| `loadTransposedFile` | fileName | | Load and transpose a `.transposed.tsv` file |
| `saveFile` | fileName | | Save a single file to disk |
| `saveAll` | | | Save all modified files to disk |
| `createFile` | fileName | colSpecs | Create a new file (see below) |
| `deleteFile` | fileName | | Remove file from dataset and delete from disk |
| `renameFile` | oldName | newName | Rename a file in the dataset |

**`createFile` column specs** are pipe-delimited in p2 to work within the TSV column limit:

```
createFile	NewFile.tsv	id:string|name:text|value:number
```

### Column Commands

| Command | p1 | p2 | p3 | Description |
|---------|----|----|-----|-------------|
| `addColumn` | fileName | columnSpec | afterCol | Add a column (see position below) |
| `removeColumn` | fileName | columnName | | Remove a column and its data |
| `renameColumn` | fileName | oldName | newName | Rename a column |
| `moveColumn` | fileName | columnName | afterCol | Move a column (see position below) |
| `setColumnType` | fileName | columnName | newType | Change the type in a column header |

**Column position** (`afterCol` parameter):
- Empty or omitted: append at the end
- `*`: insert at the beginning (before all columns)
- A column name: insert after that column

### Row Commands

| Command | p1 | p2 | Description |
|---------|----|----|-------------|
| `addRow` | fileName | values | Add a row with pipe-delimited values |
| `removeRow` | fileName | key | Remove a row by its primary key (column 1 value) |

**`addRow` values** are pipe-delimited in p2:

```
addRow	Items.tsv	sword|Iron Sword|25
```

### Cell Commands

| Command | p1 | p2 | p3 | p4 | p5 |
|---------|----|----|-----|-----|-----|
| `setCell` | fileName | key | columnName | value | |
| `setCells` | fileName | columnName | value | | |
| `setCellsWhere` | fileName | columnName | value | whereCol | whereVal |
| `transformCells` | fileName | columnName | expression | | |

- **`setCell`**: Set a single cell by primary key and column name
- **`setCells`**: Set all cells in a column to the same value
- **`setCellsWhere`**: Set cells in a column where another column matches a value
- **`transformCells`**: Apply a Lua expression to each cell in a column (sandboxed)

#### Transform Expressions

The `transformCells` expression runs in a sandbox with these variables:

| Variable | Description |
|----------|-------------|
| `value` | Current cell value (string) |
| `key` | Primary key of the current row |
| `rowIndex` | 1-based data row index |
| `getCell(file, key, col)` | Read any cell in the dataset |
| `getRow(file, key)` | Read any row as a name-value table |

Example: `tostring(tonumber(value) * 2)` — doubles a numeric column.

If the expression returns `nil`, the cell value is left unchanged.

### Comment and Blank Line Commands

| Command | p1 | p2 | p3 | p4 |
|---------|----|----|-----|-----|
| `addComment` | fileName | text | posType | posValue |
| `addBlankLine` | fileName | posType | posValue | |

**Position types** for line insertion:

| posType | posValue | Description |
|---------|----------|-------------|
| (empty) | | Append at end of file |
| `afterHeader` | | After the header row |
| `beforeHeader` | | Before the header row |
| `afterRow` | key | After the row with given primary key |
| `beforeRow` | key | Before the row with given primary key |
| `atEnd` | | At the end of the file |
| `rawIndex` | number | At a specific raw line index |

### Files.tsv Helper Commands

These commands operate on the `Files.tsv` file registry:

| Command | p1 | p2 | Description |
|---------|----|----|-------------|
| `filesUpdatePath` | oldPath | newPath | Update a file's path (primary key) |
| `filesUpdateSuperType` | fileName | newSuperType | Update a file's superType |
| `filesUpdateLoadOrder` | fileName | newLoadOrder | Update a file's loadOrder |
| `filesUpdateTypeName` | fileName | newTypeName | Update a file's typeName |

**Note:** `Files.tsv` must be loaded before using these commands.

### Control Commands

| Command | p1 | p2 | Description |
|---------|----|----|-------------|
| `echo` | message | | Print a message (only in verbose mode or with a logger) |
| `assert` | fileName | | Fail if the file is not loaded |
| `assertColumn` | fileName | columnName | Fail if the column does not exist |

## DataSet API

The `data_set` module provides the underlying API used by the migration script executor.
It can also be used directly for programmatic data manipulation.

```lua
local data_set = require("data_set")

local ds = data_set.new("/path/to/data")

-- Load and inspect
ds:loadFile("Items.tsv")
print(ds:rowCount("Items.tsv"))           -- number of data rows
print(ds:getCell("Items.tsv", "sword", "name"))  -- cell by key + column
local names = ds:getColumnNames("Items.tsv")     -- ordered column names

-- Modify
ds:addColumn("Items.tsv", "weight:float", {after = "name"})
ds:setCell("Items.tsv", "sword", "weight", "3.5")
ds:renameColumn("Items.tsv", "desc", "description")

-- Save
ds:saveFile("Items.tsv")  -- or ds:saveAll() for all dirty files
```

### Constructor

```lua
data_set.new(rootDir, options)
```

- `rootDir` — absolute path to an existing directory (required)
- `options.logger` — custom logger instance (optional)

### File Operations

| Method | Description |
|--------|-------------|
| `loadFile(fileName)` | Load a TSV file from `rootDir/fileName` |
| `loadTransposedFile(fileName)` | Load and transpose a `.transposed.tsv` file |
| `saveFile(fileName)` | Write file to disk, creating parent directories as needed |
| `saveAll()` | Save all files with unsaved changes |
| `createFile(fileName, colSpecs)` | Create a new in-memory file with pipe-delimited column specs |
| `deleteFile(fileName)` | Remove from dataset and delete from disk |
| `renameFile(oldName, newName)` | Rename a file (saved to new path on next save) |
| `copyFile(sourceName, targetName)` | Create an independent deep copy |

### Query Operations

| Method | Description |
|--------|-------------|
| `listFiles()` | Sorted list of loaded file names |
| `hasFile(fileName)` | Check if a file is loaded |
| `getFile(fileName)` | Get the raw file entry |
| `isDirty(fileName)` | Check if file has unsaved changes |
| `getColumnNames(fileName)` | Ordered list of column names |
| `getColumnSpec(fileName, colName)` | Full header spec string |
| `getColumnIndex(fileName, colName)` | 1-based column index |
| `hasColumn(fileName, colName)` | Check if column exists |
| `rowCount(fileName)` | Number of data rows |
| `hasRow(fileName, key)` | Check if row exists by primary key |
| `getRow(fileName, key)` | Row as `{colName = value, ...}` table |
| `getRowByIndex(fileName, index)` | Row by 1-based data row index |
| `getCell(fileName, key, colName)` | Single cell value |

### Column Operations

| Method | Description |
|--------|-------------|
| `addColumn(fileName, spec, pos)` | Add column; `pos`: `{after="col"}`, `{before="col"}`, `{index=N}`, or `nil` (append) |
| `removeColumn(fileName, colName)` | Remove column and all its data |
| `renameColumn(fileName, old, new)` | Rename column, preserving type and position |
| `moveColumn(fileName, colName, pos)` | Reorder column (same position format as `addColumn`) |
| `setColumnType(fileName, colName, type)` | Change column type in header |
| `setColumnDefault(fileName, colName, def)` | Set or remove default value |

### Row Operations

| Method | Description |
|--------|-------------|
| `addRow(fileName, values)` | Append row from a sequence or `{col=val}` table |
| `removeRow(fileName, key)` | Remove row by primary key |

### Cell Operations

| Method | Description |
|--------|-------------|
| `setCell(fileName, key, colName, val)` | Set a single cell |
| `setCells(fileName, colName, val)` | Set all cells in a column |
| `setCellsWhere(file, col, val, wCol, wVal)` | Conditional set |
| `transformCells(fileName, colName, expr)` | Apply sandboxed expression |

### Comment and Blank Line Operations

| Method | Description |
|--------|-------------|
| `addComment(fileName, text, pos)` | Insert comment line |
| `addBlankLine(fileName, pos)` | Insert blank line |
| `removeLineAt(fileName, rawIndex)` | Remove a raw line (not the header) |
| `getRawLineCount(fileName)` | Total raw lines (data + comments + blanks) |
| `getRawLine(fileName, rawIndex)` | Get raw line at index |
| `isCommentLine(fileName, rawIndex)` | Check if line is a comment |
| `isBlankLine(fileName, rawIndex)` | Check if line is blank |

### Helpers

```lua
-- Files.tsv helper (file must be loaded first)
local fh = ds:filesHelper()            -- or ds:filesHelper("Files.tsv")
fh:updatePath("Old.tsv", "New.tsv")
fh:updateSuperType("File.tsv", "custom_type_def")
fh:updateLoadOrder("File.tsv", "100")
fh:updateTypeName("File.tsv", "NewType")
fh:addEntry({"File.tsv", "Type", "parent", "50"})
fh:removeEntry("File.tsv")
local entry = fh:getEntry("File.tsv")

-- Manifest helper (manifest must be loaded first)
local mh = ds:manifestHelper()         -- or ds:manifestHelper("Manifest.transposed.tsv")
local val = mh:getField("package_id")
mh:setField("version", "2.0.0")
local pid = mh:getPackageId()
local ver = mh:getVersion()
```

## Error Handling

All operations return `nil, errorMessage` on failure. The migration script executor stops
on the first error and reports the step number:

```
step 3 (renameColumn): column not found: nonexistent in Items.tsv
```

In dry-run mode, `saveFile` and `saveAll` are skipped but all other operations execute
normally, allowing validation of the migration logic without modifying files on disk.
