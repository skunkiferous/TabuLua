# Complex Values in the JSON Transcoders — `json-natural` by default, optional `:typed`

## Summary

The three JSON `transcode` stages — `json:objects`, `json:rows`, `json:columns`
([json_transcoders.lua](../json_transcoders.lua)) — currently accept only **simple
scalar** cell values. Any composite (a JSON object or array sitting in a cell
position) is rejected outright by `valueToCell`:

```lua
elseif type(v) == "table" then
    return nil, "composite value, which is not supported yet"
```

This plan lifts that restriction so a cell may itself be a table-typed value
(`{string}`, a tuple `{int,int}`, `{int:Foo}`, a nested record, …), matching the
column's declared type. The bare ids *become* the **`json-natural`** stages
(conventional JSON, the same shape `exportNaturalJSON` emits), and a parallel
**`:typed`** family (`json:objects:typed`, …) is added for **symmetry with export**
and for the cases `json-natural` cannot represent losslessly.

**What `:typed` is actually for (corrected).** JSON objects only have string keys,
so json-natural can only render a map as `{ "key": value }`. `:typed` exists to
preserve **non-string keys**. Two sub-cases, neither of which is "a table-typed map
key as a *column type*" (that is forbidden outright — see D4):

- **Non-string scalar keys** in typed maps — `map<integer,…>`, `map<boolean,…>`,
  `map<enum,…>` (see the [serialization.lua](../serialization.lua#L364) comment).
  **Natural now handles these fully**, including numeric-looking string keys,
  because reconstruction is type-directed (D6) — so `:typed` offers *no* advantage
  here. JSON stringifies the key; the key type's own parser rebuilds it.
- **Table keys at the value level** inside an untyped `table`/`raw`/`any` column
  (the type does not constrain keys). Natural stringifies such a key irrecoverably;
  `:typed` preserves it. This is the **only** remaining `:typed` advantage, and it
  only matters for `:typed` *input* and export round-trips — a table key cannot
  arrive via natural JSON (object keys are strings).

## Background — the architecture this rides on

A transcoder does **not** produce parsed values; it produces **TSV text** that the
normal loader then types and validates. So supporting a complex cell means: turn
the JSON substructure into TabuLua's **native, brace-less cell text** (what the
map/array/tuple/record parsers consume), and let the existing type machinery do
the rest. Column **names, types and order** still come from the file's `typeName`
schema (`schemaHeader`, [json_transcoders.lua](../json_transcoders.lua#L53)), never
from the JSON — unchanged.

The building blocks already exist and are already wired together in the **other**
JSON path, the reformatter's round-trip importer
([importer.lua](../importer.lua)):

- `deserializeNaturalJSON(jsonStr)` → Lua value (natural; lossy on complex keys)
- `deserializeJSON(jsonStr)` → Lua value (typed; exact)
  ([deserialization.lua](../deserialization.lua))
- `serializeTableWithoutCB(luaValue)` → native brace-less cell text
  ([parsers/utils.lua](../parsers/utils.lua#L24)); the column parser later wraps it
  in `{}` and evaluates it via `ltcn` ([table_parsing.lua](../table_parsing.lua#L82)).

`importer.lua` already does exactly `deserializer(dkjson.encode(subValue))` to go
from an already-decoded sub-table to a reconstructed value
([importer.lua](../importer.lua#L97)). This plan reuses that proven pattern inside
the transcoders.

## Design decisions

### D1 — Conversion path: substructure → native cell text → existing parser

For a composite cell value `v` (already a Lua table from `dkjson.decode`):
`deserializer(dkjson.encode(v))` → Lua value → `serializeTableWithoutCB` → native
cell text. The column's own parser then performs final typing **and validation**,
so the transcoder does **not** need to type-direct the reconstruction itself. This
keeps the change tiny and makes type mismatches (a JSON object landing in an `int`
column) fail through the normal `badVal` path.

### D2 — One chokepoint, parametrised by the deserializer

All three layouts funnel every cell through `valueToCell`. We change **only**
`valueToCell`, threading in a `tableDeserializer`. Natural passes
`deserializeNaturalJSON`; `:typed` passes `deserializeJSON`. Because the stage
signature `(name, content, env, badVal, ctx)` is fixed by the content pipeline, the
six stage functions are produced by **three factories**, each closing over a
deserializer (no copy-paste of the objects/rows/columns logic).

### D3 — Two stages per layout: bare id = natural (default), `:typed` = alternative

**Decided.** The bare ids `json:objects` / `json:rows` / `json:columns` *become*
the **`json-natural`** stages — natural handles both simple and complex values, so
the old "simple-values-only" semantics are **dropped entirely** (no behaviour to
preserve; the format shipped only in 0.24.0 with no complex data yet). There is
**no `:natural` suffix** — it would redundantly repeat what the bare id already
means, and the `json:` prefix already says "JSON". The typed variant takes the one
obvious name `json:objects:typed` (etc.), mirroring the export side's
`json-typed` / `json-natural` pairing. So per layout there are exactly two stages:
`json:objects` (natural) and `json:objects:typed`.

### D4 — Table-typed map keys: the type system already rejects them (no guard)

**Decided + revised during implementation.** The intent was for natural mode to
hard-error on a column whose type has a table-typed map key. Implementation
revealed this needs **no transcoder code at all**: the type parser itself refuses
to build such a type — `parseType("{{integer,integer}:string}")` fails with
*"map key_type can never be a table"*, and a record containing such a field fails
with *"field type is invalid"*. So the type can never register, `recordFieldTypes`
returns nil, and `schemaHeader` aborts the file with its standard *"is not a known
record type"* message before any value is parsed — exactly the "don't even try"
behaviour, for free.

A complex key also cannot *arrive* via natural JSON regardless: JSON object keys
are always strings. The originally-planned recursive `mapKVType` guard was both
unnecessary and unworkable (`mapKVType` returns nil for a table-keyed map), so it
was **removed**. The pointer-to-`:typed` message is also dropped: a table-keyed
map type won't parse for `:typed` either, so there is nothing to redirect to.

### D5 — Non-round-trippable values: flag every one, but carry on

**Decided.** A value that cannot survive a JSON round-trip — concretely, a
**non-finite number** (`NaN`/±`Inf`; reachable only via `1e999`-style overflow,
since `dkjson.decode` rejects the `NaN`/`Infinity` tokens) — is reported via
`badVal` **but does not abort the file**. The walk continues and **every**
offending value is flagged (recursively, including numbers nested inside composite
cells), so the author sees the full list to fix in one pass rather than one error
at a time. The stage still returns its best-effort TSV text. This is mechanically
sound: `runTranscode` only treats a `nil` return as failure
([content_pipeline.lua](../content_pipeline.lua#L616)), so a transform may call
`badVal` any number of times and still emit output.

This is enforced **JSON-side** (in the transcoder walk), never in
`state.PARSERS.number`: a global guard would also reject the legitimate
native/`ltcn` table-interior round-trip of `(0/0)`/`(1/0)` and change non-JSON
input formats. Structural problems (malformed JSON, non-object element, arity
mismatch) keep their current **abort** behaviour — only fidelity issues are
flag-and-continue.

### D6 — Type-directed reconstruction (implemented, was deferred)

**Decided + implemented in Phase 1.** Natural reconstruction is **type-directed**:
`reconstructTyped(v, fieldType)` walks the decoded value alongside the column's
declared type. The decisive case is **map keys** — each is rebuilt with the *key
type's own parser* (`parseType(keyType)`), so the key's Lua type matches what the
map parser requires: a `map<string,…>` key `"01"` stays the string `"01"`, a
`map<integer,…>` key `"1"` becomes the number `1`. It recurses through
maps/arrays/tuples/records (typing keys correctly *per depth*), sees through a
nullable container (`{K:V}|nil`) via `containerType`, interprets the special-float
sentinels **only** in a numeric leaf (`isNumericType`), and falls back to the
type-blind `processNaturalValue` for untyped (`table`/`raw`) or ambiguous-union
slots where there is no key type to honour.

This was originally deferred, but the type-blind baseline **mis-handled valid
`map<string,…>` data with numeric-looking keys** (it coerced the key, then the
string-keyed map rejected it) — a real defect, so D6 was pulled forward.

## Limitations (to document)

- **Table-typed map keys are unrepresentable as a column type (D4).** The type
  parser rejects them outright (*"map key_type can never be a table"*), so neither
  natural nor `:typed` can have such a column — the file aborts at schema
  resolution. (Table keys still exist at the *value* level inside an untyped
  `table`/`raw` column, but cannot arrive via natural JSON, whose object keys are
  always strings.)
- **Map keys of every kind round-trip in natural (D6).** Type-directed
  reconstruction rebuilds each key with the key type's parser, so `map<integer,…>`,
  `map<boolean,…>`, and `map<string,…>` (including numeric-looking string keys like
  `"01"`/`"1"`) all round-trip correctly, at any nesting depth. The old ambiguity
  (a numeric-looking *string* key) is gone, as is the `"NAN"`-in-a-string-slot
  misread (sentinels are interpreted only in numeric slots). The one remaining
  natural-only gap is **value-level table keys in an untyped `table`/`raw` column**,
  which cannot arrive via natural JSON anyway (JSON object keys are strings) — that
  is `:typed`-input territory.
- **NaN/±Inf are not JSON.** Reachable only via `1e999` overflow; flagged per D5.
  Inside a `:typed` table they arrive as the `"NAN"`/`"INF"` sentinels and
  reconstruct, but a bare scalar numeric cell cannot carry them (no valid token).
- **64-bit integers** round-trip exactly on the native-integer Lua build (verified:
  Lua 5.4 + dkjson preserve `INT64_MAX` and `2^53+1`); on a non-native-integer
  build (5.1/LuaJIT) all JSON numbers are doubles and lose precision above `2^53`.

## Backward compatibility

Strictly additive. Composite cells are a **hard error today**, so no currently
passing file contains one — the change can only turn previously-failing inputs into
successes. Scalar cells stay on their exact current path (and `json-natural` is the
identity on scalars). The format published in 0.24.0 has no table-JSON data in the
wild yet, so only tests need updating.

## Implementation phases (per-phase commit)

### Phase 1 — `json-natural` complex values (the default) — DONE

1. ✅ Three layout factories (`makeTranscoder(body, reconstruct)`); bare `json:*`
   ids instantiated with the type-directed natural codec (`reconstructTyped`).
2. ✅ No complex-key guard — D4 is handled by the type parser itself (see D4).
3. ✅ `valueToCell(v, fieldType, reconstruct, flag, where)`:
   - `type(v)=="table"` → `toCellText(reconstruct(v, fieldType))` (native
     brace-less text), with `pcall`/error plumbing, replacing the rejection;
   - **non-finite number** at any depth → `flag(...)` and **continue** (D5);
   - scalar/`null`/missing → unchanged.
4. ✅ Type-directed reconstruction (D6): map keys via the key type's parser,
   recursion through maps/arrays/tuples/records, nullable-container unwrap,
   numeric-only sentinels; `processNaturalValue` extracted in
   [deserialization.lua](../deserialization.lua) for the untyped/union fallback.
5. ✅ Tests: `spec/json_complex_values_spec.lua` (arrays, maps, tuples, nested
   records across all three layouts; non-string + numeric-looking-string keys;
   nested per-depth key typing; nullable containers; D4 type rejection; D5
   flag-and-continue).
6. ⏳ Docs: module header done; `DATA_FORMAT_README.md` still to update.

### Phase 2 — `:typed` family (symmetry with export)

1. Add a typed codec `(v, _fieldType) -> deserializeJSON(dkjson.encode(v))` and
   instantiate the same three factories with it; register `json:objects:typed`,
   `json:rows:typed`, `json:columns:typed` in
   [builtin_content_stages.lua](../builtin_content_stages.lua#L146) (same shape as
   the natural ids; `inputExtensions={"json"}` guard, no matcher).
2. Tests: a typed round-trip of a value natural cannot carry — a **table-keyed map
   in an untyped `table`/`raw` column** — proving `:typed` preserves the table key
   where natural cannot express it.
3. Docs: note the pairing with `exportNaturalJSON` / `exportJSON`.

### Phase 3 — none required

D6 (type-directed reconstruction) was pulled into Phase 1, so the previously-listed
deferred work is done. No further phase is needed for natural.

## Resolved decisions

1. **Naming** — bare id = natural, `json:objects:typed` for typed; no `:natural`
   suffix, no simple-only stage. (D3)
2. **Complex keys in the type-spec** — hard error, don't attempt to parse. Found
   during implementation to be enforced by the type parser itself ("map key_type
   can never be a table"), so no transcoder guard was needed. (D4)
3. **Non-round-trippable values** — flag every one via `badVal` (recursively) but
   carry on and still emit output, so the author fixes them all in one pass. (D5)
4. **Type-directed reconstruction** — pulled forward from "deferred" into Phase 1
   after it was found that type-blind key coercion broke valid `map<string,…>`
   data with numeric-looking keys. Map keys are rebuilt with the key type's parser;
   sentinels are interpreted only in numeric slots. (D6)
