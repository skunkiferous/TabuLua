# COG for Markdown (and other non-TSV text): hidden markers + triggering

## Status

Research and plan. A focused slice of [content_pipeline.md](content_pipeline.md):
that document raised, but deferred, two questions about running COG on `.md`
files — its open questions **Q8** (a hidden comment style for Markdown) and **Q9**
(how non-data text templates are discovered). This plan answers both concretely.

> **Implementation ordering lives in [content_pipeline.md §6](content_pipeline.md).**
> The two plans are built **together**: content_pipeline.md §6 is the single driving
> sequence and weaves this document's phases in at **⏸ SWITCH** points. Don't infer
> ordering from this file's "Part 3 — Implementation phases" in isolation — follow
> the §6 weave. Each switch unit is **committed separately** (the user does the
> commits). The mapping content_pipeline.md uses:
>
> | This doc | Where it lands in the §6 weave |
> |---|---|
> | Phase 1 — HTML `<!---` markers | **Before** CP Phase 1 (pure `lua_cog` change; its `stripCog` sub-step defers to CP Phase 5) |
> | Phase 2 — auto-scan + discovery | **Before** CP Phase 5 (Phase 5 doc-gen needs it) |
> | Phase 3 — in-place `--cog-docs` refresh | **After** CP Phase 5 |
> | Phase 4 — generate-to-export + strip | **Absorbed into** CP Phase 5 (same work) |

Depends on: [lua_cog.lua](../lua_cog.lua) (a small grammar addition) and, for the
auto-discovery option, the content-pipeline registry's notion of "eligible
extensions". Neither the decode nor transcode phases of content_pipeline.md are
required.

## Summary

COG already works on any text file written in one of its three comment styles
(`---` / `###` / `///`) — it keys off its markers, not the file type. Two things stop
it being *usable* for Markdown today:

1. **The markers are visible markup in Markdown.** `###[[[` renders as an H3 heading,
   `---` as a horizontal rule / front-matter fence. A COG block pollutes the rendered
   `.md` and the raw source view (e.g. on a git host).
2. **Nothing triggers COG on `.md` files.** The three read-side call sites only COG
   files that are about to be TSV-parsed (manifests, descriptors, data). A `.md`
   documentation file is never read as data, so COG never sees it.

This plan adds (Part 1) a **hidden HTML-comment marker style** so COG blocks are
invisible in rendered and raw Markdown, and (Part 2) a **triggering / discovery**
mechanism so `.md` (and other non-TSV text) files get COG-processed — recommending
**auto-scan by extension, gated by `needsCog`**, over an explicit per-file list.

The motivating use case: **generate documentation from the TSV data** — reference
tables, type listings, changelogs — by embedding COG blocks in `.md` files that read
the loaded datasets.

---

## Part 1 — A hidden comment-marker style for Markdown

### 1.1 Why `<!---` and not `<!--`

Markdown's only hidden comment is the HTML form `<!-- … -->`. But COG must **not**
fire on every HTML comment — a `.md` file legitimately contains ordinary `<!-- … -->`
comments that have nothing to do with COG. So COG needs its own *sigil*, distinct
from a plain comment, exactly as `---` / `###` / `///` are distinct line sigils.

The user's suggestion is the right one: **`<!---`** (three dashes) is the COG sigil;
plain `<!--` (two dashes) is an ordinary comment COG ignores. `<!---` is still a valid
HTML comment opener (the comment body simply begins with `-`), so it stays hidden when
rendered. The symmetric close is **`--->`** (three dashes before `>`), which HTML
parses as a normal `-->` close preceded by one `-` of body. The visual echo of `---`
is deliberate — this is "the `---` COG style, wrapped to be HTML-invisible".

### 1.2 Mapping COG's five-part block to HTML comments

COG's block is five parts ([lua_cog.lua:46-63](../lua_cog.lua#L46-L63)): start
marker, code lines, code-end marker, the generated output, output-end marker. Today,
for the `---` style:

```text
---[[[
---return "generated text"
---]]]
generated text
---[[[end]]]
```

Two candidate HTML encodings.

**(A) Block form — recommended.** The code lives inside *one* multi-line HTML comment;
the generated output sits outside it (visible); the end marker is its own one-line
comment:

