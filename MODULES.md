# Lua Modules Reference

This document lists all Lua modules in the project alphabetically, with a brief description and their direct local dependencies.

## Module Index

| Module | Description | Dependencies |
|--------|-------------|--------------|
| [base64](#base64) | Pure-Lua RFC 4648 Base64 encode/decode | read_only |
| [comparators](#comparators) | Value comparison and equality functions | read_only, sparse_sequence, table_utils |
| [deserialization](#deserialization) | Data deserialization (Lua, JSON, XML, MessagePack) | read_only |
| [error_reporting](#error_reporting) | Error collection and reporting system | named_logger, read_only, serialization |
| [exporter](#exporter) | Exports parsed data to multiple formats | base64, error_reporting, exploded_columns, file_joining, file_util, named_logger, parsers, predicates, raw_tsv, read_only, serialization, tsv_model |
| [exploded_columns](#exploded_columns) | Handles exploded/collapsed column structures | read_only, table_utils |
| [file_joining](#file_joining) | Joins related TSV files by key columns | read_only, table_utils |
| [export_tester](#export_tester) | Tests exported files via re-import comparison | error_reporting, file_util, importer, manifest_loader, named_logger, read_only, round_trip |
| [file_util](#file_util) | File system operations and path manipulation | named_logger, read_only, table_utils |
| [files_desc](#files_desc) | File descriptor discovery and load order management | file_util, lua_cog, named_logger, parsers, raw_tsv, read_only, table_utils, tsv_model |
| [importer](#importer) | File import system for various formats | deserialization, file_util, named_logger, read_only, string_utils |
| [lua_cog](#lua_cog) | Code generation and templating system | file_util, named_logger, read_only, string_utils |
| [manifest_info](#manifest_info) | Package metadata, versioning, and dependencies | comparators, error_reporting, file_util, lua_cog, named_logger, parsers, predicates, raw_tsv, read_only, string_utils, table_utils, tsv_model |
| [manifest_loader](#manifest_loader) | Package loading orchestration and dependency resolution | error_reporting, file_util, files_desc, lua_cog, manifest_info, parsers, raw_tsv, read_only, table_utils, tsv_model, validator_executor |
| [named_logger](#named_logger) | Logging system with named loggers and levels | *(none)* |
| [number_identifiers](#number_identifiers) | Numeric/string identifier conversion | error_reporting, read_only |
| [parsers](#parsers) | Main entry point for type parsing system | parsers.*, read_only |
| [parsers.builtin](#parsersbuiltin) | Built-in type parsers (boolean, number, string, etc.) | base64, error_reporting, parsers.generators, parsers.lpeg_parser, parsers.state, parsers.utils, predicates, regex_utils, serialization, string_utils |
| [parsers.generators](#parsersgenerators) | Factory functions for specialized parsers | error_reporting, parsers.state, parsers.utils, predicates, read_only, sparse_sequence, table_utils |
| [parsers.introspection](#parsersintrospection) | Type querying and relationship analysis | parsers.state, parsers.utils |
| [parsers.lpeg_parser](#parserslpeg_parser) | LPEG grammar for type specification parsing | parsers.state, parsers.utils |
| [parsers.registration](#parsersregistration) | Type alias and custom parser registration | comparators, error_reporting, number_identifiers, parsers.generators, parsers.lpeg_parser, parsers.state, parsers.utils, predicates, regex_utils, serialization, string_utils, table_utils |
| [parsers.schema_export](#parsersschema_export) | Exports type definitions as a schema model | parsers.lpeg_parser, parsers.state, table_utils |
| [parsers.state](#parsersstate) | Shared state and registries for parser system | named_logger |
| [parsers.type_parsing](#parserstype_parsing) | Core type parsing with inheritance support | parsers.generators, parsers.introspection, parsers.lpeg_parser, parsers.state, parsers.utils, serialization |
| [parsers.utils](#parsersutils) | Utility functions for parsers module | parsers.state, serialization, table_parsing |
| [predicates](#predicates) | Type checking predicate functions | read_only, string_utils, table_parsing, table_utils |
| [raw_tsv](#raw_tsv) | Low-level TSV file parsing and writing | file_util, predicates, read_only, string_utils |
| [read_only](#read_only) | Read-only table proxy wrappers | table_utils |
| [reformatter](#reformatter) | TSV file reformatting and multi-format export | error_reporting, exporter, file_util, manifest_info, manifest_loader, named_logger, read_only, serialization |
| [regex_utils](#regex_utils) | Lua pattern to PCRE translation | predicates, read_only, sparse_sequence |
| [round_trip](#round_trip) | Round-trip serialization/deserialization testing | deserialization, read_only, serialization |
| [schema_validator](#schema_validator) | Validates typed JSON and XML export formats | read_only |
| [serialization](#serialization) | Data serialization (Lua, JSON, XML, SQL, MessagePack) | named_logger, predicates, read_only, sandbox, sparse_sequence |
| [sparse_sequence](#sparse_sequence) | Sparse array implementation | read_only |
| [string_utils](#string_utils) | String manipulation utilities | read_only |
| [table_parsing](#table_parsing) | Depth-based table parsing | read_only, error_reporting |
| [table_utils](#table_utils) | Table manipulation utilities | *(none)* |
| [tsv_model](#tsv_model) | TSV loading with type validation and expressions | error_reporting, exploded_columns, named_logger, parsers, predicates, raw_tsv, read_only, string_utils, table_utils |
| [validator_executor](#validator_executor) | Sandboxed execution of row, file, and package validators | comparators, named_logger, predicates, read_only, sandbox, serialization, string_utils, table_utils, validator_helpers |
| [validator_helpers](#validator_helpers) | Helper functions for validator expressions | read_only, serialization |

---

## Module Details

### base64
**File:** [base64.lua](base64.lua)

Pure-Lua RFC 4648 Base64 encode/decode. Provides `encode()`, `decode()`, and `isValid()` for binary data encoding. Used by `parsers.builtin` for the `base64bytes` type and by `exporter` for binary export conversion.

**Dependencies:** read_only

---

### comparators
**File:** [comparators.lua](comparators.lua)

Value comparison and equality functions for tables and primitive types. Provides custom comparators for sorting and deep equality testing.

**Dependencies:** read_only, sparse_sequence, table_utils

---

### deserialization
**File:** [deserialization.lua](deserialization.lua)

Data deserialization from multiple formats back to Lua values. Supports Lua literals, typed JSON, natural JSON, XML, MessagePack, and SQL BLOBs. Inverse of the serialization module.

**Dependencies:** read_only

---

### error_reporting
**File:** [error_reporting.lua](error_reporting.lua)

Error collection and reporting system using `badVal` handlers instead of exceptions. Provides structured error messages.

**Dependencies:** named_logger, read_only, serialization

---

### exporter
**File:** [exporter.lua](exporter.lua)

Exports parsed TSV data to multiple formats including JSON, Lua tables, XML, SQL, and MessagePack.

**Dependencies:** base64, error_reporting, exploded_columns, file_joining, file_util, named_logger, parsers, predicates, raw_tsv, read_only, serialization, tsv_model

---

### exploded_columns

**File:** [exploded_columns.lua](exploded_columns.lua)

Analyzes and handles "exploded" columns in TSV files where nested structures (records and tuples) are flattened into multiple columns with dot-separated paths like `location.position._1`. Provides functions to detect tuple vs record structures and reassemble nested values.

**Dependencies:** read_only, table_utils

---

### export_tester
**File:** [export_tester.lua](export_tester.lua)

Tests exported files by re-importing them and comparing against original source data. Validates that export/import round-trips preserve data correctly across all supported formats.

**Dependencies:** error_reporting, file_util, importer, manifest_loader, named_logger, read_only, round_trip

---

### file_joining
**File:** [file_joining.lua](file_joining.lua)

Joins related TSV files by key columns, enabling localization and data extension patterns. Secondary files (e.g., `Item.de.tsv`) are joined to primary files (e.g., `Item.tsv`) by matching rows on a join column (typically the first column/ID). Supports language-specific overrides and modular data organization.

**Dependencies:** read_only, table_utils

---

### file_util
**File:** [file_util.lua](file_util.lua)

File system operations including path manipulation, file reading/writing, and directory management.

**Dependencies:** named_logger, read_only, table_utils

---

### files_desc
**File:** [files_desc.lua](files_desc.lua)

Discovers and processes file descriptors from `Files.tsv`, managing file load order and metadata.

**Dependencies:** file_util, lua_cog, named_logger, parsers, raw_tsv, read_only, table_utils, tsv_model

---

### importer
**File:** [importer.lua](importer.lua)

File import system that reads exported data files back into Lua. Supports Lua files, JSON (typed and natural), TSV with various cell formats, XML, MessagePack, and SQL. Auto-detects format from file extension.

**Dependencies:** deserialization, file_util, named_logger, read_only, string_utils

---

### lua_cog
**File:** [lua_cog.lua](lua_cog.lua)

Cogwheel-style code generation and templating system. Processes `###[[[...###]]]` blocks for dynamic content generation.

**Dependencies:** file_util, named_logger, read_only, string_utils

---

### manifest_info
**File:** [manifest_info.lua](manifest_info.lua)

Handles `Manifest.transposed.tsv` files for package metadata, versioning, type aliases, and dependency declarations.

**Dependencies:** comparators, error_reporting, file_util, lua_cog, named_logger, parsers, predicates, raw_tsv, read_only, string_utils, table_utils, tsv_model

---

### manifest_loader
**File:** [manifest_loader.lua](manifest_loader.lua)

Orchestrates package loading: discovers packages, resolves dependencies, registers types, loads data files in order, and runs all validators (row, file, package) after loading.

**Dependencies:** error_reporting, file_util, files_desc, lua_cog, manifest_info, parsers, raw_tsv, read_only, table_utils, tsv_model, validator_executor

---

### named_logger
**File:** [named_logger.lua](named_logger.lua)

Logging system with named loggers, multiple log levels (DEBUG, INFO, WARN, ERROR), and configurable output targets.

**Dependencies:** *(none - uses external `logging` library)*

---

### number_identifiers
**File:** [number_identifiers.lua](number_identifiers.lua)

Converts between numeric and string identifiers with special handling for ranges and ID validation.

**Dependencies:** error_reporting, read_only

---

### parsers
**File:** [parsers.lua](parsers.lua)

Main entry point and public API for the modular type parsing system. Assembles all parser submodules and provides a clean, read-only interface.

**Dependencies:** parsers.builtin, parsers.generators, parsers.introspection, parsers.lpeg_parser, parsers.registration, parsers.schema_export, parsers.state, parsers.type_parsing, parsers.utils, read_only

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

Type introspection utilities: `getTypeKind()`, `recordFieldNames()`, `recordFieldTypes()`, `tupleFieldTypes()`, `arrayElementType()`, `mapKVType()`, `unionTypes()`.

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

**Dependencies:** comparators, error_reporting, number_identifiers, parsers.generators, parsers.lpeg_parser, parsers.state, parsers.utils, predicates, regex_utils, serialization, string_utils, table_utils

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

Reformats TSV data files in-place and exports to multiple formats. Used before committing to ensure consistent formatting.

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

### tsv_model
**File:** [tsv_model.lua](tsv_model.lua)

TSV/CSV loading and parsing with type validation via parsers module. Supports expression evaluation in cells (prefixed with `=`).

**Dependencies:** error_reporting, exploded_columns, named_logger, parsers, predicates, raw_tsv, read_only, string_utils, table_utils

---

### validator_executor

**File:** [validator_executor.lua](validator_executor.lua)

Sandboxed execution engine for row, file, and package validators. Normalizes validator specs (string or `{expr, level}` records), creates sandboxed environments with helper functions and context variables, and interprets validator results. Enforces execution quotas (1000 row, 10000 file, 100000 package). Error-level validators stop on first failure; warn-level validators collect warnings and continue.

**Dependencies:** comparators, named_logger, predicates, read_only, sandbox, serialization, string_utils, table_utils, validator_helpers

---

### validator_helpers

**File:** [validator_helpers.lua](validator_helpers.lua)

Helper functions available to validator expressions in the sandboxed environment. Provides collection predicates (`unique`, `sum`, `min`, `max`, `avg`, `count`), iteration helpers (`all`, `any`, `none`, `filter`, `find`), and lookup helpers (`lookup`, `groupBy`). All column-based functions operate on cell objects via `.parsed` to extract computed values.

**Dependencies:** read_only, serialization

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

named_logger (base)
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
schema_validator (standalone)
```

## External Dependencies

These external libraries are required but not listed in module dependencies above:

- **lpeg** - Pattern matching (used by parsers.lpeg_parser)
- **lfs** (LuaFileSystem) - File system operations (used by file_util, named_logger, export_tester)
- **logging** - Logging framework (used by named_logger)
- **dkjson** - JSON encoding/decoding (used by serialization, deserialization, importer, schema_validator)
- **MessagePack** - MessagePack serialization (used by serialization, deserialization)
- **tableshape** - Table validation (used by predicates)
- **sandbox** - Sandboxed Lua execution (used by lua_cog, manifest_info, serialization, tsv_model, table_parsing, validator_executor)
- **ltcn** - Lua table constructor notation (used by table_parsing)
- **semver** - Semantic versioning (used by parsers and most modules)
- **lsqlite3** - SQLite3 bindings (optional, used by importer for SQL import)
