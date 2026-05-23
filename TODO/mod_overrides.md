# Mod-Style Overrides: Child-Package Modifications to Parent Data

## Status

Research and plan. Companion to [pre_processors.md](pre_processors.md), which lists "letting
a dependent package add rows to a file defined in a parent package" as a deferred prerequisite.
This document covers that prerequisite *and* the broader "modify parent rows" case.

## Scope

A child (dependent) package needs to **change** data declared by a parent package, without
forking the parent files. The motivating use cases:

- A balance mod that doubles the price of every "medicine" item.
- A DLC that adds new items and creatures alongside the originals.
- A nerf patch that removes a few overpowered spells.
- A localisation pack that overrides display names on rows owned by the core.
- A "permissive prices" mod that allows zero/negative item prices the core would reject.
- A mod that changes the default spell cooldown from 5s to 3s for every spell that
  didn't specify one.

The project is application-agnostic, so the design should work equally well for any
"parent-publishes-data, child-amends-it" scenario (mod-on-game, regional config over base
config, customer-tenant on top of product defaults, etc).

### What this document does and does not cover

Two kinds of schema-touching change exist; only one of them belongs here:

| Kind | Examples | Belongs to |
|---|---|---|
| **Destructive** schema change | Rename a column, drop a column, narrow a type, change the primary key | Migration tool ([MIGRATION.md](../MIGRATION.md)) — destructively rewrites parent files |
| **Additive / widening** schema change | Override a column default, widen a column type via union, downgrade or suppress a parent validator | **This document** — overlays on the parent without modifying it |
| **Row-level** change | Add / remove / update rows; bulk transforms; filter-and-modify | **This document** — the bulk of the design |

