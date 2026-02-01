
# Change Log
All notable changes to this project will be documented in this file.
 
The format is based on [Keep a Changelog](http://keepachangelog.com/)
and this project adheres to [Semantic Versioning](http://semver.org/).
 
## [Unreleased] - yyyy-mm-dd

### Added

### Changed

### Fixed

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
 