# PK-Lookup Audit: Eliminate Redundant Row Scans

## Summary

A parsed TabuLua dataset is **PK-indexed natively**: at the bottom of
[tsv_model.lua:767-781](../tsv_model.lua#L767-L781) every data row is
stored both at a numeric position (`dataset[i]`) **and** under its
primary key (`opt_index[tostring(pk)]`), then the whole thing is wrapped
with `readOnly(dataset, opt_index)`. So for any file in `tsv_files`,
`tsv_files[fileName][somePkValue]` is an O(1) lookup straight out of the
loader — no helper, no scan.

That index is easy to lose. Any function that "extracts data rows" or
"wraps the rows for the sandbox" tends to copy entries into a fresh
plain Lua array, dropping every key that wasn't a positive integer.
Downstream consumers — graph helpers, validators, processors, exporters
— then re-build the same PK map locally, sometimes once per call, and
sometimes via a linear scan when one lookup was needed.

Round-trip example (the case that triggered this audit):

```
processTSV → PK-indexed dataset
   ↓
extractDataRows(tsv_file) → plain array {2..N+1 → row}, PK keys dropped
   ↓
wrapRowsForValidation(rows) → another plain array, PK still dropped
   ↓
graph_helpers.buildNameIndex(rows) → rebuilds the PK map from scratch
   ↓
graph_wiring.validateEdgeFiles → also calls indexByName(tsv_file)
   ↓                              (this one was scanning the original
                                  PK-indexed dataset — a pure no-op
                                  rebuild of an index already present.)
```

The graph-types audit (Phase A1-A7, see
[graph_types.md](graph_types.md)) fixed every site along that chain.
The general problem is wider than graphs: the same pattern almost
certainly exists in other code that was written before the wrapper-PK
contract was established. This task is to audit and fix the rest.

## The general problem

A site is suspect if **all three** of the following are true:

1. It iterates `for _, row in ipairs(rows) do …` where `rows` is, or
   could be, a parsed TSV file or a wrapper around one.
2. It either (a) builds a `{[pk] = row}` map for later use, or (b) does
   a `if row.name == X then return row end`-style linear find.
3. The PK column is the row's first column (which is the TabuLua
   convention — `name` for record types, `directed_edge_key` for graph
   edges, etc.).

It is **not** suspect when:

- The "rows" are raw TSV (from `stringToRawTSV`) — no PK structure
  exists at that layer.
- The lookup is keyed on a non-PK column (the indexing only exists for
  column 1).
