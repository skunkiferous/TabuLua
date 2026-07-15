# Shaped string types — a string that is validated (and canonicalized) as a table

## Status

**Phases 1, 3 & 4 landed (2026-07-14). Phase 2 (the read-back sandbox helper) is the
only one open.** Gate green: 3233 tests, 38/38 bad-input fixtures.

Phase 1 flushed out three prerequisite bugs (below). Phase 3 — the round-trip proof —
flushed out a fourth, smaller one and confirmed the core claim held:

- **The claim survived.** A `{Coord:string}` map round-trips through **every** format:
  native TSV (ltcn reads `["1,2"]=v` straight back), typed JSON, natural JSON, XML and
  SQL, plus the full `manifest_loader` → `reformatter` → reload cycle, which also
  canonicalizes a non-canonical `["1, 2"]` to `["1,2"]` in the file and is stable on a
  second pass. All because a shaped key is only ever a **string** to the serializers.
  Covered in `spec/shaped_types_round_trip_spec.lua`.
- **Bug 4 (fixed): shaped types were not idempotent on re-registration.** Every other
  custom-type kind tolerates an identical re-declaration (expression types via
  `EXPR_VALIDATORS`, string/number types via their generated-name cache, aliases
  directly), but `restrictWithShape` registered the user name straight through
  `extendParser`, which rejects a reused name. So loading a package that declares a
  shaped type *twice in one process* (load, then reload — exactly what a round-trip test
  does) failed on the second pass. Fixed with a `SHAPE_TYPES` registry mirroring
  `EXPR_VALIDATORS`: identical re-registration is a no-op, a conflicting one is a clear
  error. (Added to `MUTABLE_TABLES`, so the global-reset snapshot covers it.)
- **A natural-JSON limitation, documented not fixed.** Natural JSON has no key type, so
  a foreign reader coerces a numeric-looking object key back to a number. A `Coord` key
  (`"1,2"`) is never numeric-looking, so it survives; but a *single-scalar* shape whose
  canonical form is a bare number (e.g. `{integer}` → `"5"`) would be read back as `5`
  by a naive consumer. TabuLua's own type-directed reimport keeps it exact (it knows the
  key is a `Coord`); this is the same known natural-JSON key issue as
  `json_complex_values.md`, not a shaped-types bug.

### The three prerequisite bugs Phase 1 flushed out

The feature itself went in as designed — `shape` field, `restrictWithShape`,
canonicalization, one new dispatch branch, no grammar change. What it *cost* was
three pre-existing bugs, none of them obvious until a shaped type leaned on them:

