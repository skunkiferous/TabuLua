
# Change Log
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/)
and this project adheres to [Semantic Versioning](http://semver.org/).

## [Unreleased] - yyyy-mm-dd

### Added

### Changed

### Removed

### Fixed

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