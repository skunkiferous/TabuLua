# Non-Deterministic Package Load Order Between Unrelated Packages

## Status

**Phase 1 landed (2026-07-06).** `buildDependencyGraph` and `topologicalSort` now
iterate in sorted `package_id` order, so unrelated packages load alphabetically and
deterministically; the rule is documented in DATA_FORMAT_README (Conflict Resolution)
and covered by two new `manifest_info_spec` tests.

**Phase 2 landed (2026-07-06).** `topologicalSort` is now a greedy **ranked Kahn**
scheduler: at each step it loads the lowest-ranked package whose prerequisites have
all loaded, with rank = (input-root position, `package_id`) — so unrelated packages
follow the order their root directories were passed to `processFiles` / the CLI, then
alphabetical `package_id` within one root. `manifest_info.resolveDependencies` gained
`opt_manifestRank` (manifest path → number); `manifest_loader.resolvePackageDependencies`
derives it from `directories` + `file2dir`. Cycle diagnostics keep the same
"Circular dependency detected: a -> b -> a" path message (new `logCycle` walks the
stalled remainder). Note the refinement over Phase 1: in a dependency-entangled set
the greedy rule can order packages differently than the DFS post-order did (both
deterministic; "earliest ready package loads first" is the simpler rule, and it is
what a rank-based preference requires). Tests: 3 new in `manifest_info_spec`
(rank order, edges dominate rank, ranked-before-unranked) + 1 integration in
`manifest_loader_spec` (directory argument order controls unrelated package order,
both directions). **Both phases done; nothing remains in this document.**

Bug analysis + fix plan. Found during a modding-ecosystem review of the landed
[mod_overrides.md](mod_overrides.md) work (2026-07-03). Small, fix-ready; no open
design questions for Phase 1. Phase 2 (user-controlled load order) is optional and
can wait for a concrete need.

## The bug

The relative load order of two packages that are **not related** by `dependencies`
or `load_after` can differ **between runs of the same command on the same data**.

Everything *downstream* of `package_order` is carefully tie-broken:

- `orderFilesByPriorities` (`manifest_loader.lua`) breaks equal priorities
  alphabetically by lowercased path.
- `schedulePackageProcessors` (tier-C Kahn scheduler) breaks ties by load index.
- Overlay composition (`widenTo` union, `suppressValidator` min-severity) is
  deliberately order-independent (mod_overrides.md §3.3).

But the root `package_order` itself is not deterministic:

1. `manifest_info.buildDependencyGraph` builds the edge lists with
   `for package_id, manifest in pairs(packages)`.
2. `manifest_info.topologicalSort` seeds its DFS with
   `for node in pairs(graph)` and emits post-order.

Both iterate string-keyed tables with `pairs()`. Lua 5.2+ randomizes the
string-hash seed per process (`makeseed` in `lstate.c` mixes wall-clock time and
ASLR'd addresses), so `pairs()` order over package ids — and therefore the DFS
visit order, and therefore the topological order of packages the graph does not
constrain — **can change from one process to the next**.

## Why it matters (consequences)

`package_order` is the root of every "load order" the engine promises:

- `loadDescriptorFiles` stacks per-package file priorities using
  `prio_offset = max_prio + 1` at each package boundary (`files_desc.lua`), so the
  data-file order — and with it the **patch plan order** — inherits `package_order`.
- Mod overrides resolve conflicts by **last writer wins in package load order**
  (mod_overrides.md §4.4). With two mutually-unrelated mods patching the same
  cell, *which mod wins can flip between runs*. This silently violates the
  determinism the whole override design is built on.
- `--explain-patch` lineage chains reorder with it, so even the diagnostic tool
  shows different chains on different runs.
- `--export-merged` output can differ between runs for the conflicted cells,
  breaking "diff the merged tree against a known-good copy" workflows.
- Secondary effects: `newDefault` last-wins for overlays from unrelated packages,
  bootstrap execution order, package-validator order, tier-C scheduling tie-break
  (the "load index" being tied on is itself unstable).

Note this is not only a cross-run problem: even with a fixed hash seed, hash
order is an implementation accident — a Lua version bump or a new package id
changing bucket layout would silently reorder packages.

## Phase 1 — deterministic tie-break (the fix)

Make `topologicalSort` deterministic by removing every `pairs()`-order
dependency:

- In `buildDependencyGraph`, iterate packages in **sorted package-id order**
  when building edges (collect keys, `table.sort`, then loop). The edge lists
  themselves are already deterministic per package (`ipairs` over the manifest's
  `dependencies` / `load_after` arrays).
- In `topologicalSort`, iterate the DFS roots in **sorted package-id order**.

Resulting rule, documented in DATA_FORMAT_README: *packages unrelated by
`dependencies` / `load_after` load in alphabetical `package_id` order.*
Alphabetical is arbitrary but stable, explainable in one sentence, and matches
the existing file-level tie-break (lowercased-path alphabetical).

Tests:

- Unit: a graph with 3+ mutually-unrelated packages returns the same order
  regardless of table insertion order (build the input tables in several
  insertion orders; assert identical output).
- Integration: two packages, no relation, both patch the same cell of a shared
  parent — assert the winner is the alphabetically-later package, and that
  `--explain-patch` shows the chain in that order.
- Regression guard: the existing tutorial / spec loads still produce the same
  `package_order` (they are dependency-constrained, so they should be unaffected).

Risk: near zero. Any load that *observably* changes behaviour from this fix was
already non-deterministic.

## Phase 2 — user-controlled load order ✅ LANDED (2026-07-06; see Status)

Real modding ecosystems let the **user** order unrelated mods (Bethesda
loadorder.txt / LOOT, the Paradox launcher list, Factorio's mod list). Alphabetical
package-id order is stable but not controllable: to promote a mod above another
today you must edit a manifest (`load_after`), which a *player* shipping someone
else's mods cannot reasonably do.

Candidate: tie-break unrelated packages by **the order their root directories
were passed to `processFiles` / the CLI** instead of alphabetically (dependency
edges still dominate). The caller-supplied directory list is already ordered;
collection would need to record which input root each manifest came from. A host
application (game launcher, mod manager) then expresses user load order simply by
argument order.

Deferred until a concrete host-application need appears; Phase 1's alphabetical
rule remains the fallback for packages sharing one input root. Cross-reference:
[mod_ecosystem.md](mod_ecosystem.md) (the rest of the ecosystem-layer review).
