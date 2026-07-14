# Tables-as-Keys — why they are unsupported, and what it would take

## Status

**Option A landed (2026-07-14).** The asymmetry below is closed: all four serializers
now refuse a table key, so what we write, we can read. B and C remain future work,
behind a concrete use case. What was actually built:

- `rejectTableKey` in [serde/serialization.lua](../serde/serialization.lua), called from the key
  position of `serializeTable`, `serializeTableJSON`, `serializeTableXML` and (via
  `keyToString`) `serializeTableNaturalJSON`. `serializeSQL` inherits it, encoding
  its cells through those.
- **Reported, not raised.** A hard `error()` would abort the load with a traceback
  and no idea *which* cell was at fault. Such a value can only arrive from an
  `=expr` cell, a pre-processor or a transcoder — never from parsed file text
  (`ltcn` already rejects it) — and every one of those paths holds a `badVal`, so
  the refusal is funnelled through `utils.serializeParsedTable`
  ([parsers/utils.lua](../parsers/utils.lua)) and comes out as an ordinary bad-value
  report naming file, row and column. The four serializers still raise, for any
  caller that is not a parser.
- **Two things the plan below did not anticipate:**
  1. **`UNQUOTED_MT` keys had to stay legal.** `quoteIfNeeded` wraps every
     *non-string* value in `unquotedStr()` — a table carrying raw Lua text — and the
     map parser uses it for **keys** too. So every integer- or boolean-keyed map
     (`[3]=v`, `[true]=v`) reaches `serializeTable` with a "table" in the key
     position. A naive `type(k) == "table"` check broke four legitimate map
     round-trips. The wrapper is exempt; it can never carry a genuine table key,
     because a table is not a legal map *key type* in the first place.
  2. **`badVal` rendered its bad value with the very serializer being made strict**,
     unprotected — so the error reporter would have thrown while reporting. It now
     degrades to `<unserializable table: reason>`. That was a *pre-existing* latent
     bug: a recursive or too-deep table would already have crashed the reporter.
- Documented in `DATA_FORMAT_README.md` ("Tables Are Not Valid Map Keys"), CHANGELOG
  under Changed + Fixed. Full gate green (3200 tests, 38/38 bad-input fixtures).

## Summary

TabuLua does **not** support a *table* used as a **map key** — neither as a
declared column type (`{ {int,int} : Foo }`) nor as a value-level key that
survives a round-trip. This file records **why**, with the code that proves each
reason, and lays out the options if we ever decide to support it and which areas
would have to change.

Note the asymmetry that makes this a *trap* rather than a clean "not implemented":
the **serializer can write** a table key, but nothing in the pipeline can **read
it back**. So a naive enable would produce output that fails its own round-trip.

## The three reasons (verified)

### 1. `ltcn` — our native Lua-literal reader — cannot parse a table key