The unifying property of the in-scope set is that every change is **safe by construction
at the schema level**: no row that was valid against the parent's schema can fail to parse
against the overlaid schema. (Row-level changes from a mod *can* of course violate parent
*validators* — that's what re-validation is for; see section 7.)

---

## 1. Survey: what do mods actually do?

Looking at how real game-modding ecosystems (Bethesda, Paradox, Stellaris, Factorio, Rim­World,
Minecraft data packs) modify base-game tabular data, the operations fall into a small set:

| # | Operation | Examples | Frequency |
|---|---|---|---|
| 1 | **Update cell** on existing row | Buff a weapon's damage; rename a creature | very common |
| 2 | **Bulk update** by filter | "Double price of all medicine items" | very common |
| 3 | **Add new row** | New item, new spell, new boss | very common |
| 4 | **Remove row** | Nerf-by-deletion, remove deprecated quest | common |
| 5 | **Replace row wholesale** | Total redesign of a single item | moderate |
| 6 | **Append to a list cell** | Add a tag, add an immunity, add a drop entry | moderate |
| 7 | **Remove from a list cell** | Strip a tag, remove a resistance | less common |
| 8 | **Replace a value in a list cell, preserving position** | Change `steel` to `mithril` in a `materials` list without disturbing the other entries | less common |
| 9 | **Merge into a map cell** | Add an entry to a `resistances` map | less common |
| 10 | **Conditional override** | "If price > 100, apply 10% discount" | moderate |
| 11 | **Compute from other rows** | Set new column based on aggregate of original data | uncommon but high-value |
| 12 | **Override column default** | Change the default value applied to all empty cells of a column | uncommon |
| 13 | **Loosen a column type** | Allow values the parent's column type rejected (e.g. negative prices) | uncommon |
| 14 | **Downgrade / suppress a parent validator** | "I know prices are now huge, stop warning about it" | uncommon |

Operation 8 is intentionally distinct from a remove (#7) plus an append (#6): the
replaced element keeps its **original position** in the list, which matters when
downstream code or sibling rows treat list positions as meaningful (a `drops[1]`
"guaranteed slot" vs a `drops[2]` "rare slot", for instance). Remove-then-append would
shift every later element and would push the new value to the tail. Op 8 is also
deliberately value-based rather than index-based — the mod says "replace `steel` with
`mithril`" and the engine finds the slot, so the mod survives parent-list reorderings
between when it was written and when it loads (§4.3 covers the encoding).

Operations 1–11 are row-level. Operations 12–14 are **schema-level**: they touch column
metadata, not cells, but they're still safe to express as an overlay because they only
*loosen* the parent's constraints. Tier A0 (section 3) covers 12–14; tiers A/B/C (sections
4–6) cover 1–11.

Beyond the data-change operations themselves, two architectural concerns matter just as much:

- **Override ordering / conflict resolution.** When two mods both touch the same cell, who
  wins? Packages already have a load order (`load_after`, `dependencies`), so the answer is
  "last writer wins", but it has to be **observable** — a modder should be able to ask "what
  changed this cell?".
- **Schema friction.** Original authors rarely anticipate every mod use case. If the base
  game declared `price:positive` but a mod wants a *negative* price, the parent's type constraint
  blocks the mod. The schema-overlay tier (section 3) lets the mod widen the type or
  downgrade the validator — but only in safe (non-narrowing) directions, so the parent
  package itself remains internally consistent.

---

## 2. Conceptual model

Two independent axes:

- **What is touched.** *Schema-level* changes target column metadata (type, default,
  validators). *Row-level* changes target rows and cells.
- **How expressive the syntax is.** From declarative single-row patches up through
  filter-and-transform up through full programmatic mutation.

I propose four tiers; a single child package can use any combination.

### A0. Schema-level overlay

The child declares an **overlay file** that targets specific columns of a parent file,
overriding the column's default, widening its type, or downgrading a validator's severity.
Only loosening directions are allowed (so by construction, no parent row that was valid
becomes invalid). Covers operations 12–14.

### A. Direct row operations (row-level, low expressiveness)

Child package declares **patch rows** in its own files. Each patch row either:

- adds a new row to a parent file (operation 3),
- removes a row from a parent file (operation 4),
- modifies one or more cells of an existing parent row (operations 1, 5–9).

This is the "explicit" tier: every change is a row in a patch file, addressable by primary
key. It is what every mod system eventually offers because it round-trips cleanly: you can
diff the patch file, version-control it, and reason about it.

### B. Filter-and-transform (row-level, medium expressiveness)

A patch file may include a **selector expression** instead of (or in addition to) explicit
primary keys, and a **transform expression** that runs on each matched row. This is the
"double the price of every medicine" case (operations 2, 10, 11). It composes well with
tier A — a single patch file can mix explicit rows and filter-based bulk edits.

### C. Pre-processor in the child package (row-level, full expressiveness)

The existing [pre_processors.md](pre_processors.md) design already provides this for *own-package*
files. Extend the same mechanism to let a child package register pre-processors that mutate
**parent files**. Anything tier A and B can do, tier C can do as well — but C is the escape
hatch for "I need full programmatic control" cases that tier A/B can't express cleanly.

Most mod authors will live in A0 (a few rows) plus A and B (the bulk of their content);
the engine team and advanced modders use tier C.

---

## 3. Design: tier A0 — schema-level overlay

A child package may declare a **schema overlay file** targeting a parent file. It is
registered in `Files.tsv` via a new column:

```tsv
fileName:filepath        typeName:type_spec   schemaOverlayOf:filepath|nil   ...
ItemSchema.tsv           SchemaOverlay        Item.tsv                       ...
```

`SchemaOverlay` is a new built-in row type. Each row targets one column of the parent
file and declares one or more loosening changes:

```tsv
column:name   newDefault:string|nil   widenTo:type_spec|nil   suppressValidator:expression|nil   validatorLevel:error_level|none|nil
cooldown      3.0                                                                                  
price                                  gold|int                                                   
price                                                          "self.price < 10000 or 'price seems unusually high'"   warn
weight                                                         "self.weight > 0 or 'weight must be positive'"          none
```
(Let's assume `gold` is an alias to `uint`)

### 3.1 The three loosening operations

| Column | Effect | Safety argument |
|---|---|---|
| `newDefault` | Replaces the column's default value (literal or `=expr`). Only takes effect for parent rows whose cell is empty. | Populated cells unchanged. The only observable difference is for cells the parent author left blank — which is precisely the "use the default" case. |
| `widenTo` | Replaces the column's type with a wider one. Engine validates that the new type **strictly extends** the parent's type (`gold` → `gold\|int`, `Element` → `Element\|nil`, etc.). | Every value valid under the parent type is still valid under the widened type, by definition of type extension. No parent row's parsing can break. |
| `suppressValidator` + `validatorLevel` | Targets a parent validator by its expression text and overrides its severity. `validatorLevel=none` removes it entirely; `warn` / `error` rebinds the level. | Severity is a reporting choice, not data. A previously-error validator becoming a warning is a visibility change. The validator still runs; only its consequences change. |

Multiple rows targeting the same column are allowed: each row declares one operation,
and they compose.

### 3.2 What overlays explicitly cannot do

- **Narrow a type.** Rejected at load time: there might be a parent row whose value no
  longer parses under the narrower type.
- **Change a column name, drop a column, change the primary key.** Destructive — use the
  migration tool.
- **Add a new column.** Use file joining (`joinInto`); already supported.
- **Tighten a validator** (`warn` → `error`, or add a new one). The child can add its own
  row/file validators against its own patch rows; it cannot tighten existing parent
  validators. Tightening would break parent data that previously validated.

### 3.3 Multiple packages overlay the same column

When packages X and Y both declare overlays for the same parent column:

- `newDefault`: later package (in load order) wins.
- `widenTo`: engine takes the **union** of all declared widenings. So if X widens
  `gold` to `gold|int` and Y widens it to `gold|float`, the final column type is
  `gold|int|float`. Order-independent.
- `suppressValidator`: lowest severity across all overlays wins (`none` < `warn` <
  `error`). Order-independent.

This means schema overlays from multiple mods compose cleanly without "last writer wins"
churn for the most common cases.

### 3.4 Interaction with tier A/B row patches

Schema overlays are applied **first** — before any patch file's data cells are parsed.
This matters: a `price:gold` parent column widened to `gold|int` by an overlay will accept
`price = -10` in a subsequent `update` patch row. Without the overlay, the same patch
would fail at type-parse time.

The order is: overlays → parse patch files → apply patches → validators. See section 7.

### 3.5 What can go wrong

| Risk | Mitigation |
|---|---|
| `widenTo` is not actually wider than the parent type | Engine rejects at load with a clear "narrowing not allowed" error. |
| `widenTo` is identical to the parent type | Warning; no-op. |
| `newDefault` is itself an `=expression` that fails | Standard default-evaluation error path; reported with file/column context. |
| `newDefault`'s value doesn't parse under the column type (even after `widenTo`) | Error at overlay-application time. |
| `suppressValidator` text doesn't match any parent validator | Warning; nothing suppressed. Probably a typo. |
| Two unrelated parent validators happen to share an expression string | Both match. Author can disambiguate by adding context inside the string, or we can extend the match to `{validator_expression, file_scope}` later. |
| Overlay targets a column the parent doesn't have | Error. |
| Overlay targets a file the parent doesn't have | Error (same as a row patch). |
| Overlay tries to set both `widenTo` and a `newDefault` whose value only parses under the wider type | Works: widening is applied first, then the default is re-parsed under the new type. |

### 3.6 Reformatter behaviour

The overlay file round-trips like any other TSV. Parent files are **not** rewritten with
the overlaid schema applied — same rule as row patches (see section 7.1).

---

## 4. Design: tier A — direct row operations

### 4.1 File registration

Child package declares a patch file in its own `Files.tsv`:

```tsv
fileName:filepath   typeName:type_spec   patchOf:filepath|nil   ...
ItemPatch.tsv       patch                Item.tsv               ...
```

`typeName` is the fixed keyword **`patch`**. This marks the file as a patch document
rather than a row-typed data file: the engine knows not to try to validate the patch
file's rows against any parent row type, and reformatters / exporters treat it as a
patch document. Reserving `patch` as a typeName keyword adds one entry to the type-name
namespace and is otherwise unused.

`patchOf` names the file (in any parent package — looked up by basename, same convention
as `joinInto`) being patched.

Rationale for a *separate file* rather than declaring patches inline in arbitrary child files:

- Patches are a distinct concept from "data this package owns". Keeping them in a separate
  file makes intent obvious to reviewers.
- The file's columns can be a **subset** of the target's columns. A patch that only changes
  `price` doesn't need every other column.
- Standard reformatter tooling and the join system continue to apply per-file unchanged.

Each column in the patch-file header declares its **own** type, independent of the
parent's column types. By convention the author writes the parent's column type made
nullable (`price:gold|nil` against a parent that declared `price:gold`), so that empty
cells are valid and carry the "leave unchanged" semantics described in §4.2. But the
author is free to declare any type: it controls only how the patch file's TSV cell is
parsed into a Lua value. The **parent's** column parser then re-validates the value when
the patch is applied (§4.4). This two-step "parse here, validate there" model means tier
A0 widenings (§3) take effect naturally — the parent's parser has already been swapped
to the widened version by the time patches apply.

### 4.2 Special column: `patchOp`

Column 1 of a patch file is the **parent's primary-key column**, with the same name and
type the parent declared. The operation column `patchOp:patch_op` sits anywhere after
it; column 2 by convention. The column name is **`patchOp`** rather than a shorter
`op` because `op` is too plausible as a user-data column name (a build tool's "op",
a workflow's "op", etc.) and clash would be silent and confusing. The matching
built-in type is `patch_op` (snake_case, mirroring `type_spec` / `validator_spec` /
`processor_spec`), so the header column reads `patchOp:patch_op`.

```tsv
name:name   patchOp:patch_op   price:gold|nil   weight:float|nil   element:Element|nil
sword2      add                 150              1.5                Fire
oldSword    remove
sword       update                               =self.weight*2
shield      update              25                                  =nil
```

`patch_op` is a new built-in enum type: `{enum: add | remove | update | replace}`.

| op | Meaning |
|---|---|
| `add` | Insert a new row. Primary key must not already exist in the parent file. Empty cells use the parent column's default value, exactly as in a normal data file. |
| `remove` | Delete the row whose primary key matches. Non-key cells are ignored. |
| `update` | Modify named cells of an existing row. **Empty cells = leave the target's cell unchanged** (a local override of TabuLua's normal "empty = use default" rule). Missing target row = error (or warning, configurable). |
| `replace` | Wholesale replace: same as `remove` + `add`. Used when "what was unchanged" is no longer meaningful. |

**Primary-key uniqueness invariant.** A given parent primary key appears in **at most
one row** per patch file. All changes to one parent row are coalesced into a single
patch row: multiple cell updates become multiple non-empty cells in the same row. This
keeps the patch file a regular TabuLua TSV — column 1 is the unique primary key, no
composites, no duplicates.

Multi-package patches on the same parent row still work: each package declares its own
patch file. Cross-package and cross-file conflict resolution is in §4.4.

**Setting a nullable column explicitly to `nil` in an `update` row.** Empty already
means "leave unchanged", so the natural representation of "set to nil" is unavailable.
Use **`=nil`** — an `=`-expression evaluating to nil:

```tsv
name:name   patchOp:patch_op   element:Element|nil
sword       update              =nil
```

`=nil` works because TabuLua's `=expr` evaluator runs in patch files like everywhere
else. The expression delivers `nil` to the patch executor, which passes it through the
parent's column parser. That parser must accept `nil` — i.e. the parent column must be
nullable (`T|nil`), or the apply step errors with "column X is not nullable". This is
the correct constraint anyway.

The `update` row in the example above demonstrates all three semantics in one line:
empty `price` cell → leave unchanged; `=self.weight*2` → compute and set; `=nil` on the
last cell → set the nullable `element` column to `nil`.

(`upsert` from earlier drafts is omitted from the v1 op set. Its semantics straddle
`add` and `update` — empty means "use default" for the add path but "leave unchanged"
for the update path, and the row's prior existence is exactly what would pick the
branch. Authors pick `add` or `update` explicitly.)

### 4.3 List/map cell mutations

Operations 6–9 (append to list, remove from list, replace-in-place, merge map) need
syntax distinct from "set whole cell" because the patch executor must know whether
to replace a list cell wholesale or merge into it. Two options for the set-style
operations:

1. **In-place sub-syntax in the cell.** E.g., `tags:{name}` could accept `+combat,-old_tag`
   in a patch file to mean "add `combat`, remove `old_tag`". Compact but adds a new dialect
   the user has to learn — and conflicts with values that legitimately start with `+`/`-`.
2. **Companion columns with verb prefixes.** `append_tags:{name}|nil`,
   `prepend_tags:{name}|nil`, `remove_tags:{name}|nil`, `replace_tags:{name}|nil`
   (the `replace_` form sets the list wholesale — equivalent to listing `tags`
   itself in an `update` row, but expressed with the same prefix family for visual
   consistency). A few columns per patched list column is verbose, but each one is
   a normal valid-identifier column.

   The verb-prefix form is **required** rather than aesthetic: TabuLua column names must
   be valid identifiers (letters / digits / underscores, starting with a letter or
   underscore). Suffix forms like `tags+` / `tags-` / `tags=` would not parse — `+`,
   `-`, `=` are not legal in column names. Underscore-separated verb prefixes keep the
   special role legible in the spreadsheet view and stay within the existing identifier
   grammar.

Recommendation: **Option 2.** Verbosity is a fair price for staying within the existing
type system; tier C (pre-processor) is available for the rare case where it's too clunky.

For maps, mirror the same: `append_resistances`, `remove_resistances`,
`replace_resistances`. The `remove_` form on a map is a list of keys to remove.
`prepend_` does not apply to maps (map entries have no order).

**Direction: first vs last.** For list columns, when the patch value matches the
parent list in more than one position, the unsuffixed verb prefix targets the
**first** match by default. A `_last_` variant targets the last match instead:

- `remove_<col>` removes the first occurrence of each listed value; `remove_last_<col>`
  removes the last occurrence.
- `replace_oldvalue_<col>` / `replace_newvalue_<col>` replace the first match (encoded
  below); `replace_last_oldvalue_<col>` / `replace_last_newvalue_<col>` replace the
  last match.

`_first_` is implied (no suffix) because most modder edits target a value that is
present at most once in the parent's list, where "first" is the only match anyway.
The `_last_` form is opt-in for the rarer case where the parent's list has duplicates
and the mod wants the tail occurrence. Targeting any other specific occurrence
(second-from-front, middle, etc.) remains tier-C territory; positional editing by
index is intentionally not exposed (see the value-based-encoding rationale below).

`append_<col>` and `prepend_<col>` are paired verbs rather than one verb with a
direction suffix: append's linguistic meaning is "add to the end", so overloading
`append_<col>` with `_first_` / `_last_` semantics would read backwards. Both
verbs accept a list of values to insert; `append_<col>` puts them at the tail,
`prepend_<col>` puts them at the head (in the order given — `prepend_tags={a,b}`
on a parent list `{c,d}` produces `{a,b,c,d}`, not `{b,a,c,d}`).

Map columns are unaffected by the first/last distinction or by `prepend_`: map
keys are unique and unordered.

**Prefix collision with parent columns.** If a parent file already has a column literally
named `append_tags`, `remove_<x>`, or `replace_<x>`, that column wins for the patch
file's interpretation — the patch executor first checks whether the patch column's name
matches a parent column directly, and only falls back to the merge-prefix interpretation
when there's no direct match. This means a parent author's column name is never
silently re-interpreted. The engine warns when a patch column matches both a parent
column and a merge-prefix form so the modder can disambiguate. Rare in practice — the
verb prefixes are deliberately cumbersome partly to keep collision odds low.

**Replace in place** (operation 8) preserves the original position of the replaced
element. It is encoded **by value, not by index**: the patch says "replace the entry
whose current value is `steel` with `mithril`", and the engine finds the slot and
writes back at the same position. Two reasons for this framing over an index-based
form:

1. **Robustness against parent-list reorderings.** If the parent's list grew, shrank,
   or reordered between when the mod was authored and when it loads, an index-based
   patch ("change index 2") silently targets the wrong slot. A value-based patch keeps
   matching the right element regardless of where it moved to.
2. **TabuLua collection-column rules close the index-based path anyway.** A patch
   file naming `drops[2]` alone would violate the "consecutive indices starting at 1"
   rule for bracket/`_N` collection columns *and* the "no mixing exploded `drops[N]`
   with a non-exploded `drops`" restriction (DATA_FORMAT_README §"Exploded Columns" →
   Collection Rules / Restrictions). The same applies to the tuple-alias `drops._2`.

The encoding: a pair of companion columns per patched list column.

| Column | Type | Meaning |
|---|---|---|
| `replace_oldvalue_<col>` | `T\|nil` (T = list element type) | Value to find in the parent's list (first occurrence). |
| `replace_newvalue_<col>` | `T\|nil` | Value to write back at the found position. |
| `replace_last_oldvalue_<col>` | `T\|nil` | Same as `replace_oldvalue_<col>` but targets the **last** matching occurrence. |
| `replace_last_newvalue_<col>` | `T\|nil` | Paired write for `replace_last_oldvalue_<col>`. |

```tsv
name:name   patchOp:patch_op   replace_oldvalue_drops:name|nil   replace_newvalue_drops:name|nil
dragon      update              steel                              mithril
```

Behavior and bad-input mitigations:

- **`oldvalue` not in the list.** Error by default. Configurable to `warn` for
  compatibility-patch use cases that target multiple parent versions and tolerate
  the absence.
- **`oldvalue` appears more than once.** The unsuffixed pair (`replace_oldvalue_<col>`
  / `replace_newvalue_<col>`) replaces the **first** occurrence; the `_last_` pair
  (`replace_last_oldvalue_<col>` / `replace_last_newvalue_<col>`) replaces the
  **last**. The engine warns on the ambiguous match either way. Targeting any other
  specific occurrence is the case for tier C.
- **`oldvalue == newvalue`.** No-op; warn (probably a typo or stale data).
- **Both companion cells empty.** Treated as "no replacement requested" — same as
  not having the columns at all. (Consistent with the rule that empty cells in
  `update` rows mean "leave unchanged"; the pair together describes one optional
  operation.)
- **Only one of the two filled.** Error: the pair is meaningless without both halves.

For **multiple replacements** on the same parent row's list, the natural extension is a
list-valued pair, deferred until the single-pair form proves inadequate:

| Column | Type | Meaning |
|---|---|---|
| `replace_oldvalues_<col>` | `{T}\|nil` | List of values to find. |
| `replace_newvalues_<col>` | `{T}\|nil` | Same length; paired by index with the `_oldvalues` list. |

Until that extension lands, multi-replacement uses tier C or splits across multiple
patch files.

For sub-**record** fields (not tuples or collections), dotted-path patching works
naturally because record-field paths don't have the consecutive-index rule. A patch
column `stats.attack:integer|nil` is fine on its own; the parent's other `stats.*`
fields are untouched (empty = leave unchanged, same rule as for top-level columns).
This covers operation 1 ("update cell on existing row") at any record depth.

(For the rare case where a mod genuinely needs index-based positional editing — e.g.
the list has duplicate values and a specific occurrence is the target — that's tier C
territory. We're not closing the door on a future positional-by-index op, but the
value-based form covers the common case more robustly.)

### 4.4 Conflict resolution

When two child packages patch the same cell of the same row:

- Apply patches in **package load order** (already deterministic via `load_after`).
- Later writer wins.
- The system records a **patch lineage** per cell (which package, which patch row,
  which op). On `--verbose` or via a dedicated `--explain-patch` flag, the user can ask
  "why does `sword.price` equal 150?" and get the chain.

Two patches inside the *same* package on the same cell: warn unless explicitly allowed
via a manifest field `allow_self_overlapping_patches:boolean`. Default off so authors catch
their own accidents.

### 4.5 Constraint relaxation

When a mod's patched value would fail the parent column's type or trip a parent validator,
the mod uses a **schema overlay** (tier A0, section 3) to widen the type or downgrade the
validator. Row patches do not carry inline schema overrides — keeping the two concerns
separate makes load-order semantics straightforward and lets the same overlay apply to
many patch files.

Concrete examples:

- Mod wants negative prices: declare `widenTo: gold|int` in a schema overlay on
  `Item.tsv`'s `price` column, *then* write `update` patch rows with negative prices.
- Mod's "doubled prices" trip a `self.price < 10000` parent validator: add a
  `suppressValidator` overlay row with `validatorLevel: warn`.

Section 3.2 lists what overlays cannot do (no narrowing, no rename, no drop, no
tightening). Those remain firmly migration-territory.

---

## 5. Design: tier B — filter and transform

A patch file row with `patchOp=update` and an empty primary key (or a special sentinel like
`*`) is interpreted as a **bulk update**, with an extra column carrying a selector
expression:

```tsv
patchOp:patch_op   where:expression|nil   name:name|nil   price:gold|nil   ...
update        =row.tags has "medicine"               =row.price * 2
```

Semantics:

- `where` is evaluated for every row of the target file. Sandbox: read-only view of the
  full target file, the row under consideration (`row`), the same helpers validators get
  (`all`, `count`, `unique`, etc.), and published contexts.
- For each matching row, every non-empty cell of the patch row is applied (as an expression
  if it starts with `=`, otherwise as a literal).
- If the value is an `=expression`, the expression's `self` is the **target row**, not the
  patch row. This is how `=row.price * 2` does what you'd hope.

Bulk operations naturally combine with explicit-key updates in the same file — the engine
just applies them in row order (preserving the file's listed order is more predictable than
sorting).

### 5.1 Helper: filter shortcuts

For the very common "select by enum or tag" case, allow a sugar form in `where`:

```tsv
where:expression|nil
=tag("medicine")
=category("weapon")
=rarity("Epic")
```

These resolve to `row.tags has "medicine"` (etc.) using conventions the parent package
declares. Not essential for v1, but makes patches readable. Defer to later.

### 5.2 What can go wrong (bad input)

This is where the surface area expands. Each of these should produce a clear error
pointing at the patch row:

| Risk | Mitigation |
|---|---|
| `where` expression throws | Caught, reported as patch row error, that patch row skipped, loading continues. |
| `where` selects zero rows | Warning (configurable level, default `warn`). Easy modder mistake: typo'd a tag name. |
| `where` selects every row when modder meant a subset | Cannot detect automatically; document the "always verify your selector" idiom. Could add an optional `expectedMatchCount:integer|nil` column for safety. |
| Transform expression references a column that doesn't exist | Parser-time error (header validation), not runtime. |
| Transform expression produces wrong type | Same as `setCell` from pre_processors: report via `badVal`, skip that cell, continue. |
| Transform expression uses non-deterministic state (`os.time`, etc.) | The sandbox already blocks this — same as validators. |
| Two filter patches both touch the same cell of the same row | Warn; later one wins. Same rule as 4.4. |
| `patchOp=add` and the key already exists | Error. Suggest `replace` if a full rewrite was intended, or splitting into an `update`. |
| `patchOp=remove`/`update` and the key doesn't exist | Configurable: `error` (default for `update`), `warn`, or `silent`. Often the desired behaviour for a "compatibility patch" that targets multiple parent versions and tolerates missing rows. |
| `where` filter on a non-existent column | Error at parse time of the expression. |
| Patch file's primary-key column missing (for `add`/`update`/`remove`) | Error: patch file must have the parent's primary key column. |
| Modder patches a row that another mod (loaded earlier) already removed | Warn; the patch becomes a no-op. |
| Mod targets a file the parent removed in a newer version | Loading fails with a clear "patch target `Foo.tsv` not found" error. |
| Patch causes a validator that previously passed to now fail | Validators re-run after patches; that's the *point*. Failure is loud. |

---

## 6. Design: tier C — package-scoped pre-processors

Once tier A and B exist, the existing [pre_processors.md](pre_processors.md) plan extends
naturally:

- Child package's `Manifest.transposed.tsv` gains a `preProcessors:{processor_spec}|nil`
  field (mirroring `package_validators`).
- These run **after** parent files are parsed *and* after tier A/B patches from the same
  package are applied, but **before** validators re-run.
- The processor sandbox sees the full merged-and-patched state of every file the child has
  declared an interest in. Write helpers (`setCell`, etc.) are scoped to files in the
  current package and to files the package has declared patches for.

### 6.1 Ordering across packages

When multiple child packages each declare tier-C processors that touch the same parent
file, ordering needs to be deterministic and overridable:

1. **Default order: package load order.** Inherited from `load_after` / `dependencies`,
   same rule the existing pipeline already uses for everything else. Within a single
   package, the `priority` field on `processor_spec` (see pre_processors.md §Ordering)
   orders that package's own processors.
2. **Explicit ordering: the `requires` field on `processor_spec`.** A processor can
   declare `requires:{"otherPackage.id"}`, meaning "any tier-C processor from
   `otherPackage.id` on this same file must have run before me". Useful when a mod
   author wants to make an ordering dependency explicit (even if load order already
   implies it), and for catching the "you forgot to depend on the mod I extend" case.
3. **Missing requirements: warn, do not fail.** If the required package isn't loaded,
   the constraint is vacuous; the processor still runs (its author may have written it
   to tolerate the dependency being absent). The warning surfaces the partial install
   to the user.
4. **Cycles: error.** A → B → A across the `requires` graph is rejected at load time.

### 6.2 Re-running parent processors

A parent's own pre-processor — declared in its `Files.tsv`, not in a mod — can opt into
being re-executed after tier A/B patches by setting `rerunAfterPatches: true` on its
spec. This is the cleanest answer to "the parent's processor computed back-refs from the
original data, then a mod added new rows: how do the new rows get back-refs?". The
parent author marks the processor as idempotent and we run it again in the
cross-package phase. Details in pre_processors.md §"Re-running after patches".

This is the escape hatch. Most mods won't need any of tier C.

---

## 7. Pipeline integration

The current pipeline (per `pre_processors.md`):

```
processFiles
  ├── resolvePackageDependencies
  ├── resolveFileDescriptors
  ├── processOrderedFiles          -- parses TSVs, evaluates =expr cells
  ├── runAllPreProcessors          -- mutate own-package parsed rows
  └── runAllValidators
```

After this proposal:

```
processFiles
  ├── resolvePackageDependencies
  ├── resolveFileDescriptors
  ├── applySchemaOverlays    [NEW]    -- tier A0: defaults / widening / validator levels
  ├── processOrderedFiles          -- parses TSVs in each package; patch files parsed against overlaid schema
  ├── runAllPreProcessors          -- own-package pre-processors (per pre_processors.md)
  ├── applyPatches            [NEW]   -- tier A + B: applies patch files in package order
  ├── runPackagePreProcessors [NEW]   -- tier C: cross-package mutators + rerun-flagged parent processors
  └── runAllValidators             -- row + file + package validators (re-run against final state)
```

Key invariants:

- Schema overlays run **before** anything else parses cells. Widening a column's type
  has to take effect before patch-file cells in that column are typed-checked, or the
  whole point of widening is lost.
- Patches and cross-package processors run **after** all parent packages' files are loaded
  and their own pre-processors have run. This guarantees parent files are in their
  "final author-intended" state before mods touch them.
- The cross-package phase (`runPackagePreProcessors`) runs *two* sets of processors,
  interleaved by ordering rules (§6.1): the child packages' tier-C processors *and* any
  parent processors that opted into `rerunAfterPatches: true`. The rerun-flagged
  parent processors run against the patched data; this is how a parent's
  inverse-relation logic (or any other derived data) reaches rows added by mods.
- Validators run **once**, at the end, against the fully patched state. This is the natural
  answer to "do we re-validate after changes?": yes — but only once. The parent's
  validators are re-applied to the patched data, so a mod that introduces a violation is
  caught (subject to any A0 severity overrides).
- A separate, optional **"would-this-pass-without-mods?"** mode (`--validate-base-only`)
  can be added for parent-package authors who want to lint their own data in isolation
  while a mod is loaded. Future, not v1.

### 7.1 Reformatter behaviour

The reformatter writes the **original** patch files and the **original** parent files; it
does not bake patches back into the parent. This matches the current rule for
pre-processor effects and for COG-generated rows: derived data is not source-of-truth.

A potential addition for tooling: a `--export-merged` flag that writes a copy of each
parent file with patches applied, separately from the source layout. Useful for "show me
the final state". Not required for v1.

---

## 8. What the original author didn't anticipate

This is the user's question, and the most interesting one. Even if every machinery in
sections 3–6 works, a mod may be blocked by *design decisions* baked into the original data:

1. **No primary key the mod can target.** If the parent split data across rows in a way
   that doesn't expose what the mod cares about (e.g. each row is a class+level combo, and
   the mod wants to change every Wizard row), the modder has to filter on multiple
   columns. Tier B (filter) handles this — the lesson is that filter-by-expression must be
   first-class, not an afterthought.

