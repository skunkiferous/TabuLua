# Lua Modules Reference

This document lists all Lua modules in the project alphabetically, with a brief description and their direct local dependencies.

## Module Index

| Module | Description | Dependencies |
|--------|-------------|--------------|
| [archive_formats](#archive_formats) | Lazy archive-format registry (zip via libdeflate); enumerates and extracts the member files inside a container archive, mirroring `compression`'s lazy-provider pattern | compression, global_reset, named_logger, read_only |
| [base64](#base64) | Pure-Lua RFC 4648 Base64 encode/decode | read_only |
| [builtin_content_stages](#builtin_content_stages) | Seeds the content-pipeline registry with the built-in stages (EOL-normalise, COG macro, gzip decode, JSON + EAV + XML + TSV-cell + Lua-file transcoders) | compression, content_pipeline, eav_transcoder, file_util, global_reset, json_transcoders, lua_cog, lua_transcoder, read_only, tsv_transcoders, xml_transcoder |
| [builtin_wiring](#builtin_wiring) | Registers the built-in `Type` / `enum` / `custom_type_def` `onLoad` handlers, the ten optional `Files.tsv` columns, the graph-family per-typeName cascade, and the edge-consistency engine post-pass with the type-wiring registry | error_reporting, global_reset, graph_helpers, graph_wiring, named_logger, parsers, read_only, type_wiring |
| [cog_discovery](#cog_discovery) | Auto-scans package roots for COG-eligible doc/template files (extension + `needsCog`-gated), with `.cogignore` opt-out | content_pipeline, file_util, lua_cog, read_only |
| [comparators](#comparators) | Value comparison and equality functions | read_only, sparse_sequence, table_utils |
| [compression](#compression) | Lazy compression-codec registry (gzip via libdeflate); registers per-`(format, direction)` loaders pulled in only on first use | named_logger, read_only |
| [content_pipeline](#content_pipeline) | Content-stage registry: dispatches decode/transcode/normalize/macro/asset stages by file name/extension/magic before parsing | file_util, named_logger, read_only |
| [data_set](#data_set) | Mutable in-memory representation of multiple TSV files | raw_tsv, file_util, string_utils, read_only, sandbox, sandbox_env, predicates, named_logger |
| [deserialization](#deserialization) | Data deserialization (Lua, JSON, XML, MessagePack) | read_only |
| [doc_generator](#doc_generator) | Export-time data-driven doc generation: expands COG doc templates against the loaded dataset and writes them to the export dir (never TSV-parsed) | builtin_content_stages, content_pipeline, file_util, named_logger, read_only |
| [eav_transcoder](#eav_transcoder) | Content-pipeline transcoder pivoting `.eav` (long-format) files to/from a schema-typed wide TSV; auto-matched by extension and reversible | parsers, raw_eav, raw_tsv, read_only |
| [error_reporting](#error_reporting) | Error collection and reporting system | named_logger, read_only, serialization |
| [exporter](#exporter) | Exports parsed data to multiple formats | base64, error_reporting, exploded_columns, file_joining, file_util, named_logger, parsers, predicates, raw_tsv, read_only, serialization, tsv_model |
| [exploded_columns](#exploded_columns) | Handles exploded/collapsed column structures | read_only, table_utils |
| [file_joining](#file_joining) | Joins related TSV files by key columns | read_only, table_utils |
| [global_reset](#global_reset) | Registry for resetting all module-level mutable state | *(none)* |
| [export_tester](#export_tester) | Tests exported files via re-import comparison | error_reporting, file_util, importer, manifest_loader, named_logger, read_only, round_trip |
| [extract_test_errors](#extract_test_errors) | Standalone CLI script: extracts failed-test info from TAP test output | file_util, named_logger, read_only *(standalone CLI script)* |
| [file_util](#file_util) | File system operations and path manipulation; resolves virtual archive-member paths so reads see inside containers | archive_formats, global_reset, named_logger, read_only, table_utils |
| [files_desc](#files_desc) | File descriptor discovery and load order management | builtin_wiring, file_util, lua_cog, named_logger, parsers, raw_tsv, read_only, table_utils, tsv_model, type_wiring |
| [graph_helpers](#graph_helpers) | Graph data primitives: accessors, edge-key codec, cycle detection, traversal, and validators | read_only |
| [graph_wiring](#graph_wiring) | Family detection helpers for graph-shaped record types (`detectFamily`, `detectRole`, `detectEdgeFamily`). After Phase 2b the dispatch / validation entry points moved into the type-wiring registry | read_only |
| [importer](#importer) | File import system for various formats | deserialization, file_util, named_logger, read_only, string_utils |
| [json_transcoders](#json_transcoders) | Content-pipeline JSON↔TSV transcoders in three layouts (`json:objects` / `json:rows` / `json:columns`) × natural/`:typed` codecs, id-selected via the `Files.tsv` `transcoder` column; **reversible** so JSON inputs round-trip in the reformatter | deserialization, error_reporting, parsers, raw_tsv, read_only, serialization, tsv_model |
| [lua_cog](#lua_cog) | Code generation and templating system | file_util, named_logger, read_only, string_utils |
| [lua_transcoder](#lua_transcoder) | Content-pipeline transcoder reading/writing TabuLua's `--file=lua` export (`return { <header>, <row>, … }`) as a wide TSV; id-selected (`lua:tabulua`), schema-free, reversible, executed under the sandbox + instruction quota | error_reporting, parsers, raw_tsv, read_only, sandbox, sandbox_env, serialization, string_utils, tsv_model |
| [manifest_info](#manifest_info) | Package metadata, versioning, dependencies, and the `bootstrap` field dispatcher (`runPackageBootstraps`) | error_reporting, file_util, lua_cog, named_logger, parsers, raw_tsv, read_only, sandbox, sandbox_env, tsv_model |
| [manifest_loader](#manifest_loader) | Package loading orchestration and dependency resolution | builtin_wiring, error_reporting, file_util, files_desc, lua_cog, manifest_info, parsers, patch_executor, processor_executor, raw_tsv, read_only, sandbox_env, schema_overlay, table_utils, tsv_model, type_wiring, validator_executor |
| [migration](#migration) | Migration script executor for batch TSV modifications | named_logger, raw_tsv, data_set, string_utils, read_only, file_util |
| [ollama_batch](#ollama_batch) | Batch-processes TSV rows through a local Ollama LLM | named_logger, raw_tsv, string_utils, read_only, file_util |
| [named_logger](#named_logger) | Logging system with named loggers and levels | global_reset |
| [normalize_output](#normalize_output) | Normalizes reformatter output for bad input test comparison | *(none — standalone CLI script)* |
| [number_identifiers](#number_identifiers) | Numeric/string identifier conversion | error_reporting, read_only |
| [parsers](#parsers) | Main entry point for type parsing system | global_reset, parsers.*, read_only |
| [parsers.builtin](#parsersbuiltin) | Built-in type parsers (boolean, number, string, etc.) | base64, error_reporting, parsers.generators, parsers.lpeg_parser, parsers.state, parsers.utils, predicates, regex_utils, serialization, string_utils |
| [parsers.generators](#parsersgenerators) | Factory functions for specialized parsers | error_reporting, parsers.state, parsers.utils, predicates, read_only, sparse_sequence, table_utils |
| [parsers.introspection](#parsersintrospection) | Type querying and relationship analysis | parsers.state, parsers.utils |
| [parsers.lpeg_parser](#parserslpeg_parser) | LPEG grammar for type specification parsing | parsers.state, parsers.utils |
| [parsers.registration](#parsersregistration) | Type alias and custom parser registration | error_reporting, number_identifiers, parsers.generators, parsers.lpeg_parser, parsers.state, parsers.utils, predicates, regex_utils, sandbox, sandbox_env, serialization, string_utils |
| [parsers.schema_export](#parsersschema_export) | Exports type definitions as a schema model | parsers.lpeg_parser, parsers.state, table_utils |
| [parsers.state](#parsersstate) | Shared state and registries for parser system | named_logger |
| [parsers.type_parsing](#parserstype_parsing) | Core type parsing with inheritance support | parsers.generators, parsers.introspection, parsers.lpeg_parser, parsers.state, parsers.utils, serialization |
| [parsers.utils](#parsersutils) | Utility functions for parsers module | parsers.state, serialization, table_parsing |
| [predicates](#predicates) | Type checking predicate functions | read_only, string_utils, table_parsing, table_utils |
| [processor_executor](#processor_executor) | Sandboxed execution of file pre-processors that mutate parsed rows | error_reporting, named_logger, parsers, read_only, sandbox, sandbox_env, table_utils, type_wiring, validator_executor, validator_helpers |
| [raw_eav](#raw_eav) | Low-level reader/writer for the Entity–Attribute–Value (EAV / "long") 3-column table layout | raw_tsv, read_only |
| [raw_tsv](#raw_tsv) | Low-level TSV file parsing and writing | file_util, predicates, read_only, string_utils |
| [read_only](#read_only) | Read-only table proxy wrappers | table_utils |
| [reformatter](#reformatter) | TSV file reformatting and multi-format export | error_reporting, exporter, file_util, manifest_info, manifest_loader, named_logger, read_only, serialization |
| [regex_utils](#regex_utils) | Lua pattern to PCRE translation | predicates, read_only, sparse_sequence |
| [round_trip](#round_trip) | Round-trip serialization/deserialization testing | deserialization, read_only, serialization |
| [sandbox_env](#sandbox_env) | Single owner of the sandbox "safe API surface" | comparators, predicates, read_only, string_utils, table_utils |
| [patch_executor](#patch_executor) | Tier-A mod row patches: applies `add`/`remove`/`update`/`replace` ops from `patch` files to their target parent datasets (in load order, two-step value re-validation), mutating in place without baking into parent source | named_logger, parsers, read_only, tsv_model |
| [schema_overlay](#schema_overlay) | Tier-A0 mod schema overlays: collects `SchemaOverlay` files and applies their column `widenTo` / `newDefault` (pre-parse) and validator `suppress`/downgrade (pre-validation) to a parent file, without baking into the source | content_pipeline, named_logger, parsers, raw_tsv, read_only, tsv_model, validator_executor |
| [schema_validator](#schema_validator) | Validates typed JSON and XML export formats | read_only |
| [serialization](#serialization) | Data serialization (Lua, JSON, XML, SQL, MessagePack) | named_logger, predicates, read_only, sandbox, sparse_sequence |
| [sparse_sequence](#sparse_sequence) | Sparse array implementation | read_only |
| [string_utils](#string_utils) | String manipulation utilities | read_only |
| [table_parsing](#table_parsing) | Depth-based table parsing | read_only, error_reporting |
| [table_utils](#table_utils) | Table manipulation utilities | *(none)* |
| [tsv_diff](#tsv_diff) | TSV file comparison tool with order-based and primary-key modes | named_logger, raw_tsv, read_only, string_utils, file_util |
| [tsv_model](#tsv_model) | TSV loading with type validation and expressions | error_reporting, exploded_columns, named_logger, parsers, predicates, raw_tsv, read_only, string_utils, table_utils |
| [tsv_transcoders](#tsv_transcoders) | Content-pipeline transcoders reading/writing the three TSV export variants whose cells are Lua literals / typed JSON / natural JSON (`tsv:lua` / `tsv:json-typed` / `tsv:json-natural`), id-selected via the `Files.tsv` `transcoder` column, schema-free, and reversible | deserialization, error_reporting, parsers, raw_tsv, read_only, serialization, string_utils, tsv_model |
| [type_wiring](#type_wiring) | Registry that attaches behaviour to files by walking the `extends` chain; Phase 1 supports the `onLoad` slot | named_logger, read_only |
| [validator_executor](#validator_executor) | Sandboxed execution of row, file, and package validators | graph_helpers, named_logger, read_only, sandbox, sandbox_env, serialization, type_wiring, validator_helpers |
| [validator_helpers](#validator_helpers) | Helper functions for validator expressions | read_only, serialization |
| [xml_transcoder](#xml_transcoder) | Content-pipeline transcoder reading/writing TabuLua's own namespaced XML export format as a wide TSV; id-selected (`xml:tabulua`), schema-free, and reversible | deserialization, error_reporting, parsers, raw_tsv, read_only, serialization, string_utils, tsv_model |

---

## Module Details

### archive_formats
**File:** [archive_formats.lua](archive_formats.lua)

Archive / data-set format registry (TODO/archive_files.md §1). An *archive* is one on-disk file that is a **container for a set of member files** with an internal directory tree (a zip) — the load-bearing distinction from [compression](#compression), which wraps a single byte stream: an archive fans out to N members, so it cannot be a content-pipeline stage. The registry mirrors `compression`'s lazy-provider shape: a provider registers a **loader** keyed by extension (`zip`), run lazily the first time an archive of that format is opened, pulling in whatever rock it needs (or returning `nil` + reason). Registering the zip format does not require `libdeflate`; only opening a real zip does, so a project that never touches an archive runs without it, and one that does without it gets a clear "zip archives are not supported" error (logged once) instead of a crash. `list(format, bytes)` parses the central directory to enumerate members (metadata only); `read(format, bytes, member, maxBytes)` extracts one member, inflating method-8 entries via the same `libdeflate` raw-DEFLATE path the gzip provider uses and verifying each against its central-directory CRC-32 (reusing `compression.crc32`). The pure-Lua zip provider targets the common case (single-disk, non-encrypted, non-Zip64, method 0/8); Zip64, encryption, split archives, zip-slip paths, and member/size bomb caps are explicit clear errors. `formatForName` / `isArchive` classify a path by extension. Snapshots the provider registry and restores it via `global_reset`. (Not yet wired into the loader — that is archive_files.md Phase 2+.)

**Dependencies:** compression, global_reset, named_logger, read_only

---

### base64
**File:** [base64.lua](base64.lua)

Pure-Lua RFC 4648 Base64 encode/decode. Provides `encode()`, `decode()`, and `isValid()` for binary data encoding. Used by `parsers.builtin` for the `base64bytes` type and by `exporter` for binary export conversion.

**Dependencies:** read_only

---

### builtin_content_stages
**File:** [builtin_content_stages.lua](builtin_content_stages.lua)

Seeds the [content_pipeline](#content_pipeline) registry with the built-in content stages (the content-pipeline analog of [builtin_wiring](#builtin_wiring) for the type-wiring registry). Registers: a core `normalize`-phase EOL-normalise stage; the `macro`-phase COG stage (`transform` = `lua_cog.processContentBV`, `sinkTransform` = `lua_cog.stripCog`); a `decode`-phase gzip stage (delegating to [compression](#compression), reversible); and the `transcode`-phase stages — the three JSON layouts from [json_transcoders](#json_transcoders) (id-selected, with an `inputExtensions={"json"}` guard), the auto-matched, reversible `.eav` stage from [eav_transcoder](#eav_transcoder), and the id-selected (`xml:tabulua`), reversible XML stage from [xml_transcoder](#xml_transcoder) (`inputExtensions={"xml"}`). Also declares the COG-scan-eligible extension set. Snapshots the registry and restores it via `global_reset`.

**Dependencies:** compression, content_pipeline, eav_transcoder, file_util, global_reset, json_transcoders, lua_cog, lua_transcoder, read_only, tsv_transcoders, xml_transcoder

---

### builtin_wiring
**File:** [builtin_wiring.lua](builtin_wiring.lua)

Seeds the [type_wiring](#type_wiring) registry with the built-in `Type` / `enum` / `custom_type_def` `onLoad` handlers. The handlers themselves (alias registration, enum-parser registration, custom-type spec registration) were previously inline in `manifest_loader.lua`; loading `builtin_wiring` puts them in the registry under their canonical typeNames, then snapshots the registry and arranges restoration via `global_reset` so test runs that mutate the registry can recover the built-in baseline.

**Dependencies:** error_reporting, global_reset, named_logger, parsers, read_only, type_wiring

---

### cog_discovery
**File:** [cog_discovery.lua](cog_discovery.lua)

COG template discovery (cog_markdown.md Part 2). Data files are listed in `Files.tsv`, but doc/templating files are not, so this module auto-scans the same package roots for non-data text files whose extension is COG-scan-eligible (per [content_pipeline](#content_pipeline)'s `isScanEligible` set) **and** that actually contain a COG block (`lua_cog.needsCog`). The `needsCog` gate keeps the broad scan cheap — a file with no COG block is a one-substring no-op — so dropping a `.md` with a COG block anywhere in a package "just works" with no per-file registration. A `.cogignore` marker opts a directory subtree out. An optional shared read cache lets `discover()` and the later [doc_generator](#doc_generator) read each template only once.

**Dependencies:** content_pipeline, file_util, lua_cog, read_only

---

### comparators
**File:** [comparators.lua](comparators.lua)

Value comparison and equality functions for tables and primitive types. Provides custom comparators for sorting and deep equality testing.

**Dependencies:** read_only, sparse_sequence, table_utils

---

### compression
**File:** [compression.lua](compression.lua)

Compression-codec registry (content_pipeline.md §3.7, §9 Q2). Each `(format, direction)` pair — e.g. `("gzip", "decompress")` — is an independently and optionally supported codec. A provider registers a **loader** for a pair; the loader runs lazily the first time that pair is used, pulling in whatever rock/native lib the codec needs (or returning `nil` + reason if missing). The laziness matters: registering the gzip decode stage does not require `libdeflate` — only inflating a real `.gz` does, so a pipeline that never touches a compressed file works without it, and one that does without it gets a clear per-file "gzip decompression is not supported" error instead of a hard startup failure. gzip ships in both directions (built on pure-Lua `libdeflate`); other formats (zstd, brotli, …) are pairs with no provider yet.

**Dependencies:** named_logger, read_only

---

### content_pipeline
**File:** [content_pipeline.lua](content_pipeline.lua)

The content-stage registry — the sibling of the [type_wiring](#type_wiring) registry. type-wiring dispatches on a file's *parsed* record type; this registry dispatches on a file's *name* (extension / basename glob / directory / magic bytes) **before** any parsing, operating on raw bytes/text. Stages are grouped into ordered phases — `decode` (decompress; loops with extension peeling), `transcode` (structured→TSV; single match, id- or extension-selected), `normalize` (core EOL), `macro` (COG), `asset` (binary→binary) — and each file carries a `text`/`binary` content kind so text-only phases never touch binary. `readAndRun` (read + source pipeline) and `runSink` (export/inverse direction) are the entry points; `register` adds stages (built-ins via [builtin_content_stages](#builtin_content_stages), user stages via the bootstrap api). Helpers `peeledName` / `reversibleDecode` (decode round-trip) and `autoTranscodes` / `reversibleTranscode` (transcode routing + round-trip) support the loader and reformatter. Snapshots/restores via `global_reset`.

**Dependencies:** file_util, named_logger, read_only

---

### data_set
**File:** [data_set.lua](data_set.lua)

Mutable in-memory representation of multiple TSV files for the migration tool. Supports loading, saving, creating, deleting, renaming, and copying files. Provides column operations (add, remove, rename, move, set type/default), row operations (add, remove, copy), cell operations (get, set, conditional set, sandboxed transform), and comment/blank line management. Includes `filesHelper()` for `Files.tsv` manipulation and `manifestHelper()` for `Manifest.transposed.tsv` access.

**Dependencies:** raw_tsv, file_util, string_utils, read_only, sandbox, sandbox_env, predicates, named_logger

---

### deserialization
**File:** [deserialization.lua](deserialization.lua)

Data deserialization from multiple formats back to Lua values. Supports Lua literals, typed JSON, natural JSON, XML, MessagePack, and SQL BLOBs. Inverse of the serialization module.

**Dependencies:** read_only

---

### doc_generator
**File:** [doc_generator.lua](doc_generator.lua)

Data-driven doc generation (content_pipeline.md §3.10, cog_markdown.md §2.4). At export time, COG doc templates (found by [cog_discovery](#cog_discovery)) are expanded against the fully-loaded dataset and written to the export dir, mirroring the source layout. Each template runs through the content pipeline's `macro` stage (COG) with the load-time env extended so `files` exposes each dataset under **both** its typeName and its filename, so a COG block can read any dataset; the COG scaffolding is optionally stripped (`exportParams.stripCog`) for a clean published file. Templates are produced, **never** TSV-parsed.

**Dependencies:** builtin_content_stages, content_pipeline, file_util, named_logger, read_only

---

### eav_transcoder
**File:** [eav_transcoder.lua](eav_transcoder.lua)

Content-pipeline transcoder for the EAV (long-format) layout. Registered by [builtin_content_stages](#builtin_content_stages) as a `transcode` stage that **auto-matches the `.eav` extension** (no `Files.tsv` `transcoder` column needed, since EAV is unambiguous by extension) and is **reversible**. `eavToTSV` (forward) pivots the header-less triples via [raw_eav](#raw_eav) and projects them onto the file's `typeName` schema — typed `name:type` headers in schema field order, the key column being the schema's first field, absent fields becoming empty cells, unknown attributes an error. `tsvToEav` (reverse `encode`) de-types the header and compresses the reformatted wide TSV back to sparse triples, so the reformatter can rewrite an `.eav` source. Cells stay strings.

**Dependencies:** parsers, raw_eav, raw_tsv, read_only

---

### error_reporting
**File:** [error_reporting.lua](error_reporting.lua)

Error collection and reporting system using `badVal` handlers instead of exceptions. Provides structured error messages.

**Dependencies:** named_logger, read_only, serialization

---

### exporter
**File:** [exporter.lua](exporter.lua)

Exports parsed TSV data to multiple formats including JSON, Lua tables, XML, SQL, and MessagePack. An archive file streams to the export verbatim (passthrough copy), but a loaded archive *member* is input-only: it is skipped (via `file_util.resolveArchivePath`) so it is never re-emitted at a nested `.zip/`-as-directory path — the packed archive is its export representation (archive_files.md §5).

**Dependencies:** base64, error_reporting, exploded_columns, file_joining, file_util, named_logger, parsers, predicates, raw_tsv, read_only, serialization, tsv_model

---

### exploded_columns

**File:** [exploded_columns.lua](exploded_columns.lua)

Analyzes and handles "exploded" columns in TSV files where nested structures (records and tuples) are flattened into multiple columns with dot-separated paths like `location.position._1`. Provides functions to detect tuple vs record structures and reassemble nested values.

**Dependencies:** read_only, table_utils

---

### global_reset
**File:** [global_reset.lua](global_reset.lua)

Central registry for resetting module-level mutable state. Modules with internal caches or other post-load state call `register(fn)` during initialization, passing a function that restores their state. Calling `reset()` invokes all registered functions, returning every participating module to its original condition. Registrations persist across resets.

**Dependencies:** *(none)*

---

### export_tester
**File:** [export_tester.lua](export_tester.lua)

Tests exported files by re-importing them and comparing against original source data. Validates that export/import round-trips preserve data correctly across all supported formats.

**Dependencies:** error_reporting, file_util, importer, manifest_loader, named_logger, read_only, round_trip

---

### extract_test_errors
**File:** [extract_test_errors.lua](extract_test_errors.lua)

Standalone CLI script for the test runner ([run_tests.sh](run_tests.sh)). Parses TAP-format test output and extracts the failed-test information into a summary file, exiting non-zero when any test failed. Applies a `--log-level` argument early (before other modules load) so their loggers start at the requested level. Invoked as `lua54 extract_test_errors.lua <test_results.txt> <test_errors.txt>`; not part of the engine's `require` graph.

**Dependencies:** file_util, named_logger, read_only *(standalone CLI script)*

---

### file_joining
**File:** [file_joining.lua](file_joining.lua)

Joins related TSV files by key columns, enabling localization and data extension patterns. Secondary files (e.g., `Item.de.tsv`) are joined to primary files (e.g., `Item.tsv`) by matching rows on a join column (typically the first column/ID). Supports language-specific overrides and modular data organization.

**Dependencies:** read_only, table_utils

---

### file_util
**File:** [file_util.lua](file_util.lua)

File system operations including path manipulation, file reading/writing, and directory management. Also the **archive integration surface** (TODO/archive_files.md §3): `resolveArchivePath(path)` splits a path like `mods/utilmod.zip/data/Item.tsv` into the container and member when the `.zip` segment is a real file on disk, and `readFileBinary` / `getFileSize` are archive-aware — a member reads (extracts) and sizes (central-directory metadata, no extraction) exactly as if it were a loose file. Because the whole loader funnels through those two functions, this lights up the entire load path with no change to `content_pipeline`, `files_desc`, or `storeRawFile`. A small per-process archive cache (keyed by container path + mtime/size, holding the parsed central directory and — within a budget — the raw bytes) avoids re-parsing the zip per member access. It is cleared by `global_reset`, and also exposed as `clearArchiveCache()` — the cache only earns its keep within a single load, so `manifest_loader.processFiles` brackets each run with a clear, bounding retained archive bytes to one run. A loose-file path takes a few cheap string checks and is otherwise untouched. `expandArchives(files, extensions, file2dir)` is the collection-side companion: after `collectFiles`, it appends each archive's collectable members as virtual paths (metadata only, no extraction) so they participate in the load like loose files.

**Dependencies:** archive_formats, global_reset, named_logger, read_only, table_utils

---

### files_desc
**File:** [files_desc.lua](files_desc.lua)

Discovers and processes file descriptors from `Files.tsv`, managing file load order and metadata. Consults the [type_wiring](#type_wiring) registry (via `hasOnLoad`) to decide which files need a second descriptor pass — any typeName whose ancestor chain has a registered `onLoad` qualifies, so future built-ins or user packages that register a wired type are picked up automatically.

**Dependencies:** builtin_wiring, file_util, lua_cog, named_logger, parsers, raw_tsv, read_only, table_utils, tsv_model, type_wiring

---

### graph_helpers
**File:** [graph_helpers.lua](graph_helpers.lua)

Graph-data primitives shared by validator expressions, processor expressions, and the auto-wiring layer. Three groups of helpers:

- **Accessors** (`isRoot`, `isLeaf`, `parentsOf`, `childrenOf`, `neighboursOf`) operate on the engine-owned link fields of a single row. Family-mismatch checks are best-effort (`isRoot` errors if the row exposes `graphLinks`, etc.) since wrapped rows don't carry schema metadata.
- **Edge-key codec** (`splitEdgeKey`, `makeEdgeKey`, `makeUndirectedEdgeKey`, `edgeForLink`) for parsing and constructing the `<a>__<b>` compound keys used by `basic_graph_edge` / `graph_edge` / `tree_edge` files.
- **Traversal & validation** (`bfs`, `dfs`, `ancestorsOf`, `descendantsOf`, `shortestPath`, `findCycle`, `graphRefsExist`, `graphAcyclic`, `graphTreeShape`). Traversal helpers take an explicit `rows` argument (the row wrapper doesn't expose a back-reference) and carry a visited-set guard. The three `graph*` validators return `true` on success or an error-message string, matching the validator-expression contract.

`graphRefsExist`, `graphAcyclic`, and `graphTreeShape` are injected into the validator sandbox env by [validator_executor](#validator_executor) so the auto-wired validator expressions can call them.

**Dependencies:** read_only

---

### graph_wiring
**File:** [graph_wiring.lua](graph_wiring.lua)

Detects graph-family files in a manifest and auto-attaches their completion pre-processors and structural validators. Family detection walks the `Files.tsv` superType / extends chain transitively, matching on the literal superType strings (`basic_graph_node`, `graph_node`, `tree_node`); `tree_node` aliases to the same parser as `graph_node`, so chain-walking the user-written name is the only way to tell tree files apart from generic DAG files.

`applyAutoWiring(lcFn2PreProcessors, lcFn2FileValidators, lcFn2Type, extendsMap)` mutates the two maps in place — prepending the completion pre-processor (so it runs before user processors) and appending the structural validators (`graphRefsExist`, `graphAcyclic`, `graphTreeShape` as appropriate per family). Idempotent across repeated calls.

`validateEdgeFiles(...)` is the post-load consistency check for `edgesFor`-attached edge files: target exists, family matches, ≤1 edge file per node file, every endpoint is a row in the node file, every edge corresponds to a declared link (checked after pre-processor completion). It runs after the validator phase in [manifest_loader](#manifest_loader).

**Dependencies:** graph_helpers, named_logger, read_only

---

### importer
**File:** [importer.lua](importer.lua)

File import system that reads exported data files back into Lua. Supports Lua files, JSON (typed and natural), TSV with various cell formats, XML, MessagePack, and SQL. Auto-detects format from file extension.

**Dependencies:** deserialization, file_util, named_logger, read_only, string_utils

---

### json_transcoders
**File:** [json_transcoders.lua](json_transcoders.lua)

Content-pipeline JSON↔TSV transcoders. Several JSON layouts encode the same tabular data — `json:objects` (one object per row, self-describing), `json:rows` (one array per row, positional), `json:columns` (one array per column, the transpose) — so they can't be told apart by extension; the author selects one per file via the `Files.tsv` `transcoder` column. In every layout the column names, types and order come from the file's `typeName` schema (in sorted field order), **not** the JSON, so the emitted TSV carries a typed `name:type` header and the normal type/validation machinery applies. Each layout has a bare (`json-natural`) and a `:typed` codec. All six stages are **reversible**: a `*ToJson` encoder rewrites a `.json` source from the reformatted wide TSV (schema-free — names/types/order read from the wide-TSV header via `processTSV`), so JSON inputs round-trip in the reformatter like `.xml`/`.eav` (normalizing/canonical, not byte-identical). Registered as id-selected `transcode` stages by [builtin_content_stages](#builtin_content_stages).

**Dependencies:** deserialization, error_reporting, parsers, raw_tsv, read_only, serialization, tsv_model *(also uses external `dkjson`)*

---

### lua_cog
**File:** [lua_cog.lua](lua_cog.lua)

Cogwheel-style code generation and templating system. Processes `###[[[...###]]]` blocks for dynamic content generation.

**Dependencies:** file_util, named_logger, read_only, string_utils

---

### lua_transcoder
**File:** [lua_transcoder.lua](lua_transcoder.lua)

Content-pipeline `transcode` stage that reads TabuLua's `--file=lua` export — a single `return { <header>, <row>, … }` table (sequence of sequences, row 1 = `name:type` header) — back in as a wide, typed TSV, and re-encodes a wide TSV to that Lua document (the inverse of `exporter.exportLua`). Registered as `id="lua:tabulua"` with **no `extensions`**: a `.lua` is a **code library** to the loader by default, so a data `.lua` must be opted in with a `Files.tsv` `transcoder` column (`inputExtensions={"lua"}` is a guard, not a matcher); it never auto-fires. Unlike the parse-only transcoders it **executes** the file — under `sandbox.protect` with a size-scaled instruction quota and a [sandbox_env](#sandbox_env) env, exactly like `manifest_info.loadCodeLibrary`, so a hostile data file that loops aborts instead of hanging the load. It is **schema-free** (column names/types come from row 1, not a `typeName`): `luaToTSV` (forward) re-serialises each cell to the native in-cell form through the column's own [parsers](#parsers) parser; `tsvToLua` (reverse, the reversible `encode`) re-parses the wide TSV with [tsv_model](#tsv_model) and re-emits each cell via [serialization](#serialization)`.serialize`. A `.lua` misses the reformatter's native-TSV rewrite branch, so the reformatter round-trips it through the id-selected `reversibleTranscode` path with no reformatter change.

**Dependencies:** error_reporting, parsers, raw_tsv, read_only, sandbox, sandbox_env, serialization, string_utils, tsv_model

---

### manifest_info
**File:** [manifest_info.lua](manifest_info.lua)

Handles `Manifest.transposed.tsv` files for package metadata, versioning, type aliases, and dependency declarations.

**Dependencies:** error_reporting, file_util, lua_cog, named_logger, parsers, raw_tsv, read_only, sandbox, sandbox_env, tsv_model

---

### manifest_loader
**File:** [manifest_loader.lua](manifest_loader.lua)

Orchestrates package loading: discovers packages, resolves dependencies, dispatches type-wiring `onLoad` callbacks (via [type_wiring](#type_wiring) — replaces the former hand-written `Type` / `enum` / `custom_type_def` branches), registers types, loads data files in order, and runs all validators (row, file, package) after loading.

**`extractDataRows` preserves the dataset's PK index.** The internal `extractDataRows(tsv_file)` helper returns the data rows as a plain array but also copies the dataset's column-1 PK keys onto the result, so callers receive a row array that is still PK-indexed (`rows[someName]` is O(1)). Direct consumers — file validators, file pre-processors, package validators — should reuse this index instead of rebuilding a name→row map.

**Dependencies:** builtin_wiring, error_reporting, file_util, files_desc, graph_wiring, lua_cog, manifest_info, parsers, processor_executor, raw_tsv, read_only, sandbox_env, table_utils, tsv_model, type_wiring, validator_executor

---

### migration
**File:** [migration.lua](migration.lua)

Migration script executor for batch modifications to TSV data files at the raw level (no type parsing). Reads a TSV script file where each row is a command with positional parameters, and executes them sequentially against a DataSet. Supports `--dry-run` (validate without writing), `--verbose` (log each step), and `--log-level=LEVEL` options. CLI entry point: `lua54 migration.lua <script.tsv> <rootDir> [options]`. See [MIGRATION.md](MIGRATION.md) for full documentation.

**Dependencies:** named_logger, raw_tsv, data_set, string_utils, read_only, file_util

---

### named_logger
**File:** [named_logger.lua](named_logger.lua)

Logging system with named loggers, multiple log levels (DEBUG, INFO, WARN, ERROR), and configurable output targets.

**Dependencies:** global_reset *(also uses external `logging` library)*

---

### ollama_batch
**File:** [ollama_batch.lua](ollama_batch.lua)

Batch-processes TSV rows through a local Ollama LLM. Reads a config TSV file specifying input/output files, columns, prompt, model settings, and optional reference data and Lua transformation code. Sends rows to Ollama in batches as JSON arrays, parses JSON array responses, and merges generated columns back into the output. Progress is tracked in a TSV file for checkpoint/resume support. Supports `--resume`, `--status`, `--dry-run`, `--verbose`, `--log-level=LEVEL`, `--model=MODEL`, `--batch-size=N`, and `--timeout=N` options. Optional `prepare_input` and `process_output` Lua files provide input/output transformation hooks. Prompt templates support `{REFERENCE:filename}` placeholders for injecting reference data. CLI entry point: `lua54 ollama_batch.lua <config.tsv> <baseDir> [options]`.

**Dependencies:** named_logger, raw_tsv, string_utils, read_only, file_util *(also uses external `dkjson` and `socket.http` libraries)*

---

### normalize_output

**File:** [bad_input/normalize_output.lua](bad_input/normalize_output.lua)

Standalone CLI script for the bad input test framework. Normalizes reformatter output for repeatable comparison by stripping timestamps, normalizing path separators to forward slashes, replacing temp directory paths with `{DIR}`, and sorting lines to handle non-deterministic Lua table iteration order.

**Dependencies:** *(none — standalone CLI script, not part of the main module system)*

---

### number_identifiers
**File:** [number_identifiers.lua](number_identifiers.lua)

Converts between numeric and string identifiers with special handling for ranges and ID validation.

**Dependencies:** error_reporting, read_only

---

### parsers
**File:** [parsers.lua](parsers.lua)

Main entry point and public API for the modular type parsing system. Assembles all parser submodules and provides a clean, read-only interface.

**Dependencies:** global_reset, parsers.builtin, parsers.generators, parsers.introspection, parsers.lpeg_parser, parsers.registration, parsers.schema_export, parsers.state, parsers.type_parsing, parsers.utils, read_only

---

### parsers.builtin
**File:** [parsers/builtin.lua](parsers/builtin.lua)

Registers built-in type parsers: boolean, number, integer, float, long, string, text, markdown, identifier, name, version, http, type_spec, regex, percent, any, hexbytes, base64bytes, and integer range types (byte, ubyte, short, ushort, int, uint).

**Dependencies:** base64, error_reporting, parsers.generators, parsers.lpeg_parser, parsers.state, parsers.utils, predicates, regex_utils, serialization, string_utils

---

### parsers.generators
**File:** [parsers/generators.lua](parsers/generators.lua)

Factory functions for creating specialized parsers. Handles parser spec lookup and validation.

**Dependencies:** error_reporting, parsers.state, parsers.utils, predicates, read_only, sparse_sequence, table_utils

---

### parsers.introspection
**File:** [parsers/introspection.lua](parsers/introspection.lua)

Type introspection utilities: `getTypeKind()`, `recordFieldNames()`, `recordFieldTypes()`, `tupleFieldTypes()`, `arrayElementType()`, `mapKVType()`, `unionTypes()`, `isNullable()`.

**Dependencies:** parsers.state, parsers.utils

---

### parsers.lpeg_parser
**File:** [parsers/lpeg_parser.lua](parsers/lpeg_parser.lua)

LPEG-based grammar for lexing and parsing type specification strings. Includes `parsedTypeSpecToStr()` for serialization.

**Dependencies:** parsers.state, parsers.utils

---

### parsers.registration
**File:** [parsers/registration.lua](parsers/registration.lua)

Type registration system: `registerAlias()`, `registerEnumParser()`, type restrictions (`restrictNumber()`, `restrictString()`, `restrictEnum()`, `restrictUnion()`), and default value management.

**Dependencies:** error_reporting, number_identifiers, parsers.generators, parsers.lpeg_parser, parsers.state, parsers.utils, predicates, regex_utils, sandbox, sandbox_env, serialization, string_utils

---

### parsers.schema_export
**File:** [parsers/schema_export.lua](parsers/schema_export.lua)

Exports all registered type definitions as a schema model. Generates structured data describing each type's name, definition, kind, parent, constraints, and enum labels. Enables external tools to understand the type system.

**Dependencies:** parsers.lpeg_parser, parsers.state, table_utils

---

### parsers.state
**File:** [parsers/state.lua](parsers/state.lua)

Shared state and configuration for the parser system. Central registry for parsers, type definitions, logger configuration, and forward reference placeholders.

**Dependencies:** named_logger

---

### parsers.type_parsing
**File:** [parsers/type_parsing.lua](parsers/type_parsing.lua)

Core type parsing logic: `parseType()`, `parse_type()`, handles complex types (tuples, records, arrays, maps, unions, enums) and inheritance via `extends` keyword.

**Dependencies:** parsers.generators, parsers.introspection, parsers.lpeg_parser, parsers.state, parsers.utils, serialization

---

### parsers.utils
**File:** [parsers/utils.lua](parsers/utils.lua)

Low-level utility functions for the parsers module including version management helpers.

**Dependencies:** parsers.state, serialization, table_parsing

---

### predicates
**File:** [predicates.lua](predicates.lua)

Type checking predicate functions for validation (is_string, is_number, is_table, etc.).

**Dependencies:** read_only, string_utils, table_parsing, table_utils

---

### processor_executor

**File:** [processor_executor.lua](processor_executor.lua)

Sandboxed execution of file pre-processors that mutate parsed rows before any
validator runs. Exposes the write helpers `setCell`, `clearCell`, `rowByKey`,
and `dataIndex` to the sandbox, in addition to all read-side helpers inherited
from `validator_helpers`. Pre-processor authors are required to be idempotent
when their spec opts into the future mod-override re-run; the default is a
single run per file. Updates only `cell.parsed`/`cell.evaluated` so the
reformatter preserves the original on-disk text. See [DATA_FORMAT_README §Pre-Processors](DATA_FORMAT_README.md#pre-processors) for the user-facing description.

**Wrapped row arrays preserve the dataset's PK index.** `wrapRowsForProcessor` returns a plain Lua array that also mirrors the dataset's column-1 PK index, so `wrappedRows[someName]` returns the wrapped row for that PK in O(1). The `rowByKey` helper delegates to this index; processor authors should reach for `rowByKey` (or the index directly) rather than scanning rows manually.

**Dependencies:** error_reporting, named_logger, parsers, read_only, sandbox, sandbox_env, table_utils, validator_executor, validator_helpers

---

### raw_eav
**File:** [raw_eav.lua](raw_eav.lua)

Low-level reader/writer for the Entity–Attribute–Value (EAV / "long") table layout: a header-less, tab-separated, 3-column `(entity, attribute, value)` file (canonical extension `.eav`) whose row and column identifiers are domain keys / column names (not indices). `eavToTable` rebuilds the wide table (header + PK rows) from the triples; `tableToEav` compresses a wide table back to triples. EAV files carry no header — it is synthesized on read (key column defaults to `"name"`, overridable via `keyColumn`) and dropped on write. Cells stay strings.

**Dependencies:** raw_tsv, read_only

---

### raw_tsv
**File:** [raw_tsv.lua](raw_tsv.lua)

Low-level TSV/CSV file parsing and writing without type validation. Pure data handling. Includes `transposeRawTSV()` which swaps rows and columns for transposed files. Comment lines in transposed files are converted to `__comment#:comment` placeholder columns (where `#` is a sequential number), which are restored to comment lines when the file is serialized back.

**Dependencies:** file_util, predicates, read_only, string_utils

---

### read_only
**File:** [read_only.lua](read_only.lua)

Creates read-only proxy wrappers for tables to prevent accidental mutations. Used throughout public APIs.

**Dependencies:** table_utils

---

### reformatter
**File:** [reformatter.lua](reformatter.lua)

Reformats TSV data files in-place and exports to multiple formats. Used before committing to ensure consistent formatting. An archive member is a read-only input: the reformatter skips it (via `file_util.resolveArchivePath`) and never writes reformatted bytes back into a container (archive_files.md §5).

**Dependencies:** error_reporting, exporter, file_util, manifest_info, manifest_loader, named_logger, read_only, serialization

---

### regex_utils
**File:** [regex_utils.lua](regex_utils.lua)

Lua pattern to PCRE translation and pattern matching utilities.

**Dependencies:** predicates, read_only, sparse_sequence

---

### round_trip

**File:** [round_trip.lua](round_trip.lua)

Round-trip serialization/deserialization testing utilities. Provides deep equality comparison (with NaN and cycle handling), format-tolerant comparison, and test functions for all serialization formats.

**Dependencies:** deserialization, read_only, serialization

---

### sandbox_env

**File:** [sandbox_env.lua](sandbox_env.lua)

The single owner of the sandbox "safe API surface" — the curated set of Lua builtins, `math`, `string`/`table` subsets, and TabuLua helpers exposed to user code running inside the kikito sandbox. `new(extras)` builds a fresh environment for the five internal sandboxes (validators, processors, code libraries, custom-type `validate` expressions, `transformCells`); `cogGlobals()` builds the same set minus the helper block for cell expressions and COG scripts. Replaces five hand-rolled, drift-prone environment tables.

**Dependencies:** comparators, predicates, read_only, string_utils, table_utils

---

### patch_executor

**File:** [patch_executor.lua](patch_executor.lua)

Tier-A mod-style row patches (`TODO/mod_overrides.md` §4). Applies a patch file (`typeName=patch`, `patchOf=Target.tsv`) to its parent dataset: `add` / `remove` / `update` / `replace` ops keyed by the parent primary key, carried by the patch file's `patchOp` column. `applyPatches` runs after own-package pre-processors and before validators, in package load order (last writer wins). Each patch value is parsed against the patch file's own column type then re-validated against the parent column's parser (so a tier-A0 `widenTo` overlay lets a patch set a value the parent type would reject). The parent dataset is mutated in place via `read_only.unwrap` (append / `table.remove` / cell write); added rows are built with `tsv_model.newDataCell` / `newDataRow`. Returns the set of patched targets so the reformatter can skip them — patches are never baked into parent source.

**Dependencies:** named_logger, parsers, read_only, tsv_model

---

### schema_overlay

**File:** [schema_overlay.lua](schema_overlay.lua)

Tier-A0 mod-style schema overlays (`TODO/mod_overrides.md` §3). A child package declares a `SchemaOverlay` file (`schemaOverlayOf=Target.tsv`) that *loosens* a parent file's column metadata without forking it. `collectOverlays` parses every overlay file in a pre-parse pass and folds the rows into a per-target map: `widenTo` (strictly-wider type, union-composed), `newDefault` (last-writer-wins), and `suppressValidator` + `validatorLevel` (lowest severity wins). `columnOverridesFor` feeds the widen/default overrides into `tsv_model.processTSV` as the target file's header parses; `applyValidatorOverrides` rebinds or drops the matched parent validators just before validation. Overlays are a load-time view only — the declared `type_spec` / `default_expr` are preserved so the reformatter never bakes them into the source.

**Dependencies:** content_pipeline, named_logger, parsers, raw_tsv, read_only, tsv_model, validator_executor

---

### schema_validator

**File:** [schema_validator.lua](schema_validator.lua)

Validates the structure of typed JSON and XML export files. Ensures typed JSON follows the `[size, elem1, ..., [key,val], ...]` table encoding and validates XML element types.

**Dependencies:** read_only

---

### serialization
**File:** [serialization.lua](serialization.lua)

Data serialization to multiple formats: Lua tables, JSON (typed and natural), XML, SQL, and MessagePack. Handles complex nested structures, sparse sequences, and special values (NaN, infinity).

**Dependencies:** named_logger, predicates, read_only, sandbox, sparse_sequence

---

### sparse_sequence
**File:** [sparse_sequence.lua](sparse_sequence.lua)

Sparse array implementation for efficient storage of arrays with gaps. Provides sequence operations and utilities.

**Dependencies:** read_only

---

### string_utils
**File:** [string_utils.lua](string_utils.lua)

String manipulation utilities: split, trim, escape/unescape, and common text processing operations.

**Dependencies:** read_only

---

### table_parsing
**File:** [table_parsing.lua](table_parsing.lua)

Depth-based table parsing utilities for handling nested structures.

**Dependencies:** read_only, error_reporting

---

### table_utils
**File:** [table_utils.lua](table_utils.lua)

Table manipulation utilities: copy, filter, keys, values, merge, and array operations.

**Dependencies:** *(none)*

---

### tsv_diff

**File:** [tsv_diff.lua](tsv_diff.lua)

TSV file comparison tool that compares two TSV files at the data level, understanding columnar structure. Supports order-based (positional) and primary-key-based comparison modes. Features include column mapping for renamed columns, whitespace trimming, case-insensitive comparison, numeric tolerance (epsilon), column filtering (`--only`/`--exclude`), context lines, and configurable output. Works at the raw level (no type parsing). CLI entry point: `lua54 tsv_diff.lua <file1.tsv> <file2.tsv> [options]`. See [TSV_DIFF.md](TSV_DIFF.md) for full documentation.

**Dependencies:** named_logger, raw_tsv, read_only, string_utils, file_util

---

### tsv_model
**File:** [tsv_model.lua](tsv_model.lua)

TSV/CSV loading and parsing with type validation via parsers module. Supports expression evaluation in cells (prefixed with `=`).

**Dependencies:** error_reporting, exploded_columns, named_logger, parsers, predicates, raw_tsv, read_only, string_utils, table_utils

---

### tsv_transcoders
**File:** [tsv_transcoders.lua](tsv_transcoders.lua)

Content-pipeline `transcode` stages that read back the three TSV export variants whose **container** is the native wide TSV (same `name:type` header, columns and rows) but whose **cells** are rendered in an alternate codec: `tsv:lua` (Lua literals), `tsv:json-typed` (self-describing typed JSON) and `tsv:json-natural` (conventional JSON) — the inverses of `exporter.exportLuaTSV` / `exportJSONTSV` / `exportNaturalJSONTSV`. Each is registered with an `id` and **no `extensions`** (they share the `.tsv` extension with native data, so they never auto-fire; `inputExtensions={"tsv"}` is a guard, not a matcher) and is **schema-free** (column names/types come from the file's own header). The forward transforms walk the TSV skeleton with [raw_tsv](#raw_tsv), decode each cell — header cells included, since they too are serialised in the export — via [deserialization](#deserialization), then re-serialise each data cell to the native in-cell form through the column's own [parsers](#parsers) parser, so the output is byte-for-byte the wide TSV any other source for that schema would produce. The reversible `encode` re-parses the wide TSV with [tsv_model](#tsv_model) and re-renders every cell through the matching [serialization](#serialization) serialiser. The reformatter routes a `transcoder`-assigned `.tsv` to this `encode` rather than the native rewrite, so the chosen cell encoding is preserved.

**Dependencies:** deserialization, error_reporting, parsers, raw_tsv, read_only, serialization, string_utils, tsv_model

---

### type_wiring
**File:** [type_wiring.lua](type_wiring.lua)

Registry that attaches behaviour to a file by walking its `extends` chain. Each entry is keyed by a typeName (case-insensitive on lookup). Phase 1 supports a single contribution slot — `onLoad(file, fileType, extends, badVal, loadEnv)` — which `manifest_loader` dispatches via `applyWiring` from the per-file load loop. The dispatch is shallowest-first, fires each ancestor at most once per call, and is safe against cycles in the `extends` map. Companion accessors: `hasOnLoad(typeName, extends)` (used by `files_desc` to decide whether a file requires the second descriptor pass) and `hasOnLoadFor(typeName, extends, ancestorTypeName)` (used by `manifest_loader.registerFileType` to skip records whose type registration is owned by a wired `onLoad`). See [TODO/type_wiring.md](TODO/type_wiring.md) for the full multi-phase plan; later phases add `preProcessors` / `rowValidators` / `fileValidators` slots and a separate `registerModule` API for engine-init declarations.

**Dependencies:** named_logger, read_only

---

### validator_executor

**File:** [validator_executor.lua](validator_executor.lua)

Sandboxed execution engine for row, file, and package validators. Normalizes validator specs (string or `{expr, level}` records), creates sandboxed environments with helper functions and context variables, and interprets validator results. Enforces execution quotas (1000 row, 10000 file, 100000 package). Error-level validators stop on first failure; warn-level validators collect warnings and continue.

**Wrapped row arrays preserve the dataset's PK index.** `wrapRowsForValidation` returns a plain Lua array that also mirrors the dataset's column-1 PK index, so `wrappedRows[someName]` returns the wrapped row for that PK in O(1). Consumers should use this directly instead of building a local name→row map; the [graph_helpers](#graph_helpers) `nameIndex` helper is the right tool when generality over plain-array fixtures is needed.

**Dependencies:** graph_helpers, named_logger, read_only, sandbox, sandbox_env, serialization, validator_helpers

---

### validator_helpers

**File:** [validator_helpers.lua](validator_helpers.lua)

Helper functions available to validator expressions in the sandboxed environment. Provides collection predicates (`unique`, `sum`, `min`, `max`, `avg`, `count`), iteration helpers (`all`, `any`, `none`, `filter`, `find`), and lookup helpers (`lookup`, `groupBy`). All column-based functions operate on cell objects via `.parsed` to extract computed values. `lookup` short-circuits to O(1) when `column` is the PK column and the rows table is PK-indexed (the wrappers from [validator_executor](#validator_executor) and [processor_executor](#processor_executor), or anything from `extractDataRows`); otherwise it falls through to a linear scan, so plain-array test fixtures still work.

**Dependencies:** read_only, serialization

---

### xml_transcoder
**File:** [xml_transcoder.lua](xml_transcoder.lua)

Content-pipeline `transcode` stage that reads TabuLua's own XML export format (`<file>/<header>/<row>`, namespace `urn:tabulua:table:1`) back in as a wide, typed TSV, and re-encodes a wide TSV to that XML. Registered as `id="xml:tabulua"` with **no `extensions`**, so it is selected only when a `Files.tsv` `transcoder` column names it — a stray `.xml` asset is never auto-interpreted (`inputExtensions={"xml"}` is a guard, not a matcher). It is **schema-free**: column names/types come from the file's own `<header>` (`name:type` cells), not a `typeName`. `xmlToTSV` (forward) decodes each typed cell — including composite `<table>` cells — via [deserialization](#deserialization), then re-serialises it to the native in-cell form through the column's own [parsers](#parsers) parser, so every column (scalar or composite) agrees with how the rest of the pipeline represents it. `tsvToXml` (reverse, the reversible `encode`) re-parses the wide TSV with [tsv_model](#tsv_model) and emits the namespaced document via `serialization.serializeXML`, exactly as `exporter.exportXML`. The root namespace is verified on read (defense-in-depth) before the file is treated as data.

**Dependencies:** deserialization, error_reporting, parsers, raw_tsv, read_only, serialization, string_utils, tsv_model

---

## Dependency Graph (Simplified)

```
table_utils (base)
    └── read_only
        └── sparse_sequence
        └── string_utils
        └── number_identifiers
        └── base64
        └── table_parsing
            └── predicates
                └── raw_tsv
                    └── tsv_model

global_reset (base)
    └── named_logger
        └── parsers.state
        └── parsers.utils
            └── parsers.lpeg_parser
            └── parsers.introspection
            └── parsers.generators
                └── parsers.type_parsing
                └── parsers.registration
                    └── parsers.builtin
                        └── parsers (aggregator)
        └── parsers.schema_export

serialization
    └── error_reporting
    └── comparators
    └── deserialization (inverse)
        └── importer
        └── round_trip
            └── export_tester
    └── validator_helpers
        └── validator_executor
            └── processor_executor
            └── manifest_loader

file_util
    └── lua_cog
    └── manifest_info
    └── files_desc
    └── manifest_loader
    └── exporter
    └── reformatter

exploded_columns
    └── tsv_model
    └── exporter
data_set
    └── migration

raw_tsv
    └── raw_eav
        └── eav_transcoder
    └── json_transcoders
    └── tsv_transcoders
    └── lua_transcoder
    └── tsv_diff
    └── ollama_batch

content_pipeline (text-stage registry)
    └── cog_discovery
    └── builtin_content_stages   (also ← compression, json_transcoders, eav_transcoder, tsv_transcoders, lua_transcoder, xml_transcoder)
        └── doc_generator

compression (lazy codec registry, standalone)
schema_validator (standalone)
```

## External Dependencies

These external libraries are required but not listed in module dependencies above:

- **lpeg** - Pattern matching (used by parsers.lpeg_parser)
- **lfs** (LuaFileSystem) - File system operations (used by file_util, named_logger, export_tester)
- **logging** - Logging framework (used by named_logger)
- **dkjson** - JSON encoding/decoding (used by serialization, deserialization, importer, schema_validator, ollama_batch)
- **MessagePack** - MessagePack serialization (used by serialization, deserialization)
- **tableshape** - Table validation (used by predicates)
- **sandbox** - Sandboxed Lua execution (used by lua_cog, manifest_info, serialization, tsv_model, table_parsing, validator_executor)
- **ltcn** - Lua table constructor notation (used by table_parsing)
- **semver** - Semantic versioning (used by parsers and most modules)
- **LuaSocket** - HTTP client (used by ollama_batch for Ollama API calls)
- **lsqlite3** - SQLite3 bindings (optional, used by importer for SQL import)
