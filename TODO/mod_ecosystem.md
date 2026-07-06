# Mod Ecosystem: Optional Compatibility, Conflicts, and Multi-Mod Scale

## Status

Research and plan (2026-07-03). Follow-up to the fully-landed
[mod_overrides.md](mod_overrides.md): that work built the **data-operation
layer** (what a mod can do to parent data); this document covers the
**ecosystem layer** (how many mods from many authors coexist). It comes out of
a review of how popular moddable games behave when mods build on other mods and
when mods ship *optional* compatibility with other mods.

The companion bug-fix doc [package_order_determinism.md](package_order_determinism.md)
(non-deterministic order between unrelated packages) should land **before or with**
Phase 3 here, since conflict semantics are meaningless while last-writer-wins is
unstable.

## Scope

TabuLua's manifest today has two inter-package primitives:

- `dependencies:{{package_id, cmp_version}}|nil` — **hard** requirement with a
  version constraint (`=`, `>`, `>=`, `<`, `<=`, `~`, `^`); a missing or
  version-mismatched dependency fails the load (`manifest_info.buildDependencyGraph`).
- `load_after:{package_id}|nil` — **soft ordering**: if the named package is
  present it loads first; if absent, silently no constraint.

That is the *ordering half* of a soft dependency. What real ecosystems
additionally have, and TabuLua lacks, is the **presence half**: content that
activates only when another mod is installed, declared incompatibilities, and
the diagnostics users need once dozens of independently-authored packages
compose.

## 1. Survey: mod-on-mod scenarios in real ecosystems

| # | Scenario | Real-world examples | TabuLua today |
|---|---|---|---|
| 1 | Mod hard-depends on another mod (library/framework mods, "requires Bob's Metals") | Factorio `dependencies`, Forge `depends`, RimWorld `loadAfter`+error | ✅ `dependencies` + version constraint |
| 2 | Mod patches rows another mod **added** | Ubiquitous — balance mods over content mods | ✅ works: patches apply in package order; each apply re-indexes by PK, so rows added by an earlier mod are targetable (worth a dedicated spec, see Phase 7) |
| 3 | **Optional compatibility**: mod B adjusts itself *if* mod A is present, works fine without | Factorio `? optional-dependency`, RimWorld `PatchOperationFindMod`, Stellaris compat patches folded into the mod | ❌ not expressible (§2) |
| 4 | Separate "A+B compatibility patch" mini-mod | The workaround every ecosystem uses where #3 is missing | ✅ a third package hard-depending on both |
| 5 | Declared incompatibility ("this overhaul breaks with X") | Factorio `!mod`, Forge `breaks` | ❌ no `conflicts` field (§3) |
| 6 | Player-visible conflict report ("which of my 40 mods touch the same thing?") | LOOT, Wrye Bash — entire third-party tools | ⚠️ lineage records it; `--explain-patch` shows one cell at a time; no conflicts-only report (§5) |
| 7 | Compatibility patch spanning several base-game versions (rows come and go) | Common on slow-updating mods | ⚠️ `update`/`replace_oldvalue_` on a missing key is a hard error; tolerance was designed (mod_overrides.md §5.2) but deliberately left out of v1 (§6) |
| 8 | Many mods naming files freely → name collisions | Namespacing by mod id (Minecraft `modid:item`, Factorio prototype names) | ⚠️ `patchOf`/`schemaOverlayOf`/`bulkPatchOf`/`joinInto` resolve by **basename only**; on collision "last file wins (arbitrary)" per the comment in `patch_executor.applyPatches` (§4) |
| 9 | Mod adds a **column** to a parent file, visible to other mods | RimWorld defModExtensions, Bethesda new records | ⚠️ `joinInto` exists but joins apply at **export** only (`exporter.lua` skips secondary files); load-time expressions/validators never see the joined columns (§7; mod_overrides.md §8.5 NOTE still open) |
| 10 | User-controlled load order between unrelated mods | loadorder.txt, launcher lists | ⚠️ see [package_order_determinism.md](package_order_determinism.md) Phase 2 |

Scenarios 3, 5, 6, 7, 8 are the actionable gaps; 9 and 10 are tracked here as
design notes / deferred phases.

## 2. Gap: optional compatibility is not expressible

The single biggest gap. A mod cannot ship content that applies **only when
another mod is present**, because:

- A patch / overlay / bulk-patch file whose target file is not loaded is a
  **hard error** ("patch target '<x>' not found (must match a loaded file by
  basename)" in `patch_executor.applyPatches`; the overlay and bulk paths
  behave the same way). So `CompatA/ItemPatch.tsv` targeting mod A's file
  kills the load whenever A is absent.