We read native cell text (the brace-form Lua-literal cells) with the `ltcn` safe
parser, not `load`/`eval` ([table_parsing.lua:82](../util/table_parsing.lua#L82)). Its
PEG grammar makes a table a legal **value** but **never a legal key**
([ltcn.lua], the installed rock — `C:\lua\systree\share\lua\5.4\ltcn.lua`):

```lua
Key   = T"Number" + T"String" + T"Boolean";          -- no V"Table"
Value = T"Number" + T"String" + T"Boolean" + V"Table";
IndexedField = Cg(symb"[" * V"Key" * symb"]" * symb"=" * V"Value");
```

So `[{1,2}]=x` cannot re-parse: `[` expects a `Key`, and `Key` excludes tables.
This is already called out in the parser's own contract:

> [table_parsing.lua:72](../util/table_parsing.lua#L72) — *"Does not support: tables
> as keys, nil values (use '' instead)."*

This is **not** an `ltcn` oversight we could fix by swapping in a fork: upstream
lists it under *"Features Not Implemented"* —

> *"Tables as keys (not useful without considerable extra functionality)."*

(upstream now at [gitlab.com/craigbarnes/ltcn](https://gitlab.com/craigbarnes/ltcn),
formerly [github.com/craigbarnes/ltcn](https://github.com/craigbarnes/ltcn)). A
fork-network check (June 2026) found only two forks —
[NirvanaNimbusa/ltcn](https://github.com/NirvanaNimbusa/ltcn) (a dead mirror, no
code change) and [tst2005/lua-table-parser](https://github.com/tst2005/lua-table-parser)
— and **neither adds table-key support**; tst2005 carries the *same* "Features Not
Implemented: Tables as keys" line. Note the upstream's own rationale ("not useful
without considerable extra functionality") is exactly **reason 3** below: a parsed
table key is useless without a value-equality / interning layer. So Option B must
add the capability on **our** parser path, not via `ltcn`.

**The asymmetry.** The *serializer* has no such guard. `serializeTable` emits any
non-identifier key via `[ serialize(k) ]= …`, and `serialize` recurses into a
table key, so it will happily produce `[{1,2}]=v`
([serialization.lua:186-191](../serde/serialization.lua#L186-L191)). That string is then
unreadable by `ltcn` — write succeeds, read fails. A table key is therefore not
"rejected early"; it silently breaks the round-trip.

### 2. The "natural" JSON format cannot represent a table key

JSON object keys are **always strings**. `serializeTableNaturalJSON` stringifies a
non-string key (a table key is recursively serialized to a JSON-ish string and
then `dkjson.encode`d as the object key —
[serialization.lua:456-458](../serde/serialization.lua#L456-L458),
[serialization.lua:520-522](../serde/serialization.lua#L520-L522)). On read,
`deserializeNaturalJSON` only ever sees a *string* key; there is no information to
rebuild the original table, and even a convention couldn't reconstruct one
losslessly. Natural JSON is the format we expect to be **commonly used as an
import/export interchange**, so this matters.

Our **`json:*:typed`** family is self-describing and *could* carry a structured
key in principle — but it still lowers to the same native cell text that `ltcn`
must read (reason 1), so it gains nothing here. See
[json_complex_values.md](json_complex_values.md) D4 and its Limitations section,
which reach the same conclusion: *"a table-valued key round-trips in neither
format (`ltcn` rejects table keys in a cell)."*

Relatedly, the **type system refuses a table-typed map key as a column type** at
schema-resolution time — the type parser breaks with *"map key_type can never be
a table"* ([parsers/type_parsing.lua:464-468](../parsers/type_parsing.lua#L464-L468),
gated by `isNeverTable` / `state.NEVER_TABLE`,
[parsers/introspection.lua:178](../parsers/introspection.lua#L178)). So
`{ {int,int} : Foo }` never even registers. (Table keys can still occur at the
*value* level inside an untyped `table`/`raw`/`any` column, which is exactly where
the silent round-trip break in reason 1 bites.)

### 3. Lua semantics — tables are entities, not values

Even if reasons 1 and 2 were solved, Lua compares table keys by **identity
(reference)**, not by **structure**. `t[{1,2}] = x` stores under *that specific
table object*; `t[{1,2}]` with a freshly-built `{1,2}` returns `nil`. So a table
key is only ever retrievable by holding the original reference — useless for
data that is parsed fresh on every load (every load builds new tables, so no
lookup by content would ever hit). This is a language-level constraint we cannot
fix; it also explains *why* reasons 1 & 2 are not merely missing features —
content-addressed table keys are semantically meaningless in stock Lua without a
custom equality layer.

## Options, if we ever support this

Ordered roughly by cost. None is free; (3) is the only one that yields *usable*
semantics.

### Option A — Fail loud instead of failing silently (cheapest; ✅ **done**, see Status)

Don't *support* table keys, but stop the asymmetric trap: make the serializer
**refuse** a table key the same way `ltcn` refuses to read one, so the failure is
immediate and symmetric.

- **Where:** `serializeTable` ([serialization.lua:186-191](../serde/serialization.lua#L186-L191))
  and its JSON/XML siblings (`serializeTableNaturalJSON`, `serializeTableJSON`,
  `serializeTableXML`) — detect `type(k) == "table"` in the key position and
  `error(...)` (or route through the active `badVal`) with a message pointing here.
- **Cost:** small, localized. **Risk:** a currently-"working" write (that was
  actually un-round-trippable) becomes a hard error — that's the point, but it is
  technically a behaviour change; gate behind a version bump.
- This is the natural complement to the existing read-side contract at
  [table_parsing.lua:72](../util/table_parsing.lua#L72).

### Option B — Canonical-string key encoding (round-trippable, but lossy semantics)

Encode a table key as a canonical **string** (e.g. its serialized native form) on
write, and decode that string back to a table on read, for the native + typed-JSON
paths only.

- **Where:**
  - native write: key branch of `serializeTable`
    ([serialization.lua:181-191](../serde/serialization.lua#L181-L191));
  - native read: extend the cell grammar — but **not by editing `ltcn`** (vendored
    rock). Either pre/post-process the cell text in
    [table_parsing.lua](../table_parsing.lua) or move table-typed cells onto our
    own `parsers/lpeg_parser.lua` path, which we control;
  - typed JSON: `processTypedValue` / reconstruction in
    [deserialization.lua](../serde/deserialization.lua);
  - type system: relax `NEVER_TABLE` for map keys in
    [parsers/type_parsing.lua:464](../parsers/type_parsing.lua#L464) and
    [parsers/builtin.lua](../parsers/builtin.lua) so `{ {int,int} : Foo }` can register;
  - comparator/identity: `comparators.lua` would need structural key equality for
    sort/dedupe stability.
- **Cost:** medium-high and touches the type core. **Does not** fix natural JSON
  (reason 2) — keys there remain plain strings, so the natural format stays a
  second-class citizen for this feature.
- **Caveat:** still collides with reason 3 — two structurally-equal table keys
  must be deduplicated to one entity at parse time, or you get two map entries
  that "look equal". Requires a canonicalizing intern step on load.

### Option C — Value-semantics layer for table keys (correct, expensive)

Introduce an interning/equality layer so structurally-equal tables map to one
canonical key object (content-addressed keys), making `t[{1,2}]` behave like a
value lookup.

- **Where:** a new module owning canonicalization + a custom key-equality index,
  consumed wherever maps are built (`parsers/generators.lua` map parser,
  `data_set.lua`, `comparators.lua`) — plus everything Option B touches for the
  read/write formats.
- **Cost:** highest; cross-cutting. Only worth it if table-keyed maps become a
  genuine first-class requirement.

## Recommendation

Adopt **Option A now** (turn the silent round-trip break into a symmetric, loud
error) and keep B/C as future work behind a concrete use case. Document the
limitation in `DATA_FORMAT_README.md` alongside the existing JSON-layout notes.

*Done — see [Status](#status). B and C stay parked; nothing has asked for them.*

## Related

- [string_shaped_types.md](string_shaped_types.md) — **Option B, done in the one place
  it is cheap.** A `shape` field on `custom_type_def` declares a *string* whose text is
  validated and canonicalized as a table type. That is this doc's canonical-string key
  encoding, but confined to a declared type instead of retrofitted onto every table —
  so the type core, `ltcn`, the JSON layouts, XML, SQL and the serializers need no
  change, and it *does* fix natural JSON (a shaped key is just a string object key).
  It even answers reason 3: Lua compares strings by value and interns them, so two
  structurally-equal canonical keys **are** the same key, with no interning layer of
  ours. Option A (this doc) is what makes it the only way to key a map by a composite.
- [json_complex_values.md](json_complex_values.md) — D4 + Limitations reach the
  same `ltcn`-can't-read-a-table-key conclusion from the JSON-transcoder side.
- [lua55_compatibility.md](lua55_compatibility.md) — other `ltcn` constraints.
