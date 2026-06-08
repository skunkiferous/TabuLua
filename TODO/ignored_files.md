# IgnoredFile tag: declarative "don't load this file" recognition

## Status

**Done.** This resolved the open [type_wiring.md](type_wiring.md) **Phase 4**
item (`isMigrationScript` generalisation) and superseded its proposed
`shape_wiring` registry. All changes below shipped (CHANGELOG entry
"`IgnoredFile` type tag and `MigrationScript` built-in type").

## Problem

[manifest_loader.lua](../manifest_loader.lua) recognises migration scripts
with `isMigrationScript(rawtsv)` — a **content-shape heuristic**: it returns
true iff the first data row's column 1 is named `command` and the remaining
columns are `p1, p2, … pN` in order, then drops the file from the load.

Two defects:

1. **False positives = silent data loss.** Any legitimate data file with a
   `command` primary key followed by `p1, p2…` columns is silently skipped.
2. **Implicit / bespoke.** Nothing in the file declares "do not load me"; the
   recognition is a one-off pattern walker that no other file type can reuse.

[type_wiring.md](type_wiring.md) Phase 4 proposed generalising this into a
separate `shape_wiring` registry. That is overkill.

## Why migration scripts can't just go through the type system

Migration scripts live in the data tree but are deliberately **not** loaded as
data, for two reasons that make normal parsing impossible:

1. The parameter columns (`p1…p5`) carry **no fixed per-row type** — each row's
   cells mean different things for different commands.
2. The `command` column — which would be the primary key — **repeats** (e.g.
   `setCell` appears many times), violating TabuLua's primary-key uniqueness
   rule.

So the file must be recognised and skipped **before** any parsing/validation
runs. Recognition must come from the file's declaration, not its shape.

## Design

A built-in **type tag** `IgnoredFile` marks any file type that should be
recognised but not loaded as data. A built-in record type `MigrationScript`
is tagged with it. The loader skips any file whose `typeName` (from `Files.tsv`)
is a member of `IgnoredFile` — a single, generic, declarative check.

Empirically verified facts this relies on (see the discussion that produced
this plan):

- Every record type extends the registered `table` parser
  (`typeSameOrExtends(<anyRecord>, "table") == true`), and unrelated record
  shapes can coexist as members of one tag whose ancestor is `table`.
- The bare kind-keyword `record` is **not** a registered parser, so it cannot
  be a tag ancestor (`registerTypeTag` requires `parseType(ancestor)` to
  succeed). `table` is registered and works.

Therefore the tag uses **`parent = "table"`**, which admits arbitrary record
(file) types with **no change to the tag system**.

### Generality

Any user type can opt into "don't load me" by adding `IgnoredFile` to its
`tags` field (orthogonal to its own `superType` and constraints). Use cases
beyond migration scripts: scratch/template files, fixtures, example data kept
in-tree but excluded from the dataset.

## Changes

1. **`parsers/builtin.lua`** (`registerDerivedParsers`): register
   - `MigrationScript` = `{command:string, p1:string|nil, p2:string|nil,
     p3:string|nil, p4:string|nil, p5:string|nil}` (columns per
     [migration.lua](../migration.lua) `COMMANDS` — up to `p5` via
     `setCellsWhere` `row[6]`).
   - `IgnoredFile` type tag, `parent = "table"`, `members = {"MigrationScript"}`.

2. **`parsers.lua`**: export `isMemberOfTag = introspection.isMemberOfTag`
   on the public API (manifest_loader needs it).

3. **`manifest_loader.lua`**:
   - Delete `isMigrationScript` (and its call site).
   - In `processSingleTSVFile`, right after `fileType` is resolved (before the
     content pipeline read), add:
     ```lua
     if fileType and isMemberOfTag("IgnoredFile", fileType) then
         logger:info("Skipping IgnoredFile-tagged file: " .. file_name)
         raw_files[file_name] = nil
         return
     end
     ```
     Gating before the read means an ignored file is never parsed, never
     validated, and not stored in `raw_files` (matching today's drop
     behaviour).

4. **`spec/manifest_loader_spec.lua`**: update the "should skip migration
   scripts" test — the migration script is now **listed in Files.tsv** with
   `typeName=MigrationScript` and asserted absent from `tsv_files`.

5. **Docs**: `CHANGELOG.md` (Added / Changed / Removed + migration note),
   `DATA_FORMAT_README.md` (new "Ignored files" subsection), and mark
   [type_wiring.md](type_wiring.md) Phase 4 resolved.

## Breaking change (accepted)

In-tree migration scripts must now carry a `Files.tsv` row with
`typeName=MigrationScript`; an unlisted in-tree `.tsv` is no longer
shape-detected and would be parsed as data (and fail). Migration scripts are
one-shot/disposable, and those kept **outside** the dataset (the common CLI
case — `migration.lua <script> <rootDir>` with separate args) are never
scanned and need nothing. `migration.lua` itself reads scripts directly via
`raw_tsv.fileToRawTSV` and is unaffected.

## Verification

- `busted spec/manifest_loader_spec.lua spec/migration_spec.lua
  spec/parsers_introspection_spec.lua`
- Full `busted` suite.
