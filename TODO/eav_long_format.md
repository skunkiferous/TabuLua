# Add Entity–Attribute–Value (EAV / long-format) Table Support — new `raw_eav` module

## Summary

Add a new low-level module [raw_eav.lua](../raw_eav.lua) that reads and writes
tables stored in the **Entity–Attribute–Value (EAV)** layout — also called the
**"long" / "narrow" / "tidy-melted"** format. An EAV file is a plain
**3-column** table where each row is a single `(entity, attribute, value)`
triple:

```
item1   title     Sword
item1   damage    10
item2   title     Shield
item2   defense   5
```

- **column 1 — entity:** a *domain key* (the row's primary-key value, e.g.
  `item1`), **not** a numeric row index.
- **column 2 — attribute:** a *column name* (e.g. `title`, `damage`), **not** a
  numeric column index.
- **column 3 — value:** the cell value for that `(entity, attribute)` pair.

The module's job is a **pivot / un-pivot** between this long layout and the
normal "wide" table layout TabuLua already uses everywhere (row 1 = header of
column names, column 1 = primary key). Reading **rebuilds** the wide table;
writing **compresses** the wide table back to triples.

Everything stays at the raw level — cells are strings, exactly like
[raw_tsv.lua](../raw_tsv.lua). No type coercion; that is the caller's job.

## Why This Module (and not COO)

This plan replaces an earlier, now-removed plan that targeted **Matrix Market /
COO**, where the row and column identifiers are **1-based integer indices** into
a sparse matrix. The `.xyz` reference that prompted that plan meant something
unrelated, and the COO feature was never what was actually wanted.

What is actually wanted is the **EAV model**: a 3-column table whose row and
column identifiers are **domain keys / column names**, not indices. COO and EAV
look superficially similar (both are 3-column "triple" files) but are
semantically different:

| | COO (sparse matrix) | EAV (this plan) |
| --- | --- | --- |
| col 1 | integer row index `I` (1..M) | entity = PK value (string) |
| col 2 | integer col index `J` (1..N) | attribute = column name (string) |
| col 3 | numeric value | value (string) |
| header | `%%MatrixMarket …` + size line `M N L` | **none** (see below) |
| output shape | a 2/3/4-cell raw TSV mirroring the triples | a **rebuilt wide table** (header + PK rows) |

The decisive difference is the **output shape**. COO keeps the triples as
triples in the raw TSV structure. EAV **reconstructs the original wide table**
so the rest of the pipeline treats an EAV-stored file as an ordinary table.

### Why EAV files carry no header

Because every row already states its own entity *and* its own attribute name,
a header row in the source would be redundant and ambiguous — there is nowhere
for a per-column header to live, and a literal `entity attribute value` first
line would just parse as a bogus data triple. So:

- **EAV files are pure triples, no header.** Any header present in a source
  file is meaningless and is discarded.
- **Reading rebuilds** the wide table's header from the distinct attribute
  names, plus a synthesized name for the entity (PK) column.
- **Writing compresses** the wide table to triples, using the wide header's
  column names as the `attribute` cell. Only the **entity column's own header
  name is dropped** (re-synthesized on the next read, default `"name"`).