2. **Constraints too tight.** Use a schema overlay (tier A0, section 3) — widen the column
   type, override the default, downgrade or suppress the offending validator. Examples:

   - `widenTo: gold|int` on `Item.tsv:price` to allow negative prices.
   - A `suppressValidator` row with `validatorLevel: warn` to silence the parent's
     "price seems unusually high" check.
   - `newDefault: 3.0` on `Spell.tsv:cooldown` to change the global default cooldown.

   The overlay is per-column and per-validator; nothing else in the parent's schema is
   touched. Section 3.3 covers what happens when two mods overlay the same column.

3. **Hidden coupling.** A parent file might compute something via a `=expr` cell that
   depends on a published constant. The mod changes the constant in a patch; the
   `=expr` cells were already evaluated. **They won't recompute** unless we re-evaluate.
   This is the trickiest case. Three options:

   - **Document the gotcha.** Tell modders that patching published constants doesn't
     recompute downstream `=expr` cells; they must patch the downstream cells too.
   - **Lazy re-evaluation.** Mark cells whose expressions depend on patched data as
     dirty and recompute. This is a dependency-graph problem; well-defined but
     significantly more engineering.
   - **Hybrid:** the engine re-evaluates `=expr` cells of any *row* whose published-data
     dependencies have changed since first parse. Detected by analysing the AST of each
     `=expr` (similar to how `canProcessCell` already does for ordering). Defer to v2.

   Recommendation for v1: **document it**, expose a CLI warning when patched data is
   referenced by `=expr` cells the engine can statically detect aren't being re-evaluated.

