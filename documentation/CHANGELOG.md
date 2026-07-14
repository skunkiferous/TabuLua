
# Change Log
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/)
and this project adheres to [Semantic Versioning](http://semver.org/).

## [Unreleased] - yyyy-mm-dd

### Added

### Changed

- **A table used as a map key is now refused when writing, instead of silently
  breaking the round-trip.** The serializers would happily write `[{1,2}]=v` into a
  cell, but **nothing in the pipeline can read that back**: `ltcn`, our cell reader,
  allows a table as a *value* but never as a *key*; a JSON object key is always a
  string; and the typed-JSON and XML forms are re-imported through a native cell, so
  they end up at `ltcn` all the same. (Even if they could be read, Lua compares table
  keys by identity, not content, so a key rebuilt on load could never match the one
  written.) So the engine could emit a file it could not re-parse, with no warning.
  All four serializers (`serializeTable`, `serializeTableJSON`,
  `serializeTableNaturalJSON`, `serializeTableXML`, and therefore the SQL export,
  which encodes cells through them) now reject a table key, mirroring the read side.
  Such a value can only come from an `=expr` cell, a pre-processor or a transcoder —
  never from parsed file text — so it is **reported as a bad value**, naming the file,
  row and column, rather than raised as an error that would abort the load. A table
  as a *value* is unaffected. Note this is technically a behaviour change: a write
  that "worked" before now fails, which is the point. See `TODO/tables_as_keys.md`.

- **Lua 5.5 now passes the full suite, at parity with 5.4.** It previously failed 22
  tests outright. The blocker was the `ltcn` rock (our Lua-literal cell parser): Lua 5.5
  makes a generic `for ... in` **control variable read-only** (implicitly `<const>`), and
  `ltcn`'s `tokenset_to_list` reassigns one, so *every* table-parsing test died with
  `attempt to assign to const variable 's'`. Upstream is dormant — no commit since
  2024-11-04, and its issue and merge-request trackers are both empty — so waiting was
  not a plan: `Docker/ltcn-lua55.patch` carries a three-line, behaviour-preserving fix
  (copy the loop variable into a fresh local; valid on Lua 5.1–5.5, so it is also exactly
  what an upstream MR would carry) and `Docker/Dockerfile.lua55` applies it to the
  installed rock, then **asserts it took**, so the build fails loudly if upstream ever
  moves. Note this fixes *our* test image, not the ecosystem: a user installing on Lua 5.5
  from LuaRocks still gets the unpatched rock. See `TODO/lua55_compatibility.md`.

- **The Docker test images actually install `libdeflate` now.** None of them ever did, so
  every gzip/zip test failed in every image and the container runs carried ~48 permanent
  failures that masked real ones. On Lua 5.5 the rock cannot be installed the normal way at
  all — its rockspec still declares `lua >= 5.1, < 5.5`, so `luarocks install libdeflate`
  refuses with *"No results matching query were found for Lua 5.5"* — even though the code
  is pure Lua and runs there fine (deflate round-trip verified); that image therefore builds
  it from the rockspec with the stale upper bound relaxed.

- **`migration_spec`'s CLI tests no longer hard-code the interpreter name.** They shelled
  out to `lua54`, which exists on a typical Windows dev box but not in the Docker images
  (`sh: lua54: not found`), so seven tests could only ever pass in one environment. They now
  probe `lua54`, `lua5.4`, `lua` in order — the same candidates, in the same order, as
  `bad_input/run_bad_input_tests.sh`.

### Removed

### Fixed

- **The error reporter could itself throw while rendering the bad value it was about to
  report.** `badVal` serialized a table value with the plain serializer, which
  legitimately refuses some tables — a recursive one, one nested deeper than
  `MAX_TABLE_DEPTH`, and now one using a table as a map key. Reporting such a value is
  exactly how the user learns it is bad, so the reporting path must never fail on it:
  it now degrades to `<unserializable table: reason>` instead of raising the
  serializer's error in the reporter's own face.

- **A graph file with a bad reference reported "Quota exceeded" instead of the actual
  error.** When `graphRefsExist` rejects a row it appends a `didYouMean` suggestion, and
  that suggestion edit-distances the offending name against *every* name in the file —
  work that dwarfs the scan that found the error. On a 164-row file it cost ~850k
  operations against a 174k file-validator quota, so the sandbox aborted the validator
  *while it was building the message*, and the user was told their data had blown an
  operation quota rather than that row `X` references an unknown node. Two changes, either
  of which fixes the case, together making the diagnostic path affordable:
  `string_utils.closestMatch` now skips any candidate whose **length** differs from the
  value by at least the current best distance (edit distance is never below the length
  difference, so those candidates cannot win — same result, a fraction of the matrices),
  and `FILE_VALIDATOR_QUOTA_PER_ROW` rises from 1,000 to 10,000, sizing the quota for the
  failure path rather than the success path. A runaway file validator still aborts.

- **gzip and zip support was silently unavailable on Linux and macOS.** The `libdeflate`
  rock installs its module as `LibDeflate.lua`, but we asked for it as
  `require("libdeflate")`. That resolves on a **case-insensitive** filesystem (Windows) and
  nowhere else, so on Linux and macOS the engine reported *"libdeflate rock is not
  installed"* — **even when it was installed** — and degraded: `.gz` sources were rejected
  as unsupported, and every member of every `.zip` package silently failed to load. The
  lookup now goes through one shared `compression.requireLibDeflate()`, which asks for the
  rock's real name first and keeps the lowercase spelling as a fallback; the zip provider
  reuses it rather than repeating the `require`. Nothing about this was Lua-version
  specific — it was invisible only because development happens on Windows.

- **A row with an empty leading cell could serialize as a blank line.**
  `raw_tsv.rawTSVToString` explicitly supports a `nil` cell (it writes `nil`), but sized the
  row with `#line` — and `#` over a table with a **hole** is a *border*: the language is
  free to return any of them. Lua 5.4 answered 3 for `{nil, false, 3.14}` and Lua 5.5
  answers 0, which silently emitted an **empty row** instead of the data. The width is now
  the largest integer key, which does not depend on that choice, so such a row round-trips
  identically on every Lua version.

- **Version constraints (`>=`, `<=`) in `dependencies` / `conflicts` crashed on Lua 5.5.**
  The `semver` rock defines `__lt` but not `__le`. Lua up to 5.4 quietly emulated `a <= b`
  as `not (b < a)`; Lua 5.5 removed that emulation, so any `>=` or `<=` version comparison
  raised `attempt to compare two table values` and took down package loading wherever a
  constraint was declared. `manifest_info.versionSatisfies` now expresses both through `<`
  alone — equivalent for a total order, and correct on every Lua version.

## [0.31.0] - 2026-07-12

### Added

- **`--list-columns`: find out what you could be declaring but aren't.** An
  **optional** `Files.tsv` column or manifest field is, by construction,
  undiscoverable: nothing warns when one is absent, and nothing can — most
  packages use almost none of the dozen-plus feature columns, so a warning per
  unused column per `Files.tsv` on every load would be pure noise. The
  consequence was that a package written against an older release kept working,
  silently, while its author had no way short of reading this whole file to learn
  what the engine had since learned to accept. `--list-columns` is that way:

  ```sh
  lua reformatter.lua --list-columns tutorial/core/ tutorial/expansion/
  ```

  It prints the format's full inventory — every core and optional `Files.tsv`
  column, then every `Manifest.transposed.tsv` field — marking each `[x]`/`[ ]`
  by whether the loaded packages declare it, with the release that added it and a
  `declared by n/total` count. It closes with the unused ones **newest first**, so
  *"what's new since I last looked?"* is the first thing you read. Diagnostic
  only: it loads, reports, and exports nothing; it never touches the exit code.
  Each column now carries a `since` in its `descriptorColumns` declaration
  (`type_wiring`), and each manifest field one in `MANIFEST_FIELD_SINCE`
  (`manifest_info`) — **add an entry when you add a column**, or the report cannot
  tell anyone it arrived.

- **`asset_file`: a package can now SAY that a file is not a table**
  (`TODO/non_table_files.md`, Phase 1). A `Files.tsv` row with
  `typeName=asset_file` declares its file an **asset**: it is not parsed, has no
  schema and no `loadEnv.files` entry, is copied **byte-for-byte** to the export,
  and is **never rewritten in place** by the reformatter. Asset is not a new role —
  `.md`, `.txt`, `.lua` and `.zip` have always had it *implicitly*, from their
  extension — it simply could not be **stated**, so a `.json` asset was
  indistinguishable from a `.json` nobody had declared yet. `asset_file` is a
  member of the new built-in **`AssetFile`** type tag (ancestor `table`, mirroring
  `IgnoredFile`/`MigrationScript`), so any user file type can opt in through its
  `tags` field. The plain name `Asset` stays free for a user's own table of asset
  *metadata*.

  **A declaration beats the extension, for every extension.** This is not a
  `.json`/`.xml` patch: a **`.tsv`** can be declared an asset too, and is then
  carried through the pipeline untouched — which the loader could not express at
  all before, since any `.tsv` it saw was either parsed (and reformatted in place)
  or dropped. A hand-formatted lookup table, a fixture shipped for another tool, or
  any file whose exact bytes matter can now be declared and will arrive in the
  export unchanged, under its own name (a `.tsv` asset is *not* re-serialized into
  `--file=json`'s format). A declared asset is streamed verbatim rather than read as
  text, so its bytes — EOLs included — are exactly preserved; implicit `.md`/`.txt`
  assets keep their existing text handling (COG templates and `--strip-cog` need
  their content as a string), so the byte-for-byte guarantee is precisely what
  declaring the file buys.

  Internally, the two "is it data?" gates that disagreed — the **parse** gate
  (`loadOtherFiles`) and the **declaration** gate (which classified by extension) —
  are now one function, `fileRole`, returning `table` / `asset` / `ignored` (plus
  the non-role `undeclared`). Both callers ask it, so they can no longer contradict
  each other. Rules 1–2 (the declarations) are checked **before** the extension;
  the extension is only ever a guess for an *undeclared* file. New spec
  `spec/non_table_files_spec.lua`.

- **Tutorial: `theme.json`, a declared asset** (`TODO/non_table_files.md`, Phase 4).
  `tutorial/core/theme.json` is nested JSON — no rows, no columns, nothing a schema
  could describe — declared `typeName=asset_file` and therefore copied byte-for-byte
  into every export instead of being parsed or dropped. It sits deliberately next to
  `DraftItem.tsv`, the tutorial's *undeclared* file: the two are the same situation
  with and without a declaration, which is the whole point of the feature. Both are
  written up in `tutorial/README.md`.

- **Manifest `asset_files` / `ignored_files` globs** (`TODO/non_table_files.md`,
  Phase 2). Two new manifest fields (`{string}|nil`) declare file roles in bulk:
  `asset_files` says what a `typeName=asset_file` row says, and `ignored_files` what
  an `IgnoredFile` `typeName` says — for a whole class of files at once.

  ```tsv
  asset_files:{string}|nil       "ui/*.json","docs/**"
  ignored_files:{string}|nil     "*.tmp.tsv","scratch/**"
  ```

  **`ignored_files` finally silences temporary files** — the annoyance that started
  this whole thread. A temp `.tsv` in the data tree was first a hard error, then a
  warning; now a package says once that those files are not its data, and the loader
  says nothing at all about them: not loaded, not exported, **not warned**.

  New **`util/glob.lua`**: `*` matches within one path segment (it never crosses
  `/`), `**` matches any run of segments including none, `?` matches one character.
  A glob with **no `/`** matches by **basename at any depth** (the gitignore rule), so
  `*.tmp.tsv` catches `sub/deep/x.tmp.tsv` too; a glob with a `/` is anchored to the
  package root. Matching is case-insensitive. A package's globs govern only the files
  **it owns**, matched against paths relative to **its own root**, so a mod dropped
  into `mods/utilmod/` keeps working unedited — the same relocatability rule its
  `Files.tsv` follows. New spec `spec/glob_spec.lua`.

- **Customizable SVG colour schemes** (`TODO/graph_svg_export.md`, follow-up).
  `--file=svg` colours are now fully configurable from the command line, one
  colour per drawable *type*. `--svg-color-scheme=<name>` picks a base palette
  from four built-ins — `default`, `dark`, `mono`, `colorblind` (an unknown name
  is now an error with a did-you-mean suggestion, instead of silently falling
  back). `--svg-color=<key>=<color>` (repeatable) overrides an individual colour
  on top of the base; the keys are `node`, `root`, `leaf`, `isolated`, `border`,
  `label`, `edge-directed`, `edge-undirected`, `edge-label`, and `background`, and
  `<color>` is a `#rgb` / `#rrggbb` hex value, a CSS colour name, or `none` for a
  transparent canvas (validated, with did-you-mean on the key). Directed and
  undirected links now carry **separate** colours (`edge-directed` vs
  `edge-undirected`), so DAG arrows and peer links can be tinted independently.
  The `isolated` key colours a directed-graph node with no edges at all (no
  parents and no children — previously the confusingly-named `root-leaf`). The
  `background` fills the canvas with a full-viewBox rect drawn first, but defaults
  to transparent (`none`) for every scheme except `dark`, so diagrams still embed
  cleanly and adapt to the page; there is no built-in title or frame (wrap the
  `<svg>` yourself for a caption). The renderer merges the overrides over the
  chosen base palette deterministically. Covered by new `svg_render` colour tests
  (named scheme, per-key override merge, directed vs undirected link colours,
  isolated fill, background on/off/override) and a
  `bad_input/cli_errors/svg_color_scheme_suggestion` fixture for the unknown-scheme
  error.

- **SVG edge annotations & tuning flags** (`TODO/graph_svg_export.md`, Phase 5).
  When a drawn node file has an attached `edgesFor` edge file, each drawn edge is
  now labelled with a value from that edge file — by default the first
  non-comment scalar column (e.g. `requiredLevel` on the tutorial's
  `SkillEdges.tsv`), overridable with `--svg-label-column=<col>` and disableable
  with `--no-svg-edge-labels`. The `svg*` layout/appearance knobs are exposed as
  CLI flags on `--file=svg`: `--svg-sweeps=<N>` (crossing-reduction passes),
  `--svg-node-spacing=<N>` / `--svg-layer-spacing=<N>` (px), and
  `--svg-color-scheme=<name>`. All are documented in the usage help and covered by
  an edge-labelling case in `spec/svg_export_integration_spec.lua` (weights appear
  by default and vanish with labels off; the edge file itself is never drawn).

- **Undirected graph SVG support** (`TODO/graph_svg_export.md`, Phase 4).
  `--file=svg` now also draws `basic_graph_node` files. Since an undirected
  graph has no inherent layering, the exporter synthesizes one and reuses the
  single layout engine: new **`graph_layout.bfsLayering(nodes, neighbours)`**
  does a deterministic BFS from the lexicographically smallest node (each node's
  layer = its BFS distance), stacks disconnected components below one another
  (ordered by smallest member), and orients each undirected edge lower-layer →
  higher-layer (ties by name) exactly once. `graph_layout.layout` gained an
  `opts.layers` override so a caller can supply that precomputed layering instead
  of the longest-path ranking. Undirected diagrams are rendered without
  arrowheads and without root/leaf tinting (an undirected graph has neither).
  Cycles and disconnected components — both legal for basic graphs — lay out and
  render deterministically. Covered by new `graph_layout.bfsLayering` unit tests
  and an undirected end-to-end case in `spec/svg_export_integration_spec.lua`.

- **`--file=svg` graph-diagram export** (`TODO/graph_svg_export.md`, Phase 3).
  New **`exporter.exportSVG`**, registered as the `svg` file format in
  `reformatter.lua`, draws graph-family data files as SVG diagrams —
  `lua reformatter.lua --file=svg <dirs…>` writes one `svg-svg/<name>.svg` per
  graph file, mirroring the source layout. It is the first *selective* exporter:
  it walks the processed files, detects each file's graph family via
  `graph_wiring.detectRole` (over `joinMeta.lcFn2Type` / `extends`), draws the
  directed families (`graph_node` / `tree_node`) by building the adjacency from
  `graphChildren`, laying it out with `graph_layout` and rendering it with
  `svg_render`, and **skips** every non-graph file with an info log plus an
  end-of-run summary count (a graph-only picture of a non-graph file is
  meaningless). Roots and leaves are tinted so a DAG's entry and terminal points
  stand out. Undirected (`basic_graph_node`) graphs are recognised but deferred to
  the next phase. Optional `exportParams` knobs (`svgSweeps`, `svgNodeSpacing`,
  `svgLayerSpacing`, `svgColorScheme`) are plumbed through with sensible defaults.
  Covered by `spec/svg_export_integration_spec.lua` (a graph file is drawn with
  one box per node and one edge per parent link; a sibling non-graph file
  produces no `.svg`; two runs are byte-identical).

- **SVG graph renderer** (`TODO/graph_svg_export.md`, Phase 2). New
  **`serde/svg_render.lua`** with **`render(laidOut, opts)`**, which turns a
  laid-out graph (exactly what `graph_layout.layout` returns, plus optional
  per-node `label`/`role` and per-edge `label`/`directed`) into a complete,
  self-contained `<svg>` document string. Nodes are rounded `<rect>`s with a
  centred label; edges are `<polyline>`s through the node centres and dummy bend
  points, with the final segment clipped to the target box border so a directed
  arrowhead (a single reusable `<marker>` in `<defs>`) lands cleanly on the edge.
  Roots and leaves get distinct fills from a small built-in palette (labels stay
  dark so they read on the fill on any page background). The renderer knows
  nothing about graph families or the engine — the caller supplies the
  `directed` flag and node roles — and the output is fully self-contained (no
  external stylesheet, font, or script) and deterministic: nodes emit in name
  order, coordinates are integers, labels are XML-escaped, and the crossing count
  is surfaced as an `<!-- crossings: N -->` comment, so identical input yields a
  byte-identical SVG. Covered by `spec/svg_render_spec.lua` (element counts,
  viewBox, directed vs undirected markers, box-edge clipping, role tints,
  escaping, and a golden-string byte-stability test). The exporter/reformatter
  wiring that drives this over real graph files lands in Phase 3.

- **Layered graph-layout engine** (`TODO/graph_svg_export.md`, Phase 1). New
  **`wiring/graph_layout.lua`** with a single pure entry point
  **`layout(nodes, adjacency, opts)`** that turns a flat list of node names plus
  a directed adjacency (`name → array of names it points to`) into
  `{ nodes = {name → {x, y, layer}}, edges = { {from, to, points} }, width,
  height, crossings }`. It runs the classic four-stage Sugiyama pipeline —
  longest-path layer assignment, dummy-node insertion for edges that span more
  than one layer, wmedian crossing reduction (configurable sweeps, best-of
  retention), and integer coordinate assignment with a light per-layer centering
  pass. The engine is family-agnostic (knows nothing about graph families, TSV
  rows, or SVG), so it can lay out any directed graph. Output is integer-only and
  every ordering tie breaks on the node name, so identical input yields
  byte-identical output on every run and platform; the reported `crossings` count
  is surfaced for callers and tests. This is the geometry half of the coming
  `--file=svg` export; the renderer and exporter wiring land in later phases.
  Covered by `spec/graph_layout_spec.lua` (layering, coordinates, long-edge bend
  points, the unavoidable K2,2 crossing, and determinism across runs and input
  orderings).

- **"Did you mean …?" suggestions on identifier-not-found diagnostics**
  (`TODO/did_you_mean.md`, Phase 1). New **`error_reporting.didYouMean(value,
  candidates, opt_maxDistance)`** returns a `" (did you mean 'X'?)"` suffix (note
  the leading space) for the candidate closest to a mistyped identifier, or `""`
  when nothing is close.
  It builds on the `string_utils` edit-distance functions added with the
  mod-ecosystem follow-up: matching is case-insensitive (candidates compared
  lowercased, reported in original casing) and deterministic (a copy of the
  candidates is sorted, so the first of equally-close ties always wins). It
  accepts either a sequence (`{"a", "b"}`) or a set keyed by name
  (`{[name]=...}`), and tolerates `nil`/non-string inputs so call sites need no
  pre-checks. Intended for error paths only.
  - Adopted at the high-value data-error sites: patch/overlay targets not found
    by basename or not owned by the named package (`patch_executor`,
    `manifest_loader` — the shared `newTargetResolver` now returns the candidate
    basenames in its failure `info`); `patchOp=update` keys missing under the
    `error` policy (not warn/silent, which are expected version drift); a
    package's missing dependency, bootstrap library / exported function, and
    unknown manifest column (`manifest_info`); `setCell` unknown column
    (`processor_executor`); record parser unknown field and self-ref field
    (`generators`, `type_parsing`); unknown / ancestor type names
    (`type_parsing`, `registration`, via the new `parsers.utils.namedTypeCandidates`
    which filters generated registry keys like `integer._R_GE_0` and composites);
    graph row references to unknown nodes (`graph_helpers`); `edgesFor` targets
    (`builtin_wiring`); join columns (`file_joining`); and the exporter's
    secondary-file lookup (`exporter`).
  - New `bad_input` regression fixture `type_errors/unknown_type_suggestion`
    pins the end-to-end suggestion (`'integr' … (did you mean 'integer'?)`).
  - **Phase 2 — CLI + tooling.** Every command-line tool now suggests the
    closest option / format / log level on a typo, and the `data_set` /
    `migration` data-mutation errors suggest the closest file, column, or PK:
    - `reformatter`: unknown `--option`, `--file=` format, `--data=` format, and
      `--log-level=`. The recognised long options are now captured in one
      `KNOWN_OPTIONS` table beside the usage text (the parser is an if/elseif
      chain with no other central list) so the two can't drift.
    - `migration`, `tsv_diff`, `export_tester`, `extract_test_errors`,
      `ollama_batch`: unknown option / log level / format, each with its own
      hand-maintained option list next to its arg parser.
    - `data_set`: the shared `assertFileLoaded` / `assertColumnExists` guards
      (used ~50×) plus the row-not-found paths now append a suggestion from the
      loaded file names / header columns / primary keys (new `dataRowKeys`
      helper), so every delegating `migration` command benefits; `migration`'s
      own `addColumn` / `moveColumn` / `copyColumn` / `assert` / `assertColumn`
      checks suggest too. These sites return `nil, err`, so the suffix goes into
      the returned string.
    - `file_util` / `archive_formats`: "member not found in archive/zip" suggests
      the closest member from the already-parsed central directory; `manifest_loader`'s
      "file listed in Files.tsv does not exist on disk" suggests the closest
      actual on-disk path (no extra directory listing).
  - **Phase 3 — investigations + re-audit.**
    - **Provided-variant typo check** (the variant analogue of the
      `onlyIfPackages` gate-id heuristic). A `--variant=X` that names no known
      variant selects nothing and is silently ignored — `validateVariantGroups`
      only checks values belonging to a declared group. Resolving the survey's
      open question: variants legitimately exist *outside* declared
      `variant_groups` (the Files.tsv `variant` column selects files by variants
      that need no group), so the "known" set is every `variant_group` value
      **plus** every value any Files.tsv `variant` column mentions (collected as
      `joinMeta.knownVariants`, riding out like `skippedGates`). New
      `manifest_info.unknownVariants` reports the suspects (case-sensitive
      membership — a case slip is itself a typo — with a case-insensitive
      suggestion) in a `=== --variant check ===` section under `--check-conflicts`.
    - **Re-audit hits.** `schema overlay: widenTo 'X' … is not a valid type`
      (`tsv_model`) now suggests the closest real type name (via the newly
      exported `parsers.unknownTypeSuffix`); a manifest `Missing column 'X'`
      (`manifest_info`) and a Files.tsv `Column ignored: X` (`files_desc`) each
      suggest the closest actual/known column. New `bad_input` fixture
      `files_tsv_errors/column_typo_suggestion`.

### Changed

- **A `Files.tsv` missing `fileName` or `loadOrder` is now an ERROR, not a
  warning.** Without either column the descriptor's row loop declares *nothing*
  (it is guarded on both indices), so every data file in the package then fell
  through as undeclared and the load "succeeded" with an **empty model** — the one
  real warning drowned in the flood of consequent `Not listed in Files.tsv`
  warnings, and the exit code stayed clean, so a build script saw nothing wrong.
  It now fails the run and says why (`no file can be declared without it, so
  NOTHING in this package will load`), with a did-you-mean against the headers
  actually present — which is what a typo'd `loadOrdr:number` really needs. The
  remaining core columns (`typeName`, `superType`, `baseType`) still only warn:
  the row loop tolerates their absence. `description` stays silent (it is pure
  user metadata), and an absent **optional** column stays silent by design — see
  `--list-columns` above. New fixture:
  `files_tsv_errors/missing_mandatory_column`.

- **An undeclared data file is now reported and skipped, not silently loaded.**
  A data file that no `Files.tsv` row declares is no longer parsed: it is reported
  (`Not listed in Files.tsv, so NOT loaded: <path>`, naming both ways out) and skipped
  entirely — not parsed, not reformatted in place, and not exported (it never
  reaches `raw_files`). Previously such a file was loaded anyway with whatever its
  header said, entering the model with no `typeName` (so no registered type, no
  `schema.tsv` entry, no `loadEnv.files` entry), no load order (it sorted ahead of
  every declared file), and none of the per-file wiring `Files.tsv` supplies
  (joins, validators, pre-processors, transcoder, variant) — a stray or
  half-renamed file was indistinguishable from a real one. "Data" is now one
  concept across the loader: any file whose extension, **after** the content
  pipeline peels its decode layers, is `.tsv`, `.csv`, `.json`, `.xml`, or `.eav`
  — so `Item.tsv.gz` and `Item.json.gz` are data too. Notably an undeclared `.eav`
  used to be a hard error that failed the whole run (the transcoder needs the
  `typeName` only `Files.tsv` can give it); it is now simply skipped.

  **Assets** (`.md`, `.txt`, `.lua`, `.zip`, and a `.gz` wrapping a non-data name)
  are not data: they need no declaration and still load and export as before. A
  declared-but-variant/gate-inactive file is *declared*, and keeps its existing
  treatment. New spec `spec/undeclared_data_files_spec.lua`.

  **Migration — `.json` / `.xml` assets must now be declared.** `.json` and `.xml`
  count as data extensions above, so a `.json`/`.xml` file that **no `Files.tsv` row
  declares** is now skipped and **no longer copied into the export**, where 0.30.0
  copied it verbatim. Silent removal from an export is the kind of thing you find
  out about late, so: if such a file is data, give it a row **with a `transcoder`**
  (e.g. `json:objects`); if it is not data, give it a row with
  **`typeName=asset_file`** (see Added, above), which restores the verbatim copy and
  says so explicitly. The warning names both routes.

- **A role typeName is no longer checked as if it were a table type**
  (`TODO/non_table_files.md`, Phase 3). `asset_file`, `patch`, `bulk_patch`,
  `custom_type_def`, `type_wiring_def`, `SchemaOverlay`, `MigrationScript`, `Type`,
  `enum` and `files` are **roles**: words a `Files.tsv` row uses to say what the
  engine should *do* with a file, not the name of the record type its rows are. Two
  checks in `files_desc` are about table types and were category errors on a role,
  and both fired: `typeName 'X' should match fileName 'Y'` (a role is not named after
  its file — `ui/theme.json` declared `asset_file` is exactly right) and
  `Multiple types with name 'X'` (several files legitimately share a role; a package
  with three patches is not declaring the type `patch` three times). A clean tutorial
  run emitted **eight** such warnings a user could do nothing about; it now emits
  none, while a *real* `typeName`/`fileName` mismatch still warns as before. Roles are
  declared once, in the wiring registry (`type_wiring.register(name, {role = true})`,
  queried via `type_wiring.isRoleTypeName`), rather than as a list of exempt names
  hard-coded in the checks — so the fix covers the whole class, including the
  `files` exemption that used to be spelled out by hand.

- **An `IgnoredFile`-tagged file is no longer exported.** A file the loader is told
  to ignore (`typeName=MigrationScript`, or any type tagged `IgnoredFile`) is now
  *neither loaded nor exported* — "pretend it isn't there", as its documentation
  always claimed. It was in fact being copied into every export: the loader dropped
  it from `raw_files`, and the asset pass that runs afterwards — walking the
  unfiltered file list — put it straight back. In-tree migration scripts therefore
  disappear from export trees; they remain untouched in the source tree, which is
  where `migration.lua` reads them from.

- **A `Files.tsv` now declares its paths relative to ITSELF, so a package is
  relocatable.** A self-contained utility mod can be copied into a subdirectory of a
  bigger package — `mods/utilmod/` — and keep working with its `Files.tsv`
  **byte-for-byte unchanged**: its `Item.tsv` resolves to `mods/utilmod/Item.tsv`,
  because that is where its `Files.tsv` sits. Previously every path in a nested
  `Files.tsv` had to be spelled out from the package root, so a package encoded its
  own install location and could not be moved without being edited — the opposite of
  a reusable mod. This applies to `fileName` and to the descriptor columns that name
  a file by path and are matched exactly, now declared `relativePath` in the wiring
  registry: `joinInto` and `edgesFor`. The override-target columns (`patchOf`,
  `bulkPatchOf`, `schemaOverlayOf`) resolve by *basename* and were already
  location-independent, so they are unaffected. A `Files.tsv` at a package root is
  unchanged in every respect (its prefix is empty), which is the overwhelmingly
  common case. A descriptor cannot point outside its own directory: `..` is not a
  valid `filepath`, so a nested `Files.tsv` can only declare files at or below
  itself. New spec `spec/relocatable_package_spec.lua`. As a side fix, a `fileName`
  cell that fails to parse is now reported and skipped instead of crashing the
  loader.

- **An input directory with no `Files.tsv` is now an error.** Every directory passed
  to the loader must be a package directory: one with a `Files.tsv` in its **root**,
  declaring its data files. Only the root needs one — the root's `Files.tsv` can
  declare files anywhere below it by path (`sub/Item.tsv`), and a subdirectory needs
  no `Files.tsv` of its own (though it may have one; see the relocatability entry
  above). Previously a bare folder of TSVs was accepted as a
  "simple package" and its files were loaded untyped — the same guessing the change
  above removes, so the two rules now agree: data is loaded because a `Files.tsv`
  says what it is, or it is not loaded. An **empty** directory is rejected too
  (passing one is a mistake — a typo'd path, or the parent of the real packages —
  worth hearing about rather than silently doing nothing). This subsumes the old
  "contains files but no Manifest or Files.tsv directly" check with one rule and a
  clearer message, and still catches its case: the parent of your packages
  (`tutorial/` instead of `tutorial/core/`) has no `Files.tsv` of its own.

### Fixed

- **A `Files.tsv` row no longer governs a file it was never about.** A file's declared
  load order was found by matching a row's path against the **tail** of the file's
  path, so any file whose path merely *ended with* a declared one's was silently
  governed by that row: `DraftItem.tsv` ends with `item.tsv`, and so does
  `sub/Item.tsv`. Both took the root `Item.tsv` row's priority and counted as
  *declared* — while none of that row's actual wiring (typeName, joins, validators,
  pre-processors, all looked up by exact key) ever applied to them. That made the
  file exactly the untyped stray the undeclared-data rule above exists to catch, and
  it slipped through. The lookup is now by **exact key** — the same
  input-directory-relative key every other `Files.tsv` map uses — so a row governs a
  file here precisely when it governs it everywhere else. The tutorial's
  `DraftItem.tsv` is this case, kept on purpose as a live demonstration of the
  undeclared-file warning.

- **Zip members with backslash-separated names now load.** Zips written by Windows
  PowerShell's `Compress-Archive` use `\` in member names, against the zip spec
  (APPNOTE 4.4.17.1), which mandates `/`. Such an archive enumerated its members
  as `data\Item.tsv` while every lookup normalised to `data/Item.tsv`, so a member
  could never be read back — the load failed with `member not found in archive`,
  whose did-you-mean unhelpfully suggested the very name it had just listed.
  Member names are now normalised to forward slashes at the single point where
  they enter the system (the central-directory parse in `archive_formats`), so the
  rest of the loader sees one separator convention; `read` matches the normalised
  path and seeks by the central-directory offset, never by the raw on-disk name. A
  backslash-terminated *directory* entry is now also correctly skipped.

## [0.30.0] - 2026-07-10

### Added

- **Modding guide + mod-ecosystem hardening.** Closes out `TODO/mod_ecosystem.md`
  (Phase 7, its last phase):
  - New **`documentation/MODDING.md`**: the task-oriented modding guide — how a mod
    (an ordinary child package) overrides another package's data, a use-case →
    feature map (patch / bulk patch / overlay / `onlyIfPackages` + `packages` /
    `ifMissing` / `conflicts` / diagnostics), the **side-table idiom** as the
    supported pattern for mod-added columns, mods building on mods, and an author
    checklist. Linked from the README doc index and the *Mod Overrides* chapter.
  - **`--check-conflicts` now includes an `onlyIfPackages` typo check.** A
    misspelled gate id silently deactivates its file forever (indistinguishable from
    "mod absent"); the report flags gate ids from skipped rows that matched **no
    known id** — not a loaded package, and not named by any manifest's
    `dependencies` / `load_after` / `conflicts` — with an edit-distance did-you-mean
    covering case slips, transpositions, and near-miss spellings. Skipped-row gate
    ids are collected during descriptor gating (`joinMeta.skippedGates`; the ids
    live nowhere else, since a skipped row exits before descriptor-column storage)
    and analysed by the new `manifest_info.unknownGateIds`. The matching lives in
    two new general-purpose `string_utils` functions: `editDistance` (a
    Damerau-Levenshtein counting an adjacent transposition as one edit) and
    `closestMatch` (nearest candidate under a length-scaled distance limit).
  - New `spec/mod_on_mod_spec.lua` pins **mod-on-mod composition** (survey
    scenario 2): a later mod updating cells / merging lists on a row an earlier
    mod's patch **added** (and `--check-conflicts` classifying that as benign
    layering), and a later mod removing an earlier mod's added row (classified as
    row tension). Worked by construction since the mod-overrides work; now a
    regression cannot slip in unnoticed.

