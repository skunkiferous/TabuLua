# Re-importing TabuLua's Own Export Formats (input transcoders)

## Status

**Planned — not started.** A short follow-up carved out of the
[archive_files.md](archive_files.md) review (2026-06): an audit of the
[reformatter](../reformatter.lua) export matrix showed that several formats TabuLua
*writes* cannot be *read back* by the production loader. This doc closes the
round-trip gap for the formats worth supporting as input, completing the family
begun by [json_input_round_trip.md](json_input_round_trip.md) and
[xml_input_round_trip.md](xml_input_round_trip.md).

## Problem

The reformatter exports on two axes — `--file` (container) × `--data` (cell value
serialization) — but the loader only ingests a format that has a native path
(`.tsv`/`.csv`, `.eav`, `.gz`) or a registered **input transcoder**. Current state of
each export, as an *input*:

| Export `--file`/`--data` | Re-importable today? |
|---|---|
| `tsv` / *(native, no `--data`)* | ✅ the canonical input format |
| `json` / `json-typed`, `json-natural` | ✅ via `json:*` ([json_input_round_trip.md](json_input_round_trip.md)) |
| `xml` / `xml` | ✅ via `xml:tabulua` ([xml_input_round_trip.md](xml_input_round_trip.md)) |
| `tsv` / `lua` | ❌ cells are Lua literals **with `{ }`**; native parse expects brace-less |
| `tsv` / `json-typed` | ❌ cells are typed-JSON, not native |
| `tsv` / `json-natural` | ❌ cells are natural-JSON, not native |
| `lua` / `lua` | ❌ `.lua` is treated as a code library, never loaded as data |
| `sql` / * | ❌ **won't support** (see Scope) |
| `mpk` / `mpk` | ❌ **won't support** (see Scope) |

(`importer.lua` *can* read all of these, but it is wired only into
[export_tester.lua](../export_tester.lua) for round-trip *testing* — not into the
production loader. This work makes the loader itself read them.)

## Scope

**In scope** — four new `transcode`-phase input stages:

