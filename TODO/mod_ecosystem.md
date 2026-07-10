# Mod Ecosystem: Optional Compatibility, Conflicts, and Multi-Mod Scale

## Status

**✅ COMPLETE (2026-07-09): all seven phases landed**, plus both phases of the
companion [package_order_determinism.md](package_order_determinism.md). The
user-facing summary of the whole layer is
[documentation/MODDING.md](../documentation/MODDING.md). Only §7's deferred
design notes (load-time joins, negative gating, version-ranged conflicts)
remain open, each waiting on a concrete need.

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
| --- | --- | --- | --- |
| 1 | Mod hard-depends on another mod (library/framework mods, "requires Bob's Metals") | Factorio `dependencies`, Forge `depends`, RimWorld `loadAfter`+error | ✅ `dependencies` + version constraint |
| 2 | Mod patches rows another mod **added** | Ubiquitous — balance mods over content mods | ✅ works: patches apply in package order; each apply re-indexes by PK, so rows added by an earlier mod are targetable (worth a dedicated spec, see Phase 7) |
| 3 | **Optional compatibility**: mod B adjusts itself *if* mod A is present, works fine without | Factorio `? optional-dependency`, RimWorld `PatchOperationFindMod`, Stellaris compat patches folded into the mod | ✅ landed 2026-07-06: `packages` context (§2.2 / Phase 1) + `onlyIfPackages` file gating (§2.1 / Phase 2) |
| 4 | Separate "A+B compatibility patch" mini-mod | The workaround every ecosystem uses where #3 is missing | ✅ a third package hard-depending on both |
| 5 | Declared incompatibility ("this overhaul breaks with X") | Factorio `!mod`, Forge `breaks` | ✅ `conflicts` manifest field (§3 / Phase 3, landed 2026-07-06) |
| 6 | Player-visible conflict report ("which of my 40 mods touch the same thing?") | LOOT, Wrye Bash — entire third-party tools | ✅ `--check-conflicts` (§5 / Phase 5, landed 2026-07-08): conflicts-only apply-order chains, benign composition filtered out, package-qualified sources |
| 7 | Compatibility patch spanning several base-game versions (rows come and go) | Common on slow-updating mods | ✅ `ifMissing:missing_policy\|nil` (§6 / Phase 6, landed 2026-07-08): per-file `error`/`warn`/`silent` tolerance for missing keys, values, and whole target files |
| 8 | Many mods naming files freely → name collisions | Namespacing by mod id (Minecraft `modid:item`, Factorio prototype names) | ✅ landed 2026-07-07 (§4 / Phase 4): deterministic pick + warning on ambiguity, `package.id:Name.tsv` qualified form via the `override_target` column type; `joinInto` was never basename-based (full-path targeting, see Phase 4 notes) |
| 9 | Mod adds a **column** to a parent file, visible to other mods | RimWorld defModExtensions, Bethesda new records | ⚠️ `joinInto` exists but joins apply at **export** only (`exporter.lua` skips secondary files); load-time expressions/validators never see the joined columns (§7; mod_overrides.md §8.5 NOTE still open) |
| 10 | User-controlled load order between unrelated mods | loadorder.txt, launcher lists | ✅ input-root argument order ([package_order_determinism.md](package_order_determinism.md) Phase 2, landed 2026-07-06) |

Scenarios 3, 5, 6, 7, 8 were the actionable gaps — all landed (Phases 1–6);
9 remains a design note (§7), and 10 landed via
[package_order_determinism.md](package_order_determinism.md). Phase 7
(hardening + the modding guide) is what remains of the plan.

## 2. Gap: optional compatibility is not expressible

The single biggest gap. A mod cannot ship content that applies **only when
another mod is present**, because:

