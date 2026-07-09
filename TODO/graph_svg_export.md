# SVG Rendering of Graph Files (`--file=svg`)

## Summary

Add a new **export target that draws a graph** — the graph-family data files
(`basic_graph_node` / `graph_node` / `tree_node`, see
[graph_types.md](graph_types.md)) — as a self-contained **SVG** diagram, one
picture per node file. Invoked as `lua reformatter.lua --file=svg <dirs...>`;
it emits an `.svg` for every graph file it finds and skips everything else.

Layout is a **layered (Sugiyama-style) drawing** with the number of
edge crossings reduced by the standard **median / barycenter heuristic**. No
new dependency: an SVG is just text, produced by string building in pure Lua,
exactly like the existing XML export.

## Prerequisites

**None — everything this needs has already landed.**

- [graph_types.md](graph_types.md) (all phases done) gives us the three node
  families, family detection (`graph_wiring.detectRole(typeName, extends)`),
  the accessors (`graph_helpers.childrenOf` / `parentsOf` / `neighboursOf`),
  and the completion pre-processor that fills the inverse relation, so by the
  time a file reaches the exporter both sides of every link are populated.
- The [content_pipeline.md](content_pipeline.md) sink driver already routes
  export through [exporter.lua](../serde/exporter.lua); `joinMeta` now carries
  `lcFn2Type` and `extends` (graph_types Phase A5), so the exporter can resolve
  each file's type lineage — which is all family detection needs.
