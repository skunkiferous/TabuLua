# Registry-driven descriptor-column map lifecycle

## Summary

Finish the type-wiring generalization for optional `Files.tsv` columns. The
registry already drives column **recognition, parsing, and storing**
([files_desc.lua:179-212](../files_desc.lua#L179-L212),
[:334-400](../files_desc.lua#L334-L400)). It does **not** drive the
**lifecycle of the backing maps** — each `lcFn2*` map is still allocated,
threaded, and re-assembled into `joinMeta` by hardcoded name in
[manifest_loader.lua](../manifest_loader.lua) and
[files_desc.lua](../files_desc.lua). This plan makes the map lifecycle
registry-driven so a feature module (graphs being the motivating example) is
fully pluggable with **no** name reference left in the two core loader modules.

This is the loose end already flagged in
[type_wiring.md:99,114](type_wiring.md#L114) ("one bespoke `Files.tsv` column,
`edgesFor`, plumbed through the loader") — promoted here to a concrete change.

## Motivation / the `edgesFor` smell

`lcFn2EdgesFor` (the graph edge-file column) appears by name in both core
loader modules even though graphs are supposed to be entirely addable on top of
the base project. Tracing every occurrence shows it is **never read** by either
module — it is only:

1. **allocated by name** — [manifest_loader.lua:532](../manifest_loader.lua#L532)
   `local lcFn2EdgesFor = {}`
2. **threaded by name** — positional arg at
   [manifest_loader.lua:549](../manifest_loader.lua#L549) →
   [files_desc.lua:588](../files_desc.lua#L588)
3. **re-keyed by name into `opts`** —
   [files_desc.lua:617](../files_desc.lua#L617)
4. **re-assembled by name into `joinMeta`** —
   [manifest_loader.lua:634](../manifest_loader.lua#L634)

The *consumer* side is already correctly pluggable: `graph_wiring` registers the
`edgesFor` column **and** its edge↔node post-pass in one self-contained module
([builtin_wiring.lua:464-470](../builtin_wiring.lua#L464-L470)), and
`validateEdgeFilesPass` reads everything it needs out of `joinMeta`/`tsv_files`
by its own known key ([builtin_wiring.lua:338-458](../builtin_wiring.lua#L338-L458)).
Nothing in core reaches *into* graph logic.

So the four sites above are pure plumbing left over from a half-finished
generalization — not a missing mechanism. `edgesFor` is simply the clearest
case: the other registered columns each have a *second* reason their name still
appears in core (see "What stays" below), so they cannot vanish entirely, but
`edgesFor` can and should.

## Current state: two halves, one generalized

| Concern | Driven by registry? | Where |
| --- | --- | --- |
| Header recognition (`name:type` → column) | ✅ Yes | [files_desc.lua:179-212](../files_desc.lua#L179-L212) via `descriptorColumnsByName()` |
| Row-loop parse + store into `joinMeta[fieldOnMeta][lcfn]` | ✅ Yes | [files_desc.lua:334-400](../files_desc.lua#L334-L400) |
| **Map allocation** (`local lcFn2X = {}`) | ❌ No | [manifest_loader.lua:516-535](../manifest_loader.lua#L516-L535) |
| **Map threading** (positional params) | ❌ No | [files_desc.lua:584-589](../files_desc.lua#L584-L589) |
| **`opts` assembly** (`opts.lcFn2X = ...`) | ❌ No | [files_desc.lua:601-624](../files_desc.lua#L601-L624) |
| **`joinMeta` assembly** | ❌ No | [manifest_loader.lua:623-644](../manifest_loader.lua#L623-L644) |

The row loop already reads its target via `opts[decl.fieldOnMeta]` and even
guards for a missing pre-allocation ("A nil target means the loader didn't
pre-allocate a map" — [files_desc.lua:337-339](../files_desc.lua#L337-L339)).
That guard is the design's own admission that allocation was left manual.

The registry is fully sealed before `loadDescriptorFiles` runs (bootstraps +
`sealTypeWiring()` at
[manifest_loader.lua:1021-1030](../manifest_loader.lua#L1021-L1030)), so
`descriptorColumnsByName()` is complete and authoritative at allocation time.
No bootstrap cycle blocks this.

## Proposed design

Drive the map lifecycle from `descriptorColumnsByName()` the same way parsing
already is. Concretely: a single shared `metaMaps` table owns every
registered-column map; the loader auto-creates one empty map per registered
`fieldOnMeta`; `joinMeta` is assembled from the registry rather than a
hand-written field list.

### 1. Collapse the `loadDescriptorFiles` signature

Replace the ~11 per-column positional map parameters with a single `metaMaps`
table. New shape (illustrative):

```lua
local function loadDescriptorFiles(desc_files_order, prios, desc_file2mod_id,
    post_proc_files, extends, lcFn2Type, lcFn2LineNo, metaMaps,
    raw_files, loadEnv, badVal, variants, lcSkippedFiles)
```

- `lcFn2Type`, `lcFn2LineNo`, `extends`, `post_proc_files` stay explicit — they
  are **core/derived**, not registered descriptor columns. `lcFn2Type` and
  `lcFn2LineNo` are populated directly in `processFilesDesc`
  ([files_desc.lua:384-385](../files_desc.lua#L384-L385)); `extends` is built by
  `checkTypeName`.
- `metaMaps` carries all the `fieldOnMeta`-keyed maps.

Inside `loadDescriptorFiles`, before the load loop:

```lua
for _, decl in pairs(descriptorColumnsByName()) do
    metaMaps[decl.fieldOnMeta] = metaMaps[decl.fieldOnMeta] or {}
end
```

Then `opts` pulls column maps straight from `metaMaps` (the row loop already
reads `opts[decl.fieldOnMeta]`, so `opts` can simply *be* / wrap `metaMaps`,
plus the core entries). The explicit `lcFn2EdgesFor = ... or {}` and
`lcFn2Transcoder = ... or {}` lines at
[files_desc.lua:617-618](../files_desc.lua#L617-L618) and every other
`lcFn2X = lcFn2X` line in the `opts` literal go away.

### 2. Assemble `joinMeta` from the registry in `processOrderedFiles`

Delete the per-column `local lcFn2X = {}` block
([manifest_loader.lua:516-535](../manifest_loader.lua#L516-L535)) and build
`joinMeta` by starting from `metaMaps` and adding the non-column entries:

```lua
local metaMaps = {}
local desc_files = loadDescriptorFiles(..., lcFn2Type, lcFn2LineNo, metaMaps, ...)
...
local joinMeta = metaMaps          -- every registered fieldOnMeta map, already populated
joinMeta.lcFn2Type     = lcFn2Type -- core/derived additions
joinMeta.extends       = extends
joinMeta.lcSkippedFiles = lcSkippedFiles
```

`lcFn2EdgesFor`, `lcFn2JoinColumn`, `lcFn2Export`, `lcFn2JoinedTypeName` —
columns that no core module reads — now appear **nowhere** in
`files_desc.lua` / `manifest_loader.lua`.

### 3. What stays (deliberate aliases, not leaks)

Some registered-column maps are genuinely *consumed* inside the core loaders, so
they keep a local alias pulled out of `metaMaps` — but they are no longer
*allocated* or *assembled* by hand:

| Map | Consumed in core by | Reason it stays referenced |
| --- | --- | --- |
| `lcFn2Ctx`, `lcFn2Col` | `buildTableSubscribers` ([manifest_loader.lua:215-268](../manifest_loader.lua#L215)) | context/column publishing is an engine feature |
| `lcFn2JoinInto` | `validateJoinTargetsExist` / `validateFileJoins` ([files_desc.lua:534-561](../files_desc.lua#L534-L561)) | join validation lives in core |
| `lcFn2RowValidators`, `lcFn2FileValidators`, `lcFn2PreProcessors` | `runAll*` + written via `ensureList` in `processSingleTSVFile` ([manifest_loader.lua:409-414](../manifest_loader.lua#L409-L414)) | validator/processor execution is core; maps mutated post-load |
| `lcFn2Transcoder` | `loadOtherFiles` ([manifest_loader.lua:497-503](../manifest_loader.lua#L497-L503)) | data-vs-asset routing is core |

These read `metaMaps.lcFn2X` where needed. Their *names* remaining in core is
acceptable: they are core engine behaviours, not addable features. The litmus
test the refactor satisfies: **a feature module that only declares a column +
consumes it via its own `joinMeta` key (like graphs) needs zero core edits.**

> Future option (out of scope): the still-core-consumed maps could move behind
> registry-driven accessors too (e.g. validators/processors via their wired
> `applyTypeWiring` contributions already), shrinking core further. Noted, not
> planned here.

## Blast radius

- **[files_desc.lua](../files_desc.lua)** — `loadDescriptorFiles` signature +
  `opts` assembly. `processFilesDesc` row loop is **unchanged** (already
  generic).
- **[manifest_loader.lua](../manifest_loader.lua)** — `processOrderedFiles`
  local-map block, the `loadDescriptorFiles` call, and the `joinMeta` literal.
  Downstream consumers (`runAllValidators`, `runAllPreProcessors`,
  `loadOtherFiles`, exporter) read `joinMeta` by key and are **unchanged**.
- **Public API note:** `loadDescriptorFiles` is exported in the `files_desc` API
  table ([files_desc.lua:674](../files_desc.lua#L674)). The signature change is
  breaking for any external caller. In-tree the only callers are
  `manifest_loader` and the ablation spec below. Decide explicitly whether to
  treat this as an internal-only API (preferred — simpler) or to keep a
  back-compat shim.
- **[spec/files_desc_ablation_spec.lua](../spec/files_desc_ablation_spec.lua)** —
  `buildAndLoad` calls `loadDescriptorFiles` directly with the long positional
  list ([:104-109](../spec/files_desc_ablation_spec.lua#L104-L109)) and reads
  back `lcFn2Ctx` / `lcFn2EdgesFor` etc. Must be updated to the `metaMaps`
  shape. This spec is the one that asserts per-column ablation, so it is the
  primary regression guard for the change.

## Step-by-step

1. Add the `metaMaps` allocation loop + signature change to
   `loadDescriptorFiles`; rewrite `opts` to source column maps from `metaMaps`.
2. Update `processOrderedFiles`: drop the hand-written `lcFn2*` block, pass
   `metaMaps`, assemble `joinMeta` from it + core entries, and re-derive the
   handful of local aliases the function still needs.
3. Update `files_desc_ablation_spec.lua` `buildAndLoad` to the new signature.
4. Run the full spec suite; pay attention to:
   - `files_desc_ablation_spec` (per-column presence/round-trip)
   - `graph_wiring_integration_spec` (edge-file end-to-end —
     [spec/graph_wiring_integration_spec.lua](../spec/graph_wiring_integration_spec.lua))
   - `type_wiring_register_module_spec` (column merge / `fieldOnMeta` mapping)
5. Grep to confirm `lcFn2EdgesFor` (and the export-only join maps) no longer
   appear in `files_desc.lua` / `manifest_loader.lua`.
6. Update docs that describe the loader plumbing:
   [type_wiring.md:99,114,1220-1227](type_wiring.md#L1220-L1227) and the
   `edgesFor` row in [type_wiring.md:99](type_wiring.md#L99).

## Acceptance check

A grep for `EdgesFor` over `files_desc.lua` and `manifest_loader.lua` returns
**nothing**, the full suite is green, and adding a brand-new feature column via
`registerModule({descriptorColumns=...})` + a consumer that reads
`joinMeta[fieldOnMeta]` requires **no** edit to either loader module.

## Open questions

1. **API surface:** keep `loadDescriptorFiles` exported with the new signature
   (treat as internal), or stop exporting it / add a shim? (Recommend: keep
   exported, new signature, document as internal — only the ablation spec and
   `manifest_loader` use it.)
2. **`opts` vs `metaMaps` identity:** make `opts` literally *be* `metaMaps`
   (column maps + core fields on one table) or keep `opts` separate and have it
   reference `metaMaps`? Identity is simplest but mixes core fields into the
   table that becomes `joinMeta` — verify no unwanted keys leak into `joinMeta`
   (e.g. `log`, `prio_offset`, `fn2Idx`). Likely keep them separate: `opts`
   references `metaMaps`, `joinMeta` is built from `metaMaps`.
3. **Core-consumed maps:** leave the aliases (this plan) or push them behind the
   registry too in a follow-up? (Recommend: leave for now; note as future work.)