- A patch / overlay / bulk-patch file whose target file is not loaded is a
  **hard error** (`patch target '<x>' not found (must match a loaded file by
  basename)` in `patch_executor.applyPatches`; the overlay and bulk paths
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
names the id; and — ✅ landed with Phase 7 — `--check-conflicts` lists all
`onlyIfPackages` ids that never matched any known package id across the run
(known ids = loaded packages plus everything named in `dependencies` /
`load_after` / `conflicts` of all loaded manifests), with an edit-distance
did-you-mean (`manifest_info.unknownGateIds` + `string_utils.closestMatch`).

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

```text
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

The override references — `patchOf`, `schemaOverlayOf`, `bulkPatchOf` —
resolve by **lowercased basename** across every loaded file. (*Correction to
the original survey: `joinInto` does NOT — it targets the full path as listed
in `fileName`, and duplicate listed names already trigger the generic
"Multiple files with name" warning; it is out of scope here.*) With a handful
of first-party packages basename resolution is fine; with many
independently-authored mods, two packages shipping an `Item.tsv` is *when*,
not *if*. Before Phase 4, the resolution comment in
`patch_executor.applyPatches` said it plainly: "on a basename collision the
last file wins (arbitrary, as before)" — a patch could silently bind to the
wrong package's file, and a schema overlay silently applied to *every* file
sharing the target basename.

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

```text
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
  the PK index / `lookup` (cheap: documentation only); (b) apply joins in the
  loaded model (a real feature: header extension, PK-matched cell attach,
  reformatter no-bake, patch interaction). (a) ✅ done in
  `documentation/MODDING.md` (Phase 7); (b) waits for a concrete need.
- **A modding-guide doc page.** mod_overrides.md §8.5 already wished for a
  page mapping mod use-cases to TabuLua features. With this plan the mapping
  is: change cells/rows → patch; bulk → bulk_patch; loosen schema → overlay;
  add columns → join/side-table; conditional content → `onlyIfPackages` +
  `packages` context; ordering → `dependencies`/`load_after`; diagnostics →
  `--explain-patch`/`--check-conflicts`/`--export-merged`.
  ✅ Written as [documentation/MODDING.md](../documentation/MODDING.md)
  (Phase 7).
- **Patch-the-patch.** No ecosystem lets a mod edit another mod's *patch
  document*; they patch the merged result, which TabuLua's load-ordered apply
  already gives. Explicitly out of scope (a patch file is not a patchable
  target — its `typeName` is the `patch` keyword, not a record type).
- **User-controlled load order** — ✅ landed 2026-07-06
  ([package_order_determinism.md](package_order_determinism.md) Phase 2): unrelated
  packages load in input-root argument order, then alphabetical `package_id`.

## 8. Implementation phases (proposed)

Each phase is independently shippable; order chosen so each unlocks the next's
tests. All new columns/types register through the type-wiring registry (no core
`files_desc` edits), per the established pattern.

**Where [package_order_determinism.md](package_order_determinism.md) Phase 2
(user-controlled load order) fits: FIRST — before Phase 1 below. ✅ Landed
2026-07-06 in exactly that slot.** It refines
the load-order tie-break rule (input-root order, then alphabetical `package_id`)
that every later phase's tests and tutorial content observe: the Phase 2
tutorial `compat` package, Phase 3's conflict semantics, and especially
Phase 5's `--check-conflicts` chains (whose whole point is showing users a
last-writer-wins order they can then *reorder* — the lever must exist before
the report telling them to pull it). Landing it first avoids re-touching those
phases' fixtures when the rule changes underneath them. At the absolute latest
it must precede Phase 5.

**Phase 1 — `packages` published context + sandbox presence helpers (§2.2).
✅ LANDED (2026-07-06).** As designed, with two refinements: (a) the reserved
names are seeded into `loadEnv` **before** code libraries load (they load
during dependency resolution), so the existing library-name conflict check
fires naturally — `packages` starts as an empty placeholder and is replaced
with the real read-only table once the package set is resolved (manifest-file
COG therefore sees only the placeholder, documented); (b) the reservation was
generalised: `buildTableSubscribers` now rejects a `publishContext` that would
shadow **any** existing expression-environment name (`files`, `packages`,
`versionSatisfies`, a code library, or a curated sandbox global) instead of
silently clobbering it — closing a pre-existing latent bug for `files` too.
Version is exposed as a plain string. Tests (4, in `manifest_loader_spec`):
`=expr` cells reading `packages[...].version` / absent-package nil /
`versionSatisfies`; a package validator branching on presence; the
code-library collision failing the load; the `publishContext` shadow rejected.
Documented under *Detecting Other Packages* in DATA_FORMAT_README. The `where`
selector integration lands with Phase 2's tutorial compat package (same
evaluation path as validators, already covered).

**Phase 2 — `onlyIfPackages` descriptor column (§2.1). ✅ LANDED (2026-07-06).**
As designed: column registered via the type-wiring registry (module
`package_gating`, `fieldOnMeta=lcFn2OnlyIfPackages`, type
`{package_id}|nil`); gating runs in `files_desc.processFilesDesc` directly
after the variant filter, reusing the `lcSkippedFiles` machinery, keyed on the
same published `packages` set expressions see (threaded as
`opts.loadedPackages` from the `loadEnv` the function already received —
dependency resolution always precedes descriptor loading, so the set is
final). Info-level skip log names the missing id. New
`spec/only_if_packages_spec.lua` (2 integration tests over a core+mod fixture)
covers: gated patch + gated bulk_patch (whose `where` reads `packages` — the
ME-P1 deferred integration) applying when the required package is loaded;
AND semantics (a two-package gate with one absent skips); a gated row whose
file doesn't exist on disk raising no existence error; and the headline
scenario — the mod loading standalone with its whole compat layer quietly
deactivated, no "patch target not found". Tutorial: rather than a third
package, `tutorial/expansion/SeasonalPatch.tsv` is gated on the not-installed
`tutorial.seasons` package, and the expansion manifest adds it to `load_after`
— demonstrating the full idiom (and that `load_after` on an absent package is
a no-op). One scope note: because a skipped row exits before descriptor-column
storage, `lcFn2OnlyIfPackages` only holds entries for *active* gated rows —
the Phase 7 typo heuristic will need to read gate ids from the skipped rows'
cells instead of that map.

