# TabuLua Modding Guide

How to build a **mod** — a package that changes another package's data without
forking it — and how to run many mods from many authors together. This page maps
use-cases to features; the authoritative reference for every mechanism is
[DATA_FORMAT_README.md](DATA_FORMAT_README.md) (especially its *Mod Overrides*
chapter), and the diagnostic tools live in [REFORMATTER.md](REFORMATTER.md).

The same machinery serves any layered-data setup: mod-on-game, regional config
over base config, a customer tenant over product defaults. "Mod" below means
"child package".

## How modding works

- **A mod is an ordinary package**: a directory (or zip) with a
  `Manifest.transposed.tsv` and a `Files.tsv`. There is no separate mod format.
- **Overrides are ordinary TSV files in the mod's own package**, marked by a
  `Files.tsv` column (`patchOf`, `bulkPatchOf`, `schemaOverlayOf`). The parent
  package is never edited — and never *written*: the reformatter refuses to bake
  override effects back into parent sources (the **no-bake invariant**), so the
  parent stays byte-identical and upgradable.
- **Package load order decides everything**, and it is fully deterministic:
  `dependencies` / `load_after` edges dominate; unrelated packages load in the
  order their root directories were passed on the command line, then by
  alphabetical `package_id`. Later writers win. A launcher or mod manager
  reorders independent mods simply by reordering their directory arguments.
- Overrides apply **after** parsing and **before** validators, so validators and
  every export see the merged state.

## Use-case → feature map

| I want to… | Use | Reference |
|------------|-----|-----------|
| Change cell values / add / remove specific rows | row patch (`patchOf` + `patchOp`) | *Row Patches* |
| Edit or drop **many rows** chosen by a condition | bulk patch (`bulkPatchOf` + `where`) | *Bulk Patches* |
| Merge into a list/map cell instead of replacing it | delta companion columns (`append_<col>`, …) | *List and Map Cell Deltas* |
| Allow values the parent's schema rejects | schema overlay (`widenTo` / `newDefault` / `suppressValidator`) | *Schema Overlays* |
| Add **columns** to another package's rows | the side-table idiom (below) | this page |
| Activate content only when another mod is installed | `onlyIfPackages` + `load_after` | *Conditional Files* |
| Branch an expression/validator on another mod | `packages` context + `versionSatisfies` | *Detecting Other Packages* |
| Support several versions of the target | `ifMissing` | *Tolerating Missing Targets* |
| Require another package (with a version range) | manifest `dependencies` | *Manifest Fields* |
| Order after a package that may not be installed | manifest `load_after` | *Manifest Fields* |
| Refuse to run alongside an incompatible mod | manifest `conflicts` | *Manifest Fields* |
| Change data programmatically | package pre-processors | *Package-Scoped Pre-Processors* |
| See who set a value, or where mods fight | `--explain-patch`, `--check-conflicts`, `--export-merged` | REFORMATTER.md |

## The core recipes

### Change another package's rows

Declare a patch file in your `Files.tsv` and write ordinary TSV rows keyed by
the parent's primary key:

```tsv
fileName:filepath	typeName:type_spec	patchOf:filepath|nil	loadOrder:number
ItemPatch.tsv	patch	Item.tsv	1
```

```tsv
name:name	patchOp:patch_op	price:gold|int|nil	append_tags:{name}|nil
sword	update	150	"discounted"
oldSword	remove
laserSword	add	999
```

`update` edits named cells (empty = leave unchanged, `=nil` clears), `add`
inserts (existing key = error), `remove` deletes, `replace` upserts wholesale.
For collection cells, the `append_` / `prepend_` / `remove_` /
`replace_oldvalue_`+`replace_newvalue_` companions **merge** instead of
replacing — several mods appending to one list compose cleanly.

For condition-driven edits ("all Epic items +100 gold"), use a **bulk patch**:
a `where:expression` selects the rows, the remaining columns transform them.

### Loosen the parent's schema first when needed

A patch value is re-validated against the **parent's** column type. To set a
value the parent would reject (say a negative price on a `gold` column), ship a
**schema overlay** alongside the patch: `widenTo` a strictly wider type, set a
`newDefault`, or suppress/downgrade a parent validator. Overlays can only
*loosen* — every parent row that parsed before still parses.

### Add columns: the side-table idiom

Mods cannot inject new columns into a parent's file (a column is schema, and
schema changes would break every other consumer's expectations). The supported
pattern is a **side table**: ship your own file keyed by the *parent's* primary
key values, and let consumers join at read time.

```tsv
fileName:filepath	typeName:type_spec	loadOrder:number
ItemGlow.tsv	ItemGlow	1
```

```tsv
name:name	glowColor:name	glowRadius:float
sword	blue	1.5
torch	orange	4.0
```

