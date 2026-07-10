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
| `--export-merged[=<dir>]` | Write a TSV snapshot of every dataset with all mod overrides applied (patches, schema overlays, package-scoped pre-processors) to `<dir>` (default: `merged`), mirroring the source layout. Independent of `--file=`; can run on its own. See [Merged Export (`--export-merged`)](#merged-export---export-merged). |
| `--explain-patch[=<filter>]` | Print which mod override set each cell / row / column. Optional `<filter>` = `<file>[:<pk>[:<column>]]` narrows the report. See [Explain Patch (`--explain-patch`)](#explain-patch---explain-patch). |
| `--cog-docs` | Refresh COG doc templates (`.md`/`.txt`/`.html` files containing a COG block) in place against the loaded data, keeping the markers so they stay re-runnable. Independent of reformat/export; nothing is exported. **Mutually exclusive with the export options** (`--file=`, `--data=`, `--strip-cog`, `--clean`, `--collapse-exploded`, `--export-dir=`, `--export-merged`) — combining them is an error. |
| `--strip-cog` | When exporting, strip the COG scaffolding (markers and code lines) from generated doc templates, leaving only the generated output for a clean published file. Default: off (markers kept). |
| `--no-number-warn` | Suppress the informational warnings about `number` type usage (recommending `float` instead). Useful when `number` is intentionally used for mixed integer/decimal formatting. |
| `--no-unquoted-warn` | Suppress the informational warnings about assuming a value is a single unquoted string. Useful when TSV data intentionally contains unquoted string values in array columns. |
| `--variant=<name>` | Activate a named variant for conditional file inclusion. Can be specified multiple times. Only `Files.tsv` rows whose `variant` column matches an active variant are loaded. See [Variant-Based Conditional File Inclusion](#variant-based-conditional-file-inclusion). |
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

### Export with variant selection

```bash
lua reformatter.lua --file=json --variant=en tutorial/core/ tutorial/expansion/
```
Activates the `en` variant, so only `Files.tsv` rows with `variant=en` (or no variant) are loaded. Files tagged with other variants (e.g., `fr`) are fully skipped.

### Export with multiple variants

```bash
lua reformatter.lua --file=json --variant=en --variant=ios tutorial/core/ tutorial/expansion/
```
Activates both the `en` and `ios` variants simultaneously.

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

-- Without variants (all rows active)
reformatter.processFiles(directories, exporters, exportParams)

-- With variants (only matching rows active)
reformatter.processFiles(directories, exporters, exportParams, {"en", "ios"})
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

## Variant-Based Conditional File Inclusion

The `--variant=<name>` option controls which `Files.tsv` rows are active during processing. This enables listing all localization, platform, or feature variants in a single `Files.tsv` and selecting which to load at processing time -- no more editing `Files.tsv` per export.

### How It Works

`Files.tsv` supports an optional `variant:name|nil` column. Rows with an empty variant value are **always active**. Rows with a non-empty variant value are **only active** when that variant name is passed via `--variant=<name>`. Files with inactive variants are fully skipped: not loaded, not exported, and not validated for joins.

### Example

Given this `Files.tsv`:

| fileName | ... | variant |
| ----------- | --- | ------- |
| Item.tsv | ... | |
| Item.en.tsv | ... | en |
| Item.fr.tsv | ... | fr |

- `--variant=en` loads `Item.tsv` and `Item.en.tsv`; skips `Item.fr.tsv`
- `--variant=fr` loads `Item.tsv` and `Item.fr.tsv`; skips `Item.en.tsv`
- No `--variant` flag skips both `Item.en.tsv` and `Item.fr.tsv`

### Variant Groups

Packages can declare **variant groups** in `Manifest.transposed.tsv` to enforce that exactly one variant from a group is selected. Groups can optionally specify a **default** variant that is applied automatically when no variant from that group is explicitly provided. See the `variant_groups` field in the [Data Format Specification](DATA_FORMAT_README.md#variant-group-validation).

## Pre-Processors and Round-Trip

Files may declare `preProcessors` in `Files.tsv` to mutate parsed rows after
loading (typically to derive inverse relations or normalise data). Those
mutations are intentionally **not** persisted on reformat: the reformatter
writes the original raw cells, exactly as the author wrote them. Round-trip
fidelity is preserved even when a processor has run. The processor's effects
remain visible to validators and exporters in memory; they just don't appear
on disk. See [DATA_FORMAT_README §Pre-Processors](DATA_FORMAT_README.md#pre-processors).

## Mod Overrides and Round-Trip

When a dependent package ships **mod overrides** — row patches, schema overlays,
or package-scoped pre-processors (see [DATA_FORMAT_README §Mod Overrides](DATA_FORMAT_README.md#mod-overrides)) —
the reformatter follows the same "no-bake" rule as for pre-processors: a parent
file that a mod patched is **left untouched on disk**. Its in-memory dataset
reflects the merged result (so validators and exporters see it), but reformatting
that file in place would write the mod's changes back into the parent's source, so
the reformatter skips it. The patch / overlay files themselves round-trip normally.

## Merged Export (`--export-merged`)

`--export-merged[=<dir>]` writes a **TSV snapshot of every loaded dataset with all
mod overrides applied** to a separate tree (default: `merged/`), so you can inspect
the final merged data without disturbing any source file. It is the deliberate
counterpart to the no-bake rule above: where in-place reformat *omits* overrides,
merged export *includes* them.

```bash
lua reformatter.lua --export-merged tutorial/core/ tutorial/expansion/
lua reformatter.lua --export-merged=build/merged tutorial/core/ tutorial/expansion/
```

- **Layout.** Each file is written to `<dir>/<package-dir-name>/<path-relative-to-it>`,
  so packages keep separate subtrees and the source layout is mirrored
  (`merged/core/Item.tsv`, `merged/expansion/ItemPatch.tsv`, …).
- **Independent of `--file=`.** It can run on its own (just load + merged snapshot)
  or alongside a format export. It is **mutually exclusive with `--cog-docs`**.
- **What it shows.** A cell whose final parsed value differs from its on-disk text
  is re-rendered (so patch edits, list/map deltas, schema-overlay defaults,
  package-processor writes, **and** ordinary resolved data — column defaults and
  file-level pre-processor output — all appear); every **unchanged** cell keeps its
  exact original text **byte-for-byte**, and `=expr` cells keep their expression. In
  other words it is a *fully-resolved* snapshot, not just "source + mod edits": diffing
  it against the sources shows everything the load resolved, which includes more than
  the mods alone. To attribute a specific cell to a specific override, use
  [`--explain-patch`](#explain-patch---explain-patch) instead.
- **Line endings.** Output is written verbatim as LF (the in-memory convention),
  matching reformatter behaviour — never CRLF — so a merged file does not differ from
  an LF source on whitespace alone.
- **Same name and format as the source.** Each merged file is encoded back to its
  source's on-disk format so it diffs cleanly against the original: plain `.tsv`/`.csv`
  written verbatim, a compressed `.gz` **re-compressed**, and a reversible transcoded
  source (`.eav`, id-selected `json:*` / `xml:tabulua`) **re-encoded** — reusing the
  same encoders as in-place reformat. (Diffing a re-compressed `.gz` needs a
  gz-aware diff, e.g. `git diff` or `zdiff`, which compares the decompressed contents.)
  **Archive (`.zip`) members are left as-is for now** and skipped, as are any
  non-reversible sources whose format can't be reproduced.
- **Sources are untouched.** Merged export never modifies the inputs; it only writes
  under `<dir>`.

## Explain Patch (`--explain-patch`)

`--explain-patch[=<filter>]` prints a **lineage report** answering "which mod override
set this?". Where `--export-merged` shows the merged *data*, `--explain-patch` shows the
*provenance* — every override write attributed to the file (or package) responsible.

```bash
lua reformatter.lua --explain-patch tutorial/core/ tutorial/expansion/
lua reformatter.lua --explain-patch=Item.tsv:healthPotion:price tutorial/core/ tutorial/expansion/
```

Example output (full report):

```text
=== Patch lineage ===

spell.tsv
  [schema] cooldown  newDefault 3.0   <- tutorial.expansion:SpellTuning.tsv

item.tsv
  [schema] price  widenTo gold|int   <- tutorial.expansion:ItemPricePolicy.tsv
  [schema] validator  suppress -> warn: self.price > 0 or 'price must be positive'   <- tutorial.expansion:ItemPricePolicy.tsv
  healthPotion
    price = -5   <- tutorial.expansion:ItemPatch.tsv
    tags append {clearance}   <- tutorial.expansion:ItemPatch.tsv
  shadowCloak
    price = 2100 (bulk 'epic_surcharge')   <- tutorial.expansion:ItemBulk.tsv
```

- **What it records.** Every kind of mod override: schema overlays (`widenTo`,
  `newDefault`, validator suppression), row ops (`add` / `remove` / `replace`),
  cell `update`s and list/map deltas (`append` / `remove` / in-place `replace`),
  `bulk` rule matches (named by their rule), and package-processor writes
  (attributed to `package:<id>`). When two mods write the same cell, both entries appear
  in apply order — the chain, last-writer-last.
- **Sources are package-qualified.** An override file is attributed as
  `<package_id>:<basename>` (e.g. `tutorial.expansion:ItemPatch.tsv`), so two mods
  shipping same-named patch files stay distinguishable.
- **Filter.** `<filter>` = `<file>[:<pk>[:<column>]]` narrows the report, e.g.
  `--explain-patch=Item.tsv` (one file), `…=Item.tsv:sword` (one row), or
  `…=Item.tsv:sword:price` (one cell). The file part is matched case-insensitively.
- **Cost.** Lineage tracking is **off by default** and adds zero overhead to a normal
  run; it is enabled only for this flag. Loads and reports; it does not require an
  export and is **mutually exclusive with `--cog-docs`**.

## Check Conflicts (`--check-conflicts`)

`--check-conflicts` prints a **conflicts-only report** answering "where do my mods
fight?". Where `--explain-patch` lists every override write, `--check-conflicts`
filters that lineage down to the slots where a later write **discards** an earlier
source's work, each shown as its apply-order chain (last writer wins).

```bash
lua reformatter.lua --check-conflicts tutorial/core/ tutorial/expansion/ mods/...
```

Example output:

```text
=== Override conflicts ===

item.tsv
  [schema] price  -- multiple defaults, last wins
    newDefault 50   <- ModA:PricePolicy.tsv
    newDefault 60   <- ModB:PricePolicy.tsv
  sword : price  -- multiple writers, last wins
    = 110   <- ModA:PricePatch.tsv
    = 120   <- ModB:PricePatch.tsv
  oldSword  -- row remove/replace vs. other writes
    price = 90   <- ModA:PricePatch.tsv
    [remove]   <- ModB:CleanupPatch.tsv

3 conflicting slot(s). Conflicts are legal; load order decides the winner (input-root order, dependencies, load_after).
```

- **What is flagged.** A cell whose whole value is rewritten (`= v` /
  `replace_whole`) after a *different* source already wrote it; a row removed or
  replaced while another source also wrote to it (in either order); a column
  default set by two or more overlays (`newDefault` is last-writer-wins).
- **What is NOT flagged (benign composition).** List/map deltas from several mods
  (`append` / `remove` / in-place `replace` compose in load order), `widenTo` from
  several overlays (order-independent union), validator suppressions
  (order-independent minimum), and a mod patching cells of a row another mod
  *added* — that is intentional mod-on-mod layering.
- **`onlyIfPackages` typo check.** The report also flags **gate ids** — the package
  ids a `Files.tsv` row lists in its `onlyIfPackages` column — that matched **no
  known package id** anywhere in the run: not a loaded package, and not named by any
  manifest's `dependencies` / `load_after` / `conflicts` (an id someone references is
  a real mod that is merely absent). A misspelled gate id otherwise deactivates its
  file silently, forever. When a known id is a close spelling match (case slip,
  swapped or dropped characters — edit distance, scaled to the id's length), the
  report suggests it:

  ```text
  === onlyIfPackages check ===

  Gate ids matching no loaded package and named by no manifest (possible typos):
    'CORE'   gates: CompatB.tsv   (did you mean 'Core'?)
  ```

  The section is printed only when there is something to flag.
- **Diagnostic, not a gate.** Conflicts are legal by design — load order decides —
  so the exit code stays 0. To change a winner, reorder the input-root arguments or
  add `load_after` / `dependencies` (see *Conflict Resolution* in the data-format
  guide); re-run to confirm.
- **Cost.** Same as `--explain-patch`: lineage tracking is enabled only for this
  flag (or when override work exists anyway). Loads and reports; no export needed;
  **mutually exclusive with `--cog-docs`**. Both reports can be printed in one run
  by passing both flags.

## Error Handling

- The reformatter logs warnings when file content changes during reformatting
- Export directory is created automatically if it doesn't exist
- Failed file operations are logged with error details
- The process continues with remaining files after non-fatal errors
