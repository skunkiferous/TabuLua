
# Change Log
All notable changes to this project will be documented in this file.
 
The format is based on [Keep a Changelog](http://keepachangelog.com/)
and this project adheres to [Semantic Versioning](http://semver.org/).
 
## [Unreleased] - yyyy-mm-dd

### Added

### Changed

### Fixed

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
 