# Type-Wiring Registry: Generalising Auto-Wired Behaviour

## Status

Refactor. Depends on [graph_types.md](graph_types.md) Layer A having landed: the
goal is to refactor the hard-wired graph auto-wiring (plus three pre-existing
hard-wired type behaviours) into a single registry mechanism *after* we have
real graph data exercising the auto-wiring code path.

## Summary

Several places in the engine attach behaviour to a file based on whether its
`typeName` transitively extends a specific built-in super-type. Today each one
is a separate `if ...Set[fileType] then ...` branch in
[manifest_loader.lua](../manifest_loader.lua) plus a tiny
`isFoo(typeName, extends)` walker. After [graph_types.md](graph_types.md)
Layer A lands, there will be at least seven such cases (`Type`, `enum`,
`custom_type_def`, `basic_graph_node`, `graph_node`, `tree_node`, and the
[files_desc.lua](../files_desc.lua) `POST_PROCESS_PARENTS` table).

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
| [manifest_loader.lua:462-464](../manifest_loader.lua#L462-L464) | `enumsSet[fileType]` | Calls `registerEnumParser(file, fileType, badVal)` — registers an enum parser from the file's column 1. |
| [manifest_loader.lua:465-467](../manifest_loader.lua#L465-L467) | `typesSet[fileType]` | Calls `registerAliases(file, fileType, extends, badVal)` — registers a type alias for each row. |
| [manifest_loader.lua:468-470](../manifest_loader.lua#L468-L470) | `customTypesSet[fileType]` | Calls `registerCustomTypesFromFile(file, ...)` — registers a custom type from each row. |
| [manifest_loader.lua:522-554](../manifest_loader.lua#L522-L554) | Three walkers `isType`, `isEnum`, `isCustomTypeDef` plus `findAllTypes` and `buildCustomTypesSet` | Three near-identical implementations of "is `T` in the ancestor chain of this typeName?" |
| [graph_types.md §"Auto-wiring via superType chain"](graph_types.md#L224) | Three more branches for `basic_graph_node`, `graph_node`, `tree_node` | Appends entries to `lcFn2PreProcessors`, `lcFn2RowValidators`, `lcFn2FileValidators`. |

After [graph_types.md](graph_types.md) Layer A:

- 7 special-cased super-types
- 4+ near-identical "is X in the ancestor chain?" walkers
- Two separate dispatch points
  ([manifest_loader.lua:462-470](../manifest_loader.lua#L462-L470) for
  `Type` / `enum` / `custom_type_def`; the planned `manifest_loader` chunk
  for graph types)

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

## Design

### The registry

A new module `type_wiring.lua` exposes:

```text
type_wiring.register(typeName, contributions) → nil
type_wiring.applyWiring(fileType, extends, ctx) → nil
type_wiring.hasOnLoad(typeName, extends) → boolean
type_wiring.getVersion() → string
```

Where `contributions` is a table with optional fields:

| Field | Type | Phase | Available to user TSVs? |
|---|---|---|---|
| `onLoad` | function `(file, fileType, extends, badVal, loadEnv)` | per-file load loop, before subsequent files parse | No — named Lua callback only |
| `preProcessors` | array of `processor_spec` | appended to `lcFn2PreProcessors` before pre-processor phase | Yes |
| `rowValidators` | array of `validator_spec` | appended to `lcFn2RowValidators` | Yes |
| `fileValidators` | array of `validator_spec` | appended to `lcFn2FileValidators` | Yes |

### Why the two-phase split

The split between `onLoad` and the validator/processor arrays is forced by
*when* the work has to happen:

- `Type` / `enum` / `custom_type_def` register parsers/types. Those
  registrations must be visible to **subsequent files** in the load loop. They
  can't be `preProcessors` — pre-processors run after all files are parsed.
- Graph completion processors and validators don't need that timing — they
  just append to the same arrays the user already populates from
  `Files.tsv`.

The `onLoad` slot is restricted to in-engine callbacks because it has direct
access to the `parsers` module's mutable registration API. Sandboxing it would
mean exposing that API to user expressions — a much larger surface-area
decision than this refactor wants to take on.

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
            append(ctx.preProcessors, w.preProcessors)
            append(ctx.rowValidators, w.rowValidators)
            append(ctx.fileValidators, w.fileValidators)
        end
        t = extends[t]
    end
end
```

Order: **shallowest first** — the file's own type contributes first, then its
parent, then its grandparent, … This matches how multiple `preProcessors`
already sort (the file's own declared processors run before inherited ones).
Multiple ancestors contributing the same field accumulate (no overriding): if
`tree_node` and its parent `graph_node` both contribute validators, both run.
Authors can suppress an unwanted ancestor contribution via the same
mod-override mechanism they would use for any other auto-wired validator
([mod_overrides.md §3](mod_overrides.md), schema overlays).

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

### Core's seeding module

Since core ships no data files, a small module — `builtin_wiring.lua` — runs
at engine init and seeds the registry the **same way user packages would**,
but via the Lua API:

```lua
local TW = require("type_wiring")
TW.register("Type",            { onLoad = registerAliases })
TW.register("enum",            { onLoad = registerEnumParser })
TW.register("custom_type_def", { onLoad = registerCustomTypesFromFile })
-- Once graph_types Phase A3/A4 has landed:
TW.register("basic_graph_node", {
    preProcessors  = { "<symmetrise graphLinks>" },
    fileValidators = { "<refs exist>" },
})
TW.register("graph_node", {
    preProcessors  = { "<complete graphParents/Children>" },
    fileValidators = { "<refs exist>", "<cycle free>" },
})
TW.register("tree_node", {
    fileValidators = { "<single root>", "<≤1 parent>" },
})
```

The `onLoad` callbacks (`registerAliases`, `registerEnumParser`,
`registerCustomTypesFromFile`) move from
[manifest_loader.lua](../manifest_loader.lua) into `builtin_wiring.lua`
essentially unchanged — same signatures, same internals. They're just no
longer dispatched by a hand-written `if`-cascade.

This matches how [parsers/builtin.lua](../parsers/builtin.lua) already works:
the built-in types are registered via Lua calls; user packages declare types
via TSV files; both end up in the same registry. Type-wiring follows the same
shape, one level up.

### User packages: `TypeWiring.tsv`

User packages contribute through a new descriptor file:

```tsv
typeName:name        preProcessors:{processor_spec}|nil   rowValidators:{validator_spec}|nil   fileValidators:{validator_spec}|nil
MySuperType          [...]                                 [...]                                 [...]
```

Loaded during the same early pass that loads `Files.tsv`. Each row becomes a
`register(typeName, {...})` call. `onLoad` is intentionally absent from the
TSV form — see "Restricted to declarative contributions" below.

The dispatcher then sees those entries during file processing exactly the
same way it sees built-in entries: there's **no privileged path** for
engine-registered wiring.

### Restricted to declarative contributions in TSVs

A `TypeWiring.tsv` row can only contribute `preProcessors` / `rowValidators`
/ `fileValidators` — never `onLoad`. Rationale:

- These three are already sandboxed-expression types (`processor_spec`,
  `validator_spec`) with established semantics.
- A user-authored `onLoad` would need access to the parsers module's mutable
  state, which the sandbox does not expose.
- The contribution kinds available declaratively are exactly the ones a user
  can already write directly in their own `Files.tsv`. `TypeWiring.tsv` is a
  convenience that says "do the same thing automatically for every file
  extending T" — it's not a new capability, just a different lookup key.

If a user genuinely needs an `onLoad` (e.g. a new built-in shape that
registers parsers), they would write a Lua module and call
`type_wiring.register(...)` from it — the same path core uses for its
built-ins. That requires being part of the engine, not a pure-data package.

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
matching glob X") and whose value is the raw string. Today it would have
one member (COG itself). Worth carving out only if a second stage appears
— a decompressor, a macro pre-expander, a license-header stripper.
Collapsing a single branch isn't enough motivation on its own; recorded
here because the architectural shape is the same and a future contributor
should not propose adding COG to the type-wiring registry without seeing
why it doesn't fit.

## Implementation Plan

Each phase is independently shippable.

### Phase 1 — `type_wiring` module + migrate `Type` / `enum` / `custom_type_def`

This phase is *internal-only*: no user-visible change, no new features. It
establishes the registry and proves the dispatcher against the three
existing cases.

- New module `type_wiring.lua` with `register`, `applyWiring`,
  `hasOnLoad`, `getVersion`.
- New module `builtin_wiring.lua` that, at init time, registers the three
  existing `onLoad` handlers. The handlers themselves
  (`registerAliases`, `registerEnumParser`, `registerCustomTypesFromFile`)
  move out of [manifest_loader.lua](../manifest_loader.lua) into
  `builtin_wiring.lua`.
- [manifest_loader.lua](../manifest_loader.lua):
  - Replace
    [manifest_loader.lua:462-470](../manifest_loader.lua#L462-L470) with a
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
  ancestor-walk accumulation and `register` / `applyWiring` mechanics.

### Phase 2 — Migrate graph types

This phase happens *after* [graph_types.md](graph_types.md) Layer A has
landed with its hard-coded auto-wiring.

- Move the three hard-coded "if super extends basic_graph_node /
  graph_node / tree_node, append the matching wiring" branches out of
  [manifest_loader.lua](../manifest_loader.lua) (or wherever Phase A3/A4
  put them) and into `register(...)` calls in `builtin_wiring.lua`.
- Confirm the ancestor-walk accumulation produces the same result as the
  hand-written cascade. In particular: a `tree_node` file should pick up
  `tree_node`'s, `graph_node`'s, and `basic_graph_node`'s contributions
  in shallowest-first order. If that ordering matters for cycle-detect
  vs. tree-shape validation, document it.
- Tests: graph_types' existing integration tests in `spec/` (from
  graph_types.md Phase A3 / A4) must continue to pass without
  modification.

### Phase 3 — `TypeWiring.tsv` file kind for user packages

- New descriptor file kind, recognised by basename `TypeWiring.tsv`
  (lowercase match like `Files.tsv`).
- Loaded during the same early-files pass that loads `Files.tsv`, after
  the package's `Files.tsv` (so type-spec aliases declared there are
  already parseable).
- Each row becomes a `register(typeName, {...})` call.
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
- `DATA_FORMAT_README.md`: short section on `TypeWiring.tsv` — what it
  does, what fields are available, how it composes with `Files.tsv`.
- `tutorial/`: extend the existing tutorial with a small custom
  super-type and an accompanying `TypeWiring.tsv` row that attaches a
  validator. Demonstrates the feature without inventing a new graph or
  type from scratch.
- `CHANGELOG.md`: `### Changed` (internal refactor) for Phase 1 + Phase 2;
  `### Added` for Phase 3.
- Update [graph_types.md](graph_types.md) and
  [pre_processors.md](pre_processors.md) to point at this document where
  they currently describe the hard-coded auto-wiring.

## Interaction with planned features

| Feature | Effect |
|---|---|
| **[graph_types.md](graph_types.md)** | The three hard-coded auto-wiring branches in Phase A3 / A4 become three `register(...)` calls in `builtin_wiring.lua`. No user-visible behaviour change. The "auto-wiring mechanism itself is generalisable" footnote at [graph_types.md:251-253](graph_types.md#L251) is **what this document plans**. |
| **[pre_processors.md](pre_processors.md)** | No effect on user-facing semantics. Wiring just appends entries to the existing `lcFn2PreProcessors` table; the `priority` / `rerunAfterPatches` / `requires` fields work unchanged. |
| **[mod_overrides.md](mod_overrides.md)** | Wiring-contributed validators and processors are indistinguishable from author-declared ones once merged into the file's arrays — so `suppressValidator` overlays ([mod_overrides.md §3](mod_overrides.md)) work on them out of the box. Worth a one-line note in that document. Cross-package patches' validator re-run ([mod_overrides.md §7](mod_overrides.md)) likewise covers wiring-contributed validators automatically. |

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

- **User-authored `onLoad` callbacks.** Would require either exposing the
  parsers module to the sandbox (large surface change) or a separate
  registration API only available to Lua libs. Defer until a real use
  case appears.
- **Shape-based wiring** (the `isMigrationScript` generalisation). One
  branch isn't enough to motivate it.
- **Wiring-aware diagnostics.** A `--explain-wiring <file>` flag that
  lists "this file got these contributions from these ancestors via
  these registries" would be useful for debugging large package
  compositions, but adds CLI surface area. Defer.
- **Programmatic introspection by user expressions.** A validator asking
  "is this file's type wired?" via a helper. Not v1; revisit if a real
  use case appears.

## Open questions

1. **`onLoad` registration timing.** Today `registerAliases` etc. run
   inside the per-file load loop. If a type-wired `onLoad` registers a new
   type, must subsequent files see it? Yes — that's the whole point.
   Confirm the registry dispatch slot is inside the same loop, not a
   separate pass.

2. **Composition order across ancestor chain.** Shallowest-first feels
   right (file's own type contributes before its parent), but worth
   validating against `tree_node`'s expectation that the `graph_node`
   cycle validator runs before the `tree_node` single-root validator. If
   that ordering matters, document it; if it doesn't, the convention is
   free.

3. **Where does `builtin_wiring.lua` sit in the dependency graph?** It
   depends on `type_wiring`, `parsers` (for `registerAliases` etc.), and
   the helpers currently in [manifest_loader.lua](../manifest_loader.lua).
   Likely a leaf-ish module loaded last, just before the engine starts
   processing files. Resolve at Phase 1.

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
   pipeline; reuse that ordering machinery.

These resolve during Phase 1 implementation; none are blockers for
starting.
