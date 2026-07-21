# Boxed int64 — a real integer type, identical on every Lua version

## Status

**COMPLETE — all phases landed (2026-07-21).** int64 is an interned box, exact on every
Lua version including LuaJIT, recognizable by value in every position (untyped containers,
arrays, map keys), and round-trips through all six export formats. Cross-runtime golden-byte
tests pass on both runtimes; docs (`DATA_FORMAT_README.md`, `CHANGELOG.md`, `REFORMATTER.md`)
are updated. The two superseded working documents this plan replaced have been deleted.

A follow-on change, done after the plan and also landed, **unified the type-tag names across
formats** (typed JSON `{"int"}`→`{"integer"}`, `{"i64"}`→`{"int64"}`; XML `<number>`→`<float>`)
so one concept reads the same word in typed JSON, XML and the Lua `{__int64}` wrapper.

Everything marked *(measured)* below was actually run — on the host (Lua 5.4) or in the
LuaJIT container.

## Goal

Make `int64` a value that **remembers it is an integer**, so that:

1. **Exports are identical on every Lua version**, LuaJIT included.
2. The serializers can tell an int64 from a string **without consulting the schema** —
   which is what makes it work *anywhere* a value can appear, including nested inside
   untyped `table` / `raw` columns, arrays (`{int64}`), and map keys (`{int64:Item}`).

The current representation — a canonical decimal **string** — is exact, but a string is
indistinguishable from a genuine string at serialization time. That is the entire problem,
and it cannot be solved by a schema lookup because untyped containers have no schema.

### Accepted cost *(ratified 2026-07-18)*

int64 is expected to be a **small percentage of all data** (ids, not bulk values), so the
added memory (a proxy table + weak-map entry per distinct value, versus a ~40-byte string)
and the metamethod indirection on payload access are **acceptable**.

## Supersedes

Two working documents were folded into this plan and then **deleted** (2026-07-21) once
their content was carried forward:

- **`int64_export_representation.md`** (deleted) — planned per-format export presentation on
  the assumption that the representation stays a string. Its per-format *policy* decisions
  were carried forward into Phase 7 below; its Phase 1 (the platform-capability `tonumber`
  rule) and its Phase 7 (deferred nested int64) were obsolete, because the box solves both
  by construction.
- **`int64_representation_options.md`** (deleted) — the options survey that led here. Option 1
  ("uniform boxed representation") was chosen; the measured evidence was carried forward into
  *Measured foundations* below, so nothing was lost.

## The design

### The box

An **empty-proxy table**, identical in shape on every Lua version:

- The proxy itself is **empty** — the payload lives in a module-private weak-keyed map, so
  `next(box)` cannot leak it. This is exactly the `util/read_only.lua` pattern.
- **Immutable.** Because the proxy is empty, *every* key is a new key, so `__newindex`
  always fires. This matters more than it looks — see *Measured foundations*.
- `__metatable = "int64"`, which both masks the metatable from tampering **and doubles as
  the type tag** the serializers dispatch on.
- Metamethods: `__tostring` (canonical digits), `__eq`, `__lt`, `__le`, and `__len` /
  `__index` / `__newindex` that **error with a message naming the API**.

### Interning

`of()` returns the **same box for the same value**, via a registry keyed by the canonical
decimal string. This is what makes a box usable as a **map key**: identity becomes value
by construction.

The registry is **weak-valued** (`__mode = "v"`), which is both memory-safe and sound: an
entry can only be collected when nothing references that box, and if nothing references
it, no live table key can be compared against it *(measured)*.

**Implementation contract: the module must never return a non-interned box.** Every value
`of`/`add`/`sub`/`neg` returns must come from the registry, or key parity breaks silently.
`__eq` is defined anyway as a safety net, so a cache reset cannot cause a *wrong* answer —
only a slower one.

### Payload, per platform

| Runtime | Payload | Parse from decimal text |
|---|---|---|
| Lua 5.3+ | native 64-bit integer | `math.tointeger` after range validation |
| LuaJIT | FFI `int64_t` cdata | digit-by-digit accumulation *(measured exact)*, or `strtoll` via `ffi.cdef` |

Both are exact through the full int64 range, and both are **invisible to callers** — the
payload never leaves the module, so no platform-specific type reaches user code.

## What this replaces in `util/int64.lua`

The rewrite is mostly a **deletion**. Today the module implements schoolbook decimal
arithmetic on strings — `cmpMag`, `magAdd`, `magSub`, `signedAdd`, `split`, `render`,
~150 lines. With a native/cdata payload, `add`/`sub`/`neg`/`compare` become ordinary
operators.

**But do not delete the range validation.** `checkString` stays: it is what rejects
non-canonical text, leading zeros, `-0`, and out-of-range magnitudes *before* any
conversion — and on 5.3+ `tonumber("9223372036854775808")` silently yields a **float**, so
the string-domain range check is still the thing standing between us and a wrong value.

**New work, not a port:** both backends **wrap silently on overflow** (Lua 5.3+ integer
arithmetic and cdata `int64_t` both wrap). The current string implementation detects
overflow structurally via `render`. Overflow detection must be **re-implemented** by sign
analysis on the operands and result. This is the single most likely place to introduce a
silent bug, and it needs dedicated tests at `MIN`/`MAX` boundaries.

