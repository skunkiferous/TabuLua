# Pre-Processors

## Summary

Add a new optional processing step — **pre-processors** — that runs after files
are parsed but **before** any row, file, or package validators. A pre-processor
is a sandboxed user expression (mirroring file validators) that can **mutate**
the parsed rows of its file: typically to derive, normalise, or symmetrise data.

This is feature #1 of two needed before a future `graph_node` built-in can be
implemented. (Feature #2 — letting a dependent package add rows to a file
defined in a parent package — is tracked separately.)

## Motivation

TabuLua's current pipeline is read-only after `=expr` cell evaluation:
expressions populate empty cells in a single row, validators inspect the
finished data, but nothing transforms the *set* of rows. Several real use cases
need exactly that:

- **Bidirectional references.** A "prerequisites" column on each row implies an
  inverse "requiredBy" column. Authors should write only one side.
- **Derived back-references** in graph-shaped data (motivating use case:
  `graph_node` / `tree_node`).
- **Normalisation** that depends on the whole file (e.g. levelling all rows
  to a common base, sorting derived arrays).

A row-local `=expr` cannot do any of this because it can only read its own
row. A file validator sees the whole file but cannot write. Pre-processors
fill the gap.

## Design

### Naming

- New `Files.tsv` column: **`preProcessors:{processor_spec}|nil`**.
- New built-in type alias: **`processor_spec`** =
  `expression|{expr:expression,level:error_level|nil,priority:number|nil,rerunAfterPatches:boolean|nil,requires:{package_id}|nil}`.
  The first two fields mirror `validator_spec`. The remaining three are
  processor-specific:
  - `priority` (default `100`) — controls within-file ordering; see "Ordering" below.
  - `rerunAfterPatches` (default `false`) — see "Re-running after patches" below.
  - `requires` — opt-in cross-package ordering; only meaningful when the
    processor is declared at package scope as a tier-C mod-override processor
    (see [mod_overrides.md](mod_overrides.md) §6).
- New module: **`processor_executor`** (sibling of `validator_executor`).

`preProcessors` (not `preValidators`, not `processors`) — the prefix makes the
"runs before validators" timing explicit and the `Processor` suffix avoids
confusion with the `Validator` family.

### Where it runs in the pipeline

```
processFiles
  ├── resolvePackageDependencies
  ├── resolveFileDescriptors
  ├── processOrderedFiles            -- parses TSVs, evaluates =expr cells
  ├── runAllPreProcessors    [NEW]   -- mutate parsed rows
  └── runAllValidators               -- row + file + package validators
```

Pre-processors are run **per file**. Across files, processing order follows
package load order (inherited from `load_after` / `dependencies` in the manifest).

### Ordering

Within a file, processors are sorted by **ascending `priority`** (default `100`);
ties are broken by the order written in the `preProcessors` cell. Lower priority
runs first — same convention as `loadOrder` in `Files.tsv`, so authors don't have
to learn a new dial.

Authors who don't care about ordering can omit `priority` entirely: every
processor gets `100` and they run in textual order, identical to the
original "as written" rule.

A later processor sees the effects of earlier ones.

### Re-running after patches

When a dependent (child) package adds or modifies rows in a parent file via the
mod-override patch system (see [mod_overrides.md](mod_overrides.md)), the parent's
own pre-processors have already finished — they ran against the original parent
data, before any patches were applied. Patched rows therefore don't receive
any derived data the parent's processor was responsible for computing
(e.g. inverse back-references).

A processor opts into being re-executed after patches by setting
**`rerunAfterPatches: true`** in its spec. When the mod-override pipeline reaches
the cross-package processor phase (mod_overrides.md §7), every processor with
this flag is re-invoked on its file, in the same priority order as the
initial run, against the now-patched data.

Because the processor runs twice on the same rows in this case, its author
contract is stronger than the baseline: it must be **idempotent** — applying it
twice in succession must yield the same result as applying it once. Inverse
relation computation (the motivating use case) is naturally idempotent because
the second run re-derives the same back-refs from the same forward-refs;
counters and accumulators are not.

Default is `false`. Most processors are write-once and don't need to participate
in mod-override re-runs at all.

### Mutation API exposed to the processor sandbox

A processor expression runs in a sandboxed environment identical to a file
validator (`rows`, `fileName`, `ctx`, helpers, code libraries, published
contexts), **plus** a small set of write helpers:

