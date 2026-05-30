# Content-Pipeline Registry: File-Name / Extension-Keyed Text Stages

## Status

Research and plan. This is the **second registry** foreseen by
[type_wiring.md §"COG processing — a different registry, not this one"](type_wiring.md):
that section concluded COG cannot live in the type-wiring registry and that the
right home is *"a separate registry — a content pipeline or text-stage registry
whose dispatch key is 'any text file' (or files matching glob X) and whose value
is the raw string. Today it would have one member (COG itself). Worth carving out
only if a second stage appears — a decompressor, a macro pre-expander, a
license-header stripper."*

Two such stages are now wanted, which is what triggered this plan:

- **Decompressors** — a `.gz` / `.zst` / `.br` input is decompressed so the rest
  of the codebase reads it as ordinary text.
- **Format transcoders** — a module that reads XML / JSON / SQLite (or Matrix
  Market `.mtx`, see [matrix_market_coo.md](matrix_market_coo.md)) and emits TSV
  text for further processing.

So the single-member case has become a multi-member pipeline, and the registry is
worth building. This document plans it.

Reconciled against the engine as of v0.21.0. The
[type-wiring registry](type_wiring.md) (Phases 1–3b landed) is the **sibling**
of this one, not its host: type-wiring dispatches on a file's *parsed* record
type; this registry dispatches on a file's *name* before any parsing happens.
The two never overlap (see §1).

## Scope

A registry of **content stages** that transform a file's bytes around parsing —
mostly after it is read from disk and before TSV parsing, but also (sink direction)
before an export artifact is written. Dispatch is by **path metadata** — extension,
basename pattern, directory — and/or **content sniffing** (magic bytes), never by
`typeName` (which does not exist yet at this point in the pipeline).

The pipeline operates on **bytes** and tracks each file's **content kind** — `text`
or `binary` (§3.11). The kind decides the terminal action:

- **text → parse** (the common case): TSV parsing, what *most* callers do.
- **text → write** (non-data text): a Markdown / HTML / plain-text file written out
  instead of parsed — doc generation (§3.10).
- **binary → write** (asset): a non-text file (image, audio, font, model, …)
  processed byte-to-byte and written to the export/build output, **never parsed and
  never EOL-normalised** (§3.11).

So "produces text" is only true for the first two terminals; the third is the binary
asset case. The pipeline is **format-agnostic** at the dispatch level — extension /
magic / directory matching works identically on text and binary — and COG in
particular is not TSV-specific: it runs on any *text* file in one of its comment
styles (`---` / `###` / `///`), so the same machinery that expands a COG block in a
`.tsv` can generate a `.md` doc, while binary stages ride the same registry without
ever touching the text path.

In scope:

- Decompression (`.gz`, `.zst`, …) — bytes → bytes/text.
- Transcoding structured formats (XML / JSON / SQLite / `.mtx`) → TSV text.
- Macro expansion — **COG**, which moves into this registry as its first member, in
  **both** directions and on **any** text format (§3.10), not only TSV.
- Data-driven generation of non-data text files (e.g. `.md` docs from TSV data) at
  export time (§3.10).
- **Binary asset stages** keyed by extension/magic — e.g. PNG/JPEG re-encode or
  resize, texture-atlas packing, audio transcode, font subsetting — for packages that
  carry game assets alongside their data (§3.11).
- Other whole-file text transforms keyed on name: license-header stripping,
  charset/EOL normalisation, include/macro expanders.

The pipeline is **bidirectional**: a *source* direction runs on read (decode →
transcode → macro-expand), and a *sink* direction runs on export (the inverse
order). The same registry holds both; a stage may supply a source `transform`, a
sink `transform`, or both. COG is the canonical example present in **both**
directions — it *expands* on read and *strips* on export (§3.9). v1 ships the full
source direction plus one sink stage (COG-comment stripping); heavier sink stages
(re-compression, TSV→JSON reverse-transcoding) are staged later (§6, Phase 5).

Out of scope (recorded in §9 and the relevant sub-sections):

- Reverse-transcoders for structured formats (TSV → XML/SQLite) beyond what
  [exporter.lua](../exporter.lua) already serializes — deferred to Phase 5.
- Per-row or per-cell transforms — those are [pre_processors.md](pre_processors.md)
  / type-wiring territory and run *after* parsing.
- Dispatch on parsed record type — that is the [type-wiring registry](type_wiring.md).

---

## 1. Why a separate registry (and where the line is)

The three reasons from [type_wiring.md](type_wiring.md) restated, because they are
the load-bearing justification for a *new* registry rather than another slot on the
existing one:

1. **It runs before the typeName is known.** Type-wiring dispatches by walking a
   file's `extends` chain. At the content stage no chain exists yet — the file is
   still a string (or raw bytes).
2. **A stage can synthesise the file's header.** COG already may emit the column
   header itself, so `typeName` is a *result* of the content stage, not an input.
   A JSON transcoder is the same: it manufactures the whole TSV including the
   header line. Type-driven dispatch is structurally impossible.
3. **The value being transformed is raw text/bytes, not a parsed file.** All four
   type-wiring contribution kinds (`onLoad`, processors, validators) operate on the
   post-parse `file` value; a content stage operates on the pre-parse string.

The clean dividing line:

| Concern | Registry | Dispatch key | Operates on |
|---|---|---|---|
| Decompress / transcode / macro-expand a file | **content pipeline** (this doc) | file name / extension / dir / magic bytes | raw bytes / text |
| Attach parsers, processors, validators to a record type | [type-wiring](type_wiring.md) | `extends` chain + tags of the parsed `typeName` | parsed `file` value |

---

## 2. Today's hard-wiring

