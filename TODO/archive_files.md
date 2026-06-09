# Archive / Data-Set Files: Containers of Many Files (zip first)

## Status

**Phase 1 DONE (pending user commit) — registry + zip provider, no loader
integration.** Shipped `archive_formats.lua`: the lazy provider registry
(`registerProvider`/`resolve`, `formatForName`/`isArchive`, `list(format,bytes)` /
`read(format,bytes,member,maxBytes)`) mirroring `compression`, plus the pure-Lua zip
provider (central-directory parse + member extract; method 0 verbatim, method 8 via
the shared `libdeflate` raw-DEFLATE path; **CRC-32 verification on every read**;
member-count + per-member `maxBytes` caps; zip-slip / absolute-path rejection;
Zip64 / encrypted / split / corrupt → clear errors). `crc32` + `u32le` are now public
on `compression`. `snapshotState`/`restoreState` registered with `global_reset`. Tests:
`spec/archive_formats_spec.lua` (22 — list/read stored+deflated, comment scan, all the
caps and rejections, CRC mismatch, graceful libdeflate-absent via a fake provider).
Full suite 2916 green. Docs: CHANGELOG, MODULES. **Next: Phase 2** (virtual member
paths + archive-aware `readFileBinary`/`getFileSize` in `file_util`).

This document proposes a new capability and a new
registry. It is a *sibling* of the [compression](../compression.lua) provider
registry and the [content-pipeline](content_pipeline.md) stage registry, but it
solves a problem neither can: a single on-disk file that is a **container for a
*set* of member files**, with its own internal directory structure.

Reconciled against the engine as of v0.26.0.

> **Prerequisite — [export_format_reimport.md](export_format_reimport.md).** That
> work (input transcoders for `tsv:lua` / `tsv:json-typed` / `tsv:json-natural` /
> `lua:tabulua`) must land **before** this one and is **assumed done** throughout
> the design and phases below. The reason: a "built" mod packed in a zip carries
> *export-format* members, several of which the loader cannot currently re-read — so
> an archive of them would be useless until those formats are re-importable. With the
> prerequisite done, the full set of loadable member formats is: native
> `.tsv`/`.csv`, `.eav`, `.gz`, `json` (+`json:*`), `xml` (+`xml:tabulua`), and
> `tsv:*` / `lua:tabulua` — **not** `sql` / `mpk` (deliberately excluded). The
> deferred "loadable member formats" note (referenced below) is written once the
> prerequisite ships.

## The problem

A "game mod" is often distributed as a single packed file — classically a **zip**.
Scenario the user described:

1. Someone builds a small "utility mod" with TabuLua. The built mod is packed into
   `utilmod.zip`.