### API surface

Existing, retained (semantics unchanged, implementation replaced): `of`, `compare`, `eq`,
`lt`, `le`, `gt`, `ge`, `add`, `sub`, `neg`, `MIN`, `MAX`, `getVersion`.

**New, required** — because the raw operations stop working once a value is not a string:

- **`int64.is(v)`** — highest priority. *Both* `type()` and `math.type()` fail silently on
  a non-string int64 *(measured)*, so there is otherwise **no correct way** for user code
  to ask the question.
- **`int64.tostring(v)`** — canonical digits. Also the mandated pre-step for
  concatenation, since `..` cannot be overloaded on a builtin ctype.
- **`int64.abs(v)`, `int64.sign(v)`** — `math.*` is closed to non-numbers.
- **`int64.toNumber(v)`** — explicit, documented-lossy, replacing `tonumber`.

**Deferred by decision:** `mul` / `div` / `mod`. int64 carries **ids**; these are unlikely
and can be added with a real use case.

## Measured foundations

Carried forward from the options survey so it survives that document's deletion.

### The mutation hole — why the box must be an empty proxy

A naive box `setmetatable({payload}, MT)` looks fine but is **silently, globally
corruptible** *(measured, Lua 5.4)*:

```text
v[1]=5 (mutate)   OK     MUTATED
payload intact    OK     5            <- the interned value is now corrupted
```

`__newindex` **only fires for new keys**. Combined with interning, one stray write
corrupts that value for every holder in the dataset. The empty-proxy form closes it
completely *(measured)*:

```text
v[1]=5 (mutate)   ERROR  int64 values are immutable
v.x=5  (mutate)   ERROR  int64 values are immutable
payload intact    OK     9223372036854775807
v == of(s)        OK     true
table key         OK     found
```

### Interning and the weak registry

*(measured, LuaJIT)* `rawequal(of(s), of(s))` is true; `t[of(s)]` hits; one distinct key.
Of 51 ids created, 1 survived GC — precisely the one still referenced as a table key, and
still reachable.

**Catch:** arithmetic results are **not** interned automatically (`a - 7LL` yields a fresh
cdata). Hence the implementation contract above.

### What stops working when a value is not a string

*(measured, LuaJIT cdata; the box behaves the same by construction)*

| Class | Operations |
|---|---|
| **Silent — no error, wrong answer** | `v == "9223…"` → **false**; `type(v)`; `math.type(v)` → **nil** |
| **Loud — error** | `..`; `:sub()`; `:match()`; `#v`; `math.abs`; `math.floor` |
| **Improvements** | `table.sort` numeric (strings sort `100, 30, 9`); `<` numeric; arithmetic exact |

The box converts most of the silent class into the loud class, and its error messages can
name the API — turning the contract from documentation into runtime guidance.

### Two bonuses the box brings

- **Sorting is correct.** Strings sort lexically *(measured: `100, 30, 9`)*. The
  `COMPARATORS.int64` hook exists only to paper over this.
- **Arithmetic is exact.** `v + 1` on a string silently coerces through a double and
  rounds — the exact footgun that caused `long → int64` aliasing to be rejected.

## Integration points

Each of these was found by reading the code, and each is a concrete task.

### 1. `read_only` — a blocking incompatibility, with an existing precedent