4. **No extension hooks.** If the parent didn't `publishColumn` for a piece of data the
   mod needs to read, the mod can still read it via `loadEnv.files["Whatever.tsv"]`. This
   is already supported by the existing sandbox. The advice to original authors is:
   "publish liberally; cost is near zero, missing publication is a real friction point
   for modders".

5. **File-shape assumptions.** A mod that wants to add a column to a parent file
   (e.g. add `forbidden_for_evil_alignment:boolean` to every Item row) cannot do so
   through patches — patches modify cells of *existing* columns. The right mechanism for
   this is the existing **file joining** feature (`joinInto`): the mod declares
   `EvilAlignment.tsv` with `joinInto=Item.tsv, joinColumn=name`, adding a column. So we
   don't need to extend the patch system for this case; we point modders at joining.
   Worth a doc page that maps mod-use-cases to TabuLua features.
   NOTE: OK, but can we create a join for a file in a parent package? Also, we might need
   to define the content of the new file "dynamically" with COG, to match the original file
   rows, so this must also be possible.

---

## 9. Implementation phases (proposed)

Each phase is independently shippable.

**Phase 1 — schema overlay (`schemaOverlayOf`, default override, type widening,
validator-severity override).**

- New built-in row type `SchemaOverlay` and `Files.tsv` column `schemaOverlayOf:filepath|nil`.
- New module `schema_overlay.lua`.
- Type-compatibility check: confirm `widenTo` strictly extends the parent type; reject
  narrowing.
