# XML Input Round-Trip — namespaced, id-selected, schema-free `xml_transcoder`

## Summary

Make TabuLua's **XML export format** a first-class **input** format too, so an XML
file written in our own schema can be read back in, parsed to a wide table, and —
like `.eav` — **round-tripped** by the reformatter (read → wide TSV → write XML
back). Today XML is export-only: [exporter.lua](../exporter.lua) `exportXML`
emits `<file>/<header>/<row>` and [serialization.lua](../serialization.lua)
`serializeXML` ↔ [deserialization.lua](../deserialization.lua) `deserializeXML`
already round-trip at the **value** level, but there is no content-pipeline
`transcode` stage that consumes an XML *file* as data.

This plan adds that stage. It mirrors the EAV transcoder
([eav_transcoder.lua](../eav_transcoder.lua), [eav_long_format.md](eav_long_format.md))
in shape — a forward `transform` plus a reversible `encode` — but differs in three
deliberate ways decided up front (see **Design Decisions**): it is **id-selected**
(never auto-fires on a stray `.xml`), **schema-free** (column names/types come from
the file's own `<header>`, not a `typeName`), and the format is **namespaced** so
"is this XML ours?" is answered by the root element's namespace.

## Background — why a namespace, and why id-selected

XML is "invent your own schema": an `.xml` file in a package may be a TabuLua data
file *or* an unrelated game asset that merely happens to share an element name.
Blindly treating every `.xml` as TabuLua input would misread assets. Two
mechanisms guard against that, used together:

1. **An XML namespace on the root element** is the natural, standardised
   discriminator — it is exactly what namespaces are *for* ("whose vocabulary is
   this `<file>` from?"), and it is something JSON lacks (hence JSON's bolted-on
   `transcoder` id). The current export format has **no** namespace and a generic
   `<file>` root, which is the actual footgun this plan closes.

2. **Explicit id-selection** (`transcoder=xml:tabulua` in `Files.tsv`) means the
   stage **never auto-fires by extension** — a stray `.xml` asset is never
   interpreted as data unless the author opts that specific file in. This matches
   the JSON transcoders' dispatch and is the most conservative answer to the
   asset-collision concern.

The namespace then also serves as **defense-in-depth**: even when a file is
explicitly selected with `transcoder=xml:tabulua`, the transcoder verifies the
root is in our namespace and errors clearly if someone points it at a foreign XML.

### Why the id is `xml:tabulua`, not `xml`

XML is an open meta-format: users will reasonably want to plug in **their own** XML
input layouts. Reserving the bare `xml` id for "our" format would squat the whole
XML space. So our typed export/import format takes the **specific** id
`xml:tabulua` (mirroring the `json:<layout>` convention — family `xml`, our variant
`tabulua`), leaving `xml:<their-format>` free for user-registered transcoders.

### Namespace URI: a URN, no domain required

An XML namespace is an **opaque unique string**; the XML Namespaces spec does not
require it to resolve, be registered, or be owned. No parser dereferences it. To
avoid implying ownership of an internet domain, this plan uses a **URN**:

```
urn:tabulua:table:1
```

The trailing `1` is a format-version segment. Because the namespace is **baked
into every exported file**, changing it later is a breaking change (re-export +
version bump), so it is chosen once here.

## Design Decisions

These four were settled before drafting and drive the steps below:

| # | Question | Decision | Rationale |
| --- | --- | --- | --- |
| 1 | How is the XML transcoder dispatched? | **Explicit id-only** (`transcoder=xml:tabulua`), like JSON | A stray `.xml` asset is never auto-grabbed; the namespace is checked as defense-in-depth inside the transform. The specific id leaves the `xml:*` space free for user-defined XML formats. |
| 2 | Does it require a `typeName`? | **Schema-free / self-describing** | Our XML already carries `name:type` in `<header>` and typed-element values; reading them back is true symmetry with export and needs no `typeName`. A downstream `typeName` in `Files.tsv`, if present, still validates. |
| 3 | Behaviour of the input-extension guard | **Add `inputExtensions` guard, hard error** | Catches a mis-pointed `transcoder` column (e.g. `transcoder=json:rows` aimed at `foo.txt`) early instead of mis-parsing. |
| 4 | Namespace the export format? | **Add namespace + version bump** (breaking) | The namespace is the clean long-term discriminator; worth a one-time break to gain it. |

## Implementation Steps

Land **steps 1–2 first** (small, self-contained); then the transcoder (3–4); then
the reformatter wiring (5) and tests (6).

### Step 1 — Namespace the export format *(breaking; version bump)*

- [exporter.lua](../exporter.lua) `exportXML` (~L824): change the `filePrefix`
  root open tag to `<file xmlns="urn:tabulua:table:1">`.
- [schemas/export.xsd](../schemas/export.xsd): add `targetNamespace="urn:tabulua:table:1"`,
  a matching default `xmlns`, and `elementFormDefault="qualified"`; the existing
  type definitions are otherwise unchanged.
- [schemas/export.dtd](../schemas/export.dtd): DTDs are namespace-blind — document
  the namespaced root in a comment and declare `xmlns` as a `#FIXED` attribute on
  `file` so DTD validation still passes.
- Bump module versions touched, add a **CHANGELOG** entry flagging the break.
- **Golden-file scope:** only *exporter-level* XML fixtures regenerate. The
  value-level tests in [round_trip.lua](../round_trip.lua) /
  `spec/round_trip_spec.lua` and `serializeXML` operate on **bare cell values**
  (`<integer>…</integer>`, `<table>…`) with **no `<file>` wrapper**, so they are
  unaffected by the namespace.

### Step 2 — `inputExtensions` guard *(hard error)*

- [content_pipeline.lua](../content_pipeline.lua):
  - In `validateSpec`: accept an optional `inputExtensions` array (validate it is
    a table of non-empty strings, mirroring the existing `extensions` check).
  - In `runTranscode`, the **explicit-selection** branch (after `findStageById`
    succeeds, ~L552): if `spec.inputExtensions` is set, compare the effective
    name's final extension against it; on mismatch, `badVal(name, …)` and abort
    the file (return `nil, name, kind, true`). The decode loop has already peeled,
    so `data.json.gz` arrives as effective name `data.json` and passes.
  - **Keep it distinct from `extensions`.** `extensions` means *auto-match*; if the
    three `json:*` layouts declared `extensions={"json"}` they would all auto-fire
    on any `.json` and trip the "multiple transcode stages match (ambiguous)"
    guard. `inputExtensions` is a **guard only**, never a matcher.
- [builtin_content_stages.lua](../builtin_content_stages.lua): add
  `inputExtensions={"json"}` to the `json:objects` / `json:rows` / `json:columns`
  stages, and `inputExtensions={"xml"}` to the new XML stage (Step 4).

### Step 3 — New module `xml_transcoder.lua` *(schema-free, modelled on `eav_transcoder`)*

- `xmlToTSV(name, content, _env, badVal, _ctx)` — forward source transform:
  - Parse the `<file>/<header>/<row>` structure reusing the primitives behind
    [deserialization.lua](../deserialization.lua) `parseXMLContent` (~L262).
  - **Reject if the root element is not in `urn:tabulua:table:1`** (defense-in-depth)
    via `badVal` + `nil`.
  - Read each `<header>` cell as a `name:type` string → the typed TSV header; read
    each `<row>`'s typed elements (`<integer>`, `<string>`, `<null/>`, …) → cells.
  - **Composite (`<table>`) cells — supported, symmetric with export.** Since
    `serializeXML` already emits nested `<table>…` for table-valued cells,
    `xmlToTSV` accepts them too: a `<table>` element is decoded (reusing the
    `parseXMLContent` recursion, the inverse of `serializeTableXML`) to a Lua
    table, then serialised into the TSV cell in the **same in-cell form the rest
    of the pipeline already uses for table-typed columns** (i.e. whatever
    `raw_tsv`/the parsers expect for a `table` column — verify against how a
    `table`-typed column round-trips through `serialize`/TSV today, so XML input
    and the other transcoders agree). This is the one place XML diverges from the
    JSON transcoders, which still reject composite values.
  - Emit typed TSV via `raw_tsv.rawTSVToString`. **No `ctx.typeName` consulted.**
- `tsvToXml(content, _env, _badVal)` — reversible `encode`:
  - Parse the wide TSV (`raw_tsv.stringToRawTSV`), regenerate the namespaced
    `<file>…` document reusing `serialization.serializeXML` per cell (which already
    handles `<table>`) and the same wrapping `exportXML` uses. Returns `(xmlText)`
    or `(nil, reason)`, matching the decode/transcode `encode` contract.
- Standard module scaffold (semver `VERSION`, `read_only` API table,
  `apiToString`/`apiCall`) as in the sibling transcoders.

### Step 4 — Register the XML stage

In [builtin_content_stages.lua](../builtin_content_stages.lua), alongside the JSON
and EAV registrations:

```lua
content_pipeline.register(NAME, {
    phase = "transcode",
    id = "xml:tabulua",               -- id-only: never auto-fires on a stray .xml;
                                      -- `xml:*` left open for user-defined formats
    inputExtensions = {"xml"},        -- guard (Step 2), NOT a matcher
    outputKind = "text",
    reversible = true,
    encode = xml_transcoder.tsvToXml,
    transform = xml_transcoder.xmlToTSV,
})
```

No `extensions` key — that is what keeps a non-data `.xml` asset from ever being
auto-interpreted.

### Step 5 — Generalise `reversibleTranscode` to id-selected reversible stages

The reformatter finds a re-encoder via
[content_pipeline.lua](../content_pipeline.lua) `reversibleTranscode(file_name)`
(~L468), which is **extension-keyed** and content-free. An id-only XML stage has no
`extensions`, so it is **not** found there, and the reformatter loop at
[reformatter.lua:446](../reformatter.lua#L446) does not currently have the per-file
`transcoder` id in hand. Without this, XML loads and validates but the reformatter
leaves it untouched as "derived source."

Do the **general** form (decided), so any current or future id-selected reversible
transcoder — not just XML — gets reformatter round-trip for free:

- Extend `reversibleTranscode` to take an **optional explicit transcoder id**:
  `reversibleTranscode(file_name, opt_transcoderId)`. When the id is given, resolve
  the stage by `id` (via the existing `findStageById("transcode", id)` path) and
  return its `{encode}` iff it declares `reversible` + `encode`; otherwise fall
  back to the current extension-keyed lookup. This keeps the EAV (extension) path
  working unchanged while covering id-only stages with one entry point.
- Thread the per-file `transcoder` id (from the `Files.tsv` ctx the loader already
  builds — the same value that drove `runTranscode`'s explicit selection) into the
  reformatter's reformat loop, and pass it to `reversibleTranscode`. The reformat
  loop currently keys only on `file_name`; it needs access to the per-file ctx that
  the loader produced, so that mapping (file → transcoder id) must be available to
  `processFiles`/the reformat pass.
- The encode output is **text**, so it writes via the text path (`safeReplaceFile`),
  like the EAV branch — not the binary gzip branch.

This subsumes what would otherwise be an XML-specific shim, and means a future
reversible JSON layout (or any id-selected transcoder) is reformatter-ready with no
further engine change.

### Step 6 — Tests

- New `spec/xml_transcoder_spec.lua`:
  - File-level round-trip: XML (our schema) → wide TSV → `tsvToXml` → XML, asserting
    structural/value equality.
  - Namespace-rejection: a `<file>` in a foreign/empty namespace selected with
    `transcoder=xml:tabulua` errors via `badVal`.
  - Schema-free header parsing: names/types are taken from `<header>`, no `typeName`
    supplied.
  - **Composite cells:** a row with a `<table>` value round-trips (XML → wide TSV →
    `tsvToXml` → XML) and agrees with how a `table`-typed column round-trips through
    the other formats.
  - Reformatter round-trip (Step 5): an `.xml` data file declared
    `transcoder=xml:tabulua`, when its wide TSV is reformatted, is rewritten in
    place via the id-selected `encode`.
- `inputExtensions` guard coverage (in the content-pipeline spec): guard fires on a
  mismatched extension under explicit selection; passes on a match and on a peeled
  `data.json.gz`.
- Regenerate exporter-level XML golden fixtures for the namespace (Step 1).

## Resolved During Planning

- **Composite cell values → supported (symmetric with export).** Folded into
  Step 3: `xmlToTSV` decodes `<table>` cells rather than rejecting them, since
  `serializeXML` already emits them. The one detail to nail at implementation time
  is the in-cell serialised form, which must match how a `table`-typed column is
  represented elsewhere in the pipeline.
- **`reversibleTranscode` generalisation → do the general form.** Folded into
  Step 5: `reversibleTranscode` gains an optional explicit-id parameter, so any
  id-selected reversible transcoder (not just XML) is reformatter-ready.

## Open

- **In-cell table form.** Confirm the exact serialisation a `table`-typed cell uses
  in TSV today (Lua-literal vs JSON vs other) so `xmlToTSV`'s `<table>` decoding and
  `tsvToXml`'s re-encoding agree with the rest of the pipeline rather than inventing
  a third form.
- **Final id spelling.** `xml:tabulua` is the working id; confirm before code (the
  `xml:*` family convention is the fixed part, the `tabulua` variant name is the
  bikesheddable part).