| Helper | Purpose |
| --- | --- |
| `setCell(row, column, value)` | Set a parsed value on a row; re-serialises through the column's type to keep `.parsed`/`.reformatted` consistent. |
| `clearCell(row, column)` | Equivalent to `setCell(row, column, nil)` (only valid if the column is nullable). |
| `rowByKey(key)` | O(1) lookup into the current file by primary-key value (built once per processor run). |

`rows` is presented as a writable wrapper (not the read-only proxy validators
get). Direct field assignment (`row.foo = "bar"`) is **not** supported — the
sandbox forces use of `setCell` so we can re-validate the value's type. Direct
read access (`row.foo`) returns the parsed value as in validators.

Adding or removing rows is **not** supported in v1. Both have non-trivial
ordering, key-uniqueness, and reformat-round-trip implications. They can be
added later behind explicit `addRow` / `removeRow` helpers.

### Defensive contract

Processors run before any validation, so the input may be logically broken
(broken refs, duplicate keys, cycles, etc.) — but it has already passed
**type** parsing, so every cell's type is sound.

Documented author contract:

1. **Never raise.** If a processor expression evaluates to an error or runtime
   exception, the load aborts with a clear error message naming the file and
   processor. (Same failure mode as a file validator quota violation.)
2. **Be tolerant of missing data.** Helper functions like `rowByKey` return
   `nil` for unknown keys rather than erroring. The author's expression must
   handle that — usually by skipping the affected row and leaving validation
   to flag it.
3. **No order dependence.** Within a file, processors run top-down, but the
   author should not assume an order that mixes write-then-read across rows
   unless they explicitly walk the array twice.

### Result interpretation

Validators return `true`/error-string. Processors return *nothing* meaningful.
A processor that returns `false` or a string is treated the same as a
validator failure for diagnostics (logged at the level configured in
`{expr, level}`, default `error`), but the row mutations it *did* perform
before failing are kept. This matches validators: a failed validator does not
roll back state, and processors should follow the same rule.

### Quota

`PROCESSOR_QUOTA = 50000` per file. Higher than `FILE_VALIDATOR_QUOTA`
(10,000) because mutation work is more expensive than pure checking.
Configurable via the module API for tests, like the existing quotas.

### Round-trip / reformatter behaviour

By default, reformatting writes the **original** raw cells, **not** the
processor-mutated values. Rationale: the reformatter's job is to faithfully
preserve author input; values "computed" by a processor are derived state, not
source-of-truth, and round-tripping them would silently change the on-disk
file every time it loads. This matches how `=expr` defaults are already
preserved in the file.

(A future opt-in flag could materialise processor output during reformat, but
v1 will not include it.)

### Module split

A new module `processor_executor.lua` exposes:

- `runFilePreProcessors(processors, rows, fileName, parsersAPI, badVal, extraEnv) -> bool, warnings`
- `PROCESSOR_QUOTA` (number, mutable for tests)
- `normalizeProcessorSpec(spec)` — delegates to `validator_executor.normalizeValidatorSpec`
- `getVersion()`

Rationale for a new module rather than extending `validator_executor`:
the write helpers, the row wrapper, and the row re-serialisation logic are
processor-specific. `processor_executor` will `require("validator_executor")`
to reuse `normalizeValidatorSpec` and the env-building primitives. Common
helpers can later be lifted into a shared `sandbox_env.lua` if duplication
grows.

Dependency list for `processor_executor`:

```
comparators, named_logger, parsers, predicates, read_only, sandbox,
serialization, string_utils, table_utils, validator_executor, validator_helpers
```

`parsers` is new (vs `validator_executor`) — needed for re-serialising mutated
cells through the column type.

## Implementation Plan

### Phase 1 — Type and column plumbing

1. **`parsers/builtin.lua`**: register `processor_spec` alias as
   `expression|{expr:expression,level:error_level|nil}`. Add a one-line doc
   block above the registration mirroring `validator_spec`.
2. **`files_desc.lua`**:
   - Add column constant `PRE_PROCESSORS_COL = "preProcessors:{processor_spec}|nil"`.
   - Extend `parseFilesDescHeader` to recognise it and return a
     `preProcessorsIdx`.
   - Extend `processFilesDesc` to read the column and populate a new
     `lcFn2PreProcessors` map.
   - Update the `opts` docstring at the top of `processFilesDesc`.