- **Missing-target tolerance for multi-version compat patches: the `ifMissing`
  Files.tsv column.** A compat patch supporting several versions of its target — where
  a row (or a whole file) exists in one version only — could not be written: `update`
  on a missing key, a `replace_oldvalue_` value not found, and a target file matching
  no loaded file are load errors. The new optional
  `ifMissing:missing_policy|nil` column (enum `error | warn | silent`, default
  `error` = the unchanged standard severities) sets a **per-override-file** tolerance:
  under `warn` every such miss becomes a logged no-op (a missing target *file* skips
  the whole patch/bulk/overlay file); `silent` additionally quiets the `remove`-missing
  and list-`remove_` not-present warnings. `add` on an **existing** key stays an error
  under every policy (a collision, not a version gap), and `replace` needs no
  tolerance — a missing key appends (upsert). Together with `onlyIfPackages` this
  completes the compat-patch toolkit: gate on *presence*, tolerate *version drift*
  within presence. Phase 6 of `TODO/mod_ecosystem.md` (mod_overrides.md §5.2's
  deferred configurable severity); registered through the type-wiring registry
  (module `row_patch`); documented under *Tolerating Missing Targets* in
  `DATA_FORMAT_README.md`; new `spec/if_missing_spec.lua` (7 integration tests).

- **The `--check-conflicts` report: "where do my mods fight?".** A new reformatter
  flag prints a conflicts-only view of the patch lineage: just the slots where a later
  override **discards** another source's work, each as its apply-order chain
  (last-writer-last) — a cell whose whole value two sources rewrote (`= v` /
  `replace_whole`), a row one mod removed/replaced while another wrote to it (in
  either order), and a column default (`newDefault`) set by two or more overlays.
  Benign composition is deliberately not flagged: list/map deltas, `widenTo` unions,
  validator suppressions, and a mod patching cells of a row another mod *added*.
  Conflicts are legal by design (load order decides), so this is a diagnostic, not a
  gate — the exit code stays 0; mutually exclusive with `--cog-docs` like its
  siblings. Phase 5 of `TODO/mod_ecosystem.md`; `Lineage:conflictReport()` in
  `patch_lineage`; documented in `REFORMATTER.md` (*Check Conflicts*) and under
  *Inspecting Overrides* in `DATA_FORMAT_README.md`; new
  `spec/check_conflicts_spec.lua` (14 tests). Two supporting lineage changes, both
  also visible in `--explain-patch`:
  - **Lineage sources are now package-qualified** (`ModA:PricePatch.tsv` instead of
    `PricePatch.tsv`) whenever file ownership is known, so two mods shipping
    same-named override files — common, since patch files gravitate to conventional
    names — stay distinguishable and are correctly counted as distinct writers.
  - **`newDefault` now records its full per-source history** (winner last), not just
    the merged winner, so an overwritten default is visible at all. Schema lineage
    events are also recorded in sorted (deterministic) target/column order.

