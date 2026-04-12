# TSV Diff Tool

The TSV diff tool compares two TSV files at the data level, understanding columnar structure
rather than performing a naive line-by-line diff. It identifies structural differences (added,
removed, or renamed columns) and row-level differences (changed, added, or removed rows),
comparing only the common columns between the two files.

## Quick Start

### Command Line

```bash
# Show usage and available options
lua54 tsv_diff.lua

# Compare two files (order-based, default)
lua54 tsv_diff.lua old.tsv new.tsv

# Compare by primary key (first column)
lua54 tsv_diff.lua old.tsv new.tsv --mode=pk

# Ignore whitespace and case differences
lua54 tsv_diff.lua old.tsv new.tsv --trim --ignore-case

# Compare with numeric tolerance
lua54 tsv_diff.lua old.tsv new.tsv --epsilon=0.001

# Map renamed columns
lua54 tsv_diff.lua old.tsv new.tsv --map=old_score/new_score --map=old_id/new_id

# Show context lines around differences
lua54 tsv_diff.lua old.tsv new.tsv --context=3

# Limit output
lua54 tsv_diff.lua old.tsv new.tsv --max-diffs=10 --summary
```

### Programmatic Usage

```lua
local tsv_diff = require("tsv_diff")

-- Compare two files
local identical, output, diffCount, colInfo = tsv_diff.diff("old.tsv", "new.tsv", {
    mode = "pk",
    trim = true,
    epsilon = 0.001,
})
if identical then
    print("Files are identical")
else
    print(output)
    print("Differences: " .. diffCount)
end

-- Compare raw TSV structures directly
local raw_tsv = require("raw_tsv")
local data1 = raw_tsv.stringToRawTSV("name\tval\njohn\t1")
local data2 = raw_tsv.stringToRawTSV("name\tval\njohn\t2")
local identical, output = tsv_diff.diff(data1, data2)
```

## CLI Arguments

| Argument | Description |
|----------|-------------|
| `<file1.tsv>` | Path to the first TSV file (required) |
| `<file2.tsv>` | Path to the second TSV file (required) |

## Comparison Modes

| Mode | Option | Description |
|------|--------|-------------|
| Order-based | `--mode=order` | Compares rows by position (row 1 vs row 1, etc.). Default mode. Similar to a normal diff. |
| Primary-key-based | `--mode=pk` | Matches rows by the value in the first column (the primary key). Detects added, removed, and reordered rows. |

## Options

| Option | Description |
|--------|-------------|
| `--map=OLD/NEW` | Map column name `OLD` in file 1 to `NEW` in file 2. Use this when a column was renamed. Can be specified multiple times. |
| `--trim` | Ignore leading and trailing whitespace in cell values. |
| `--ignore-case` | Compare cell values case-insensitively. |
| `--epsilon=N` | Treat numbers within `N` of each other as equal. `N` can be a floating-point value (e.g., `0.001`). Non-numeric values are always compared exactly. |
| `--only=COL1,COL2,...` | Only compare the listed columns (plus the primary key in `pk` mode). Columns not listed are ignored in both structural and data comparison. |
| `--exclude=COL1,COL2,...` | Exclude the listed columns from comparison. Useful for ignoring timestamp or auto-generated columns. |
| `--context=N` | Show `N` unchanged rows around each difference (order mode only). Default: 0. |
| `--max-diffs=N` | Stop after `N` row-level differences. Useful to avoid flooding output on large files. |
| `--summary` | Suppress cell-level detail, show only which rows differ. |
| `--quiet` | Suppress the diff output entirely, show only the summary section. |
| `--log-level=LEVEL` | Set log level: `debug`, `info`, `warn`, `error`, `fatal`. |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Files are identical (on compared columns) |
| 1 | Differences found |
| 2 | Error (bad arguments, unreadable files, etc.) |

## How Comparison Works

### Column Analysis

Before comparing data, the tool analyzes the column structure of both files:

1. **Primary key** is always the first column. In `pk` mode, both files must have the
   same primary key column (or a `--map` must align them).
2. **Column order is ignored** (except column 1). Columns are matched by name, not
   position. If file 1 has columns `name, age, email` and file 2 has `name, email, age`,
   the values are matched correctly.
3. **Only common columns are compared.** A column present in one file but not the other
   is reported as "added" or "removed" in the column analysis, but does not cause every
   row to appear different.