**Phase 3 — `conflicts` manifest field (§3). ✅ LANDED (2026-07-06).** As
designed: `conflicts:{package_id}|nil` in MANIFEST_SPEC (normalised like
`load_after` in `extractManifestFromTSV`), checked in `buildDependencyGraph`'s
sorted per-package loop — both-loaded → "Conflicting packages loaded together"
error naming both sides, absent target silently vacuous, self-conflict a
manifest error. Symmetric by construction (every loaded manifest's list is
checked). Version-ranged conflicts stay deferred as designed. Tests: 3 in
`manifest_info_spec` plus a new bad-input fixture
`bad_input/manifest_errors/conflicting_packages` (CLI-mode case — `args.txt`
passing the two package directories, since a data-mode case dir can hold only
one package). No tutorial change (a conflict fails the load; nothing
demonstrable in a shipping tutorial).

**Phase 4 — ambiguous-target warning + qualified targeting (§4).
✅ LANDED (2026-07-07), with three as-implemented corrections to the design:**

1. **`joinInto` was mis-described in §4 and is out of scope.** It does *not*
   resolve by basename — it targets the **full path as listed in `fileName`**
   (`files_desc.validateJoinTargetsExist`), and duplicate listed names already
   trigger the generic "Multiple files with name" warning. No qualifier
   needed; documented in DATA_FORMAT_README (*Targeting a Parent File*).
2. **The qualified form is opt-in per column declaration.** `:` is not a legal
   `filepath` character (which is also why the qualifier is unambiguous), and
   a Files.tsv cell parses under the type the file *declares* — so the
   qualified syntax cannot ride on `patchOf:filepath|nil`. A new built-in
   **`override_target`** type (predicate `isQualifiedPath`: plain path, or
   `qualifier:path`) is accepted as an alternative header spelling via a new
   `altTypes` field on descriptor-column declarations
   (`patchOf:override_target|nil` etc.); existing `filepath|nil` headers are
   untouched.
3. **Schema overlays got the full re-key, not just a warning.** Overlays are
   now collected against the *resolved* target file key (loader passes a
   resolver into `collectOverlays`), fixing a latent bug where an overlay
   silently applied to **every** loaded file sharing the target basename —
   and an overlay target matching no loaded file is now a reported error
   (previously silently inert; doc §3.5 always said error).

Resolution itself is shared: `patch_executor.newTargetResolver` /
`splitQualifiedTarget` (exported) — deterministic alphabetically-first pick +
warning naming all candidates on unqualified ambiguity; qualified filter by
`manifest_loader.buildFileToPackage` ownership (case-insensitive id match);
errors for unknown-package / package-owns-no-such-file. The same resolver
replaced three independent hash-order basename maps (patch apply, package-
processor write scope, `=expr` recompute), removing more collision
nondeterminism. Tests: `spec/target_resolution_spec.lua` (5 integration
tests: ambiguous-unqualified deterministic pick, qualified patch binding,
unknown-qualifier error, qualified overlay binding, and the counter-case
proving the same-basename double-overlay is gone).

**Phase 5 — `--check-conflicts` report (§5). ✅ LANDED (2026-07-08).** As
designed — `Lineage:conflictReport()` (pure lineage consumer) + reformatter flag
(mutually exclusive with `--cog-docs`, exit stays 0) — with the classification
made concrete and two supporting lineage changes:

1. **What counts as a fight.** A whole-value cell write (`= v` /
   `replace_whole`) landing *after* an event from a different source; a row
   removed/replaced while 2+ sources touched it (either order; the row's full
   chain is printed and its cell slots are subsumed, not double-reported); and
   a `newDefault` slot with 2+ distinct sources. Deltas (`append` / `prepend` /
   `remove` / in-place `replace`), `widenTo` unions, validator suppressions,
   and cells written to a row another mod *added* are benign composition —
   including a delta layered on a different source's `= v` (only the reverse
   order clobbers).
