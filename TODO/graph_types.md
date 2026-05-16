# Graph Types: `basic_graph_node`, `graph_node`, `tree_node`

## Summary

Add built-in support for three graph-shaped data layouts, in increasing
strictness:

| Type | Shape | Links | Cycles | Roots |
|---|---|---|---|---|
| `basic_graph_node` | Undirected graph | `graphLinks` | allowed | n/a |
| `graph_node` | Directed acyclic graph (DAG) | `graphParents` + `graphChildren` | forbidden | one or more |
| `tree_node` | Tree | `graphParents` + `graphChildren` (≤1 parent each) | forbidden | exactly one |

Each is a record type plus a pre-baked **pre-processor** (completes the
inverse relation) and a set of **validators** (refs exist, cycle-free, tree
shape). Authors opt in by declaring `superType=<one of the three>` in
`Files.tsv` — the same discovery mechanism already used by `enum` and
`custom_type_def`.

Optional **edge files** can be attached to any of the three kinds for
authoring per-edge data (weights, types, descriptions). Edges are pure
metadata: the node file remains the source of truth for which links exist.

## Prerequisites

This plan rests on two other planned features:

- **[pre_processors.md](pre_processors.md)** — the graph completion logic is
  implemented as a pre-processor with `rerunAfterPatches: true`. The plan
  here cannot start until pre-processors land.