Expressions, validators, and processors read across files with the standard
helpers — a dataset is PK-indexed, so `files['itemglow.tsv'][self.name]` is an
O(1) join, and `lookup(files['itemglow.tsv'], 'glowColor', 'blue')` searches by
any column — and the side table exports as its own file. Rows for keys the parent doesn't have can be caught by a file validator
if you want referential integrity. (The `joinInto` column merges files at
export within a package's own file set; cross-package column injection is
deliberately not a feature.)

### Optional compatibility (react to another mod)

To adjust to another mod *if present* without requiring it, pair the two
halves of a soft dependency:

- **Presence**: gate the compat rows with `onlyIfPackages` — when any listed
  package is absent, the file is skipped entirely (not parsed, not exported,
  no "patch target not found", no on-disk-existence requirement). A row with
  this condition is called *gated*, and each package id it lists is a
  *gate id* — the terms the diagnostics use.
- **Ordering**: add the other mod to your manifest's `load_after` — a no-op
  when it is absent.

```tsv
fileName:filepath	typeName:type_spec	patchOf:filepath|nil	onlyIfPackages:{package_id}|nil	loadOrder:number
MagicCompat.tsv	patch	Spell.tsv	"other.magic.mod"	5
```

Inside expressions (`=expr` cells, validators, `where` selectors), the
read-only `packages` context answers the same question with version detail:

```lua
=packages['other.magic.mod'] ~= nil and 2.5 or 1.0
=versionSatisfies('>=', '2.0.0', packages['other.magic.mod'].version)
```

Watch for typos: a misspelled gate id is silently "absent" forever. The skip is
info-logged, and `--check-conflicts` flags gate ids that match no known package
(with a did-you-mean when a known id is a close spelling match).

### Tolerate version drift in the target

A compat patch that supports base-game 1.x *and* 2.x — where a row or a whole
file exists in one version only — sets `ifMissing` on its `Files.tsv` row:
`warn` (logged no-op per miss) or `silent`. `add` on an existing key stays an
error under every policy. Rule of thumb: `onlyIfPackages` gates on *presence*,
`ifMissing` tolerates *version drift within presence*.

### Hard requirements and hard incompatibilities

- `dependencies` (manifest): the named package must be loaded and satisfy the
  version constraint (`>=`, `~`, `^`, …), or the load fails.
- `conflicts` (manifest): loading both packages together fails with an explicit
  error naming both sides — for combinations that must not compose (two total
  overhauls). Either side declaring it is enough.

### When declarative isn't enough

A manifest-declared **package-scoped pre-processor** runs sandboxed Lua over
the fully merged state (after all patches, before validators), with write
access scoped to files the package owns or declares patches for. Use it for
computed cross-row changes no patch can express.

## Mods building on mods

A mod's files — including rows its patches **added** to a parent — are ordinary
targets for every later mod. Mod C can patch a row mod B added, append to a
list B created, or overlay a file B ships; it declares `load_after: {"b.id"}`
(or `dependencies` for a hard requirement) and targets the file normally.
There is one deliberate exception: a patch **document** is not itself a
patchable target — mods layer on the merged *result*, not on each other's
patch files.

When two loaded packages ship the same file name, an unqualified target
resolves deterministically (alphabetically-first) with a warning; bind it
explicitly with the package-qualified form — `patchOf=some.mod:Shared.tsv`,
declared as `patchOf:override_target|nil` (see *Targeting a Parent File*).

## Debugging a mod setup

All three are reformatter flags; none requires an export
(see [REFORMATTER.md](REFORMATTER.md) for full syntax and sample output):

- **`--explain-patch[=<file>[:<pk>[:<col>]]]`** — provenance: every override
  write as an apply-order chain, attributed as `package.id:File.tsv` (or
  `package:<id>` for processors). Start here for "why is this value X?".
- **`--check-conflicts`** — just the fights: cells, rows, and column defaults
  where a later mod discarded an earlier mod's work, plus the
  `onlyIfPackages` typo check. Benign composition (deltas, `widenTo` unions,
  patching a row another mod added) is not flagged. Conflicts are legal —
  load order decides — so this never fails the run; to change a winner,
  reorder the input roots or add `load_after`.
- **`--export-merged[=<dir>]`** — the final merged data as a diffable TSV
  tree, byte-identical to the sources where nothing changed.

## Mod author checklist

1. One package per mod; pick a collision-proof `package_id`
   (`author.modname` style — ids are compared case-sensitively).
2. Declare every package you patch: `dependencies` if required (with a version
   range), `load_after` + `onlyIfPackages` if optional.
3. Patch, don't fork: prefer `patchOf` / `bulkPatchOf` / `schemaOverlayOf`
   rows over copies of parent files; prefer delta companions over whole-list
   replacement (they compose with other mods).
4. New content goes in your own files: new rows via `patchOp=add`, new
   columns via a side table keyed by the parent's PK.
5. Supporting several target versions? Set `ifMissing=warn` on the compat
   file — and check the log.
6. Before shipping, run `--check-conflicts` with the mods you intend to
   compose with, and `--export-merged` to eyeball the final data.
