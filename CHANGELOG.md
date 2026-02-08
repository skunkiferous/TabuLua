
# Change Log
All notable changes to this project will be documented in this file.
 
The format is based on [Keep a Changelog](http://keepachangelog.com/)
and this project adheres to [Semantic Versioning](http://semver.org/).
 
## [Unreleased] - yyyy-mm-dd

### Added

### Changed

### Fixed

## [0.5.3] - 2026-02-07

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
- New `ancestor` constraint for custom type definitions. Allows defining types whose values must
  be names of registered types extending a specified ancestor type. For example,
  `{name="numericUnit",ancestor="number"}` accepts only type names like `kilogram` or `metre`
  that extend `number`. When `ancestor` is set, `parent` defaults to `type_spec` (can be
  overridden). Enables the "Quantity pattern" for pairing unit type names with numeric values.
- Tutorial expansion now demonstrates the `ancestor` constraint with an `intTypeName` custom type.
- `extendsOrRestrict()` now recognizes union types as extending a common ancestor when all
  member types extend that ancestor. For example, a union `integer|float` is now recognized
  as extending `number`, and `ubyte|ushort` as extending `integer`. Unions containing `nil`
  are excluded (since `nil` does not extend any base type). This also improves SQL type mapping
  for such unions (e.g., `REAL` instead of `TEXT` for numeric unions).
- Guards in `registerTypesFromSpec` to reject union types as parents for scalar constraints
  (numeric, string, enum, ancestor). Union parents remain valid for expression-based validators.

### Fixed

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
   
### Changed
 
### Fixed
 