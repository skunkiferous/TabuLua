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
record-type aliases:

```text
basic_graph_node = {graphLinks:{node_name}|nil, name:node_name}
graph_node       = {graphChildren:{node_name}|nil, graphParents:{node_name}|nil, name:node_name}
tree_node        = {extends:graph_node, name:node_name}
```

`tree_node`'s `extends`-with-same-field form parses successfully (per
[parsers/type_parsing.lua:540-560](../parsers/type_parsing.lua#L540-L560)
same-type redeclaration is compatible), but the engine canonicalises it
to **the same parser as `graph_node`**. The two aliases are
interchangeable at the parser layer. **Family distinction lives entirely
in `Files.tsv` via the literal `superType=` string**: auto-wiring inspects
the user-written `superType` (`basic_graph_node` / `graph_node` /
`tree_node`) and attaches the matching validator set on that basis, not
by walking the type chain. This is the same lookup style already used by
`enum` and `custom_type_def`.

Authors who want a structurally identical but truly distinct *parser*
type (e.g. to gate a custom record validator) must add a real
distinguishing field — same-type redeclaration alone won't do it. This is
out of scope for v1; revisit if real demand appears.

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
basic_graph_edge = {comment:comment|nil, name:undirected_edge_key}
graph_edge       = {comment:comment|nil, name:directed_edge_key}
tree_edge        = {extends:graph_edge, name:directed_edge_key}
```

The `name` column **is** the compound edge key — single-column primary key,
no schema change to TabuLua's PK model.

The `comment` field is engine-owned and serves two purposes:

1. **Forces record interpretation.** Per
   [parsers/lpeg_parser.lua:96-106](../parsers/lpeg_parser.lua#L96-L106),
   a `{key:val}` spec with a single pair parses as a *map* type, not a
   single-field record. A second field is therefore required to land in
   the record branch. `comment:comment|nil` is the cheapest such field
   that also has user-facing value.
2. **Free-text description column.** Edge files routinely want a place
   to note "what this edge means" — `comment` gives every edge file one
   out of the box without authors having to declare it themselves.

Like `tree_node`, `tree_edge` aliases to the same canonical parser as
`graph_edge`. The tree-vs-DAG distinction lives in `Files.tsv superType`,
not at the parser layer.

Authors extending an edge type add their own columns (`weight:float|nil`,
`kind:EdgeKind|nil`, etc.) using existing record-inheritance syntax. The
`comment` column flows through inheritance automatically.

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

### Helpers (`graph_helpers` module)

A new `graph_helpers` module groups every graph-shaped utility — the small
accessors, the edge-key codec, the cycle-detection helper used by the
validators, and the traversal helpers. Keeping them in a dedicated module
(rather than folding them into a generic `processor_helpers`) keeps the
graph surface area cohesive and avoids loading graph code on behalf of
rows that have nothing to do with graphs.

**Accessors and edge-key codec:**

| Helper | Applies to | Returns |
|---|---|---|
| `isRoot(row)` | `graph_node`, `tree_node` | `true` iff `#graphParents == 0`. Errors on `basic_graph_node`. |
| `isLeaf(row)` | `graph_node`, `tree_node` | `true` iff `#graphChildren == 0`. Errors on `basic_graph_node`. |
| `parentsOf(row)` | `graph_node`, `tree_node` | `graphParents` as a list (never nil) |
| `childrenOf(row)` | `graph_node`, `tree_node` | `graphChildren` as a list (never nil) |
| `neighboursOf(row)` | `basic_graph_node` | `graphLinks` as a list (never nil) |
| `splitEdgeKey(key)` | edge rows | `(a, b)` — the two endpoint names |
| `makeEdgeKey(a, b)` | directed | `"a__b"` |
| `makeUndirectedEdgeKey(a, b)` | undirected | `"<lower>__<higher>"` (canonical) |
| `edgeForLink(edgeRows, a, b)` | both edge kinds | the edge row whose endpoints are `{a,b}`, or `nil` |

**Traversal:**

| Helper | Applies to | Returns |
|---|---|---|
| `bfs(row, direction?)` | all three | Iterator yielding rows in BFS order starting at (and including) `row`. `direction` defaults to the natural direction — `graphLinks` for basic, `graphChildren` for directed. On directed families, pass `"parents"` to walk against the arrows. `"parents"` errors on `basic_graph_node`. |
| `dfs(row, direction?)` | all three | Same contract as `bfs`, depth-first. |
| `ancestorsOf(row)` | `graph_node`, `tree_node` | List of every node reachable by following `graphParents` from `row` (excluding `row` itself). Errors on `basic_graph_node`. |
| `descendantsOf(row)` | `graph_node`, `tree_node` | List of every node reachable by following `graphChildren` from `row` (excluding `row` itself). Errors on `basic_graph_node`. |
| `shortestPath(a, b)` | all three | List of rows forming an unweighted shortest path from `a` to `b` inclusive, or `nil` if disconnected. For directed families, follows `graphChildren`. |

When a helper is applied to a family it doesn't support (e.g. `ancestorsOf`
on a `basic_graph_node` row), the helper errors with a message naming both
the helper and the row's type — matching the decision on `isRoot` in
Open Question 3. Silent fallback would mask schema-mismatch bugs in
processor and validator expressions.

The accessors and edge-key codec are convenience wrappers — none does work
that can't be expressed inline. Their value is making validator and
processor expressions read declaratively. The traversal helpers do real
work and consolidate it in one tested place; without them, every consumer
would re-implement BFS/DFS over the engine's row/lookup model.