- Validator-by-text matcher with severity override (incl. `none` to remove entirely).
- Pipeline: `applySchemaOverlays` step inserted before file-cell parsing.
- Multi-overlay composition: later wins for `newDefault`; union for `widenTo`; min for
  severity.
- Tutorial: small example overlay changing a default and widening a type.
- Tests: bad cases — narrowing rejected, identical type warned, missing column / file
  error, unmatched validator-suppression warned.

Independently useful: even without any row-patching machinery, a mod can change defaults
and loosen constraints. It also unblocks Phase 2's "negative price" use case.

**Phase 2 — row patches: `patchOf` + `typeName=patch`, `patchOp` enum, no filter.**

- Reserve **`patch`** as a typeName keyword in `Files.tsv` (marks a file as a patch
  document; engine skips parent-row-type validation for it).
- New built-in enum type `patch_op` with members `add | remove | update | replace`
  (no `upsert` — see §4.2).
- `Files.tsv` gains `patchOf:filepath|nil` column.
- Header rule: column 1 = the parent file's primary-key column (same name and same
  type the parent declared); `patchOp:patch_op` sits anywhere after, column 2 by
  convention.
- Enforce **primary-key uniqueness within the patch file** — each parent PK appears
  at most once per file (§4.2 invariant). All changes to one parent row coalesce into
  multiple non-empty cells of a single patch row.