```markdown
# Item Reference

<!---[[[
local out = {"| Name | Price |", "|---|---|"}
for _, item in ipairs(files["Item.tsv"]) do
  out[#out+1] = ("| %s | %d |"):format(item.name, item.price)
end
return table.concat(out, "\n")
]]]--->
| Name | Price |
|---|---|
| Sword | 100 |
<!---[[[end]]]--->
```

- `<!---[[[` opens an HTML comment that stays open across the raw Lua lines and is
  closed by `]]]--->` (which doubles as the code-end marker). The whole code block is
  therefore one hidden comment.
- The generated table is plain Markdown — **visible** when rendered.
- `<!---[[[end]]]--->` is a self-contained hidden comment marking the end of the
  regenerated region.

Authoring ergonomics are good: the Lua is written plainly, no per-line prefix — which
matters because doc-generation blocks are real loops, not one-liners.

**(B) Per-line form — conservative fallback.** Mirrors the existing styles exactly,
wrapping every marker and code line:

```markdown
<!---[[[--->
<!---local out = {"| Name | Price |"}--->
<!---return table.concat(out, "\n")--->
<!---]]]--->
| Name | Price |
<!---[[[end]]]--->
```

Smaller parser change (it reuses the existing "strip a fixed prefix per code line"
path), but verbose and awkward for multi-line code.

**Recommendation: (A) block form**, with (B) recorded as the lower-effort alternative.
They are not mutually exclusive — the parser can accept both — but (A) is what makes
real doc generation pleasant.

### 1.3 The `-->`-in-code gotcha (block form)

In block form the code is inside a single HTML comment, so a literal `-->` appearing
*in the Lua code* would close that comment early in a **renderer's** eyes (the COG
parser itself is unaffected — it scans for the `]]]--->` line, not for `-->`). The
consequence is only cosmetic-in-source: a renderer would show code after the stray
`-->`. Lua's own `--` comments are **safe** (only `-->` closes an HTML comment), and a
literal `-->` in code is rare.

Mitigations, in order of preference:

- **Document the restriction**: avoid a literal `-->` inside a block-form code body
  (write `--` `>` apart, or use the per-line form for that block).
- The **per-line form** contains the damage to a single line if it ever matters.

This is a documentation/lint concern, not a blocker; recorded as Part 4 Q1.

### 1.4 Parser changes in `lua_cog`