All traversal helpers carry a visited-set guard so they remain safe to call
on `basic_graph_node` data, which permits cycles by design.

### Auto-wiring via `superType` chain

Family detection matches on the **literal `superType=` string** the author
wrote in `Files.tsv` (one of `basic_graph_node` / `graph_node` /
`tree_node`, possibly via an intermediate user alias that resolves
transitively). It does **not** rely on parser-type identity, because
`tree_node` and `graph_node` alias to the same canonical parser — they
are indistinguishable at the parser layer.

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

`graph_helpers` exposes a shared cycle-detection helper used by both the
cycle validator and the single-root tree validator:

```text
findCycle(rows, parentField) → nil | path-array
```

Standard DFS with grey/black colouring; returns the first cycle path
found (for the error message) or `nil` if acyclic. Reuses TabuLua's
existing `lookup` helper internally.

## Implementation Plan

### Layer A — single-package graphs (depends only on pre-processors)

Each phase here is independently shippable.

**Phase A1 — Type registration** ✅ *Done.*

- `parsers/builtin.lua`: register `node_name`, `undirected_edge_key`,
  `directed_edge_key`, `basic_graph_node`, `graph_node`, `tree_node`,
  `basic_graph_edge`, `graph_edge`, `tree_edge`.
- For `node_name`: extend the existing `name` parser with the `__`
  rejection rule.
- For the edge-key types: write parser functions in `parsers/builtin.lua`
  that split / validate / (re)order / reassemble.
- Tests: `spec/parsers_graph_types_spec.lua` covering all parser paths
  including the edge cases enumerated above.

Landed adjustments (from Open Questions 6 & 7):

- Edge types include `comment:comment|nil` (single-field `{key:val}`
  parses as a map, so a second field is required).
- `tree_node` / `tree_edge` alias to their parent parsers. Family
  distinction is keyed off `Files.tsv superType` strings, not parser
  identity.

**Phase A2 — `graph_helpers` module** ✅ *Done.*

- Create the new `graph_helpers` module with the accessors, edge-key codec,
  cycle-detection helper, and traversal helpers enumerated above:
  `isRoot`, `isLeaf`, `parentsOf`, `childrenOf`, `neighboursOf`,
  `splitEdgeKey`, `makeEdgeKey`, `makeUndirectedEdgeKey`, `edgeForLink`,
  `findCycle`, `bfs`, `dfs`, `ancestorsOf`, `descendantsOf`, `shortestPath`.
- Helpers are pure-functional, no engine state. Traversal helpers reuse the
  row-lookup mechanism already used by validators, and carry a visited-set
  guard so they stay safe on cyclic basic graphs.
- Family-mismatch errors are raised at call time with a message naming both
  the helper and the row's type.
- Tests: `spec/graph_helpers_spec.lua`, covering every helper against
  fixtures for each of the three families, including cycle-safety for
  basic-graph traversal and the family-mismatch error paths.

Landed adjustments:

- Traversal helpers take `rows` explicitly: `bfs(row, rows, direction?)`,
  `dfs(row, rows, direction?)`, `ancestorsOf(row, rows)`,
  `descendantsOf(row, rows)`, `shortestPath(a, b, rows)`. The row wrappers
  don't expose a back-reference to the file's rows, and adding one is
  out of scope here; passing `rows` explicitly mirrors the existing
  `lookup(rows, ...)` convention in `validator_helpers`.
- Family-mismatch detection is **best-effort** rather than schema-aware:
  helpers check for the *presence* of the wrong-family field
  (e.g. `isRoot` errors when `row.graphLinks ~= nil`) but cannot detect
  family on a row whose engine-owned fields are all nil. The common
  misuse case (calling a directed helper on populated undirected data)
  is caught; ambiguous isolated rows fall through. Tightening this
  needs schema-aware row wrappers — out of scope for Phase A2.

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
- `MODULES.md`: add a module-detail entry for the new `graph_helpers`
  module; if `graph_wiring` is a separate module, add an entry for that too.
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
- **Weighted-edge graph queries** (Dijkstra, A*, max-flow, etc.). The
  built-in `shortestPath` is unweighted; consumers that need weighted
  traversal can read `weight` (or any other column) off the attached edge
  file and run their own algorithm. Folding this into `graph_helpers`
  would require taking a dependency on the edge-file schema.
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

6. **`tree_node` / `tree_edge` parser identity.** *(Closed during Phase A1.)*
   The plan originally claimed `{extends:X, name:Y}` with same-typed `Y`
   produces a distinct sub-type. The engine canonicalises this to the
   same parser as the parent, so `tree_node` ≡ `graph_node` and
   `tree_edge` ≡ `graph_edge` at the parser layer. Decision: keep the
   aliases as authored, but make auto-wiring key off the literal
   `superType=` string in `Files.tsv`. See "Auto-wiring via `superType`
   chain" above.

7. **Single-field record syntax.** *(Closed during Phase A1.)* A `{key:val}`
   spec with exactly one pair parses as a *map*, not a single-field
   record (per
   [parsers/lpeg_parser.lua:96-106](../parsers/lpeg_parser.lua#L96-L106)).
   The edge types therefore include a `comment:comment|nil` column to
   land in the record branch. Doubles as a free description column for
   every edge file.

These should be resolved during implementation, not as blockers.