4. **Column mappings** (`--map`) allow comparing columns with different names. This is
   useful when a column was renamed, or when a column type was renamed.

### Data Comparison

- **Comments and blank lines** are always skipped.
- **Missing cells** (rows shorter than the header) are treated as empty strings.
- When `--trim` is enabled, leading/trailing whitespace is stripped before comparison.
- When `--ignore-case` is enabled, values are lowercased before comparison.
- When `--epsilon` is set, values that are both valid numbers and within the tolerance
  are considered equal. Non-numeric values are always compared exactly.

### Order-Based Mode

Rows are compared by position: row 1 of file 1 against row 1 of file 2, and so on.
If one file has more rows, the extra rows appear as additions or removals.

With `--context=N`, unchanged rows around differences are included in the output,
separated by `...` when there are gaps.

### Primary-Key-Based Mode

Rows are matched by their primary key value (first column). This mode can detect:

- **Changed rows** — same primary key, different values in other columns.
- **Added rows** — primary key exists in file 2 but not file 1.
- **Removed rows** — primary key exists in file 1 but not file 2.
- **Reordered rows** — same data, different order. These are **not** reported as differences.

Duplicate primary keys in either file produce a warning.

## Output Format

The output uses a unified-diff style with three sections:

### 1. Column Analysis

```
=== Column Analysis ===
Primary key: name
Common columns: 3
Added columns (only in file 2): email
Removed columns (only in file 1): phone
Column mappings:
  'old_score' <-> 'new_score'
```

### 2. Diff Output

**Order-based mode:**
```
--- old.tsv
+++ new.tsv

  row 2 [alice]
~ row 3 [bob]
    age: '30' -> '31'
    score: '95' -> '98'
- row 4 [charlie]
+ row 5 [diana]
```

Markers:
- `~` changed row
- `-` removed row (only in file 1)
- `+` added row (only in file 2)
- `  ` (two spaces) context row (unchanged)
- `...` gap between context blocks

**Primary-key-based mode:**
```
--- old.tsv
+++ new.tsv

~ [bob]
    age: '30' -> '31'
- [charlie]
+ [diana]
```

### 3. Summary

```
=== Summary ===
Common columns compared: 3
Columns only in file 2: 1
Columns only in file 1: 1
Rows changed: 1
Rows added: 1
Rows removed: 1
Total differences: 3
```

## API Reference

### `tsv_diff.diff(input1, input2, options)`

Compares two TSV data sets.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `input1` | `string` or `table` | File path or raw TSV structure (from `raw_tsv.stringToRawTSV`) |
| `input2` | `string` or `table` | File path or raw TSV structure |
| `options` | `table` or `nil` | Options table (see below) |

**Options table fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `mode` | `string` | `"order"` | `"order"` or `"pk"` |
| `columnMap` | `table` | `nil` | Map of file 1 column names to file 2 column names |
| `trim` | `boolean` | `false` | Trim whitespace from values |
| `ignoreCase` | `boolean` | `false` | Case-insensitive comparison |
| `epsilon` | `number` | `nil` | Numeric tolerance |
| `only` | `table` | `nil` | Set of column names to compare (keys are names, values are `true`) |
| `exclude` | `table` | `nil` | Sequence of column names to exclude |
| `context` | `number` | `0` | Context lines (order mode only) |
| `maxDiffs` | `number` | `nil` | Maximum differences before stopping |
| `summary` | `boolean` | `false` | Suppress cell-level detail |
| `quiet` | `boolean` | `false` | Suppress diff output |

**Returns:**

| Position | Type | Description |
|----------|------|-------------|
| 1 | `boolean` or `nil` | `true` if identical, `false` if different, `nil` on error |
| 2 | `string` | Formatted output, or error message on failure |
| 3 | `number` or `nil` | Number of row-level differences, `nil` on error |
| 4 | `table` or `nil` | Column analysis result, `nil` on error |

The column analysis result (return value 4) contains:

| Field | Type | Description |
|-------|------|-------------|
| `commonCols` | `table` | Sequence of `{name1, idx1, name2, idx2}` for matched columns |
| `addedCols` | `table` | Sequence of column names only in file 2 |
| `removedCols` | `table` | Sequence of column names only in file 1 |
| `pkMatch` | `boolean` | Whether primary key columns match |
| `pkName1` | `string` | Primary key column name in file 1 |
| `pkName2` | `string` | Primary key column name in file 2 |