- The [reformatter.lua](../reformatter.lua) `FILE_FORMATS` table is a
  self-described registry ("to add a new format, simply extend this
  configuration"), so a new `svg` entry needs no dispatch plumbing.

## Motivation

Graph data is the one data shape a wide table is *worst* at communicating. A
`SkillTree.tsv` with `graphParents={"perception","stealth"}` cells is correct
and round-trips cleanly, but no author can eyeball it and see the shape of the
tree, spot an accidental extra root, or notice that two subtrees cross in a way
that will confuse a UI built from the data. A rendered picture turns "is this
graph shaped the way I think?" from a manual trace into a glance.

TabuLua already generates *derived text* at export time (COG-expanded Markdown
docs, [cog_markdown.md](cog_markdown.md)); a rendered diagram is the same idea
for a shape that text serves poorly. SVG is the right target: vector (crisp at
any zoom), text (diffable, deterministic, no binary blob), openable in any
browser, and embeddable straight into the generated Markdown docs.

Crossing minimization matters because a layered graph with many crossings is
nearly as unreadable as the raw table. Getting crossings *low* (not provably
minimal — that is NP-hard) with the well-worn barycenter heuristic is the
difference between a useful picture and a hairball.

## Design

### What gets drawn, and when

`--file=svg` is a normal export format in every mechanical sense (subdir
`exported/svg/`, mirrors source layout), with one behavioural difference: it
is **selective**. `exportSVG` walks the processed files and, for each one,
asks `graph_wiring.detectRole(typeName, extends)`:

- `nil` (not a graph family) → **skip**, log at `info` ("no graph to draw").
- `{family="basic"}` → draw as an undirected graph.
- `{family="directed", tree=…}` → draw as a DAG / tree (arrows, layered).

Edge files (`basic_graph_edge` / `graph_edge` / `tree_edge`) are **not** drawn
on their own — they carry no nodes. Instead, if a node file has an attached
edge file (`edgesFor`, resolved from `joinMeta.lcFn2EdgesFor`), its rows are
used to **annotate** the drawn edges (Phase 5). A run that finds no graph
files writes nothing and says so — not an error.

### No new dependency

An SVG document is UTF-8 XML text. We build it with `table.concat` over a list
of element strings, the same technique [exporter.lua](../serde/exporter.lua)
`exportXML` already uses. Fonts are the generic `sans-serif` family (never
embedded, never fetched). Nothing binary, nothing external. This keeps the SVG
export in the same "pure text, fully deterministic" bucket as every other
export and sidesteps a native or vendored graphing library entirely.

### Two new modules, split by concern

| Module | Responsibility | Home |
|---|---|---|
| `graph_layout` | Family-agnostic **layout**: nodes + adjacency → `{x,y}` per node + a crossing count. Pure, no SVG, no engine state. | `wiring/graph_layout.lua` (beside `graph_helpers`) |
| `svg_render` | **Rendering**: a laid-out graph → an SVG string. Knows nothing about graph families or the engine. | `serde/svg_render.lua` (beside `exporter`) |

`exporter.exportSVG` is the thin glue: detect family → build the adjacency
from `graph_helpers` accessors → `graph_layout.layout(...)` →
`svg_render.render(...)` → write `<name>.svg`. Splitting layout from rendering
means the layout engine is unit-testable on pure numbers (no XML parsing in
tests) and could later feed a different renderer (Graphviz `.dot`, an HTML
canvas, a PNG) without being rewritten.

### The layered layout engine (`graph_layout`)

One engine serves all three families; the family only decides how the input
adjacency is built and whether edges get arrowheads. The engine takes a
**directed** adjacency (for undirected input we orient edges by BFS discovery,
below) and runs the classic four-stage Sugiyama pipeline:

1. **Layer assignment (ranking).** Longest-path layering: every root
   (in-degree 0) is at layer 0; each node's layer is `1 + max(layer of
   parents)`. Deterministic and O(V+E). Produces the vertical bands.

2. **Virtual (dummy) nodes for long edges.** An edge spanning more than one
   layer (`A` at layer 0 → `C` at layer 2) is split with a chain of dummy
   nodes, one per intermediate layer. This is standard Sugiyama: it lets the
   crossing-reduction and routing steps treat every edge as connecting
   *adjacent* layers, and lets long edges bend around nodes instead of
   slicing through them.

3. **Crossing reduction (the crossing-minimization step).** Order the nodes
   *within* each layer to reduce crossings between adjacent layers, using the
   **median heuristic** (Eades–Wormald / the method in Graphviz's `dot`):
   - Sweep down (layer 0 → last), setting each node's position to the median
     of its already-placed upstream neighbours' positions; sweep up doing the
     same with downstream neighbours; repeat for a fixed number of passes
     (default 8, `exportParams.svgSweeps`).
   - Count crossings between each adjacent layer pair after each full sweep
     (the standard O(E·log) accumulator over the two-layer ordering). **Keep
     the ordering with the fewest total crossings seen across all sweeps** —
     the heuristic is not monotone, so the last sweep is not always the best.
   - **Determinism:** every tie (equal medians, a node with no neighbours on
     the reference side) breaks by the node's **primary-key name**, never by
     table/hash order. This is the same determinism discipline as
     [package_order_determinism.md](package_order_determinism.md): identical
     input data must produce a byte-identical SVG on every run and platform.

4. **Coordinate assignment.** `y = layer · verticalSpacing`; `x = position ·
   horizontalSpacing`, with a light centering pass so each node sits near the
   average x of its neighbours (improves straightness without a full
   quadratic-program solver). Integer coordinates only — no floats — so the
   output is bit-stable and diffs cleanly. Dummy nodes contribute bend points
   for their edge's polyline and are then discarded.

The engine returns `{ nodes = {name → {x,y,layer}}, edges = {{from,to,
points}}, width, height, crossings }`. `crossings` is surfaced (log line + an
SVG `<!-- crossings: N -->` comment) so a human — or a test — can see the
heuristic's result without re-deriving it.

**Honesty about "minimized".** Exact crossing minimization is NP-hard even for
two layers. The plan targets *low* crossings via the median heuristic with
multiple sweeps and best-of retention — the same practical bar Graphviz sets —
not a provable optimum. The design deliberately keeps the door open (return
value carries the count; sweeps are a knob) so the heuristic can be tuned or
swapped without touching the renderer or exporter.

### Undirected graphs (`basic_graph_node`)

An undirected graph has no inherent layering. Rather than bolt on a separate
force-directed engine (floating-point, harder to make bit-deterministic across
platforms), we **synthesize a layering** and reuse the one engine:

- Pick the **deterministic start node** = lexicographically smallest node
  name. BFS from it; a node's layer is its BFS distance. Orient each tree edge
  parent→child for the engine's benefit; non-tree ("back"/"cross") edges are
  kept as undirected polylines drawn without arrowheads.
- **Disconnected components:** when BFS exhausts, restart from the smallest
  unvisited name, stacking the next component below the previous one. Order of
  components is by their smallest member name — deterministic.

Force-directed layout is noted as a possible future alternative (Open
Question 2), but layered-BFS gives a clean, deterministic, dependency-free
first version that shares all the crossing-reduction machinery.

### The renderer (`svg_render`)

Given the laid-out graph, emit one self-contained `<svg>`:

- **Canvas.** `viewBox="0 0 width height"` sized to the content plus a margin;
  `width`/`height` in px so it renders standalone. Wide graphs simply produce a
  wide viewBox — the consumer scrolls/zooms.
- **Nodes.** A rounded `<rect>` sized to the label, with the `name` centered in
  a `<text>`. Optional role tinting: roots and leaves get a distinct fill for
  directed families (computed from `graph_helpers.isRoot`/`isLeaf`), so the
  entry and terminal points of a DAG pop out. Colours come from a small
  built-in palette chosen to read on both light and dark backgrounds.
- **Edges.** A `<polyline>`/`<path>` through the node centres and any dummy-node
  bend points. Directed families get an arrowhead via a single reusable
  `<marker>` defined once in `<defs>`. Undirected edges: no marker.
- **Self-contained & deterministic.** No external stylesheet, no web font, no
  script; element order is fully determined by the (already deterministic)
  layout. Byte-identical across runs.

### Integration into the format registry

Add to `FILE_FORMATS` in [reformatter.lua:129](../reformatter.lua#L129):

```lua
["svg"] = {
    extension = ".svg",
    description = "SVG diagram of graph-family files (skips non-graph files)",
    validData = {"svg"},
    defaultData = "svg",
    getExporter = function() return exporter.exportSVG end,
},
```

and a matching `["svg"]` entry in `DATA_FORMATS` (a passthrough — SVG has no
cell-serialization axis; the entry exists only so `--data` validation and the
`svg-svg` subdir naming stay uniform with every other format). `exportSVG` is
registered in the exporter's public `API` table alongside `exportXML` et al.

Optional `exportParams` knobs (all with sensible defaults, all plumbed the
same way `exportExploded` already is): `svgSweeps`, `svgNodeSpacing`,
`svgLayerSpacing`, `svgLabelEdges`, `svgColorScheme`. v1 can ship
defaults-only and add CLI flags later.

## Implementation Plan

Each phase is independently shippable and **committed separately** (the user
does all commits), matching the workflow used by the graph and mod-override
plans.

Ideally, the public API of the new modules would allow using them to generate
SVGs from "other sources" than just graph-data TSV files. For example, if we
decided to generate a SVG graph showing the relation of all files and packages.

**Phase 1 — `graph_layout` engine.**
- New `wiring/graph_layout.lua`: `layout(nodes, adjacency, opts)` →
  `{nodes, edges, width, height, crossings}`. Implements ranking, dummy-node
  insertion, median-heuristic crossing reduction with best-of retention, and
  integer coordinate assignment. Pure, deterministic, PK-name tie-breaks.
- Tests: `spec/graph_layout_spec.lua` — a hand-checked small DAG (assert exact
  layers and a known crossing count), a chain, a diamond, a wide fan, a
  multi-root DAG, and a determinism test (two runs → identical output).

**Phase 2 — `svg_render` renderer.**
- New `serde/svg_render.lua`: `render(laidOut, opts)` → SVG string. Nodes,
  edges, arrowhead marker, role tinting, viewBox, crossings comment.
- Tests: `spec/svg_render_spec.lua` — structural assertions (one `<rect>` per
  node, one edge element per edge, arrowhead marker present for directed and
  absent for undirected, `viewBox` matches reported size) plus a byte-stability
  (golden-string) test. No XML library needed — assert on substrings/counts.

**Phase 3 — wire into exporter + reformatter (directed families).**
- `exporter.exportSVG(process_files, exportParams)`: iterate files, detect via
  `graph_wiring.detectRole`, skip non-graph (log), build directed adjacency
  from `graph_helpers.childrenOf`, lay out, render, write
  `exported/svg/<relative>.svg`. Register in the exporter `API`.
- Add the `svg` entries to `FILE_FORMATS` / `DATA_FORMATS`; extend the usage
  help and the examples block in `generateUsage`.
- Integration test: `--file=svg` over the tutorial (`tutorial/expansion/
  SkillTree.tsv` is a real `graph_node` file from graph_types Phase A6)
  produces exactly one `.svg`, with a node per skill and an edge per parent
  link, and skips the non-graph tutorial files.

**Phase 4 — undirected support (`basic_graph_node`).**
- Deterministic BFS-layering + disconnected-component stacking in `exportSVG`
  (or a small helper in `graph_layout`); undirected edges rendered without
  arrowheads.
- Tests: a `basic_graph_node` fixture (including a disconnected component and a
  cycle — legal for basic graphs) lays out and renders deterministically.

**Phase 5 (optional) — edge-file annotations & styling knobs.**
- When a drawn node file has an `edgesFor` edge file, label each edge with a
  chosen column (default: the first non-`comment` scalar column, e.g.
  `requiredLevel` on the tutorial's `SkillEdges.tsv`), via
  `graph_helpers.edgeForLink`.
- Wire the `svg*` `exportParams` knobs to real CLI flags.

**Phase 6 — documentation.**
- `DATA_FORMAT_README.md`: an "SVG diagram export" note under the export
  formats, explaining selectivity and the crossing-reduction caveat.
- `MODULES.md`: detail entries for `graph_layout` and `svg_render`.
- `CHANGELOG.md`: `### Added` bullet under `[Unreleased]`.
- `README.md`: a "Features" bullet.
- `reformatter` usage help already updated in Phase 3.
- Nice-to-have: have the tutorial's COG doc template embed the generated
  `SkillTree.svg` inline, demonstrating the diagram-in-docs story
  ([cog_markdown.md](cog_markdown.md)).