- **Package-qualified override targets + ambiguity diagnostics.** With many
  independently-authored mods, two packages shipping the same file name is inevitable,
  and `patchOf` / `bulkPatchOf` / `schemaOverlayOf` resolve by basename. Three changes
  make that safe (`TODO/mod_ecosystem.md` Phase 4):
  - **Deterministic resolution + warning on ambiguity.** An unqualified target whose
    basename matches several loaded files now binds to the **alphabetically-first full
    name** (previously an arbitrary, hash-order-dependent pick) and logs a warning
    naming every candidate and the winner.
  - **The `package.id:Name.tsv` qualified form.** A target may name the owning package
    (`patchOf=some.mod:Shared.tsv`, matched case-insensitively; ownership by directory,
    the same rule package processors use), binding it to that package's file. A
    qualifier naming an unloaded package or one that owns no such file is a load error.
    Because `:` is not a legal `filepath` character, the qualified form is **opt-in per
    column declaration**: a new built-in **`override_target`** type (a filepath
    optionally prefixed with a package qualifier) — declare `patchOf:override_target|nil`
    instead of `patchOf:filepath|nil`; both header spellings are recognised
    (descriptor-column declarations gained an `altTypes` field).
  - **Schema overlays now bind to exactly one file.** Overlays are collected against
    the resolved target file (with the same diagnostics), fixing a latent bug where an
    overlay silently applied to **every** loaded file sharing the target's basename.
    Also stricter: an overlay whose target matches no loaded file is now a reported
    error (previously silently inert) — gate the overlay row with `onlyIfPackages` when
    its target belongs to an optional package.

  Internals: new `patch_executor.splitQualifiedTarget` / `newTargetResolver` (shared by
  patch application, package-processor write scope, and the `=expr` recompute, removing
  three independent hash-order basename maps); `schema_overlay.collectOverlays` takes an
  optional resolver and keys overlays by resolved file key. `joinInto` is unaffected —
  it targets the full path as listed in `fileName`, not a basename (documented).
  Documented under *Targeting a Parent File* in `DATA_FORMAT_README.md`; new
  `spec/target_resolution_spec.lua` (5 integration tests).

- **Declared package incompatibility: the `conflicts` manifest field.** A package
  manifest may now list package ids in `conflicts:{package_id}|nil`: if any listed
  package is loaded alongside, the load **fails** with an explicit
  "Conflicting packages loaded together" error naming both sides — instead of two
  incompatible mods (e.g. two total overhauls) silently composing via last-writer-wins.
  The check is symmetric by construction (every loaded manifest's `conflicts` list is
  checked, so either side declaring it is enough), a conflict naming an **absent**
  package is silently vacuous (the declaration only bites when both are installed),
  and a self-conflict is a manifest error. Mirrors Factorio's `!mod` / Forge's
  `breaks`. Checked in `manifest_info.buildDependencyGraph` where both manifests are
  in hand. Phase 3 of `TODO/mod_ecosystem.md`; documented under *Manifest Fields* in
  `DATA_FORMAT_README.md`. New bad-input fixture
  `bad_input/manifest_errors/conflicting_packages` plus 3 `manifest_info_spec` tests.

- **Conditional file loading: the `onlyIfPackages` Files.tsv column — the declarative
  half of optional mod compatibility.** A `Files.tsv` row listing package ids in a new
  optional `onlyIfPackages:{package_id}|nil` column is active only when **every**
  listed package is loaded (AND semantics; use two rows for OR). When any listed
  package is absent the row is skipped exactly like a variant-filtered row: the file
  is not parsed, not exported, exempt from the on-disk existence check, and — the
  point for compat patches — a gated `patchOf` / `bulkPatchOf` / `schemaOverlayOf`
  whose target lives in the absent package no longer kills the load with "patch target
  not found". Each skip logs the missing id at info level. Combined with `load_after`
  (the ordering half, a no-op when the package is absent) this is the
  **optional-compatibility idiom**: a mod ships built-in support for another mod that
  quietly deactivates when that mod is not installed, replacing the separate
  "A+B compatibility patch" package that ecosystems without conditionals force on
  authors. Applies to any file kind (patches, overlays, bulk patches, data, joins).
  The column registers through the type-wiring registry (module `package_gating`);
  the gating runs beside the variant filter in `files_desc.processFilesDesc`, keyed
  on the same published `packages` set expressions see. Tutorial:
  `tutorial/expansion/SeasonalPatch.tsv` is gated on the not-installed
  `tutorial.seasons` package (and the expansion manifest pairs it with `load_after`).
  Phase 2 of `TODO/mod_ecosystem.md`; documented under *Conditional Files* in
  `DATA_FORMAT_README.md`. New `spec/only_if_packages_spec.lua` covers the
  gated-compat load in both directions (required package present → patch + bulk
  `where` reading `packages` apply; absent → whole compat layer skips, load green).

- **Expressions can detect other loaded packages (`packages` + `versionSatisfies`) —
  the expression half of optional mod compatibility.** Every sandbox surface that sees
  the load environment — `=expr` cells, COG blocks, row / file / package validators,
  bulk-patch `where` selectors, and pre-processors — now has a read-only **`packages`**
  table mapping each loaded `package_id` to `{name, version}` (an absent package
  indexes to `nil`, so presence is a truthiness test) and the
  **`versionSatisfies(op, required, installed)`** helper (the manifest `dependencies`
  operators: `=`, `>`, `>=`, `<`, `<=`, `~`, `^`). A compat rule can now say
  `packages["some.mod"] and row.tags has "metal"` in a `where` selector, or warn from a
  validator unless a rebalance mod is loaded. Both names are **reserved**: they are
  seeded into the load environment *before* code libraries load, so a library claiming
  either fails with the standard name-conflict error; a `publishContext` that would
  shadow **any** existing expression-environment name (`files`, `packages`, a code
  library, a curated sandbox global like `math`) is now likewise a load error instead
  of a silent clobber. Manifest-file COG cannot see `packages` (manifests load while
  the package set is still being resolved). Phase 1 of `TODO/mod_ecosystem.md`;
  documented under *Detecting Other Packages* in `DATA_FORMAT_README.md`.

- **User-controlled load order for unrelated packages (mod-manager support).** Packages
  *not* related by `dependencies` / `load_after` now load in the order their **root
  directories were passed to the loader** (CLI argument order), falling back to
  alphabetical `package_id` order among packages sharing one root — so a host
  application (game launcher, mod manager) controls the relative order of independent
  mods simply by argument order, with no manifest edits. Implemented by replacing the
  topological sort's DFS with a **greedy ranked Kahn scheduler**: at each step the
  lowest-ranked package whose prerequisites have all loaded is loaded next, with rank =
  (input-root position, `package_id`); dependency edges always dominate, and cycle
  detection keeps the same "Circular dependency detected: a -> b -> a" path diagnostic.
  In a dependency-entangled set the alphabetical fallback can order packages differently
  than the previous DFS post-order did (both fully deterministic — the new rule is the
  simpler "earliest ready package loads first"). `manifest_info.resolveDependencies`
  gains an optional `opt_manifestRank` (manifest path → numeric preference), which
  `manifest_loader` derives from the `directories` argument via the collector's
  `file2dir` map. Completes `TODO/package_order_determinism.md` (Phase 2); documented
  under Conflict Resolution in `DATA_FORMAT_README.md`.

### Fixed

- **Made package load order deterministic across runs.** The relative load order of two
  packages *not* related by `dependencies` or `load_after` could previously differ between
  runs of the same command on the same data: `buildDependencyGraph` and `topologicalSort`
  iterated string-keyed tables with `pairs()`, whose order Lua 5.2+ randomizes per process
  via the string-hash seed. Both now iterate in sorted `package_id` order, so unrelated
  packages load in **alphabetical `package_id` order** — a stable tie-break that matches
  the existing file-level rule (lowercased-path alphabetical). Dependency edges still
  dominate. This makes every load order derived from `package_order` reproducible,
  including mod-override conflict resolution (last-writer-wins) and the `--explain-patch`
  / `--export-merged` diagnostics. Documented under Conflict Resolution in
  `DATA_FORMAT_README.md`.

## [0.29.0] - 2026-06-20

### Changed

- **Grouped the engine's Lua modules into topical sub-directories.** The repository
  root previously held 59 flat module files; it now holds **7** (the CLI entry-point
  scripts `migration`, `ollama_batch`, `tsv_diff`, `reformatter`, `export_tester`,
  `extract_test_errors`, plus the `parsers` aggregator). The other 52 library modules
  moved into eight relationship-based packages — `util/`, `infra/`, `tsv/`, `serde/`,
  `content/`, `wiring/`, `overrides/`, `loader/` — mirroring the dependency layering and
  the existing `parsers/` package. Each is now required by its **dotted, namespaced
  name** (e.g. `require("util.read_only")`, `require("tsv.tsv_model")`,
  `require("content.content_pipeline")`); all ~540 internal `require` sites were updated
  accordingly. This is a **purely structural change** — no runtime behavior, public
  CLI invocation, data format, or API surface changed, and the full test suite passes
  unchanged (3014 assertions). **Breaking only for external code that requires an engine
  module by its old bare name** (`require("read_only")` → `require("util.read_only")`);
  in-project data packages and sandboxed user code are unaffected, since they never
  require engine modules directly. `documentation/MODULES.md` was reorganized to match
  (grouped index, a directory-layout table, and corrected file links).

## [0.28.0] - 2026-06-15

### Added

- **Recompute downstream `=expr` cells after patches.**
  When a mod override changes a cell, other `=expr` cells in the **same row** that read
  it (via `self.x`) are now **re-evaluated**, so derived values stay consistent without
  the mod having to patch them too. Example (shipped in the tutorial): core `Spell.tsv`
  has `totalDamage = self.baseDamage * …`; an expansion patch buffs `fireball`'s
  `baseDamage` 25→40 and `totalDamage` now recomputes 37.5→60 automatically. Covers
  explicit `=expr` cells **and** columns with a default `=expr` applied to an empty cell;
  re-evaluation runs in dependency order (a chain `a = self.b+1`, `b = self.c+1` resolves
  correctly). A cell the override set **directly** is never clobbered (its explicit value
  wins), and recomputed values are not baked into source (the `=expr` is preserved). It
  runs in two (idempotent) passes — after patches and after the package-scoped
  pre-processors — so such a processor also reads consistent derived values. This
  needs to know which cells an override set directly, so **patch lineage is now tracked
  automatically whenever there is override work** (previously only for `--explain-patch`);
  a plain non-mod load still tracks nothing. Cross-row / published-constant dependencies
  remain out of scope. New `patch_executor.recomputeAfterPatches`.

- **`--explain-patch` + patch lineage.** A new
  reformatter flag `--explain-patch[=<filter>]` prints a per-cell **lineage report**
  answering "which mod override set this?" — the provenance counterpart to
  `--export-merged`'s merged data. It records every kind of override and attributes
  each to the file (or `package:<id>`) responsible: schema overlays (`widenTo`
  / `newDefault` / validator suppression), row `add`/`remove`/`replace`, cell
  `update`s and list/map deltas, `bulk` rule matches (named by their rule), and
  package-processor writes. Two mods writing the same cell appear as a chain in
  apply order. The optional `<filter>` = `<file>[:<pk>[:<column>]]` narrows the report
  (e.g. `--explain-patch=Item.tsv:sword:price`). Tracking is threaded as an optional
  lineage object through every override write path. New module `patch_lineage`;
  `manifest_loader.processFiles` returns the collected `lineage` on its result.

- **`tsv_diff` directory comparison and compressed-source support.** `tsv_diff` (the
  data-level TSV comparison tool, see `TSV_DIFF.md`) now accepts **two directories**
  instead of two files: `lua54 tsv_diff.lua <dir1> <dir2>` walks both trees recursively
  and compares them file by file, reporting each `.tsv` file as identical (`=`),
  differing (`~`, with the per-file diff inlined), or present on only one side (`+`/`-`),
  followed by a directory summary. It also reads **compressed sources** transparently: a
  `.tsv.gz` (or any file whose leading bytes are the gzip magic) is decompressed and its
  *uncompressed* content compared. In directory mode, files are paired by their relative
  path with any compression extension peeled, so a plain `Item.tsv` in one tree matches a
  gzipped `Item.tsv.gz` in the other — making it easy to verify the output of a
  reformatter run (e.g. `--export-merged`) against compressed source data. The new public
  `tsv_diff.diffDirectories(dir1, dir2, options)` exposes this directly (and `diff()`
  auto-dispatches to it when both inputs are directories); single-file mode gains the same
  gzip awareness. Decompression goes through the lazy `compression` codec registry, so
  gzip is the only format wired today and `libdeflate` is loaded only when a compressed
  file is actually read.

