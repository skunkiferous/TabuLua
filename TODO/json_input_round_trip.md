# JSON Input Round-Trip — reversible `encode` for the six `json:*` transcoders

> **Status: DONE** (pending user commit). All steps landed: reverse encoders in
> `json_transcoders.lua` (`*ToJson` / `*ToJsonTyped`), the six stages flipped to
> `reversible`/`encode` in `builtin_content_stages.lua`, `spec/json_round_trip_spec.lua`
> (16 tests), two pre-existing tests updated for the inverted behavior
> (content_pipeline_spec, json_transcode_integration_spec), and docs
> (module header, `DATA_FORMAT_README.md`, `CHANGELOG.md`, `MODULES.md`). Full
> suite green (2865), `bad_input` unchanged (the pre-existing `extend_typo`
> failure is unrelated). No engine change was needed — the reformatter plumbing
> built for XML covered it, as predicted.

## Summary

Make the JSON input formats **round-trippable** by the reformatter, the way `.xml`
and `.eav` already are. Today the six JSON `transcode` stages
([json_transcoders.lua](../json_transcoders.lua),
[builtin_content_stages.lua](../builtin_content_stages.lua)) are **forward-only**:
they turn a `.json` data file into a wide, typed TSV (`transform`), but declare no
`encode`, so the reformatter classifies a `.json` source as *derived* and leaves it
untouched. This plan adds the inverse — a **`tsvToJson` re-encoder per layout** —
and flips the six stages to `reversible = true`, so a reformatted wide TSV is
written **back** to its original JSON layout in place.