[read_only.lua:124-133](../util/read_only.lua#L124-L133) **refuses to wrap any table that
already has a metatable**, and prints an `ERROR` when it does:

```lua
if t_mt ~= nil then
    if t_mt ~= 'badVal' and t_mt ~= semver_mt then
        print(now.."ERROR [read_only] Can't make tables with a metatable read only: "..dump(t))
    end
    return t
end
```

An int64 box **always** has a metatable, so every box reaching `readOnly()` would spam
errors. The fix is precedented: `badVal` and `semver` are already exempt — add `"int64"`
to that exemption list. A box is already immutable, so returning it unchanged is correct.

### 2. `read_only` — the code sharing the user asked about

The proxy machinery is genuinely shareable: `proxy_to_original`, the empty proxy, the
metatable cache, `unwrap`. But `readOnly`'s `opt_index` currently forwards only
`__tostring`, `__call`, `__index`, `__type` ([read_only.lua:168-180](../util/read_only.lua#L168-L180)).
The box additionally needs `__eq`, `__lt`, `__le`, and an overriding `__len`.

**Recommended:** extend `opt_index` to forward those four metamethods. It is a small,
low-risk change that benefits any future value type, and it lets int64 reuse the proxy
machinery rather than clone it. All boxes must share **one** `opt_index` so they share one
metatable — `__eq` only fires when both operands are tables, and the cache is keyed by
`opt_index` identity, so this falls out naturally.

### 3. `quoteIfNeeded` — a concrete bug the box would introduce

[parsers/utils.lua:131-140](../parsers/utils.lua#L131-L140) dispatches on `type(parsed)`:

```lua
elseif parsed_type == "table" then
    return unquotedStr('{'..reformatted..'}')
```

A box is a `table`, so an int64 cell would be reformatted as **`{9223372036854775807}`** —
braces added, TSV output corrupted. Needs an int64 case *before* the table branch.
(`pretendString` may already be the intended lever.)

### 4. Serializers

Every serializer gains one arm — `int64.is(v)` — replacing the schema-driven dispatch the
superseded plan needed. **This is the payoff**: because the check is per value, it works at
any depth, so nested `{int64}`, `{name:int64}` and untyped-container cases are solved by
construction rather than deferred.

The box is also a table in **key** position, so it needs the exemption `unquotedStr`
already has from `rejectTableKey` ([serialization.lua:79-94](../serde/serialization.lua#L79-L94)).
Unlike a generic table key, an interned box is legitimate: it compares by value and
re-parses to the same identity, which is precisely what that refusal exists to prevent.

### 5. Comparators, joins, patch targeting

`state.COMPARATORS.int64` ([builtin.lua:317](../parsers/builtin.lua#L317)) can simplify —
`__lt` makes plain `<` correct. Join keys, override targeting and patch matching compare
values with `==`; interning makes that work, and `__eq` backs it up.

### 6. Sandbox — an unexpected security *improvement*

Sandboxed user code (validators, processors, `=expr`) will receive boxes. Because the
proxy is **empty** and the payload lives in a module-private weak map, sandboxed code
**cannot reach the cdata at all** on LuaJIT. This is strictly safer than handing out raw
FFI objects, and it removes the main objection to using FFI internally.

### 7. `global_reset`

`read_only` registers a reset hook for its metatable cache
([read_only.lua:73-76](../util/read_only.lua#L73-L76)). The intern registry needs a
decision: clearing it is safe for correctness (`__eq` covers identity mismatches) but
would mean pre- and post-reset boxes are different objects. See OQ2.

## Phases

Per-phase review and commit, as usual.

### Phase 1 — `read_only` foundation

Extend `opt_index` to forward `__eq`, `__lt`, `__le`, `__len`; add `"int64"` to the
metatable exemption list. Self-contained, no int64 dependency, full suite must stay green.

### Phase 2 — the box, interning, and the new `util/int64.lua`

Rewrite the module: empty-proxy box, weak intern registry, per-platform payload, retained
`checkString` validation, **re-implemented overflow detection**, and the new API
(`is`, `tostring`, `abs`, `sign`, `toNumber`). Extend `spec/int64_spec.lua` — boundary
tests at `MIN`/`MAX`, interning identity, immutability, and the contract that no
non-interned value ever escapes. Green on **both** runtimes before proceeding.

### Phase 3 — the parser, the model, and the parent change

`PARSERS.int64` returns a box; `COMPARATORS.int64` simplifies; fix `quoteIfNeeded`.

**Also lands the parent change** (`extends number`, per *Decisions*), which is not
cosmetic:

- `generators.extendsOrRestrictsType('int64', 'number')` — one line, but it flips which
  restriction family a derived custom type gets.
- **Range support is optional here (OQ8)** — `restrictNumber`-generated parsers compare
  against plain-number bounds and would **error** on a box. Either branch inside
  `restrictNumber` to build an int64-aware range parser via `int64.compare`, **or defer
  `min`/`max` on an int64 parent with a clear rejection message**. Deferring regresses
  nothing, since `min`/`max` on an int64 is impossible today.
- `parentInteger` needs no action (OQ9) — int64 lands in the same position as `long`.
- `quantity` needs no action (OQ10) — the parent change alone makes int64 a valid
  `number_type`, exactly like `long`, and `quantity` delegates rather than computing.
- The exported schema records int64's parent (`exported/lua-lua/schema.lua`), so its
  regenerated output changes — expected, and worth an explicit diff review.

Success criterion: **TSV round-trip is byte-identical to today** on both runtimes. Nothing
outside the model has changed yet.

### Phase 4 — serializers recognize the box

Add the `int64.is(v)` arm to `serialize`, `serializeJSON`, `serializeNaturalJSON`,
`serializeSQL`, `serializeXML`, and the table serializers; exempt boxes from
`rejectTableKey`. At this point every format still emits **exactly what it emits today** —
this phase only makes the box *recognizable*, so any output change is a bug.

**Mandatory MessagePack guard (per OQ5).** `serializeMessagePack` hands the value to the
`lua-MessagePack` rock, which dispatches on Lua type. A box is an **empty table**, so it
would pack as an **empty map — silently losing the value entirely**. Whether or not real
int64 support is implemented, this phase must ensure a box never reaches `mpk.pack`
unrecognized: either encode it properly, or **fail loudly**. Silent loss is the one
outcome that is not acceptable.

### ⚠️ Phases 5 and 7 were RESTRUCTURED (2026-07-19, ratified)

Two problems with the original split were found by measurement during Phase 4:

1. **`{"int":"…"}` already means "any Lua integer"** — `serializeJSON(123)` emits it today.
   Reading it back as a box would turn **every** integer in an untyped `table`/`raw` column
   into a box, and a box has **no arithmetic** (`box + 1` raises), so sandboxed validators
   and processors doing math on such values would break. **Decided: int64 gets its own tag**
   — `{"i64":"<digits>"}` in typed JSON and `<int64>` in XML — so `{"int":…}` keeps meaning
   Lua integer and only genuine int64s read back as boxes. This supersedes the typed-JSON
   and XML rows of the Phase 7 table below, and OQ4.
2. **Read and write must land together per format.** Reading a tag the writer does not yet
   emit breaks round-trip at the intermediate commit — the same "two halves must land
   together" argument this plan already makes for SQL's `BIGINT` column + bare literal.

**Phases 5 and 7 are therefore replaced by one phase per format, each landing read AND
write together**, so every commit stays round-trip green and independently reviewable:

- **5a — typed JSON** (`{"i64":"…"}`, read + write)
- **5b — XML** (`<int64>`, read + write)
- **5c — MessagePack** (standard `0xD3`, read + write, incl. the self-validating
  `unpackers[0xD3]` patch; replaces the Phase 4 raise-guard)
- **5d — Lua literal** (`{__int64 = "…"}` wrapper for untyped containers, read + write)
- **5e — SQL** (`BIGINT` column + bare literal, both halves together)

Phase 6 (map keys / nested containers), Phase 8 (cross-runtime round-trip) and Phase 9
(docs) are unchanged. The per-format rationale in the Phase 7 table below still applies —
only the typed-JSON and XML *tag spellings* changed, and the phase each half lands in.

**Additional obligation for 5d, found in Phase 3:** a **declared** `{int64}` container needs
the ltcn treatment too, not just untyped ones. Container cells are parsed by `ltcn`, which
lexes bare number literals before any int64 code runs, so on LuaJIT a bare
`9007199254740993` in a `{int64}` cell silently becomes `9007199254740992`. Phase 7's claim
that declared containers need no wrapper is true on the write side, false on the read side.

### Phase 5 (ORIGINAL — superseded by 5a–5e above, kept for its detail)

Deserialization produces boxes for `{"int":"…"}` wrappers instead of `tonumber`-ing them,
on **every** runtime (this replaces the superseded plan's platform-capability rule, which
existed only because a string could not carry the tag). Same treatment for
`deserializeXML`'s numeric path. Verify the second read path — `serde/importer.lua` calls
`deserialize*` directly ([331, 518](../serde/importer.lua#L331)) — see OQ3.

Also lands the two other read-side reconstructions decided above:

- **Lua literal (OQ12)** — post-process `ltcn.parse` output, converting a table whose sole
  key is `__int64` (with a canonical int64 string value) into a box, guarded by the cheap
  `string.find` pre-check. See *Closing the Lua-literal gap* under Phase 7.
- **MessagePack (OQ5/OQ11)** — install the self-validating `unpackers[0xD3]` patch, which
  must assert its known-answer round-trip and **raise** rather than degrade quietly.

### Phase 6 — map keys, nested containers, and quantity

`{int64:Item}`, `{int64}`, records with int64 fields. Parses today; this phase proves the
box works in **key** position end-to-end, which is the case interning exists for.

Also covers **quantity with an int64 number type** (per OQ10) — verification rather than
construction: that the `tagged_number` comparator reaches the box's `__lt`, and that the
`{type, box}` tuple serializes through Phase 4's per-value arm.

### Phase 7 — per-format export policy

The salvaged, still-valid content of the superseded export plan. Now applies **at any
depth**, not just to declared scalar columns:

| Format | Emit as | Rationale |
|---|---|---|
| **TSV** | bare digits | Already correct; must not regress. |
| **SQL** | `BIGINT` column + bare literal | Two halves that **must land together** — `sql_types` maps by *base* type and int64 currently falls through `string` → `TEXT` ([exporter.lua:810](../serde/exporter.lua#L810)), so a `BIGINT` column receiving a quoted literal would be a type mismatch. |
| **Typed JSON** | `{"int":"<digits>"}` | Digits inside a JSON *string*, so no number parser touches them; the tag preserves the meaning. **Now works nested and untyped too** — the original parity goal. |
| **Natural JSON** | quoted string — **no change** | A bare number is exact on 5.3+ but **rounds on LuaJIT re-read**, reintroducing the version-dependence int64 exists to remove. Decided; see *Decisions*. |
| **XML** | `<integer>` form | Decided (OQ4) — honest about the meaning, no new vocabulary. Requires the Phase 5 read fix first, or the value rounds on re-read. |
| **MessagePack** | standard int64 (`0xD3` + 8 bytes BE) | Decided (OQ5), **validated end-to-end**. Write via the exported `m.packers` hook; read via a **self-validating `debug.getupvalue` patch** of `unpackers[0xD3]`. Extension types rejected — they would make the output proprietary. The Phase 4 guard against silent empty-array loss applies regardless. Open: OQ11 (patch on 5.3+ too, or LuaJIT only?). |
| **Lua literal** | **int64** → quoted string (no change). **`long`** → **bare number literal**, also no change *(measured: `9223372036854775807`, unquoted)* | A bare literal is lexed by **LuaJIT straight into a double** on re-import, and there is no tag convention in Lua output to rescue it — so int64 must stay quoted. `long` keeps its bare literal safely, because `long` cannot exist on LuaJIT (fails at type resolution), so its literal can never be re-read there. Same reasoning as natural JSON and MessagePack. **Plus:** an int64 inside an *untyped* `table`/`raw` column is tagged `{__int64 = "…"}` so it survives re-read — see *Closing the Lua-literal gap* below. |

#### Closing the Lua-literal gap in *untyped* containers

Every other format restores int64-ness on re-read — typed JSON via `{"int":"…"}`,
MessagePack via `0xD3`, TSV and SQL via the declared column type. The Lua literal had no
tag convention, so a quoted `"9223372036854775807"` re-read as an ordinary string,
indistinguishable from genuine text. That affected **untyped `table`/`raw` containers on
every runtime** (declared `int64` columns were always fine — the column type re-supplies
the box).

**Decided (OQ12): close it with a table wrapper.** This was the last place the box did not
achieve parity, and it is now covered.

#### ltcn capabilities — investigated *(measured, ltcn 231 lines)*

The gap is **closable**, but only one mechanism survives contact with the grammar:

| Candidate tag | Verdict |
| --- | --- |
| **Comment** — `--[[int64]] "9223…"` | ❌ **Parsed but discarded.** `LongComment = P"--" * V"LongString" / 0` — the `/ 0` capture drops it — and `Skip = (Space + Comment)^0` treats comments as whitespace. They never reach a capture, so they cannot be post-processed. |
| **Call syntax** — `int64"9223…"` | ❌ **Rejected by the grammar.** `Value = Number + String + Boolean + Table` admits no call form. Both `int64"x"` and `int64("x")` fail to parse. |
| **Table wrapper** — `{__int64 = "9223…"}` | ✅ **Parses.** A table is a legal *value*, so this round-trips through ltcn and can be post-processed back into a box. |

So the wrapper is the only route — and it is **the same convention typed JSON already
uses** (`{"int":"…"}`), not a new invention.

**Two caveats before adopting it:**

1. **There is no `lua-typed` data format to hide it in.** The valid data formats are
   `{"lua", "json-typed", "json-natural"}` (plus `xml`, `mpk`) — JSON has a typed/natural
   split, Lua does not. So a wrapper changes *the* Lua output, with no opt-in variant.
   Note the "proprietary format" objection is **much weaker here than for MessagePack**:
   the Lua literal is already a TabuLua-specific format, defined by ltcn's restricted
   grammar and meant to be read back by us — unlike MessagePack, a true interchange format
   with external consumers.
2. **Ambiguity** with genuine user data containing that key. Mitigate exactly as typed JSON
   does: a distinctive key (`__int64`), converted only when the table has that single key
   with a string value matching the canonical int64 pattern.

#### The adopted design — tag only where the type is not otherwise recoverable

- **Declared `int64` column** → plain quoted string, *unchanged*. The column type already
  restores the box, so no wrapper and **no existing output churns**.
- **Declared container types** (`{int64}`, `{name:int64}`, records) → **also unchanged**.
  The type still says where the int64s are, so wrapping would be noise.
- **int64 inside an untyped `table` / `raw` column** → `{__int64 = "9223…"}`.

This follows the principle used throughout: the schema restores the type where it exists;
a tag is needed only where it does not.

**Write side — the rule is per column, not per depth.** A naive "wrap whenever nested"
rule would over-wrap declared containers, turning a `{int64}` column into
`{{__int64="1"},{__int64="2"}}` for no benefit. The exporter must decide from `col.type`
— wrap **iff the column is an untyped `table`/`raw`** — and thread that choice into
`serialize`, since the serializer itself is value-driven and cannot see the column.

**Read side (Phase 5) — post-process the ltcn output.** After `ltcn.parse`
([table_parsing.lua:82](../util/table_parsing.lua#L82)), walk the result and convert
qualifying nodes into boxes. Ambiguity is mitigated exactly as typed JSON does it: convert
**only** a table whose sole key is `__int64` and whose value is a string matching the
canonical int64 pattern; anything else stays a plain table.

*Performance note:* that walk would otherwise run on **every** parsed table cell. Guard it
with a cheap `string.find(text, "__int64", 1, true)` on the raw cell text before parsing —
if the marker is absent, skip the walk entirely.

### Phase 8 — cross-runtime round-trip tests

Export the full range (`MIN`, `MAX`, ±2^53±1, `0`, `-0` normalization) through every
format and re-import, asserting byte-exactness — on the host **and** in the LuaJIT
container. `serde/round_trip.lua` is the natural home. This phase is what proves the goal.
We should produce test output with Lua 5.3+, and check it reads correctly on LuaJIT and vice versa,
at least once for each format.

### Phase 9 — docs, CHANGELOG, cleanup

`DATA_FORMAT_README.md`, `CHANGELOG.md`, and **delete** the two superseded TODO documents.

Docs deliverables carried forward:

1. **The `long` vs `int64` contract** — want a bare number in natural JSON → `long`
   (5.3+ only); want it to work on LuaJIT → `int64`. The differing rendering is intended;
   a reader who does not know that will file it as a bug.
2. **The int64 usage contract** — all operations go through the int64 API. `==` against a
   string literal, `..`, `#`, string methods and `math.*` do not work, **by design**.
3. **CHANGELOG the tutorial's changed natural-JSON output** — `catalogId` moved from a
   bare number to a quoted string when it migrated `long` → `int64`. Already committed and
   currently unrecorded.
4. **The Lua-literal conventions** (see *Closing the Lua-literal gap* under Phase 7).
   Document the `{__int64 = "…"}` wrapper as part of the Lua data-file format — it is
   author-visible, so it must be specified, not merely implemented: when it appears
   (untyped `table`/`raw` only), what it means, and that hand-authored files may use it.
   Also state the `long` / `int64` rendering difference in that format (`long` bare,
   `int64` quoted) for the same reason it is stated for natural JSON: a reader who does not
   know it is intentional will file it as a bug.

## Decisions

- **Uniform boxing on every Lua version**, not cdata-on-LuaJIT-only. The asymmetric form
  works, but contract violations would be **silent on the platform people develop on**
  (`v == "9223…"` and `type(v)=="string"` behave *correctly* on 5.4, then silently
  misbehave on LuaJIT). Uniform boxing makes a violation fail identically everywhere.
- **The box must be an empty proxy**, not `{payload}` — see the measured mutation hole.
- **Memory and indirection cost accepted** — int64 is a small fraction of data.
- **Natural JSON and the Lua literal keep quoted strings.** Unchanged from the superseded
  plan and unaffected by boxing: both are re-read through a number parser that rounds on
  LuaJIT.
- **The payload never escapes the module.** No native integer and no cdata reaches user
  code; the box is the only public form.
- **`int64` extends `number`, not `string`** *(decided 2026-07-18)*. The `extends` relation
  describes what the parsed value **is** — the rule `percent` states in its own comment:
  *"percent only logically extends number, because it produces a number as a parsed
  value"*. int64 extended `string` only because its value happened to be a string; once
  the value is a box, that justification is gone and `string` is a leftover artifact.

  It also fixes a backwards capability. The parent decides which **restriction family** a
  derived custom type may use:

  | Parent | Restrictions unlocked | Sensible for an id? |
  | --- | --- | --- |
  | `string` (today) | `minLen` / `maxLen` / `pattern` via `restrictString` | ❌ nonsense |
  | `number` (proposed) | `min` / `max` via `restrictNumber` | ✅ "ids must be positive" |

  **`number`, not `integer`** — mirroring `long`, which
  [extends `number` directly for exactly this reason](../documentation/DATA_FORMAT_README.md):
  `integer` is the ±2^53 safe-range type, and int64's range is *wider*. A subtype must
  narrow, never widen.

  **Verified not to break map keys:** legality is gated on `NEVER_TABLE` — *"map key_type
  can never be a table"* ([type_parsing.lua:466-469](../parsers/type_parsing.lua#L466-L469)) —
  which tests whether the *type* is a table type, not whether it extends string. The
  `extends string` requirement at [registration.lua:845](../parsers/registration.lua#L845)
  applies to **shaped types**, which int64 does not use. `{int64:Item}` is unaffected.

  *Process note: this was originally filed as an open question. It is a design decision
  and should have been surfaced as a consequence of boxing before that choice was
  ratified — boxing is what creates the question, by removing the reason the old answer
  was right.*

## Open questions

1. ✅ **RESOLVED (2026-07-18) — `int64` extends `number`**, mirroring `long`. Rationale,
   evidence and the map-key verification are in *Decisions*. The consequences it creates
   are tracked as OQ8–OQ10 and as work in Phase 3.
2. ✅ **RESOLVED (2026-07-19) — the intern registry PERSISTS across `global_reset`.**
   Clearing it would be safe for correctness but changes identity across a reset:
   `__eq` rescues *comparisons*, but **not table-key lookups**, which are identity-based —
   so a pre-reset box would stop matching a post-reset one used as a key. Persisting is
   the safer choice, and it does not leak, because unreferenced boxes are collected.

   ⚠️ **Mechanism correction — the registry must be weak-VALUED (`__mode = "v"`), not
   weak-keyed.** The registry maps *canonical decimal string* → *box*, and **Lua strings
   are never removed from weak tables** (manual §2.5.4: strings "behave more like values
   than like objects"). So a weak-**keyed** registry would pin every box forever — the
   exact leak this decision is trying to avoid. Measured on Lua 5.4, 50 unreferenced boxes
   after a full collection:

   ```text
   __mode="k" (weak KEYS)   -> 50 of 50 entries survive GC   <- permanent leak
   __mode="v" (weak VALUES) ->  0 of 50 entries survive GC   <- correct
   ```

   This matches the LuaJIT measurement in *Measured foundations* (51 created, 1 survived —
   the one still referenced as a table key).
3. **The second read path** — does `serde/importer.lua` lower to cell text like the
   transcoders, or build model values directly? If the latter, Phase 5 needs a matching
   change there.
4. ✅ **RESOLVED (2026-07-18) — use the existing `<integer>` tag.** It is honest about the
   meaning and needs no new vocabulary. The XML reader's `tonumber`
   ([deserialization.lua:349, 368](../serde/deserialization.lua#L349)) is handled by
   Phase 5, which must land first or the value rounds on re-read.
5. ⚠️ **INVESTIGATED (2026-07-18) — possible and worth doing, but the rock cannot do it,
   and there is a silent-data-loss hazard that must be handled regardless.**

   **Exact 64-bit encoding IS reachable on LuaJIT** *(measured)* — a MessagePack int64 is
   just tag `0xd3` plus 8 big-endian bytes, and FFI byte reinterpretation produces and
   consumes them exactly, `MIN` and `MAX` included:

   ```text
   9223372036854775807LL  7FFFFFFFFFFFFFFF  roundtrip=true
   -9223372036854775808LL 8000000000000000  roundtrip=true
   ```

   On Lua 5.3+ the same is trivial with native `string.pack(">i8", v)`. (Do **not** route
   LuaJIT through compat53's `string.pack` — it would pass the value through a double.)

   **But `lua-MessagePack` dispatches on Lua type and cannot be handed either form**
   *(measured)*:
   - `mpk.pack(cdata)` → error, `"pack 'cdata' is unimplemented"`.
   - `mpk.pack(<big number>)` on LuaJIT emits tag **`CB` — float64**, not an integer.

   **The hazard:** a box is a *table*, and an **empty** one. `mpk.pack(box)` would
   therefore silently emit an **empty map** — total loss of the value, with no error. This
   must be prevented in Phase 4 even if proper support is deferred (see the guard added
   there).

   **No buffer hacking is needed — the write side is a supported extension point, and it
   works** *(measured, lua-MessagePack 0.5.4)*. `m.packers` is **publicly exported**, and
   dispatch is `packers[type(v)](buffer, v)` where `buffer` is simply a table of string
   fragments concatenated at the end — so a custom packer just appends. There is no
   position pointer to fight and no need to overwrite a same-sized dummy value:

   ```text
   cdata  (custom packer)  -> D37FFFFFFFFFFFFFFF     standard int64
   MIN                     -> D38000000000000000
   box    (packers.table)  -> D37FFFFFFFFFFFFFFF
   nested {box, "x"}       -> 92 D3…0001 A178        composes at depth
   box UNHOOKED            -> 90                     <- empty fixarray: the silent loss
   ```

   **The read side is the real constraint:** `unpackers` is **not** exported *(measured:
   `m.unpackers == nil`)*, and `0xD3` decodes through `unpack_int64` to a **rounded double**
   on LuaJIT. (`unpackers[0xD3] = nil` exists in the source but only in the
   `SIZEOF_NUMBER == 4` "small_lua" branch, which does not apply here.)

   **DECIDED (2026-07-18): standard int64 `0xD3` on the wire, with the read side patched
   via `debug.getupvalue`. Validated end-to-end.**

   A MessagePack **extension type** was rejected outright: `m.build_ext` is exported and
   would give a clean read hook, but extension tags are rarely used in practice and would
   turn our output into a **proprietary format**. Interoperable output is worth more than
   a tidy hook.

   The read side is therefore patched: `unpackers` is an upvalue of the exported
   `m.unpack_cursor`, reachable with `debug.getupvalue`. **Measured working** — the
   upvalue is found by name, `0xD3` is present, and after patching, values round-trip
   exactly on LuaJIT:

   ```text
   VALIDATION: unpackers reachable = true, is table = table, 0xD3 present = true
   9223372036854775807LL  -> 9223372036854775807    exact=true
   -9223372036854775808LL -> -9223372036854775808   exact=true
   nested {box,"x",42}    -> [1]=9223372036854775807 [2]=x [3]=42
   ```

   **The risk is accepted on an explicit basis:** MessagePack is a *settled* format, so
   the library has little reason to churn — and the patch is **self-validating**, so a
   breaking upgrade is detected rather than silently tolerated.

   **Required: the patch must verify itself at install time** and fail loudly, never
   degrade quietly. Check, in order, that `m.unpack_cursor` exists, that an upvalue named
   `unpackers` is found, that it is a table, and that `unpackers[0xD3]` is a function —
   then patch, then **assert a known-answer round-trip** (`MAX` and `MIN` through
   pack/unpack). If any step fails, raise: silently falling back to the stock unpacker
   would reintroduce rounding invisibly. A spec asserting the same known-answer round-trip
   turns a future library upgrade into a **red test**, which is the whole basis on which
   this risk was accepted.

   **Tag ambiguity — resolved, see OQ11.** On LuaJIT a `0xD3` is *always* an int64, because
   `long` cannot exist there (it fails at type resolution). On Lua 5.3+ the tag is
   ambiguous, but benignly so: both readings are exact and both re-emit as `0xD3`, so the
   exported bytes are identical either way.

   **Either way, the Phase 4 guard stands:** an unhooked box packs to `0x90` — a single
   byte, empty array, total silent loss *(measured)*.
6. **Exported schema** — `exported/lua-lua/schema.lua` currently records int64's parent as
   `string`. Follows from OQ1.
7. **Performance sanity check** — a dataset with many distinct int64 ids should be
   measured once, to confirm the accepted cost is actually in the range assumed.
8. ✅ **RESOLVED (2026-07-18) — range support goes lower-level, and is optional.**
   `restrictNumber` ([registration.lua:186](../parsers/registration.lua#L186)) builds
   parsers that compare against plain-number bounds, and a box compared to a number
   **errors**. But `restrictNumber` is a convenience that saves code, not a required path:
   the same parser can be built at a lower level with an int64-aware comparison routed
   through `int64.compare` (which already accepts numbers via `of()`).

   Two acceptable shapes, in order of preference:
   1. `restrictNumber` detects an int64 parent and generates an int64-specific range
      parser. Contained branch; shared machinery untouched.
   2. **Or defer entirely** — reject `min`/`max` on an int64 parent with a clear message
      and add it with a first real use case, per the repo's usual convention. `min`/`max`
      on an int64 is impossible *today*, so deferring it regresses nothing.
9. ✅ **RESOLVED (2026-07-18) — mirror `long`; not a defect.** `long` is already
   number-but-not-integer, so `parentInteger` being false for int64
   ([registration.lua:207](../parsers/registration.lua#L207)) puts it in exactly the same
   position as the type it is modelled on. Accepted as-is. If it is a wart, it is a
   pre-existing one shared with `long` and should be fixed for both or neither.
10. ✅ **RESOLVED (2026-07-18) — int64 behaves like `long` as a quantity: allowed, with no
    special-casing.** Verified this is nearly free, because `quantity` is **generic**:
    - `number_type` is just `{extends:number}` ([builtin.lua:922](../parsers/builtin.lua#L922)),
      so the parent change **by itself** makes int64 a valid quantity number type — the
      same way `long` already is.
    - `quantity` **delegates** parsing to the declared type's own parser and stores what it
      returns ([builtin.lua:949-962](../parsers/builtin.lua#L949-L962)); it performs no
      arithmetic on the value.
    - Its reformat is `reformatted_num .. parsed_type` — concatenation of the *reformatted
      text*, never the parsed value, so a box never reaches a string operation.

    Remaining work is therefore **verification, not construction**, and is already covered:
    the `tagged_number` comparator must reach the box's `__lt` (it will — same-type
    comparison), and the `{type, box}` tuple must serialize (Phase 4's per-value
    `int64.is` arm handles it at any depth). Add a quantity-with-int64 case to Phase 6.
11. ✅ **RESOLVED (2026-07-18) — on LuaJIT, `0xD3` unambiguously means int64.** The
    ambiguity I raised does not exist on the runtime that needs the patch:

    **`long` cannot exist on LuaJIT.** It fails at *type resolution*
    (`state.UNSUPPORTED.long`, committed), so no `long` value is ever in memory there. A
    `0xD3` read on LuaJIT is therefore always an int64.

    This holds for cross-runtime files too — the case worth checking: a MessagePack file
    authored on Lua 5.4 from a `long` column, then read on LuaJIT. That file's `long`
    **column** fails at resolution regardless of how the bytes decode, so the data cannot
    load either way. There is no path where a `0xD3` on LuaJIT is legitimately a `long`.

    **On Lua 5.3+ the tag is genuinely ambiguous** (the library emits `0xD3` for any native
    integer above 2^32) — **but the ambiguity is benign**, because both readings are exact
    and both re-emit as `0xD3`:
    - Read as a native integer (unpatched): exact on 5.3+, re-packs as `0xD3`.
    - Read as a box (patched): exact, re-packs as `0xD3`.

    The **exported bytes are identical either way**, so this is not a correctness question
    and does not affect interoperability. It only decides the in-memory Lua type inside
    *untyped* containers.

    **Recommendation: patch both runtimes**, for consistency with Phase 5's rule that
    deserialization yields boxes on every runtime. A `long` value landing in an untyped
    container as a box is harmless — it is exact, it re-exports identically, and a declared
    `long` column is unaffected because the read path lowers to cell text before parsing.
    Choosing LuaJIT-only is also defensible; it is a uniformity-versus-minimal-intervention
    preference, not a risk.
12. ✅ **RESOLVED (2026-07-18) — adopt the `{__int64 = "…"}` wrapper, tagging *untyped
    containers only*.** The last parity gap is closed rather than documented. Design and
    the ltcn evidence are under Phase 7; the read half lands in Phase 5.

## Related

- [luajit_compatibility.md](luajit_compatibility.md) — why int64 exists; its preserved
  "Approach B: FFI int64_t" write-up is the ancestor of this plan, and its rejection
  reasons (`LL` suffix, `type()`, no interning, sandbox) are each answered here.
- [tables_as_keys.md](tables_as_keys.md) — the identity-vs-value argument. Interning is its
  "Option C", applied successfully; the `rejectTableKey` exemption is the other half.
- [string_shaped_types.md](string_shaped_types.md) — the precedent for "a value that is
  not what it appears to be", and the map-key reasoning this plan revisits.
- [util/read_only.lua](../util/read_only.lua) — the empty-proxy pattern this plan reuses,
  and the exemption list it must join.