The state machine in [processLines](../lua_cog.lua#L93-L163) needs a fourth style.
Concretely:

- **Marker recognition.** Add HTML variants to the three `line:match` groups:
  - output-end: `^<!%-%-%-%[%[%[end%]%]%]%-%->` (i.e. `<!---[[[end]]]--->`)
  - start: `^<!%-%-%-%[%[%[` (`<!---[[[`)
  - code-end: `^%]%]%]%-%->` (`]]]--->`) — note this marker does **not** start with
    the sigil, because in block form it is the *close* of the comment opened by the
    start marker.
- **Code accumulation depends on the opening style.** Record which style opened the
  block. For the line-comment styles (`---`/`###`/`///`) keep today's behaviour: each
  code line must start with the sigil and is stripped with `line:sub(4)`
  ([lua_cog.lua:152-158](../lua_cog.lua#L152-L158)). For the HTML block style,
  accumulate the **raw** line (no sigil required, no prefix stripped) until the
  `]]]--->` code-end.
- **`needsCog`** ([lua_cog.lua:204-208](../lua_cog.lua#L204-L208)) gates all
  processing on the presence of an end marker; add the `<!---[[[end]]]--->` pattern so
  Markdown files are detected.
- **Nesting / error checks** ([lua_cog.lua:109-130](../lua_cog.lua#L109-L130)) carry
  over unchanged in meaning; just include the new marker forms.

Everything else (sandbox, quota, env, output buffering) is unchanged. The strip
helper planned in [content_pipeline.md §3.9](content_pipeline.md) (`lua_cog.stripCog`)
likewise just learns the new marker forms.

### 1.5 Visibility summary

| State | What the reader sees |
|---|---|
| Rendered `.md` | Only the generated output (all `<!--- … --->` parts hidden). |
| Raw `.md` (e.g. git host) | Generated output + invisible-when-rendered HTML comments; no heading/rule pollution. |
| Exported `.md` with `stripCog` ([content_pipeline.md §3.9](content_pipeline.md)) | Only the generated output; markers and code removed entirely. |

---

## Part 2 — Triggering: which files get COG, and when

### 2.1 The choice

Two ways to decide which non-TSV files COG should process:

- **(1) Explicit list.** Authors register each COG-processed non-data file (a manifest
  field, a `Files.tsv` passthrough row, or an export-parameter list).
- **(2) Auto-scan by extension.** The engine walks the package directories and, for
  every file with a COG-eligible extension (`.md`, `.markdown`, `.html`, `.txt`, …),
  runs COG **if the file actually contains COG markers**.

### 2.2 Recommendation: auto-scan, gated by `needsCog`

**Recommend (2).** The decisive fact is that COG already has
[`needsCog(content)`](../lua_cog.lua#L204-L208) — it returns false unless the file
contains an end marker. So a broad scan is **cheap and safe**: a `.md` with no COG
block is a no-op (one substring check), and only files that *opt in by containing a
COG block* are processed. This gives zero-config authoring — drop a `.md` with a
`<!---[[[ … ]]]--->` block anywhere in the package and it just works — without the
maintenance burden and "forgot to register it" failures of an explicit list.

The content-pipeline registry is the right home for the **eligible-extension set**:
the `macro` stage (COG) declares which extensions trigger a scan, so adding `.html`
later is a one-line registry change rather than an engine edit. (This is the
"the new registry should allow that" capability the user asked for.)

Keep a thin escape hatch, not a mandate:

- **Opt-out** for a directory or file (a `.cogignore`, or an exclude glob in the
  manifest) for the rare case where a stray marker shouldn't be processed.
- **Explicit include** for files outside the scanned roots (uncommon).

So: auto-scan by default, explicit list only as an override — not the primary
mechanism.

### 2.3 Discovery

Data files are enumerated via `Files.tsv`; doc files are not. The scan reuses the
existing directory walk ([file_util.getFilesAndDirs](../file_util.lua),
[sortFilesBreadthFirst](../file_util.lua)) over the **same package roots already
walked for data files**, filtered to the eligible extensions. Docs therefore live
alongside the data they document, and the export output can mirror the source layout.

`.tsv` is **not** in the eligible-extension set for this scan — data files are already
COG-processed on read at the three existing call sites; the scan only covers non-TSV
text, so nothing is double-processed.

### 2.4 Two modes, one engine

The same COG + data env serves two destinations:

- **Generate-to-export (primary, for published docs).** Read the template, COG-expand
  with the full dataset in the env, write the result to the **export directory** —
  optionally `stripCog` for a clean published file. The source template is untouched.
  Driven by [exporter.lua](../exporter.lua) (the sink driver,
  [content_pipeline.md §3.9-3.10](content_pipeline.md)).
- **In-place refresh (for checked-in docs).** Rewrite the **source** `.md` keeping its
  markers, to keep a committed `README.md` current with the data — the classic `cog`
  use ([lua_cog.rewriteFile](../lua_cog.lua#L185-L201)). Suitable for a build/CI step
  or a `--cog-docs` command. Markers are **kept** (it must stay re-runnable), which is
  exactly why the hidden HTML style (Part 1) matters for this mode.

### 2.5 The env (data access)

Doc blocks need to read the data. They use the **same env COG already receives** — the
one that "could contain a copy of all already processed files"
([lua_cog.lua:91-92](../lua_cog.lua#L91-L92)). Generation runs **after** the dataset
is fully loaded (generate-to-export at export time; in-place refresh after the normal
load), so a template can reference any file's rows (illustrated above as
`files["Item.tsv"]`; the exact binding is whatever the existing COG env exposes —
to be confirmed against `loadEnv` shape during implementation).

### 2.6 When it runs in the pipeline

- Generate-to-export: a pass inside the export flow, after data load, alongside
  the other sink stages. Ordering with `stripCog`: **expand, then strip** (generate the
  content, then remove scaffolding) — see [content_pipeline.md §3.10](content_pipeline.md).
- In-place refresh: a standalone step (command/CI), independent of export.

Neither touches TSV parsing — these files are produced, not parsed (the pipeline's
"produces text, parsing is optional" property,
[content_pipeline.md §Scope](content_pipeline.md)).

---

## Part 3 — Implementation phases

Each phase is independently shippable. **For *ordering relative to the content
pipeline*, follow the [content_pipeline.md §6](content_pipeline.md) weave, not the
order listed here** — these phases are interleaved with CP's at the ⏸ SWITCH points
there, and each is committed separately (the user commits). The list below defines
*what each phase contains*; §6 defines *when each runs*.

**Phase 1 — HTML-comment marker style in `lua_cog`.** *(§6: before CP Phase 1.)*

- Add the `<!---[[[` / `]]]--->` / `<!---[[[end]]]--->` markers and block-form raw code
  accumulation to `processLines`; extend `needsCog` and the nesting checks (§1.4).
- Teach the (planned) `stripCog` the new markers.
- Tests in `spec/lua_cog_spec.lua`: block-form expand; round-trip (expand twice =
  same); plain `<!-- … -->` comments are **left untouched**; `<!---` blocks coexist
  with `---`/`###`/`///` blocks in one file; strip removes only `<!---`-family parts;
  the `-->`-in-code caveat documented with a test asserting the parser still finds the
  `]]]--->` line. *No triggering yet — driven via the existing API in tests.*

**Phase 2 — eligible-extension auto-scan + discovery.** *(§6: before CP Phase 5.)*

- Content-pipeline registry holds the COG-eligible extension set (`.md`, `.markdown`,
  `.html`, `.txt`); `.tsv` excluded (§2.3).
- Directory-walk discovery over package roots, `needsCog`-gated (§2.2-2.3).
- Opt-out mechanism (`.cogignore` / manifest exclude).
- Tests: a `.md` with a block is found and processed; one without a block is skipped;
  an ignored file is skipped; a `.tsv` is not double-processed.

**Phase 3 — in-place refresh mode.** *(§6: after CP Phase 5.)*

- A build/CI step (or `--cog-docs` command) that rewrites source non-TSV files in
  place, markers kept, data env loaded (§2.4 in-place).
- Tests: a `README.md` template refreshes its generated region from a fixture dataset;
  re-running is idempotent; source markers preserved.

**Phase 4 — generate-to-export + strip integration.** *(§6: absorbed into CP Phase 5
— implement as one with it.)*

- Wire into the exporter sink flow ([content_pipeline.md §3.9-3.10](content_pipeline.md)):
  expand with data env → optional `stripCog` → write to export dir.
- Tests: a `.md` template exports the generated doc; with `stripCog` the published file
  has no `<!---` scaffolding; the source template is unmodified.

---

## Part 4 — Open questions

1. **Block form vs per-line form, and the `-->`-in-code caveat (§1.3).** *Lean: ship
   block form as primary; accept per-line too; document "no literal `-->` in a
   block-form code body".*

2. **Eligible-extension set.** Start with `.md` / `.markdown`; add `.html` / `.txt`
   when wanted? *Lean: `.md` + `.markdown` in Phase 2; others on demand via the
   one-line registry change.*

3. **Scan roots.** Exactly the package data roots, or also a dedicated `docs/` tree, or
   configurable? *Lean: package roots (docs live with data); revisit if projects want
   a separate docs tree.*

4. **Export destination + naming for generated docs.** Mirror source layout under the
   export dir? Separate `docs/` subdir? *Lean: mirror source layout; confirm against
   the exporter's existing relative-path logic
   ([exporter.lua:124-134](../exporter.lua#L124-L134)).*

5. **Should generated `.md` exports be `stripCog`-stripped by default?** A published doc
   site wants clean files; a "docs-as-source" repo may want markers kept for the next
   refresh. *Lean: follow the global `stripCog` export option (default off), so the
   author chooses.*

6. **Front matter interaction.** A `.md` starting with a `---` YAML front-matter fence
   must not be mistaken for a COG `---` marker. The COG `---` markers are specifically
   `---[[[` / `---]]]` / `---[[[end]]]`, so a bare `---` fence is already safe; confirm
   with a front-matter fixture test in Phase 1.

---

## Part 5 — Relationship to existing TODOs

- [content_pipeline.md](content_pipeline.md) — the parent plan. **This document
  resolves its open questions Q8 (hidden Markdown marker style) and Q9 (non-data
  template discovery).** The `macro`-phase machinery, the sink direction, `stripCog`,
  and the "produces text, parsing optional" property all come from there; this plan
  fills in the `.md`-specific marker grammar and the trigger decision.
- [lua_cog.lua](../lua_cog.lua) — gains the fourth (HTML-comment) marker style; its
  expansion/strip internals are otherwise unchanged.
- [exporter.lua](../exporter.lua) — the sink driver for generate-to-export
  (Phase 4); already the home of the `stripCog` export option.