Round-trip is therefore *value-preserving but header-lossy by design* (the PK
column's display name is the single thing not stored). This is intentional and
documented.

## Data Representation

Both layouts use the shape `raw_tsv` already uses — a sequence whose elements
are either strings (comment / blank lines) or sequences of string cells. This
keeps EAV interoperable with every existing helper (`rawTSVToString`,
`isRawTSV`, `transposeRawTSV`, the migration `data_set`, etc.).

**Long (EAV) form** — what's on disk:

```lua
{
  {"item1", "title",   "Sword"},
  {"item1", "damage",  "10"},
  {"item2", "title",   "Shield"},
  {"item2", "defense", "5"},
}
```

**Wide form** — what the rest of the engine consumes (header first, PK first
column):

```lua
{
  {"name",  "title",  "damage", "defense"},  -- header ("name" key column synthesized)
  {"item1", "Sword",  "10",     ""},
  {"item2", "Shield", "",       "5"},
}
```

(The key column is named `"name"` by default — Unreal Engine's DataTable import
requires the row-key column to be called `name`. Override via `keyColumn`.)

Mapping rules, long → wide (the **rebuild**):

1. **Entities** become data rows, in **first-seen order** (the order each
   distinct entity first appears in the triples).
2. **Attributes** become columns, in **first-seen order** (the order each
   distinct attribute name first appears).
3. The header row is `{keyColumn, attr1, attr2, …}` where `keyColumn` is the
   synthesized PK-column name (option, default `"name"`).
4. Each data row is `{entity, v(attr1), v(attr2), …}`; a `(entity, attribute)`
   pair with no triple becomes `""` (an empty cell — a *ragged* / sparse EAV
   file is normal and expected).

Mapping rules, wide → long (the **compress**):

1. Row 1 is the header; cells `2..N` are the attribute names; cell 1 (the PK
   column name) is **discarded**.
2. For each subsequent data row, for each column `2..N`, emit
   `{row[1], header[i], row[i]}` **unless** the value is empty and
   `skipEmpty` is on (the default) — sparse tables stay sparse.

## File Format & Extension

There is **no de-facto standard extension** for EAV / long-format files in the
wild, so this plan settles on one explicitly and matches it explicitly, to keep
dispatch simple:

- **Extension: `.eav`.** A standalone extension, **not** `.eav.tsv`. A header-less
  triple file is *not* a valid TabuLua `.tsv` — a `.tsv` is expected to have a
  header row and a first-column primary key, and the loader/reformatter would
  (wrongly) treat it as a ready-made table. A distinct `.eav` extension is the
  signal "these bytes are not a table yet; transcode first."
- **Separator: tab (`\t`).** Despite not being a `.tsv`, the on-disk separator is
  a tab — "CSV" is read here as *character*-separated, not comma-separated. Keeping
  tab lets `raw_eav` delegate splitting, escaping, and UTF-8/EOL handling straight
  to `raw_tsv` with no comma-quoting rules to reinvent.
- **No header line.** Pure `(entity, attribute, value)` triples, as described
  above. `#`-comment and blank lines are still recognised (and skipped on read),
  inherited from `raw_tsv`.

The reader is otherwise content-agnostic — `stringToTable` / `eavToTable` accept
any 3-column structure regardless of where it came from — but `.eav` is the
canonical extension that an extension-keyed dispatcher (see "After It's Done")
matches on.

## Proposed API (`raw_eav.lua`)

The module mirrors `raw_tsv.lua`'s skeleton exactly: `semver` version, `NAME`,
`getVersion`, a `readOnly` `API` table, and the `__call` dispatcher
(`raw_eav("eavToTable", t)` etc.).

```lua
--- Rebuilds a wide table from an EAV (long, 3-column) raw TSV structure.
--- Entities become rows and attributes become columns, both in first-seen
--- order. Missing (entity, attribute) pairs become empty cells. A header row
--- {keyColumn, attr1, attr2, ...} is prepended (the entity column's name is
--- synthesized, since EAV files carry no header).
--- Comment/blank lines in the input are ignored.
--- @param eav table A raw TSV structure of 3-cell rows
--- @param opts table|nil { keyColumn="name", onConflict="error"|"first"|"last" }
--- @return table A wide raw TSV structure (header row + one row per entity)
--- @error Throws if eav is not a table, a data row does not have exactly 3
---        cells, an entity/attribute cell is empty, or a duplicate
---        (entity, attribute) pair is seen while onConflict="error"
local function eavToTable(eav, opts) ... end

--- Compresses a wide table into an EAV (long, 3-column) raw TSV structure.
--- Row 1 is treated as the header; cell 1 (the PK column's name) is discarded,
--- cells 2..N are the attribute names. Each data row yields one triple per
--- non-empty value (all values when opts.skipEmpty is false). Output is
--- header-less triples in row-major (per-entity, then per-attribute) order.
--- @param tbl table A wide raw TSV structure (header row + data rows)
--- @param opts table|nil { skipEmpty=true }
--- @return table A raw TSV structure of 3-cell rows
--- @error Throws if tbl is not a table, has no header row, has a duplicate or
---        empty attribute name in the header, or a data row has an empty entity
local function tableToEav(tbl, opts) ... end

--- Parses an EAV-format string into a wide raw TSV structure.
--- Equivalent to eavToTable(raw_tsv.stringToRawTSV(s), opts): inherits the
--- UTF-8 check, EOL normalization, comment/blank handling, and tab splitting.
--- @param s string The EAV file contents (valid UTF-8)
--- @param opts table|nil see eavToTable
--- @return table A wide raw TSV structure
--- @error Throws on the same conditions as stringToRawTSV / eavToTable
local function stringToTable(s, opts) ... end

--- Reads an EAV-format file and rebuilds the wide raw TSV structure.
--- Extension-agnostic; dispatch on extension (if wanted) belongs elsewhere.
--- @param file string The file path to read
--- @param opts table|nil see eavToTable
--- @return table|nil The wide raw TSV structure, or nil on read error
--- @return string|nil Error message on read failure, nil on success
local function fileToTable(file, opts) ... end

--- Serializes a wide raw TSV structure to an EAV-format string.
--- Equivalent to raw_tsv.rawTSVToString(tableToEav(tbl, opts)).
--- @param tbl table A wide raw TSV structure
--- @param opts table|nil see tableToEav
--- @return string The EAV file contents (header-less triples)
--- @error Throws on the same conditions as tableToEav / rawTSVToString
local function tableToString(tbl, opts) ... end

--- Checks whether a value is a well-formed EAV (long) raw TSV structure:
--- a valid raw TSV whose every non-comment row has exactly 3 cells with a
--- non-empty entity and attribute. Does not check for duplicate pairs.
--- @param t any The value to check
--- @return boolean
local function isEav(t) ... end
```

Public-API table (alphabetical, matching `raw_tsv`'s layout):

```lua
local API = {
    eavToTable    = eavToTable,
    fileToTable   = fileToTable,
    getVersion    = getVersion,
    isEav         = isEav,
    stringToTable = stringToTable,
    tableToEav    = tableToEav,
    tableToString = tableToString,
}
```

> **Naming note.** Within the `raw_eav` namespace, `…ToTable` means "rebuild the
> wide table" and `tableTo…` / `…ToEav` means "compress to triples." The names
> are deliberately the inverse-pair mirror of `raw_tsv`'s `stringToRawTSV` /
> `rawTSVToString`. Adjust before implementing if a different convention is
> preferred (e.g. `pivotEav` / `unpivotEav`).

## Options Reference

| Option | Used by | Default | Meaning |
| --- | --- | --- | --- |
| `keyColumn` | `eavToTable`, `stringToTable`, `fileToTable` | `"name"` | Header name synthesized for the rebuilt entity (PK) column. Defaults to `"name"` because Unreal Engine DataTable import requires the row-key column to be called `name`. |
| `onConflict` | `eavToTable`, `stringToTable`, `fileToTable` | `"error"` | What to do when the same `(entity, attribute)` appears twice: `"error"` (reject), `"first"` (keep earliest), `"last"` (keep latest). |
| `skipEmpty` | `tableToEav`, `tableToString` | `true` | Skip empty cells when compressing (keeps sparse tables sparse). Set `false` to emit a triple for every cell. |

## Behaviour Details

### `eavToTable` (rebuild)
- **Validation.** Iterate rows; each non-comment row must be a sequence of
  **exactly 3 cells**, else error citing the row index and the actual width.
- **Empty keys.** An empty `entity` or `attribute` cell is an error citing the
  row index (an empty PK or column name can't be reconstructed meaningfully).
- **Duplicate `(entity, attribute)`.** Track seen pairs. On a repeat:
  `"error"` → throw citing both row indices and the pair;
  `"first"` → ignore the new triple; `"last"` → overwrite the stored value.
- **Ordering.** Maintain two insertion-ordered lists (entities, attributes)
  plus lookup maps, so column/row order is **first-seen** and deterministic.
- **Sparsity.** Build the result by indexing into a `entity → {attr → value}`
  map, then emitting `""` for any `(entity, attribute)` with no value.
- **Comments / blanks.** String rows in the input are **skipped** (they have no
  stable position in a pivoted table). Documented; a future option could
  preserve leading comments if a need arises.

### `tableToEav` (compress)
- **Header.** The first element must be a cell sequence (the header). If the
  structure starts with comment/blank string rows, skip them to find the
  header; if none is found → error. Header cell 1 is discarded; cells `2..N`
  are attribute names. Reject an **empty or duplicate** attribute name (it
  would make the round-trip ambiguous), citing the column index.
- **Data rows.** For each subsequent cell-sequence row: `entity = row[1]`
  (error if empty). For `i = 2..N`, let `value = row[i] or ""`; emit
  `{entity, header[i], value}` unless `value == ""` and `skipEmpty`. Rows
  shorter than the header are tolerated (missing trailing cells = empty).
  Comment/blank rows among the data are skipped.
- **Output order.** Row-major: all triples for entity 1 (in header-column
  order), then entity 2, etc. Stable and diff-friendly.
- **Cell stringification.** Reuse `raw_tsv.rawTSVToString` for the final
  string form, so Lua numbers/booleans in cells are stringified consistently
  and tab/CR/LF/invalid-UTF-8 cells are rejected there.

### `stringToTable` / `fileToTable` / `tableToString`
- Thin compositions over `raw_tsv` so EOL handling, UTF-8 validation, and tab
  splitting are inherited rather than reimplemented:
  - `stringToTable(s, o)` = `eavToTable(raw_tsv.stringToRawTSV(s), o)`
  - `fileToTable(f, o)`   = read via `raw_tsv.fileToRawTSV(f)`; propagate
    `nil, err` on read failure (matches the `fileToRawTSV` contract), else
    `eavToTable(..., o)`
  - `tableToString(t, o)` = `raw_tsv.rawTSVToString(tableToEav(t, o))`

### `isEav`
- `raw_tsv.isRawTSV(t)` must hold, and every non-comment row must have exactly
  3 cells with non-empty cells 1 and 2. Returns a boolean (never throws).
  Does **not** check for duplicate pairs (that's `eavToTable`'s job, and is
  conflict-policy-dependent).

## Dependencies

Minimal — almost everything is delegated to `raw_tsv`:

- **raw_tsv** — `stringToRawTSV`, `rawTSVToString`, `fileToRawTSV`, `isRawTSV`.
- **read_only** — `readOnly` wrapper for the public API (project convention).

No direct `file_util` / `predicates` / `string_utils` dependency is needed if
all I/O and validation flows through `raw_tsv`. (If `fileToTable` is made to do
its own reading instead of calling `fileToRawTSV`, add `file_util`.)

## Test Plan

New spec [spec/raw_eav_spec.lua](../spec/raw_eav_spec.lua), mirroring
[spec/raw_tsv_spec.lua](../spec/raw_tsv_spec.lua) (busted + luassert, a
`before_each`/`after_each` temp dir for the file test). One top-level
`describe("raw_eav", …)` with a nested block per function.

### `eavToTable`
- Canonical example (the `item1/item2` triples above) → expected wide table
  with header `{"name","title","damage","defense"}` and two sparse rows.
- **First-seen column order** preserved (attributes ordered by first
  appearance, not alphabetically): assert exact header order.
- **First-seen row order** preserved (entities in first-appearance order).
- **Sparsity:** an attribute only some entities have → `""` for the others.
- **`keyColumn` option** changes the header's first cell (default `"name"`).
- **Comment/blank lines** in the input are ignored.
- Single entity / single attribute / single triple edge cases.
- Empty input (`{}`) → just a header? Decide: `{}` in → `{}` out (no entities,
  no attributes); document and assert.
- **Conflicts:**
  - duplicate pair with `onConflict="error"` (default) → error naming both
    rows and the pair;
  - `"first"` → earliest value kept;
  - `"last"` → latest value kept.
- **Errors:** non-table input (type in message); a row with 2 or 4 cells
  (cite index + width); empty entity cell; empty attribute cell.

### `tableToEav`
- Round-trip: `tableToEav(eavToTable(x))` reproduces `x`'s triples **modulo the
  discarded key-column header name and modulo skipped-empty cells** — assert on
  the triple set, noting order is row-major.
- `skipEmpty=true` (default) drops empty-value cells; `skipEmpty=false` emits a
  triple for every cell.
- Lua-number cells are stringified (via `rawTSVToString` path) — exercised
  through `tableToString`.
- Leading comment/blank rows before the header are skipped to find the header.
- **Errors:** no header row; duplicate attribute name in header (cite column);
  empty attribute name in header; data row with an empty entity cell.

### `stringToTable` / `fileToTable` / `tableToString`
- `stringToTable` on a tab-separated EAV string → same as `eavToTable` on the
  parsed structure; CR / LF / CRLF all accepted (inherited).
- `tableToString` produces tab-separated, `\n`-terminated triples with no
  header line; feeding it back through `stringToTable` round-trips the values.
- `fileToTable` reads a temp file; returns `nil, err` for a missing file
  (matches `fileToRawTSV`).

### `isEav`
- Accepts a well-formed 3-cell-row structure (with and without comment rows).
- Rejects: non-table; a row of wrong arity; empty entity or attribute cell.

### Module API
- `getVersion` returns the semver string; `__tostring` returns
  `"raw_eav version X.Y.Z"`; the callable form works:
  `raw_eav("eavToTable", t)` and `raw_eav("isEav", t)`; unknown operation
  errors.

## Documentation Updates

1. **[MODULES.md](../MODULES.md)** — add a `raw_eav` row to the Module Index
   table and a `### raw_eav` detail section:

   > **raw_eav** — Low-level reader/writer for the Entity–Attribute–Value
   > (EAV / "long") table layout: a header-less, tab-separated, 3-column
   > `(entity, attribute, value)` file (canonical extension `.eav`) whose row
   > and column identifiers are domain keys / column names (not indices). `eavToTable` rebuilds the wide table (header + PK rows) from the
   > triples; `tableToEav` compresses a wide table back to triples. EAV files
   > carry no header — it is synthesized on read (key column defaults to
   > `"name"`, overridable via `keyColumn`) and dropped on write. Cells stay
   > strings. **Dependencies:** raw_tsv, read_only.

   Also add `raw_eav` under `raw_tsv` in the simplified dependency graph
   (`raw_tsv └── raw_eav`).

2. **[CHANGELOG.md](../CHANGELOG.md)** — under `## [Unreleased] ### Added`:

   > - **`raw_eav` — Entity–Attribute–Value (long-format) table support.** New
   >   low-level module that pivots between the 3-column `(entity, attribute,
   >   value)` layout (row/column identifiers are domain keys, not indices) and
   >   the normal wide table layout. `eavToTable`/`stringToTable`/`fileToTable`
   >   rebuild a wide table from triples; `tableToEav`/`tableToString` compress
   >   a wide table to triples; `isEav` validates the long shape. First-seen
   >   row/column ordering, configurable duplicate-pair policy (`onConflict`,
   >   default error), sparse-table aware (`skipEmpty`). Cells stay strings.

3. **No new top-level doc file.** Behaviour is small enough for the function
   comments + the MODULES.md entry, matching the COO plan's stance.

## Scope / Non-Goals

- **Type coercion.** Values stay strings, like `raw_tsv`. Typed conversion is
  the caller's job (or a later `tsv_model` pass).
- **Header preservation for the PK column.** Not stored (there's nowhere for it
  to live in pure triples); re-synthesized via `keyColumn`. By design.
- **Multi-valued attributes.** One value per `(entity, attribute)`; repeats are
  governed by `onConflict`. A list-valued EAV (same pair, many rows → an array
  cell) is out of scope; revisit if a real need appears.
- **Comment preservation across the pivot.** Comments/blanks are dropped on
  read. A future `preserveComments` option could keep leading comments.
- **Extension-based dispatch.** Deciding that a given file is EAV-shaped and
  routing it to `fileToTable` automatically belongs in `files_desc` /
  `content_pipeline`, not here. See "After It's Done."
- **COO / Matrix Market.** A different feature (integer-indexed sparse
  matrices). The earlier plan for it has been removed in favour of this one; if
  the index-based use case ever resurfaces it should be its own module (e.g.
  `raw_coo`), not folded into `raw_eav`.

## After It's Done

- Decide whether [files_desc.lua](../files_desc.lua) /
  [content_pipeline](content_pipeline.md) should recognise an EAV-layout source
  (by the `.eav` extension, or by a manifest declaration) and route it
  through `fileToTable` so EAV files load as ordinary wide tables in the normal
  order. This is the natural follow-up that realises "read files in different
  layouts as long as they represent the same data." It is a load-order /
  recognition change, so handle it as a separate task.
- Consider an `expand`/`preserveComments` option pair if either sparsity
  defaults or comment loss turn out to matter in practice.

## References

- [raw_tsv.lua](../raw_tsv.lua) — module skeleton + helpers to delegate to
- [spec/raw_tsv_spec.lua](../spec/raw_tsv_spec.lua) — test conventions to mirror
- [MODULES.md](../MODULES.md) — module index + detail format
- [file_joining.lua](../file_joining.lua) — confirms the wide convention
  (column 1 = join/ID key)
- [TODO/content_pipeline.md](content_pipeline.md) — where extension-keyed
  dispatch to `raw_eav` (the "first transcoder") would live as a follow-up