[lua_cog.processContentBV](../lua_cog.lua#L235) is invoked at three call sites,
each with the identical shape:

| Call site | Context |
|---|---|
| [manifest_info.lua:237](../manifest_info.lua#L237) | manifest files |
| [files_desc.lua:161](../files_desc.lua#L161) | descriptor (`Files.tsv`-style) files |
| [manifest_loader.lua:356](../manifest_loader.lua#L356) | data files |

Each does, verbatim:

```lua
local content, err = readFile(file)          -- file_util.readFile, text mode "r"
if not content then ... end
raw_files[file] = content                    -- original on-disk text kept for round-trip
content = lua_cog.processContentBV(file, content, env, badVal)
local rawtsv = stringToRawTSV(content)        -- (manifest_loader then runs isMigrationScript)
```

This is exactly the "hard-coded preprocessing stage" pattern the type-wiring
refactor collapsed for parsed-file behaviour. Three copies of the same
read→cog→parse sequence; adding a decompressor would mean editing all three.

---

## 3. Design

### 3.1 The registry module

A new module `content_pipeline.lua`, shaped like `type_wiring.lua` but simpler
(there is no per-typeName cascade — every stage is module-level):

```text
-- Register a stage. moduleName is for provenance / dedup in errors.
content_pipeline.register(moduleName, stageSpec) → nil

-- Read a file from disk and run the full pipeline on it.
content_pipeline.readAndRun(file_name, env, badVal)
    → text, effectiveName            -- text ready for stringToRawTSV

-- Run the pipeline on already-in-memory bytes (for tests / embedded sources).
content_pipeline.run(file_name, bytes, env, badVal) → text, effectiveName

content_pipeline.getVersion() → string
```

A `stageSpec` is data + one function:

```lua
{
    phase     = "decode" | "transcode" | "macro",   -- coarse ordering (§3.3)
    priority  = 100,                                  -- tie-break within a phase
    -- matchers (any-of); at least one required:
    extensions = { "gz" },                            -- match by final extension
    basenameGlob = nil,                               -- e.g. "*.backup.tsv"
    directory  = nil,                                 -- match files under a dir
    magic      = "\x1f\x8b",                          -- leading-bytes sniff
    -- or a custom predicate, ORed with the above:
    matches    = function(effectiveName, bytes) return boolean end,
    -- the work — source direction (on read); sink direction (on export):
    transform     = function(effectiveName, content, env, badVal)
                        return newContent, newEffectiveName  -- newName optional
                    end,
    sinkTransform = nil,                              -- §3.9; the export-side inverse
    reversible    = false,                            -- §3.6 round-trip
    maxOutputBytes = 64 * 1024 * 1024,                -- §3.7 decompression-bomb cap
}
```

`transform` mirrors `processContentBV`'s signature (`name, content, env, badVal`)
so COG drops in with no adaptation. It returns the transformed content and an
optional **new effective name** — the mechanism that drives extension peeling
(§3.3). `sinkTransform` (optional) is the export-side counterpart, run by the
exporter in reverse phase order (§3.9); a stage with only `transform` is read-only,
a stage with only `sinkTransform` is export-only.

### 3.2 Dispatch keys

Four matcher kinds, ORed together, plus an escape-hatch `matches` predicate:

- **`extensions`** — match on the *final* extension of the current effective name
  (`gz`, `json`, `xml`, `sqlite`, `mtx`). The common case.
- **`basenameGlob`** — for multi-part conventions a single extension can't capture
  (`*.tsv.gz` already handled by peeling, but e.g. `*.min.json`).
- **`directory`** — "everything under `compressed/` is gzip", for layouts that
  encode format by location rather than extension.
- **`magic`** — leading-bytes sniff (gzip `\x1f\x8b`, zstd `\x28\xb5\x2f\xfd`,
  SQLite `"SQLite format 3\0"`). Required because extensions lie or are absent, and
  because it lets a decode stage fire on a mislabelled file. Magic matching is why
  the file is read in binary (§3.4).

### 3.3 Ordering: phases + extension peeling

Two composable ordering mechanisms.

**Phases** give the coarse, fixed order:

1. **`decode`** — bytes → bytes/text. Decompression, decryption. May run more than
   once (`.tsv.gz.enc` → decrypt → gunzip).
2. **`transcode`** — structured → TSV text. JSON / XML / SQLite / `.mtx` → TSV.
   Runs at most once per file (you don't transcode TSV into TSV).
3. **`macro`** — text → text template expansion. **COG.** Runs after decode/transcode,
   so a COG block can reference the decoded/transcoded content. The text need **not**
   be TSV: for a data file it is TSV-shaped (the COG block emits rows), but for a
   `.md`/`.html`/text file it is whatever that format is (the COG block emits
   documentation). COG is format-agnostic — it keys off its comment markers, not the
   file type. `macro` runs on `text` content only (§3.11).
4. **`asset`** — bytes → bytes, for `binary` content (§3.11). Image re-encode/resize,
   atlas packing, audio transcode, font subsetting. Runs last; its output takes the
   **write** (not parse) terminal. Skipped for `text` content.

The pipeline runs all matching `decode` stages (looping, see below), then the one
matching `transcode` stage, then all matching `macro` stages (text only), then all
matching `asset` stages (binary only). Within a phase, `priority` breaks ties (lower =
earlier). A file is `text` *or* `binary` (§3.11), so the `macro` and `asset` phases are
mutually exclusive per file — never both.

**Extension peeling** handles chained decoders. A stage may rename the effective
name by returning a second value; a decompressor strips its own extension:

```
data.tsv.gz.enc
  → decrypt stage (.enc peeled) → data.tsv.gz   (bytes)
  → gunzip stage  (.gz  peeled) → data.tsv       (text)
  → transcode: no stage matches ".tsv"
  → macro: COG runs on the text
  → stringToRawTSV
```

After each `decode` stage the dispatcher re-evaluates matchers against the **new
effective name**, looping until no `decode` stage matches. This is exactly how
Unix tooling composes (`.tar.gz`, `file.json.gz`) and keeps each stage ignorant of
the others. A `transcode` stage typically renames to `…​.tsv` (or simply marks the
content as TSV-text); a `macro` stage keeps the name.

The **effective name** is internal only. Files are still referenced in `Files.tsv`
and on disk by their **on-disk** name (`data.tsv.gz`); the pipeline maps on-disk →
effective for its own dispatch and never asks the user to name the post-peel form.
See §10 Q4.

### 3.4 Binary reading and EOL normalisation

[file_util.readFile](../file_util.lua#L315) opens with mode `"r"` (text mode → on
Windows the C runtime translates CRLF→LF during the read). Compressed and SQLite
inputs are **binary** and must be read with `"rb"`, or the byte stream is corrupted
before any decode stage sees it. Magic-byte sniffing (§3.2) also needs the true
bytes.

Plan: the pipeline reads **binary always**, and EOL normalisation becomes an
explicit core stage (a `macro`-phase, or a dedicated post-decode step) that runs
`file_util.unixEOL` ([file_util.lua:402](../file_util.lua#L402), already
`\r\n? → \n`) on text content before TSV parsing. This *subsumes* today's implicit
platform-dependent CRLF handling into one explicit, testable place — but it is a
**behaviour change** on Windows (the C runtime's translation moves into our code),
so it carries the same ablation risk type-wiring's L4 cleanup did. See §9 and the
Phase 1 ablation step.

**Critical: EOL normalisation runs on `text` content only.** A file whose content
kind is `binary` (§3.11) must **never** be passed through `unixEOL` — an image or
font with bytes that happen to look like `\r\n` would be silently corrupted. The
normalise stage therefore checks the current content kind and is a no-op on binary.
This is the main reason content kind is a first-class property of the pipeline rather
than an afterthought: reading binary always is only safe if every text-only transform
(EOL-normalise, COG, `stringToRawTSV`) is gated on the kind.

(Conservative alternative considered and rejected: read text-mode by default and
re-open binary only when a decode matcher fires. Rejected because magic-byte
sniffing needs the bytes *before* we know whether a decode stage matches —
chicken-and-egg. Reading binary once and normalising explicitly is simpler and
removes a platform-dependent surprise.)

### 3.5 `raw_files` and what counts as source of truth

Today `raw_files[file] = content` stores the **on-disk** text before COG — the
source the reformatter round-trips. That contract is preserved **for text files**:
`raw_files` keeps the **original on-disk bytes** of every text file, whatever the
pipeline later derives from them.

**Binary files that no stage needs are the exception**: they are *not* stored as
content at all but as a lightweight **passthrough descriptor** (see "Large binary
files" below) — and this holds whether or not the extension is recognised, since the
test is "does a stage need the bytes?", not "is the type known?". So `raw_files[file]`
is either a string (text, or a binary a stage actually consumed) or a
`{__passthrough=true, …}` table (binary nothing processes). Consumers must handle both.

The pipeline's output (decompressed / transcoded / COG-expanded text) is **derived
data**, not source of truth — the same principle COG-generated rows already follow
and that [mod_overrides.md §7.1](mod_overrides.md) states for patches.

#### Existing default: non-TSV files are copied verbatim, not ignored

A point worth stating explicitly, because it is the foundation the asset phase
(§3.11) builds on and is easy to misread: **the exporter does not ignore non-TSV
files today — it copies them through unchanged.** The current flow:

- **Load.** A file the loader doesn't recognise as a descriptor or data TSV is handled
  by [processUnknownFile](../manifest_loader.lua#L408-L422): it logs "Don't know how
  to process …" (debug for `.md`, warn otherwise) but still reads the bytes into
  `raw_files` verbatim. **No COG, no parsing** happens on this path today — the file
  is simply retained.
- **Export.** [exporter.lua:302](../exporter.lua#L302) iterates **all** of
  `raw_files`. TSV files are regenerated from the parsed model; every other file is
  written out with `content2 = content` — i.e. **verbatim**. The test
  [`spec/exporter_spec.lua:547-563`](../spec/exporter_spec.lua#L547-L563) ("should
  handle non-TSV files in raw_files") asserts a `readme.txt` exports as-is.

So the baseline is **passthrough copy**, not omission — and today it is a *dumb* copy
(the unknown-file path doesn't even run COG, unlike the data-file path which does at
its three call sites, §2). What the content pipeline adds is a chance to *intercept*
a file that would otherwise be copied verbatim and substitute processed bytes:

| File | Default (no matching stage) | With a matching stage |
|---|---|---|
| `.tsv` | regenerated from parsed model | (n/a — TSV path) |
| `.png` (binary) | **streamed** by reference, never loaded (see below) | with an `asset` stage (§3.11): loaded, processed (re-encode/resize), processed bytes exported |
| `.md`/`.txt` with COG markers | copied verbatim today; COG-expanded once §3.10 lands | COG-expanded with dataset in scope, plus optional `stripCog` |
| any other binary no stage needs | **streamed** verbatim by reference, never loaded (see below) | (n/a — would have a stage) |

**Consequence for the asset phase:** adding a `.png` stage does **not** change
*whether* files reach the export — they already do — only *what* lands for the
matched extension, and *how* it gets there. A binary nothing processes is
**streamed** to the export unchanged (never loaded); a binary a stage claims is
**loaded, processed, and the result written**. Files no stage needs keep reaching the
export untouched. "Ignored" is never the default; the design only ever upgrades a
stream-through copy into a processed copy.

(Whether the *binary-read* change in §3.4 alters any current text passthrough is an
ablation concern: today raw files are read in text mode, so a Windows CRLF file
copied verbatim could differ byte-for-byte once reads go binary. Covered by the
Phase 1 ablation step — for `text`-kind files the verbatim copy must match today's
output; `binary`-kind files are new territory with no prior behaviour to preserve.)

#### Large binary files: stream, never fully load (memory safety)

The verbatim-copy default above hides a real hazard once packages carry **game
assets**: today [processUnknownFile](../manifest_loader.lua#L408-L422) does
`raw_files[file] = readFile(file)` — it slurps the **entire file into memory as a
Lua string**, and the exporter holds *every* such string in `raw_files`
simultaneously. A handful of multi-hundred-MB textures, audio banks, or video files
would exhaust memory before anything is even exported. This is unacceptable for the
asset case and must be designed out, not patched later.

**Rule: a file's content is read into `raw_files` only if something will process it.
Any binary file that needs no processing — *whether or not its extension is
recognised* — is passthrough-by-reference: never loaded, never held in memory, only
streamed.** Concretely:

1. **The load decision is "needs processing", not "known vs unknown".** Two
   *independent* classifications apply to every file:
   - **Content kind** (`text`/`binary`, §3.11) — gates which transforms may run
     (text-only transforms never touch binary).
   - **Will any matching stage consume the bytes?** — the *load* decision, on its own
     axis.

   A file's content is fully read into `raw_files` only when the second answer is yes:
   a text file that will be parsed / COG-expanded, or a binary with a matched
   `decode`/`asset` stage that needs the bytes. **Every other binary gets the
   passthrough descriptor — including recognised binary formats that simply have no
   active stage.** A `.png` when no image stage is registered streams exactly like an
   unknown `.xyz`; "known-ness" is irrelevant, only "does a stage need the content".
   (This corrects an earlier "unknown ⇒ streamed" framing: an unknown extension is
   merely the *common* case of "no stage needs it", not the criterion itself.)

2. **Deciding this is cheap — no full read.** The decision needs only the file's
   **name** (extension / glob / directory matchers) plus, when a stage matches by
   `magic`, a **small fixed-size header read** (a few bytes), never the whole file.
   Only once a stage both matches *and* declares it needs the content is the file
   loaded in full (bounded by `maxOutputBytes`, §3.7). So classification costs a
   `stat` + at most a header read for every file, and a full read for none that
   won't be processed.

3. **No full read at load time for passthrough files.** Instead of the file's bytes,
   `raw_files` holds a small **placeholder descriptor** (the user's suggested
   "placeholder"):

   ```lua
   raw_files[file_name] = {
       __passthrough = true,        -- sentinel: not string content
       kind          = "binary",
       sourcePath    = <abs path>,  -- where to stream from at export
       size          = <bytes>,     -- from a stat, not a read
       -- mtime, etc. optional
   }
   ```

   The descriptor is O(1) in memory regardless of file size. Note `type()` flips from
   `string` to `table` — every `raw_files` consumer must tolerate that (see
   "Consumer impact" below).

4. **Streamed copy at export.** When the exporter meets a `__passthrough` descriptor
   it does **not** `writeFile(content)`; it **block-copies** `sourcePath` → export
   path through a new `file_util.copyFileStreamed(src, dst, blockSize)` helper that
   loops `src:read(blockSize)` / `dst:write(block)` (e.g. 64 KiB blocks) with both
   handles in binary mode. Peak memory is one block, not one file. (No such helper
   exists today — `file_util` only has content-based `writeFile`
   [:327](../file_util.lua#L327); the streamed copy is new work, Phase 6.)
   If the platform offers a cheaper primitive (hardlink / reflink / OS `copy`), the
   helper may use it when source and destination are on the same volume; the
   block-loop is the portable fallback.

5. **Stages that *do* process bytes opt back into loading.** A `.png` re-encode
   stage, a gzip `decode`, a JSON `transcode` — each inherently needs the content, so
   a *matched, content-needing* stage loads the file (bounded by `maxOutputBytes`,
   §3.7), processes it, and writes the result. Only files **no** stage needs stay
   streamed-by-reference. The placeholder records "does a stage need this?" so the
   loader knows which path to take. Large + needed-by-a-stage is the one case that
   still costs memory, and that is the stage author's explicit, bounded choice.

**Consumer impact (the `type()` flip).** Auditing the current `raw_files` consumers:

- **Exporter** [exporter.lua:302](../exporter.lua#L302) and the MessagePack path
  [:794](../exporter.lua#L794) iterate `pairs(raw_files)` and assume string content
  (`content2 = content`). Both must branch: `if content.__passthrough then
  copyFileStreamed(content.sourcePath, dst) else writeFile(content) end`.
- **Reformatter** [reformatter.lua:360](../reformatter.lua#L360) iterates
  **`tsv_files`** keys and only reads `raw_files[k]` for those — binary files have no
  `tsv_files` entry, so they never reach it. Safe unchanged, but assert it.
- **`loadReferencedFiles`** [manifest_loader.lua:713-724](../manifest_loader.lua#L713-L724)
  and **`processUnknownFile`** are the producers; they switch to writing descriptors
  instead of strings for binary files.

**Source of truth.** A passthrough binary's source of truth *is the file on disk* —
`raw_files` never held a copy to begin with, so the "derived data is not source"
rule (§3.5) is trivially satisfied: the exporter streams the untouched original.

### 3.6 Reformatter behaviour

The reformatter writes back the **source** representation, never the derived TSV:

- **`macro` (COG):** unchanged — COG already rewrites only its own blocks inside the
  original file via `lua_cog.rewriteFile`.
- **`decode`:** a stage may declare `reversible = true` and supply a paired
  re-encoder (e.g. gzip can re-compress); the reformatter then writes the source
  back compressed. Most decoders are marked `reversible = false` in v1 → the
  reformatter leaves the original bytes untouched.
- **`transcode`:** JSON/XML/SQLite → TSV has no automatic inverse, so transcoded
  files are **read-only inputs**: `reversible = false`, and the reformatter must
  skip rewriting them (it must not overwrite `data.json` with TSV). A future
  reverse-transcoder is the only way to round-trip these; out of scope (§9).

This is the natural extension of the existing "derived data is not source-of-truth"
rule to the new derivations.

### 3.7 Safety: sandbox, quotas, decompression bombs

Stages process **untrusted input bytes**, so:

- Transcoders authored as user code run under the **same sandbox + instruction
  quota** machinery COG already uses (`sandbox.protect` + `pcall`, see
  [lua_cog](../lua_cog.lua) and `manifest_info.loadCodeLibrary`).
- Decode stages must enforce **`maxOutputBytes`** — a gzip/zstd bomb expands a few
  KB into gigabytes. The pipeline aborts the file with a `badVal` error when a
  decode stage's output exceeds its declared cap.
- A `transcode` failure **aborts the file** (you cannot TSV-parse half-converted
  JSON), reported via `badVal`. A `macro`/COG failure keeps today's behaviour:
  report via `badVal`, fall back to the pre-stage content.

### 3.8 Error handling

Mirror `processContentBV`: stages report via `badVal`, never raise. The pipeline's
return value contributes to load success the same way COG's does today. On a fatal
stage error the file is dropped from the load (as a failed read already is at
[manifest_loader.lua:350-353](../manifest_loader.lua#L350-L353)).

### 3.9 Sink direction and COG-comment stripping

The sink direction is the export-time counterpart of §3.1–3.3: where the source
pipeline runs `decode → transcode → macro-expand` on the way *in*, the sink pipeline
runs the inverse phases on the way *out*. [exporter.lua](../exporter.lua) is the
sink **driver** — the analog of the three read-side call sites (§2) — invoking
`content_pipeline.runSink(file_name, content, env, badVal)` on a file's content
before it writes the export artifact.

**Reformatter vs. export — two different output operations.** They must not be
conflated:

- **Reformatter / in-place rewrite** *round-trips* the source: COG already keeps its
  markers and code block ([lua_cog.lua:106-159](../lua_cog.lua#L106-L159)) so the
  file stays re-runnable. Source of truth is preserved. No sink stage runs.
- **Export** produces a *derived distribution artifact*. This is where sink stages
  fire. They are **one-way / lossy** by nature and never written back over source.

**COG-comment stripping** is the first concrete sink stage and the worked example
for the whole sink direction — the `macro`-phase inverse of the COG source stage:

- Source `transform` = `lua_cog.processContentBV` (expand; keep scaffolding).
- Sink `sinkTransform` = a new `lua_cog.stripCog(content)` that removes the
  `---[[[ … ---]]]` code block and the start / `---[[[end]]]` markers, **keeping the
  generated content** inline as plain data. (The three comment styles `---` / `###`
  / `///` are already recognised by `processLines`; `stripCog` reuses the same line
  matchers.)
- It is **lossy**: the code block is discarded, so the export cannot regenerate
  itself. That is precisely why it is export-only and never round-tripped — the
  source file keeps its COG blocks; only the exported copy is stripped.
- **Opt-in.** Stripping is an export option (e.g. `exportParams.stripCog = true`),
  off by default so existing exports are unchanged. Phrasing the user asked for: "an
  option to strip the COG comments from the exported data."

**Interaction with the existing exporter.** [exporter.lua](../exporter.lua) already
regenerates TSV exports from the parsed `tsv_files` model and strips developer-only
*comment columns* ([exporter.lua:84-88](../exporter.lua#L84-L88)). COG markers are
whole *lines*, not columns, and survive into any export path that copies a file's
raw text (`content2 = content` for non-regenerated formats, e.g.
[exporter.lua:302](../exporter.lua#L302) and the MessagePack path at
[:794](../exporter.lua#L794)). The sink `stripCog` stage closes that gap uniformly,
for every format that passes raw content through, without each exporter
re-implementing marker detection.

### 3.10 Data-driven generation of non-TSV files (e.g. Markdown docs)

A primary future use of COG is **generating documentation from the data**: a `.md`
file containing COG blocks that read the loaded TSV datasets and emit reference
tables, type listings, changelogs, etc. This is the same `macro` stage as everywhere
else — COG is format-agnostic — applied to a file that is **never TSV-parsed**: the
pipeline produces the expanded Markdown and the driver writes it out.

Why this lands naturally in the **sink/export** direction: by export time the full
dataset is already loaded, so a doc template's COG block can reference *any* file's
rows through the same env COG already receives (the env "could contain a copy of all
already processed files" — [lua_cog.lua:91-92](../lua_cog.lua#L91-L92)). The exporter
(sink driver, §3.9) discovers doc-template files and runs them through the macro
stage with the dataset in scope.

Two sink behaviours compose for clean published docs:

1. **generate** — COG-expand the `.md` template against the data (produces content,
   keeps markers, like the source-direction expand).
2. **strip** — `stripCog` removes the markers so the published `.md` is clean.

`generate` then `strip` yields documentation with no COG scaffolding in the output.

**Markdown comment-visibility wrinkle.** COG's three marker styles are `---`, `###`,
`///` ([lua_cog.lua:104-117](../lua_cog.lua#L104-L117)). In Markdown these are *visible
markup* — `###[[[` renders as an H3 heading, `---` as a horizontal rule / front-matter
fence — so a COG block is ugly when the **source** `.md` is viewed directly (e.g. on a
git host). Two answers, not mutually exclusive:

- **Strip on export** (above) keeps the *published* output clean, but the *source*
  template still renders its markers when viewed raw.
- **Add a hidden comment style to COG** — the HTML comment `<!-- … -->`, which Markdown
  renderers suppress — so the source template is clean too. This is a small, isolated
  COG enhancement (a fourth marker style alongside `---`/`###`/`///`); recorded as an
  open question (§9 Q8) rather than committed here, because it touches COG's grammar.

**Open design point — how doc templates are discovered.** A doc `.md` is not a data
file, so it does not appear in `Files.tsv` the usual way. Options: a dedicated
`typeName`/passthrough marker, a convention (a `docs/` directory or `.md.cog`
extension), or an explicit export-parameter list. Deferred to the doc-generation phase
(§6, Phase 5); flagged in §9 Q9.

### 3.11 Binary / asset stages (non-text files)

Packages that carry game assets — images, audio, fonts, models, shaders — bring
non-text files that may need extension-keyed processing of their own: re-encode a PNG,
resize or generate mipmaps for a texture, pack a sprite atlas, transcode audio,
subset a font, strip metadata. The registry's **dispatch** half already supports this
unchanged — extension / `magic` / `directory` matching works on bytes — and §3.4
already reads every file binary. What makes binary a first-class case rather than an
accident is the **content kind** property and the terminal it selects.

**Content kind.** Every file in flight carries a kind, `text` or `binary`. A stage
declares the kind of its **output** (and may require a kind of its **input**):

```lua
{
    phase      = "asset",          -- §3.3; binary-terminal phase
    extensions = { "png" },
    inputKind  = "binary",         -- refuses to run on text
    outputKind = "binary",
    transform  = function(name, bytes, env, badVal) return newBytes end,
    maxOutputBytes = ...,          -- image bombs too (§3.7)
}
```

A `decode` stage may flip kind (gunzip of a `.txt.gz` yields `text`; of a `.png.gz`
yields `binary`) — it sets `outputKind` per file, or sniffs. **The default kind is
`binary`**: a file is `text` only if its extension is in the known text set (or a
stage claims it as text); everything else defaults to `binary`. The decisive rule
from §3.4: **text-only transforms (`unixEOL`, COG, `stringToRawTSV`) never run on
`binary` content.**

Content kind is one axis; the *load* decision (§3.5) is a separate one. Kind decides
*which transforms may run*; "does a stage need the bytes?" decides *whether the file
is read into memory at all*. A `binary` file with no matching content-needing stage —
**recognised format or not** — is streamed by reference and never loaded (§3.5
"Large binary files"); a `binary` with a matched `decode`/`asset` stage is loaded so
that stage can process it. Don't conflate "binary" with "streamed": all streamed
files are binary, but a binary is only streamed when nothing needs its content.

**The `asset` phase / terminal.** Add a fourth phase, `asset`, after `macro`, for
binary→binary work. A file that ends the pipeline as `binary` has the **write** (not
parse) terminal: it is copied/written to the export or build output, never TSV-parsed.
On the read side this matters little — assets are not loaded as engine *data* — so the
asset path is overwhelmingly an **export/build-time** concern, driven by the same sink
driver ([exporter.lua](../exporter.lua), §3.9) that handles doc generation. (A read-time
binary stage is permitted but has no data-loading consumer today; left available for a
future "asset referenced by a data row" need.)

**Round-trip.** Same rule as everywhere (§3.6): the asset *source* is not overwritten
by the processed form unless the stage is `reversible`. Processed assets land in the
export/build output; the source tree keeps the originals.

**Native libraries.** Real image/audio/font work needs C codecs (libpng, etc.), which
the sandbox does not expose — so binary asset stages are **engine-provided / trusted**,
exactly like the gzip and SQLite cases (§4, §9 Q2). A pure-Lua binary stage (e.g. a
trivial header rewrite) *can* come from a bootstrap, but the heavy codecs cannot.

**Safety.** Decompression-bomb logic (§3.7) applies verbatim — a tiny PNG can decode
to a gigabyte bitmap, so binary stages enforce `maxOutputBytes` too. A failing asset
stage aborts that file via `badVal` and is skipped from the output; it never aborts the
data load.

So the registry **does** allow non-text/image processing — but only because content
kind is tracked and binary is explicitly walled off from the text transforms. Without
that, "read binary always" (§3.4) would corrupt every asset. The asset terminal itself
is staged late (Phase 6) since it depends on no data-load path; the design hooks are
put in place from Phase 1 (the content-kind field).

---

## 4. User extensibility

Same three-path model as the type-wiring registry, with one fewer path because a
content stage is fundamentally a Lua function:

| Path | Reach | Why |
|---|---|---|
| **Engine code** (`builtin_content_stages.lua` seed module) | All phases, arbitrary Lua | Mirrors `builtin_wiring.lua`; COG + core EOL-normalise register here. |
| **Bootstrap (code library)** | `decode` / `transcode` / `macro` whose `transform` is sandboxed Lua | Reuses the [type-wiring `bootstrap` manifest field](type_wiring.md) + frozen `api`. Most transcoders are pure `(bytes) → text` functions — a natural sandbox fit. |
| **Pure-data (`TypeWiring.tsv` analog)** | **None** | A stage is a Lua function; it cannot be a TSV cell. (A future declarative "extension X → transcoder named Y" mapping could let a data file *select* an already-registered stage, but the transcoder itself stays code.) |

A real constraint to call out: production decompression (zlib) and SQLite reading
realistically need **C libraries / FFI**, which the sandbox does not expose. v1
therefore ships only stages implementable in pure Lua (COG already is; `.mtx` and
JSON are; EOL-normalise is) and treats native-lib stages (gzip, SQLite, XML via a C
parser) as **engine-provided** — registered by core or a trusted engine module, not
by sandboxed bootstrap code. See §9 Q2.

---

## 5. Pipeline integration

The three call sites in §2 collapse into one `content_pipeline.readAndRun` call.
Before:

```lua
local content, err = readFile(file)
raw_files[file] = content
content = lua_cog.processContentBV(file, content, env, badVal)
local rawtsv = stringToRawTSV(content)
```

After:

```lua
-- readAndRun reads binary, stores raw_files internally, runs decode→transcode→macro
local content = content_pipeline.readAndRun(file, env, badVal)   -- nil on fatal stage error
if not content then return end
local rawtsv = stringToRawTSV(content)
```

`raw_files` population moves inside `readAndRun` (it owns the read now). COG is no
longer named at the call sites — it is just the registered `macro` stage. The
`isMigrationScript(rawtsv)` check in `manifest_loader` is **unaffected**: it runs on
the post-pipeline `rawtsv`, exactly as it runs on post-COG text today.

---

## 6. Implementation phases

Each phase is independently shippable.

> **Woven with [cog_markdown.md](cog_markdown.md).** The two plans are implemented
> **together**, not one-then-the-other — cog_markdown's phases interleave with the
> ones below at the points marked **⏸ SWITCH** / **▶ RESUME**. Each switch is a
> self-contained unit of work that **must be committed separately** (the user does
> all commits — when a switch unit is complete, stop and let the user commit before
> continuing). The interleave order, at a glance:
>
> 1. **⏸ cog_markdown Phase 1** (HTML `<!---`/`--->` marker style in `lua_cog`) —
>    *before* CP Phase 1, so CP's COG `macro` stage and (later) `stripCog` handle all
>    four marker styles from the outset.
> 2. CP Phases 1 → 4.
> 3. **⏸ cog_markdown Phase 2** (eligible-extension auto-scan + discovery) — *before*
>    CP Phase 5, which needs discovery to find doc templates.
> 4. CP Phase 5 — **absorbs cog_markdown Phase 4** (generate-to-export + strip); they
>    are the same work seen from two sides.
> 5. **⏸ cog_markdown Phase 3** (in-place `--cog-docs` refresh) — *after* CP Phase 5.
> 6. CP Phase 6.

The switch points appear inline below, each just before the phase it precedes.

> **⏸ SWITCH to [cog_markdown.md](cog_markdown.md) → Phase 1 (HTML-comment marker
> style).** Do this **first**, before CP Phase 1 below. It is a pure `lua_cog.lua`
> grammar addition (the `<!---[[[` / `]]]--->` / `<!---[[[end]]]--->` markers + block
> form) with its own `spec/lua_cog_spec.lua` tests, independent of the registry.
> Landing it first means the COG `macro` stage registered in CP Phase 1 — and the
> `stripCog` added in CP Phase 5 — cover all four styles with no later retrofit.
> **Exception:** cog_markdown Phase 1's "teach `stripCog` the new markers" sub-step
> has no `stripCog` to teach yet; defer that single bullet to CP Phase 5.
> *Commit cog_markdown Phase 1 separately, then* **▶ RESUME** *here.*

**Phase 1 — `content_pipeline` module + migrate COG; zero feature change.**

- New `content_pipeline.lua` (`register`, `run`, `readAndRun`, `runSink`,
  `getVersion`) with the phase/peel dispatcher but only the `macro` phase exercised.
- **Content-kind field** (`text`/`binary`, §3.11) threaded through from the start, even
  though only `text` is used in Phase 1 — so the EOL-normalise / COG / parse steps are
  gated on kind from day one and the later `asset` phase needs no retrofit. The core
  EOL-normalise stage is registered as `text`-only here.
- **Binary passthrough-by-reference + `raw_files` descriptor** (§3.5 "Large binary
  files") — a memory-safety change, not a feature, so it belongs in Phase 1 even
  though asset *processing* waits for Phase 6. A binary file no stage needs (recognised
  type or not) gets a `{__passthrough=true, sourcePath, size}` descriptor instead of
  being slurped into a string; the exporter learns to block-stream them via a new
  `file_util.copyFileStreamed`; every `raw_files` consumer is made descriptor-tolerant
  (§3.5 "Consumer impact"). Without this, the binary-read switch above would make the
  existing "load every unknown file as a string" behaviour even more dangerous for
  large assets. Tests: a large binary fixture loads as a descriptor (not a string) and
  exports byte-identically via streaming; peak memory does not scale with file size;
  the reformatter ignores binary files.
- New `builtin_content_stages.lua` seed module (mirrors `builtin_wiring.lua`):
  registers COG as the `macro` stage (`transform = lua_cog.processContentBV`,
  matcher = "any file") and a core `normalize-eol` stage. (COG now recognises the
  fourth `<!---` marker style from the switch above — no extra work here.)
- Switch the read to binary (`"rb"`) inside `readAndRun`; EOL normalisation becomes
  the explicit core stage.
- Collapse the three call sites (§5).
- **Ablation tests** for the EOL behaviour change: CRLF / LF / mixed / no-trailing-EOL
  fixtures on Windows and POSIX must produce identical `rawtsv` to the pre-refactor
  pipeline. Treat any difference as a bug to fix here, exactly as type-wiring's L4
  ablation did.
- Tests: existing `spec/lua_cog_spec.lua` behaviour preserved through the new entry
  point; new `spec/content_pipeline_spec.lua` for register/dispatch/peel mechanics.

**Phase 2 — `decode` phase + first decompressor.**

- Dispatcher runs the `decode` loop (extension peeling + magic sniffing) ahead of
  `transcode`/`macro`.
- First concrete stage: gzip (pure-Lua inflate, or engine-provided helper —
  §9 Q2), with `maxOutputBytes` enforcement and a decompression-bomb test.
- Tests: `data.tsv.gz` loads identically to `data.tsv`; chained `*.gz.gz`; bomb cap
  trips `badVal`; magic-byte match on a `.gz` renamed to `.dat`.

**Phase 3 — `transcode` phase + first transcoder.**

- Dispatcher slot for the single matching `transcode` stage.
- First transcoder: **Matrix Market `.mtx`** — [matrix_market_coo.md](matrix_market_coo.md)
  is already specced, pure text, and the cleanest first case. Its reader becomes the
  `transcode` stage's `transform` (the `raw_tsv` reader/writer that doc proposes can
  be the implementation; the pipeline supplies the *dispatch*). Then JSON.
- `reversible = false`; reformatter skips rewriting transcoded sources (§3.6).
- Tests: `matrix.mtx` → expected TSV; malformed input aborts the file via `badVal`;
  reformatter leaves the `.mtx` untouched.

**Phase 4 — user-extensibility + reformatter integration.**

- Bootstrap path registers sandboxed `decode`/`transcode`/`macro` stages via the
  shared type-wiring `api` (extend `makeBootstrapAPI` or add a sibling factory).
- Reformatter honours `reversible` and the re-encoder pairing for round-trip.
- Tests: a bootstrap-registered JSON transcoder; reversible gzip round-trips;
  non-reversible transcode is skipped on reformat.

> **⏸ SWITCH to [cog_markdown.md](cog_markdown.md) → Phase 2 (eligible-extension
> auto-scan + discovery).** Do this **before** CP Phase 5 below — Phase 5's doc
> generation needs a way to *find* `.md` templates. It adds the COG-eligible
> extension set to the registry (built in CP Phase 1) and the `needsCog`-gated
> directory walk over package roots, plus the `.cogignore`/opt-out. This resolves
> §9 Q9. *Commit cog_markdown Phase 2 separately, then* **▶ RESUME** *here.*

**Phase 5 — sink direction: COG-comment stripping + data-driven doc generation
(§3.9, §3.10). Absorbs [cog_markdown.md](cog_markdown.md) Phase 4.**

Depends on CP Phase 1 (the `macro` phase + the module) and on cog_markdown Phase 2
(discovery, just completed in the switch above). Independent of the decode/transcode
phases (2–4), so the sink half *could* ship right after Phase 1 — but the doc-gen
half needs discovery, hence the switch ordering. The "generate-to-export + strip"
work here **is** cog_markdown Phase 4 viewed from the pipeline side; implement them
as one.

- Add `content_pipeline.runSink` (inverse phase order) and the `sinkTransform` slot.
- New `lua_cog.stripCog(content)` reusing the existing `---`/`###`/`///` line
  matchers **plus the `<!---` style** added in cog_markdown Phase 1; registered as
  the COG `macro` stage's `sinkTransform`. (This is where cog_markdown Phase 1's
  deferred "teach `stripCog` the new markers" sub-step lands.)
- [exporter.lua](../exporter.lua) becomes the sink driver: an opt-in
  `exportParams.stripCog` (default off) routes a file's raw content through
  `runSink` before writing, covering every raw-passthrough export path
  ([:302](../exporter.lua#L302), MessagePack [:794](../exporter.lua#L794)) uniformly.
- **Doc generation:** the exporter discovers non-data text templates (via the
  cog_markdown Phase 2 scan), runs them through the `macro` stage with the full
  loaded dataset in the env, and writes the expanded output — optionally composed
  with `stripCog` for clean published docs. These files are **never TSV-parsed**
  (§3.10).
- Tests: a COG file exports with markers + code block removed and generated rows
  kept when `stripCog=true`; unchanged when `stripCog=false`; the *source* file is
  never modified (only the export copy); stripping is idempotent; a `.md` template
  generates expected content from a fixture dataset and is not TSV-parsed.

> **⏸ SWITCH to [cog_markdown.md](cog_markdown.md) → Phase 3 (in-place `--cog-docs`
> refresh).** Do this **after** CP Phase 5. It is a standalone command/CI step
> (`lua_cog.rewriteFile` + the loaded data env) that rewrites source `.md` templates
> in place, keeping their markers — independent of the export path. *Commit
> cog_markdown Phase 3 separately, then* **▶ RESUME** *at CP Phase 6.*

**Phase 6 (optional) — heavier formats, the `asset` phase, full reverse-transcode.**

- XML and SQLite transcoders (need native parsers — engine-provided, §9 Q2).
- **The `asset` phase + binary asset stages** (§3.11): the binary-terminal phase, a
  first engine-provided image stage (e.g. PNG re-encode/resize via a C codec), driven
  by the exporter at build time, with `maxOutputBytes` enforcement and an image-bomb
  test. The content-kind plumbing **and** the binary streaming/descriptor path from
  Phase 1 (§3.5) mean this adds a phase, not a refit — a matched asset stage simply
  opts back into loading the bytes (§3.5 point 5) where binaries no stage needs stay
  streamed.
- Reversible `decode` re-encoders (re-compress on export) and structured
  reverse-transcoders (TSV → JSON/XML) as `sinkTransform`s beyond what
  [exporter.lua](../exporter.lua) already serialises. Symmetric to the source
  direction; deferred until a concrete need appears.

---

## 7. What can go wrong (bad input)

| Risk | Mitigation |
|---|---|
| Decompression bomb (KB → GB) | `maxOutputBytes` cap per decode stage; abort + `badVal` (§3.7). |
| Binary file read in text mode corrupts bytes | Pipeline reads binary always (§3.4). |
| EOL-normalise / COG / TSV-parse run on a binary asset and corrupt it | Content kind is tracked; text-only transforms are gated on `text` kind and no-op on `binary` (§3.4, §3.11). |
| Image/asset decode bomb (tiny file → huge bitmap) | `maxOutputBytes` cap on `asset`/`decode` stages, same as compression bombs (§3.7, §3.11). |
| Asset stage needs a C codec the sandbox can't load | Binary asset stages are engine-provided/trusted, not sandboxed bootstrap (§3.11, §9 Q2). |
| Large binary asset (100s of MB) loaded into `raw_files` exhausts memory | A binary no stage needs is never loaded — regardless of whether its type is recognised, `raw_files` holds an O(1) passthrough descriptor and the exporter block-streams the original (§3.5 "Large binary files"). |
| A `raw_files` consumer assumes string content and trips on a descriptor table | The `type()` flip is audited; exporter branches on `__passthrough`, reformatter only touches `tsv_files` keys (§3.5 "Consumer impact"). |
| EOL behaviour change breaks existing data on Windows | Phase 1 ablation tests across CRLF/LF/mixed (§6). |
| Two stages match the same file in the same phase | `priority` orders them; `transcode` is single-match (ambiguity is a `badVal` error). |
| Extension-peel loop never terminates (a stage that doesn't shorten the name) | Decode loop requires the effective name to change each iteration, else it stops and warns. |
| Transcoder produces malformed TSV | `transcode` failure aborts the file via `badVal` (§3.7). |
| Reformatter overwrites a `.json` source with derived TSV | `reversible = false` transcodes are read-only; reformatter skips (§3.6). |
| Native-lib transcoder registered from sandboxed bootstrap (no FFI) | Native-lib stages are engine-provided only; bootstrap stages are pure-Lua (§4, §9 Q2). |
| `Files.tsv` references the post-peel name `data.tsv` but the file on disk is `data.tsv.gz` | Files are referenced by on-disk name; effective name is internal (§3.3, §10 Q4). |

---

## 8. Relationship to existing TODOs

- [type_wiring.md](type_wiring.md) §"COG processing — a different registry, not
  this one" **is the origin** of this plan. That section should now point here
  instead of saying "worth carving out only if a second stage appears" — the second
  (and third) stages have appeared.
- [matrix_market_coo.md](matrix_market_coo.md) — its `.mtx` reader is the natural
  **first transcoder** (Phase 3). That doc can keep the `raw_tsv` reader/writer as
  the *implementation*; this registry provides the *extension-keyed dispatch* so the
  reader fires automatically on `.mtx` inputs instead of being called by hand.
- [pre_processors.md](pre_processors.md) / [type_wiring.md](type_wiring.md) — the
  *parsed-file* siblings. Content stages run strictly **before** them; nothing here
  touches rows or cells.
- [mod_overrides.md](mod_overrides.md) — a mod may ship its patch/data/overlay files
  compressed or in a structured format; the content pipeline decodes/transcodes them
  to TSV **before** schema overlays, patches, and cross-package processors run. The
  reformatter "derived data is not baked back" rule (§7.1 there) now also covers
  content-pipeline-derived files. Cross-referenced from that document.
- [lua_cog.lua](../lua_cog.lua) — becomes a registered `macro` stage in **both**
  directions: `processContentBV` as the source `transform` (expand, unchanged) and a
  new `stripCog` as the `sinkTransform` (export-time comment stripping, §3.9). Its
  expansion implementation is unchanged; only its invocation moves and a strip helper
  is added. COG is **format-agnostic** (§3.3, §3.10): the same stage that expands a
  `.tsv` block generates a `.md` doc from the data. A possible follow-on COG grammar
  change — an HTML-comment marker style for clean Markdown source — is tracked in §9 Q8.
- [exporter.lua](../exporter.lua) — the **sink driver** (Phase 5). Today it already
  strips developer-only *comment columns* and regenerates TSV from the parsed model;
  it gains an opt-in `stripCog` export option that routes raw-passthrough content
  through `content_pipeline.runSink`, so COG marker *lines* are dropped uniformly
  across export formats rather than per-exporter (§3.9).

---

## 9. Open questions

1. **EOL normalisation behaviour change.** Moving Windows CRLF handling out of the C
   runtime and into an explicit stage is cleaner but observable. Confirm via Phase 1
   ablation that no existing fixture changes. *Lean: do it, gated on ablation.*

2. **Native libraries for gzip / SQLite / XML.** Pure-Lua inflate exists and is fine
   for `.gz`; SQLite and a real XML parser realistically need C. Options: (a) ship
   pure-Lua-feasible stages in v1, engine-provide the rest; (b) sanction a small FFI
   allowlist for trusted engine modules; (c) shell out to an external tool. *Lean:
   (a) for v1, revisit (b) when SQLite support is actually requested.*

3. **Reformatter for transcoded files — skip vs reverse.** v1 skips (read-only
   source). A reverse-transcoder makes round-trip possible but doubles every format's
   surface. *Lean: skip in v1; full reverse-transcode is Phase 6. Note the sink
   direction itself is not deferred — the `macro`-phase sink (COG-comment stripping)
   ships in Phase 5; only the heavier decode/transcode reverses wait.*

4. **COG-strip scope — markers only, or markers + generated rows?** The user's ask is
   "strip the COG comments," i.e. remove the `---[[[ … ---]]]` code block and markers
   but **keep** the generated data rows (§3.9). A second mode that also drops the
   generated block (leaving nothing) has no obvious use case. *Lean: keep-generated-
   rows only; revisit if a "drop everything COG-touched" need appears.*

5. **On-disk name vs effective name in `Files.tsv`.** Should a descriptor reference
   `data.tsv.gz` or `data.tsv`? *Lean: on-disk name (`data.tsv.gz`); the engine maps
   on-disk → effective internally, so authors never write the peeled form.* Confirm
   this against how `fileName:filepath` matching and joins resolve names.

6. **Caching decoded output.** Decompression is the only expensive stage; reads
   happen once per load, so memoisation is unnecessary in v1. Revisit if hot-reload
   re-decodes large inputs repeatedly.

7. **Per-file opt-out.** Should a file be able to declare "do not run the pipeline on
   me" (e.g. a literal `.gz` that is genuinely data, not a compressed TSV)? Magic-byte
   plus a directory/extension allowlist covers most cases; an explicit opt-out marker
   can be added if false-positive transcoding shows up.

8. **A hidden COG comment style for Markdown.** *Resolved — see
   [cog_markdown.md](cog_markdown.md) Part 1.* COG's `---`/`###`/`///` markers are
   *visible* markup in Markdown (§3.10); the answer is a fourth, HTML-comment marker
   style using the sigil `<!---` … `--->` (distinct from a plain `<!-- -->` so COG
   ignores ordinary comments), invisible when rendered.

9. **Discovering non-data text templates.** *Resolved — see
   [cog_markdown.md](cog_markdown.md) Part 2.* The answer is **auto-scan by eligible
   extension, gated by `needsCog`** (a no-op on files without a COG block), with an
   opt-out and an explicit-include escape hatch — not a mandatory per-file list. The
   content-pipeline registry holds the eligible-extension set.

---

## 10. Risks & alternatives considered

- **"Just add a fourth phase to the type-wiring registry."** Rejected for the three
  structural reasons in §1 — the dispatch key (name, not type) and the value (bytes,
  not parsed file) are fundamentally different. Conflating them would force every
  type-wiring contribution kind to special-case a pre-parse, no-typeName phase.

- **"Keep COG hard-wired; only add decompression."** Would leave two parallel
  preprocessing mechanisms and three more call sites to edit per new stage. Migrating
  COG into the registry is what makes the three call sites collapse to one.

- **"Dispatch purely on magic bytes, ignore extensions."** Magic is necessary
  (mislabelled files) but not sufficient — text formats (`.json` vs `.tsv`) share no
  reliable magic, and directory/convention layouts encode format by location.
  Extensions + glob + dir + magic together cover the real cases.

- **Performance.** One extra pass over each file's bytes per matching stage. For
  files with no registered stage beyond COG, the cost is identical to today. Decode
  and transcode are O(file size) and run once per load.