- `tsv:lua` — a `.tsv` whose composite cells are Lua literals (`{attack=80,defense=40}`).
- `tsv:json-typed` — a `.tsv` whose composite cells are typed JSON.
- `tsv:json-natural` — a `.tsv` whose composite cells are natural JSON.
- `lua:tabulua` — a `.lua` file: `return { <header>, <row>, <row>, … }`
  (sequence-of-sequences, row 1 is the `name:type` header), per
  [exporter.exportLua](../exporter.lua#L626).

**Out of scope — `sql` and `mpk` will *not* become input formats** (user decision):

- **SQL** — nobody ships data as `.sql`; DB-to-DB transfer goes through CSV/TSV
  precisely so the source's DB vendor and schema don't gate reading the data. An
  exported `.sql` carries DDL we'd have to re-parse for no real input use case.
- **MessagePack** — a binary wire/cache format, not designed to be a human-authored
  or hand-edited *source* input.

**Already covered, no work here** — `json` (file format) via `json:*`, `xml` via
`xml:tabulua`, plus native `.tsv`/`.csv`, `.eav`, `.gz`.

## Design

**The unifying insight: one family, one skeleton, different cell encodings.** All
four exports are the *same wide table* the native TSV uses — same `name:type` header,
same columns, same rows — differing only in **how each cell value is rendered**:

- The three `tsv:*` exports reuse `exportTSV`'s skeleton and swap only the per-cell
  serializer ([exporter.lua:568-605](../exporter.lua#L568-L605):
  `serialize`/`serializeJSON`/`serializeNaturalJSON`). So the inverse is symmetric:
  read the identical TSV structure, re-parse each non-empty cell from its alternate
  encoding back to a native value, and emit the native wide TSV the parser expects.
- The `.lua` file is one `return { … }` table; row 1 is the header, the rest are data
  rows whose cells are already native Lua values once `load`-ed.

This plugs straight into the **existing transcoder machinery** — no engine change:

- Each is a `content_pipeline` `transcode`-phase stage with an `id`, **id-selected
  via the `Files.tsv` `transcoder` column** (never auto-fires — these share the
  `.tsv`/`.lua` extensions with native data and code libraries, so auto-matching would
  be ambiguous and dangerous). This is exactly the `json:*` model
  ([content_pipeline.md §3.2](content_pipeline.md), Phase 3).
- `inputExtensions` guard: `{"tsv"}` for the three `tsv:*`, `{"lua"}` for
  `lua:tabulua` — a hard error if the column is pointed at the wrong extension.
- **Reuse the existing deserializers** in
  [deserialization.lua](../deserialization.lua) (already used by `importer.lua`):
  the Lua-literal reader, `deserializeJSON`, `deserializeNaturalJSON`. The transcoders
  are thin: parse the TSV skeleton (or `load` the Lua table), re-serialize each cell to
  native via the column parser, emit wide TSV — the same shape `xml_transcoder`'s
  `xmlToTSV` already follows.
- **Reversible.** Each stage's `encode` is the corresponding *existing export
  serializer*, so the reformatter round-trips an `tsv:lua` / `…json…` / `lua:tabulua`
  source in place via `reversibleTranscode` — the plumbing
  ([json_input_round_trip.md](json_input_round_trip.md), the XML `reversibleTranscode`
  id-path) already exists. (v1 may ship forward-only and add `encode` second; the hook
  is free.)

### The `.lua` overload — the one real wrinkle

`.lua` is already meaningful to the loader as a **code library** (manifest bootstrap /
`loadCodeLibrary`), and `lua` is in `EXTENSIONS`. A data `.lua` must be distinguished
from a code `.lua`. The discriminator is the **`transcoder=lua:tabulua` column**: it is
id-only and never auto-fires, so a `.lua` is loaded as data *only* when a `Files.tsv`
row explicitly assigns the transcoder; every other `.lua` stays a code library exactly
as today. Confirm the data-vs-asset gate ([manifest_loader.lua:477-487](../manifest_loader.lua#L477-L487))
routes a transcoder-assigned `.lua` to `processSingleTSVFile` before the
code-library/unknown path — it checks `lcFn2Transcoder[key]` in that `or`-chain, so it
should, but assert it with a test.

Why `lua:tabulua` is worth having (and not just `tsv:lua`): if the consuming
application is itself written in Lua, exporting `--file=lua` and reading it back with
the **native `load`** is zero-code on their side — no TSV reader to write — so the Lua
*file* format is the natural round-trip pair for a Lua application, more so than a
Lua-celled TSV.

## Implementation phases

Each independently shippable and **committed separately** (user does all commits).

**Phase 1 — the three `tsv:*` cell transcoders.**
- New stages (in `json_transcoders.lua` for the JSON pair, a small new module or
  alongside for `tsv:lua`), id-selected, `inputExtensions={"tsv"}`, reusing the
  existing deserializers; emit native wide TSV.
- Tests: an exported `tsv:lua` / `tsv:json-typed` / `tsv:json-natural` fixture with
  composite cells (record / tuple / array) loads to the same model as the native
  source; malformed cell aborts via `badVal`.

**Phase 2 — `lua:tabulua` (the `.lua` file format).**
- A stage that `load`s the `return { … }` table in the sandbox, takes row 1 as the
  `name:type` header, emits wide TSV; `inputExtensions={"lua"}`.
- Confirm + test the code-library-vs-data routing for `.lua`.

**Phase 3 (optional) — reversibility.**
- Add each stage's `encode` (= the existing export serializer) and flip
  `reversible=true`, so the reformatter round-trips these sources in place. Mirrors
  the json/xml round-trip work; no engine change.

## Open questions

1. **Stage naming.** `tsv:lua` / `tsv:json-typed` / `tsv:json-natural` mirror the
   `--data` names; `lua:tabulua` mirrors `xml:tabulua`. Alternative: `lua:rows` to echo
   `json:rows`. *Lean: `tsv:lua` / `tsv:json-typed` / `tsv:json-natural` / `lua:tabulua`.*
2. **Round-trip fidelity.** Like json/xml, the round-trip is *normalizing* (canonical
   native TSV out), not byte-identical to the export — fine for input. Confirm the
   typed vs natural distinction is value-lossless for `:typed`, faithful-within-the-
   native-int-build for natural (same caveat as
   [json_input_round_trip.md](json_input_round_trip.md)).
3. **Do we also want `lua:tabulua` to read a hand-written (not exported) `.lua`?**
   Yes by construction — any `return {header, rows…}` table works, not just our
   exporter's output. Document the expected shape.

## Relationship to existing TODOs / modules

- [json_input_round_trip.md](json_input_round_trip.md) /
  [xml_input_round_trip.md](xml_input_round_trip.md) — the direct precedent; this
  finishes the "read back every export format we reasonably can" story. All the
  reformatter round-trip plumbing they built (`reversibleTranscode` id-path,
  `fn2Transcoder`, the reformat else-branch) is reused as-is.
- [content_pipeline.md](content_pipeline.md) — the host registry; these are ordinary
  `transcode`-phase, id-selected stages.
- [serialization.lua](../serialization.lua) / [deserialization.lua](../deserialization.lua)
  — the forward serializers are the `encode` inverses; the deserializers are the
  forward readers. [importer.lua](../importer.lua) already pairs them for round-trip
  testing — this lifts the same pairings into the production loader.
- [archive_files.md](archive_files.md) — the motivation: a "built" mod packed in a zip
  is only loadable if its members are in a re-importable format. Once these transcoders
  land, the archive plan gains a "loadable member formats" note enumerating the set
  (native `.tsv`/`.csv`, `.eav`, `.gz`, `json`+`json:*`, `xml`+`xml:tabulua`, and now
  `tsv:*` / `lua:tabulua`; **not** `sql` / `mpk`).