- **[mod_overrides.md](mod_overrides.md)** — single-package graphs work as
  soon as pre-processors are in. Cross-package graph extension (a child
  package adds nodes to a parent package's graph) needs mod-overrides
  Phase 2 (row patches) and Phase 5 (cross-package pre-processors). The
  `rerunAfterPatches` plumbing already in pre_processors.md handles
  back-reference recomputation once the mod system can add rows.

The plan below is split into two layers matching these dependencies.

## Motivation

A DAG-only design ("everything is a `graph_node`") was the initial sketch,
but on reflection three layers map better to real use cases:

- **Undirected basic graph.** Many domains have peer relationships with no
  direction — friendships, shared-tag networks, neighbour adjacencies,
  faction-vs-faction tensions. Authoring these as a DAG forces an arbitrary
  parent/child labelling.
- **DAG.** Dependency graphs, tech trees with multiple prerequisites, mod
  load-order graphs, ability prerequisites — anything where "X precedes Y"
  is well-defined and cycles are bugs.
- **Tree.** Skill trees, dialogue trees, area hierarchies, classification
  taxonomies — anywhere a single parent is the natural shape and a single
  root is an invariant worth enforcing.

Layering them means each user picks the loosest type that fits, and the
engine catches violations of the *stricter* shape only when the user
declared the stricter type. A DAG author isn't punished for having multiple
roots; a tree author is.

Edges-as-separate-file solves a real duplication problem: if every link
needs a weight, putting `weight` on the node would require it on *both*
endpoints and a validator to enforce symmetry. A dedicated edge file with
a single row per edge is one source of truth, naturally avoids conflicts,
and round-trips cleanly.

## Design

### Field naming convention

Per [DATA_FORMAT_README.md:39](../DATA_FORMAT_README.md#L39) ("Field names
should use **camelCase**, starting with a lower-case letter"), the
engine-owned structural fields are camelCase:

- `graphLinks` (undirected)
- `graphParents`, `graphChildren` (directed)

The `graph` prefix marks them as engine-owned across all three node types —
authors extending a node type can still add their own `parents` or
`children` fields without colliding.

Type aliases follow the existing snake_case convention used by `type_spec`,
`validator_spec`, `processor_spec`: `node_name`, `basic_graph_node`,
`graph_node`, `tree_node`, `basic_graph_edge`, `graph_edge`, `tree_edge`,
`undirected_edge_key`, `directed_edge_key`.

### The node types

All three node types are registered in `parsers/builtin.lua` as built-in
record-type aliases. `tree_node` is defined by **redeclaring `name`** —
a regular user-writable inheritance form that produces a distinct named
type with no new fields:

```text
basic_graph_node = {name:node_name, graphLinks:{node_name}|nil}
graph_node       = {name:node_name, graphParents:{node_name}|nil, graphChildren:{node_name}|nil}
tree_node        = {extends:graph_node, name:node_name}
```

The `tree_node` form is allowed because re-declaring a field with the same
type is explicitly compatible (see
[parsers/type_parsing.lua:540-560](../parsers/type_parsing.lua#L540-L560)).
This means a user can define their own equally-structured-but-distinct
sub-type by the same trick (e.g. `{extends:tree_node, name:node_name}` to
add their own validator family) — there is no built-in privilege here.

**Documentation note** required in `DATA_FORMAT_README.md`: the redeclaration
form is mildly weird. We should call it out under "Field Redefinition in
Child Record Types" — same-type redeclaration is legal and is the supported
idiom for "create a structurally identical but distinct sub-type".

### The `node_name` PK type

`node_name` is a new built-in type alias:

```text
node_name = name + forbid '__'
```

Mechanically: extend the `name` parser (already restricts to identifier-shape
ASCII strings) with one additional rejection — the substring `__`. Reported
as a regular parse error pointing at the offending cell.

The `__` exclusion is what makes edge-key encoding (next section) unambiguous.
Naming it `node_name` rather than `graph_node_name` is deliberate: the type
is useful any time an author wants to compose two names into a key with `__`
as a separator. Graph edges are the first consumer but not the only
foreseeable one.

### Edge-key sub-types

Two new built-in types parse compound keys of the form `<a>__<b>` where
each half is a `node_name`:

| Type | Used in | Parser behaviour |
|---|---|---|
| `undirected_edge_key` | `basic_graph_edge` files | Splits on `__`, validates both halves are `node_name`s, sorts ascending lexicographically (byte order), emits a `warn` if reordering occurred, reassembles as `lower__higher`. |
| `directed_edge_key` | `graph_edge` / `tree_edge` files | Same split + validation; preserves authored order (no reorder). Self-loops (`A__A`) parse fine; the cycle validator on the node file flags them as cycles for DAG/tree contexts later. |

Both types are sub-types of `name` at the value level (a single identifier
string fits the `name` shape). The structured parsing lives in the parser
function, not in the value representation — so primary-key uniqueness
checks (which compare parsed strings) flag duplicates naturally: two rows
authored as `A__B` and `B__A` in a `basic_graph_edge` file both parse to
`A__B`, and the engine's existing PK-uniqueness rule triggers a clean error
with no new code path.

Edge cases the parser must handle:

- `__B` or `A__` (empty half) — error.
- `A__B__C` (more than two halves) — error.
- A half that contains `__` — impossible by construction (the half is a
  `node_name`).
- Reorder warning is `warn`, not `error` — the data is correct, the file
  will be canonicalised on the next reformatter run.
- Self-loops (`A__A`) — valid for undirected; flagged later by the cycle
  validator for DAG/tree.

### The edge types

Edge types are built-in record-type aliases parallel to the node types:

```text
basic_graph_edge = {name:undirected_edge_key}
graph_edge       = {name:directed_edge_key}
tree_edge        = {extends:graph_edge, name:directed_edge_key}
```

The `name` column **is** the compound edge key — single-column primary key,
no schema change to TabuLua's PK model. Authors extending an edge type add
their own columns (`weight:float|nil`, `kind:EdgeKind|nil`, etc.) using
existing record-inheritance syntax.

### Edge files: attaching to a node file

A new `Files.tsv` column **`edgesFor:filepath|nil`** points an edge file
at its node file (basename match, same convention as `joinInto`):

```tsv
fileName:filepath   typeName:type_spec   superType:super_type   edgesFor:filepath|nil   ...
Quests.tsv          Quest                graph_node                                     ...
QuestEdges.tsv      QuestEdge            graph_edge             Quests.tsv              ...
```

`edgesFor` is engine-validated:

- Target file must exist and have a graph-node-family `superType`.
- The edge file's `superType` must match the node file's family
  (`basic_graph_node` ↔ `basic_graph_edge`, etc.). Mixing families is an
  error.
- Every edge row's parsed endpoints must reference rows that exist in the
  node file.
- Every edge row's endpoints must match a declared link on the node file
  (option **(a)** from prior discussion — edges are pure metadata; an edge
  without a corresponding link in the node file is an error). Missing
  edge rows are *not* an error: an unannotated link simply has no edge data.
- A node file may have **zero or one** edge file. Multiple edge files for
  the same node file is an error (avoids per-cell merge questions). Authors
  needing extra per-edge data can extend the edge record type with more
  columns.

### Helpers (`processor_helpers` module)

The `processor_helpers` module — already planned in pre_processors.md — gets
a graph-helper section:

| Helper | Applies to | Returns |
|---|---|---|
| `isRoot(row)` | `graph_node`, `tree_node` | `true` iff `#graphParents == 0` |
| `isLeaf(row)` | `graph_node`, `tree_node` | `true` iff `#graphChildren == 0` |
| `parentsOf(row)` | `graph_node`, `tree_node` | `graphParents` as a list (never nil) |
| `childrenOf(row)` | `graph_node`, `tree_node` | `graphChildren` as a list (never nil) |
| `neighboursOf(row)` | `basic_graph_node` | `graphLinks` as a list (never nil) |
| `splitEdgeKey(key)` | edge rows | `(a, b)` — the two endpoint names |
| `makeEdgeKey(a, b)` | directed | `"a__b"` |
| `makeUndirectedEdgeKey(a, b)` | undirected | `"<lower>__<higher>"` (canonical) |
| `edgeForLink(edgeRows, a, b)` | both edge kinds | the edge row whose endpoints are `{a,b}`, or `nil` |

These are convenience wrappers — none does work that can't be expressed
inline. Their value is making validator and processor expressions read
declaratively.

### Auto-wiring via `superType` chain

When a file declares `superType=<graph-node-family>` (directly or
transitively), the engine auto-attaches:

1. **A completion pre-processor.** Symmetrises the link fields. For
   `basic_graph_node`: `A.graphLinks ⊇ {B}` ⇒ `B.graphLinks ⊇ {A}`. For
   `graph_node`/`tree_node`: `A.graphChildren ⊇ {B}` ⇒
   `B.graphParents ⊇ {A}` and vice versa. Registered with
   `priority: 50` (low number → runs early) and `rerunAfterPatches: true`.
2. **Validators.** Refs-exist for all three; cycle-free for `graph_node`
   and `tree_node`; single-root and ≤1-parent for `tree_node`.

When the file *also* has an `edgesFor` edge file, an additional
package-level validator checks the edges↔links consistency described above.

Author overrides:

- Author can still write their own `preProcessors` and `fileValidators` in
  `Files.tsv` — those run **after** the auto-wired ones (so the
  user-defined ones see completed back-references).
- Author can suppress an auto-wired validator using the mod-override
  schema-overlay mechanism (`suppressValidator` row, see
  [mod_overrides.md §3](mod_overrides.md)). This is useful when a tree
  intentionally has multiple roots during construction, etc.

The auto-wiring mechanism itself is generalisable: it's "a built-in
superType implicitly contributes `preProcessors` and validator entries to
every file that extends it". This could later support other built-in
shape-types (`series_node`, `partition_node`, …). Worth a footnote in the
plan but not v1 work.

### Cycle-detection helper

`processor_helpers` (or a new `graph_helpers` if the API grows) exposes a
shared cycle-detection helper used by both the cycle validator and the
single-root tree validator:

```text
findCycle(rows, parentField) → nil | path-array
```

Standard DFS with grey/black colouring; returns the first cycle path
found (for the error message) or `nil` if acyclic. Reuses TabuLua's
existing `lookup` helper internally.

## Implementation Plan

### Layer A — single-package graphs (depends only on pre-processors)

Each phase here is independently shippable.

**Phase A1 — Type registration**

- `parsers/builtin.lua`: register `node_name`, `undirected_edge_key`,
  `directed_edge_key`, `basic_graph_node`, `graph_node`, `tree_node`,
  `basic_graph_edge`, `graph_edge`, `tree_edge`.
- For `node_name`: extend the existing `name` parser with the `__`
  rejection rule.
- For the edge-key types: write parser functions in `parsers/builtin.lua`
  that split / validate / (re)order / reassemble.
- Tests: `spec/parsers_graph_types_spec.lua` covering all parser paths
  including the edge cases enumerated above.

**Phase A2 — Helpers**

- Add the graph helpers (`isRoot`, `isLeaf`, `parentsOf`, `childrenOf`,
  `neighboursOf`, `splitEdgeKey`, `makeEdgeKey`, `makeUndirectedEdgeKey`,
  `edgeForLink`, `findCycle`) to `processor_helpers`.
- Helpers are pure-functional, no engine state.
- Tests: extend `spec/processor_helpers_spec.lua` (or create it if the
  pre-processors plan didn't already).

**Phase A3 — Auto-wired completion pre-processors**

- `manifest_loader.lua` (or a new `graph_wiring.lua` module if the
  auto-wiring grows non-trivial): when a file's typeName transitively
  extends `basic_graph_node` / `graph_node` / `tree_node`, append the
  matching completion processor entry to `lcFn2PreProcessors` for that
  file before the pre-processor phase runs.
- The completion processors are stock expressions stored as strings,
  configured with `priority: 50` and `rerunAfterPatches: true`.
- Tests: integration tests in `spec/manifest_loader_spec.lua` confirming
  back-references are populated after load for each of the three families.

**Phase A4 — Auto-wired validators**

- Same mechanism for `lcFn2FileValidators`: append refs-exist (all three),
  cycle-free (`graph_node` + `tree_node`), and tree-shape (`tree_node`)
  validators.
- For tree-shape: ≤1 parent on every node; ≥1 root; exactly 1 root after
  completion (a "disconnected forest" is a multi-root violation).
- Tests: `spec/graph_validators_spec.lua` for each rule, plus
  `bad_input/graph_errors/` fixtures (missing ref, cycle, two roots in a
  tree, two-parents in a tree, link to self in DAG, etc.).

**Phase A5 — Edge files (`edgesFor`)**

- New `Files.tsv` column `edgesFor:filepath|nil`, parsed in
  `files_desc.lua` analogously to `joinInto`.
- Auto-wired package-level validator: every edge's endpoints exist in the
  target node file *and* match a declared link in the node file.
- One edge file per node file (multi-file error).
- Family-match enforcement (basic↔basic, directed↔directed).
- Tests: integration tests covering the success path, the orphan-edge
  error, and the family-mismatch error.

**Phase A6 — Tutorial example**

The tutorial currently lacks any graph data. A fresh `SkillTree.tsv` as a `graph_node` file in
`tutorial/expansion/`. Have more advanced skills depend on multiple basic skills. For example,
some "tracking" skill might depend on first getting a improved perception AND
an improved stealth skill. And the links can have data too, like how many levels you require
in each "parent" skill, to buy the new skill.

**Phase A7 — Documentation**

- `DATA_FORMAT_README.md`: new "Graph Types" section covering the three
  node types, the edge-key types, `node_name`, `edgesFor`, auto-wiring,
  and the same-type-redeclaration idiom used by `tree_node`.
- `MODULES.md`: update `processor_helpers` description; if `graph_wiring`
  is a new module, add a module-detail entry.
- `tutorial/README.md`: walkthrough of the chosen tutorial file.
- `CHANGELOG.md`: `### Added` bullet under `[Unreleased]`.
- `README.md`: "Features" bullet for graph support.

### Layer B — cross-package graph extension (depends on mod-overrides)

These phases are only implementable once mod-overrides Phase 2 (row
patches) and Phase 5 (cross-package pre-processors) have landed. They are
mostly *configuration* changes — the heavy lifting was already done by
Layer A and by the mod-override implementation.

**Phase B1 — Verify `rerunAfterPatches` interaction**

- The completion processors from Phase A3 already declare
  `rerunAfterPatches: true`. Confirm they actually re-run against patched
  data in the cross-package phase.
- Tests: integration tests with a parent package defining a graph and a
  child package adding nodes via `patchOp=add` and removing nodes via
  `patchOp=remove`, asserting that back-references on existing nodes are
  recomputed correctly.

**Phase B2 — Patch-time validator re-run**

- All auto-wired validators (refs-exist, cycle-free, tree shape) run
  against the merged-and-patched state — this is the default behaviour
  per mod-overrides §7, so the only work is verifying it.
- Tests: child package introduces a cycle by adding a parent edge; expect
  the cycle validator to fire with a clear error path.

**Phase B3 — Cross-package edge files**

- A child package may declare an edge file with `edgesFor` pointing at a
  parent package's node file. Engine resolves the path the same way
  `patchOf` does (basename match in any parent package).
- Constraint: at most one edge file per node file across **all** loaded
  packages. A child package declaring an edge file while the parent already
  has one is an error — child mods can instead add `patchOp=add` rows to
  the parent's edge file (using the `patchOf` mechanism).
- Tests: child package adds edges to a parent graph; child package
  attempts to add a competing edge file (rejected).

**Phase B4 — Tutorial / docs update**

- Extend the tutorial example with an expansion-package mod that adds a
  new graph node and an edge to the existing graph, demonstrating the
  end-to-end story.
- Cross-references between `graph_types.md`, `pre_processors.md`, and
  `mod_overrides.md` so newcomers can navigate the dependency.

## Out of scope (deferred)

- **Edge files for multi-graph cases.** If a node file participates in
  several distinct relationship families (e.g. "depends on" *and* "is part
  of"), one edge file per file isn't enough. Two ways to extend later:
  (a) named graph fields beyond `graphParents`/`graphChildren`; (b)
  multiple edge files distinguished by a `relationKind` column. Defer
  until the single-family case is in production.
- **Composite primary keys at the engine level.** Edge keys currently
  encode two names into one string with `__`. A true composite PK would be
  more elegant but is a much larger engine change. The `__`-encoding gets
  us the practical benefit at near-zero engine cost.
- **Index-based positional editing of `graphParents`/`graphChildren`
  lists from mods.** Mod-overrides Phase 4 covers list mutations
  (`append_<col>`, `remove_<col>`, `replace_<col>` with value-based
  matching). Positional editing within these lists is tier-C territory.
- **Graph traversal helpers** (BFS, DFS, ancestor/descendant queries,
  shortest path). Out of scope for the *type system* — these belong in a
  separate `graph_query` library if/when a real consumer appears.
- **Heterogeneous edge types within a single edge file.** All rows in an
  edge file share the file's record type. Mixing edge kinds requires
  union types on edge columns, no special engine support.

## Open questions

1. **Disconnected forests in `tree_node`.** A `tree_node` file with two
   roots is currently a validation error. Some authoring workflows
   construct a forest first and connect it later. Two options:
   (a) keep "exactly one root" strict;
   (b) add a `treeShape:tree|forest` Files.tsv column (default `tree`).
   Lean (a) for v1 — multi-root cases can use `graph_node`. Revisit if a
   real use case appears.
   Response: I don't even see a use for this. No support planed.

2. **Edge ordering within `graphParents`/`graphChildren` lists.** Should
   completion preserve authored order on the authored side and just append
   on the derived side? Or sort everything canonically?
   Lean: preserve authored order on the authored side; append in
   discovery order on the derived side; document that ordering is
   significant only for the authored side. Authors who care about
   canonical ordering can run a follow-up pre-processor.
   Response: I can imagine cases where the ordering matters. And in those case,
   the responsibility of the ordering is on the author. If they want entire
   control on the ordering, they then have to "fill-in" all links themselves.
   If we fill in gaps ourselves, just append at the end; do not change
   the existing order.

3. **`isRoot` on `basic_graph_node`.** Roots aren't meaningful for
   undirected graphs, so the helper would just error. Alternative:
   `isIsolated(row)` (no neighbours) — meaningful for all three families.
   Decision deferred to helper-implementation time.
   Response: isRoot() can error for undirected graphs.

4. **Performance for large graphs.** Completion is O(E) where E = total
   edge mentions across all rows. Cycle detection is O(V + E). For
   reasonable game-data sizes (thousands of nodes) this is well below the
   pre-processor and file-validator quotas. For larger graphs, raise the
   quotas at the call site rather than restructure the algorithm.
   Response: We are managing data that should be represented as visual
   / audio game assets. If we are overloaded managing this data,
   the game itself will never even boot, when loading the assets,
   so I will assume this is not a problem.

5. **Reformatter output for back-references.** Per pre-processors.md
   §"Round-trip", processor-mutated values are not written back to disk.
   This means `graphChildren` declared by the author stays in the file,
   but `graphParents` inferred by completion is *not* written to its
   target rows on reformat — even if the author had also declared some
   parents on those rows, the inferred *additions* don't persist. Author
   contract: "write each edge on one side only; the other side is
   computed". Document this prominently — it's the most likely source of
   user surprise.
   Response: Agreed. We leave as is, but warn authors about this.

These should be resolved during implementation, not as blockers.
