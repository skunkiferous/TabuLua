# Type-Wiring Registry: Generalising Auto-Wired Behaviour

## Status

Refactor. [graph_types.md](graph_types.md) Layer A has landed (commits
`d5df0ad`…`8c41bda`, ending at v0.20.0). The implementation of that auto-wiring
in [graph_wiring.lua](../graph_wiring.lua) surfaced several specific *needs*
that this plan, as originally drafted, did not anticipate. See
"Lessons from the graph wiring implementation" below; the Design section has
been revised to address each of them so a single registry can cover the
existing three behaviours (`Type` / `enum` / `custom_type_def`) **and** the
landed graph wiring without losing capability.

**Phases 1, 2a, 2b, 3a, 3b: landed.** The registry module
([type_wiring.lua](../type_wiring.lua)) and the built-in seed module
([builtin_wiring.lua](../builtin_wiring.lua)) now host the full per-typeName
cascade (`onLoad`, `preProcessors`, `rowValidators`, `fileValidators`
with per-entry `position` override and expression-string idempotency)
and the module-level `registerModule` API (`descriptorColumns`,
`sandboxHelpers`, `enginePostPasses`). `manifest_loader` calls
`type_wiring.applyWiring` once per file (replaces the three `onLoad`
branches AND the post-load graph auto-wiring pass) and
`type_wiring.runEnginePostPasses` once after the per-file validator
phase (replaces the direct `validateGraphEdgeFiles` call).
`processor_executor` and `validator_executor` merge
`type_wiring.sandboxAdditions()` into their helper blocks at engine init.
`files_desc.lua`'s core hard-coded schema is now six columns
(`fileName`, `typeName`, `superType`, `baseType`, `loadOrder`,
`description`); the other ten optional columns flow in through
feature-module `registerModule` calls. `graph_wiring.applyAutoWiring`
and `graph_wiring.validateEdgeFiles` are gone from the public API; the
leaf detection helpers (`detectFamily`, `detectRole`,
`detectEdgeFamily`) remain.

User packages now reach the registry through two paths:

- **3a — code library path.** `type_wiring.makeBootstrapAPI()` returns
  a proxy api + `seal()` closure. The manifest `bootstrap` field
  (`{{library:name, fn:name}}|nil`) drives this path:
  `manifest_info.runPackageBootstraps` invokes each entry in
  package-dependency order, after libraries load and before any
  descriptor file is parsed. `seal()` fires immediately after — the
  api's only legitimate use is inside the bootstrap calls
  themselves, so a captured handle invoked later (e.g. from a
  function called during file loading) errors at the call site.

- **3b — pure-data path via the `type_wiring_def` built-in.** A new
  built-in record type whose fields are `typeName` + the three
  per-typeName spec-list slots. Any file declaring
  `typeName=type_wiring_def` (or extending it) has its rows
  dispatched as `type_wiring.register(...)` calls by the standard
  onLoad cascade — same mechanism used for Type files, enum files,
  and custom_type_def files. Authors name such files however they
  like (convention: `TypeWiring.tsv`); the engine recognises them by
  record type, not by basename. The shared seal of 3a does NOT
  apply here because 3b registrations happen via direct
  `type_wiring.register` calls from inside the onLoad handler — they
  never touch the bootstrap api.

Phases 4 (optional) and 5 remain.

## Summary

Several places in the engine attach behaviour to a file based on whether its
`typeName` transitively extends a specific built-in super-type. Today each one
is a separate `if ...Set[fileType] then ...` branch in
[manifest_loader.lua](../manifest_loader.lua) plus a tiny
`isFoo(typeName, extends)` walker, **or** (since graph_types Layer A) a
typeName→role lookup in [graph_wiring.lua](../graph_wiring.lua). Counting both
styles there are now at least seven such cases (`Type`, `enum`,
`custom_type_def`, `basic_graph_node`, `graph_node`, `tree_node`, and the
[files_desc.lua](../files_desc.lua) `POST_PROCESS_PARENTS` table), plus one
cross-file post-pass (`validateEdgeFiles`) that exists outside the per-file
pipeline entirely.

This document plans a refactor that collapses every "if file extends T, do X"
branch into a single **type-wiring registry**: a small module exposing
`register(typeName, contributions)`, plus one generic dispatch loop that
consults the registry and walks the `extends` chain. Each existing branch
becomes one `register(...)` call; new ones become one more without touching
the dispatcher.

The behaviour change is **zero**. All existing tests must continue to pass.
The motivation is structural: code clarity, room for user packages to
contribute the same kind of wiring without engine modifications, and a single
grep-point for "which behaviours fire on which type".

## Motivation

### What's hard-wired today