1. **No user-defined type could be a map key** (`NEVER_TABLE` was never set for
   derived types, so `{Code:integer}` was refused with "map key_type can never be a
   table" — about a *string*). A hard prerequisite: a shaped type that cannot key a
   map is pointless. Fixed by inheriting the flag in `doTypeParamsUpdate`.
2. **A tuple cell with too many elements crashed the load** (`fields_parsers[i]`
   indexed past the end → `parser is nil` inside `callParser`). Fixed to report the
   bad cell. The *missing*-element half of that hole (a `{integer,integer}` happily
   accepts `1`) was left alone by decision — see Decisions below.
3. **A `pattern`-only custom string type could not be registered at all**
   (`restrictString` asked `rangeToIdentifier` to name a range that wasn't there, and
   failed with "min and max cannot both be nil" about numbers nobody wrote).

And one design decision the tests forced, rather than the plan:

- **A key collision is an error, not a last-wins.** The first draft let two spellings
   of a key collapse silently. The spec caught that `pairs()` decides *which* value
   survives — so the same file could load differently between runs. The map parser now
   rejects a duplicate key, as the record parser already did for a duplicate field.
   This is the one shared-container change; it fires only when two *distinct* raw keys
   parse to the same key, which no existing data does (the gate is green).

## Summary

A **shaped string type** is a custom type whose values are **strings at runtime**, but
whose text must parse as a given **table type**. Declared entirely in data:

```
name:name	parent:type_spec|nil	shape:type_spec|nil
Coord	string	{integer,integer}
Rect	string	{x:integer,y:integer,w:integer,h:integer}
```

A `Coord` cell holds `1,2`. It is a string — so it sorts, exports, and (the point)
**works as a map key**: `{ Coord : Item }` is a legal column type, and the native cell
`["1,2"]=Sword` is something every reader in the pipeline can already read back.

This is the practical answer to [tables_as_keys.md](tables_as_keys.md). That doc's
Option B was "canonical-string key encoding", costed as *medium-high, touches the type
core, and doesn't fix natural JSON". Confining the same idea to a **declared type**
instead of retrofitting it onto every table changes the economics completely: the type
core, `ltcn`, the JSON layouts, the XML form, the SQL export and the four serializers
all need **zero** changes, because a shaped value is only ever a string to them.

**No type-spec grammar change.** The shape is a `type_spec` in a *cell*, which
`custom_type_def` already does for its `parent` field. It never appears in a column
header, so the header grammar is untouched.

## Why canonicalization is the whole trick

The shape parser hands back a *reformatted* canonical text alongside the parsed table.
We store **that** as the value, not what the author typed. So `1, 2` and `1,2` both
become the string `1,2`.

Which lands exactly on reason 3 of tables_as_keys — the one that doc called a
language-level constraint we cannot fix:

> Lua compares table keys by **identity (reference)**, not by **structure**. […]
> content-addressed table keys are semantically meaningless in stock Lua without a
> custom equality layer.

Lua compares *strings* by value, and interns them. Two structurally-equal canonical
keys **are the same key**, in stock Lua, with no interning layer of ours. The
canonicalization step is what turns "a string that looks like a table" into a genuine
value-semantics key; without it, `1, 2` and `1,2` would be two different map entries
that look identical to a reader.

Corollary: canonicalization is **not optional** in this design. (Decided 2026-07-14.)

## Design

### The field

One new `custom_type_def` field, `shape:type_spec|nil`
([parsers/builtin.lua](../parsers/builtin.lua), the `custom_type_def` alias), and one
new branch in [`registerTypesFromSpec`](../parsers/registration.lua) — whose dispatch
is already a closed set of constraint kinds (`min/max` → `restrictNumber`,
`minLen/maxLen/pattern` → `restrictString`, `values` → `restrictEnum`, `validate` →
`restrictWithExpression`, `members` → tag). `shape` is a **sixth kind**, and follows
the existing one-constraint-kind-per-type rule. Both declaration paths (a manifest
`custom_types` entry and a `custom_type_def` file) go through that one function, so
both light up at once.

To compose a shape with a further check, declare a second type whose `parent` is the
first — which already works — rather than relaxing the exclusivity rule.

### The parser: `restrictWithShape(badVal, parentName, newName, shapeSpec)`

Built on `extendParser` (the parent parser runs first, then ours), in
[parsers/registration.lua](../parsers/registration.lua):

1. **At registration** (once, not per cell): `parseType` the shape to get its parser.
   Validate that the parent `typeSameOrExtends(parent, "string")` — same guard
   `minLen`/`pattern` use — and that the shape really is a table type
   (`not isNeverTable(shape)`), so `shape=integer` is refused with a clear message
   rather than silently doing nothing.
2. **Per cell**: the parent (string) parser yields the raw text. Trial-parse that text
   with the shape parser against the shared silent `nullBadVal`, saving and restoring
   its error count — the idiom the **union parser** already uses
   ([parsers/generators.lua](../parsers/generators.lua), `get_union_parser`), so a
   failed trial does not pollute the real error count.
3. On failure: one error on the real `badVal` — `does not match shape
   {integer,integer}` — not the shape parser's inner complaints.
4. On success: return the shape parser's **reformatted** text as both the parsed value
   and the reformatted value. That text is the brace-less canonical form
   (`serializeTableWithoutCB`), which is exactly the cell convention.

`extendParser` already registers the `extends string` relation and inherits the string
comparator, so schema export, SQL typing, sorting and the `NEVER_TABLE` bookkeeping all
follow for free.

### What we deliberately do NOT do

- Not a new *kind* of value. The parsed value is a `string`, full stop. Nothing
  downstream learns a new type, which is why the blast radius is small.
- Not `FORCE_REFORMATTED_AS_STRING`. That flag is for the *opposite* case (a non-string
  parsed value that reformats as a string, e.g. `cmp_version`). A shaped value is
  already a string, so `quoteIfNeeded` does the right thing, and `serializeTable`
  quotes a non-identifier string key by itself — which is what makes `["1,2"]=v`
  round-trip through `ltcn`'s `Key = Number + String + Boolean`.

## Phases

### Phase 1 — the type ✅ **done** (registration + parser + canonicalization)

`shape` field (`custom_type_def`, the manifest tuple form, `builtin_wiring`'s field
list), `restrictWithShape`, dispatch branch, registration-time guards, and the
shape's own strict completeness check. Specs in `spec/parsers_shaped_types_spec.lua`,
plus regressions for the three bugs above in the tuple / map / custom-type specs.

One thing worth knowing: a shaped type validates *strictly* — missing elements and
fields are rejected — while the containers it delegates to do **not**. That is
deliberate (see Decisions), not an inconsistency to "fix" by loosening the shape.

### Phase 2 — reaching the table from an expression (the one open phase)

The value is a string by construction, so an `=expr` cell, a validator or a
pre-processor that wants the structured form needs a way back: a sandbox helper (working
name `asShape(v)` / `shapeOf(v)`) registered through the type-wiring registry's
`sandboxHelpers`. It reads the column's declared shape, parses the string, returns the
table. Read-only — writing back means writing the canonical string. Deferred until a
concrete use case, like every other `sandboxHelpers` addition. Until then the value is
usable as a *key* and as opaque text, which is the headline use case; only *computing on
its parts inside an expression* needs this.

### Phase 3 — the payoff, as tests ✅ **done**

`spec/shaped_types_round_trip_spec.lua`, two layers: value-level serialize→deserialize
for native / typed JSON / natural JSON / XML (+ SQL embedding), and a full
`manifest_loader` → `reformatter` → reload cycle on a `{Coord:string}` column. Proves
the string key survives every format, that a non-canonical key is rewritten canonical in
the file, and that reload is clean and reformat-stable. Findings folded into Status:
the idempotency fix (bug 4) and the documented natural-JSON coercion edge. One testing
gotcha worth knowing: a loaded cell is a **read-only proxy**, reachable by key but not
by `next`/`pairs`, so key-type assertions must `unwrap` first.

### Phase 4 — docs ✅ **done**

`DATA_FORMAT_README.md` — new "Shaped String Types" section, the `shape` row in the
custom-type field table, the sixth constraint kind, and a *"what to do instead"* pointer
from "Tables Are Not Valid Map Keys", which until now only said *don't*. CHANGELOG has
the feature under Added and the three bugs (plus the duplicate-key change) under Fixed.

## Decisions

- **Canonicalize on load** (2026-07-14, user). Not optional: it is what gives a shaped
  key value-semantics. The reformatter will therefore rewrite `1, 2` as `1,2` in the
  author's file, exactly as it already does for every other container cell.
- **Fix the tuple *crash*, not the tuple *laxness*** (2026-07-14, user). A cell with too
  many elements is now a reported error rather than a crash, but a cell with too *few*
  is still silently accepted, in tuples and records alike. Shaped types therefore check
  their own completeness instead of relying on the container. The lax-arity hole remains
  open — it affects every tuple and record column, and deserves its own decision, since
  closing it would turn data that "passed" for years into errors.
- **A key collision is an error** (2026-07-14, forced by a test). See Status.
- **Identical re-registration is a no-op** (2026-07-14, forced by a Phase 3 test). Bug 4
  in Status: shaped types now match every other custom-type kind, which already tolerated
  it.

## Open questions

1. **Field name.** `shape` is the working name. Alternatives considered: `represents`,
   `encodes`, `structure`, `parses_as`. `shape` is short and reads well in a TSV.
2. **Ordering is lexicographic**, inherited from the string comparator — so `"10,2"`
   sorts before `"9,1"`. Deterministic and stable, but it will surprise someone who
   writes a `Coord` and expects numeric order. Documented as such for now; an opt-in
   shape-aware comparator stays possible, but one that parses every cell on every
   comparison is a bad trade.
3. **Should the shape be exported in the schema** (`parsers/schema_export.lua`)? It is
   real, checkable structure that a consumer of the schema would want. Cheap to add,
   but it is the one place the shape leaks outside the type system. Still open.
4. **Empty / degenerate shapes** — `shape={}` is currently *accepted* (`{}` is a table
   type, so the guard passes), giving a type whose only legal value is the empty
   string. Harmless, but almost certainly a typo when written. Refuse it? Still open.
5. **The error message names the internal parser, not the type.** A pattern- or
   length-restricted type reports as `string._RS_R_ANY_RE__0x5E...` rather than `Sku`,
   because `restrictString` pushes the *generated* name onto the col_types stack. This
   predates shapes (it is how every `restrictString` type has always reported) and is
   ugly enough to be worth its own small fix. Shaped types are unaffected — they report
   as `Coord`, because `restrictWithShape` registers under the declared name.

## Related

- [tables_as_keys.md](tables_as_keys.md) — why a real table key cannot work, and why
  this is Option B done in the one place it is cheap. Option A (serializers refuse a
  table key) landed 2026-07-14 and is what makes this the *only* way to key a map by a
  composite value.
- [type_wiring.md](type_wiring.md) — the registry Phase 2's sandbox helper hangs off.
