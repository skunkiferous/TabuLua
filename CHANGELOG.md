
# Change Log
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/)
and this project adheres to [Semantic Versioning](http://semver.org/).

## [Unreleased] - yyyy-mm-dd

### Added

### Changed

### Fixed

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

### Changed

### Fixed

## [0.9.0] - 2026-02-21

### Added

- Directory exploration now automatically skips hidden files and directories (names
  starting with `"."`, e.g. `.git`, `.env`). Skipped entries are logged at INFO level.

### Changed

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
   
### Changed
 
### Fixed
 