| Source | Trigger | Behaviour |
|---|---|---|
| [files_desc.lua:19](../files_desc.lua#L19) | `POST_PROCESS_PARENTS = {Type=true, enum=true}` | Triggers the reprocessing pass that re-detects post-processing-needed files. |
| [manifest_loader.lua:471-479](../manifest_loader.lua#L471-L479) | `enumsSet[fileType]` / `typesSet[fileType]` / `customTypesSet[fileType]` | Three branches calling `registerEnumParser` / `registerAliases` / `registerCustomTypesFromFile` — each is an `onLoad`-style hook that registers parsers/types from a file's contents while subsequent files are still being parsed. |
| [manifest_loader.lua:531-563](../manifest_loader.lua#L531-L563) | Three walkers `isType`, `isEnum`, `isCustomTypeDef` plus `findAllTypes` and `buildCustomTypesSet` | Three near-identical implementations of "is `T` in the ancestor chain of this typeName?" |
| [graph_wiring.lua:40-44](../graph_wiring.lua#L40-L44) (`ROLE_OF`) + [graph_wiring.lua:209-236](../graph_wiring.lua#L209-L236) (`applyAutoWiring`) | A `typeName` whose `extends` chain leads to `basic_graph_node` / `graph_node` / `tree_node` | Prepends a completion `processor_spec` to `lcFn2PreProcessors`, appends `graphRefsExist` / `graphAcyclic` / `graphTreeShape` `validator_spec`s to `lcFn2FileValidators`. The contributions are bundled per role (not decomposed along the extends chain). |
| [graph_wiring.lua:88-100](../graph_wiring.lua#L88-L100) (`detectEdgeFamily`) | Edge files declaring `edgesFor` | Engine-managed cross-file validator [`validateEdgeFiles`](../graph_wiring.lua#L277-L416) invoked from [manifest_loader.lua:1094-1098](../manifest_loader.lua#L1094-L1098), *after* the per-file validator phase. Needs `lcFn2EdgesFor`, `lcFn2Type`, `extends`, and the full `tsv_files` map. |
| [files_desc.lua:66](../files_desc.lua#L66) + [:223](../files_desc.lua#L223) + [:452-457](../files_desc.lua#L452-L457) | `edgesFor:filepath\|nil` column | A Files.tsv column dedicated to graph wiring, plumbed through to `joinMeta.lcFn2EdgesFor` for `validateEdgeFiles` to consume. **(Resolved — see [descriptor_map_lifecycle.md](descriptor_map_lifecycle.md): the map lifecycle is now registry-driven; `edgesFor` is no longer named in either loader module — only declared by `graph_wiring`. `lcFn2EdgesFor` still lands on `joinMeta` automatically via the shared `metaMaps`.)** |
| [processor_executor.lua:378-383](../processor_executor.lua#L378-L383) + [validator_executor.lua:46-48](../validator_executor.lua#L46-L48) | n/a | The five graph helpers (`completeBasicGraph`, `completeDirectedGraph`, `graphRefsExist`, `graphAcyclic`, `graphTreeShape`) are hard-coded into the processor / validator sandbox envs so the auto-wired expressions can resolve them. |

After graph_types Layer A landed:

- 7 special-cased super-types
- 4+ near-identical "is X in the ancestor chain?" walkers
- **Three** separate dispatch points
  ([manifest_loader.lua:471-479](../manifest_loader.lua#L471-L479) for
  `Type` / `enum` / `custom_type_def`;
  [graph_wiring.applyAutoWiring](../graph_wiring.lua#L209-L236) for the
  three graph-node families during `processOrderedFiles`;
  [validateEdgeFiles](../graph_wiring.lua#L277-L416) for the post-pipeline
  edge consistency pass)
- **Five hard-coded sandbox helpers** that the wired expressions depend on
- **One bespoke Files.tsv column** (`edgesFor`) that exists solely so wiring
  has the metadata it needs (the column's *lifecycle* is now registry-driven —
  see [descriptor_map_lifecycle.md](descriptor_map_lifecycle.md))

### What we lose by leaving it

- **Per-feature engine edits.** Each new shape-type (`series_node`,
  `partition_node`, future built-ins) requires another `if`, another walker,
  another set membership in two files.
- **No symmetric story for users.** TabuLua already has good *file-level*
  data-driven configuration: `Files.tsv` columns like `joinInto`,
  `publishContext`, `preProcessors`, `fileValidators`. Type-level inheritance
  of those same fields ("every file whose typeName extends T inherits T's
  preProcessors") is the missing dual. Today only the engine can express it.
- **Diffuse grep-surface.** "Which behaviours fire on which super-type?" is
  answered by reading several modules; after the refactor it's one
  `builtin_wiring.lua` file plus, for user packages, one `TypeWiring.tsv` per
  package.

### What the refactor produces

- 1 registry module
- 1 ancestor-chain walker
- 1 dispatch loop per wiring phase
- N `register(typeName, ...)` calls — one per built-in wired type
- 1 optional `TypeWiring.tsv` per user package, for the contribution kinds
  expressible declaratively

## Lessons from the graph wiring implementation

graph_types Layer A landed without this refactor, so the auto-wiring lives in
its own [`graph_wiring.lua`](../graph_wiring.lua) module. Writing it surfaced
seven specific *needs* that the original Design (below) didn't anticipate.
The Design has been revised to address each of them; this section keeps the
findings in one place so future contributors can see *why* the registry has
the shape it does.

### L1 — Per-kind insertion position matters

Completion pre-processors must run **before** any user-declared pre-processors
(otherwise validators see incomplete back-references); structural validators
must run **after** any user-declared validators (so cheaper, more
authoring-specific errors fire first). The graph wiring expresses this by
**prepending** to `lcFn2PreProcessors` and **appending** to
`lcFn2FileValidators` — see
[graph_wiring.lua:225](../graph_wiring.lua#L225) (`prepend=true`) vs.
[graph_wiring.lua:229](../graph_wiring.lua#L229) (`prepend=false`). The
original plan's "shallowest first, always append" rule is correct for the
validator side but wrong for the processor side.

### L2 — Engine-managed validators run outside the per-file sandbox pipeline

`validateEdgeFiles`
([graph_wiring.lua:277](../graph_wiring.lua#L277)) is a plain Lua function
invoked from [manifest_loader.lua:1094-1098](../manifest_loader.lua#L1094-L1098)
*after* the per-file validator phase. It needs cross-file state
(`tsv_files`, `lcFn2EdgesFor`, `lcFn2Type`, `extends`, `badVal`) that the
sandboxed `validator_spec` form doesn't expose. The original plan's three
contribution kinds (`onLoad` + the two processor/validator-spec arrays)
have no slot for this; a fourth kind is needed.

Crucially, this kind of check doesn't "belong to" any single super-type —
`validateEdgeFiles` cares about the edges↔nodes relation, not about which
of the three graph families a node file uses. So `enginePostPasses` is a
**module-level** concern, not a per-typeName cascade contribution. The
revised Design surfaces this as a separate `registerModule` API; see L4
for the same lens applied to other slots.

### L3 — Wired expressions need their helpers in the sandbox env

The auto-wired expression `"completeBasicGraph(rows)"` only runs because
[processor_executor.lua:378-383](../processor_executor.lua#L378-L383) hard-codes
`completeBasicGraph` into the processor sandbox env, and the same applies to
the three validators in
[validator_executor.lua:46-48](../validator_executor.lua#L46-L48). The original
plan registers an expression *string* but is silent on how the function being
called gets into the env. Without addressing this, a Phase-3 user
`TypeWiring.tsv` row could reference a helper that doesn't exist anywhere.

Same module-level shape as L2: a helper name occupies a single slot in the
sandbox env regardless of typeName, so `sandboxHelpers` belongs to the
owning module, not to any particular super-type in the cascade.

### L4 — The "core" Files.tsv schema is mostly feature accretion

`edgesFor:filepath|nil` is the *latest* example of a much older pattern.
Of the sixteen columns
[files_desc.parseFilesDescHeader](../files_desc.lua#L173) recognises
today, only six are intrinsic to "describe a file":
`fileName`, `typeName`, `superType`, `baseType`, `loadOrder`,
`description`. The other ten — `publishContext`, `publishColumn`,
`joinInto`, `joinColumn`, `export`, `joinedTypeName`, `variant`,
`rowValidators`, `fileValidators`, `preProcessors`, `edgesFor` — each
belong to a specific feature (data publishing, file joining, variants,
validators, pre-processors, graph wiring) and each was added by editing
`files_desc.lua` in three or four places plus widening `joinMeta`.

Every one of these optional columns already has an `Idx == -1` guard:
files without them parse fine. So they aren't *required* core, they
just *live* in core because there hasn't been anywhere else to put them.
The registry should be that "anywhere else". After the refactor, the
hard-coded schema in `files_desc.lua` shrinks to the six intrinsic
columns; the rest are re-introduced by feature modules at engine init
(see "Minimal core Files.tsv schema" in the Design section).

A second consequence: most of these declarations aren't tied to a
*specific* super-type — `joinInto` works for any file type, not just
files extending some hypothetical `Joinable`. So the registration API
for column declarations (and for the other engine-init slots —
`sandboxHelpers`, `enginePostPasses`) shouldn't pretend to be
per-typeName. The original Design conflated two registration
concerns; the revised Design splits them (see L4-derived split under
"The registry").

### L5 — Parser aliases break the "walk extends chain" cascade

`tree_node` is registered as a plain `registerAlias('tree_node', 'graph_node')`
in [parsers/builtin.lua:1008](../parsers/builtin.lua#L1008) — so when a user
writes `superType=tree_node` in Files.tsv, `extends[userType] = "tree_node"`
but `extends["tree_node"]` is **nil** (the relationship to `graph_node`
lives at the parser layer, not the Files.tsv-extends layer). A naive
"walk `extends[t]` upward" dispatcher would stop at `tree_node` and never
inherit `graph_node`'s wiring. `graph_wiring` works around this by
flattening: its `ROLE_OF` table lists each leaf (`tree_node`, `graph_node`,
`basic_graph_node`) with its **full** bundle of contributions —
[graph_wiring.lua:40-44](../graph_wiring.lua#L40-L44) — instead of
decomposing along the chain. The original plan's "shallowest-first
cascade" assumed the extends walk would naturally compose; in practice it
either (a) needs parser aliases to extend the walk, or (b) accepts the
per-leaf flattening graph_wiring uses.

### L6 — Re-applying wiring must be idempotent

[`graph_wiring.appendUnique`](../graph_wiring.lua#L178-L189) +
[`alreadyContainsExpr`](../graph_wiring.lua#L163-L173) make
`applyAutoWiring` a no-op when run on an already-wired map (matched by
expression string). This is important because the mod-overrides pipeline,
hot-reload, and tests can all re-enter the wiring step. The original plan
is silent on idempotency; the registry needs to specify this as a
contract.

### L7 — Contributions carry priority / level / rerun-after-patches metadata

The completion `processor_spec` entries are read-only tables with
`{expr, priority, rerunAfterPatches, level}` —
[graph_wiring.lua:105-117](../graph_wiring.lua#L105-L117). The validator
entries carry `{expr, level}`. The original plan's "contributions table"
lists `processor_spec` and `validator_spec` as types but doesn't spell out
that wired entries must support the same metadata fields user entries do —
in particular `priority` (so the completion processor sorts before user
processors that *aren't* marked `priority<100`) and `rerunAfterPatches`
(so cross-package patches re-run completion).

## Design

### The registry

A new module `type_wiring.lua` exposes two distinct registration APIs —
one per-typeName (cascade dispatch), one module-level (engine-init
declarations). Conflating them was the original Design's mistake; L4
makes the split unavoidable.

```text
-- Per-typeName: cascade contributions, dispatched by walking the
-- file's extends chain at load time.
type_wiring.register(typeName, contributions) → nil

-- Module-level: engine-init declarations that aren't tied to any
-- particular super-type. moduleName is for provenance in error
-- messages and dedup of identical declarations.
type_wiring.registerModule(moduleName, declarations) → nil

-- Per-typeName dispatch / query
type_wiring.applyWiring(fileType, extends, ctx) → nil
type_wiring.hasOnLoad(typeName, extends) → boolean

-- Module-level accessors used by the engine at init / post-pass time
type_wiring.runEnginePostPasses(tsv_files, joinMeta, badVal) → boolean
type_wiring.sandboxAdditions() → { processor = {...}, validator = {...} }
type_wiring.descriptorColumns() → { [colName] = colSpec, ... }

type_wiring.getVersion() → string
```

**Per-typeName contributions** (`register`) — appear when a file's
typeName transitively extends the registered typeName. These flow
through the cascade walk, support `position` overrides, and obey the
idempotency contract.

| Field | Type | Lifecycle phase | Insertion | User TSV? |
|---|---|---|---|---|
| `onLoad` | function `(file, fileType, extends, badVal, loadEnv)` | per-file load loop, before subsequent files parse (Phase 1 of the load pipeline) | n/a — direct call | No — named Lua callback only |
| `preProcessors` | array of `processor_spec` | pre-processor phase (Phase 2) | **prepend** by default (so wiring runs before user processors); per-entry `position` field (`"prepend"` or `"append"`) overrides | Yes |
| `rowValidators` | array of `validator_spec` | row-validator phase (Phase 3) | **append** by default (user errors fire first); per-entry override allowed | Yes |
| `fileValidators` | array of `validator_spec` | file-validator phase (Phase 3) | **append** by default; per-entry override allowed | Yes |

The `processor_spec` / `validator_spec` array elements support the same
metadata user expressions already accept: `{expr, priority?,
rerunAfterPatches?, level?, position?}`. Wiring entries that omit metadata
get the same defaults user entries do. The `position` field is per-entry —
a wiring kind that needs *both* a prepended completion processor and an
appended diagnostic processor lists both in the same `preProcessors` array
with different `position` values.

**Module-level declarations** (`registerModule`) — engine-init
contributions that aren't tied to a particular typeName. A feature
module says "I add this column" / "I add this helper" / "I add this
post-pass" without naming any super-type. This is the slot through
which feature modules re-introduce columns that today live in
`files_desc.lua`'s hard-coded list (L4).

| Field | Type | Lifecycle | Dedup rule | User TSV? |
|---|---|---|---|---|
| `descriptorColumns` | array of `{ name, type, fieldOnMeta, parse?(rowVal)→stored }` declaring extra Files.tsv columns | parsed during `processFilesDesc`, the parsed map ends up at `joinMeta[fieldOnMeta]` | Identical declarations (same name, same type, same `fieldOnMeta`, same `parse` function identity) merge silently; any other re-declaration of the same `name` is a registration-time error naming both contributing modules | No — engine schema extension |
| `sandboxHelpers` | `{ processor = {[name]=fn,…}, validator = {[name]=fn,…}, both = {[name]=fn,…} }` | merged into the processor / validator sandbox envs at engine init, before any expression runs | Identical `(name, function)` pairs merge silently; same name with a different function is a registration-time error | No — merged Lua functions only |
| `enginePostPasses` | array of `function(tsv_files, joinMeta, badVal) → ok` | engine post-pass phase (Phase 4) — runs after every per-file validator, sees fully completed back-references and all cross-file state | Function-identity dedup; ordering is registration order with ties broken by `moduleName` lexicographically for determinism | No — engine-only Lua callback |

Why no `position` on the module-level slots? Because they aren't
mixed into per-file ordered arrays — columns are unordered (each lives
at its own `joinMeta` key), helpers go into an env map (also
unordered), and post-passes have their own registration-order rule.

The Phase 1 / Phase 2 / Phase 3 / Phase 4 phases described earlier
still apply; per-typeName and module-level contributions just feed
into them through different registration APIs.

### Why the lifecycle split

Four phases, not the two the original plan assumed, because *when* the
work has to happen forces them apart:

- **Phase 1 (`onLoad`).** `Type` / `enum` / `custom_type_def` register
  parsers/types. Those registrations must be visible to **subsequent files**
  in the load loop. They can't live in `preProcessors` — pre-processors
  run after all files are parsed.
- **Phase 2 (`preProcessors`).** Graph completion appends to back-reference
  fields. Needs all rows parsed (Phase 1 done) but must run before
  validators (Phase 3 starts).
- **Phase 3 (`rowValidators` / `fileValidators`).** Sandboxed per-file
  expression-based validation. Sees Phase 2 output. This is the existing
  validator pass.
- **Phase 4 (`enginePostPasses`).** Cross-file engine-managed checks that
  need state the sandbox doesn't expose. Graph's `validateEdgeFiles` is
  the canonical example: it walks every edge file's rows, looks up
  corresponding nodes in a different file, and reports mismatches via
  `badVal`. Sandboxing it would mean exposing `tsv_files` and the full
  `joinMeta` to user expressions — a much larger decision than this
  refactor wants to make.

The `onLoad`, `enginePostPasses`, `sandboxHelpers`, and `descriptorColumns`
slots are restricted to in-engine callbacks/declarations because they have
direct access to engine-mutable state (the `parsers` module's registration
API, the full `tsv_files` map, the sandbox env constructor, the Files.tsv
schema). Sandboxing any of them would mean exposing the corresponding
internal API to user expressions — out of scope for this refactor.

### Dispatch

The dispatcher walks the `extends` chain from the file's typeName up to a
built-in root. For each ancestor with a registered wiring, it accumulates
contributions:

```lua
function applyWiring(fileType, extends, ctx)
    local t = fileType
    while t do
        local w = REGISTRY[t:lower()]
        if w then
            if w.onLoad then
                w.onLoad(ctx.file, fileType, extends, ctx.badVal, ctx.loadEnv)
            end
            insertContributions(ctx.preProcessors,  w.preProcessors,
                                "prepend")              -- L1, default for processors
            insertContributions(ctx.rowValidators,  w.rowValidators,  "append")
            insertContributions(ctx.fileValidators, w.fileValidators, "append")
        end
        t = extends[t]
    end
end
```

`insertContributions` handles three concerns at once: the per-kind default
position (L1), the per-entry `position` override, and idempotency (L6) —
an entry whose `expr` already appears in the target array is skipped, so
re-running `applyWiring` on the same `ctx` is a no-op. This matches the
implementation pattern in
[graph_wiring.lua:163-189](../graph_wiring.lua#L163-L189)
(`alreadyContainsExpr` and `appendUnique`).

Order *within* a phase: **shallowest first** — the file's own type
contributes first, then its parent, then its grandparent, … This matches
how multiple `preProcessors` already sort (the file's own declared
processors run before inherited ones). Multiple ancestors contributing
the same field accumulate (no overriding): if `tree_node` and its parent
`graph_node` both contribute validators, both run. Authors can suppress
an unwanted ancestor contribution via the same mod-override mechanism
they would use for any other auto-wired validator
([mod_overrides.md §3](mod_overrides.md), schema overlays).

### Parser-alias dispatch (L5)

`extends[t]` only follows the chain declared in `Files.tsv superType=`
columns and in *user-authored* type aliases. Parser-layer aliases —
declared via `registration.registerAlias(...)` in
[parsers/builtin.lua](../parsers/builtin.lua) — do **not** appear in
that map. The concrete consequence today:
`extends["tree_node"] == nil` even though `tree_node` is registered as
a plain alias of `graph_node` at
[parsers/builtin.lua:1008](../parsers/builtin.lua#L1008).

For wiring purposes this means: when a user writes `superType=tree_node`,
the dispatch walk reaches `"tree_node"` and stops — it does **not**
naturally fall through to `"graph_node"`'s registered contributions.

Two ways the registry can handle this; pick **(a)** as the default.

- **(a) Per-leaf flattening.** Each parser-aliased leaf registers its
  *full* contribution bundle. This is what `graph_wiring` does today
  with its three-row `ROLE_OF` table. Pros: zero new machinery, dispatch
  rule stays "walk `extends` upward". Cons: duplication if many leaves
  share a common bundle.
- **(b) Parser-alias-aware walk.** The dispatcher consults a second
  map (built from `parsers.registration` introspection) so that after
  exhausting `extends`, it also walks any parser-alias chain. Pros: a
  single `register("graph_node", {...})` would cover both `graph_node`
  and `tree_node`. Cons: needs read access to the parsers module's
  alias registry (a small surface-area decision); creates a third
  composition rule on top of `extends` + tags.

Phase 2 (migrating the graph wiring) ships with (a) — the existing
`ROLE_OF` shape carries over to three `register(...)` calls verbatim,
no new walk semantics needed. (b) is recorded as a future option;
revisit if a second registerAlias-style family appears.

### Idempotency contract (L6)

`applyWiring` and `runEnginePostPasses` must be **safe to invoke more
than once** against the same map / state. Both the mod-overrides
pipeline (which re-runs wiring after row patches) and the existing
hot-reload paths in tests can re-enter. Two rules:

- For `preProcessors` / `rowValidators` / `fileValidators`: a wired
  entry whose `expr` already appears in the target array is **not
  inserted again** (matched by string equality on `expr`, mirroring
  [graph_wiring.alreadyContainsExpr](../graph_wiring.lua#L163-L173)).
- For `onLoad` and `enginePostPasses`: the **wiring dispatcher** does
  not enforce idempotency at the function level (it can't compare
  closures); each callback is responsible for its own re-entry safety.
  This matches today's `registerAliases` etc., which already check
  for duplicate registrations internally.

### Tag-keyed wiring

A registry entry can match by **type-tag membership**, not only by `extends`
ancestry. TabuLua's tag system already exposes the required introspection at
[parsers/introspection.lua:557-572](../parsers/introspection.lua#L557-L572)
(`isMemberOfTag(tagName, typeName)` — handles direct membership, subtype
membership, and transitive tag membership), and tags share a single namespace
with types by design
([parsers/registration.lua:79-82](../parsers/registration.lua#L79-L82)), so
the registry's `REGISTRY[name]` lookup table holds both kinds of entries
without collision.

The dispatcher gains a second pass:

```lua
function applyWiring(fileType, extends, ctx)
    -- Pass 1: ancestor chain (unchanged)
    local t = fileType
    while t do
        applyEntry(REGISTRY[t:lower()], ctx)
        t = extends[t]
    end
    -- Pass 2: tag membership
    for tagName, _ in pairs(state.TAG_MEMBERS) do
        if isMemberOfTag(tagName, fileType) then
            applyEntry(REGISTRY[tagName:lower()], ctx)
        end
    end
end
```

**Why both passes?** Ancestry expresses "a `tree_node` *is a* `graph_node`,
and inherits its wiring". Tag membership expresses "a `kilogram` *is tagged
as* a `Unit`, regardless of where it sits in the inheritance tree". The two
relations are independent: a type can extend `number` and simultaneously be a
member of the `Unit` tag, picking up wiring from both keys. Sample use cases:
all `Unit`-tagged types get an SI-normalisation processor; all
`MutableConfig`-tagged types get a "warn on missing default" validator; all
number-tagged types get a range-check validator parameterised from the
type's own min/max.

User-facing forms are unchanged: `TypeWiring.tsv` accepts a tag name in the
`typeName` column the same way it accepts a type name, and `builtin_wiring`
likewise — `TW.register("Unit", { ... })` registers wiring for the `Unit`
tag if `Unit` was declared as a tag, or for the `Unit` type if it was
declared as a type. The registry doesn't need to know which; the
namespace-sharing rule guarantees only one of them is ever in scope under
that name.

**Composition order.** Ancestor pass runs first, then tag pass. Rationale:
ancestor wiring is "behaviour brought in by the type's lineage" (the more
specific story); tag wiring is "behaviour brought in by a cross-cutting
concern" (the more orthogonal story) — applying lineage first and layering
cross-cutting on top matches the OO mental model. Within each pass, the
existing within-pass rule applies (shallowest first for ancestors;
registration order for tags, since tag membership has no inherent
ordering).

**`onLoad` for tag entries.** Allowed in principle — a tag-keyed `onLoad`
would fire for every file whose typeName is a tag member, with the same
in-engine-only restriction. No current use case demonstrates the need;
defer the decision until one surfaces.

**Performance.** The naive tag pass is O(T × M) where T is the number of
registered tags and M is the average tag size. For TabuLua's realistic
scale (tens of tags, tens to hundreds of members) this is well under
existing parsing cost. A reverse index ("type → tags it belongs to") can be
added later if the scan shows up in profiling, but isn't warranted in v1.

### Engine post-passes (L2 — module-level)

Some wiring needs a cross-file check that can't be expressed as a per-file
`validator_spec`: it needs to compare data across files, or it needs
engine-only state (`tsv_files`, `lcFn2Type`, `extends`, ...). Graph's
[`validateEdgeFiles`](../graph_wiring.lua#L277-L416) is the existing case;
plausible future cases include "every file extending `Currency` shares the
same precision" or "the union of all `Faction`-tagged rows is well-formed".

Such checks register via `registerModule`:

```lua
TW.registerModule("graph_wiring", {
    enginePostPasses = {
        graph_wiring.validateEdgeFiles,  -- function (tsv_files, joinMeta, badVal) → ok
    },
})
```

Module-level (not per-typeName) because a cross-file check doesn't
"belong to" any single super-type — `validateEdgeFiles` cares about the
edges↔nodes relation, not about which graph family is involved.
Registering it once under the owning module avoids the awkward "register
the same callback under three typeNames and rely on dedup" pattern.

The registry collects every registered `enginePostPasses` entry into a
single ordered list at engine init. Ordering is registration order with
ties broken by `moduleName` lexicographically for determinism. The
existing `runEnginePostPasses` step in `manifest_loader.processFiles`
runs them after the per-file validator phase, before `processFiles`
returns.

A post-pass receives `(tsv_files, joinMeta, badVal)`. It returns `true`
on success, `false` on any reported error. Its return value contributes
to `validationPassed`. Errors must be reported via `badVal` (not raised),
matching the existing
[manifest_loader.lua:1094-1098](../manifest_loader.lua#L1094-L1098) pattern.

### Sandbox helpers (L3 — module-level)

Wired `processor_spec` / `validator_spec` entries reference functions by
name (`"completeBasicGraph(rows)"`). The dispatcher cannot make those
functions callable on its own — they live in the sandbox env constructed
by [processor_executor.createProcessorEnv](../processor_executor.lua#L357)
and [validator_executor.VALIDATOR_HELPERS](../validator_executor.lua#L27).

Modules declare their helpers once, at engine init:

```lua
TW.registerModule("graph_wiring", {
    sandboxHelpers = {
        processor = {
            completeBasicGraph    = processor_executor.completeBasicGraph,
            completeDirectedGraph = processor_executor.completeDirectedGraph,
        },
        validator = {
            graphRefsExist = graph_helpers.graphRefsExist,
            graphAcyclic   = graph_helpers.graphAcyclic,
            graphTreeShape = graph_helpers.graphTreeShape,
        },
    },
})
```

Module-level because a helper name occupies a single global slot in the
sandbox env — it can't sensibly be "registered per typeName" (which name
would the env see for files that aren't in the cascade?). Centralising on
the owning module also means the duplicate-across-three-families pattern
the original Design hinted at simply doesn't arise.

`type_wiring.sandboxAdditions()` returns `{processor = {...}, validator =
{...}}`. `processor_executor` and `validator_executor` call this once at
engine init and merge the results into their existing helper blocks.
**Name collisions are an error** — wiring authors don't get to silently
shadow existing helpers. Resolution: pick a different name, or coordinate
with the helper's owner. The error message names both contributing
modules.

User-authored `TypeWiring.tsv` cannot contribute sandbox helpers —
arbitrary Lua-in-the-sandbox is out of scope.

### Descriptor columns and the minimal core Files.tsv schema (L4 — module-level)

Of the sixteen columns
[files_desc.parseFilesDescHeader](../files_desc.lua#L173) recognises
today, only six are intrinsic to "describe a file":

| Column | Why it's core |
|---|---|
| `fileName:filepath` | The file the row refers to. Read before anything else can dispatch. |
| `typeName:type_spec` | The file's record type — the cascade dispatch key. |
| `superType:super_type` | Populates the `extends` map that the cascade dispatcher walks. |
| `baseType:boolean` | Tightly coupled to `superType` validation in [files_desc.checkBaseType](../files_desc.lua#L282). |
| `loadOrder:number` | Package- and file-level ordering; controls when wiring fires. |
| `description:text` | Pure user metadata; harmless either way but small enough to leave in core. |

The other ten — `publishContext`, `publishColumn`, `joinInto`,
`joinColumn`, `export`, `joinedTypeName`, `variant`, `rowValidators`,
`fileValidators`, `preProcessors`, `edgesFor` — are feature-specific
accretion (L4). After the refactor, `files_desc.lua` hard-codes only the
six core columns; every other column is re-introduced by a feature
module registering it via `registerModule`:

```lua
-- file_joining (existing engine module)
TW.registerModule("file_joining", {
    descriptorColumns = {
        { name = "joinInto",        type = "filepath|nil",
          fieldOnMeta = "lcFn2JoinInto",
          parse = function(v) return v:lower() end },
        { name = "joinColumn",      type = "name|nil",
          fieldOnMeta = "lcFn2JoinColumn" },
        { name = "export",          type = "boolean|nil",
          fieldOnMeta = "lcFn2Export" },
        { name = "joinedTypeName",  type = "type_spec|nil",
          fieldOnMeta = "lcFn2JoinedTypeName" },
    },
})

-- variants
TW.registerModule("variants", {
    descriptorColumns = {
        { name = "variant", type = "name|nil", fieldOnMeta = "lcFn2Variant" },
    },
})

-- validators
TW.registerModule("validators", {
    descriptorColumns = {
        { name = "rowValidators",  type = "{validator_spec}|nil",
          fieldOnMeta = "lcFn2RowValidators" },
        { name = "fileValidators", type = "{validator_spec}|nil",
          fieldOnMeta = "lcFn2FileValidators" },
    },
})

-- pre-processors
TW.registerModule("pre_processors", {
    descriptorColumns = {
        { name = "preProcessors", type = "{processor_spec}|nil",
          fieldOnMeta = "lcFn2PreProcessors" },
    },
})

-- publish (sandbox-context exposure)
TW.registerModule("publish", {
    descriptorColumns = {
        { name = "publishContext", type = "name|nil", fieldOnMeta = "lcFn2Ctx" },
        { name = "publishColumn",  type = "name|nil", fieldOnMeta = "lcFn2Col" },
    },
})

-- graph_wiring (added by L4's original case)
TW.registerModule("graph_wiring", {
    descriptorColumns = {
        { name = "edgesFor", type = "filepath|nil",
          fieldOnMeta = "lcFn2EdgesFor",
          parse = function(v) return v:lower() end },
    },
})
```

`files_desc.lua` consults `type_wiring.descriptorColumns()` once at the
top of `parseFilesDescHeader`, merges the result with its six built-in
columns, and uses the combined list to drive both header recognition
and the row-loop population of `joinMeta[col.fieldOnMeta][lcfn]`. The
`parse` function — when present — is applied to the raw cell value
before storage (mirroring the current `:lower()` calls on `joinInto`
and `edgesFor`).

The dedup rule (table at "The registry"): identical declarations merge
silently; any other re-declaration of the same `name` is a
registration-time error naming both contributing modules. This catches
"two unrelated features want a `weight` column and accidentally
collide" at engine init rather than at row-parse time.

Why "core" still keeps the six columns rather than dropping all the way
to zero: the six are *load-bearing* for the wiring registry itself —
the cascade dispatcher reads `superType`/`baseType`, the load loop
needs `fileName` and `loadOrder`, and `typeName` *is* the dispatch
key. Moving any of them into wiring would create a bootstrap cycle.
The six-column boundary is exactly the line below which the registry
becomes circular.

User-authored `TypeWiring.tsv` cannot contribute descriptor columns
either: a Files.tsv row that referred to a column Files.tsv itself
doesn't yet recognise is a chicken-and-egg loading problem. Users
contribute *values* through the regular `TypeWiring.tsv` form.

### Ablation check

A small but real concern with L4's reframing: each currently-optional
column has an `Idx == -1` guard, so files **without** that column
already parse — but does the whole pipeline run cleanly when the
column truly never appears? Phase 2a includes an ablation step that
generates synthetic Files.tsv fixtures with one optional column at a
time removed and runs the full load pipeline against them. Any code
path that *assumes* the column-presence — e.g. a downstream module
looking up `joinMeta.lcFn2JoinInto` and failing on `nil` instead of
empty — is fixed at that point. After this, the "shrunk core schema"
in the refactored `files_desc.lua` is safe by construction.

### Core's seeding module

Since core ships no data files, a small module — `builtin_wiring.lua` — runs
at engine init and seeds the registry the **same way user packages would**,
but via the Lua API:

```lua
local TW = require("type_wiring")

-- ============================================================
-- Module-level: schema columns, sandbox helpers, post-passes.
-- These were previously hard-coded in files_desc.lua / executor
-- modules / manifest_loader.lua; each becomes a registerModule call
-- owned by the feature it belongs to.
-- ============================================================

TW.registerModule("publish", {
    descriptorColumns = {
        { name = "publishContext", type = "name|nil", fieldOnMeta = "lcFn2Ctx" },
        { name = "publishColumn",  type = "name|nil", fieldOnMeta = "lcFn2Col" },
    },
})

TW.registerModule("file_joining", {
    descriptorColumns = {
        { name = "joinInto",       type = "filepath|nil",
          fieldOnMeta = "lcFn2JoinInto",
          parse = function(v) return v:lower() end },
        { name = "joinColumn",     type = "name|nil",  fieldOnMeta = "lcFn2JoinColumn" },
        { name = "export",         type = "boolean|nil", fieldOnMeta = "lcFn2Export" },
        { name = "joinedTypeName", type = "type_spec|nil",
          fieldOnMeta = "lcFn2JoinedTypeName" },
    },
})

TW.registerModule("variants", {
    descriptorColumns = {
        { name = "variant", type = "name|nil", fieldOnMeta = "lcFn2Variant" },
    },
})

TW.registerModule("validators", {
    descriptorColumns = {
        { name = "rowValidators",  type = "{validator_spec}|nil",
          fieldOnMeta = "lcFn2RowValidators" },
        { name = "fileValidators", type = "{validator_spec}|nil",
          fieldOnMeta = "lcFn2FileValidators" },
    },
})

TW.registerModule("pre_processors", {
    descriptorColumns = {
        { name = "preProcessors",  type = "{processor_spec}|nil",
          fieldOnMeta = "lcFn2PreProcessors" },
    },
})

TW.registerModule("graph_wiring", {
    descriptorColumns = {
        { name = "edgesFor", type = "filepath|nil",
          fieldOnMeta = "lcFn2EdgesFor",
          parse = function(v) return v:lower() end },
    },
    sandboxHelpers = {
        processor = {
            completeBasicGraph    = processor_executor.completeBasicGraph,
            completeDirectedGraph = processor_executor.completeDirectedGraph,
        },
        validator = {
            graphRefsExist = graph_helpers.graphRefsExist,
            graphAcyclic   = graph_helpers.graphAcyclic,
            graphTreeShape = graph_helpers.graphTreeShape,
        },
    },
    enginePostPasses = { graph_wiring.validateEdgeFiles },
})

-- ============================================================
-- Per-typeName: cascade contributions, dispatched at file load time.
-- ============================================================

-- Phase 1 migration: the three existing onLoad-style wirings.
TW.register("Type",            { onLoad = registerAliases })
TW.register("enum",            { onLoad = registerEnumParser })
TW.register("custom_type_def", { onLoad = registerCustomTypesFromFile })

-- Phase 2 migration: graph wiring. The bundles match the per-leaf
-- flattening in graph_wiring.ROLE_OF / VALIDATORS_FOR_ROLE.

local BASIC_COMPLETION = {
    expr = "completeBasicGraph(rows)",
    priority = 50, rerunAfterPatches = true, level = "error",
    position = "prepend",
}
local DIRECTED_COMPLETION = {
    expr = "completeDirectedGraph(rows)",
    priority = 50, rerunAfterPatches = true, level = "error",
    position = "prepend",
}

TW.register("basic_graph_node", {
    preProcessors  = { BASIC_COMPLETION },
    fileValidators = {
        { expr = "graphRefsExist(rows, 'basic')", level = "error" },
    },
})

TW.register("graph_node", {
    preProcessors  = { DIRECTED_COMPLETION },
    fileValidators = {
        { expr = "graphRefsExist(rows, 'directed')", level = "error" },
        { expr = "graphAcyclic(rows)",               level = "error" },
    },
})

-- tree_node is a parser-alias of graph_node (L5). The dispatcher walk
-- stops at "tree_node" when extends[t] is nil, so we register the
-- *full* bundle here rather than relying on cascade composition.
TW.register("tree_node", {
    preProcessors  = { DIRECTED_COMPLETION },
    fileValidators = {
        { expr = "graphRefsExist(rows, 'directed')", level = "error" },
        { expr = "graphAcyclic(rows)",               level = "error" },
        { expr = "graphTreeShape(rows)",             level = "error" },
    },
})
```

A few things to notice in the migrated form:

- The per-typeName `register` calls are now small — just `preProcessors`
  and `fileValidators`. Everything else moved to the single
  `registerModule("graph_wiring", ...)` call, which owns the column,
  the helpers, and the post-pass once.
- The `priority=50, rerunAfterPatches=true, position="prepend"`
  metadata on completion processors maps one-to-one to
  [graph_wiring.lua BASIC_COMPLETION / DIRECTED_COMPLETION](../graph_wiring.lua#L105-L117).
- Validators omit `position`, so they default to `"append"` — matching
  [graph_wiring.lua:229](../graph_wiring.lua#L229) (`prepend=false`).
- The duplication-across-three-families pattern the original Design
  invited (`sandboxHelpers` repeated three times, `enginePostPasses`
  repeated three times) is **gone** — it was a symptom of putting
  module-level concerns in per-typeName registrations.

The `onLoad` callbacks (`registerAliases`, `registerEnumParser`,
`registerCustomTypesFromFile`) move from
[manifest_loader.lua](../manifest_loader.lua) into `builtin_wiring.lua`
essentially unchanged — same signatures, same internals. They're just no
longer dispatched by a hand-written `if`-cascade.

This matches how [parsers/builtin.lua](../parsers/builtin.lua) already works:
the built-in types are registered via Lua calls; user packages declare types
via TSV files; both end up in the same registry. Type-wiring follows the same
shape, one level up.

### User packages: bootstrap-registered wiring (code libraries)

Code libraries are already user-supplied Lua: a package's manifest can
list `code_libraries`, and [manifest_info.loadCodeLibrary:339-367](../manifest_info.lua#L339-L367)
loads each via `sandbox.protect(content, opt)` + `pcall`, with a
quota and the standard `sandbox_env.new()` env. The library's
top-level code runs at that point and its return value becomes the
library's `exports` table.

That existing flow already covers **pure-library init**: building local
tables, computing constants, wiring exports together — anything that
doesn't need to touch engine state happens implicitly at load time. The
new piece this refactor adds is a path for **engine-extending init**:
calls to `register` / `registerModule` from within a user package.

#### The `bootstrap` manifest field

A new optional manifest field declares functions to invoke after all
code libraries have loaded:

```text
bootstrap:{{library:name, fn:name}}|nil
```

Each entry references a function exported by one of the package's
code libraries. After every package's `code_libraries` are loaded
(maintaining the existing manifest-scan order), the engine walks each
package's `bootstrap` list in package-dependency order, resolves each
`{library, fn}` against the loaded `loadEnv[library]`, and calls
`fn(api)` — with `api` a single frozen table carrying the registration
handles.

A library that ships no `bootstrap` entry is pure sandbox code that
produces values; the engine never gives it the registration handles.
Declaring a `bootstrap` entry is the deliberate trust marker that
says "this function does engine-extending work."

#### The `api` table

A single shared table, passed unchanged to every bootstrap call across
every package, frozen to prevent inter-package coupling through stashed
fields:

```lua
local function makeBootstrapAPI()
    local sealed = false
    local api = readOnly({
        register       = function(...)
            if sealed then error("register: bootstrap phase ended", 2) end
            return TW.register(...)
        end,
        registerModule = function(...)
            if sealed then error("registerModule: bootstrap phase ended", 2) end
            return TW.registerModule(...)
        end,
    })
    return api, function() sealed = true end
end
```

The engine creates one `(api, seal)` pair at the start of the bootstrap
phase, passes `api` to every bootstrap call, then invokes `seal()` once
after the last bootstrap returns. From that point forward, any call to
`api.register` / `api.registerModule` errors — so a bootstrap that
stashed the handle into its library's persistent state for later abuse
gets a clean error at call time rather than a confusing
"registration silently had no effect" (registrations after init
wouldn't be visible to the column parser, the env builder, or the
cascade dispatcher anyway).

Note: proxy identity is what makes the seal work — `api.register` is a
stable reference whose *call* checks `sealed`, not whose *lookup* does.
Inlining the real `TW.register` reference at bootstrap-call time would
defeat the seal. Don't "optimise" by inlining.

Two design wins from this shape:

- **`type_wiring.register` and `registerModule` stay phase-unaware.**
  The init-phase check lives in exactly one place (the api factory),
  not threaded into every registration function.
- **Future API additions are purely additive.** Adding
  `api.someNewHelper` later doesn't change any existing bootstrap's
  call signature.

#### What a bootstrap can contribute

A bootstrap function can register against any of the seven contribution
slots **except `onLoad`**:

| Slot | Bootstrap-reachable? | Why |
|---|---|---|
| `preProcessors` / `rowValidators` / `fileValidators` | Yes | Just append-or-prepend on per-file arrays; no privileged access needed. |
| `descriptorColumns` | Yes | The `parse` function is sandbox-Lua (typically a one-liner like `function(v) return v:lower() end`); the rest is data. |
| `sandboxHelpers` | Yes | Helpers run *inside* the sandbox at call time anyway, so a sandboxed-Lua function is the natural shape. |
| `enginePostPasses` | Yes | The callback receives `(tsv_files, joinMeta, badVal)` and reports via `badVal` only — sandboxed Lua can read tables given to it as references; mutation isn't required for an inspection pass. |
| `onLoad` | **No** | The three existing `onLoad` callbacks all mutate the parsers-module registration tables, which aren't exposed in `sandbox_env.new()`. A sandbox-loaded library can't reach them. Deferred (see Out of scope). |

This is a noteworthy expansion of trust: a user-data package with a
declared bootstrap is *de facto* shipping engine extensions, even
though the code library itself runs sandboxed. The reason it works at
all is that the four reachable slots are limited to "produce a value
the engine will call later under controlled conditions" — none of them
expose ambient mutation of engine state.

### User packages: `TypeWiring.tsv` (pure-data path)

For packages that don't need a code library at all, `TypeWiring.tsv` is
the pure-data path:

```tsv
typeName:name        preProcessors:{processor_spec}|nil   rowValidators:{validator_spec}|nil   fileValidators:{validator_spec}|nil
MySuperType          [...]                                 [...]                                 [...]
```

Loaded during the same early pass that loads `Files.tsv`. Each row becomes a
`register(typeName, {...})` call. `onLoad` is intentionally absent from the
TSV form — see "What each user path can contribute" below.

The dispatcher then sees those entries during file processing exactly the
same way it sees built-in entries: there's **no privileged path** for
engine-registered wiring.

### What each user path can contribute

Three user-extension paths, each with a different reach:

| Slot | Engine code | Bootstrap (code library) | `TypeWiring.tsv` |
|---|---|---|---|
| `onLoad` | Yes | No (parsers-mutation outside sandbox) | No (no Lua-function syntax) |
| `preProcessors` / `rowValidators` / `fileValidators` | Yes | Yes (per-typeName via `register`) | Yes (one row per typeName) |
| `descriptorColumns` | Yes | Yes (via `registerModule`) | No (chicken-and-egg: column-as-yet-unrecognised) |
| `sandboxHelpers` | Yes | Yes (via `registerModule`) | No (no Lua-function syntax) |
| `enginePostPasses` | Yes | Yes (via `registerModule`) | No (no Lua-function syntax) |

Rationale for the "No" cells:

- A `TypeWiring.tsv` row is a TSV cell; it can encode a sandboxed
  expression (`processor_spec`, `validator_spec`) but not a Lua
  function value, so the three Lua-function-valued slots are
  unreachable from TSV.
- `TypeWiring.tsv` can't contribute `descriptorColumns` because a row
  in it would refer to columns Files.tsv itself doesn't yet recognise
  during early parsing — a chicken-and-egg loading problem.
- `onLoad` callbacks need to mutate the parsers-module registration
  tables, which aren't exposed in `sandbox_env.new()`. Neither user
  path reaches them. Only engine code does.

### Migration script detection — a softer fit

[manifest_loader.lua:390-414](../manifest_loader.lua#L390-L414)
`isMigrationScript` fires on rawtsv shape, not on typeName — migration
scripts don't appear in `Files.tsv`. It's worth flagging as a similar
architectural pattern ("hard-coded recogniser that triggers a special path")
but the dispatch key is different. Two options:

- (a) Leave it alone. The cost is one branch in the loader; the benefit of
  moving it is small.
- (b) Generalise into a separate "file-shape recogniser" registry, parallel
  to (but distinct from) the type-wiring registry.

Lean (a) for now. Document it as a known candidate; revisit if a second
shape-based recogniser appears.

### COG processing — a different registry, not this one

[lua_cog.processContentBV](../lua_cog.lua) is invoked at three call sites
([manifest_info.lua:235](../manifest_info.lua#L235),
[files_desc.lua:147](../files_desc.lua#L147),
[manifest_loader.lua:428](../manifest_loader.lua#L428)) on the raw text of
every manifest, descriptor, and data file before TSV parsing. It is the
same architectural shape as the type-wiring branches — a hard-coded
preprocessing stage — but **it cannot live in this registry**, for three
reasons:

1. **It runs before the typeName is known.** Type-wiring dispatches by
   walking the file's `extends` chain. At the COG stage no chain exists
   yet; the file is still a string.
2. **COG can synthesise the file's header.** A COG block is allowed to
   emit the column header itself, so the typeName is a *result* of COG,
   not an input. Type-driven dispatch is structurally impossible.
3. **The value being transformed is a string, not a parsed file.** All
   four type-wiring contribution kinds (`onLoad`, processors, validators)
   operate on the post-parse `file` value. Adding a fourth phase that
   operates on raw text would conflate two unrelated lifecycles.

The right home for COG is a *separate* registry — a "content pipeline" or
"text-stage" registry whose dispatch key is "any text file" (or "files
matching glob X") and whose value is the raw string. When this was first
written COG was the single member, so the note said to carve it out "only
if a second stage appears — a decompressor, a macro pre-expander, a
license-header stripper." Those stages are now wanted (decompression of
`.gz`/`.zst` inputs; transcoders for XML/JSON/SQLite/`.eav` → TSV), so
that registry **is now planned** — see [content_pipeline.md](content_pipeline.md).
COG migrates into it as the first `macro`-phase stage. This section
remains as the rationale for *why* COG does not belong in the type-wiring
registry; a future contributor should not propose adding COG here without
seeing why the dispatch key (file name, not record type) and the value
(raw bytes, not a parsed file) make it a different registry.

## Implementation Plan

Each phase is independently shippable.

### Phase 1 — `type_wiring` module + migrate `Type` / `enum` / `custom_type_def`

This phase is *internal-only*: no user-visible change, no new features. It
establishes the registry and proves the dispatcher against the three
existing cases.

- New module `type_wiring.lua` with `register`, `registerModule`,
  `applyWiring`, `hasOnLoad`, `runEnginePostPasses`, `sandboxAdditions`,
  `descriptorColumns`, `getVersion`.
- New module `builtin_wiring.lua` that, at init time, registers the three
  existing `onLoad` handlers. The handlers themselves
  (`registerAliases`, `registerEnumParser`, `registerCustomTypesFromFile`)
  move out of [manifest_loader.lua](../manifest_loader.lua) into
  `builtin_wiring.lua`.
- [manifest_loader.lua](../manifest_loader.lua):
  - Replace
    [manifest_loader.lua:471-479](../manifest_loader.lua#L471-L479) with a
    single `type_wiring.applyWiring(fileType, extends, ctx)` call.
  - Delete `isType`, `isEnum`, `isCustomTypeDef`, `findAllTypes`,
    `buildCustomTypesSet` — replaced by the generic ancestor walk inside
    the registry.
  - `typesSet` / `enumsSet` / `customTypesSet` either go away entirely
    (each handler does its own "am I applicable?" check) or collapse into
    a single `wiredFiles` map maintained by the registry. Pick at
    implementation time.
- [files_desc.lua](../files_desc.lua): `POST_PROCESS_PARENTS` becomes a
  query into the registry — `type_wiring.hasOnLoad(typeName, extends)` —
  so the reprocessing pass automatically picks up any future type that
  registers an `onLoad`. This is the small functional win of Phase 1:
  new `onLoad`-registering built-ins don't need to be added to a second
  table by hand.
- Tests: all existing `spec/manifest_loader_*` tests must continue to
  pass unchanged. Add a small `spec/type_wiring_spec.lua` covering
  ancestor-walk accumulation, idempotency, and `register` / `applyWiring`
  mechanics.

### Phase 2a — `registerModule`: engine post-passes, sandbox helpers, descriptor columns

Before migrating graph wiring, the three module-level contribution
slots have to exist, and the core Files.tsv schema has to shrink. Each
bullet is independently shippable.

- **`registerModule` API.** Mirror of `register`, keyed by `moduleName`
  rather than typeName. Holds only the three module-level slots
  (`descriptorColumns`, `sandboxHelpers`, `enginePostPasses`) — passing
  per-typeName fields to it is a registration-time error and vice versa
  (catches the conceptual mix-up early).
- `enginePostPasses`:
  - Registry collects every callback into a single ordered list at engine
    init. `type_wiring.runEnginePostPasses(tsv_files, joinMeta, badVal)`
    invokes them and returns aggregate `ok`.
  - [manifest_loader.processFiles](../manifest_loader.lua) calls this
    after the per-file validator phase, before returning. The result
    feeds into `validationPassed`.
  - Ordering: registration order with ties broken by `moduleName`
    lexicographically. Function-identity dedup so a duplicate
    registration is a silent no-op.
  - Tests: a stand-alone unit spec for the post-pass list builder, plus
    an integration that registers a no-op pass and asserts it ran.
- `sandboxHelpers`:
  - Registry exposes `sandboxAdditions()` returning
    `{processor = {...}, validator = {...}}`.
  - `processor_executor` and `validator_executor` merge the result into
    their existing helper blocks at engine init.
  - Name-collision check is registration-time, not env-build-time, so
    the error message names both contributing modules.
  - Tests: a `spec/type_wiring_sandbox_helpers_spec.lua` covering merge,
    collision detection, and the `processor`/`validator`/`both` keys.
- `descriptorColumns`:
  - Registry exposes `descriptorColumns()` returning the union of
    declared columns.
  - [files_desc.parseFilesDescHeader](../files_desc.lua#L173) and
    [files_desc.processFilesDesc](../files_desc.lua#L336) consult this
    union (merged with the six intrinsic core columns) to recognise
    columns; the parsed value lands at `joinMeta[col.fieldOnMeta][lcfn]`
    (with the registered `parse` function applied first if present).
  - Tests: a `spec/type_wiring_descriptor_columns_spec.lua` covering
    declaration, dedup of identical declarations, and the conflict
    error for incompatible re-declarations.

- **Shrink the core Files.tsv schema** (the L4 cleanup):
  - Move the ten optional columns currently hard-coded in
    [files_desc.lua](../files_desc.lua)
    (`publishContext`, `publishColumn`, `joinInto`, `joinColumn`,
    `export`, `joinedTypeName`, `variant`, `rowValidators`,
    `fileValidators`, `preProcessors`) into `registerModule` calls
    owned by the corresponding feature module (`publish`,
    `file_joining`, `variants`, `validators`, `pre_processors`).
    Code shape per "Core's seeding module" above.
  - `files_desc.lua` retains hard-coded recognition only for the six
    intrinsic columns: `fileName`, `typeName`, `superType`, `baseType`,
    `loadOrder`, `description`.
  - The `parseFilesDescHeader` index variables become a single
    `{[colName] = idx}` map produced by merging the six built-ins with
    the registry union. The hard-coded `*Idx` locals go away.
  - `processFilesDesc`'s long if/else cascade
    ([files_desc.lua:408-457](../files_desc.lua#L408-L457)) collapses
    into a single loop over the merged column map, calling each
    column's `parse` function and storing into
    `joinMeta[col.fieldOnMeta][lcfn]`. The "engine-internal" handling
    of `fileName`/`typeName`/`superType`/`baseType`/`loadOrder`/
    `description` (extends-map population, type-name lookup tables,
    priority calculation) stays inline — those are the load-bearing
    six.
  - Tests: every existing `spec/files_desc*` test must continue to
    pass without modification.
- **Ablation check.** Generate synthetic Files.tsv fixtures with one
  optional column at a time removed; run the full load pipeline
  against each; assert no path errors on `nil`-from-missing-map. Any
  failure here is a real bug in the existing code that the shrunk
  schema would expose (today the `Idx == -1` guard masks it because
  the column being absent from a *fixture* is rare). Treat findings
  as bug fixes, not blockers — the shrunk schema is correct;
  downstream consumers that assumed presence aren't.
  - Tests: `spec/files_desc_ablation_spec.lua` parametrised over the
    ten optional columns.

### Phase 2b — Migrate graph wiring

This phase migrates the landed graph wiring
([graph_wiring.lua](../graph_wiring.lua)) into `builtin_wiring.lua`
using the slots from Phase 2a. Behaviour change: zero.

The split between per-typeName and module-level (Phase 2a) means the
migration is *cleaner* than the original Design suggested — the
duplicated `sandboxHelpers`/`enginePostPasses` across three families
collapse into a single `registerModule("graph_wiring", ...)` call.

- **One `registerModule("graph_wiring", ...)` call** that owns:
  - The `edgesFor` `descriptorColumn` (declared by `graph_wiring`; the
    header parser and row loop read it generically from the registry).
    The map continues to land at `joinMeta.lcFn2EdgesFor` — now allocated
    and assembled automatically via the shared `metaMaps`, with no
    per-column plumbing left in `files_desc.lua` / `manifest_loader.lua`
    (see [descriptor_map_lifecycle.md](descriptor_map_lifecycle.md)).
  - The five `sandboxHelpers` entries
    ([processor_executor.lua:378-383](../processor_executor.lua#L378-L383)
    and
    [validator_executor.lua:46-48](../validator_executor.lua#L46-L48)).
    Implementations stay in `processor_executor` and `graph_helpers`;
    only the env-injection point moves.
  - The `validateEdgeFiles` `enginePostPasses` entry, replacing the
    direct call at
    [manifest_loader.lua:1094-1098](../manifest_loader.lua#L1094-L1098).
    The function itself stays in `graph_wiring.lua` (now a leaf
    helper, no longer the dispatcher).
- **Three `register(...)` calls** for `basic_graph_node` / `graph_node`
  / `tree_node`, each carrying only `preProcessors` and
  `fileValidators` — the per-leaf-flattened bundles from
  [graph_wiring.lua:40-44](../graph_wiring.lua#L40-L44).
- Delete `graph_wiring.applyAutoWiring` and the
  `validateGraphEdgeFiles` call from `manifest_loader.lua` once the
  registry covers them. The leaf-module exports (`validateEdgeFiles`,
  `detectFamily`, etc.) stay for tests and any internal callers.
- Tests: every existing `spec/graph_wiring*` and `spec/graph_helpers*`
  test must continue to pass unchanged. Where a test imports
  `graph_wiring.applyAutoWiring` or `.validateEdgeFiles` directly, the
  unit test continues to work because those entry points stay; the
  integration tests now exercise the registry-driven path automatically.

### Phase 3a — Manifest `bootstrap` field + proxy api factory

This phase opens the engine-extending registration path to user
packages (sandboxed code libraries) without expanding the sandbox env.

- **Manifest schema.** Extend
  [manifest_info.lua:43-71](../manifest_info.lua#L43-L71) (alongside
  `code_libraries`, `custom_types`, `dependencies`, etc.) with the new
  optional field:

  ```text
  bootstrap:{{library:name, fn:name}}|nil
  ```

  Parsing follows the same pattern as `code_libraries`: a list of
  `{library_name, function_name}` pairs.
- **Proxy api factory.** New helper, likely living in `type_wiring.lua`
  itself:

  ```lua
  type_wiring.makeBootstrapAPI() → api, seal
  ```

  Returns the frozen api table (with `register` / `registerModule`
  proxies) and the `seal()` closure that flips the shared sealed flag.
  Internals as in "The `api` table" sketch in the Design section.
- **Invocation point.** New step in
  [manifest_info.buildDependencyGraph](../manifest_info.lua#L414) — or a
  small new function called from it — that, after every package's
  `loadCodeLibraries` has succeeded, walks each package's `bootstrap`
  list in **package dependency order** (so a child package can register
  against a typeName its parent just declared), resolves each
  `{library, fn}` against `loadEnv[library]`, and invokes `fn(api)`.
  Calls `seal()` once after the last bootstrap returns.
- **Bootstrap validation.** Per-entry checks during manifest parsing
  (deferred resolution to load time for non-existent libraries since
  manifest order doesn't guarantee code-library availability at parse
  time):
  - `library` must name one of the package's own `code_libraries`
    entries (cross-package borrowing of bootstraps is not v1).
  - `fn` must resolve to a function on the loaded library's exports
    table; otherwise error with a clear message naming the manifest
    file, the library, and the missing function.
- **Tests.** New `spec/type_wiring_bootstrap_spec.lua`:
  - Bootstrap registered against a known typeName fires before
    Files.tsv parsing.
  - Bootstrap that calls `api.register` after `seal()` errors with the
    expected message.
  - Bootstrap that stashes `api.register` into a library export and
    invokes it from a validator expression errors at *call* time (the
    seal works regardless of when the proxy reference was captured).
  - Two packages whose bootstraps register conflicting `descriptorColumns`
    fail with both module names mentioned.
  - Package dependency ordering: a child package's bootstrap can refer
    to a typeName declared by a parent package's bootstrap.

### Phase 3b — `TypeWiring.tsv` file kind for user packages

The pure-data path, complementary to Phase 3a's code-library path.

- New descriptor file kind, recognised by basename `TypeWiring.tsv`
  (lowercase match like `Files.tsv`).
- Loaded during the same early-files pass that loads `Files.tsv`, after
  the package's `Files.tsv` (so type-spec aliases declared there are
  already parseable).
- Each row becomes a `register(typeName, {...})` call. The same api
  table from Phase 3a is reused — the TSV loader is a thin adapter
  over the bootstrap path's `register`, sealed at the same point.
- Validation: `typeName` must be a known type (warn if unknown — possibly
  declared by a not-yet-loaded later package, in which case the row
  resolves later; error if never resolved); each `processor_spec` /
  `validator_spec` must parse.
- Cross-package ordering: type-wiring contributions from later packages
  append to (don't override) contributions from earlier packages.
  Suppression goes through [mod_overrides.md §3](mod_overrides.md) schema
  overlays, same as for `Files.tsv`-declared validators.
- Tests: new `spec/type_wiring_user_tsv_spec.lua` covering load,
  accumulation across packages, and the unknown-type warning/error path.

### Phase 4 (optional) — Migrate `isMigrationScript`

Skipped by default; revisit if a second shape-based recogniser surfaces.
If migrated: generalise into a tiny separate registry (`shape_wiring` or
similar) — kept distinct from `type_wiring` because the dispatch key
differs.

### Phase 5 — Documentation

- `MODULES.md`: new `type_wiring` and `builtin_wiring` module-detail
  sections; update dependency graph.
- `DATA_FORMAT_README.md`:
  - Short section on `TypeWiring.tsv` — what it does, what fields are
    available, how it composes with `Files.tsv`.
  - Short section on the manifest `bootstrap` field and the `api`
    table — the engine-extending path for user packages, the
    `library, fn` shape, the post-init seal, the
    "what each user path can contribute" matrix.
- `tutorial/`:
  - Extend the existing tutorial with a small custom super-type and an
    accompanying `TypeWiring.tsv` row that attaches a validator
    (pure-data path).
  - Add a second walkthrough using a code library + `bootstrap` entry
    to register a `descriptorColumn` and a tiny `enginePostPasses`
    callback — demonstrating the Lua-path features the TSV path
    can't reach.
- `CHANGELOG.md`: `### Changed` (internal refactor) for Phase 1, Phase 2a
  and Phase 2b; `### Added` for Phase 3a and Phase 3b. Plus a
  **migration guide section** (see below) so users of existing data
  projects know what they have to do.
- Update [graph_types.md](graph_types.md) and
  [pre_processors.md](pre_processors.md) to point at this document where
  they currently describe the hard-coded auto-wiring.

#### CHANGELOG migration-guide content

The migration guide goes directly into `CHANGELOG.md` under the
type-wiring release entry (no separate document). Suggested wording —
the key message is "you don't have to do anything; here's what's
available if you want it":

> **Migration guide (Type-Wiring Registry refactor)**
>
> **Required changes for existing data projects: none.** This release
> is an internal refactor of how the engine attaches behaviour to
> file types. Existing `Manifest.transposed.tsv` files, `Files.tsv`
> files, and data files continue to load and behave identically.
>
> **What changed internally:**
>
> - Ten previously hard-coded optional columns in `Files.tsv`
>   (`publishContext`, `publishColumn`, `joinInto`, `joinColumn`,
>   `export`, `joinedTypeName`, `variant`, `rowValidators`,
>   `fileValidators`, `preProcessors`, `edgesFor`) are now registered
>   by feature modules at engine init rather than enumerated in
>   `files_desc.lua`. All ten continue to be recognised in any
>   `Files.tsv`; their semantics, types, and behaviour are unchanged.
> - The six intrinsic columns (`fileName`, `typeName`, `superType`,
>   `baseType`, `loadOrder`, `description`) remain hard-coded core.
> - The graph-types auto-wiring previously in `graph_wiring.lua` now
>   flows through the same registry; user-visible behaviour is
>   unchanged.
>
> **New opt-in surfaces (you can ignore these unless you want them):**
>
> - **`TypeWiring.tsv`** (per package). A new optional descriptor file
>   that lets a package declare "every file whose typeName extends T
>   inherits these validators / processors." Pure data, no Lua needed.
>   See `DATA_FORMAT_README.md` § *Type Wiring*.
> - **`bootstrap` field in the manifest**. A new optional list of
>   `{library, fn}` pairs that run once at engine init with access to
>   the wiring registration APIs. Use this when shipping a code library
>   that needs to add engine-extending behaviour (custom `Files.tsv`
>   columns, sandbox helpers for use in expressions, cross-file
>   validators).
>
> **If you maintain engine-side Lua that reaches into `joinMeta`:**
> every existing field (`lcFn2JoinInto`, `lcFn2EdgesFor`,
> `lcFn2RowValidators`, …) continues to exist with the same shape and
> contents — only the population path has moved, not the data layout.
>
> **If you import `graph_wiring` directly from a code library:**
> `graph_wiring.applyAutoWiring`, `validateEdgeFiles`, `detectFamily`,
> and `detectEdgeFamily` remain exported. Direct callers continue to
> work; the engine itself just no longer calls `applyAutoWiring` and
> `validateEdgeFiles` directly — those flow through the registry.

## Interaction with planned features

| Feature | Effect |
|---|---|
| **[graph_types.md](graph_types.md)** (landed) | The three landed auto-wiring branches in [graph_wiring.lua](../graph_wiring.lua) become three `register(...)` calls in `builtin_wiring.lua`, plus one `enginePostPasses` entry, one `descriptorColumns` entry (`edgesFor`), and five `sandboxHelpers` entries. No user-visible behaviour change. The "auto-wiring mechanism itself is generalisable" footnote at [graph_types.md:303-307](graph_types.md#L303-L307) is **what this document plans**. |
| **[pre_processors.md](pre_processors.md)** | No effect on user-facing semantics. Wiring inserts entries into the existing `lcFn2PreProcessors` table (prepend by default, per-entry `position` override); the `priority` / `rerunAfterPatches` / `requires` fields work unchanged. |
| **[mod_overrides.md](mod_overrides.md)** | Wiring-contributed validators and processors are indistinguishable from author-declared ones once merged into the file's arrays — so `suppressValidator` overlays ([mod_overrides.md §3](mod_overrides.md)) work on them out of the box. Worth a one-line note in that document. Cross-package patches' validator re-run ([mod_overrides.md §7](mod_overrides.md)) likewise covers wiring-contributed validators automatically. `enginePostPasses` callbacks must re-run after patches if they depend on patched state — the `rerunAfterPatches` flag already supported on `processor_spec` extends to engine-pass entries the same way. |
| **Existing manifest `code_libraries`** | Phase 3a piggybacks on the existing code-library loader: a library is sandbox-loaded as today, then if the manifest's `bootstrap` field names a function on that library's exports, the function is invoked with the `api` table. No change to existing `code_libraries` semantics for libraries without a bootstrap entry. |

## Programming-pattern context

For reviewers: the pattern this refactor is an instance of has a few common
names, useful as background.

- **Plugin registry / strategy dispatch keyed by type.** A central table
  maps a key (here: ancestor typeName) to a bundle of behaviours; a single
  dispatcher consults the table instead of branching by hand.
- **Open/Closed Principle realisation.** The dispatcher is closed for
  modification; the set of wired super-types is open for extension.
- **Aspect contribution with a type-extends pointcut.** AOP framing: the
  pointcut is "files whose typeName transitively extends T"; the advice is
  the wiring entry (`onLoad`, `preProcessors`, validators).
- **Trait / mixin composition at the type level.** A super-type carries
  behaviour with it, not just structure — a child type inherits the wiring
  the same way it inherits the columns.

None of these are new ideas; the refactor's value is recognising that the
engine has independently invented the *cascade* shape four times and
collapsing it into one place.

## Out of scope (deferred)

- **User-authored `onLoad` callbacks.** The only contribution slot the
  Phase 3a bootstrap path doesn't reach. Reason: the three existing
  `onLoad` callbacks (`registerAliases`, `registerEnumParser`,
  `registerCustomTypesFromFile`) all mutate the parsers-module
  registration tables, which aren't exposed in `sandbox_env.new()` —
  the env used by code libraries. Bridging that would mean either
  exposing `parsers.registration` to sandboxed code (a large surface
  decision) or running bootstraps unsandboxed (gives up the existing
  trust model). Neither is needed for any landed or planned feature.
  Defer until a real use case appears.
- **Cross-package bootstrap borrowing.** Phase 3a requires
  `bootstrap.library` to name one of the *same package's* code
  libraries. A package wanting to call a function from a dependency's
  code library can't do that via the bootstrap field. Out of scope
  because there's no concrete use case and it complicates the trust
  model (which package is the engine extension blamed on?).
- **Migrating the six intrinsic core columns** (`fileName`, `typeName`,
  `superType`, `baseType`, `loadOrder`, `description`) out of
  `files_desc.lua` into `registerModule` calls. The cascade dispatcher
  itself depends on `typeName` / `superType` / `baseType`; moving them
  would create a bootstrap cycle. Six-column core schema is the floor.
- **Parser-alias-aware dispatch walk (option (b) under "Parser-alias
  dispatch").** Would let a single `register("graph_node", {...})`
  cover `tree_node` automatically via the parser's alias graph. Not
  done in v1 because per-leaf flattening is what `graph_wiring`
  already does and the duplication is small (three leaves). Revisit
  if a second `registerAlias`-style family appears.
- **Shape-based wiring** (the `isMigrationScript` generalisation). One
  branch isn't enough to motivate it.
- **Wiring-aware diagnostics.** A `--explain-wiring <file>` flag that
  lists "this file got these contributions from these ancestors via
  these registries" would be useful for debugging large package
  compositions, but adds CLI surface area. Defer.
- **Programmatic introspection by user expressions.** A validator asking
  "is this file's type wired?" via a helper. Not v1; revisit if a real
  use case appears.
- **Reverse index for tag-keyed wiring.** The naive O(T × M) tag pass
  is fine at TabuLua's current scale; add a `type → tags` reverse index
  only if profiling shows the scan dominating parse time.

## Open questions

1. **`onLoad` registration timing.** Today `registerAliases` etc. run
   inside the per-file load loop. If a type-wired `onLoad` registers a new
   type, must subsequent files see it? Yes — that's the whole point.
   Confirm the registry dispatch slot is inside the same loop, not a
   separate pass.

2. **Composition order across ancestor chain.** Shallowest-first feels
   right (file's own type contributes before its parent), but worth
   validating against `tree_node`'s expectation that the `graph_node`
   cycle validator runs before the `tree_node` single-root validator.
   The landed graph wiring sidesteps this entirely via per-leaf
   flattening (L5): `tree_node` registers the full validator stack in
   the order it wants. If Phase 2b sticks with flattening, the cascade
   composition order is academic for graphs; if a future wiring uses
   real cascade composition, this question reopens.

3. **Where does `builtin_wiring.lua` sit in the dependency graph?** It
   depends on `type_wiring`, `parsers` (for `registerAliases` etc.),
   `graph_wiring` / `graph_helpers` / `processor_executor` (for the
   graph slot's `sandboxHelpers` and `enginePostPasses` callbacks), and
   the `manifest_loader` helpers that today live there. Likely a
   leaf-ish module loaded last, just before the engine starts processing
   files. Resolve at Phase 1.

4. **Suppression-friendliness of contributed validators.** Mod-overrides
   §3 matches a parent's validator by expression text. Wiring-contributed
   validators are also matched by expression text, so this just works —
   but it means the wiring author should write distinctive expression
   strings. A `-- wiring:graph_node refsExist` comment in the expression
   text would make them grep-able from the overlay.

5. **TSV loading order.** `TypeWiring.tsv` must load after the package's
   `Files.tsv` (so type-spec aliases are parseable) but before the regular
   data files (so wiring is in place before they're processed). This is
   the same slot `Files.tsv` itself occupies in the dependency-resolution
   pipeline; reuse that ordering machinery. Always load `TypeWiring.tsv`,
   if present, after `Files.tsv`. Log a warning about correct ordering,
   if any other file load order is lower than `TypeWiring.tsv`.

6. **`enginePostPasses` ordering across packages.** Function-identity dedup
   keeps a single callback from running multiple times when registered
   under several typeNames, but doesn't define ordering *between distinct*
   post-passes. Registration order is the natural choice; for built-in
   wiring that resolves to engine-init order, deterministic. For Phase 3a
   user-contributed callbacks the order follows package-dependency order
   first, then within-package registration order — the same chain that
   orders bootstrap invocations. Document at Phase 2a / Phase 3a.

7. **Idempotency for `descriptorColumns`.** Two `registerModule`
   entries declaring `{name="edgesFor", type="filepath|nil",
   fieldOnMeta="lcFn2EdgesFor"}` with identical specs must merge to one
   column declaration. A conflicting redeclaration (same name, different
   type or different `fieldOnMeta`) must be a registration-time error.
   Spec for the equality predicate: name match plus deep-equals on
   `type` and `fieldOnMeta`; the `parse` function field is opaque so
   identical names with different `parse` functions are treated as a
   conflict. Confirm at Phase 2a. (Less load-bearing now that
   module-level declarations don't fan out across per-typeName
   registrations, but the rule still matters for two unrelated modules
   accidentally picking the same column name.)

8. **Are `publishContext` / `publishColumn` really feature-module
   columns?** They feed the cell-expression sandbox via the `lcFn2Ctx` /
   `lcFn2Col` maps, which is arguably more "core" than the other
   optional columns — `_G.contexts` is part of the sandbox surface. The
   plan groups them under a `publish` module, but if the ablation step
   in Phase 2a turns up too many implicit dependencies on their
   presence, they could promote back to core. Decide at Phase 2a after
   the ablation findings.

9. **Manifest schema versioning vs the new `bootstrap` field.** Adding
   a field to the manifest is a non-additive change for any package
   pinning a specific manifest schema version. The existing
   `code_libraries` / `custom_types` / `package_validators` additions
   set a precedent that new optional fields are accepted in older
   schemas without bumping the version; the same convention applies
   here. Confirm at Phase 3a that the manifest-parsing layer treats
   missing `bootstrap` as `nil` (the same way it treats missing
   `code_libraries`), so older packages continue to load unchanged.

10. **Interaction between bootstraps and `package_validators`.**
    `package_validators` (existing manifest field) runs after every
    package's data is loaded; bootstraps run *before* any package data
    is loaded. The two are disjoint phases — a package validator
    can't influence wiring registration, and a bootstrap can't see
    parsed file data. Worth a one-line note in the bootstrap doc so
    new users don't conflate the two. Confirm at Phase 3a.

These resolve during Phase 1 / Phase 2a / Phase 3a implementation;
none are blockers for starting.
