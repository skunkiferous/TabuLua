# SQL as an input format — the `sql:*` transcoders and reformatter round-trip

## Status

**PLANNED — not started (2026-07-24; retrimmed 2026-07-27).**

## What we want

`.sql` becomes an input format, so the reformatter can round-trip a `.sql` file the same
way it already round-trips `.json`, `.xml`, `.lua` and `.tsv`. This works on **every**
supported runtime — Lua 5.3/5.4/5.5 and LuaJIT — using the **pure-Lua text parser only.
`lsqlite3` is not used here.**

This reverses the "SQL won't be an input" ruling in
[export_format_reimport.md §Scope](export_format_reimport.md). That ruling rested on
"`BIGINT` is a trap on LuaJIT" — now solved: the reader takes the digits as text
([`buildInt64SafeSelect`](../serde/importer.lua#L688) casts to `TEXT`; the text parser
boxes the literal at [importer.lua:617-633](../serde/importer.lua#L617-L633)), so a `.sql`
reads exactly on every runtime.

**Out of scope, deferred to future work:** using an actual SQL engine (`lsqlite3`) as a
second reader. That belongs with the broader "multiple DB dialects" effort
([improved-sql.txt](improved-sql.txt)), not here. `lsqlite3` stays an optional CI
dependency; this plan neither requires nor invokes it. The governing rule — *a dataset
must load identically whether or not `lsqlite3` is installed* — is satisfied trivially by
never using it.

## What already exists (do not rebuild)

| Piece | Where |
| --- | --- |
| SQL text reader (values) | [`parseSQLContent`](../serde/importer.lua#L445) — complete for our own output |
| int64-safe read | text parser boxes digits ([importer.lua:617-633](../serde/importer.lua#L617-L633)) |
| SQL writer | [`exportSQL`](../serde/exporter.lua#L1150) / [`createTableInsertSQL`](../serde/exporter.lua#L1056) |
| Id-selected reversible stage machinery | [builtin_content_stages.lua:251-259](../content/builtin_content_stages.lua#L251-L259) |
| Reformatter round-trip plumbing | `reversibleTranscode` else-branch ([reformatter.lua:651-660](../reformatter.lua#L651-L660)) — no change needed; a `.sql` is neither `.tsv` nor `.csv`, so it falls straight through, as `.lua` did |

## The one design decision: an embedded `tabulua_schema` metadata table

The wide-TSV header (`name:type[:default]`) can't be rebuilt from the DDL alone — column
names are sanitized (`stats.attack` → `stats_attack`;
[exporter.lua:930-955](../serde/exporter.lua#L930-L955)) and SQL types are coarser than
ours (`BIGINT` = `integer` *and* `int64`; `TEXT` = `string`, `table`, unions, …). The
schema must therefore ride *in the file*. A `--` comment would work for a file round-trip,
but it is a lexeme every engine discards on load — so store the metadata as **a real
table** the database keeps and re-dumps.

**Each per-table `.sql` file carries its own metadata, self-contained, via a shared table
declared `IF NOT EXISTS`:**

```sql
-- (1) shared metadata table — created once, a no-op in every file after the first
CREATE TABLE IF NOT EXISTS "tabulua_schema" (
  "table_name"  TEXT    NOT NULL,
  "column_name" TEXT    NOT NULL,   -- model name (stats.attack); '<TABLE>' on the table-info row
  "sql_name"    TEXT    NOT NULL,   -- physical column in the data table; '<TABLE>' on row 0
  "position"    INTEGER NOT NULL,   -- 0 = table-info row; 1..N = column order
  "type"        TEXT    NOT NULL,   -- type_spec (int64, {integer}, foo|nil); '<TABLE>' on row 0
  "default"     TEXT,               -- NULL when the column had none
  "attributes"  TEXT,               -- NULL, or a JSON object (extensibility bag)
  PRIMARY KEY ("table_name","column_name"),
  UNIQUE      ("table_name","position"),
  UNIQUE      ("table_name","sql_name"));
-- (2) this file's metadata; DELETE-first makes a reload idempotent, portably.
--     position 0 is the table itself (carries version + model name); 1..N the columns.
DELETE FROM "tabulua_schema" WHERE "table_name" = 'Item';
INSERT INTO "tabulua_schema" VALUES
  ('Item','<TABLE>','<TABLE>',0,'<TABLE>',NULL,'{"tabulua":{"version":"0.33","model_name":"Item"}}'),
  ('Item','name','name',1,'identifier',NULL,NULL),
  ('Item','stats.attack','stats_attack',2,'integer',NULL,NULL), … ;
-- (3) the data table, exactly as today
CREATE TABLE "Item" ( … );
INSERT INTO "Item" ( … ) VALUES … ;
```

Self-contained per file (import one table = read one file) **and** non-conflicting when
concatenated (load the whole export into one DB = the metadata table is created once, each
file adds its own rows). Every construct — `CREATE TABLE IF NOT EXISTS`, multi-statement
scripts, two tables per file, composite PK, portable `DELETE`-before-`INSERT` — works on
SQLite, MySQL and PostgreSQL (9.1+).

### The rules that make it work

- **Store both names.** `column_name` = model name (the header label); `sql_name` = the
  physical column. The reader locates each value **by the stored `sql_name`**, never by
  re-running the normalizer and never by assuming physical column order — so a change to
  `sqlColumnName` can't mis-read an old file, and a foreign/length-capped column name still
  imports. `UNIQUE (table_name, sql_name)` enforces the mapping is a bijection.
- **PK is `(table_name, column_name)`; `position` is a `UNIQUE` ordering helper.** Column
  order is recoverable only from an explicit `position` (dumped rows are unordered).
  `position = 0` is the table-info row; real columns are `1..N`.
- **The table-info row uses the sentinel `'<TABLE>'`, not NULLs**, in `column_name` /
  `sql_name` / `type` (angle brackets never appear in exported names). Keeps every real
  row fully populated and the PK total. The reader detects the table row **by
  `position = 0`**.
- **`table_name` is the SQL table name** (must match `CREATE TABLE "…"`, from the file
  basename, [exporter.lua:1057-1061](../serde/exporter.lua#L1057-L1061)). The **model
  dataset name** (`header.__dataset`) can diverge (`Manifest.transposed.tsv` → SQL table
  `Manifest.transposed`, dataset `Manifest`) and rides row 0's `attributes` as
  `tabulua.model_name`; the reader uses it when present, else the file-derived name.
- **`default` is carried** in its own column — no longer a loss.
- **The metadata schema is versioned, not frozen.** The reader hard-codes the DDL; every
  file emits it byte-identically (`IF NOT EXISTS` → first wins).

### The `attributes` bag — extensibility, kept safe

Committed metadata stays as real columns; the bag holds only open-ended and experimental
descriptive metadata. `type` and anything the loader *acts on* never live in the bag.

- **`TEXT`, JSON-by-convention** — never a `JSON`/`jsonb` type (SQLite has none). A
  preserved payload, not a portably-queryable field.
- **Validated on read:** `NULL`, or a JSON **object**; reject array/scalar/unparseable
  (no silent `pcall`-and-shrug). Empty object ≡ NULL. **Bounded** by a per-cell size cap.
- **Namespaced, preserve-unknown.** `"tabulua"` = TabuLua-defined (validate known keys,
  preserve unknown → forward-compat). `"app"` = application-owned, carried verbatim, never
  interpreted. Any other top-level key → reserved, preserve+ignore.
- **Descriptive, never behavioral** — the core safety property. Nothing in the bag changes
  how a cell is parsed/validated/evaluated, and nothing is handed to the sandbox or `load`.
  Units, labels, descriptions, provenance — yes; validators, defaults, expressions — no.
  This is what stops a hand-authored `.sql` becoming a code-injection surface.
- **Version = TabuLua product `major.minor`, as a string** compared component-wise
  (`"0.15"` vs `"0.5"` compares wrong as a float). Any schema change bumps ≥ minor, so
  *equal marker ⇒ schema identical*. Lives on the `position = 0` row as `tabulua.version`.
  **Provenance, not a gate:** compatibility is enforced *structurally* (does the file carry
  the shape the reader needs?); the version only yields a friendly hint on structural
  failure ("likely written by a newer TabuLua") and is forward-insurance.

## What SQL round-trip loses

**Comment rows.** `__comment` placeholders the native TSV reformatter preserves have no
SQL representation. This makes the SQL round-trip **normalizing and mildly lossy** — a
step below json/xml (which lose only formatting) — and must be documented at the same
prominence as the `--collapse-exploded` caveat. (Column defaults are **not** lost; the
`default` column carries them.)

## Phases

Per-phase review and commit, as usual (the user commits).

### Phase 0 — extract the leaf module

[`serde/exporter.lua` requires `content.content_pipeline`](../serde/exporter.lua#L62), so
a transcoder that required `exporter` back risks a partially-initialized module. Extract
the DDL builder (`createTableInsertSQL`, `colToSQL`, `sqlColumnName`, the `sql_types` map)
into a **leaf module `serde/sql_schema.lua`** that both `exporter` and the new transcoder
require. Pure move — output byte-identical, asserted by the existing exporter specs.

### Phase 1 — move the source of truth to the embedded table (write + read)

Write and read together — `export_tester` round-trips through the importer, so splitting
them breaks the round-trip mid-phase.

- **Exporter** (`serde/sql_schema.lua` / `exportSQL`): prepend each file with the
  `CREATE TABLE IF NOT EXISTS "tabulua_schema"` block (all seven columns; the three
  constraints), the per-table `DELETE FROM … WHERE table_name = '<T>'`, the `position = 0`
  table-info row (sentinels + `{"tabulua":{"version":"0.33","model_name":<header.__dataset>}}`),
  and one INSERT per model column (`column_name`, `sql_name = sqlColumnName(col)`,
  `position`, `type_spec`, `default`, `attributes` = NULL). Data table DDL/INSERTs follow
  unchanged. **Stop writing the `-- tabulua-types:` comment.**
- **Reader** (`parseSQLContent`): recognize `tabulua_schema` **by name**, parse its INSERTs
  into the column schema, read the table-info row (`position = 0`) — record
  `tabulua.version` for diagnostics (**don't gate on it**), take `tabulua.model_name` as the
  dataset name (else file-derived) — then for each real column (`position ≥ 1`) locate its
  value column **by `sql_name`**, label it with `column_name`, order the header by
  `position`. Verify every `sql_name` exists and the counts match; treat the *other* table
  as data — dropping the first-`CREATE TABLE` assumption at
  [importer.lua:398](../serde/importer.lua#L398). Retire
  [`extractSQLColumnTypes`](../serde/importer.lua#L427) — the metadata table replaces it,
  **no comment fallback**.
- All 31 committed `.sql` goldens churn (gain the table, lose the comment) — regenerate and
  diff-review.
- Assert the output still loads in a real engine (`it_sqlite` gate), now with two tables.

### Phase 2 — the four `sql:*` forward transcoders (read)

`--file=sql` accepts `--data` ∈ `{json-typed, json-natural, xml, mpk}`
([reformatter.lua:274-286](../reformatter.lua#L274-L286)) and the cell encoding is not
sniffable, so the id says it — mirroring `tsv:*`:

`sql:json-typed` · `sql:json-natural` · `sql:xml` · `sql:mpk`

- New `content/sql_transcoder.lua`: `sqlToTSV` variants on `parseSQLContent`,
  reconstructing the header from the metadata table and re-serializing each value to native
  cell text via the column parser (the two-step
  [`xml_transcoder.xmlToTSV`](../content/xml_transcoder.lua#L205) uses).
- Register four id-only stages, `inputExtensions = {"sql"}`, `outputKind = "text"`.
  Id-only selection is also the "is this file ours?" marker (SQL has no `xmlns`).
- Validate `attributes` structurally; preserve unknown keys; interpret none (v1).
- **Refuse, with a clear message:** missing `tabulua_schema`; metadata count ≠ data column
  count; a third/unrecognized `CREATE TABLE`; **`--collapse-exploded` output** (the CREATE
  TABLE has collapsed root columns while the metadata describes every exploded column — the
  counts disagree; naming the flag beats silently importing the wrong shape); unterminated
  literals (surface the parser error through `badVal`).
- Tests: an exported `.sql` per `--data` loads to the same model as its native TSV source;
  header-only file; whole-export concatenation into one DB; malformed file aborts.

### Phase 3 — reversibility (the reformatter round-trip)

- `encode = tsvToSql` per stage, reusing `serde/sql_schema.lua` (incl. Phase 1 metadata
  emission) and `serializeSQL` with the id's table serializer — the pairing
  [`exportSQL`](../serde/exporter.lua#L1150) already uses.
- Integration test mirroring `tsv_transcode_integration_spec`: load a `.sql`, reformat,
  assert it re-reads to the same model. **Normalizing, not byte-identical** — same contract
  as json/xml.
- Explicitly assert the one documented loss (comment rows).

### Phase 4 — docs

`DATA_FORMAT_README.md` (the `sql:*` family, the `tabulua_schema` table and layout, the
`attributes` bag + version marker, the comment-row loss, the `--collapse-exploded`
refusal), `REFORMATTER.md` (round-trip matrix row), `MODULES.md`, `CHANGELOG.md`. Update
[export_format_reimport.md](export_format_reimport.md) to point here, and drop the note
from [improved-sql.txt](improved-sql.txt).

## Open questions

1. **`--collapse-exploded`: refuse (Phase 2) or emit metadata for the collapsed shape** so
   those exports become re-importable too? Cheap, but changes that flag's output — separate
   decision.
2. **The v1 `attributes` vocabulary.** v1 defines **two table-level** reserved keys —
   `tabulua.version`, `tabulua.model_name` (both on row 0) — and **no per-column keys**
   (emit NULL). Add the first per-column key (`description`, `unit`, `label`, …) with a real
   use case, bumping the minor. Open sub-decision: the exact reserved-vs-`app` namespace
   spelling.

## Deferred — optional `lsqlite3` engine (future multi-dialect work)

Reading `.sql` through an actual SQL engine buys tolerance for **SQL we did not write**
(hand-authored files, other tools' dumps, unusual quoting). It is **not** part of this
plan; it belongs with [improved-sql.txt](improved-sql.txt)'s DB-flavour work. Recorded here
so the known costs aren't rediscovered later:

- The two readers **diverge** ([importer.lua:707-715](../serde/importer.lua#L707-L715)):
  BLOB columns come back as raw bytes vs model text; composite cells use a `val:sub(1,1)`
  heuristic vs the caller's `--data` deserializer; MessagePack string-cells have no engine
  equivalent. All must be reconciled before an engine can be trusted.
- **Row order out of SQLite is unspecified** — a `SELECT` with no `ORDER BY` may reorder
  rows and rewrite the user's file. The engine path would need `ORDER BY rowid` and must
  refuse `WITHOUT ROWID`. (The text parser has no such risk — it appends `VALUES` tuples
  positionally as it scans, like every other reader in the system.)
- Selection must be **explicit** (a `:sqlite` id suffix, or a `Files.tsv` option), never
  presence-based — auto-use makes a load succeed or fail by what's installed. When selected
  but absent: hard error naming the rock.
- Needs a **differential parity spec** (`parseSQLContent` vs the engine, deep-equal over a
  fixture corpus, `it_sqlite`-gated) and `lsqlite3` installed on the 5.3/5.4/5.5 Docker
  images too (today only LuaJIT has it), to prove parity on a native-integer runtime.
- Whether `lsqlite3` returns native integers on Lua 5.3+ (vs all-doubles on LuaJIT) must be
  measured, not assumed.

## Related

- [export_format_reimport.md](export_format_reimport.md) — the family this joins; its Scope
  section is what this reverses. `tsv:*` / `lua:tabulua` are the template.
- [boxed_int64.md](boxed_int64.md) — made `int64` a `BIGINT` literal; the reader-side answer
  is this plan's precondition.
- [luajit_compatibility.md](luajit_compatibility.md) — why reading a `BIGINT` as a number
  was ever a problem.
- [improved-sql.txt](improved-sql.txt) — the broader "make SQL output better" wishlist
  (foreign keys, whole-DB creation, DB flavours). The deferred engine belongs here.