## Out of scope (deferred)

- **PNG / other raster output.** SVG only. A raster needs a rasterizer (native
  dep or a heavy pure-Lua renderer) — out of the "text, no dependency" bucket.
  Consumers who need PNG can convert the SVG with their own tooling.
- **Force-directed / spring layout.** Layered-BFS covers undirected graphs
  deterministically for v1 (see Open Question 2).
- **Interactive SVG** (hover, collapse, JS behaviour). The export is a static,
  script-free document by design (self-contained, diffable).
- **Provably-minimal crossings.** NP-hard; the median heuristic is the
  practical target (see Design "Honesty about minimized").
- **Cross-package merged graphs as a single picture.** v1 draws each node file
  as it exists in the merged model; whether to also draw one combined diagram
  spanning multiple packages is a later question.
- **Multi-relation graphs** (a node file participating in several edge
  families) — blocked on the same multi-graph extension already deferred in
  [graph_types.md](graph_types.md) "Out of scope".
- **Per-file diagram customization via `Files.tsv`.** v1 exposes appearance
  only as run-wide `exportParams` knobs (`svgColorScheme`, `svgLayerSpacing`,
  …). A later iteration could let each author store per-file rendering
  preferences — colour scheme, spacing, orientation, which edge column to
  label with, whether to draw at all — as **new `Files.tsv` descriptor
  columns** registered by the SVG feature module through the type-wiring
  registry (`registerModule(..., {descriptorColumns=…})`), exactly as graphs
  added `edgesFor`. Those columns would flow through `joinMeta` and override
  the run-wide defaults per file. This is deferred because it commits us to a
  customization vocabulary (which knobs are worth persisting) that is best
  designed against real usage once the defaults-only version has been lived
  with — and because it needs zero core edits when we do it, so nothing is
  lost by waiting.