3. **`manifest_loader.lua`**: pass `lcFn2PreProcessors` through the chain
   alongside `lcFn2FileValidators`; include it in the returned `joinMeta`.

### Phase 2 — `processor_executor` module

1. Create `processor_executor.lua` modelled on `validator_executor.lua`:
   - Writable row wrapper: a metatable that exposes `.parsed` reads on
     `__index` and rejects `__newindex` (forcing `setCell`).
   - `createProcessorEnv(rows, fileName, ctx, extraEnv)` — builds the sandbox
     env; reuses validator helpers (`unique`, `lookup`, `groupBy`, `all`, …)
     and adds write helpers `setCell`, `clearCell`, `rowByKey`.
   - `setCell(row, column, value)`:
     - Looks up the cell, asserts the column exists in the header.
     - Calls the column's parser (already attached to the cell) to validate
       the new value's type; on failure, reports via `badVal` and returns.
     - Updates `cell.parsed`, `cell.value`, `cell.reformatted` through
       the same code path used by `=expr` evaluation.
   - `runFilePreProcessors`: same shape as `runFileValidators` but uses
     `PROCESSOR_QUOTA` and the writable wrapper.
2. Register `processor_executor` with `global_reset` if it adds module-level
   state (likely none — keep stateless).

### Phase 3 — Wire into the pipeline

1. **`manifest_loader.lua`**: add `runAllPreProcessors(tsv_files, joinMeta,
   loadEnv, badVal)`, called from `processFiles` between
   `mergeManifestFiles(...)` and `runAllValidators(...)`. Iterate
   `joinMeta.lcFn2PreProcessors`; for each file, call
   `processor_executor.runFilePreProcessors`.
2. Threading: pre-processors must see the same published contexts as
   validators. Pass `loadEnv` through unchanged (it already carries
   `loadEnv.files` and published contexts).
3. Edge cases:
   - File with no `preProcessors` column → skipped.
   - File filtered out by variant → skipped (use the existing
     `lcSkippedFiles` set).
   - Joined secondary files: processors run on the secondary file's own row
     set, **before** join. (Join happens at export time, not load time, so
     this is already the case.)

### Phase 4 — Tests

New `spec/processor_executor_spec.lua` covering:

- Normalisation of `processor_spec` string vs `{expr, level}`.
- `setCell` updates `.parsed`, `.value`, `.reformatted` consistently.
- `setCell` rejects type-incompatible values (reports via `badVal`).
- `setCell` on a non-existent column reports via `badVal`.
- `clearCell` rejects non-nullable columns.
- `rowByKey` returns `nil` for unknown keys (no throw).
- `runFilePreProcessors` runs processors in order; second processor sees
  first's writes.
- Quota enforcement: an infinite-loop processor aborts cleanly.
- A throwing processor reports an error and the load continues to other
  files (matches validator behaviour).
- Reading helpers (`all`, `lookup`, etc.) are available.

Extend `spec/manifest_loader_spec.lua`:

- Integration test loading a tiny package with `preProcessors` set,
  asserting that subsequent file validators see the mutated rows.
- Integration test asserting reformatter output is the **original** content,
  not the mutated content.

Add `bad_input/processor_errors/` fixtures (subdirectories with a `Files.tsv`,
data file, and expected output) for:

- `processor_syntax_error/` — invalid Lua in a processor expression.
- `processor_quota_exceeded/` — processor that exhausts the quota.
- `processor_type_violation/` — processor calls `setCell` with a value the
  column type rejects.
- `processor_unknown_column/` — processor calls `setCell` on a missing column.

Each fixture follows the existing `bad_input/*/` convention.

### Phase 5 — Tutorial example

Add a small in-file inverse-relation example to `tutorial/core/`. Suggested
shape: a new file `tutorial/core/Quest.tsv` of type `Quest` with columns
`name:name`, `prerequisites:{name}|nil`, `unlocks:{name}|nil`. The author
fills in `prerequisites` only; a `preProcessors` entry in `Files.tsv`
computes `unlocks` as the inverse relation:

```tsv
fileName:filepath   ...  preProcessors:{processor_spec}|nil
Quest.tsv           ...  "for _, r in ipairs(rows) do for _, p in ipairs(r.prerequisites or {}) do local target = rowByKey(p); if target then setCell(target, 'unlocks', append(target.unlocks, r.name)) end end end"
```