- New module `patch_executor.lua` (sibling of `validator_executor` and the planned
  `processor_executor`). Reads patch files, applies ops to target tsv_files in load order.
- **Two-step value handling:** parse each non-empty patch cell against the patch
  file's own column type (which by convention is the parent's column type made
  nullable); then re-validate the value against the **parent's** column parser at
  apply time (§4.1, §4.4). Tier A0 widenings have already swapped the parent's parser
  before this phase runs.
- Empty-cell semantics: in `update` rows, empty = "leave unchanged"; in `add` rows,
  empty = "use parent default". To set a nullable parent column explicitly to nil
  in an `update` row, use **`=nil`** (an =-expression evaluating to nil).
- Pipeline: insert `applyPatches` between `runAllPreProcessors` and `runAllValidators`.
- Reformatter: unchanged — patch files round-trip like any other TSV.
- Tutorial: add `tutorial/expansion/ItemPatch.tsv` patching one or two core items.
- Tests: `bad_input/patch_*/` fixtures covering missing parent primary-key column;
  duplicate patch-file primary key; missing `patchOp` column; wrong-type cell rejected
  by the parent's parser; missing parent file; `op=add` with existing key; `op=update`
  or `op=remove` with missing key; `=nil` against a non-nullable parent column.

**Phase 3 — filter/transform (tier B).**