## Open questions

1. **Selective export vs. explicit target.** `--file=svg` silently skipping
   every non-graph file is unusual for an export format (all others emit one
   output per input). Alternative: require the user to name graph files, or
   emit a small "no graph here" placeholder. *Lean: skip silently (with an
   `info` log) and print a summary count at the end — a graph-only picture of a
   non-graph file is meaningless, and the whole-directory invocation is the
   natural one.*

2. **Undirected layout: layered-BFS vs. force-directed.** Layered-BFS is
   deterministic and reuses the engine but can look arbitrary for dense peer
   graphs (friendship networks). Force-directed reads better for those but
   needs deterministic seeding and integer-quantized output to stay
   bit-stable. *Lean: ship layered-BFS in v1; revisit force-directed if a
   real dense-undirected dataset looks bad.*

3. **How much layout polish is worth it.** The plan stops at the median
   heuristic + light centering. Full Sugiyama adds Brandes–Köpf coordinate
   assignment (straighter edges) and iterated crossing minimization. *Lean:
   ship the heuristic; the return-value crossing count tells us whether more is
   warranted on real data.*

4. **Node label overflow.** Long PK names make wide boxes and wide canvases.
   Truncate with an ellipsis + `<title>` tooltip, wrap, or just let the canvas
   grow? *Lean: let it grow for v1 (SVG scrolls/zooms); add truncation as a
   knob if needed.*

5. **Default edge annotation column (Phase 5).** Auto-pick the first scalar
   edge column, or require the author to name it via an `exportParams` /
   `Files.tsv` hint? *Lean: auto-pick first non-`comment` scalar, overridable
   by a knob.*

These should be resolved during implementation, not treated as blockers.