2. Someone else builds a "bigger mod" and **includes that zip as one of their own
   files** (instead of using TabuLua's built-in dependency mechanism).
3. The bigger mod wants to **load / reference / process** data files that live
   *inside* `utilmod.zip` — its `Files.tsv`, its `.tsv` data, etc.

Today TabuLua cannot see into the zip. Worse, `.zip` is not even in the loader's
collected `EXTENSIONS` ([manifest_loader.lua:97](../manifest_loader.lua#L97)), so a
zip is currently *invisible* — neither parsed nor streamed. The default mental model
("a zip is a binary asset copied as-is") is the behaviour we will *add* as one
option, but the real ask is to let `Files.tsv` reference members **inside** the
container via the existing `fileName:filepath` column.

## What an archive is — and what it is *not*

| | Compression (`.gz`) | Archive / data-set (`.zip`) |
|---|---|---|
| Members | **one** (a single byte stream, wrapped) | **many**, with an internal directory tree |
| Maps to | a `decode` content-pipeline stage (bytes→bytes) | **new concept**: one file → a *set* of virtual files |
| Existing home | [compression.lua](../compression.lua) | **new** `archive_formats.lua` |

This is the load-bearing distinction. The [content pipeline](content_pipeline.md) is
**single-file** at every entry point — `readAndRun(name) → text`, `run(name, bytes)
→ text` — so an archive **cannot** be modelled as a content-pipeline stage. A
`.tsv.gz` *decodes in place* to one `.tsv`; a `.zip` *fans out* to N members. The fan-
out has to happen at **collection / path-resolution** time, before the per-file
pipeline ever runs. (A zip whose member is itself a `.tsv.gz` is then handled by the
content pipeline as usual, once that member is addressable — the two compose.)

## Design overview

Four pieces, each independently shippable:

1. **`archive_formats.lua`** — the "register" the request anticipated: a lazy
   provider registry keyed by extension (`zip` to start), mirroring
   [compression.lua](../compression.lua)'s `registerProvider`/`resolve` pattern.
2. **A pure-Lua zip provider** — central-directory parsing + member extraction via
   the libdeflate rock already used for gzip (no native dependency).
3. **Virtual member paths + an archive-aware read layer** in
   [file_util.lua](../file_util.lua) — so a path like
   `mods/utilmod.zip/data/Item.tsv` reads transparently as if the member were a
   loose file. Because the whole loader funnels reads through `readFileBinary` /
   `getFileSize`, making *those two* archive-aware lights up the entire pipeline
   with no change to `content_pipeline`, `files_desc`, `storeRawFile`, etc.
4. **Collection / expansion** — `collectFiles` enumerates an archive's members and
   adds their virtual paths to the `files` list, so they participate in the
   existence check, the data-vs-asset gate, COG scanning, and transcoder routing
   exactly like loose files.

### 1. The registry: `archive_formats.lua`

Shaped like [compression.lua](../compression.lua) (lazy, optional, never a hard
require at startup):

```lua
-- Register a provider for one archive format (lazy loader, like compression).
archive_formats.registerProvider(format, loader)
    -- loader() returns an ops table on success, or (nil, reason) when its
    -- dependency (e.g. libdeflate) is missing:
    --   ops.list(bytes, opts) -> entries | (nil, reason)
    --       entries: array of { path=<member path>, size=<uncompressed>,
    --                            method=<0|8>, compSize=<n>, offset=<n> }
    --   ops.read(bytes, memberPath, maxBytes) -> memberBytes | (nil, reason)

archive_formats.isArchive(file_name)            -> boolean   -- ext is registered
archive_formats.formatForName(file_name)        -> "zip"|nil
archive_formats.list(file_name|bytes)           -> entries | (nil, reason)
archive_formats.read(file_name|bytes, member, maxBytes) -> bytes | (nil, reason)
archive_formats.getVersion()                    -> string
```

Laziness matters for the same reason it does in `compression`: registering the zip
format must not require libdeflate. Only *opening* a real zip pulls it; a project
that never touches an archive runs fine on a box without libdeflate, and one that
*does* hit a zip without it gets a clear "zip archives are not supported" error for
that file (logged once), not a startup crash. The dependency is shared — zip
method-8 entries are raw DEFLATE, decoded by the very `LibDeflate:DecompressDeflate`
[compression.lua already uses](../compression.lua#L197).

`snapshotState`/`restoreState` for `global_reset`, mirroring `compression` /
`content_pipeline`.

### 2. The zip provider (pure Lua + libdeflate)

Zip is parseable in pure Lua — it is the same kind of byte-framing work as
[`gzipFraming`](../compression.lua#L138):

- **Central directory.** Find the End-Of-Central-Directory record (scan backward
  from EOF for signature `PK\5\6`, allowing for a trailing comment), then walk the
  central-directory file headers (`PK\1\2`) to enumerate members: name, compression
  method, compressed/uncompressed sizes, local-header offset, CRC-32.
- **Member extraction.** Seek the local file header (`PK\3\4`) at the recorded
  offset, skip its variable name/extra fields, then:
  - **method 0 (stored):** copy the bytes verbatim.
  - **method 8 (deflate):** `LibDeflate:DecompressDeflate(body)` — the same call the
    gzip provider makes, since a zip deflate member is a *raw* DEFLATE stream (no
    gzip/zlib envelope).
  - other methods (bzip2, lzma, zstd-in-zip…): unsupported in v1 → `(nil, reason)`.
- **Integrity (v1):** verify each extracted member's CRC-32 against the
  central-directory value. The [pure-Lua `crc32`](../compression.lua#L216) already
  present is **exposed publicly from `compression`** (decision below) and reused here
  — no second copy, no new module. A mismatch fails the member read with a clear
  reason (corrupt archive).

We do **not** reimplement DEFLATE — same rule as the compression work
([memory: content-pipeline-weave](../README.md), "don't reimplement compression
algorithms — envelope/framing parsing + a rock is fine"). We only parse the zip
framing and delegate the actual inflate.

#### Dependency evaluation: why not an off-the-shelf zip rock (2026-06)

Checked before writing our own. **No pure-Lua zip reader is published on
LuaRocks.** Every dedicated zip rock there binds a native C library — `LuaZip`
(zziplib), `lua-zip` (libzip), `unzip` (minizip) — all unusable under this project's
no-C-toolchain constraint. The only pure-Lua zip reader that exists is
**[zzlib](https://codeberg.org/zerkman/zzlib)** (WTFPL), but it is **source-only,
not on LuaRocks**, and — decisively — it **bundles its own pure-Lua DEFLATE**, which
would *duplicate the libdeflate this project already ships and built gzip on*. (Its
current source is genuinely pure Lua — native bitops on Lua ≥ 5.3, `bit32`/`bit`
below — so the stale `luabitop` rockspec problem the compression work hit no longer
applies to the source; it just isn't packaged as a rock.)

Conclusion: writing the thin central-directory parser ourselves and reusing
**libdeflate** for the inflate is *less* code and dependency surface than vendoring
zzlib (one inflate engine, not two) and adds **no** new dependency. zzlib's
`zzlib.files()` (central-directory iterator) and `zzlib.unzip()` are a useful **free
reference** for getting the framing right — not a runtime dependency.

> **Scoping note — Zip64 / encryption.** v1 targets the common case: a single-disk,
> non-encrypted zip under 4 GiB with method 0/8 entries, which is what a TabuLua-
> built mod produces. Zip64 (>4 GiB or >65535 entries), encryption, and split
> archives are explicit "unsupported, clear error" cases, not silent
> mis-reads.

### 3. Virtual member paths + archive-aware reads

**Path convention — the archive is a directory.** A member is addressed exactly the
way the user described and the way most tooling already does it: the archive's path,
followed by the member's internal path.

```text
mods/utilmod.zip/data/Item.tsv
└──────┬───────┘ └─────┬──────┘
   container         member path
```

The signal is "a path segment whose extension is a registered archive format **and**
which is a real file on disk." A resolver in [file_util.lua](../file_util.lua):

```lua
file_util.resolveArchivePath(path)
    -> (containerPath, memberPath)   -- when path points inside an archive
    -> (path, nil)                   -- ordinary loose file
```

It splits at the first archive-extension segment that `isFile()` on disk (so a real
directory literally named `foo.zip/` — pathological but possible — is still treated
as a directory, since it is not a file). Everything up to and including that segment
is the container; the remainder is the member path.

**No new `Files.tsv` column.** The existing `fileName:filepath` column just holds the
longer path (`utilmod.zip/data/Item.tsv`). This is the §3.3 / §10-Q5 principle from
[content_pipeline.md](content_pipeline.md) restated: *files are referenced by the
name the author writes; the engine resolves the physical access internally.* (The
`filepath` parser accepts it — it is an ordinary multi-segment relative path; confirm
in [parsers](../parsers.lua) during Phase 2.)

**Two functions become archive-aware — and only two:**

- `file_util.readFileBinary(path)` — if `resolveArchivePath` yields a member, open
  the container, extract the member (bounded by a `maxBytes` cap, see Safety), and
  return its bytes. Else read the loose file as today.
- `file_util.getFileSize(path)` — return the member's *uncompressed* size from the
  central directory (a metadata read, never an extraction), else `stat` the loose
  file.

Because [`content_pipeline.readAndRun`](../content_pipeline.lua#L678) and
[`storeRawFile`](../manifest_loader.lua#L407-L428) call exactly these, **the entire
load path sees into archives with no further change.** A member that is a `.tsv`
parses as data; a member that is a `.png` gets the passthrough descriptor (its
`sourcePath` is the virtual path, streamed at export by re-reading through the same
archive-aware `readFileBinary` — see §4). The `checkTypeName` peel
([files_desc.lua:223](../files_desc.lua#L223)) already works on the basename, so
`Item.tsv` inside a zip checks against `Item` exactly like a loose file.

**Caching.** A naive implementation re-reads and re-parses the whole zip for *every*
member access (existence check, size, read, export). For v1 add a tiny per-process
archive cache keyed by `(containerPath, mtime)` holding the parsed central directory
(small) and, optionally, the raw archive bytes under an LRU/size budget. This is the
archive analog of content_pipeline §9-Q6 ("caching decoded output") — cheap and
contained. The cache is cleared by `global_reset`.

### 4. Collection / expansion

[`collectFiles`](../file_util.lua#L548) walks directories and keeps files whose
extension is in `EXTENSIONS`. Two changes:

- **Add `zip` to `EXTENSIONS`** ([manifest_loader.lua:97](../manifest_loader.lua#L97))
  so archives are seen at all.
- **Expand archives into virtual members.** When collection meets an archive file, it
  calls `archive_formats.list` (metadata only — *never* extracts during collection)
  and appends each member whose extension is in `EXTENSIONS` as a virtual path
  `<archivePath>/<memberPath>`, with `file2dir[virtualPath] = <same dir as the
  archive>`. Members of non-collectable types are ignored (just as loose files of
  those types are). Best kept as a focused wrapper (`expandArchives(files, ...)`) so
  `collectFiles` stays simple and the expansion is independently testable.

After expansion the virtual members are indistinguishable from loose files to the
rest of the loader:

- **Existence check** ([manifest_loader.lua:546-577](../manifest_loader.lua#L546-L577))
  — `filesOnDisk[utilmod.zip/data/item.tsv]` is populated, so a `Files.tsv` reference
  resolves; a typo gets the same "not found" diagnostic.
- **Data-vs-asset gate** ([manifest_loader.lua:477-487](../manifest_loader.lua#L477-L487))
  — a member `.tsv`/`.csv`, a member assigned a `transcoder`, a compressed member
  (`data.tsv.gz` *inside* the zip), or an auto-transcoded member (`.eav`) all route to
  `processSingleTSVFile`; everything else streams as an asset. **The composition is
  free** because the gate already consults `content_pipeline.peeledName` /
  `autoTranscodes`, and those operate on the (virtual) name.
- **COG scan / doc discovery** — `cog_discovery` walks the same collected set, so a
  `.md` template inside an archive is COG-scanned too (a directory walk over a zip's
  members; verify `cog_discovery`'s own `lfs`-based `.cogignore` probe degrades
  gracefully for virtual paths — it should simply find no marker).

### 5. Export & reformatter behaviour

Two outputs, kept distinct exactly as [content_pipeline.md §3.9](content_pipeline.md)
separates them:

- **Reformatter / in-place rewrite — archives are read-only inputs in v1.** A file
  inside a zip is *not* rewritten in place (the reformatter must never try to splice
  bytes back into a container). This is the same posture as a non-reversible
  transcode ([content_pipeline.md §3.6](content_pipeline.md)): skip, leave the source
  archive untouched. Writing back into an archive is deferred (§ Phase 5).

- **Export.** The recommended v1 rule keeps the user's scenario coherent — *the
  utility mod stays packed inside the bigger mod*:
  - The **archive file itself streams to the export verbatim** (the normal
    passthrough-by-reference copy, now that `zip` is collected). The bigger mod's
    build still contains `utilmod.zip`, byte-for-byte.
  - A virtual **member loaded as data** contributes its rows to the dataset/model
    like any data file, but its per-file `raw_files` copy is **input-only**: it is
    *not* re-emitted at a nested `…/utilmod.zip/data/Item.tsv` export path (which
    would both duplicate the packed copy and create a confusing `.zip`-as-directory
    layout). Tag these `raw_files` entries (e.g. `fromArchive = containerPath`) so the
    exporter skips writing them individually — the packed archive is their export
    representation.

  This is a deliberate, documented choice (see Open Questions Q3 for the alternatives:
  *flatten* the member into the build, or *re-pack* a modified archive). v1 = "archive
  streams as-is; members are inputs," which needs the least new machinery and exactly
  matches "include the zip as one of my own files."

## Safety — archives are untrusted input

Same spirit as [content_pipeline.md §3.7](content_pipeline.md), plus archive-specific
hazards:

| Risk | Mitigation |
|---|---|
| **Zip bomb** (KB archive → GB on extraction) | A per-member `maxBytes` cap (reject on the central-directory uncompressed size *before* inflating, then backstop on actual output — exactly the two-stage check the [gzip provider](../compression.lua#L189-L204) already does). Plus an aggregate cap across all members of one archive. |
| **Too many members** (entry-count bomb) | Cap the member count from the central directory; refuse beyond it. |
| **Zip-slip / path traversal** (`../../etc/passwd`, absolute, or drive-letter member paths) | The resolver/lister **rejects** any member path that is absolute or escapes the archive root after normalisation. Member paths are always archive-relative. |
| **Unsupported method / Zip64 / encrypted** | Clear `(nil, reason)` per member — never a silent mis-read. |
| **Corrupt central directory / truncated archive** | Framing parse returns `(nil, reason)`; the file is dropped from the load via `badVal`, like a failed read at [manifest_loader.lua:350-353](../manifest_loader.lua#L350-L353). |
| **CRC mismatch** | Mandatory integrity check vs the central-directory CRC-32 (pure-Lua `crc32`, now exposed from `compression`); a mismatch fails the member read. |
| **libdeflate absent** | Lazy provider returns "unsupported," logged once; the archive's members simply don't load (the archive can still stream as an asset). |

## Implementation phases

Each phase is independently shippable and **committed separately** (the user does all
commits — stop after each phase and let them commit before continuing, per the
established workflow).

**Phase 1 — `archive_formats.lua` registry + zip provider. No loader integration.**
- Expose `crc32` (and `u32le` if useful) from `compression`'s public API.
- The lazy provider registry (mirrors `compression.lua`).
- The pure-Lua zip reader: central-directory parse + `list`; member `read` for
  methods 0/8 via libdeflate; **CRC-32 verification on every member read**; size and
  member-count caps (`maxBytes`); zip-slip rejection; unsupported-method / Zip64 /
  corrupt → clear errors.
- `snapshotState`/`restoreState`.
- Tests: `spec/archive_formats_spec.lua` — list a known fixture zip; read a stored
  member; read a deflated member; bomb cap trips; zip-slip path rejected; corrupt
  header errors; libdeflate-absent path degrades. (Build fixture zips from the test,
  or check small ones in.)

**Phase 2 — virtual paths + archive-aware reads. Still no collection change.**
- `file_util.resolveArchivePath` + the per-archive cache.
- `readFileBinary` / `getFileSize` become archive-aware.
- Confirm the `filepath` parser accepts member paths.
- Tests: `readFileBinary("fixture.zip/data/Item.tsv")` returns the member; size is the
  uncompressed size without extracting; a loose-file path is unaffected (ablation:
  every existing `readFileBinary` behaviour is byte-identical).

**Phase 3 — collection / expansion + end-to-end load.**
- `zip` into `EXTENSIONS`; `expandArchives` wrapper; `file2dir` for virtual members.
- Verify the existence check, data-vs-asset gate, and transcoder routing all work on
  virtual members with no further edits.
- Tests: `spec/archive_load_integration_spec.lua` — a package whose `Files.tsv`
  references `utilmod.zip/data/Item.tsv` loads it as data and the rows appear in the
  model; a member `.png` gets a passthrough descriptor; a member `data.tsv.gz` decodes
  *and* parses (archive ∘ content-pipeline composition); a `Files.tsv` typo inside the
  archive yields the normal "not found" error.

**Phase 4 — export + reformatter.**
- The archive streams verbatim to the export (passthrough); member `raw_files` entries
  tagged input-only so the exporter skips per-file writes; reformatter skips members.
- Tests: export contains `utilmod.zip` byte-identically and does **not** create a
  `…/utilmod.zip/…` directory; reformatting the package leaves the zip untouched.

**Phase 5 (optional / deferred) — until a concrete need appears.**
- **Writing archives** — re-pack a (possibly modified) archive on export, or flatten
  members into the build (Open Q3). Needs a zip *writer* (deflate via libdeflate's
  `CompressDeflate`, already available — see [compression.lua](../compression.lua#L271)),
  plus CRC-32 and central-directory emission. This makes archives `reversible` and lets
  the reformatter round-trip them.
- **Other formats** — `tar`/`tar.gz` (tar is trivial framing; `.tar.gz` composes the
  archive layer over the content-pipeline gzip decode), then heavier formats if asked.
- **Per-member transcoder selection** — if a member needs the `transcoder` column
  (`json:objects` etc.), confirm the column keys by the full virtual path (it should,
  since `computeFilenameKey` already lowercases the whole relative path).
- **Nested archives** (a zip inside a zip) — the resolver handles one level; recursing
  is a small extension, deferred until wanted.

## Open questions

1. **Auto-expand vs. reference-only.** v1 auto-expands every archive's collectable
   members at collection time (cheap: a central-directory *list*, never an extraction).
   The alternative — resolve *only* members explicitly named in `Files.tsv` — saves the
   list call but breaks auto-discovery (COG scan, `.eav`/auto-transcode members inside
   the zip would be invisible). *Lean: auto-expand, since listing is metadata-only and
   keeps members first-class.*

2. **Should the archive blob still export when its members are loaded?** v1 says yes —
   the zip streams verbatim *and* its data members feed the model (input-only). This
   matches "I included the zip as one of my files." *Lean: yes (stream verbatim);
   revisit if a use case wants the archive consumed-and-dropped.*

3. **Export layout for members.** Three options: **(a)** input-only — members feed the
   model, archive streams as-is, members not re-emitted *(v1 lean)*; **(b)** flatten —
   strip the `…​.zip/` segment and emit the member as a loose file in the build;
   **(c)** re-pack — write a possibly-modified archive back out (needs the Phase 5
   writer). *Lean: (a) for v1; (b)/(c) when a build actually needs the unpacked or
   rewritten form.*

4. **Where does `crc32` live?** *Resolved (user decision):* it is currently private
   to [compression.lua](../compression.lua#L216); **expose it publicly from
   `compression`** (add `crc32` to its API) and reuse it from the zip provider — no
   second copy, no new module. CRC verification on member read is **in v1**, not
   deferred.

5. **Case sensitivity of member paths.** Zip member names are case-sensitive and
   `/`-separated; the loader lowercases keys (`computeFilenameKey`). Confirm a member
   `Data/Item.tsv` referenced as `data/item.tsv` in `Files.tsv` resolves consistently
   on case-sensitive hosts. *Lean: match the existing loose-file convention (the loader
   already lowercases keys for lookup but reads via the original-cased path) — keep the
   original-cased member path for extraction, lowercase only for the lookup key.*

6. **Per-archive memory budget.** The cache may hold raw archive bytes. *Lean: cache
   the parsed central directory always (small); cache raw bytes only under an LRU size
   budget, and for large archives re-read on demand — the same "never hold a giant blob
   in memory" rule as the passthrough descriptor (content_pipeline §3.5).*

## Relationship to existing TODOs / modules

- [compression.lua](../compression.lua) — the structural template (lazy optional
  providers) **and** the shared inflate primitive (zip method 8 = the same raw DEFLATE
  the gzip provider decodes). The zip *writer* (Phase 5) reuses its `CompressDeflate` +
  `crc32` + `u32le`.
- [content_pipeline.md](content_pipeline.md) — the **sibling that this is *not***.
  Archives fan out *before* the per-file pipeline; once a member is addressable, the
  pipeline handles it (decode `.tsv.gz`, transcode `.json`, COG-expand `.md`)
  unchanged. The "referenced by author-name, resolved internally" principle (§3.3,
  §10-Q5) is reused for member paths.
- [file_util.lua](../file_util.lua) — the integration surface: `collectFiles`,
  `readFileBinary`, `getFileSize`, plus the new `resolveArchivePath` / `expandArchives`.
- [files_desc.lua](../files_desc.lua) / [manifest_loader.lua](../manifest_loader.lua)
  — **unchanged in spirit**: the existence check, data-vs-asset gate, and `checkTypeName`
  peel all operate on names and already work on virtual member paths.
- [export_format_reimport.md](export_format_reimport.md) — **the prerequisite** (see
  the Status note). It makes a "built"/exported mod's members re-importable, which is
  what gives an archive of them any value; assumed done here. Once it ships, this doc
  gains a "loadable member formats" note enumerating the supported set.
- [mod_overrides.md](mod_overrides.md) — orthogonal but complementary: a mod shipped as
  a zip can carry patch/overlay files that this feature makes addressable, after which
  the override machinery runs as normal.
