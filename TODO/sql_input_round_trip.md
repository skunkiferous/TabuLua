# SQL as an input format — the `sql:*` transcoders, reformatter round-trip, and optional `lsqlite3`

## Status

**PLANNED — not started (2026-07-24).** This document **reverses the "out of scope"
ruling** recorded in [export_format_reimport.md §Scope](export_format_reimport.md), by
user decision. That ruling had two legs, and one of them has since fallen:

- *"An exported `.sql` carries DDL we'd have to re-parse for no real input use case."* —
  still partly true, but the DDL re-parser **already exists and ships**
  ([`importer.parseSQLContent`](../serde/importer.lua#L445), plus the `lsqlite3` path).
- *"`BIGINT` is a trap on LuaJIT."* — **solved.** Both readers now take the digits as
  text ([`buildInt64SafeSelect`](../serde/importer.lua#L688) casts to `TEXT`;
  the text parser boxes the literal's characters at
  [importer.lua:617-633](../serde/importer.lua#L617-L633)), so a `.sql` reads exactly on
  every supported Lua, LuaJIT included. That is the change this plan rests on.

## A correction to the premise, before the plan

The task was phrased as *"add optional sqlite support, and **based on that** enable
round-trip for sql files."* Reading the code says the dependency runs the other way:

**The round-trip does not need `lsqlite3` at all.** The text parser is already the
complete reader — it handles int64 digits, `X'…'` BLOB columns, MessagePack-hex cells,
JSON/XML composite cells and `NULL` — and it is pure Lua, so it works on every runtime
with no rock installed. `lsqlite3` is not the enabler; it is an *optional second engine*
that buys tolerance for **SQL we did not write** (hand-authored files, other tools'
dumps, unusual quoting or multi-statement inserts) at the cost of a second set of
semantics to keep in step.

So this plan ships the round-trip on the dependency-free path **first**, and adds the
optional engine **after**, behind an explicit opt-in. Both halves are delivered; only
the order changed. If the intent was specifically "use SQLite whenever it happens to be
installed", see **OQ1** — that is the one decision this reordering puts to the user, and
it is a policy question, not a technical blocker.

### The rule that shapes everything below

> A dataset must load **identically whether or not `lsqlite3` is installed.**

This is not a new invention; it is already the stated reason `importFile` refuses to use
the SQLite path ([importer.lua:856-864](../serde/importer.lua#L856-L864)). Elevating it
to a project rule has three consequences that drive the phasing:

1. The **text parser is normative.** The engine path must match it, not vice versa.
2. Any engine use must be **explicitly selected**, never auto-upgraded by rock presence.
3. Equivalence has to be **tested differentially**, not assumed.

## What already exists (do not rebuild)

| Piece | Where | State |
| --- | --- | --- |
| SQL text reader (values) | [`parseSQLContent`](../serde/importer.lua#L445) | Complete for our own output |
| SQLite engine reader | [`importSQLFileWithSQLite`](../serde/importer.lua#L720) | Works, but **diverges** — see Gaps |
| int64-safe SELECT | [`buildInt64SafeSelect`](../serde/importer.lua#L688) | Done, unit-tested |
| Self-describing type line | `-- tabulua-types:` ([exporter.lua:1062-1080](../serde/exporter.lua#L1062-L1080)) | Emitted; read by [`extractSQLColumnTypes`](../serde/importer.lua#L427) |
| SQL writer | [`exportSQL`](../serde/exporter.lua#L1150) / [`createTableInsertSQL`](../serde/exporter.lua#L1056) | Done (the `encode` inverse) |
| Id-selected reversible stage machinery | [builtin_content_stages.lua:251-259](../content/builtin_content_stages.lua#L251-L259) | Reused as-is |
| Reformatter round-trip plumbing | `reversibleTranscode` else-branch ([reformatter.lua:651-660](../reformatter.lua#L651-L660)) | **No engine change needed** — see below |
| `lsqlite3` in CI | [Dockerfile.luajit:35-45](../Docker/Dockerfile.luajit#L35-L45) | Installed on the LuaJIT image only |
| Rock-absent test gate | `it_sqlite` ([exporter_spec.lua:23-24](../spec/exporter_spec.lua#L23-L24)) | Precedent to copy |

**The reformatter needs no change.** A `.sql` is neither `.tsv` nor `.csv`, so it falls
straight through to the reversible-transcoder else-branch — exactly as `.lua` did in
[export_format_reimport.md](export_format_reimport.md) Phase 2, and unlike `tsv:*`,
which shares an extension with native data and needed a guard.

## Gaps found by reading the code — this is the actual work

### 1. The two readers diverge in three ways *(the blocker for any engine use)*

Documented at [importer.lua:707-715](../serde/importer.lua#L707-L715), unfixed because
nothing in production reads SQL:

- **BLOB columns** come back as **raw bytes** from `lsqlite3`, where the text parser
  returns the *model* text — hex digits for `hexbytes`, base64 for `base64bytes`,
  chosen from the declared type ([importer.lua:591-598](../serde/importer.lua#L591-L598)).
- **Composite cells** are deserialized by a lone `val:sub(1,1)` heuristic instead of the
  caller's `--data` format, so an XML or MessagePack cell is mis-read.
- **MessagePack cells** (`X'…'` stored as a *string*, distinct from a BLOB column —
  [importer.lua:549-560](../serde/importer.lua#L549-L560)) have no engine-path
  equivalent at all.

### 2. Row order out of SQLite is unspecified

`SELECT … FROM t` with no `ORDER BY` has no defined row order. It happens to come back
in insertion order for an ordinary rowid table, which is why this has never bitten — but
a round-trip that reorders rows rewrites the user's file. `buildInt64SafeSelect` must
append **`ORDER BY rowid`**, and the transcoder must refuse a `WITHOUT ROWID` table
(which our exporter never emits, but a foreign file might).

**This would be the only input path in the system whose row order is not positional.**
Every other reader takes order from position and cannot lose it: `json:objects`/`rows`
iterate the decoded array with `ipairs` ([json_transcoders.lua:355](../content/json_transcoders.lua#L355),
[:377](../content/json_transcoders.lua#L377)), `json:columns` indexes `1..nRows`
([:427](../content/json_transcoders.lua#L427)), `xml:tabulua` scans the document
linearly ([xml_transcoder.lua:165-195](../content/xml_transcoder.lua#L165-L195)),
`lua:tabulua` walks `for r = 2, #data` ([lua_transcoder.lua:185](../content/lua_transcoder.lua#L185)),
and the SQL **text** parser appends `VALUES` tuples as it scans them. Even `.eav`, the
one format that *reconstructs* row order rather than reading it, does so through an
explicit insertion-ordered list precisely to avoid `pairs()` non-determinism
([raw_eav.lua:50](../tsv/raw_eav.lua#L50), [:74-77](../tsv/raw_eav.lua#L74-L77)).
Delegating order to an external engine is a new category of risk here, not a variation
on an existing one — a further reason the text parser stays normative.

### 3. The importer returns *values*; a transcoder must emit *native cell text*

Every existing transcoder produces a wide TSV whose cells are in native encoding, then
lets the normal parser machinery take over. So the SQL forward path is
`parseSQLContent` → value → `parser(badVal, value, "parsed")` → `reformatted` text —
the same two-step [`xml_transcoder.xmlToTSV`](../content/xml_transcoder.lua#L205) uses.
The importer is a *value* reader today because its only consumer is `export_tester`.

### 4. Header reconstruction — and what SQL export genuinely loses

The wide-TSV header (`name:type[:default]`) cannot be rebuilt from the DDL alone:

- Column **names are sanitized** — `stats.attack` → `stats_attack`,
  `prices[iron]`/`prices[iron]=` → `prices_iron_k`/`prices_iron_v`
  ([exporter.lua:930-955](../serde/exporter.lua#L930-L955)).
- SQL **types are coarser** than ours (`BIGINT` covers `integer` *and* `int64`; `TEXT`
  covers `string`, `table`, unions and every derived type).

Both are answered by the **embedded `tabulua_schema` metadata table** (see *The durable
answer* below), which carries, per column, the **model name**, the **physical `sql_name`**,
`position`, `type_spec` and default. So the rule is: **the metadata table is mandatory for
a `.sql` used as input**; a file without it is refused with a message saying so, not
guessed at. Because the table stores the model↔SQL name mapping **explicitly**, the reader
never re-derives it: it locates each column in the data table **by the stored `sql_name`**
(not by re-running the normalizer, and not by assuming physical column order), labels it
with `column_name`, orders the header by `position`, and verifies every `sql_name` exists
in the data table and the counts match. Storing the mapping rather than recomputing it is
what makes the read robust against a later change to the normalization code, and against a
data table whose columns were named by something other than our exporter (a real DB, a
user convention, a column-name length cap) — see *Storing both names* below.

**One thing is lost and cannot be recovered** — state it in the docs rather than
pretending otherwise:

- **Comment rows.** `__comment` placeholders that the native TSV reformatter preserves
  have no SQL representation.

(**Column defaults are NOT lost** under the metadata-table design — the `default` column
carries them. This was a loss only under the comment-based approach, which wrote
`type_spec` alone.)

This makes the SQL round-trip **normalizing and mildly lossy** — a step below the
json/xml round-trips, which lose only formatting. It must be documented at the same
prominence as the `--collapse-exploded` caveat.

**The type line is a *lexical* comment, which bounds where it survives.** `-- …` is
whitespace to every SQL parser and is discarded on load — no engine keeps it as data.
That is correct for a text-file interchange (we write the exact bytes; our readers and
hand-editors read them back), but it means a `.sql` that is loaded into a real database
and **re-dumped by that engine loses the line entirely**, and — since the reader now
requires it — the re-dumped file is no longer re-importable. There is no portable fix:
durable, catalog-stored comments exist only as `COMMENT ON …` (Postgres) and the inline
`COMMENT '…'` clause (MySQL), and **SQLite — the most likely target for the
"load the export into a DB" idea in [improved-sql.txt](improved-sql.txt) — has no
comment feature at all.** So the metadata cannot ride through a generic DB round-trip;
it rides through a *file* round-trip only. Reinforces the framing already in this plan:
the `.sql` is a TabuLua-authored **file** format, not a database-round-trip artifact.
(If flavour-specific export ever targets Postgres, its `COMMENT ON` could carry the
type metadata durably — but that is per-flavour work, not generic SQL, and out of scope
here.)

#### The durable answer — an embedded metadata *table* per file *(decided 2026-07-24)*

Because SQLite (our primary target — games ship it) has **no comment mechanism at all**,
store the schema metadata as something the database keeps and dumps: **a real table.**
This is the pattern a database uses internally (a self-carried `information_schema`), and
it survives a load-and-redump because it is *data*, not a lexeme.

**Each per-table `.sql` file carries its own metadata, self-contained, via a shared
table declared `IF NOT EXISTS`.** Every file is laid out as:

```sql
-- (1) create the shared metadata table once; a no-op in every file after the first
CREATE TABLE IF NOT EXISTS "tabulua_schema" (
  "table_name"  TEXT    NOT NULL,
  "column_name" TEXT    NOT NULL,   -- model name (stats.attack); '<TABLE>' on the table-info row
  "sql_name"    TEXT    NOT NULL,   -- actual column in the data table; '<TABLE>' on row 0
  "position"    INTEGER NOT NULL,   -- 0 = table-info row; 1..N = column order
  "type"        TEXT    NOT NULL,   -- type_spec (int64, {integer}, foo|nil); '<TABLE>' on row 0
  "default"     TEXT,               -- NULL when the column had none
  "attributes"  TEXT,               -- NULL, or a JSON object — extensibility bag, see below
  PRIMARY KEY ("table_name","column_name"),
  UNIQUE      ("table_name","position"),
  UNIQUE      ("table_name","sql_name"));
-- (2) this file's own metadata; DELETE-first makes a re-load idempotent, portably.
--     position 0 is the table itself (carries the TabuLua major.minor version); 1..N the columns.
DELETE FROM "tabulua_schema" WHERE "table_name" = 'Item';
INSERT INTO "tabulua_schema" VALUES
  ('Item','<TABLE>','<TABLE>',0,'<TABLE>',NULL,'{"tabulua":{"version":"0.33","model_name":"Item"}}'),
  ('Item','name','name',1,'identifier',NULL,NULL),
  ('Item','stats.attack','stats_attack',2,'integer',NULL,NULL), … ;
-- (3) the data table itself, exactly as today
CREATE TABLE "Item" ( … );
INSERT INTO "Item" ( … ) VALUES … ;
```

This resolves the tension that sank the two earlier options at once: **self-contained per
file** (import one table = read one file) **and non-conflicting when concatenated** (load
the whole export into one DB = the metadata table is created once, each file adds only its
own rows, and `tabulua_schema` ends up describing every table). Both the partial-import
and the whole-DB-query use cases fall out for free.

Every construct is portable — `CREATE TABLE IF NOT EXISTS`, multi-statement scripts, two
tables per file, composite PK — across SQLite, MySQL and PostgreSQL (9.1+).

Design points carried from the discussion:

- **PK is `(table_name, column_name)`; `position` is a `UNIQUE` technical helper.** The
  logical identity of a metadata row is its table + column name — the key users would
  reach for — so that is the PK. `position` only supplies ordering; it is kept honest by
  a separate `UNIQUE (table_name, position)`. Both constraint forms are portable across
  SQLite/MySQL/Postgres. (This reverses an earlier draft that made `position` the PK; the
  sentinel table-info row below removes the reason it had to be.)
- **Store BOTH names — model `column_name` and physical `sql_name`** *(decided
  2026-07-24)*. The reader locates each data column by the stored `sql_name` and never
  re-derives it. This removes a hidden coupling to the (mutable) `sqlColumnName` normalizer
  — a normalization change can never mis-read an old file — and it lets the metadata
  describe a table whose columns were **not** named by our exporter: a real DB, a user's
  own convention, or a physical name truncated by a **column-name length cap** (Postgres
  63 chars, older Oracle 30). A `UNIQUE (table_name, sql_name)` enforces the model↔SQL
  mapping is a bijection (catching two model columns that claim the same physical column).
  With `sql_name` stored, the reader also no longer depends on the data table's physical
  column *order*: `sql_name` is the value lookup, `column_name` the model label,
  `position` the header order — three orthogonal jobs. See *Storing both names widens what
  is importable* below.
- **`table_name` is the SQL table name; the model dataset name rides row 0's
  `attributes`** *(decided 2026-07-24)*. `table_name` must equal the string in
  `CREATE TABLE "…"` (the `DELETE` and the metadata↔data join depend on it), and the
  exporter derives it from the source file basename
  ([exporter.lua:1057-1061](../serde/exporter.lua#L1057-L1061)) — so it diverges from the
  model dataset name for a transposed file (`Manifest.transposed.tsv` → SQL table
  `Manifest.transposed`, dataset `Manifest`), a variant (`Item.en.tsv` → `Item.en`,
  dataset `Item`), or any future table-name sanitization. This is the **column model↔SQL
  split, one level up**: `table_name` carries the SQL half; the model half
  (`header.__dataset`) is recorded as the reserved key `tabulua.model_name` in the
  `position = 0` row's `attributes`. It is not put in the row-0 sentinel columns
  (`column_name`/`sql_name`), because `column_name` is in the PK and a model name equal to
  a real column name would collide — the `'<TABLE>'` sentinel exists to keep row 0
  collision-proof. `model_name` is inert identity metadata (a label, never executed, never
  changing cell semantics), so it sits within the `attributes` safety rule; the reader uses
  it as the dataset name when present, otherwise falls back to the file-derived name.
- **The table-info row uses a sentinel, not NULLs.** `column_name`, `sql_name` and `type`
  stay `NOT NULL`; the `position = 0` row sets all three to the non-producible constant
  `'<TABLE>'` (angle brackets never appear in exported column names, which only introduce
  `.[]=`). Making them nullable would permit NULL on *any* row — weakening the invariant
  for real columns — whereas a sentinel keeps every real row fully populated, keeps the
  `(table_name, column_name)` PK total, and makes the table row obvious. The reader
  detects the table row **authoritatively by `position = 0`**; the sentinel is the
  human-visible secondary signal.
- **`position` is REQUIRED** — the row-order argument from OQ-history *inverted*. Data
  rows dropped their position column because order was recoverable elsewhere and the
  column taxed every consumer. But these rows *describe an ordered thing* (the column
  list — positional cell formats align to header order, exploded columns must stay
  grouped, column 1 is the data table's PK), and once dumped by a real engine the rows are
  **unordered**, so column order is recoverable **only** from an explicit `position`. Same
  "relations are unordered" fact, opposite conclusion. **`position = 0` is reserved for
  the table-info row**; real columns are `1..N`, and the reader begins column iteration
  at 1.
- **`default` is carried**, closing what was a documented loss under the comment
  approach (leaving only comment rows genuinely lost — see Gap 4).
- **The metadata table's own schema is the versioned bootstrap** — hard-coded by the
  reader, and all files must emit it byte-identically (with `IF NOT EXISTS` the first
  definition wins; a divergent later one is silently ignored). It is not promised to be
  *frozen forever* — see the extensibility contract, which lets it evolve without
  breaking old files.

#### The `attributes` bag — extensibility, kept safe *(decided 2026-07-24)*

A fixed schema is brittle; "never change it" is not a promise worth making. But an
open-ended JSON column partly walks back the queryability the table just bought, so the
governing rule is: **committed metadata stays as real columns; the bag holds only the
open-ended and the experimental.** `type` and anything the loader *acts on* never live in
the bag.

- **Portability: the column is `TEXT`, JSON-by-convention — never a `JSON`/`jsonb` type.**
  SQLite (our primary target) has no JSON type; it stores JSON as TEXT and needs the
  JSON1 extension merely to *query* it. So treat the bag as a preserved payload, not a
  portably-queryable field.
- **Structurally validated on read.** `NULL`, or a JSON **object** (`{…}`) — a reader
  rejects an array, a scalar, or unparseable text; it never `pcall`s and shrugs. Empty
  object ≡ NULL.
- **Namespaced, preserve-unknown.** Reserved top-level key `"tabulua"` holds
  TabuLua-defined attributes (each documented and typed; the reader validates the ones it
  knows and **preserves** the ones it does not — the forward-compat hinge, so an old
  reader round-trips a newer writer's keys instead of dropping them). Reserved key
  `"app"` is application-owned: TabuLua **never interprets it, only carries it verbatim**.
  Any other top-level key is reserved for future TabuLua use → preserve, ignore.
- **Descriptive, never behavioral — the core safety property.** Nothing in the bag
  changes how a cell is parsed, validated, or evaluated, and nothing in it is ever handed
  to the sandbox or `load`. Units, labels, descriptions, UI hints, provenance — yes;
  validators, defaults, computed expressions — **not here** (they stay first-class, where
  they already get scrutiny). This is what stops a hand-authored `.sql` from turning the
  metadata table into a code-injection surface.
- **Bounded.** A per-cell size cap; parse-or-refuse. No unbounded blobs.
- **Table-level metadata rides the `position = 0` row's `attributes`**, under the same
  namespaces, and **must include `tabulua.version`** — see the version rule below. A
  sentinel row (rather than overloading column 1's row) keeps table metadata cleanly
  separate from any real column's metadata.
- **The version is the TabuLua product version, `major.minor`, as a string** *(decided
  2026-07-24)*. Not an independently-tracked schema-contract number — for a long-lived,
  heavily-used product the extra bookkeeping of per-component versions is not worth its
  power; one product version is simpler. **Writer rule: any change to the metadata schema
  (its columns, the sentinel, the syntax, the attribute vocabulary) bumps at least the
  minor.** So *equal marker ⇒ schema identical* (the useful property); a differing marker
  only *may* differ. Store it as a **string** compared component-wise — `"0.15"` vs
  `"0.5"` compares wrong as a float. Example today: `"0.33"`.
- **The reader treats the version as provenance, not a gate** — the one consequence of
  using the product version. A product major bump need not mean a schema break, so
  "reject on unknown major" no longer maps to "incompatible", and **compatibility is
  enforced structurally** (does the file carry the columns/shape the reader requires?)
  rather than by version comparison. The recorded version earns its keep two ways: a
  structural failure on a file marked `"0.99"` while running `"0.33"` yields a *friendly*
  hint ("likely written by a newer TabuLua"), and it is forward-insurance so a future
  reader *can* branch on it if a breaking change is ever deliberately made.
- **How this answers "never change the schema": we version it instead.** The bag absorbs
  optional/experimental attributes with no DDL churn; the version marker moves whenever the
  schema does; and a bag key that proves essential is **promoted to a first-class column**
  in a later version, deliberately and under review. The alternative — no bag, evolve
  purely by version + occasional new columns — stays fully queryable but cannot hold
  *application-owned* metadata we cannot enumerate in advance. Hence the hybrid: **bag for
  app-owned and experimental descriptive metadata; versioned real columns for TabuLua's
  own committed schema.** See OQ7 for the exact v1 vocabulary.

#### Storing both names widens what is importable *(noted, not built at v1)*

Because `sql_name` records the model↔physical mapping explicitly, `tabulua_schema` can in
principle describe a **data table our exporter never produced** — a real database table, or
one whose columns a user named by their own convention or under a length cap. Someone who
adds the `tabulua_schema` rows (by hand or via a small tool) makes such a table importable
without our normalizer ever having touched it. This is a natural, *opt-in* extension the
design now permits, not a v1 deliverable: v1 only needs to read what our own exporter
writes. It is recorded here so the capability is a known affordance rather than an accident,
and so the reader is written to trust the stored mapping (not to assume our naming) from the
start — retrofitting that later would be harder.

**Two things this requires:**

1. **Idempotent metadata INSERTs, kept portable.** Re-loading a file would collide on the
   PK. The engine-specific upserts (`INSERT OR REPLACE` / `INSERT IGNORE` /
   `ON CONFLICT`) all differ, breaking the generic-SQL promise — so use a portable
   `DELETE FROM "tabulua_schema" WHERE "table_name" = '<T>';` before the INSERTs. The data
   table keeps plain `CREATE TABLE` (per-file, unique-named; only a double-load collides,
   which is pre-existing).
2. **The reader must drop the "first/only `CREATE TABLE` is the data table" assumption.**
   Today both readers grab the first — [`extractSQLColumns`](../serde/importer.lua#L398)
   via `content:match('CREATE TABLE ".-"%s*(%b())')` and the SQLite path at
   [importer.lua:748](../serde/importer.lua#L748). Now the first table is
   `tabulua_schema`. The reader recognizes it **by its fixed name**, parses its INSERTs
   into the column schema, and treats the *other* table as data. This is contained work,
   and it is strictly simpler than the cross-file discovery it replaces (no sibling file,
   no exclusion rule, no staleness — the metadata travels *with* the data). **This
   reverses OQ4:** exactly two tables per file (one known-named metadata, one data) is now
   the expected shape; three+, or an unrecognized second table, is what gets refused.

**The `-- tabulua-types:` comment is dropped entirely** *(decided 2026-07-24)*. The
embedded table serves the *file* round-trip too — our text parser can read the
`tabulua_schema` INSERTs directly — so it is the single source of truth for both paths,
and the comment is fully redundant *documented in the same file*. This regresses nothing:
SQL-as-input does not exist yet, so today's comment-only `.sql` files were never
re-importable, and requiring the table takes away no capability that worked. The exporter
stops writing the comment, the importer requires the metadata table with **no comment
fallback**, and the comment-reader ([`extractSQLColumnTypes`](../serde/importer.lua#L427))
is *replaced by* the metadata-table reader, not kept beside it.

### 5. `--collapse-exploded` produces a file that cannot be re-imported

With that flag the CREATE TABLE has collapsed root columns (`location TEXT`) while the
metadata still describes every exploded model column (the type line at
[exporter.lua:1070-1076](../serde/exporter.lua#L1070-L1076) builds from `header`,
independent of `export_cols`, and the metadata table would inherit the same source). The
column counts disagree. **Detect and refuse**, with a message naming the flag — silently
importing the wrong shape is the failure mode to avoid. (Optionally fix the exporter to
emit metadata for the collapsed shape instead; see OQ3.)

### 6. Four data formats means four stage ids

`--file=sql` accepts `--data` ∈ `{json-typed, json-natural, xml, mpk}`
([reformatter.lua:274-286](../reformatter.lua#L274-L286)), and the cell encoding is not
reliably sniffable (typed vs natural JSON differ only inside the braces). Mirror the
`tsv:*` convention and let the id say it:

`sql:json-typed` · `sql:json-natural` · `sql:xml` · `sql:mpk`

### 7. There is no namespace marker

XML has `xmlns="urn:tabulua:table:1"` to answer *"is this file ours?"*. SQL has nothing
equivalent — so the `-- tabulua-types:` line doubles as that marker. Combined with
id-only selection (never auto-fires on a stray `.sql`), that is defense enough.

### 8. Module placement — a require-cycle to design around

[`serde/exporter.lua` requires `content.content_pipeline`](../serde/exporter.lua#L62). A
`content/sql_transcoder.lua` that required `serde.exporter` back would risk a partially
initialized module through `builtin_content_stages`. **Do not chain that way.** Extract
the DDL builder (`createTableInsertSQL`, `colToSQL`, `sqlColumnName`, the `sql_types`
map) into a **leaf module** — `serde/sql_schema.lua` — that both `exporter` and the new
transcoder require. Verify the cycle claim before assuming it (Phase 0), but design for
the leaf module regardless: it is the right shape either way, and it is what makes the
`encode` half a reuse rather than a reimplementation.

## Phases

Per-phase review and commit, as usual (the user commits).

### Phase 0 — parity, ordering, and the differential harness

No new feature; this is what makes everything after it trustworthy.

- Extract `serde/sql_schema.lua` (leaf) and point `exporter` at it. Pure move, output
  byte-identical — assert that with the existing exporter specs.
- Fix the three divergences in `importSQLFileWithSQLite`: BLOB → model text by declared
  type, composite cells through the caller's deserializer, MessagePack cells.
- Add `ORDER BY rowid` to `buildInt64SafeSelect`; refuse `WITHOUT ROWID`.
- **New spec: `spec/sql_reader_parity_spec.lua`** — for a corpus of exported `.sql`
  fixtures (one per `--data`, plus int64/BLOB/NULL/empty-table edge cases), assert
  `parseSQLContent` and `importSQLFileWithSQLite` return **deep-equal** results.
  `pending` when the rock is absent, via the `it_sqlite` gate. This spec is the
  enforcement mechanism for the identical-load rule.

*Success criterion: the two readers agree on every fixture, in the LuaJIT container.*

### Phase 1 — move the source of truth from the comment to the embedded table

Write **and** read together, because `export_tester` round-trips through the importer —
splitting them would break the round-trip mid-phase.

- **Exporter** (`serde/sql_schema.lua` / `exportSQL`): prepend each file with the
  `CREATE TABLE IF NOT EXISTS "tabulua_schema"` block (all seven columns incl. `sql_name`
  and `attributes`; `PRIMARY KEY (table_name, column_name)` + `UNIQUE (table_name,
  position)` + `UNIQUE (table_name, sql_name)`), the per-table
  `DELETE FROM … WHERE table_name = '<T>'`, the `position = 0` table-info row (sentinel
  `column_name`/`sql_name`/`type` = `'<TABLE>'`) carrying
  `{"tabulua":{"version":"0.33","model_name":<header.__dataset>}}` in `attributes`, and one
  metadata INSERT per model column (`column_name`, `sql_name` = `sqlColumnName(col)`,
  position, `type_spec`, default, `attributes`). The data table's own DDL/INSERTs follow
  unchanged. **Stop writing the `-- tabulua-types:` comment.**
- Per-column `attributes` is emitted NULL for now (v1 defines no per-column keys — see
  OQ7); the table-level `tabulua` object carries `version` and `model_name`. The column
  exists so later attributes need no DDL change.
- **Both readers** (`parseSQLContent`, `importSQLFileWithSQLite`): recognize
  `tabulua_schema` **by name**, parse its INSERTs into the column schema, read the
  table-info row (identified by `position = 0`) — **record `tabulua.version` for
  diagnostics, do not gate on it** (compatibility is structural; see the version note), and
  take `tabulua.model_name` as the dataset name (falling back to the file-derived name when
  absent) — then for each real column (`position ≥ 1`) locate its value column in the data
  table **by the stored `sql_name`** (never by re-running the normalizer or assuming column
  order), label it with `column_name`, and order the header by `position`. Verify every `sql_name`
  exists in the data table and the counts match; treat the *other* table as data — dropping
  the first-CREATE-TABLE assumption at [importer.lua:398](../serde/importer.lua#L398) and
  [:748](../serde/importer.lua#L748). Retire the comment-reader
  [`extractSQLColumnTypes`](../serde/importer.lua#L427); the metadata table replaces it,
  with **no comment fallback**.
- All 31 committed `.sql` goldens churn (gain the metadata table, lose the comment) —
  regenerate and diff-review.
- The Phase 0 parity spec still passes (both readers agree on the new shape); assert the
  output still loads in a real engine (`it_sqlite` gate), now with two tables.

### Phase 2 — the four `sql:*` forward transcoders (read)

- Validate `attributes` structurally when present (JSON object or NULL; reject otherwise)
  and preserve unknown keys; v1 interprets none of them (OQ7).
- New `content/sql_transcoder.lua`: `sqlToTSV` variants, built on `parseSQLContent`
  (text engine only in this phase), reconstructing the header from the metadata table and
  re-serializing each value to native cell text via the column parser.
- Register four id-only stages, `inputExtensions = {"sql"}`, `outputKind = "text"`.
- Refuse, with a clear message: missing `tabulua_schema` table; metadata row count ≠ data
  column count; a third/unrecognized `CREATE TABLE`; unterminated literals (surface the
  parser's existing error through `badVal`).
- Tests: an exported `.sql` per `--data` loads to the **same model** as its native TSV
  source; header-only (no-rows) file; a whole-export concatenation loads into one DB with
  `tabulua_schema` describing every table; malformed file aborts via `badVal`.

### Phase 3 — reversibility, i.e. the reformatter round-trip

- `encode = tsvToSql` per stage, reusing `serde/sql_schema.lua` (incl. the Phase 1
  metadata-table emission) and `serializeSQL` with the id's table serializer — the exact
  pairing [`exportSQL`](../serde/exporter.lua#L1150) already uses.
- Integration test mirroring `tsv_transcode_integration_spec`: load a `.sql` source,
  reformat, and assert the file is rewritten through `encode` and re-reads to the same
  model. **Normalizing, not byte-identical** — same contract as json/xml.
- Explicitly assert the one documented loss (comment rows) so it is a *recorded*
  behaviour rather than a surprise.

### Phase 4 — the optional `lsqlite3` engine

- Engine selection is **explicit**, not presence-based: a distinct stage id
  (`sql:json-typed:sqlite`, …) or a `Files.tsv` option. See OQ1/OQ2.
- When selected and the rock is **absent**: hard error naming the rock. Silently falling
  back would violate the identical-load rule in the other direction — the author asked
  for the engine because their SQL needs it.
- The Phase 0 parity spec now also runs against the transcoder, not just the importer.
- Install `lsqlite3` in the Lua 5.3/5.4/5.5 Docker images too, so parity is proven on a
  native-integer runtime as well as on LuaJIT (today only the LuaJIT image has it).

### Phase 5 — docs

`DATA_FORMAT_README.md` (the `sql:*` input family, the embedded `tabulua_schema` metadata
table and its layout, the `attributes` bag contract and version marker, the one remaining
loss (comment rows), the `--collapse-exploded` refusal), `REFORMATTER.md` (the round-trip
matrix row), `MODULES.md`, `CHANGELOG.md`.
Update
[export_format_reimport.md](export_format_reimport.md) to point here instead of saying
"won't support", and drop the corresponding note from
[improved-sql.txt](improved-sql.txt).

## Open questions

1. **Should a present `lsqlite3` be used automatically?** *Lean: no* — explicit
   selection only, per the identical-load rule and the reasoning already committed at
   [importer.lua:856-864](../serde/importer.lua#L856-L864). Auto-use makes a load
   succeed or fail depending on what is installed on the machine, which is the class of
   bug that is hardest to reproduce. The counter-argument is convenience, and it is a
   real one — this is the user's call, and it is the one place this plan departs from
   the task as phrased.
2. **How is the engine named?** A `:sqlite` id suffix (four more ids, discoverable, per
   file) versus a `Files.tsv` option column versus a CLI flag. *Lean: id suffix*, since
   every other reader choice in this system is already an id.
3. **Should `--collapse-exploded` emit metadata for the collapsed shape** so those
   exports become re-importable too, instead of merely refused? Under the metadata-table
   design this means writing `tabulua_schema` rows describing the *collapsed* columns.
   Cheap, but it changes that flag's output — worth a separate decision.
4. **Exactly two tables per `.sql` is now the expected shape** *(reverses the original
   "refuse any second CREATE TABLE")*. One known-named `tabulua_schema` metadata table
   plus one data table. The decision left: what to do with a *third* table, or an
   unrecognized second one — refuse (proposed), or read the data table and warn? *Lean:
   refuse*, since a well-formed TabuLua export never produces it.
5. ✅ **RESOLVED (2026-07-24) — the `-- tabulua-types:` comment is dropped entirely**,
   both write and read, with no fallback (see *The `-- tabulua-types:` comment is dropped*
   under Gap 4). The embedded table documents the schema in the same file, so the comment
   is fully redundant; and since SQL-as-input does not exist yet, no re-import capability
   regresses.
6. **Does `lsqlite3` return native integers on Lua 5.3+?** The LuaJIT answer is known
   (all doubles — hence the `CAST`). The 5.4 binding's integer handling should be
   measured in Phase 0 rather than assumed; it feeds the parity spec.
7. **The v1 `attributes` vocabulary.** (See *The `attributes` bag* under Gap 4.) v1
   defines **two table-level** reserved keys — `tabulua.version` and `tabulua.model_name`
   (both on the `position = 0` row) — and **no per-column keys**: emit `attributes` NULL on
   real columns, and add the first per-column key (e.g. `description`, `unit`, `label`) with
   a real use case, bumping the minor version. This keeps v1 minimal while locking in the
   structure that lets it grow without DDL churn. **The version scheme is decided** (product
   `major.minor` string, provenance not gate — see the version note under Gap 4); the one
   sub-decision still open is the exact reserved-vs-`app` namespace spelling.

## Related

- [export_format_reimport.md](export_format_reimport.md) — the family this joins; its
  Scope section is what this plan reverses. Its `tsv:*` / `lua:tabulua` stages are the
  template.
- [boxed_int64.md](boxed_int64.md) — Phase 5e made `int64` a `BIGINT` column with a bare
  literal; the reader-side answer to it is the precondition for this plan.
- [luajit_compatibility.md](luajit_compatibility.md) — why reading a `BIGINT` as a
  number was ever a problem.
- [improved-sql.txt](improved-sql.txt) — the broader "make SQL output better" wishlist
  (foreign keys, whole-DB creation, DB flavours). Independent of this plan, but its
  "load the export into SQLite" scenario is the same territory.