- **`--export-merged` reformatter flag.** Writes a
  TSV snapshot of every loaded dataset **with all mod overrides applied** (row and bulk
  patches, schema-overlay defaults, list/map deltas, package-processor writes)
  to a separate tree — `--export-merged` (default `merged/`) or `--export-merged=<dir>`
  — mirroring the source layout as `<dir>/<package>/<relpath>`. It is the deliberate
  counterpart to the no-bake rule: in-place reformat *omits* overrides to protect parent
  source, while merged export *includes* them so you can inspect (or diff) the final
  merged data. Only cells whose parsed value actually changed are re-rendered, so
  **unchanged cells stay byte-identical to source** (no requoting / default-baking
  noise) and `=expr` cells keep their expression. Each file is written **in its source's
  own on-disk format** so it diffs cleanly: plain `.tsv` verbatim (LF, never CRLF), a
  compressed `.gz` re-compressed, and a reversible transcoded source (`.eav` / `json:*`
  / `xml:tabulua`) re-encoded — archive (`.zip`) members and non-reversible sources are
  skipped. The live dataset and all source files are left untouched (the serializer
  temporarily rewrites each cell's reformatted text from `parsed`, then restores it).
  Runs independently of `--file=` and is mutually exclusive with `--cog-docs`.

- **Package-scoped pre-processors.** A
  package manifest may now declare `preProcessors:{processor_spec}|nil`. These
  **package-scoped** processors run after all files are parsed **and after patches
  are applied**, but before validators — so they (and the validators after them) see
  the fully merged-and-patched state of every loaded file via `files` (keyed like
  package validators). Their write helpers (`setCell` / `clearCell`, plus `copy` and
  `rowByKey(file, key)`) are **scoped**: a processor may only mutate files its package
  owns or has declared patches for; writing any other file is a reported error.
  **Cross-package ordering** follows package load order, refined by each spec's
  optional `requires:{name}` field ("these packages' package-scoped processors must run
  before mine"): the engine topologically schedules the packages, breaking ties by load
  order; a `requires` cycle is a hard error, and requiring an unloaded package warns
  (the constraint is vacuous) without failing the load. A parent's **own** file-level
  pre-processor flagged `rerunAfterPatches: true` is re-executed in this same phase
  against the patched data, so idempotent derived data (inverse back-references, etc.)
  reaches rows that mods added via patches. Like every other mod-override
  effect, these writes are never baked into source (they go through `setCell`, which
  leaves the on-disk text untouched). New `processor_executor` exports
  `runPackagePreProcessors` / `selectRerunProcessors`; `processor_spec` gains a
  `requires` field.

- **Mod-style list/map deltas.** A row
  patch's `update` row can now **merge into** a parent list or map cell instead of
  replacing it, via verb-prefix companion columns. For a list column `<col>`:
  `append_<col>` / `prepend_<col>` (insert at tail/head, preserving order),
  `remove_<col>` (drop the first occurrence of each value; `remove_last_<col>` drops
  the last), `replace_<col>` (set the whole list), and the paired
  `replace_oldvalue_<col>` / `replace_newvalue_<col>` (replace **in place, by
  value**, position preserved — `replace_last_*` targets the last match). Map
  columns support `append_<col>` (merge entries), `remove_<col>` (drop keys), and
  `replace_<col>`. **Prefix-collision precedence:** a patch column whose literal
  name matches a parent column always binds to it; the merge-prefix reading is only
  a fall-back (a warning fires when both are possible). Sub-record fields are
  patched by their dotted path (`stats.attack`) with no new mechanism — they are
  ordinary exploded columns. Edge cases are reported: `replace_oldvalue_` not found
  is an error, a half-specified in-place pair is a header error, a removed value not
  present warns, and `old == new` / multiple matches warn. The patch header is
  analysed once per file (`analyzePatchPlan`). Tutorial: `ItemPatch.tsv` now appends
  tags to core items via `append_tags`.

- **Mod-style filter/transform patches.**
  A dependent package can now patch parent rows **by a selector** instead of by key,
  via a `bulk_patch` file: `typeName=bulk_patch` and `bulkPatchOf=Target.tsv` in
  `Files.tsv`. Column 1 is a unique **rule name**; a required `where:expression`
  selects parent rows (evaluated per row in the validator sandbox — `self`/`row` is
  the candidate, with the validator helpers `any`/`count`/`all`/… and published
  contexts in scope); a `patchOp` of `update` or `remove` says what to do with the
  matches. For `update`, the remaining transform cells are applied to each matched
  row — a cell starting with `=` is an **expression evaluated against the matched
  target row** (`self` = that row, so `=row.price * 2` does what you'd expect),
  otherwise it is a literal parsed by the parent column. A selector matching zero
  rows warns (likely a typo); a throwing selector is a reported error. Bulk patches
  compose with row patches on the same target, applied together in package
  load order. Like row patches, they mutate the parent in place for the build/validation
  but are never baked into parent source (the reformatter skips patched targets).

  The `where` selector and transform columns are `expression`-typed, which now
  keeps their `=expr` cells **raw** (an `expression` column tolerates a leading `=`
  and is never load-evaluated — `processCell` skips it), so they survive to be
  evaluated at apply time against the target rather than at load against the rule
  row. (Two supporting improvements landed with this: the `expression` parser
  tolerates a leading `=`, and `expression`-typed columns are no longer
  load-evaluated — which also hardens `suppressValidator`. Also documented:
  omitting a column type defaults it to `string` — see `DATA_FORMAT_README.md`.)
  `validator_executor` gained `evaluateInValidatorEnv` (raw-value evaluation in the
  validator sandbox) and exposes `wrapRowsForValidation`; `patch_executor` gained
  `applyOneBulkPatch`. The tutorial expansion ships `ItemBulk.tsv` (an Epic-rarity
  surcharge on core items via `=row.price + 100`).

- **Mod-style row patches.** A
  dependent package can now **add / remove / update / replace** rows of a parent
  file without forking it, via a patch file: `typeName=patch` and
  `patchOf=Target.tsv` in `Files.tsv` (target resolved by basename). Column 1 is
  the parent's primary key; a `patchOp:patch_op` column (enum
  `add | remove | update | replace`) carries the operation:
  - **`add`** inserts a new row (empty cells take the parent column's default);
    an existing key is an error.
  - **`remove`** deletes the row by key (missing key warns, no-op).
  - **`update`** changes only the named non-empty cells — an empty cell means
    "leave unchanged" (a local override of the usual "empty = default"); `=nil`
    clears a nullable column; a missing key is an error.
  - **`replace`** rewrites a row wholesale (remove + add).

  Each patch value is parsed against the patch file's own column type, then
  re-validated against the **parent** column's parser at apply time, so a schema
  overlay's `widenTo` already in effect lets a patch set a value the parent type
  would otherwise reject (e.g. a negative price). Patches apply in **package load
  order** (last writer wins) after own-package pre-processors and **before
  validators**, so validators — and the exporter — see the patched state.
  Patches are **never baked into parent source**: the parent dataset is mutated
  in place for the build/validation, but the reformatter skips patched targets,
  and `update` writes leave each cell's on-disk text untouched. New
  module `patch_executor.lua`; the `patch` typeName keyword, the `patch_op` enum
  and the `patchOf` descriptor column register through the type-wiring registry;
  `tsv_model` gained `newDataCell` / `newDataRow` builders for constructing added
  rows. The tutorial expansion package ships `ItemPatch.tsv` (patches core items,
  including an overlay-enabled negative price — the overlay+patch combo).

- **Mod-style schema overlays.** A
  dependent package can now *loosen* a parent file's column metadata without
  forking it, via a `SchemaOverlay` file. A file declaring
  `typeName=SchemaOverlay` and `schemaOverlayOf=Target.tsv` in `Files.tsv`
  (the target resolved by basename, like `joinInto` / `edgesFor`) targets the
  parent's columns with three safe-by-construction operations:
  - **`widenTo`** replaces a column's type with a strictly *wider* one, so a
    value the declared type rejected now parses (e.g. `gold` → `gold|int` to
    allow negative prices). Narrowing — or an unknown / expression type — is
    rejected at load; an identical type warns and is a no-op. Multiple overlays
    on one column compose as the **union** of their widenings.
  - **`newDefault`** overrides the value used for that column's empty cells
    (literal or `=expr`); last overlay in load order wins.
  - **`suppressValidator` + `validatorLevel`** match a parent row/file
    validator by its expression text and downgrade it (`warn`) or remove it
    (`none`); lowest severity across overlays wins. An unmatched suppressor
    warns.

  Overlays are a **load-time view, never baked into the source**: a column's
  declared `type_spec` / `default_expr` are preserved (so the reformatter
  round-trips the parent file unchanged), while the effective
  widened type drives parsing and a separate effective default drives empty
  cells. New module `schema_overlay.lua`; the `SchemaOverlay` record type, the
  `overlay_level` enum (`error|warn|none`) and the `schemaOverlayOf` descriptor
  column register through the type-wiring registry. Collection runs as a
  pre-parse pass (so widening takes effect before target cells parse) and the
  validator-severity overrides run just before validation. The tutorial
  expansion package ships two example overlays on the core package
  (`ItemPricePolicy.tsv` widens `Item.price`; `SpellTuning.tsv` lowers the
  `Spell.cooldown` default).

## [0.27.0] - 2026-06-09

### Added

- **Archive export / reformat behaviour — the packed archive is the export
  representation of its members.** On export, an archive file streams to the build
  **verbatim** (the normal passthrough-by-reference copy), so a mod that includes a
  `utilmod.zip` keeps it byte-for-byte. Its loaded members are **input-only**: their
  data feeds the model, but they are *not* re-emitted at a nested
  `…/utilmod.zip/data/Item.tsv` path (which would both duplicate the packed copy and
  create a confusing `.zip`-as-directory layout). The reformatter likewise treats an
  archive member as a **read-only input** — it never tries to splice reformatted
  bytes back into a container, leaving the archive untouched (writing back into an
  archive is deferred). Both behaviours key off the same `resolveArchivePath` check,
  so they stay consistent across every export format. See `TODO/archive_files.md`.

- **Archive members participate in the load like loose files (collection /
  expansion).** `zip` joined the loader's collected extensions, and a new
  `file_util.expandArchives` runs after collection: for every collected archive it
  lists the members (central-directory metadata only — never an extraction) and
  appends each member whose extension is collectable as a virtual path
  (`utilmod.zip/data/Item.tsv`), mapped to the same source directory as the
  archive. From there a member is indistinguishable from a loose file to the rest
  of the loader — **with no change to the existence check, the data-vs-asset gate,
  or transcoder routing** (they already operate on names and read through the
  now-archive-aware `readFileBinary`/`getFileSize`). So a `Files.tsv` row pointing
  at a member inside a zip loads it as data and its rows appear in the model; a
  member `data.tsv.gz` *decodes and parses* (the archive layer composes with the
  content pipeline); a collectable non-data member (e.g. a `.txt`) is stored as an
  asset; and a typo in a member path yields the normal "does not exist" diagnostic.
  The archive file itself still streams verbatim as a passthrough asset. See
  `TODO/archive_files.md`.

- **Archive members are now readable as virtual files (`file_util` archive
  awareness).** A path like `mods/utilmod.zip/data/Item.tsv` transparently reads
  the member `data/Item.tsv` inside the container `mods/utilmod.zip`. The new
  `file_util.resolveArchivePath` splits such a path at the first segment whose
  extension is a registered archive format **and** which is a real file on disk
  (so a directory literally named `foo.zip/` is still a directory), and
  `readFileBinary` / `getFileSize` became archive-aware: a member is read by
  extracting it (bounded by a per-member size cap to bound a zip bomb) and sized
  from the central directory (metadata only, never an extraction). Because the
  loader funnels all binary reads and size queries through exactly these two
  functions, this lights up the whole load path with no change to
  `content_pipeline`, `files_desc`, or `storeRawFile`. A loose-file path is
  untouched (a few cheap string checks, no extra `stat`). A small per-process
  archive cache (container path + mtime/size → parsed central directory, and the
  raw bytes within a budget) avoids re-parsing the zip on every member access and
  is cleared by `global_reset`. Not yet wired into collection — a `Files.tsv`
  reference to a member resolves once collection expands archives (next phase).
  See `TODO/archive_files.md`.

- **Archive / data-set format registry (`archive_formats.lua`) — reading the
  member files inside a container archive (zip first).** A "game mod" is often
  distributed as a single packed `.zip`, and a bigger mod may include that zip as
  one of its own files. An *archive* is the load-bearing new concept: one on-disk
  file that is a **container for a set of member files** with an internal directory
  tree — distinct from `compression` (which wraps a single stream), so it cannot be
  a content-pipeline stage. This first piece is the registry itself, with no loader
  integration yet (that follows in later phases): a lazy provider registry mirroring
  `compression` (`list(format, bytes)` enumerates members from the central
  directory; `read(format, bytes, member, maxBytes)` extracts one), plus a pure-Lua
  zip provider that parses the zip framing itself and inflates method-8 members via
  the same `libdeflate` raw-DEFLATE path the gzip codec uses (no new dependency, no
  second DEFLATE engine). Each extracted member is verified against its
  central-directory **CRC-32** (`compression.crc32`, now exposed publicly alongside
  `u32le`). The provider is hardened against untrusted input — per-member size
  (zip-bomb) caps, a member-count cap, zip-slip / absolute-path rejection, and clear
  errors for Zip64 / encrypted / split / corrupt archives (never a silent mis-read);
  registering the format does not require `libdeflate`, and an archive opened without
  it degrades to a logged "unsupported," not a crash. See `TODO/archive_files.md`.

- **Re-importing TabuLua's own TSV export variants — three new `tsv:*` input
  transcoders.** The reformatter can *write* a wide TSV whose cells are Lua
  literals, typed JSON or natural JSON (`--file=tsv --data=lua|json-typed|json-natural`),
  but until now those files could not be *read back*. New content-pipeline
  `transcode` stages `tsv:lua`, `tsv:json-typed` and `tsv:json-natural`
  (`tsv_transcoders.lua`) close that gap: they share the native TSV skeleton (same
  `name:type` header) and decode each cell from its alternate encoding back to the
  native value via the existing deserializers, emitting the wide TSV the loader
  expects. They are **id-selected** via the `Files.tsv` `transcoder` column (never
  auto-fire — they share the `.tsv` extension with native data), **schema-free**
  (types come from the file's own header), and **reversible** (each declares an
  `encode`, so the reformatter rewrites the source in its chosen cell encoding).
  See `DATA_FORMAT_README.md` and `TODO/export_format_reimport.md`.

- **Re-importing the `.lua` export — the `lua:tabulua` input transcoder.** A
  `--file=lua` export is a single `return { <header>, <row>, … }` table; the new
  `lua:tabulua` content-pipeline stage (`lua_transcoder.lua`) reads it back as a
  wide, typed table — the natural round-trip pair for a Lua application, which can
  read its own exported data with the native `load`. It is **id-only** (a `.lua` is
  a code library to the loader by default, so a data `.lua` must be opted in with
  `transcoder=lua:tabulua` — it never auto-fires), **schema-free** (row 1 is the
  `name:type` header), and **reversible**. The file is executed under the same
  sandbox + instruction-quota machinery code libraries use (a hostile data file
  that loops aborts instead of hanging the load).

### Changed

- **Reformatter: a `transcoder`-assigned `.tsv`/`.csv` is no longer rewritten as
  native TSV.** Such a file's cells are in an alternate encoding (the new `tsv:*`
  transcoders) and `raw_files` holds only the derived wide TSV, so the reformatter
  now routes it to the id-selected `reversibleTranscode` path (re-rendering its
  cells through the transcoder's `encode`) instead of clobbering it with native
  TSV. Plain `.tsv`/`.csv` files with no `transcoder` are unaffected.

## [0.26.0] - 2026-06-08

### Added

- **JSON input round-trip — the six `json:*` transcoders are now reversible.**
  Each `json:objects` / `json:rows` / `json:columns` stage (and its `:typed`
  variant) now declares an `encode` (`json_transcoders.*ToJson`), so the
  reformatter rewrites a `.json` data source from the reformatted wide TSV — the
  way it already round-trips `.xml`/`.eav` — reached through the id-selected
  `reversibleTranscode` (no engine change; the generic hook was built for XML).
  The reverse is **schema-free**: column names, types and order come from the
  wide-TSV `name:type` header (parsed with `processTSV`, the same machinery the
  loader uses), not a `typeName`. The round-trip is **normalizing** (canonical
  JSON), not byte-identical: object key order becomes the header order and
  number/whitespace formatting is canonical. `:typed` is value-lossless (the
  self-describing `{"int":…}` form survives any JSON toolchain); `json-natural`
  carries the usual conventional-JSON caveats (`json_complex_values.md`). See
  `TODO/json_input_round_trip.md`.
- **`IgnoredFile` type tag and `MigrationScript` built-in type.** `IgnoredFile`
  is a built-in type tag (ancestor `table`) marking file types that the loader
  recognises but deliberately does **not** load as data. The built-in record
  type `MigrationScript` (`{command, p1…p5}`) is its one built-in member, so
  migration scripts (see `migration.lua`) are now recognised declaratively by
  their `typeName` in `Files.tsv` rather than by a hard-coded content-shape
  heuristic. Any user file type can opt into the same behaviour by adding
  `IgnoredFile` to its `tags` field — useful for scratch files, templates, or
  fixtures kept in the data tree but excluded from the dataset. See
  `DATA_FORMAT_README.md` § *Ignored files*.
- **`parsers.isMemberOfTag(tagName, typeName)`** is now part of the public
  parsers API (previously introspection-internal).

### Changed

- **Migration-script recognition is now declarative.** A migration script is
  identified by `typeName=MigrationScript` in `Files.tsv` (a member of the
  `IgnoredFile` tag) and skipped before parsing — its untyped parameter columns
  and repeating `command` primary key would otherwise fail normal loading. This
  replaces the former shape-sniffing recogniser.

  > **Migration guide:** A migration script that lives **inside** a loaded data
  > tree must now be declared in `Files.tsv` with `typeName=MigrationScript`
  > (any `fileName`, `superType` empty, `baseType=false`). Migration scripts run
  > from **outside** the dataset (the usual `lua54 migration.lua <script>
  > <rootDir>` form, with the script not under `rootDir`) are never scanned and
  > need no change. `migration.lua` itself reads scripts directly and is
  > unaffected. Migration scripts are one-shot/disposable, so this break is
  > low-impact.

### Removed

- **`isMigrationScript` content-shape heuristic** in `manifest_loader.lua`
  (replaced by the `IgnoredFile` tag check above). The old heuristic could
  silently skip a legitimate data file whose primary key happened to be
  `command` followed by `p1, p2, …`.

## [0.25.0] - 2026-06-07

### Added

- **Composite (table-typed) cell values in the JSON transcoders.** The
  `json:objects` / `json:rows` / `json:columns` stages no longer reject a cell
  that is itself a table-typed value — an array, map, tuple, or nested record
  matching the column's declared type now loads correctly across all three
  layouts. A composite JSON value is reconstructed to a Lua value and serialised to
  TabuLua's native cell text, so the column's own parser does the final typing and
  validation. Reconstruction is **type-directed**: each map key is rebuilt with the
  key type's own parser, so a `map<string,…>` key `"01"` stays the string `"01"`
  while a `map<integer,…>` key `"1"` becomes the number `1`, at any nesting depth.
  Non-finite numbers (reachable only via a `1e999`-style overflow) are reported but
  do not abort — every offending value is flagged in one pass.

- **`json:objects:typed` / `json:rows:typed` / `json:columns:typed` transcoders.**
  The same three row layouts, but cell values use TabuLua's self-describing typed
  JSON encoding (the read-back of `exportJSON`: integers as the string
  `{"int":"…"}`, special floats as `{"float":"…"}`, tables as `[size, …, [k, v]]`).
  Because the encoding carries the types, values survive independently of the
  column type and of the JSON toolchain. The main use is **64-bit integers**, which
  most JavaScript-derived JSON tools cannot represent as a number (capped at 2^53):
  the `{"int":"<digits>"}` string form round-trips an exact `int64` through any
  toolchain.

- **`deserialization.processNaturalValue` / `processTypedValue`.** The
  natural/typed JSON post-processing (special-float sentinels, int wrappers, the
  `[size,…]` table encoding) is now exposed as functions that operate on an
  already-decoded value, so a caller holding a decoded substructure can reuse them
  without a lossy re-encode.

### Fixed

- **`serializeTable`, `serializeTableJSON`, and `serializeTableXML` produced
  malformed output for a sequence stored in Lua's hash part.** These serialisers
  emitted the sequence/array part by walking `pairs(t)` and assuming it yielded
  indices `1, 2, …` in order. For a table whose sequence lives in the hash part
  (e.g. one built with explicit `{[1]=…, [2]=…}` keys), `pairs()` order is
  arbitrary, so `serializeJSON({[1]="a",[2]="b"})` could produce the malformed
  `[2,null,"b","a"]` (and likewise for the native and XML forms). All three now
  emit the sequence prefix by explicit index, making the output independent of
  `pairs()` order. (`serializeTableNaturalJSON` was already correct.)

## [0.24.0] - 2026-06-06

### Added

- **XML files load as data — the `xml:tabulua` round-trippable transcoder.** New
  `xml_transcoder` registers as a content-pipeline `transcode` stage that reads
  TabuLua's own XML export format (`<file>/<header>/<row>`) back in as a wide,
  typed table. It is **schema-free / self-describing**: column names and types
  come from the file's own `<header>` (`name:type` cells), not a `typeName`. It
  is **id-selected** (`transcoder=xml:tabulua` in `Files.tsv`) and never
  auto-fires on a stray `.xml` asset; the `xml:*` id space is left open for
  user-registered XML layouts. Like `.eav` it is **reversible**: the reformatter
  rewrites an `.xml` source from the reformatted wide TSV. Composite (`<table>`)
  cells are supported (symmetric with export) — they round-trip through the same
  `parsers`/`tsv_model` machinery every other format uses, so the in-cell form
  agrees with the rest of the pipeline. The transcoder verifies the root is in
  the `urn:tabulua:table:1` namespace and errors clearly on a foreign document.

- **`inputExtensions` guard on transcode stages.** A `transcode` stage may now
  declare `inputExtensions` (an array, e.g. `{"json"}` / `{"xml"}`). Under
  **explicit** selection (`transcoder=…` in `Files.tsv`), the effective file
  name's final extension is checked against it and a mismatch is a hard error —
  catching a mis-pointed `transcoder` column (e.g. `json:rows` aimed at a
  `.txt`) early instead of mis-parsing. It is a **guard only**, never a matcher
  (so it can't make ambiguous JSON layouts auto-fire). The three `json:*` stages
  and the new `xml:tabulua` stage declare it.

- **`raw_eav` — Entity–Attribute–Value (long-format) table support.** New
  low-level module that pivots between the 3-column `(entity, attribute,
  value)` layout (row/column identifiers are domain keys, not indices) and
  the normal wide table layout. `eavToTable`/`stringToTable`/`fileToTable`
  rebuild a wide table from triples; `tableToEav`/`tableToString` compress
  a wide table to triples; `isEav` validates the long shape. First-seen
  row/column ordering, configurable duplicate-pair policy (`onConflict`,
  default error), sparse-table aware (`skipEmpty`). Cells stay strings.

- **`.eav` files load as data — the first extension-keyed, round-trippable
  transcoder.** New `eav_transcoder` registers as a content-pipeline `transcode`
  stage that **auto-matches the `.eav` extension** (no `Files.tsv` `transcoder`
  column needed, unlike the JSON transcoders), so an `.eav` listed in `Files.tsv`
  loads as an ordinary wide, typed table. The rebuilt header is typed from the
  file's `typeName` schema (schema field order; the key column is the schema's
  first field). Unlike JSON the stage is **reversible**: the reformatter rewrites
  an `.eav` source from the reformatted wide TSV (`content_pipeline` gains
  `autoTranscodes` / `reversibleTranscode`; `eav` joins the loader's collected
  extensions and the pipeline's text extensions).

### Changed

- **BREAKING — the XML export format is now namespaced.** The exporter emits the
  root as `<file xmlns="urn:tabulua:table:1">` instead of a bare `<file>` (the
  trailing segment is a format version). This is the discriminator that lets a
  reader tell a TabuLua data file from an unrelated `.xml` asset. Existing
  exported `.xml` files must be re-exported. `schemas/export.xsd` gains a
  matching `targetNamespace` (qualified elements); `schemas/export.dtd` models
  the namespace as a `#FIXED xmlns` attribute on `file` (DTDs are
  namespace-blind). The value-level XML serializer (bare `<integer>`/`<table>`
  cell values, no `<file>` wrapper) and round-trip tests are unaffected. The
  importer and internal schema validator accept both the namespaced root and the
  legacy bare `<file>`.

- **`content_pipeline.reversibleTranscode` accepts an optional transcoder id.**
  `reversibleTranscode(file_name, opt_transcoderId)` resolves an **id-selected**
  reversible transcode stage (the XML case, which has no `extensions`), falling
  back to the existing extension-keyed lookup when no id is given (the `.eav`
  case, unchanged). The reformatter threads each file's `Files.tsv` `transcoder`
  id into the reformat pass, so any id-selected reversible transcoder is
  reformatter-ready, not just XML.

## [0.23.0] - 2026-06-04

### Added

- **`--strip-cog` reformatter flag.** Exposes the existing `exportParams.stripCog`
  option on the CLI: when exporting, COG doc templates have their scaffolding
  (markers + code lines) stripped, leaving only the generated output in the
  published copy. Default off (markers kept). Documented in
  [REFORMATTER.md](REFORMATTER.md) alongside `--cog-docs` (which was also added to
  that options table). The tutorial now demonstrates it on
  `tutorial/expansion/SkillTree.md`.

### Changed

- **Updated the tutorial.**

- **COG / cell-expression sandbox unified with the code-library sandbox.**
  `sandbox_env.cogGlobals()` — the `__index` surface backing cell expressions and
  COG scripts (`manifest_loader` `loadEnv`) — now returns exactly the same set as
  `sandbox_env.new()`, additionally exposing the pure TabuLua helper block
  (`predicates`, `stringUtils`, `tableUtils`, `equals`). Previously COG/cell
  expressions had `math` plus the curated `string`/`table` libraries (including
  `table.concat`) but not those helpers; now a COG doc block and any code library
  it calls see an identical safe API. The helpers are side-effect-free, so this
  widens convenience without weakening the sandbox. Test updated in
  `spec/sandbox_env_spec.lua`.

- **`--cog-docs` now errors when combined with export options.** `--cog-docs` is an
  in-place doc-refresh mode that exports nothing; previously pairing it with
  `--file=`, `--data=`, `--strip-cog`, `--clean`, `--collapse-exploded`, or
  `--export-dir=` silently ignored those flags and left the export dir empty. The
  reformatter CLI now reports the conflicting flags and exits non-zero instead of
  swallowing them.

### Fixed

- **Sink pipeline no longer crashes when a source-only stage matches
  (`content_pipeline.matchingStages`).** With `useSink=true` the dispatcher used the
  `useSink and sinkTransform or transform` idiom, which falls through to `transform`
  when a matched stage has no `sinkTransform` — so a decode stage (e.g. reversible
  gzip) got selected in the sink direction and `runSink` then called its nil
  `sinkTransform`. This surfaced when a `.tsv.gz` data file was present and a
  `--strip-cog` / `stripCog` export ran. Fixed to pick the direction's function
  explicitly; regression test in `spec/content_pipeline_spec.lua`.

## [0.22.0] - 2026-06-04

### Added

- **Reversible gzip data files (`data.tsv.gz`) — end-to-end load + reformat
  round-trip ([TODO/content_pipeline.md](TODO/content_pipeline.md) §3.6, Phase 4
  Part B).** Compressed TSV/CSV data files are now first-class: `.gz` is collected,
  and a file whose name peels (by the content pipeline's decode extensions) to a
  `.tsv`/`.csv` is decoded and parsed as data, while other `.gz` files stay on the
  stream/passthrough path. The reformatter no longer leaves such a source
  untouched — it reformats the **decoded** TSV and **re-compresses** it through the
  decode stage's new `encode` re-encoder (gzip is marked `reversible = true`),
  writing the bytes back in binary. It never clobbers the `.gz` with plaintext TSV.
  This builds directly on the pure-Lua gzip compressor below. New surface:
  `content_pipeline.peeledName` / `reversibleDecode` (name-only decode-extension
  peeling), a stage `encode` field, and `file_util.writeFileBinary` /
  `safeReplaceFileBinary`. Tests: `spec/content_pipeline_spec.lua` (+7) and
  `spec/gzip_reversible_integration_spec.lua` (+4, full load + reformat round-trip).

- **Pure-Lua gzip compression (`compression.compress("gzip", …)`).** The
  `gzip/compress` provider now ships, completing gzip in both directions with no
  new dependency and nothing for the user to install beyond Lua + luarocks. No
  native-free luarocks rock offers gzip *compression* (every one that does — lzlib,
  lua-zlib — binds C zlib), so this is built on the already-used pure-Lua
  `libdeflate` (which produces the raw DEFLATE body) plus a small in-module RFC 1952
  envelope writer: the fixed 10-byte header, and a **pure-Lua CRC32** + ISIZE
  trailer (libdeflate exposes only Adler-32, never the CRC-32 the gzip envelope
  requires). Accepts `opts.level` (1..9). The output round-trips through the
  existing gunzip provider and is verified standards-compliant against a real gzip
  decoder (.NET `GZipStream`, which checks the CRC32). The CRC32 lookup table is
  built lazily on first use, so merely requiring the module — or only ever
  decompressing — costs nothing. Tests in `spec/compression_spec.lua` (+8).

- **COG support for `.xml` and `.xhtml` templates.** `.xml` and `.xhtml` are now
  COG-scan-eligible extensions, so XML-family files can carry COG blocks (via the
  shared HTML-comment marker style `<!---[[[ … ]]]--->`) and be discovered /
  generated / refreshed like Markdown and HTML. Because XML (and therefore XHTML)
  forbids `--` inside a comment, `lua_cog.processContentBV` now reports an
  **error** (with the line number) when an HTML-style COG code line in an
  `.xml`/`.xhtml` file contains `--`, alerting the author at processing time
  instead of when an XML parser later rejects the file.

- **In-place COG doc refresh (`--cog-docs`) —
  [TODO/cog_markdown.md](TODO/cog_markdown.md) Part 2.4.** A new reformatter mode
  that loads the data, discovers COG doc templates, and rewrites each one **in
  place** with its generated region refreshed — markers KEPT so it stays
  re-runnable. This is the classic `cog` use for keeping a committed `README.md`
  current with the data, suitable for a build/CI step; it is independent of
  reformat/export and writes nothing to the export dir. Exposed as
  `reformatter.refreshDocs(directories)` and the `--cog-docs` CLI flag.
  Idempotent.

- **Data-driven doc generation —
  [TODO/content_pipeline.md](TODO/content_pipeline.md) §3.10,
  [TODO/cog_markdown.md](TODO/cog_markdown.md) Part 2.** At export time, COG doc
  templates (any scan-eligible text file containing a COG block, discovered by
  `cog_discovery`) are expanded against the fully-loaded dataset and written to
  the export dir, mirroring source layout — optionally with `stripCog` for a
  clean published file. A template's COG block reads data through `files`, keyed
  by **both** typeName (`files["Item"]`) and filename (`files["Item.tsv"]`).
  Templates are generated, never copied verbatim: the per-format exporters skip
  them, and a shared read cache (`file_util.newReadCache`) means each template is
  read once across discovery and expansion. New `doc_generator` module; the
  `reformatter` export flow drives it after the per-format exporters.

- **COG-comment stripping on export (`stripCog`) —
  [TODO/content_pipeline.md](TODO/content_pipeline.md) Phase 5, §3.9.** A new
  `lua_cog.stripCog` removes the COG scaffolding (start/code/code-end/output-end
  markers and the code lines) from content while keeping the generated output
  inline — across all four comment styles, lossy and idempotent. It is wired as
  the COG macro stage's `sinkTransform`, and the exporter gains an opt-in
  `exportParams.stripCog` (default off) that routes raw-passthrough text through
  the content pipeline's sink direction before writing, so a published copy can
  be free of COG markers without touching the source.

- **User-registered content-pipeline stages —
  [TODO/content_pipeline.md](TODO/content_pipeline.md) Phase 4.** A package
  `bootstrap` function can now register custom content-pipeline stages (e.g. a
  transcoder) via `api.registerContentStage(moduleName, stageSpec)`, alongside
  the existing type-wiring `register`/`registerModule`. The api is sealed after
  the bootstrap phase (a captured handle used later errors), and
  bootstrap-registered stages are cleared on `global_reset`, mirroring the
  type-wiring bootstrap surface. This lets a package ship, say, its own
  `transcoder=mypkg:format` selected from `Files.tsv`.

- **COG template discovery —
  [TODO/cog_markdown.md](TODO/cog_markdown.md) Part 2.** Non-data text files
  (`.md`, `.markdown`, `.html`, `.txt`) can carry COG blocks; the new
  `cog_discovery` module auto-scans the package roots for such files and keeps
  only those that actually contain a COG block (`lua_cog.needsCog`), so a doc
  template "just works" with no per-file registration. The eligible-extension
  set lives in the content-pipeline registry
  (`content_pipeline.registerScanExtensions` / `isScanEligible`) — adding a
  format later is a one-line change — and `.tsv`/`.csv` are deliberately
  excluded so data files are never double-processed. A `.cogignore` marker file
  opts a directory subtree out. This is the discovery half; generating docs from
  the templates lands with the exporter sink driver in a later phase.

- **Content pipeline `transcode` phase + JSON data files —
  [TODO/content_pipeline.md](TODO/content_pipeline.md) Phase 3.** A non-TSV
  data file can now be converted to TSV and parsed as data by naming a
  transcoder in a new optional `Files.tsv` column, `transcoder`. Three JSON
  layouts ship — `json:objects` (array of objects, one per row), `json:rows`
  (array of arrays, one per row, positional), and `json:columns` (array of
  arrays, one per column, the transpose) — all taking column **names, types and
  order from the file's `typeName` schema** (not inferred), so the existing
  type/validation machinery applies unchanged. Selection is explicit per file — transcoders register with an
  `id` and never fire by extension — because a format like JSON has several
  tabular layouts. A file with no `transcoder` keeps today's passthrough-asset
  behaviour. The reformatter now rewrites only `.tsv`/`.csv` sources, so a
  transcoded (or gzip-decoded) file is never clobbered with its derived TSV.
  Further formats (e.g. XML) can be added as more `id`-selected transcoders.

### Changed

- **Registry-driven descriptor-column map lifecycle —
  [TODO/descriptor_map_lifecycle.md](TODO/descriptor_map_lifecycle.md).**
  Finished the type-wiring generalization for optional `Files.tsv` columns: the
  registry already drove column recognition, parsing, and storing, but each
  `lcFn2*` backing map was still allocated, threaded, and re-assembled into
  `joinMeta` by hardcoded name in `files_desc.lua` and `manifest_loader.lua`.
  The map *lifecycle* is now registry-driven too. `loadDescriptorFiles` takes a
  single `metaMaps` table (replacing ~11 per-column positional params) and
  auto-creates one empty map per registered `fieldOnMeta` from
  `descriptorColumnsByName()`; `joinMeta` is assembled from `metaMaps` plus the
  core/derived entries instead of a hand-written field list. The export-only
  columns no core module reads (`edgesFor`, `joinColumn`, `export`,
  `joinedTypeName`) now appear **nowhere** in the two loader modules — the
  litmus test holds: a feature module that declares a column and consumes it via
  its own `joinMeta` key (graphs being the motivating example) needs **zero**
  core edits. Maps still consumed inside core (`lcFn2Ctx`/`lcFn2Col`,
  validators/processors, `lcFn2Transcoder`) keep local aliases pulled from
  `metaMaps` but are no longer allocated or assembled by hand. No behaviour
  change; `joinMeta` gains the previously-absent `lcFn2Ctx`/`lcFn2Col`/
  `lcFn2Variant` keys as a harmless side effect. **Breaking (internal API):**
  `files_desc.loadDescriptorFiles` has a new signature — the only in-tree
  callers are `manifest_loader` and the `files_desc` specs. Tests:
  `spec/files_desc_spec.lua` and `spec/files_desc_ablation_spec.lua` updated to
  the `metaMaps` shape (full suite green).

- **PK-lookup audit — [TODO/pk_lookup_audit.md](TODO/pk_lookup_audit.md).**
  Eliminated redundant row scans in code paths that had a PK-indexed
  parsed dataset (or wrapped row array) available but were still
  rebuilding name→row maps locally. Three focused fixes:
  - `manifest_loader.extractDataRows` now mirrors the dataset's
    column-1 PK index onto the returned array, so file validators,
    file pre-processors, and package validators inherit an
    `rows[pkValue]` O(1) lookup without per-call rebuilds.
  - `validator_helpers.lookup` gains a one-probe PK fast-path: when
    `column` is the PK column of a PK-indexed array, it short-circuits
    to `rows[tostring(value)]`; non-PK columns and plain-array test
    fixtures fall through to the existing linear scan.
  - `tsv_diff.comparePKBased` gets a comment explaining why it
    *must* build its own `pk2Map` (raw-TSV input with normalised PK
    keys — no native index to reuse).
  No behaviour change for consumers. Documented the wrapper-PK
  contract on `manifest_loader`, `validator_executor`,
  `processor_executor`, and `validator_helpers` in
  [MODULES.md](MODULES.md) to prevent regression.

## [0.21.0] - 2026-05-26

### Added

- **Type-wiring registry — Phases 3a and 3b of [TODO/type_wiring.md](TODO/type_wiring.md).**
  User packages can now reach the type-wiring registry through two
  complementary paths.

  **3a — `bootstrap` manifest field (code library path).** A new
  optional list of `{library, fn}` pairs on the manifest. After all
  packages' `code_libraries` are loaded but before any descriptor file
  is parsed, each entry's `fn(api)` is invoked in package-dependency
  order. The `api` table proxies `register` / `registerModule` onto
  the registry; a `seal()` closure (called by the engine after the
  bootstrap phase ends) flips a shared `sealed` flag, so any later
  call — including one through a proxy a bootstrap stashed into
  library state — errors at the call site. Use this to register
  `descriptorColumns`, `sandboxHelpers`, `enginePostPasses`, or
  Lua-valued `onLoad` callbacks (the slot the `TypeWiring.tsv` path
  can't reach).

  **3b — `type_wiring_def` built-in record type (pure-data path).**
  A new built-in alias `type_wiring_def` describes a row's wiring
  shape: `{typeName:name, preProcessors:{processor_spec}|nil,
  rowValidators:{validator_spec}|nil, fileValidators:{validator_spec}|nil}`.
  Any file declaring `typeName=type_wiring_def` (or any user type that
  extends it) has its rows dispatched as `type_wiring.register(...)`
  calls by the standard `onLoad` cascade — no hard-coded filename
  detection. Authors can name such files anything they like
  (`TypeWiring.tsv` by convention); the engine recognises them by
  record type, the same way it recognises Type files, enum files,
  and custom_type_def files. Unknown typeNames register harmlessly:
  the cascade dispatcher only fires the contributions when a file's
  extends chain reaches a registered name. One new `manifest_info`
  helper (`runPackageBootstraps`) drives the 3a side; the 3b side
  reuses the existing onLoad pipeline (no new files_desc helpers
  needed).

- **Type-wiring registry — Phases 2a and 2b of [TODO/type_wiring.md](TODO/type_wiring.md).**
  Phase 1 introduced the registry's `onLoad` slot; Phase 2 grows it into
  the full per-typeName cascade (per-type `preProcessors` / `rowValidators`
  / `fileValidators` with per-entry `position` override and
  expression-string idempotency) plus a new `registerModule` API for
  module-level engine-init slots (`descriptorColumns`, `sandboxHelpers`,
  `enginePostPasses`). Public accessors are `runEnginePostPasses`,
  `sandboxAdditions`, `descriptorColumns` / `descriptorColumnsByName`.
  The graph-types auto-wiring previously implemented as hand-written
  helpers in `graph_wiring.lua` now flows through these slots; user
  behaviour is unchanged.
- **Type-wiring registry (Phase 1 of [TODO/type_wiring.md](TODO/type_wiring.md)).**
  New [type_wiring](type_wiring.lua) module exposes a small registry that
  attaches behaviour to a file by walking its `extends` chain. Phase 1
  supports a single contribution slot — `onLoad(file, fileType, extends,
  badVal, loadEnv)` — fired from the per-file load loop *before*
  subsequent files parse, so registered parsers/aliases/types are
  visible to siblings in the same package. The companion
  [builtin_wiring](builtin_wiring.lua) module registers the three
  built-in handlers (`Type` → alias registration, `enum` → enum parser
  registration, `custom_type_def` → custom-type spec registration);
  these handlers moved out of `manifest_loader.lua` essentially
  unchanged. No user-visible behaviour change — the refactor collapses
  three hand-written `if isType / isEnum / isCustomTypeDef` branches
  and four near-identical ancestor walkers into one dispatch loop.
  Later phases will add `preProcessors` / `rowValidators` /
  `fileValidators` per-typeName slots and a separate `registerModule`
  API for engine-init slots (descriptor columns, sandbox helpers,
  engine post-passes); see TODO/type_wiring.md for the full plan.

### Changed

- **`Files.tsv` core schema shrunk to six intrinsic columns.**
  `files_desc.lua` now hard-codes only `fileName`, `typeName`,
  `superType`, `baseType`, `loadOrder`, and `description`. The other
  ten columns — `publishContext`, `publishColumn`, `joinInto`,
  `joinColumn`, `export`, `joinedTypeName`, `variant`, `rowValidators`,
  `fileValidators`, `preProcessors`, `edgesFor` — are re-introduced
  by feature-module `registerModule(...)` calls in `builtin_wiring.lua`
  at engine init. Header recognition, `joinMeta` field names, parse
  semantics, and behaviour are unchanged; only the wiring path is
  different.
- **Sandbox helper merging via the type-wiring registry.**
  `processor_executor` and `validator_executor` merge the union of
  registry-contributed `sandboxHelpers` into their helper blocks at
  engine init. Name collisions with built-in helpers are a
  registration-time error.
- **Graph wiring flows through the registry.**
  `applyGraphAutoWiring` and `validateGraphEdgeFiles` are no longer
  called directly from `manifest_loader`. Per-typeName completion +
  validators for `basic_graph_node` / `graph_node` / `tree_node` are
  registered in `builtin_wiring.lua`; the edge-consistency check is
  an `enginePostPasses` callback there too. `completeBasicGraph` /
  `completeDirectedGraph` (processor side) and `graphRefsExist` /
  `graphAcyclic` / `graphTreeShape` (validator side) flow into the
  sandbox envs through the registry's `sandboxAdditions()`.
- `files_desc.detectPostProcessingNeeded` now consults
  `type_wiring.hasOnLoad` instead of a hard-coded
  `POST_PROCESS_PARENTS = {Type=true, enum=true}` table, so any
  future built-in (or user-package) that registers an `onLoad`
  automatically triggers the descriptor-file reprocessing pass
  without a parallel edit to `files_desc.lua`.

### Removed

- **`graph_wiring.applyAutoWiring` and `graph_wiring.validateEdgeFiles`
  are no longer in the public API.** The dispatch entry points are
  replaced by registry registrations in `builtin_wiring.lua`; what
  remains in `graph_wiring.lua` are the leaf detection helpers
  (`detectFamily`, `detectRole`, `detectEdgeFamily`). Direct callers
  (none outside the engine + tests) should reach the same behaviour
  through `manifest_loader.processFiles`. The associated tests in
  `spec/graph_wiring_spec.lua` were removed; equivalent end-to-end
  coverage lives in `spec/graph_wiring_integration_spec.lua`.
- `manifest_loader.lua` no longer defines `registerEnumParser`,
  `registerAliases`, `registerCustomTypesFromFile`, `isType`, `isEnum`,
  `isCustomTypeDef`, `findAllTypes`, or `buildCustomTypesSet`. The
  three onLoad handlers live in [builtin_wiring](builtin_wiring.lua);
  the four ancestor walkers are subsumed by the single cascade walk
  in [type_wiring](type_wiring.lua). The `typesSet` / `enumsSet` /
  `customTypesSet` locals previously precomputed in
  `processOrderedFiles` are gone — each onLoad handler checks its
  own applicability via the registry's ancestor walk.

### Fixed

### Migration guide (Type-Wiring Registry refactor)

**Required changes for existing data projects: none.** This release is
an internal refactor of how the engine attaches behaviour to file
types. Existing `Manifest.transposed.tsv`, `Files.tsv`, and data files
continue to load and behave identically.

**What changed internally:**

- Ten previously hard-coded optional columns in `Files.tsv`
  (`publishContext`, `publishColumn`, `joinInto`, `joinColumn`,
  `export`, `joinedTypeName`, `variant`, `rowValidators`,
  `fileValidators`, `preProcessors`, `edgesFor`) are now registered
  by feature modules at engine init rather than enumerated in
  `files_desc.lua`. All ten continue to be recognised in any
  `Files.tsv`; their semantics, types, and behaviour are unchanged.
- The six intrinsic columns (`fileName`, `typeName`, `superType`,
  `baseType`, `loadOrder`, `description`) remain hard-coded core.
- The graph-types auto-wiring previously implemented as hand-written
  helpers in `graph_wiring.lua` now flows through the registry;
  user-visible behaviour is unchanged. `graph_wiring.applyAutoWiring`
  and `graph_wiring.validateEdgeFiles` are no longer in the public
  API.

**New opt-in surfaces (you can ignore these unless you want them):**

- **`type_wiring_def` built-in record type.** Any file declaring
  `typeName=type_wiring_def` (or extending it) is treated as a
  "wiring file" — each row becomes a registration. Lets a package
  attach `preProcessors` / `rowValidators` / `fileValidators` to
  arbitrary typeNames without any Lua. Convention is to call such
  files `TypeWiring.tsv` but the engine recognises them by record
  type, not by basename. See `DATA_FORMAT_README.md` § *Type Wiring*.
- **`bootstrap` field in the manifest**. A new optional list of
  `{fn, library}` pairs that run once at engine init with an `api`
  argument exposing `register` and `registerModule`. Use this when
  shipping a code library that needs to add engine-extending
  behaviour (custom `Files.tsv` columns, sandbox helpers for use in
  expressions, cross-file validators). The api is sealed after the
  bootstrap phase ends — captured handles can't outlive the phase.

**If you maintain engine-side Lua that reaches into `joinMeta`:**
every existing field (`lcFn2JoinInto`, `lcFn2EdgesFor`,
`lcFn2RowValidators`, …) continues to exist with the same shape and
contents — only the population path has moved, not the data layout.

**If you import `graph_wiring` directly from a code library:**
`graph_wiring.detectFamily`, `detectRole`, and `detectEdgeFamily`
remain exported (leaf detection helpers). The dispatch entry points
(`applyAutoWiring`, `validateEdgeFiles`) are gone — the engine reaches
them through the registry now, and direct callers should do the same
via `type_wiring.applyWiring` / `type_wiring.runEnginePostPasses`.

## [0.20.0] - 2026-05-24

### Added

- **Graph Types.** Three built-in record-type families for graph-shaped
  data: `basic_graph_node` (undirected, `graphLinks` field), `graph_node`
  (DAG, `graphParents`/`graphChildren`), and `tree_node` (DAG plus
  single-parent / single-root invariants). Authors opt in by declaring
  `superType=<one of the three>` in `Files.tsv` (same discovery
  mechanism as `enum` and `custom_type_def`). The engine auto-wires
  every graph file with:
  - a **completion pre-processor** that symmetrises the link fields
    (author writes `graphParents`; engine fills in `graphChildren`),
    running at priority 50 with `rerunAfterPatches=true`;
  - **refs-exist validation** (every name in a link field must reference
    a row in the file);
  - **acyclic validation** for `graph_node` and `tree_node` (cycle path
    returned for diagnostics);
  - **tree-shape validation** for `tree_node` (≤1 parent per node,
    exactly one root post-completion).

  Family detection keys off the literal `superType=` string in
  `Files.tsv` and walks the `extends` chain transitively, so a user
  type `Quest extends graph_node` propagates the wiring to downstream
  files that use `superType=Quest`. New built-in PK types
  `composable_name` (a `name` that forbids the `__` substring and also
  forbids leading or trailing `_` — all three rules keep any compound
  `<a>__<b>` encoding lossless; `node_name` is a backwards-compatible
  alias of `composable_name` used by the graph-node families),
  `undirected_edge_key` and `directed_edge_key` (compound `<a>__<b>`
  keys with both halves validated as `composable_name`s; undirected
  sorts canonically and warns on reorder). Implemented as new
  [graph_helpers](graph_helpers.lua) and
  [graph_wiring](graph_wiring.lua) modules. See
  [DATA_FORMAT_README §Graph Types](DATA_FORMAT_README.md#graph-types)
  for the user-facing description and the tutorial `SkillTree.tsv` /
  `SkillEdges.tsv` for an end-to-end example.

- **Edge files (`edgesFor`).** Optional per-row column in `Files.tsv`
  that points an edge file at its node file. Edge files carry per-edge
  data (weights, gating conditions, descriptions) without forcing
  authors to duplicate the data on both endpoints. Three parallel
  built-in record types — `basic_graph_edge`, `graph_edge`,
  `tree_edge` — give the edge side the same family discovery as the
  node side. The engine enforces: at most one edge file per node
  file; family match (basic↔basic, directed↔directed); every endpoint
  exists as a row in the node file; every edge corresponds to a
  declared link (checked after completion). The `comment:comment|nil`
  column is included in the edge types both to force the spec to parse
  as a record (single-field `{key:val}` would parse as a map) and to
  give every edge file a free description column.

- **`graph_helpers` module.** Shared graph-data primitives — accessors
  (`isRoot`, `isLeaf`, `parentsOf`, `childrenOf`, `neighboursOf`),
  edge-key codec (`splitEdgeKey`, `makeEdgeKey`,
  `makeUndirectedEdgeKey`, `edgeForLink`), cycle detection
  (`findCycle`), traversal (`bfs`, `dfs`, `ancestorsOf`,
  `descendantsOf`, `shortestPath` — all cycle-safe via a visited-set
  guard), and the three structural validators (`graphRefsExist`,
  `graphAcyclic`, `graphTreeShape`). The validators are injected into
  the validator sandbox env so user expressions can call them too.

- **`graph_wiring` module.** Detects graph-family files via Files.tsv
  superType and auto-attaches the completion pre-processor and
  structural validators. Also runs the post-load edge↔node
  consistency check for `edgesFor`-attached edge files.

- **Tutorial: `SkillTree.tsv` + `SkillEdges.tsv`.** New
  `tutorial/expansion/` files demonstrating the `graph_node` and
  `graph_edge` families. A small skill DAG with multi-parent skills
  (`tracking` from perception+stealth; `huntersMark` from
  perception+dexterity) and edge data (`requiredLevel` per
  prerequisite). See
  [tutorial/README.md §SkillTree.tsv + SkillEdges.tsv](tutorial/README.md)
  for the walkthrough.

### Fixed

- **Schema export of `{extends:X, field:type}` aliases.** Earlier drafts
  of `tree_node` and `tree_edge` used the redeclaration form
  `{extends:graph_node, name:node_name}`. The alias resolved to the same
  canonical parser as the parent (no behavioural difference), but
  `parsers.schema_export` serialised the spec as `{extends,X,field:type}`
  — a mixed comma/colon form that the type parser can't round-trip,
  breaking JSON / SQL / Lua exports of any package containing a graph
  file. `tree_node` and `tree_edge` are now plain aliases of
  `graph_node` / `graph_edge`; family distinction lives entirely in the
  `Files.tsv superType` string, where the engine was already keying off
  it for auto-wiring.

## [0.19.0] - 2026-05-22

### Added

- **`parsers.isNullable(type_spec)`.** New introspection helper that returns
  `true` if values of `type_spec` may be `nil` (the literal `"nil"` type, or
  a union — directly or via alias — that includes `nil`). Avoids the
  foot-gun of substring-matching `|nil`, which misses bare `"nil"` and
  named aliases like `super_type`.

- **Pre-Processors.** `Files.tsv` now supports an optional `preProcessors:{processor_spec}|nil`
  column. Pre-processors are sandboxed Lua expressions that mutate parsed rows
  **after** parsing and **before** any validator runs. They fill the gap between
  per-row `=expr` (read one row only) and file validators (read whole file but
  cannot write). The sandbox exposes the validator's read helpers plus
  `setCell`, `clearCell`, `rowByKey`, and `dataIndex` for mutation. Within a
  file, processors run in ascending `priority` order (default `100`); a later
  processor sees earlier processors' writes. Quota is 50,000 ops/file. The
  reformatter preserves the original raw cells on round-trip — processor
  mutations stay in-memory only. Implemented as a new
  [processor_executor](processor_executor.lua) module and wired through
  `manifest_loader.processFiles`. New built-in type alias `processor_spec`
  mirrors `validator_spec` and adds `priority`/`rerunAfterPatches` fields.
  See [DATA_FORMAT_README §Pre-Processors](DATA_FORMAT_README.md#pre-processors)
  for the user-facing description and the tutorial Quest.tsv for an
  inverse-relation example.

- **`sandbox_env` module.** The single owner of the sandbox "safe API
  surface". `sandbox_env.new(extras)` builds a *fresh* environment table —
  safe builtins, `math`, curated `string`/`table` subsets, the
  `predicates`/`stringUtils`/`tableUtils`/`equals` helper block, plus any
  per-call `extras`; `sandbox_env.cogGlobals()` builds the same set minus the
  helper block, for cell expressions and COG scripts. This replaces five
  hand-rolled, silently-drifted environment tables in `validator_executor`,
  `processor_executor`, `manifest_info` (code libraries),
  `parsers/registration` (custom-type `validate` expressions), and
  `data_set.transformCells`, so the safe set is now defined exactly once.

- **`table_utils.deepCopyUnwrapped(value)`.** Deep-copies a value into a
  fully-mutable tree, unwrapping any read-only proxies it encounters along
  the way (shared and cyclic references preserved). Backs the new processor
  `copy` helper.

- **Processor `copy` helper.** Pre-processor sandboxes now expose
  `copy(value)`, returning a fresh, fully-mutable deep clone of a read-only
  value so a changed collection can be built and installed via `setCell`.

### Changed

- `manifest_loader.processFiles()` result field `validationPassed` now also
  reflects pre-processor success: it is `true` iff every error-level
  pre-processor **and** every error-level validator succeeded. (Previously
  pre-processor errors incremented `badVal.errors` but were not folded into
  `validationPassed`.) The companion `validationWarnings` array now also
  includes pre-processor warnings.

- **Pre-processor cell reads are now read-only.** A processor reading
  `row.col` receives the parsed value READ-ONLY, exactly like a validator —
  `wrapRowForProcessor` no longer hands out the unwrapped, mutable parsed
  table. In-place mutation of a collection-valued cell
  (`table.insert(row.unlocks, x)`) now raises `attempt to update a read-only
  table`. To change a collection, deep-copy it with the new `copy` helper,
  mutate the copy, then install it via `setCell` — which re-parses and
  type-validates the new value. This closes a hole where a processor could
  change parsed data *outside* the single audited `setCell` write path,
  skipping the column's type re-validation. **Breaking** for processors that
  relied on in-place mutation; the tutorial `Quest.tsv` inverse-relation
  processor has been rewritten to the `copy` + `setCell` form. See
  [DATA_FORMAT_README §Pre-Processors](DATA_FORMAT_README.md#pre-processors).

### Fixed

- **Cell expressions and COG scripts can no longer escape the sandbox.**
  `manifest_loader`'s `loadEnv` chained, via `{__index = _G}`, all the way to
  the real global table — exposing `require`, `debug`, `io`, the dangerous
  `os.*` members, `rawget`/`rawset`, `set`/`getmetatable`, `load`, `dofile`,
  and `collectgarbage` to **any** cell expression (`=…`) or COG block in an
  ordinary `.tsv` file. `require` alone was a full escape (it reaches every
  module, including `io`/`os`), and it also re-opened the documented
  read-only `unwrap` bypass. `loadEnv` now falls through only to the curated
  `sandbox_env.cogGlobals()` set, so those names resolve to `nil`. The curated
  `table` subset includes `concat` (which the stock sandbox `BASE_ENV` omits)
  so existing COG scripts keep working.

- **`read_only` no longer leaks the original table through `next()`.** Previously
  each proxy stored its underlying table at a private `ROP_t` key inside the
  proxy itself, so a caller holding a proxy could write `local _, t = next(ro)`
  and obtain — and then mutate — the original. The proxy → original mapping
  has been moved into a module-private weak-keyed map outside the proxy; the
  proxy itself is now empty, so `next(proxy)` returns `nil` and the bypass is
  closed. Public API (`readOnly`, `readOnlyTuple`, `unwrap`) is unchanged.
  Two existing call sites that relied on `next()` returning the old sentinel
  pair as a truthy emptiness check on a proxy were updated to unwrap first:
  five `next(manifest.X)` checks in [manifest_info.lua](manifest_info.lua) and
  one `next(header.__exploded_map)` in [exporter.lua](exporter.lua).

## [0.18.0] - 2026-05-17

### Added

- New `moveCellsMatching` migration command (and corresponding `DataSet:moveCellsMatching`
  method) that moves cell values from a source column to a destination column on rows
  where the source value matches a Lua pattern. Matched source cells are cleared after
  the value is copied; empty cells are skipped. Useful for splitting an existing column
  into new columns added by an earlier migration step.

- New `tsv_diff` module and CLI tool for comparing two TSV files at the data level.
  Supports order-based (positional) and primary-key-based comparison modes. Features
  include column mapping (`--map=OLD/NEW`) for renamed columns, whitespace trimming
  (`--trim`), case-insensitive comparison (`--ignore-case`), floating-point numeric
  tolerance (`--epsilon=N`), column filtering (`--only`/`--exclude`), context lines
  (`--context=N`), and output limiting (`--max-diffs=N`). Comments and blank lines are
  ignored. Column order is not compared (except column 1 is always the primary key).
  Only common columns are compared, so adding or removing a column does not cause every
  row to appear different. Works at the raw level (no type parsing). CLI entry point:
  `lua54 tsv_diff.lua <file1.tsv> <file2.tsv> [options]`. Exit codes: 0 = identical,
  1 = differences found, 2 = error. See [TSV_DIFF.md](TSV_DIFF.md) for full documentation.

- New `ollama_batch` module and CLI tool for batch-processing TSV rows through a
  local Ollama LLM. Configured via a TSV key/value file specifying input/output files,
  columns to send to the model, columns the model generates, system prompt (with
  `{REFERENCE:file}` placeholder support), and optional Lua transformation hooks
  (`prepare_input`, `process_output`). Sends rows in batches as JSON arrays, parses
  JSON array responses, and merges generated columns into the output file. Progress is
  tracked in a TSV file (human-readable) for checkpoint/resume. Supports `--resume`,
  `--status`, `--dry-run`, `--model=MODEL`, `--batch-size=N`, `--timeout=N`, and
  `--log-level=LEVEL` options. Reference TSV/TXT files can be loaded and passed to
  both the prompt template and user code. CLI entry point:
  `lua54 ollama_batch.lua <config.tsv> <baseDir> [options]`.

## [0.17.0] - 2026-03-19

### Added

- **Variant-based conditional file inclusion.** `Files.tsv` now supports an optional
  `variant:name|nil` column. Rows with a non-empty variant value are only active
  when that variant is explicitly passed to `processFiles()`. This enables listing
  all localization (or platform, debug/release, etc.) variants in a single
  `Files.tsv` and selecting which to load at processing time — no more editing
  `Files.tsv` per export. Files with inactive variants are fully skipped: not loaded,
  not exported, and not validated for joins.
- **Variant group validation in Manifest.** A new optional `variant_groups` field
  in `Manifest.transposed.tsv` declares groups of mutually exclusive variant names
  with an optional default (e.g., `{"lang",{"en","fr","de"},"en"}`). When variants
  are provided, the system validates that exactly one value from each declared group
  is selected. If no variant from a group is selected and a default is declared, the
  default is applied automatically. Variant names must be unique across groups within
  a package. Validation is per-package.
- New `global_reset` module: a central registry for resetting module-level mutable
  state (caches, registries, etc.) back to its original post-load condition. Modules
  call `register(fn)` during initialization; calling `reset()` invokes all registered
  functions. Has no project dependencies.
- **Multiple inheritance for record types.** A record's `extends` field now accepts
  a tuple of parent type names (e.g., `{extends:{ParentA,ParentB},field:type}`),
  merging fields from all parents into the child type. Field conflict resolution:
  identical types are allowed; compatible types are narrowed to the more specific
  type; incompatible types produce an error. Self-ref fields must be identical
  across parents. Duplicate parents, non-record parents, and inline record specs
  in the parent tuple are rejected. Bare multi-extends (`{extends:{A,B}}` without
  additional child fields) creates a merged record. Diamond inheritance is handled
  naturally. `extendsOrRestrict` recognizes multi-extends children as extending
  each parent individually.
- **Inherited column defaults.** When a child file extends a parent file, columns
  that have no default value now automatically inherit the parent's default. This
  avoids having to re-declare `name:type:default` in every child file when the
  parent already specifies the default. Child-defined defaults always take
  precedence. Transitive inheritance (grandparent → parent → child) is supported.
- New core type `filepath`: an ASCII string validated by `isPath()` from
  `predicates.lua`. Each `/`-separated component must be a valid file name
  (no `<>:"|?*`, no Windows reserved names, no triple dots or trailing
  periods/spaces).

### Changed

- **Breaking:** The `fileName` column in `Files.tsv` changed from `string` to
  `filepath`; the `joinInto` column changed from `name|nil` to `filepath|nil`.
  The `joinInto` column now requires the full relative path (e.g.,
  `Resource/Bulk/Substance/Liquid.tsv`) instead of a basename (`Liquid.tsv`).
  This eliminates ambiguity when multiple files share the same basename.

### Fixed

- Increased sandbox quota for lua COG scripts.
- **Short rows with defaults no longer fail to parse.** When a data row has fewer
  columns than the header, but every missing column either has its own `default_expr`
  or inherits one from a parent file, the row is now accepted: the missing values are
  filled with the defaults and a WARNING is logged instead of an ERROR. The cascading
  parse failures that previously resulted from a short row in a parent file (causing
  dependent child files to fail too) no longer occur. Rows that are still missing a
  column with no default continue to report an ERROR as before.
- Fixed `shouldExport` check in `exportTSV` using the wrong key format. The
  lookup key was stripped to the bare filename (e.g., `"food.en.tsv"`), but the
  `lcFn2JoinInto` map in `files_desc.lua` stores the full relative path (e.g.,
  `"resource/bulk/food.en.tsv"`). This caused secondary (joined-into) files to
  never be recognized and always be exported. Now uses `computeRelativePath` with
  normalized path separators to produce the correct key.
- Added missing `shouldExport` check to `exportMessagePack`. Previously,
  secondary files were always exported in MessagePack format regardless of their
  join status.
- Fixed broken error messages in `validateFileJoins` (`files_desc.lua`). Line
  number was always 0, source file was always the last-processed file (e.g.,
  "Shape.en.tsv"), and stale column metadata from previous processing leaked
  into the message. Now correctly reports the descriptor file name, actual line
  number, and "joinInto" as the column name.
- Fixed `computeRelativePath` in the exporter corrupting file paths when the
  source directory is `"."`. The `sub(#dir + 2)` prefix-stripping logic would
  strip the first two characters of every file path (e.g., `"Resource/Bulk/…"`
  became `"source/Bulk/…"`). Added a special case: when the directory is `"."`,
  file paths are already relative and are returned as-is.

## [0.16.0] - 2026-03-08

### Added

- New `--no-unquoted-warn` option in the reformatter CLI to suppress the
  "Assuming ... is a single unquoted string" informational warnings. Useful when
  TSV data intentionally contains unquoted string values in array columns.

### Changed

- Updated `INTERNAL_MODEL.md`: added dataset `__preamble` field (v0.12.0),
  `loadEnv.files` publishing in processing pipeline (v0.12.0), custom type
  definition file processing steps (v0.10.0/v0.14.0), and `tags` field in
  custom type definition records (v0.15.0).
- Updated `USER_DATA_VIEW.md`: added `files.TypeName` to COG script variables
  (v0.12.0), and added missing `longestMatchingPrefix` and
  `sortCaseInsensitive` to `tableUtils` sandbox built-ins listing.
- Updated `MODULES.md`: added `data_set` and `migration` modules (v0.13.0).
- Reduced log level to DEBUG for noisy messages on non-essential files:
  "No priority found for" and "Don't know how to process" for `.md` files,
  and "Skipping hidden entry" for hidden directory entries.

### Fixed

- The "Assuming ... is a single unquoted string" and "Value ... is wrapped in {}"
  warnings now include the source file name and line number (e.g.,
  `myfile.tsv on line 42: Assuming foo is a single unquoted string`). Previously,
  these warnings used `state.logger:warn()` without any location context, making
  them hard to track down when they appeared many times in the same file.
- Fixed missing location info when array parsers were called from within union
  type trial parsing. The union parser uses a silent `nullBadVal` for trial
  parsing, which had empty `source_name` and `line_no = 0`. The location fields
  are now copied from the real `badVal` before the trial loop.

- The reformatter (and export tester) now excludes the export directory from file
  collection. Previously, when the data directory contained an `exported/`
  subdirectory from a prior export run, the recursive file scan would descend
  into it and produce spurious "No priority found" and "Don't know how to
  process" warnings for every exported file. `file_util.getFilesAndDirs` and
  `collectFiles` now accept an optional `excludeDirs` set of directory paths to
  skip entirely (no recursion).
- Type tag names and type names now properly detect collisions in both
  directions. Previously, registering a type tag after a type with the same name
  would silently overwrite the type's parser. Both directions now produce a clear
  error message explaining that type names and type tag names share a single
  namespace and cannot collide.
- Fixed grammar in parser name collision error message ("is already exists" →
  "is already in use").

## [0.15.0] - 2026-03-07

### Added

- New migration commands `copyColumn`, `copyRow`, and `splitFile` for duplicating
  columns, rows, and files within the migration tool.
  - `copyColumn`: duplicates a column with all its data under a new name, with
    optional position parameter.
  - `copyRow`: duplicates a row under a new primary key.
  - `splitFile`: copies a file with optional column filtering — can keep a subset
    of columns in the source and/or target, enabling file splitting. Warns if the
    primary key column is missing from either file.
- Corresponding DataSet API methods: `copyColumn()`, `copyRow()`, `splitFile()`.
- New `tags` field in `custom_type_def` for assigning a type to one or more
  existing type tags. Accepts a single tag name (`name`) or a list of tag names
  (`{name}`). This is the reverse of `members` — instead of listing members when
  defining a tag, you specify which tags a type belongs to when defining the type.
  Especially useful in files extending `custom_type_def`, where a `tags` column
  lets each row declare its tag membership.

### Changed

- To make declaring type tags without members easier, use "true" for the `members` field.

### Fixed

- Fixed line numbers in registerCustomTypesFromFile() error messages
- Fixed `restrictWithExpression` silently overwriting existing type definitions
  instead of detecting duplicates. Expression-validated types now properly allow
  identical re-registration and reject conflicting re-registration (different
  parent or expression), consistent with all other constraint types.
- Fixed crash when the same unknown map key type (e.g., `{extend:float}` instead
  of `{extends:float}`) appeared in multiple type definitions. The type parser's
  `UNKNOWN_TYPES` early-return was missing the second return value, causing
  `isNeverTable()` to receive nil and crash in the LPEG matcher.

## [0.14.0] - 2026-03-01

### Added

- New `--no-number-warn` option in the reformatter CLI to suppress the informational
  warnings about `number` type usage (the "Using 'number' type in..." messages).
  Useful when `number` is intentionally used for mixed integer/decimal formatting
  across many columns.
- File-level record types are now registered for `custom_type_def` files. When a
  child file extends a parent file, field types are validated: each child field must
  be the same type or a subtype of the corresponding parent field. This catches
  mismatches like a parent using `{extends:float}` while a child still allows
  `{extends:number}`.

### Changed

- Constraint types `{extends:X}` (colon/map form) and `{extends,X}` (comma/tuple
  form) are now treated as interchangeable after parsing. The colon form is
  automatically normalized to the comma form via alias resolution.
- Constraint types `{extends,X}` now register `type_spec` as their ancestor in the
  EXTENDS table, so `extendsOrRestrict("{extends:number}", "type_spec")` returns true.
- Union-to-union subtype checking now uses member-wise comparison as a fallback when
  exact string matching fails. For example, `{extends:float}|nil` is now correctly
  recognized as a subtype of `{extends:number}|nil`.

### Fixed

- When a file listed in Files.tsv is not found at its expected path but a file
  with the same name exists in a different directory, the error message now
  reports the actual location and suggests checking the directory, instead of
  only saying "does not exist".
- The reformatter now auto-detects and skips migration scripts (TSV files with
  `command, p1, p2, ...` headers) instead of reporting errors when they are
  co-located with data packages. A warning is logged for each skipped script.

## [0.13.0] - 2026-02-28

### Added

- **Migration tool** (`migration.lua`, `data_set.lua`). A programmatic and command-line
  interface for batch modifications to TSV data files at the raw level (no type parsing).
  Designed for data migrations — adding, removing, or renaming columns, updating cell values,
  reorganizing files, and similar structural changes to data packages.

  - **DataSet API** (`data_set.lua`): Mutable in-memory representation of multiple TSV files.
    Supports loading, saving, creating, deleting, renaming, and copying files. Provides column
    operations (add, remove, rename, move, set type/default), row operations (add, remove),
    cell operations (get, set, conditional set, sandboxed transform), and comment/blank line
    management. Includes `filesHelper()` for `Files.tsv` manipulation and `manifestHelper()`
    for `Manifest.transposed.tsv` access.

  - **Migration script executor** (`migration.lua`): Reads a TSV script file where each row
    is a command with positional parameters, and executes them sequentially against a DataSet.
    Supports `--dry-run` (validate without writing), `--verbose` (log each step), and
    `--log-level=LEVEL` options. Stops on first error with step number reporting.

  - **CLI entry point**: `lua54 migration.lua <script.tsv> <rootDir> [options]` runs a
    migration script from the command line. Shows usage help when called without arguments.

  - **Input validation**: Path traversal prevention, absolute path checks, disk-existence
    guards for create/rename/copy, save-overwrite safety, column name validation via
    `isName`, duplicate detection, and type checks on all helper method parameters.

  - See [MIGRATION.md](MIGRATION.md) for full documentation.

## [0.12.0] - 2026-02-26

### Added

- **TSV preamble support.** Comment and blank lines that appear *before* the header row in a
  regular (non-transposed) TSV file are now preserved as a preamble. The preamble is stored in
  `dataset.__preamble` (a raw TSV sub-sequence) and emitted first when the dataset is converted
  back to a string. This enables full-view COG scripts that generate both the header row and all
  data rows from within a single cog block.

- **COG views via `loadEnv.files`.** Each parsed dataset is now published into
  `loadEnv.files[typeName]` immediately after it is successfully parsed. Cog scripts in TSV files
  with a higher `loadOrder` can access previously-loaded datasets via `files.TypeName`, where
  `TypeName` matches the `typeName` column in `Files.tsv`. This enables *view* TSV files whose
  header and/or data rows are generated by a cog script that filters, transforms, or aggregates
  earlier-loaded data. View-of-view chains are supported provided `loadOrder` values are ordered
  correctly.

- **Tutorial `FireItems.tsv`** demonstrates a full COG view. It filters `Item.tsv` (loadOrder 100)
  for Fire-element items and regenerates both the header row and all data rows entirely inside a
  cog block (loadOrder 700). The file also illustrates TSV preamble support: four comment lines
  appear before the cog block and are preserved across reformatting.

### Fixed

- **`empty_data_file` bad-input test** now correctly expects the error on line 2 instead of
  line 1. The Phase 1 preamble scan advances past any blank/comment lines before looking for the
  header row; a file that contains only a single blank line therefore reports the "no valid header"
  error at line 2 (the position after the blank preamble), which is the accurate location.

## [0.11.0] - 2026-02-22

### Added

- **Column redefinition in child record types.** A child record (`{extends:Parent,...}`) may
  now re-declare a field that already exists in the parent, provided the child's type is
  compatible with (a subtype of) the parent's type. Two specialisations are supported:

  - **Column narrowing**: Re-declare a field with a stricter type.
    Example: parent has `critRate:float|nil`; child may re-declare as `critRate:float`
    (mandatory) or `critRate:nil` (omitted). `float` extends `float|nil`, so it is accepted.
  - **Column omission**: Re-declare a field as `nil` to permanently mark it as unused in that
    subtype. The parser rejects any value supplied for a `nil`-typed field, and the field is
    absent from output. Useful when a parent optional field has no meaning for a specific subtype.

  Additional rules:
  - The child's type must satisfy `extendsOrRestrict(childType, parentType)`.
    `T` always extends `T|nil`, so narrowing an optional field to mandatory is allowed.
  - Re-declaring a self-referencing parent field (`self.fieldname`) is disallowed (error).
  - Multi-level narrowing is supported: `A.x:number → B.x:integer → C.x:ubyte`.
  - `extendsOrRestrict` now returns `true` when a non-union child type extends any member of a
    union parent type (e.g., `float` extends `number|nil`; `nil` extends `number|nil`).
    This broadened check is also applied to `childUnionExtendsParent` comparisons.
  - Sibling type validation (`validateSiblingFieldTypes`) now allows sibling subtypes to
    independently narrow the same parent field, as long as both sibling types are subtypes of
    the parent's field type.
  - Using a standalone `nil` type in a **non-child** record emits a logger warning, since a
    field that can never hold a value only makes sense in a child record (as an omission marker).

- **Tutorial extended** to showcase column redefinition and omission (v0.11.0) together with
  custom type definition files (v0.10.0):
  - `tutorial/core/CoreTypes.tsv` — new custom type definition file registering `BaseStats`,
    `Point2D`, and the new `FlexStats` type (which adds an optional `critRate:float|nil` field).
    `BaseStats` and `Point2D` are moved here from the core manifest.
  - `tutorial/expansion/ExpansionTypes.tsv` — new custom type definition file registering
    `bossLevel` and `bossHp` (moved from expansion manifest) plus two new types:
    - `BossStats` — extends `FlexStats`, marks `critRate` as **omitted** (`critRate:nil`).
    - `EliteBossStats` — extends `FlexStats`, **narrows** `critRate` from `float|nil` to
      mandatory `float`.
  - `tutorial/expansion/Boss.tsv` — `bossStats` column changed from an inline
    `{extends:BaseStats,...}` spec to `BossStats|EliteBossStats`. Three existing bosses
    (no `critRate`) parse as `BossStats`; a new fourth boss `arachnidQueen` (with
    `critRate=0.35`) parses as `EliteBossStats`.

## [0.10.0] - 2026-02-22

### Added

- **Custom type definition files.** A TSV file whose `typeName` in `Files.tsv` is
  `custom_type_def` (or a type that directly or transitively has `superType=custom_type_def`)
  now has each of its data rows automatically registered as a custom type via
  `parsers.registerTypesFromSpec`. This is a convenient alternative to the inline
  `custom_types:{custom_type_def}|nil` manifest field for packages that define many
  custom types.
  - Sub-typed files (e.g. `typeName=GameCustomType, superType=custom_type_def`) are
    supported; any extra columns beyond the standard `custom_type_def` fields are
    parsed normally but ignored during type registration.
  - Cascading is supported: a custom type definition file with a lower `loadOrder`
    may define types that are used as parent types in another custom type definition
    file with a higher `loadOrder`.
  - Collision detection: re-registering a type name with a different parent type is
    an error; re-registering with the same parent type is idempotent (no error).
  - `DATA_FORMAT_README.md` updated with a "Custom Type Definition Files" sub-section
    and a new top-level "Column Omission" section (applicable to all TSV files).

## [0.9.0] - 2026-02-21

### Added

- Directory exploration now automatically skips hidden files and directories (names
  starting with `"."`, e.g. `.git`, `.env`). Skipped entries are logged at INFO level.

### Fixed

- Files referenced in `Files.tsv` that live in subdirectories of the package were
  falsely reported as "file listed in Files.tsv does not exist" when the reformatter
  was invoked with `"."` as the data directory. `getFilesAndDirs` normalises its
  directory argument at each recursive level, so `"./Resource"` becomes `"Resource"`
  internally; the old `computeFilenameKey` then performed a blind `sub(#dir + 2)` that
  silently dropped the first two characters of every sub-directory path
  (e.g. `"Resource/Bulk/…"` → `"source/Bulk/…"`), producing keys that never matched
  the entries read from `Files.tsv`. Fixed in `manifest_loader` by using
  `normalizePath` on both the discovered file path and its source directory before
  computing the relative key, so `"./"` is stripped consistently regardless of
  recursion depth.
- Missing-file errors (files listed in `Files.tsv` that do not exist on disk) now
  report the correct row number within `Files.tsv` instead of always saying `line 0`.
  The row index is now stored in a new `lcFn2LineNo` map in `files_desc` as each
  `Files.tsv` entry is processed, and propagated through `loadDescriptorFiles` to
  the error reporter.
- Missing-file errors no longer include a stale `row_key` (the name of the last
  successfully-processed row) in the error context. `badVal.row_key` is now
  explicitly cleared before each "does not exist" report.

- `normalizePath` now returns `"."` instead of `""` when a relative path resolves to
  the current directory (e.g. `"."`, `"./"`, `"a/.."`)
- `parse_type_union` crashed with an assertion ("on error, at least one badVal must be
  logged") when a union member type (e.g. `Metal.AtomicType|nil`) had already been
  parsed and cached as unknown from a prior file or column. `parse_type` returns `nil`
  silently for cached-unknown types (to avoid duplicate error messages), but the
  assertion required that every `nil` return be accompanied by a new log entry. Fixed
  by checking `state.UNKNOWN_TYPES` for the member spec before asserting: a silent nil
  that matches a cached unknown is legitimate; only a nil with no cache entry is a
  programming bug worth asserting.
- `matchDescriptorFiles` crashed with "attempt to index a nil value" when a package
  manifest was found at the root of the scanned directory (path like
  `"./Manifest.transposed.tsv"`). `normalizePath` strips the leading `"./"`, leaving
  a bare filename with no `"/"`, so `getParentPath` correctly returned `nil` but the
  callers did not guard against it. Fixed by applying `or ""` at the two call sites in
  `files_desc.lua` (lines 84 and 91), consistent with the same guard already present
  in `manifest_info.lua`.

## [0.8.0] - 2026-02-15

### Added

- **Bad input test framework** in `bad_input/` for integration-level testing of error detection
  and reporting quality. Contains 25 test cases across 8 categories (cli_errors, manifest_errors,
  files_tsv_errors, type_errors, header_errors, structure_errors, expression_errors,
  validator_errors). Each test case is a mini-package with deliberate errors; the runner copies
  files to a temp directory, runs the reformatter, normalizes output (stripping timestamps and
  paths), and compares against stored expected output. Supports `--update` mode for generating
  baselines, and category/test filtering. Includes both Windows (`run_bad_input_tests.cmd`) and
  Unix/WSL (`run_bad_input_tests.sh`) runners.

- **Pre-commit check script** (`pre_commit_check.sh`, `pre_commit_check.cmd`) that runs all
  quality gates in sequence: unit tests, tutorial export checks (JSON, SQL+MPK, Lua, TSV reformat),
  and bad input tests. Supports `--quick` mode to skip export checks.

### Changed

- Boolean parse errors now list valid values (`true`, `false`, `yes`, `no`, `1`, `0`)
- Enum parse errors now list valid members (e.g., `valid values: common, epic, legendary, rare, uncommon`)
- Version parse errors now show expected format (`X.Y.Z`)
- Number range errors now show the valid range (e.g., `must be 0..255`)
- Number/integer nil errors now say `value is missing or nil` instead of `context was 'tsv', was expecting a string`
- Empty data file error now says `file is empty or has no valid header row` instead of
  `header_row is neither a string nor a sequence; skipping this file!`
- Bad custom type errors now say `Bad custom type definition` instead of `Bad {custom_type_def}|nil`
- Short rows (fewer columns than header) now report a structural error with column count mismatch
  (e.g., `row has 1 columns but header defines 2 -- column 'value' is missing`) instead of
  flowing nil to the type parser. Nullable (`|nil`) columns in short rows are silently accepted.
- Row validator errors now show the error message prominently with the expression as secondary
  context, instead of the expression as the value and the error message as context
- Expression evaluation errors (syntax errors, undefined references) now have stack traces
  sanitized — internal sandbox file paths and string chunk prefixes are stripped, showing only
  the user-relevant error message
- Expression compile errors and runtime errors are now handled separately, fixing duplicate
  error logging that occurred when a compile-time error was caught and re-logged at runtime
- Invalid `--log-level` values now default to `ERROR` level, suppressing noisy module
  initialization output instead of falling through to `INFO`

### Fixed

- Columns with no type annotation (no `:` separator in header) now produce a warning instead
  of silently defaulting to `string`
- Files listed in `Files.tsv` that do not exist on disk are now detected and reported as errors

## [0.7.0] - 2026-02-14

### Added

- **Type tags**: Named groups of types sharing a common ancestor, declared via the new `members`
  field in `custom_type_def`. Type tags restrict `{extends,...}` acceptance to listed members
  (and their subtypes). Multiple packages can declare the same tag with the same ancestor —
  members are merged additively, enabling cross-package extensibility. Tags can be members of
  other tags (nested/transitive tagging), enabling hierarchical type groupings.
  Example: `{name="CurrencyType",parent="number",members={"gold"}}`.
- New `members:{name}|nil` field in the `custom_type_def` record type. Mutually exclusive
  with other constraint types (`min`/`max`, `minLen`/`maxLen`/`pattern`, `values`, `validate`).
- New `listMembersOfTag(tagName)` helper function available in validator expressions. Returns
  a sorted array of member type names for a type tag, or `nil` if the name is not a tag.
- New `isMemberOfTag(tagName, typeName)` helper function available in validator expressions.
  Returns `true` if `typeName` is a member of the tag (directly, via subtype, or transitively
  via nested tags).
- Tutorial: `CurrencyType` type tag in core package (with `gold` member), extended by
  expansion package (adding `bossGem` member). `ExpansionItem.tsv` uses `rewardType:CurrencyType`.
- **Self-referencing field types**: New `self._N` (tuple) and `self.fieldname` (record) syntax
  for dependent types. A field's type can be determined by the value of another field that
  produces type name strings. The referenced field must have a type that resolves to type names
  (`type`, `type_spec`, `name`, `{extends,X}`, or a type tag). Uses two-pass parsing: regular
  fields are parsed first, then self-referencing fields use the parsed value as a dynamic type
  name. Self-references cannot form cycles (no mutual self-refs, no self-referencing).
  Example: `{number_type,self._1}` means "the second field's type is determined by the first
  field's value" — if the first field parses as `"integer"`, the second field is validated as
  an integer.
- Refactored `tagged_number` from imperative validator to declarative `{number_type,self._1}`
  alias, using the new self-referencing field type feature.
- Refactored `any` from imperative validator to declarative `{type,self._1}` alias, using the
  new self-referencing field type feature.
- New `selfref` AST tag in the LPEG type parser for `self.fieldname` references.
- New `--log-level=<level>` option in the reformatter CLI to override the default `info` log
  level. Valid levels: `debug`, `info`, `warn`, `error`, `fatal`. Sets the level globally for
  all modules via new `named_logger.setGlobalLevel()` function.

## [0.6.0] - 2026-02-13

### Added

- New `hexbytes` built-in type extending `ascii` for hex-encoded binary data. Validates even length
  and hex characters only, normalizes to uppercase. Exported as native binary (MessagePack) or
  BLOB with `X'...'` literals (SQL).
- New `base64bytes` built-in type extending `ascii` for base64-encoded binary data (RFC 4648).
  Validates encoding and normalizes via decode/re-encode round-trip. Exported as native binary
  (MessagePack) or BLOB (SQL).
- New `base64` module: pure-Lua RFC 4648 Base64 encode/decode with `encode()`, `decode()`, and
  `isValid()` functions.
- Tutorial `Icon.tsv` with 8x8 monochrome pixel art icons demonstrating both binary data types.
- New bare `{extends,<type>}` type spec syntax. When the extends syntax is used without additional
  fields (e.g., `{extends,number}` or `{extends:number}`), it defines a type whose values must be
  names of registered types extending the specified ancestor. Usable anywhere a type spec is valid
  (column headers, inline, manifests). For example, `{name="numericUnit",parent="{extends,number}"}`
  accepts only type names like `kilogram` or `metre` that extend `number`. Enables the "Quantity
  pattern" for pairing unit type names with numeric values.
- `extendsOrRestrict()` now recognizes union types as extending a common ancestor when all
  member types extend that ancestor. For example, a union `integer|float` is now recognized
  as extending `number`, and `ubyte|ushort` as extending `integer`. Unions containing `nil`
  are excluded (since `nil` does not extend any base type). This also improves SQL type mapping
  for such unions (e.g., `REAL` instead of `TEXT` for numeric unions).
- Guards in `registerTypesFromSpec` to reject union types as parents for scalar constraints
  (numeric, string, enum). Union parents remain valid for expression-based validators.
- New `number_type` built-in type: a restricted `type_spec` that only accepts names of types
  extending `number` (e.g., `integer`, `float`, `long`, `percent`, or custom numeric types).
  Enables type-safe references to numeric type families.
- New `tagged_number` built-in type: a validated `{number_type,number}` tuple, similar to `any` but
  restricted to numeric types. Validates that the value matches the declared number type
  (e.g., `"integer",5` is valid but `"integer",3.5` is rejected). Supports the Quantity pattern
  for pairing unit type names with numeric values.
- New `quantity` built-in type: compact string format `<number><number_type>` (e.g., `3.5kilogram`,
  `100metre`, `-5integer`). Parsed to the same `{type_name, number}` structure as `tagged_number`.
  Extends `tagged_number`.
- Tutorial expansion now demonstrates bare extends with an `intTypeName` custom type.
- New writable `ctx` table available in all validator types (row, file, package). Enables
  validators to accumulate state across invocations — for example, a row validator can track
  seen values to check column uniqueness without being written as a file validator. Row validators
  share one `ctx` per file across all rows; file and package validators share one `ctx` across
  all their expressions.
- New `isReservedName(s)` predicate: returns true if the value is a reserved name (`self`).
- New `isTupleFieldName(s)` predicate: returns true if the value matches the tuple field name
  pattern `_<INTEGER>` (e.g., `_0`, `_1`, `_42`).
- New `INTERNAL_MODEL.md` documenting the internal Lua table structures for cells, columns,
  headers, rows, datasets, packages, exploded structures, and the processing pipeline.
- New `USER_DATA_VIEW.md` documenting the external/user view of data from the perspective of
  cell expressions, COG scripts, and validators, including helper function reference and sandbox
  built-ins summary.

### Changed

- **Breaking**: A single `_` is no longer a valid identifier or name. This affects all name
  validation (type names, aliases, record field names, enum labels, column names).
- **Breaking**: Type names and type aliases cannot end with `_`. This creates a namespace
  distinction: record field names can end with `_`, ensuring they never collide with type names.
- **Breaking**: `self` is now a reserved name: it cannot be used as a type name, type alias,
  record field name, or enum label. This prevents conflicts with the `self` keyword used in
  validator expression evaluation.
- **Breaking**: `_<INTEGER>` patterns (`_0`, `_1`, `_2`, ...) are now reserved for tuples: they
  cannot be used as type names, type aliases, record field names, or enum labels. These names are
  used internally for tuple field access (e.g., `tuple._1`, `tuple._2`).
- **Breaking**: Validators now provide parsed values directly, consistent with cell expressions.
  `self.colName` in validators returns the parsed value (e.g., a number) instead of a cell object.
  All `.parsed` access in validator expressions must be removed:
  - Before: `self.price.parsed > 0 or 'price must be positive'`
  - After: `self.price > 0 or 'price must be positive'`
  - Custom predicates in helper functions are also affected:
    - Before: `all(rows, function(r) return r.price.parsed > 0 end)`
    - After: `all(rows, function(r) return r.price > 0 end)`
- `validator_helpers` functions (`unique`, `sum`, `min`, `max`, `avg`, `lookup`, `groupBy`)
  now expect rows with parsed values directly accessible via `row[column]`, instead of
  cell objects requiring `row[column].parsed`.
- Data Access Reference section extracted from `DATA_FORMAT_README.md` into standalone
  `USER_DATA_VIEW.md`.

### Fixed

- Windows absolute path handling in file operations (exporter, manifest loader, type parsing).
- SQL exporter crash on exploded column names with bracket notation (e.g., `materials[1]`).
  Replaced `isName()` assertion with sanitization for SQL column identifiers.
- SQL exporter crash when `header.__source` or `header.__dataset` is nil.
- SQL exporter now handles union column types (e.g., `integer|string`) and type aliases
  resolving to unions (e.g., `super_type` → `type_spec|nil`). Union columns are mapped to
  `TEXT` in SQL; unions containing a table type use JSON encoding (same as standalone `table`
  columns). Previously these produced "Unknown column type" errors.

## [0.5.2] - 2026-02-07

### Added

- `super_type` is now a built-in type alias for `type_spec|nil`. Packages no longer need to
  define it as a custom type in their manifests.
- New "Cell Value Formatting" section in DATA_FORMAT_README.md documenting how to write values
  for all types (primitives, containers, nil, enums, quoting rules).
- New "Validation-Related Types" subsection in DATA_FORMAT_README.md documenting `expression`,
  `error_level`, `validator_spec`, and `super_type` built-in types.
- DATA_FORMAT_README.md now documents `self` references in regular expressions (not just defaults),
  intra-file row references, and the difference between expression context (`self.col`) and
  validator context (`self.col.parsed`).
- DATA_FORMAT_README.md now documents custom manifest fields, `package_validators`, and the
  full set of Files.tsv columns including `rowValidators` and `fileValidators`.
- Tutorial README added to the documentation table in README.md.

### Changed

- `comment` and `comment|nil` columns (e.g., `devNotes`) are now automatically stripped from all
  export formats (JSON, SQL, XML, Lua, TSV). Comment columns are developer-only annotations
  preserved during reformatting but excluded from production exports.
- `number` type usage info downgraded from deprecation warning to informational message.
  The `number` type is useful when you want mixed integer/decimal formatting (e.g., `loadOrder`),
  whereas `float` forces all values to decimal format (e.g., `5` becomes `5.0`).
- Lua code library files (`.lua`) now log at info level ("Loading code library: ...") instead of
  warning "Don't know how to process" and "No priority found for". Libraries referenced via
  manifest `code_libraries` don't need entries in `Files.tsv`.
- Array parser now gives a specific warning when values are unnecessarily wrapped in `{}`:
  "Value {...} is wrapped in {} but array braces are added automatically; remove the outer {}"
  instead of the generic "Assuming ... is a single unquoted string".
- `typeName` vs `fileName` check now tolerates dotted filenames by comparing with dots removed
  (e.g., `Item.en.tsv` with typeName `ItemEN` no longer triggers a spurious warning).
- README.md slimmed down: removed duplicated type system reference, tutorial examples, and
  package system sections that are already covered in DATA_FORMAT_README.md.
- Files.tsv `superType` column now uses the built-in `super_type` type instead of requiring
  a custom type alias in each package manifest.

### Fixed

- Fixed `findFilePath` suffix matching in `file_joining` that could match wrong files across
  packages (e.g., `ExpansionItem.tsv` matching when looking for `Item.tsv`). The function now
  requires a path separator boundary before the filename match.
- Fixed tutorial data: `load_after` value in expansion manifest corrected from `{'tutorial.core'}`
  to `"tutorial.core"` (array braces are added automatically by the parser).
- Fixed tutorial data: renamed "Chronicles of Tabula" to "Chronicles of Tabulua" throughout.
- Fixed tutorial data: `tags` column type changed from `{string}` to `{name}` in Item.tsv and
  ExpansionItem.tsv to match the actual tag values (dotted identifiers).
- Fixed REFORMATTER.md example paths that were broken (duplicated/wrong directory paths).
- Fixed README.md CLI examples using non-existent `--json` shorthand flags; corrected to
  `--file=json` syntax.

## [0.5.1] - 2026-02-06

### Added

- Comprehensive tutorial in `tutorial/` directory with two example packages (core + expansion)
  demonstrating all TabuLua features including custom types, validators, expressions, and multi-package support

### Changed

- Comment lines in transposed files now use `__comment#` prefix (instead of `dummy#`) for placeholder columns
  - Uses 1-based indexing (`__comment1`, `__comment2`, etc.) consistent with Lua conventions
  - The `__comment` prefix is reserved and should not be used for user column names
- Reformatter now reformats manifest files (`Manifest.transposed.tsv`)
  - User-defined fields beyond the standard manifest schema are preserved
  - Comments in manifests are preserved via the `__comment` placeholder mechanism

### Fixed

- Transposed data files with comments are now correctly preserved by the reformatter
  - Previously, comments in `.transposed.tsv` files would cause errors or be lost during reformatting
  - Comments are converted to `__comment#:comment` placeholder columns during loading and restored on output
- Custom numeric types now properly inherit parent min/max limits when only one bound is specified
  - e.g., `bossLevel extends level` with only `min=50` now correctly inherits `max=99` from parent
- `count()` function in validator_helpers now works with dictionary-style tables (string keys)
  - Previously returned 0 for tables like `packageFiles` which use string keys
- Duplicate file/type name warnings no longer triggered for `Files.tsv` across packages
  - Every package is expected to have its own `Files.tsv`, so duplicate warnings were spurious
- Added error when specifying parent directories instead of package directories
  - e.g., `tutorial/` instead of `tutorial/core/ tutorial/expansion/` now shows a clear error message
  - Helps users understand they must specify directories containing `Manifest.transposed.tsv` or `Files.tsv`

### Removed

- Removed `demo/` directory (superseded by the new `tutorial/` directory)

## [0.5.0] - 2026-02-03

### Added

- Multi-level validator system for row, file, and package validation
  - **Row validators**: Validate individual rows after all columns are parsed, with access to `self` (the row) and `rowIndex`
  - **File validators**: Validate entire files after all rows are processed, with access to `rows` and `count`
  - **Package validators**: Validate the full package after all files are loaded, with access to `files`
  - Validators support `error` (default) and `warn` levels
  - Validators return `true`/`""` for valid, `false`/`nil` for invalid, or a string for custom error messages
- New `validator_executor` module for sandboxed validator execution with configurable quotas
  - Row validator quota: 1,000 operations
  - File validator quota: 10,000 operations
  - Package validator quota: 100,000 operations
- New `validator_helpers` module with collection functions for use in validators
  - Aggregate functions: `sum`, `min`, `max`, `avg`, `count`
  - Collection predicates: `unique`, `all`, `any`, `none`
  - Query functions: `filter`, `find`, `lookup`, `groupBy`
- New built-in types for validator support
  - `expression`: Syntax-validated Lua expression string
  - `error_level`: Enum with values `"error"` or `"warn"`
  - `validator_spec`: Union of `expression` or `{expr:expression, level:error_level|nil}`
- New `validator_spec` columns in file descriptors: `rowValidators` and `fileValidators`
- New `package_validators` field in manifest specification
- `serializeInSandbox()` function in `serialization` module for safe serialization of arbitrary values
- Documentation for collection columns (bracket notation for arrays and maps in exploded columns)
- Documentation for `any`, `package_id`, and `regex` types
- Comprehensive test suites: `parsers_validators_spec`, `validator_executor_spec`, `validator_helpers_spec`
- Demo validators on `Item.tsv` (row and file level) and in `Manifest.transposed.tsv` (package level)

### Changed

- `manifest_loader` now runs all validators after files are loaded and returns `validationPassed` and `validationWarnings` in results
- `files_desc` parses and propagates `rowValidators` and `fileValidators` columns from file descriptors
- `table_parsing.parseTableStr` now returns `nil` on validation failure instead of continuing
- Union parser in `parsers/generators` now saves and restores error counts around each trial parse to prevent error accumulation
- `parsers/registration.restrictWithExpression` simplified to use `serializeInSandbox` for error messages
- Version bumped to 0.5.0 across all modified modules

### Fixed

- Union parser error count leaking between trial parses, which could cause false failures in nested union/array types

## [0.4.0] - 2026-02-01

### Added

- New `float` built-in type for floating-point numbers
  - Always formatted with decimal point (e.g., `5` becomes `5.0`)
  - Extends `number` type
- New `long` type tests in demo package (`Item.tsv`) with 64-bit integer values
- Deprecation warning when using `number` type directly in column definitions
  - Suggests using `float` for decimal values or `integer`/`long` for whole numbers
- Safe integer constants (`SAFE_INTEGER_MIN`, `SAFE_INTEGER_MAX` = ±2^53) for IEEE 754 double compatibility

### Changed

- **Breaking: Number type hierarchy restructured for LuaJIT/JSON compatibility**:
  - `integer`: Now restricted to safe integer range (±2^53) instead of full 64-bit
    - Values outside this range are rejected with clear error message
    - Ensures exact representation in IEEE 754 doubles (JSON, LuaJIT)
  - `long`: Now extends `number` directly (NOT `integer`)
    - On Lua 5.3+: Supports full 64-bit signed integer range (`math.mininteger` to `math.maxinteger`)
    - On LuaJIT: Limited to safe integer range with clear error message
  - `float`: Explicit floating-point type with decimal formatting
  - `number`: Parent type for all numeric types (deprecated for direct use)
  - Derived integer types (`byte`, `ubyte`, `short`, `ushort`, `int`, `uint`) unchanged - all within safe range
- `restrictNumber()` now uses safe integer bounds as defaults when extending `integer` type
- Fixed precision loss for 64-bit integers in `number` parser
  - Removed `+0.0` conversion that was corrupting large integers
  - Values like `9223372036854775807` now serialize correctly

### Fixed

- Large integers (outside ±2^53) no longer convert to scientific notation
- `long` type values preserve full 64-bit precision on Lua 5.3+
- Integer validation now properly checks safe range boundaries

## [0.3.0] - 2026-02-01

### Added

- Custom types with data-driven validators via `custom_types` manifest field
  - Numeric constraints: `min`, `max` for types extending `number` or `integer`
  - String constraints: `minLen`, `maxLen`, `pattern` for types extending `string`
  - Enum constraints: `values` for restricting enum types
  - Expression constraints: `validate` for custom Lua expression validation (sandboxed)
  - Custom error messages: expressions can return strings/numbers as error messages
  - Types without constraints act as simple type aliases
- New `registerTypesFromSpec()` function in parsers module for programmatic type registration
- New `custom_type_def` built-in record type for manifest parsing
- Demo file `CustomTypes.tsv` demonstrating custom type validators
- Comprehensive test suite for custom type registration
- Sandbox API for code libraries exposing safe TabuLua functions:
  - `predicates`: All predicate functions for validation (35+ functions)
  - `stringUtils`: `trim`, `split`, `parseVersion`
  - `tableUtils`: `keys`, `values`, `pairsCount`, `longestMatchingPrefix`, `sortCaseInsensitive`
  - `equals`: Deep content equality comparison

### Changed

- **Breaking**: Removed `type_aliases` manifest field in favor of unified `custom_types`
  - Migration: Replace `{'aliasName','parentType'}` with `{name="aliasName",parent="parentType"}`
- Updated documentation in `DATA_FORMAT_README.md` with custom types section
- Updated `manifest_info` module to process custom types during package loading

### Fixed

## [0.2.0] - 2026-01-31

### Added

- File joining system for combining related TSV files by key columns
  - New `file_joining` module with join index building and file merging
  - Support for language-specific files (e.g., `Item.de.tsv` joins to `Item.tsv`)
  - Secondary file grouping and export filtering
- Exploded arrays and maps support for nested data structures
  - Enhanced `exploded_columns` module for flattening/reassembling nested records and tuples
  - Automatic detection of tuple vs record structures from column paths
- New demo file `Item.de.tsv` for localization example

### Changed

- Updated `exporter` with file joining integration
- Updated `files_desc` with enhanced file descriptor handling
- Updated `manifest_loader` with join-aware loading
- Updated `tsv_model` with improved column handling
- Enhanced `parsers/builtin` and `parsers/generators` for new type support

## [0.1.0] - 2026-01-28
 
### Added

- Everything - First release