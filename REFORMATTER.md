# Reformatter

A Lua tool for processing, reformatting, and exporting TSV data files to various formats.

## Overview

The reformatter processes TSV (Tab-Separated Values) data files from specified directories. It performs two main functions:

1. **Reformatting**: Parses and re-serializes TSV files in-place to ensure consistent formatting
2. **Exporting**: Converts TSV files to various output formats for use in different applications

## Installation

Ensure you have Lua installed and the required modules available in your path:
- `semver`
- `named_logger`
- `read_only`
- `file_util`
- `manifest_loader`
- `error_reporting`
- `exporter`
- `serialization`
- `manifest_info`

## Command Line Usage

```
lua reformatter.lua [OPTIONS] <dir1> [dir2] ...
```

### Arguments

| Argument | Description |
|----------|-------------|
| `<dir1> [dir2] ...` | One or more directories containing TSV files to process |

### Options

| Option | Description |
|--------|-------------|
| `--export-dir=<dir>` | Set the base export directory (default: `exported`). Output goes to subdirectories like `exported/json-natural/`. |
| `--file=<format>` | Output file format (see [File Formats](#file-formats) below) |
| `--data=<format>` | Data serialization format (see [Data Formats](#data-formats) below). Required for some file formats, optional for others. |
| `--collapse-exploded` | Collapse exploded columns into single composite columns during export (e.g., `location.level` + `location.x` → `location:{level,x}`). Default: keep exploded columns as separate flat columns. |
| `--clean` | Empty the export directory before exporting. Removes all existing files and subdirectories. |
| `--no-number-warn` | Suppress the informational warnings about `number` type usage (recommending `float` instead). Useful when `number` is intentionally used for mixed integer/decimal formatting. |
| `--log-level=<level>` | Set log verbosity: `debug`, `info`, `warn`, `error`, `fatal` (default: `info`). |

## File Formats

The `--file=<format>` option specifies the output file type. Each file format supports specific data formats.

| File Format | Extension | Description | Valid Data Formats | Default Data |
|-------------|-----------|-------------|-------------------|--------------|
| `json` | `.json` | JSON array-of-arrays | json-typed, json-natural | json-natural |
| `lua` | `.lua` | Lua table (sequence-of-sequences) | lua | lua |
| `mpk` | `.mpk` | MessagePack binary | mpk | mpk |
| `sql` | `.sql` | SQL CREATE TABLE + INSERT statements | json-typed, json-natural, xml, mpk | (none) |
| `tsv` | `.tsv` | Tab-separated values | lua, json-typed, json-natural | (none) |
| `xml` | `.xml` | XML document | xml | xml |

## Data Formats

The `--data=<format>` option specifies how Lua values are serialized within the output.

| Data Format | Description |
|-------------|-------------|
| `json-natural` | Standard JSON format (compatible with any JSON parser) |
| `json-typed` | JSON with Lua type preservation (integers as `{"int":"N"}`) |
| `lua` | Lua literal syntax |
| `mpk` | MessagePack binary format |
| `xml` | XML with type-tagged elements |

## Valid Combinations

Not all file/data format combinations are valid. The table below shows which combinations work:

| File Format | Data Formats | Default |
|-------------|--------------|---------|
| json | json-typed, json-natural | json-natural |
| lua | lua | lua |
| mpk | mpk | mpk |
| sql | json-typed, json-natural, xml, mpk | (none) |
| tsv | lua, json-typed, json-natural | (none) |
| xml | xml | xml |

**Note:** File formats with "(none)" as default require the `--data=` option to be specified explicitly.

## Directory Structure

Each export creates a subdirectory named `<file>-<data>` within the export directory:

```
exported/
  json-natural/
    data/file.json
  lua-lua/
    data/file.lua
  sql-json-natural/
    data/file.sql
```

## Examples

**Important:** Specify package directories directly (directories containing `Manifest.transposed.tsv` or `Files.tsv`), not parent directories. For example, use `tutorial/core/ tutorial/expansion/` instead of just `tutorial/`.

### Basic reformatting (no export)
```bash
lua reformatter.lua tutorial/core/ tutorial/expansion/
```
Processes all TSV files in the specified package directories and reformats them in-place if changes are detected.

### Export to JSON (natural format)
```bash
lua reformatter.lua --file=json tutorial/core/ tutorial/expansion/
```
Reformats files and exports as JSON to `exported/json-json-natural/`.

### Export to JSON with type preservation
```bash
lua reformatter.lua --file=json --data=json-typed tutorial/core/ tutorial/expansion/
```
Exports as JSON (typed format) to `exported/json-json-typed/`.

### Export as TSV with Lua literals
```bash
lua reformatter.lua --file=tsv --data=lua tutorial/core/ tutorial/expansion/
```
Exports as TSV with Lua literals to `exported/tsv-lua/`.

### Export to multiple formats
```bash
lua reformatter.lua --file=lua --file=json tutorial/core/ tutorial/expansion/
```
Exports to both `exported/lua-lua/` and `exported/json-json-natural/` simultaneously.

### Custom export directory with SQL
```bash
lua reformatter.lua --file=sql --data=json-natural --export-dir=db tutorial/core/ tutorial/expansion/
```
Exports as SQL with JSON columns to `db/sql-json-natural/`.

### Multiple source directories
```bash
lua reformatter.lua --file=json tutorial/core/ tutorial/expansion/ mods/ plugins/
```
Processes files from multiple directories, all exported to `exported/json-json-natural/`.

### Clean export directory before exporting
```bash
lua reformatter.lua --clean --file=json tutorial/core/ tutorial/expansion/
```
Empties the export directory before exporting new files.

### Compact binary export
```bash
lua reformatter.lua --file=mpk --export-dir=bin tutorial/core/ tutorial/expansion/
```
Exports to `bin/mpk-mpk/` in compact MessagePack format.

## JSON Serialization Note

Values exported as **JSON** use a non-standard mapping. Since Lua tables can contain both a sequence and "mapped values", they are serialized as JSON arrays, and the Object Notation is only used for special values that could otherwise not be represented, like "nan". For example, `{key="value"}` in Lua is serialized as `[0,["key","value"]]`. See the public API functions `serializeTableJSON()` and `serializeJSON()` of the module `serialization` for more details.

## SQL Type Mapping

The SQL exporter maps Lua/TSV types to SQL types as follows:

| TSV Type | SQL Type |
|----------|----------|
| `string` | `TEXT` |
| `float` | `REAL` |
| `integer` | `BIGINT` |
| `boolean` | `SMALLINT` (0/1) |
| `table` | `TEXT` (serialized) |

- The first column is automatically designated as `PRIMARY KEY`
- Non-optional columns include `NOT NULL` constraint
- Optional types (ending in `|nil`) allow NULL values

**Example SQL output:**
```sql
CREATE TABLE "items" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "name" TEXT NOT NULL,
  "data" TEXT NOT NULL
);
INSERT INTO "items" ("id","name","data") VALUES --
('1','Item A','{"nested":"value"}'),
('2','Item B','{"other":"data"}')
;
```

## Programmatic Usage

The reformatter can also be used as a Lua module:

```lua
local reformatter = require("reformatter")

-- Get version
print(reformatter.getVersion())

-- Process files with custom exporters
local exporter = require("exporter")
local serialization = require("serialization")
local directories = {"data/", "mods/"}

-- Exporters are tables with {fn, subdir, tableSerializer (for SQL)}
local exporters = {
    {fn = exporter.exportNaturalJSON, subdir = "json-json-natural"},
    {fn = exporter.exportLua, subdir = "lua-lua"},
    -- For SQL, include tableSerializer
    {fn = exporter.exportSQL, subdir = "sql-json-natural",
        tableSerializer = serialization.serializeTableNaturalJSON},
}
local exportParams = {exportDir = "output"}

reformatter.processFiles(directories, exporters, exportParams)
```

### Available Exporter Functions

| Function | Description |
|----------|-------------|
| `exporter.exportLuaTSV` | Export as TSV with Lua literal values |
| `exporter.exportJSONTSV` | Export as TSV with typed JSON values |
| `exporter.exportNaturalJSONTSV` | Export as TSV with natural JSON values |
| `exporter.exportLua` | Export as Lua tables |
| `exporter.exportJSON` | Export as typed JSON arrays |
| `exporter.exportNaturalJSON` | Export as natural JSON arrays |
| `exporter.exportXML` | Export as XML documents |
| `exporter.exportSQL` | Export as SQL (requires `tableSerializer`) |
| `exporter.exportMessagePack` | Export as MessagePack binary |

### Table Serializers (for SQL)

| Function | Description |
|----------|-------------|
| `serialization.serializeTableJSON` | Serialize tables as typed JSON |
| `serialization.serializeTableNaturalJSON` | Serialize tables as natural JSON |
| `serialization.serializeTableXML` | Serialize tables as XML |
| `serialization.serializeMessagePackSQLBlob` | Serialize tables as MessagePack BLOBs |

### Export Parameters

The `exportParams` table supports:

| Parameter | Description |
|-----------|-------------|
| `exportDir` | Base output directory (default: `"exported"`) |
| `formatSubdir` | Subdirectory for the current format (set automatically) |
| `tableSerializer` | Function for serializing Lua tables in SQL export |
| `exportExploded` | Set to `false` to collapse exploded columns |
| `cleanExportDir` | Set to `true` to empty export directory first |

## Format Comparison

| File + Data Format | Subdirectory | Human Readable | File Size | Use Case |
|--------------------|--------------|----------------|-----------|----------|
| tsv + lua | `tsv-lua/` | Yes | Medium | Lua applications |
| tsv + json-typed | `tsv-json-typed/` | Yes | Medium | Type-preserving TSV |
| tsv + json-natural | `tsv-json-natural/` | Yes | Medium | General purpose TSV |
| lua + lua | `lua-lua/` | Yes | Medium | Direct Lua loading |
| json + json-natural | `json-json-natural/` | Yes | Medium | Web/API |
| json + json-typed | `json-json-typed/` | Yes | Medium | Type-preserving JSON |
| xml + xml | `xml-xml/` | Yes | Large | Enterprise/Legacy |
| mpk + mpk | `mpk-mpk/` | No | Small | Performance-critical |
| sql + json-natural | `sql-json-natural/` | Partial | Large | Database import |
| sql + json-typed | `sql-json-typed/` | Partial | Large | Type-preserving DB |
| sql + xml | `sql-xml/` | Partial | Large | XML-capable databases |
| sql + mpk | `sql-mpk/` | No | Medium | Compact DB storage |

## Exploded Columns in Export

TSV files can use "exploded" column names with dots to represent nested structures. For example, columns like `location.level:name` and `location.position._1:integer` implicitly define a nested record/tuple structure.

By default, the reformatter preserves these exploded columns as-is during export, maintaining round-trip fidelity with the original file format.

### The `--collapse-exploded` Option

When you specify `--collapse-exploded`, the exporter collapses exploded columns into single composite columns:

**Without `--collapse-exploded` (default):**

```text
id:string  location.level:name  location.position._1:integer  location.position._2:integer
item1      zone_a               10                            20
```

**With `--collapse-exploded`:**

```text
id:string  location:{level:name,position:{integer,integer}}
item1      {level="zone_a",position={10,20}}
```

### When to Use

| Scenario | Recommendation |
|----------|----------------|
| Round-trip editing (export then re-import) | Default (no flag) |
| Compact export for external systems | `--collapse-exploded` |
| Human editing of exported files | Default (no flag) |
| Programmatic consumption | Either works |

### Using exportExploded in Code

When using the reformatter as a module, set `exportExploded` in the export parameters:

```lua
local exportParams = {
    exportDir = "output",
    exportExploded = false,  -- Collapse exploded columns
}
reformatter.processFiles(directories, exporters, exportParams)
```

## Error Handling

- The reformatter logs warnings when file content changes during reformatting
- Export directory is created automatically if it doesn't exist
- Failed file operations are logged with error details
- The process continues with remaining files after non-fatal errors