- The PK is being deliberately normalised (whitespace-stripped, lowercased)
  before lookup — e.g. [tsv_diff.lua:357-362](../tsv_diff.lua#L357-L362).
  The native index uses `tostring(evaluated)` so any other normalisation
  scheme has to build its own map.
- Two files are being walked side-by-side and only the *joined* shape
  matters, not single-row retrieval.

## How to review the codebase efficiently

Three search passes catch almost every instance. Run them with `Grep`,
not by reading whole files; rank hits, then read context only for the
plausible ones.

### Pass 1: index-building loops

```
Grep -n  pattern='\[[a-zA-Z_]+\.name\]\s*='  glob='*.lua'
Grep -n  pattern='\[row\[1\]'                glob='*.lua'
Grep -n  pattern='\[r\[1\]'                  glob='*.lua'
```

These find lines like `idx[r.name] = r` and `map[row[1]] = row`. For
each hit:

- Confirm the surrounding loop is `for _, r in ipairs(rows)`-shaped.
- Trace one call site up to see what `rows` is. If it's a wrapped row
  array (validator/processor sandbox) or a `tsv_files[X]` dataset, the
  index already exists — flag it.

### Pass 2: scan-to-find loops

```
Grep -n -C 2  pattern='if [a-zA-Z_]+\.name ==' glob='*.lua'
Grep -n -C 2  pattern='if [a-zA-Z_]+\[1\] ==' glob='*.lua'
```

Look for the `for _, r in ipairs(rows) do if r.name == X then return r
end end` pattern. Same call-site check as Pass 1. Single-shot finds
that turn into one `rows[X]` are the cheapest possible win.

### Pass 3: wrapper / extractor functions

The architectural cause. Grep for functions whose job is "turn a parsed
dataset into a plain row array":

```
Grep -n  pattern='function [a-zA-Z_]*[Ee]xtract[a-zA-Z_]*Rows' glob='*.lua'
Grep -n  pattern='function wrap[A-Z][a-zA-Z_]*Rows'           glob='*.lua'
Grep -n  pattern='function [a-zA-Z_]*[Dd]ata[Rr]ows'          glob='*.lua'
```

For each hit, read the body. If it does `for i, row in ipairs(rows) do
out[i] = ... end` (or similar) and returns `out` without copying the PK
keys, fix it once at the source — every downstream consumer benefits
automatically without further changes.

### Known seed list (start here)

These are the candidates already surfaced; spot-check first, then run
the passes above to find anything missing.

- [manifest_loader.lua:868-876](../manifest_loader.lua#L868-L876)
  `extractDataRows(tsv_file)` — the main "strip header, return data
  rows" helper used by validators, file pre-processors, and the package
  validator (3 call sites in the same file). Drops the PK index.
- [validator_helpers.lua:214-221](../validator_helpers.lua#L214-L221)
  `lookup(rows, column, value)` — generic column-keyed find. The
  PK-column case (`column == "name"` or column index 1) could short-
  circuit to `rows[tostring(value)]` when rows is PK-indexed; arbitrary
  columns still need the scan.
- [validator_helpers.lua:223-244](../validator_helpers.lua#L223-L244)
  `groupBy(rows, column)` — same story for the PK-column case
  (degenerates to one-row groups, but the same probe-and-shortcut
  pattern applies if someone calls it that way).
- [exporter.lua](../exporter.lua) — large file; Pass 1 will surface its
  index-building loops. Likely candidates around the joined-file
  emitters and the schema export.
- [file_joining.lua](../file_joining.lua) — combines a primary file
  with secondary files keyed on a join column. If the join column is
  the PK (common), this is a Pass 1 hit.
- [manifest_info.lua](../manifest_info.lua) — builds summaries from
  loaded manifests; Pass 1 will say.
- [tsv_diff.lua:350-414](../tsv_diff.lua#L350-L414) `comparePKBased` —
  builds `pk2Map` from `rows2`. The PKs are normalised
  (`normalizeValue` strips whitespace etc.), so this is *not* a
  redundancy — keep as a documented exception, and put a one-line
  comment on the loop noting why the native index can't be reused.

## How to fix

Three patterns, listed cheapest to most invasive. Pick the one that
matches the site.

### Fix pattern 1 — Direct PK access (use when caller controls input)

When the rows-table at the call site is **known** to be a parsed
dataset or a wrapped row array (i.e. PK-indexed), delete the local
index and just look it up:

```lua
-- before
local idx = {}
for _, r in ipairs(rows) do idx[r.name] = r end
local target = idx[someName]

-- after
local target = rows[someName]
```

This is what [graph_wiring.lua:356-372](../graph_wiring.lua#L356-L372)
now does. It's the right fix for engine-internal code that knows what
it is being handed (`tsv_files[X]`, `wrappedRows`, etc.).

### Fix pattern 2 — Probe-and-fallback helper

When the function is a **general-purpose helper** that some callers pass
PK-indexed data to and others pass plain Lua arrays (notably tests),
use the small helper from
[graph_helpers.lua:131-145](../graph_helpers.lua#L131-L145):

```lua
local function nameIndex(rows)
    local first = rows[1]
    if first ~= nil and first.name ~= nil and rows[first.name] == first then
        return rows                          -- already PK-indexed, no work
    end
    local idx = {}                           -- plain array, build once
    for _, r in ipairs(rows) do
        if r.name ~= nil then idx[r.name] = r end
    end
    return idx
end
```

Then `idx[name]` works uniformly. Production paths skip the build; test
fixtures (plain arrays) still work via the fallback. The probe is one
table read — cheap enough to ignore.

For non-`name` PK columns, parameterise on the field name:
`nameIndex(rows, "edgeKey")` and probe `first.edgeKey`. The graph
helpers don't need this yet — every graph-family row keys on `name`.

### Fix pattern 3 — Preserve PK indexing at the source

When the root cause is a wrapper / extractor that strips the index,
**fix it there** so every downstream consumer benefits without
modification. Pattern:

```lua
local function wrapRowsForXxx(rows, …)
    local wrapped = {}
    for i, row in ipairs(rows) do
        local wrappedRow = wrapRowForXxx(row, …)
        wrapped[i] = wrappedRow
        local pkCell = row[1]
        if type(pkCell) == "table" and getmetatable(pkCell) == "cell" then
            local pk = pkCell.parsed
            if pk == nil then pk = pkCell.evaluated end
            if pk ~= nil and type(pk) ~= "table" then
                pk = tostring(pk)
                if wrapped[pk] == nil then wrapped[pk] = wrappedRow end
            end
        end
    end
    return wrapped
end
```

The `tostring` normalisation matches
[tsv_model.lua:771](../tsv_model.lua#L771), so a numeric PK doesn't
collide with positional indexing (`wrapped[5]` is still the 5th row;
`wrapped["5"]` is the row whose PK is `5`).

Reference implementations:

- [validator_executor.lua:78-98](../validator_executor.lua#L78-L98)
  (`wrapRowsForValidation`)
- [processor_executor.lua:137-157](../processor_executor.lua#L137-L157)
  (`wrapRowsForProcessor`)

When the extractor is `extractDataRows`-shaped (raw rows, no `cell`
metatable on row[1]), adapt: read the raw PK from `row[1].evaluated`
exactly as `tsv_model.lua` does, `tostring` it, and assign.

### Side-effect: closures that took ownership of the local index

Some places (e.g. the old
[processor_executor.lua:209-232](../processor_executor.lua#L209-L232)
`buildRowByKey`) returned a closure capturing the just-built index.
After pattern 3, the closure can collapse to a one-liner that delegates
to the now-PK-indexed array:

```lua
local function buildRowByKey(wrappedRows)
    return function(key)
        if key == nil then return nil end
        return wrappedRows[type(key) == "string" and key or tostring(key)]
    end
end
```

Keep the closure if its API is exposed to sandbox code (`rowByKey('x')`
in user expressions); just simplify the body. Delete it if it was only
used internally.

## Suggested implementation order

Each phase is independently shippable; tests after each.

**Phase 1 — Pass-1 audit of engine-internal files** (low risk):

Run Pass 1 globally. For every hit where the rows-table is a known
parsed dataset (`tsv_files[X]`, `loadEnv.files[X]`, the dataset
returned from `processTSV`), apply Fix pattern 1. These are pure
deletions — every test that passes before passes after.

Files most likely affected: `manifest_info.lua`, `exporter.lua`,
`file_joining.lua`, `files_desc.lua`. Read each hit's call site to
confirm the rows-shape before changing.

**Phase 2 — Fix `extractDataRows` at the source** (touches several
files transitively):

Update [manifest_loader.lua:868-876](../manifest_loader.lua#L868-L876)
to also copy PK keys to the returned array (Fix pattern 3, adapted for
raw rows). Removes the need for every downstream consumer to know
about the issue. Full-suite test required because file validators,
pre-processors, and package validators all flow through this.

**Phase 3 — Pass-2 audit (scan-to-find loops)** (per-site fixes):

Run Pass 2 globally. Convert single-row finds to `rows[name]` where
the rows-shape supports it. For helpers that take arbitrary rows,
apply Fix pattern 2 (`nameIndex`-style probe).

**Phase 4 — `validator_helpers.lookup` / `groupBy` PK fast-path**
(behaviour-preserving optimisation):

In [validator_helpers.lua:214-244](../validator_helpers.lua#L214-L244),
add a fast path that detects the PK-column case (column 1 or the
column whose `name` matches the wrapped array's first row PK) and
delegates to `rows[tostring(value)]`. Fall through to the existing
scan for arbitrary columns. Document the optimisation; the API
contract doesn't change.

**Phase 5 — Document the wrapper-PK contract** (prevents regression):

One short subsection in [MODULES.md](../MODULES.md) under
`validator_executor` and `processor_executor`: "**Wrapped row arrays
preserve the dataset's PK index.** `wrappedRows[someName]` returns the
wrapped row for that PK in O(1). Consumers should use this instead of
building a name→row map." Same one-liner on `extractDataRows` once
Phase 2 lands.

## Out of scope

- **Non-PK column indexing.** TabuLua only indexes column 1. A
  `groupBy(rows, "category")` over a non-PK column has to scan — no
  free lunch. If a hot path needs a secondary index, build it once at
  the call site (the current `groupBy` is fine for that).
- **Indexes over computed values.** If a caller wants to look up rows
  by a value derived from multiple columns (e.g. `lowercase(name)`),
  the dataset's index can't help. Build a local map; document why.
- **Cross-file indexes.** The PK index is per-file. A "find the row
  whose `referencedFile` PK equals X across all files" query is
  inherently O(F) at minimum. Not in scope here.
- **Test fixtures.** Many spec files build plain row tables without PK
  indexing. The `nameIndex`-probe fallback handles them transparently;
  there is no need to retrofit every test fixture.

## Acceptance criteria

For each fix:

1. The full suite (`run_tests.cmd`) passes.
2. The pre-commit check (`pre_commit_check.cmd`) passes — JSON, SQL,
   Lua, and TSV-reformat exports of the tutorial all run, plus the
   bad-input regression tests.
3. The change either deletes index-building code (Fix 1), introduces a
   one-time probe (Fix 2), or adds 6-10 lines to a wrapper that pay
   off in every downstream call (Fix 3). If a change adds local
   complexity without removing more elsewhere, reconsider.

For the audit as a whole:

- No remaining occurrences of `idx[r.name] = r` (or similar) inside
  functions that operate on parsed datasets or wrapped row arrays.
- `MODULES.md` documents the wrapper-PK contract so the next contributor
  doesn't reintroduce the pattern.

## References

- [tsv_model.lua:767-781](../tsv_model.lua#L767-L781) — where the
  dataset's PK index is built (`opt_index[tostring(pk)] = ro`).
- [read_only.lua:123-192](../read_only.lua#L123-L192) — how `readOnly`
  combines numeric storage and an opt_index into a single proxy.
- [graph_wiring.lua:352-358](../graph_wiring.lua#L352-L358),
  [graph_helpers.lua:131-160](../graph_helpers.lua#L131-L160),
  [validator_executor.lua:78-98](../validator_executor.lua#L78-L98),
  [processor_executor.lua:137-157](../processor_executor.lua#L137-L157),
  [processor_executor.lua:209-220](../processor_executor.lua#L209-L220)
  — the four reference fixes already applied for graph types.