(The exact expression will be split across multiple `preProcessors` entries
for readability, and `append` will be either added as a helper or replaced
with inline `table.insert` — to be finalised when writing the example.)

This example deliberately mirrors the `graph_node` use case so the future
graph feature can replace it with a `graph_node`-typed file.

### Phase 6 — Documentation

1. **`DATA_FORMAT_README.md`**:
   - Add a "Pre-Processors" section between "Expression Evaluation" and
     "Row, File, and Package Validators". Cover: purpose, syntax, the write
     helpers, the defensive contract, ordering, quota, round-trip behaviour.
   - Update the `Files.tsv Fields` table to include `preProcessors`.
   - Update the "Quota and Performance" table to include
     `Pre-processors | 50,000 operations per file`.
   - Add an `Error Reporting` subsection mirroring the validator examples.
2. **`MODULES.md`**:
   - Add `processor_executor` row to the Module Index (alphabetical
     position between `predicates` and `raw_tsv`).
   - Add a `### processor_executor` module-detail section after the
     existing `### predicates` section.
   - Update the Dependency Graph block at the bottom (extends the
     `validator_executor` branch with `processor_executor` as a sibling
     that depends on it and on `parsers`).
3. **`tutorial/README.md`**:
   - Add a "Quest.tsv" entry under "Core Package".
   - Add a "Pre-Processors" sub-section under the walkthrough explaining
     what the processor does and why.
4. **`REFORMATTER.md`**: brief note in the round-trip section that
   pre-processor effects are **not** persisted on reformat.
5. **`CHANGELOG.md`**: add an `### Added` bullet under `[Unreleased]`
   describing the feature.
6. **`README.md`**: update the "Features" bullet list — add
   "Pre-Processors — mutate parsed rows before validation" (or fold into
   the existing "Comprehensive Validation" bullet).

### Phase 7 — Version bump

`processor_executor` module starts at `semver(0, 18, 0)`. Bump the matching
version constant on every module that gains a new dependency or a public
API change (at minimum: `files_desc`, `manifest_loader`, `parsers.builtin`).

## Out of scope (deferred)

- **Cross-file / cross-package processors.** Needed for the graph use case
  where an expansion package adds nodes to a graph defined in the core
  package. This requires the *second* TODO ("append rows to parent package
  file" or equivalent) to land first; only then does a package-level
  processor have something to operate on. A package-level
  `preProcessors` manifest field is the natural shape, but its semantics
  depend on whether feature #2 is "row append" or "logical view".
- **Adding or removing rows from within a processor.** Requires deciding
  how the reformatter handles author-invisible rows.
- **Persisting processor output on reformat.** Would require an opt-in flag
  per processor and a careful policy for what counts as "owned by the
  processor" vs "owned by the author".
- **A built-in `graph_node` / `tree_node` type and a `cycleFree` validator
  helper.** Both build *on top* of pre-processors and the cross-package
  feature; tracked as separate TODOs after both prerequisites land.

## Open questions

1. Should `setCell` be allowed to set a value on a column not declared in
   the header? Current answer: **no** — error. Avoids creating columns by
   side effect; the schema stays driven by the header. (Reconsider if a
   real use case appears.)
   - Response: I think this is OK for now, because we cannot add/remove rows. Either we can do both, or neither.
2. Should processors see the row index? Validator code uses 1-based row
   indices including the header row; processors will likely want 1-based
   *data* indices. Decision: expose a `dataIndex(row)` helper that returns
   the 1-based data-row position. The name makes it explicit that the
   header row is excluded, so processor authors don't have to remember a
   different convention from validators (where `row.__idx` includes the
   header).
3. `processor_spec` reuses `error_level` for the `level` field, but a
   processor "warning" is a stretch semantically. We could keep `level` for
   forward compatibility (and to allow the same parser as `validator_spec`)
   but document that only `error` is meaningful in v1.
   - Response: I think this is OK for now.
4. Helper functions specific to processors (`append`, `prepend`,
   `removeFromList`, `addToSet`) — add them to `validator_helpers` (where
   they would also be readable from validators) or to a new
   `processor_helpers` module? Lean toward `validator_helpers` if they are
   pure-functional; otherwise a new module.
   - Response: Use a new `processor_helpers` module.

These should be resolved during Phase 2 implementation, not blockers for
starting work.