This is a **small** plan: the forward path
([json_complex_values.md](json_complex_values.md), shipped) and *all* the
reformatter plumbing (built by [xml_input_round_trip.md](xml_input_round_trip.md))
already exist. The XML work generalized
[content_pipeline.lua](../content_pipeline.lua) `reversibleTranscode(file_name,
opt_transcoderId)` to resolve **id-selected** reversible stages, made
[manifest_loader.lua](../manifest_loader.lua) build `joinMeta.fn2Transcoder`
(full-path → `transcoder` id), and added the
[reformatter.lua:450](../reformatter.lua#L450) else-branch that calls
`reversibleTranscode(file_name, fn2Transcoder[file_name])` and writes the encoder's
**text** output via `safeReplaceFile`. The `json:*` stages are already id-selected
with an `inputExtensions={"json"}` guard, so the **moment** each declares
`reversible`/`encode`, the existing branch round-trips it with **zero** new engine
wiring. The work is therefore confined to `json_transcoders.lua` (the encoders),
`builtin_content_stages.lua` (six one-line flips), tests, and docs.

## Background — the six stages and the forward/reverse asymmetry

There are three layouts × two codecs (from `json_complex_values.md`):

| id | layout | codec |
| --- | --- | --- |
| `json:objects` | `[ {field:val, …}, … ]` one object per row | natural |
| `json:rows` | `[ [v, v, …], … ]` one array per row | natural |
| `json:columns` | `[ [v, v, …], … ]` one array per **column** | natural |
| `json:objects:typed` / `:rows:typed` / `:columns:typed` | same shapes | typed |

The forward `transform(name, content, env, badVal, ctx)` needs the **schema**
(`ctx.typeName`): the JSON itself carries no column types, and the positional
layouts (`rows`/`columns`) carry no field names either, so `schemaHeader(ctx)`
([json_transcoders.lua](../json_transcoders.lua#L89)) resolves the typeName to the
ordered field names + a typed `name:type` header in **sorted field order**, which
becomes the wide-TSV header.

The reverse `encode(content, env, badVal)` has **no `ctx`** — and does not need one.
Exactly like `xml_transcoder.tsvToXml`, it reads everything it needs from the wide
TSV the reformatter hands it: the `name:type` header gives field **names**, **types**
and **order** (and that order *is* the schema's sorted field order, because the
forward path emitted it that way — so the positional layouts round-trip
positionally). This makes the reverse **schema-free / self-describing**, symmetric
with XML and EAV. The one structural difference from XML: the JSON layouts have **no
header row** (the schema lived in `typeName`, not the file), so `tsvToJson` must emit
**only data rows**, never the `name:type` header.

## Design Decisions

| # | Question | Decision | Rationale |
| --- | --- | --- | --- |
| 1 | Where does the re-encoder get column names/types/order? | **From the wide-TSV `name:type` header**, via `processTSV` — no `typeName`. | Symmetric with `xml_transcoder.tsvToJson`/`tsvToXml`; the header order is already the schema's sorted field order, so positional layouts round-trip. |
| 2 | One encoder or six? | **Three layout assemblers × one value-serializer parameter**, mirroring the forward `makeTranscoder(body, reconstruct)` factory. | Natural passes `serializeNaturalJSON`, typed passes `serializeJSON`; no copy-paste. |
| 3 | Is the round-trip byte-identical (like XML)? | **No — it is a *normalizing* round-trip.** | JSON object key order, number formatting and whitespace are canonicalized to the reformatter's output. This is what a reformatter is *for*; XML happens to be byte-stable for values, JSON is not. Document it (see Limitations). |
| 4 | Empty/`null`/missing cell on the reverse? | **`rows`/`columns` → JSON `null`; `objects` → emit the key with `null`** (do **not** omit). | The forward path collapses absent **and** `null` to an empty cell and can't tell them apart, so re-emitting `null` is a faithful representative; emitting the key keeps every row the same shape. |
| 5 | Which codec re-encodes a given file? | **The file's own `transcoder` id**, via `fn2Transcoder` (already threaded). | A `transcoder=json:objects:typed` file round-trips through the typed encoder; `json:objects` through natural. Fully symmetric, no new selection logic. |

## Round-trip fidelity (what "full round-trip" means here)

The round-trip is **JSON → wide TSV → (reformat) → JSON**. Within it the *parsed Lua
values* are preserved (the wide TSV is fully typed and the same parser machinery
runs both ways), so it is **semantically faithful**, but the JSON **text** is
**canonicalized**, not byte-preserved:

- **`:typed` is value-lossless** — the typed encoding is self-describing
  (`{"int":"…"}` wrappers, `[size,…]` tables), so every type, non-string/​composite
  map key, and exact int64 survives, exactly as the export side's
  [serializeJSON](../serialization.lua#L282).
- **natural is faithful within the native-integer build**, with the documented
  `json_complex_values.md` caveats (int64 above 2⁵³ only on foreign JS toolchains,
  `NaN`/`±Inf` not representable, exact scalar keys in an untyped `table` column
  coerced). These are properties of conventional JSON, not new losses — a value that
  arrived through natural JSON re-serializes to equivalent natural JSON.
- **Object key order** for `json:objects` becomes the schema's sorted field order (=
  the wide-TSV header order), regardless of the source file's key order.

This matches the reformatter's whole purpose: it rewrites sources into the
canonical form. The plan should state this in the module header and
`DATA_FORMAT_README.md` so "round-trip" is not misread as "byte-identical".

## Implementation Steps

### Step 1 — Reverse encoders in `json_transcoders.lua`

Add a `tsvToJson` family mirroring the forward `makeTranscoder` factory. Reuse the
proven `xml_transcoder.tsvToXml` scaffold for turning wide-TSV text into typed cells:

- A private `badVal` collector (no col-types seed) + `tsv_model.processTSV` with
  `defaultOptionsExtractor` / `expressionEvaluatorGenerator`, exactly as
  [xml_transcoder.lua:283](../xml_transcoder.lua#L283) `tsvToJson`/`tsvToXml`, to get
  `file[1]` (header columns, each with `.name` / `.type_spec`) and each data row's
  `cell.parsed` Lua value. Abort `(nil, reason)` on parse/validate failure, matching
  the `encode` contract.
- `makeEncoder(layout, serializeValue)` returns `encode(content, _env, _badVal)`:
  - `layout = "objects"` → `[\n {"<name>":<serializeValue(cell.parsed)>, …},\n … \n]`,
    field names from `header[i].name` (JSON-escaped), in header order; empty cell →
    `null` (D4).
  - `layout = "rows"` → `[\n [<v>, …],\n … \n]` per data row, values in header order
    (this is the shape `exporter.exportJSON`/`exportNaturalJSON` already emit — reuse
    its structure: `filePrefix="[\n"`, `linePrefix="["`, `lineSep=",\n"`,
    `colSep=","`).
  - `layout = "columns"` → transpose of `rows`: one inner array per column.
  - empty/`nil` cell → `null` everywhere (D4); the header row is **never** emitted.
  - `serializeValue` is `serializeNaturalJSON` (natural) or `serializeJSON` (typed),
    called per cell as the exporter does (`serializeX(value, false)`), so the
    output matches the export format byte-for-byte at the cell level.
- Instantiate six encoders: `objectsToJson` / `rowsToJson` / `columnsToJson`
  (natural) and `…Typed` (typed), and add them to the module API table next to the
  existing `objectsToTSV` etc.

Note: the assembler can build the document by hand (string concatenation, like
`tsvToXml`) or by constructing a Lua table and `dkjson.encode`-ing it — but
`dkjson.encode` would double-encode the already-serialized cell fragments, so
**concatenate** the per-cell serializer output, mirroring `exportJSON`.

### Step 2 — Flip the six stages to reversible

In [builtin_content_stages.lua](../builtin_content_stages.lua#L146), add to each of
the six `json:*` registrations:

```lua
reversible = true,
encode = json_transcoders.objectsToJson,   -- …rowsToJson / columnsToJson / *Typed
```

No other change: each already has `id`, `inputExtensions={"json"}` (the guard) and
`transform`. With `reversible`/`encode` present, `reversibleTranscode` resolves the
id and the reformatter else-branch round-trips the file — **no engine edit needed**
(verified: that branch was built generically for XML in `xml_input_round_trip.md`
Step 5, and `reversibleTranscode`'s id-path already covers id-only/​no-`extensions`
stages).

### Step 3 — Tests

- `spec/json_transcoder_spec.lua` (or extend `spec/json_complex_values_spec.lua`):
  unit round-trip per layout × codec — JSON → `transform` (with a `ctx.typeName`) →
  wide TSV → `encode` → JSON, asserting the re-emitted JSON **parses back to the same
  data** (compare decoded structures, not bytes — D3). Cover a composite cell (array
  / map / tuple / nested record) in each layout, and the `:typed` exact-int64 / exact
  scalar-key cases.
- Integration: an end-to-end reformatter round-trip, mirroring
  [spec/xml_transcode_integration_spec.lua](../spec/xml_transcode_integration_spec.lua) —
  a `.json` data file declared `transcoder=json:objects` (and one `:typed`) in
  `Files.tsv`, loaded via `manifest_loader`, reformatted via `reformatter`, and
  re-read to confirm the rewritten JSON still loads to the same wide table. Assert
  `result.joinMeta.fn2Transcoder[path]` carries the id (the hook the reformatter
  uses), as the XML integration spec does.
- Idempotency: reformatting an already-canonical JSON file is a no-op (the
  `new_content == old_content` guard in the reformat branch). Use a 1-pass-stable
  input to avoid the trailing-newline 2-pass settle noted for TSV round-trips.

### Step 4 — Docs

- Module header in `json_transcoders.lua`: document the reverse encoders + the
  normalizing-round-trip semantics (D3 / Limitations).
- `DATA_FORMAT_README.md`: note the `json:*` formats are now reformatter-round-trip
  (like `.xml`/`.eav`), with the fidelity caveats.
- `CHANGELOG.md`: additive entry (no breaking change — adding `encode` only enables
  a previously-skipped reformat path).
- `MODULES.md` if the `json_transcoders` API surface line lists exports.

## Backward compatibility

Strictly additive. Today a `.json` source is left untouched by the reformatter;
after this it is rewritten **only when its canonical form differs** (the existing
`new_content ~= old_content` guard), and only the text JSON path is touched
(`safeReplaceFile`, never the binary branch). No forward behavior changes.

## Open

- **D4 objects null vs omit.** Emitting `"field":null` (chosen) keeps rows uniform
  and round-trips through the forward path identically to omission; confirm no
  consumer prefers omission before coding.
- **Shared TSV→typed-cells scaffold.** `xml_transcoder` and `json_transcoders` will
  both run `processTSV` over wide-TSV text to recover `cell.parsed`. Decide at
  implementation time whether to extract that ~15-line scaffold (private `badVal` +
  `processTSV` call) into a small shared helper (e.g. in `raw_tsv` or a new
  `transcoder_util`) or to mirror it, as the two modules currently do for `failer`.