2. **Lineage sources are now package-qualified** (`ModA:PricePatch.tsv`) via
   Phase 4's `buildFileToPackage` ownership map, threaded into
   `applyOnePatch` / `applyOneBulkPatch` / `recordLineage` /
   `applyValidatorOverrides`. Without this, two mods shipping the
   conventionally same-named patch file counted as ONE source — a false
   negative in the headline scenario. Also visible in `--explain-patch`.
3. **`newDefault` records its full per-source history** (winner last) in
   `ingestOverlayFile`; previously only the merged winner reached the lineage,
   so an overwritten default was invisible to any consumer. `recordLineage`
   also iterates targets/columns sorted, making schema-event order (and thus
   both reports) deterministic.

Tests: `spec/check_conflicts_spec.lua` (14 — 9 classification units + 5
end-to-end multi-package fixtures, exactly the four designed scenarios plus
row-tension subsumption). Documented in `REFORMATTER.md` (*Check Conflicts*)
and `DATA_FORMAT_README.md` (*Inspecting Overrides*).

**Phase 6 — `ifMissing` tolerance policy (§6). ✅ LANDED (2026-07-08).** As
designed — `missing_policy` enum (`error | silent | warn`) + `ifMissing`
descriptor column (type-wiring module `row_patch`,
`fieldOnMeta=lcFn2IfMissing`), threaded through the patch plan into
`applyOnePatch` / `applyListMerge` / `applyInplaceReplace` and into the
whole-target-file checks — with three as-implemented notes:

1. **`replace` was mis-scoped in §6 and needs no tolerance**: a `replace` on a
   missing key has always *appended* (upsert), never errored — only `update`,
   `replace_oldvalue_`, and list-`remove_` had missing-target severities to
   configure. (`remove`-missing was already a warn no-op; `silent` quiets it,
   and quiets the list-`remove_` not-present warning likewise.)
2. **Whole-file tolerance covers schema overlays too**, not just
   patches/bulks: the overlay-target resolver in
   `manifest_loader.processOrderedFiles` consults the same column, so an
   overlay whose target file is absent under `warn`/`silent` skips that
   overlay file as a logged no-op. Same rationale (a file existing only in
   newer versions of a present package — the case `onlyIfPackages` cannot
   express).
3. `add` on an existing key stays an error under every policy, as designed;
   a package-qualified target with no ownership map (`missing_fn2pkg`, caller
   misuse) also stays a hard error.

Tests: `spec/if_missing_spec.lua` (7 integration tests: default + explicit
`error` regressions, missing-key update under `warn` and `silent` with the
present key still patched, tolerated `replace_oldvalue_`, absent target file
for a patch (`warn`) and an overlay (`silent`), add-collision under `silent`).
Documented under *Tolerating Missing Targets* in `DATA_FORMAT_README.md`, with
cross-links from the `patch_op` table, *Conditional Files*, and *Targeting a
Parent File*.

**Phase 7 — hardening + modding guide. ✅ LANDED (2026-07-09) — the plan is
complete.** As designed:

1. **Scenario-2 spec**: new `spec/mod_on_mod_spec.lua` (2 integration tests)
   pins that a later mod can update cells / merge lists on a row an earlier
   mod's patch **added** — and that `--check-conflicts` classifies that as
   benign layering (count 0) while remove-of-an-added-row is row tension
   (count 1).
2. **Typo heuristic in `--check-conflicts`**: `files_desc` gating collects the
   not-loaded gate ids of skipped rows into `joinMeta.skippedGates` (as
   predicted in Phase 2's scope note, the ids live nowhere else — a skipped
   row exits before descriptor-column storage; the collection loop now
   records **every** missing id of the row, not just the first). The new
   `manifest_info.unknownGateIds(packages, skippedGates)` flags ids matching
   no known id — not loaded, and not named by any manifest's `dependencies` /
   `load_after` / `conflicts` (per §2.1: an id someone references is a real,
   merely-absent mod) — with an edit-distance did-you-mean covering case
   slips, transpositions, and near-miss spellings alike
   (`string_utils.closestMatch`, applied case-insensitively); the reformatter
   prints the section (only when non-empty) after the conflict report.
   Tests in `only_if_packages_spec` (integration + unit).
3. **`documentation/MODDING.md`**: the task-oriented guide — use-case →
   feature map, recipes (patch/bulk/overlay, optional compatibility,
   `ifMissing`, `conflicts`, processors), the **side-table idiom** documented
   as the supported pattern for mod-added columns (§7 option (a); option (b),
   load-time joins, still waits for a concrete need), mods-building-on-mods
   incl. the patch-a-patch exclusion, diagnostics, and an author checklist.
   Linked from the README doc index and the *Mod Overrides* chapter.

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