> **Encoding is currently open** — §5's original "empty primary key" sketch
> violates TabuLua's primary-key uniqueness/required rules. Lock the encoding
> before starting this phase. The leading candidate (still to be discussed) is a
> **separate file kind** with a new `bulkPatchOf:filepath|nil` column in `Files.tsv`
> and a `typeName=bulk_patch` keyword, where the file's column 1 is a unique
> **rule name** (not the parent's PK) and a required `where:expression` column
> carries the selector. The two file kinds (tier A `patch`, tier B `bulk_patch`)
> can target the same parent and compose at apply time.

Once the encoding is settled, the implementation work is:

- New file-kind keyword and Files.tsv column (whatever lands).
- Sandbox env builder reuse from `validator_executor`.
- `where:expression` evaluated against the parent file's rows; per-match application
  of the transform cells, with `self` bound to the **target** row.
- Filter-shortcut sugar (§5.1) deferred to a follow-up.
- Tests including "filter selects zero rows" warn, "filter throws" error,
  "rule-name collides with anything in the parent" disambiguation.

**Phase 4 — list/map deltas via verb-prefix companion columns.**

- Patch executor recognises `append_<col>`, `prepend_<col>`, `remove_<col>`,
  `replace_<col>` companion columns for list parent columns; maps recognise
  `append_<col>`, `remove_<col>`, `replace_<col>` only (no `prepend_` — maps are
  unordered). `append_` and `prepend_` accept a list of values to insert at the
  tail or head respectively, in the order given. For list columns with duplicates,
  the find-based ops accept a `_last_` variant — `remove_last_<col>` and the
  `replace_last_oldvalue_<col>` / `replace_last_newvalue_<col>` pair (see below) —
  where the unsuffixed form targets the first match and `_last_` targets the last.
  Names use underscore separators because `+`/`-`/`=` aren't valid in TabuLua
  identifiers.
- **Prefix-collision precedence:** a patch column whose literal name matches a parent
  column name binds to that parent column; merge-prefix interpretation is the fall-back
  only when no direct match exists. Engine warns when both interpretations are possible
  so the modder can disambiguate.
- For list **replace-in-place** (operation 8), recognise the paired
  `replace_oldvalue_<col>` / `replace_newvalue_<col>` companion columns (targets the
  first match) and the `_last_` variant pair `replace_last_oldvalue_<col>` /
  `replace_last_newvalue_<col>` (targets the last match). Validate both halves of a
  pair are present (error if only one); warn on multiple matches, no-op (old == new),
  or missing-value (§4.3).
- Sub-record patching via dotted paths (`stats.attack:integer|nil`) reuses TabuLua's
  existing exploded-column handling — no new mechanism for the record subcase.
- Tests covering each merge operation, the prefix-collision precedence rule, and the
  edge cases enumerated in §4.3.
- **Deferred** to a follow-up: the multi-replace list pair
  (`replace_oldvalues_<col>` / `replace_newvalues_<col>`); any positional-by-index
  op (currently tier-C territory).

**Phase 5 — package-scoped pre-processors (tier C).**

- Builds on the existing pre-processors plan ([pre_processors.md](pre_processors.md)),
  which already specifies the relevant `processor_spec` fields (`priority`,
  `rerunAfterPatches`, `requires`).
- Permissions/scoping extension to `processor_executor` so a child package's processor
  can mutate parent files (not only its own).
- Cross-package scheduling (§6.1): package load order is the default; `requires:{package_id}`
  declares explicit ordering between sibling-mod processors that touch the same file;
  cycles in the `requires` graph error at load; missing required packages warn.
- The cross-package phase also re-invokes parent processors flagged
  `rerunAfterPatches: true` against the patched data, interleaved with tier-C processors
  by the same ordering rules.
- Tests: cross-package ordering, cycle detection, `rerunAfterPatches` re-execution sees
  patched rows.

**Phase 6 — `--explain-patch` and `--export-merged` CLI flags.**

- Patch lineage tracking added to cells (optional metadata, off by default for perf).
- Lineage records: tier-A0 schema-overlay effects (`widenTo`, `newDefault`,
  `suppressValidator`), tier-A row ops, tier-B bulk-rule matches (named by their rule
  label), tier-A list/map deltas (including `replace_oldvalue` / `replace_newvalue`
  pairs), and tier-C processor writes — each cell can name the package + file + row
  responsible for its final value.
- Reformatter learns to emit a merged copy on demand (`--export-merged`).

**Phase 7 — Recompute downstream `=expr` cells when their dependencies are patched.**

- Static dependency analysis on `=expr` cells (extension of `canProcessCell`).
- Marks dirty, re-evaluates after patches.
- The hardest phase and the most valuable for "the original devs didn't think of this"
  cases. Worth doing eventually.

All phases are independently shippable. The natural cut points: stop after Phase 1 for
"loosen-only" mod support; stop after Phase 2 for explicit declarative patches; stop
after Phase 4 for the full declarative tier-A/B surface; Phases 5–7 are
expressiveness/observability/performance refinements.

---

## 10. Open questions

1. Should the patch file's header be required to match the parent's header order/columns,
   or can it be any subset? **Lean: any subset.** Less friction for modders. The patch
   executor must look up each patch column by name in the parent's header.

2. Patch files and joined files (`joinInto`) are both ways a child file references a parent
   file. Should one file be allowed to be both? **Lean: no.** A patch *modifies*, a join
   *adds columns*. Different semantics. Forbid the combination; document that "to add
   columns, use join; to change cells, use patch".

3. Should we reuse `setCell` (from `processor_executor`) under the hood for patch
   application? **Yes.** Tier A is "declarative patches that compile to a sequence of
   setCell/addRow/removeRow calls". This keeps the validation, re-serialisation, and
   error paths in one place.

4. How does diffing work across patched data? TabuLua already has `tsv_diff.lua`. A patch
   file is itself a TSV, so diffing patches between mod versions is free. Diffing the
   *effect* of patches on parent files needs `--export-merged` from Phase 6.

5. Should patch ops include a `cog`-like construct (programmatically generate many add
   rows)? **Yes, but for free** — COG already exists and works in any file. A patch file
   can contain COG blocks generating `add` rows just like any other file. The only thing
   to check is that COG-generated `add` rows are still bound by the duplicate-key rule.

---

## 11. Risks & alternatives considered

- **"Just fork the parent files."** Considered and rejected: makes upgrades to the parent
  package nearly impossible. The whole point of a mod system is non-invasive overlays.

- **"Patch language is too declarative; just use pre-processors for everything."** Tier C
  alone *could* technically do everything. But declarative tier-A/B patches are
  inspectable as plain TSV rows, reviewable in PRs, and diffable across mod versions.
  Pre-processor expressions are opaque. The tiers complement each other.

- **"What about a JSON-Patch-style operation list?"** Considered. TSV-row-per-op fits
  TabuLua's grain better than nesting structured operation objects in cells.

- **Performance.** Patches add an O(N×M) pass where N = patch rows, M = target file rows
  in the worst case (full-file filter). For typical mod sizes this is trivial. The
  patch-lineage tracking in Phase 6 is the only feature with non-trivial memory cost,
  and it's opt-in.

- **Round-trip drift.** Already handled by section 7.1 — overlays and patches are not
  baked into parents on reformat.

---

## 12. Relationship to existing TODOs

- This document **subsumes** the "feature #2 — append rows to parent package file"
  prerequisite noted in [pre_processors.md](pre_processors.md). Phase 2 alone delivers
  that prerequisite.

- The `graph_node` / `tree_node` built-in mentioned in `pre_processors.md` becomes
  cleanly implementable once Phase 2 + Phase 5 are in place: a child package can append
  graph nodes (`patchOp=add` rows in a patch file targeting the parent's graph file), and a
  package-scoped pre-processor can recompute back-references across the merged graph.