- Nothing can gate a `Files.tsv` row on package presence.
- No sandbox surface (validators, `where` selectors, `=expr` cells, COG, tier-C
  processors) can ask "is package X loaded?". Tier-C's `requires` warns when
  the required package is unloaded but still runs the processor — ordering, not
  presence.

The workaround (scenario 4's separate compat package) works but forces authors
to publish and maintain N extra packages — exactly the boilerplate Factorio's
`?` dependencies and RimWorld's `PatchOperationFindMod` were invented to remove.

Two complementary mechanisms close the gap, one declarative and one expression-level:

### 2.1 `onlyIfPackages` descriptor column (declarative gating)

A new optional `Files.tsv` column, contributed through the type-wiring registry
like every other feature column:

```tsv
fileName:filepath   typeName:type_spec   patchOf:filepath|nil   onlyIfPackages:{package_id}|nil
CompatA.tsv         patch                AItems.tsv             {a.mod.id}
```

Semantics:

- The row is active only when **every** listed package is loaded (list = AND;
  the OR case is two rows / two files). When inactive, the file is skipped
  exactly like a variant-filtered row — reuse the `lcSkippedFiles` machinery in
  `files_desc.processFilesDesc`, which already bypasses the
  "listed file does not exist on disk" check and the priority warning.
- Applies to **any** file kind, not just patches: conditional data files,
  overlays, bulk patches, joins, code libraries via their carrier files. One
  mechanism, whole surface.
- Skipping is logged at info level with the reason ("skipped: package
  'a.mod.id' not loaded") so a user can see why a compat file didn't apply.
- The gating check needs the loaded-package set inside descriptor processing:
  thread a `packagesById` set into `loadDescriptorFiles`' opts (it already
  receives `desc_file2pkg_id`; the manifests are resolved before descriptor
  files load, so the set exists in time).

The load-order idiom to document: a conditional patch on mod A's data still
needs A **ordered first**, so the manifest pairs `load_after: {a.mod.id}` with
`onlyIfPackages` on the compat rows. `load_after` alone was always the ordering
half; this is the presence half.

**Typo hazard.** A misspelled package id silently deactivates the file forever
(indistinguishable from "mod absent"). Mitigations: the info-level skip log
names the id; and Phase 5's report can list all `onlyIfPackages` ids that never
matched any known package id across the run (a likely-typo heuristic — known
ids can be collected from `dependencies` / `load_after` of all loaded packages).

**Negative gating** ("only if X is *absent*" — RimWorld supports this for
vanilla-fallback patches) is deliberately deferred: it inverts load-order
reasoning (you can't `load_after` an absent package) and the use cases are
rarer. If needed later: a sibling `notIfPackages:{package_id}|nil` column.

### 2.2 `packages` published context (expression-level presence)

Expose the loaded-package set to every sandbox that already sees published
contexts: a read-only `packages` table, `package_id → {version=…, name=…}`,
injected into `loadEnv` by `manifest_loader.processFiles` right after
`resolvePackageDependencies`. Then:

- a `where` selector can write `=packages["a.mod.id"] and row.tags has "metal"`,
- a validator can degrade gracefully ("warn unless the rebalance mod is loaded"),
- a COG doc can render mod-aware documentation,
- a tier-C processor can branch on presence (today it can only see its own id).

Version is exposed so a compat patch can distinguish A 1.x from A 2.x
(`packages["a"].version` is a string; compare via a sandbox helper if needed —
exposing `versionSatisfies(op, req, installed)` as a sandbox helper is a cheap
add-on here).

Collision note: `loadCodeLibraries` errors when a library name collides with an
existing `loadEnv` key, so a user library named `packages` becomes a load error
once this lands — breaking, but loudly and trivially fixable (rename the
library). Reserve the name in DATA_FORMAT_README.

## 3. Gap: no declared incompatibility

Two total-overhaul mods currently compose silently, last-writer-wins. Every
mature ecosystem lets a mod say "do not load me with X" (Factorio `!x`,
Forge `breaks`).

Add a manifest field, mirroring `load_after`'s shape:

```
conflicts:{package_id}|nil
```

- Checked in `buildDependencyGraph` where both manifests are in hand: if a
  package listed in `conflicts` is loaded, **error** (consistent with how a
  missing hard dependency fails the load — an explicit author declaration
  should not be soft-ignored).
- Symmetric by construction: either side declaring it is enough.
- Version-ranged conflicts ("incompatible with X < 2.0") deferred; if needed
  the field grows to the `dependencies` tuple shape
  (`{{package_id, cmp_version}}`) where the constraint names the *broken*
  range.

## 4. Gap: basename-only targeting collides at scale

All cross-package references — `patchOf`, `schemaOverlayOf`, `bulkPatchOf`,
`joinInto` — resolve by **lowercased basename** across every loaded file. With
a handful of first-party packages that's fine; with many independently-authored
mods, two packages shipping an `Item.tsv` is *when*, not *if*. Today the
resolution comment in `patch_executor.applyPatches` says it plainly: "on a
basename collision the last file wins (arbitrary, as before)". A patch can
silently bind to the wrong package's file.

Two steps:

1. **Warn on ambiguity (cheap, do first).** When building the
   basename→fullname map, detect that a *targeted* basename maps to 2+ loaded
   files and warn, naming all candidates and which one won. Only targeted
   basenames — two unrelated `Notes.tsv` no patch touches shouldn't warn.
   Same check wherever overlays and joins resolve their targets.
2. **Qualified targeting (the real fix).** Allow the target column to name the
   owning package: `patchOf=core.game:Item.tsv`. Unqualified stays
   basename-global (backward compatible); qualified restricts the match to
   files owned by that package (ownership = longest-prefix directory match,
   the same rule `buildFileToPackage` / `matchDescriptorFiles` already use).
   `:` is a safe separator — it cannot appear in a `package_id` (a `name`) and
   a Windows drive-letter prefix can't be confused with one because the target
   is package-relative. Applies uniformly to `patchOf` / `schemaOverlayOf` /
   `bulkPatchOf` / `joinInto` via their shared parse helper.

## 5. Gap: no conflicts-only report

`--explain-patch` answers "who set *this* cell?" — one cell, or one file, at a
time. The question a user with 40 mods actually starts with is "**where do my
mods fight?**". The lineage collector already auto-records every override write
whenever override work exists (mod_overrides.md Phase 7), so this is one report
away:

- New reformatter flag `--check-conflicts`: after the load, walk the lineage
  event list and print only cells (and rows, and schema slots) written by
  **2+ distinct sources** (source = package or file, as lineage already
  attributes), each as its apply-order chain — i.e. exactly the
  `--explain-patch` chain format, filtered to length ≥ 2 with distinct owners.
- Include row-level tension: a row one package `remove`d and another package
  targeted (today a warn at apply time, but it scrolls past; the report should
  aggregate it).
- Distinguish **benign composition** from **fights** where cheap: two overlays
  widening the same column compose by design (union) and shouldn't alarm;
  two `update`s on the same cell are a genuine last-writer-wins and should.
- Exit code stays 0 on conflicts (they are legal by design); this is a
  diagnostic, not a gate. A `--check-conflicts=error` strict variant can come
  later if a host application wants conflict-free guarantees.

## 6. Gap: patches can't tolerate missing targets (multi-version compat)

mod_overrides.md §5.2 planned configurable severity for "patch targets a key
that isn't there"; v1 shipped fixed severities (`update` missing key = error,
`remove` missing = warn no-op, `replace_oldvalue_` not found = error). A
compatibility patch that supports base-game 1.x *and* 2.x — where a row exists
in one version only — cannot be written without erroring on one of them.

Add a per-patch-file policy, as a descriptor column beside `patchOf`:

```
ifMissing:missing_policy|nil      -- enum: error | warn | silent  (default error)
```

- Scope: `update` / `remove` / `replace` on a missing PK, and
  `replace_oldvalue_` / list-`remove_` values not found. `add` on an
  *existing* key stays an error always (that's a collision, not a version gap).
- Per-file, not per-row: a compat file is tolerant as a unit; mixing strict and
  tolerant rows in one file is not worth a column. Per-row can come later if
  ever needed.
- With §2's `onlyIfPackages` this completes the compat-patch toolkit: gate on
  presence, tolerate version drift within presence.
- Also covers the earlier `optionalTarget` idea: extend the same policy to the
  **whole target file** being absent (the hard error in
  `applyPatches`) — under `warn`/`silent` the patch file becomes a logged
  no-op. That subsumes the "target mod present but this file only exists in
  its newer versions" case that `onlyIfPackages` (package granularity) can't
  express.

## 7. Design notes / deferred

- **Columns added by mods, visible at load time.** The `joinInto` answer in
  mod_overrides.md §8.5 only materialises in the *export*: `exporter.lua`
  filters secondary files out and merges them into the joined output, so
  load-time validators / `=expr` / other mods never see the joined columns as
  row fields, and the §8.5 NOTE (cross-package join targets; COG-generating the
  join file to mirror parent rows) is still open. Two options when this
  becomes pressing: (a) document the **side-table idiom** as the supported
  pattern — the extension file keyed by the parent's PK, consumers use
  `rowByKey`/`lookup` (cheap: documentation only); (b) apply joins in the
  loaded model (a real feature: header extension, PK-matched cell attach,
  reformatter no-bake, patch interaction). Do (a) now as part of the
  "modding guide" below; (b) waits for a concrete need.
- **A modding-guide doc page.** mod_overrides.md §8.5 already wished for a
  page mapping mod use-cases to TabuLua features. With this plan the mapping
  is: change cells/rows → patch; bulk → bulk_patch; loosen schema → overlay;
  add columns → join/side-table; conditional content → `onlyIfPackages` +
  `packages` context; ordering → `dependencies`/`load_after`; diagnostics →
  `--explain-patch`/`--check-conflicts`/`--export-merged`. Write it as
  `documentation/MODDING.md` in the phase that lands last.
- **Patch-the-patch.** No ecosystem lets a mod edit another mod's *patch
  document*; they patch the merged result, which TabuLua's load-ordered apply
  already gives. Explicitly out of scope (a patch file is not a patchable
  target — its `typeName` is the `patch` keyword, not a record type).
- **User-controlled load order** — tracked in
  [package_order_determinism.md](package_order_determinism.md) Phase 2.

## 8. Implementation phases (proposed)

Each phase is independently shippable; order chosen so each unlocks the next's
tests. All new columns/types register through the type-wiring registry (no core
`files_desc` edits), per the established pattern.

**Phase 1 — `packages` published context + sandbox presence helpers (§2.2).**
Small: build the read-only table in `processFiles` after dependency
resolution, inject into `loadEnv`, expose `versionSatisfies` as a sandbox
helper. Reserve the `packages` name in docs. Tests: `where` selector and
package validator branching on presence/version; collision with a user code
library named `packages` errors loudly.

**Phase 2 — `onlyIfPackages` descriptor column (§2.1).** The conditional-load
mechanism. Registry-contributed column; gating inside
`files_desc.processFilesDesc` via the variant-skip path; info-level skip
logging. Tests: conditional patch applies when the package is present and is
skipped (whole load green) when absent; conditional *data* file likewise;
skipped file exempt from the on-disk existence check; `load_after` +
`onlyIfPackages` idiom in the tutorial (a small `compat` package).

**Phase 3 — `conflicts` manifest field (§3).** Depends on
[package_order_determinism.md](package_order_determinism.md) Phase 1 landing
first only in spirit (conflict *semantics* assume stable order); code-wise
independent. MANIFEST_SPEC addition + check in `buildDependencyGraph`. Tests:
both-loaded errors naming both packages; absent conflict target is silent;
self-conflict is a manifest error.

**Phase 4 — ambiguous-target warning + qualified targeting (§4).** Step 1
(warning) can ship alone if step 2 grows. Tests: two packages shipping the
same basename + a patch targeting it warns and names the winner; qualified
`pkg:basename` binds to the named package's file; qualified miss ("package has
no such file") errors; `joinInto` gets the same treatment.

**Phase 5 — `--check-conflicts` report (§5).** Pure lineage consumer +
reformatter flag (mutually exclusive with `--cog-docs`, like its siblings).
Tests: two mods updating one cell → reported chain; overlay-union composition
not reported; remove-vs-update tension reported; no override work → empty
report, exit 0.

**Phase 6 — `ifMissing` tolerance policy (§6).** New `missing_policy` enum +
descriptor column; thread into `applyOnePatch` / delta appliers / target
resolution. Tests: missing-key update under `warn`/`silent`; missing *target
file* under `warn` (logged no-op load succeeds); default stays error
(regression on existing bad_input fixtures).

**Phase 7 — hardening + modding guide.** A dedicated spec for scenario 2
(mod C patches a row mod B added — works today by construction, but nothing
pins it); typo-heuristic listing for `onlyIfPackages` ids (§2.1) folded into
`--check-conflicts`; write `documentation/MODDING.md` (§7) mapping use-cases
to features, including the side-table idiom for mod-added columns.

## 9. What already works (verified, no change needed)

For the record, the review confirmed these compose correctly today: mod-on-mod
patch chains (a mod's files are ordinary targets; per-apply PK re-index makes
rows added by earlier mods targetable); version-constrained hard dependencies
with the full operator set; dependency-cycle detection with path reporting;
zip-packaged mods as patch/overlay sources and targets; order-independent
overlay composition (union widening, min severity); post-patch re-validation;
same-row `=expr` recompute; `--explain-patch` / `--export-merged` / no-bake.
The gaps above are all in the many-mods-many-authors layer, not in the
data-operation layer.
