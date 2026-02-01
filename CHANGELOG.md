
# Change Log
All notable changes to this project will be documented in this file.
 
The format is based on [Keep a Changelog](http://keepachangelog.com/)
and this project adheres to [Semantic Versioning](http://semver.org/).
 
## [Unreleased] - yyyy-mm-dd

### Added

### Changed

### Fixed

## [0.3.0] - 2026-02-01

### Added

- Custom types with data-driven validators via `custom_types` manifest field
  - Numeric constraints: `min`, `max` for types extending `number` or `integer`
  - String constraints: `minLen`, `maxLen`, `pattern` for types extending `string`
  - Enum constraints: `values` for restricting enum types
  - Types without constraints act as simple type aliases
- New `registerTypesFromSpec()` function in parsers module for programmatic type registration
- New `custom_type_def` built-in record type for manifest parsing
- Demo file `CustomTypes.tsv` demonstrating custom type validators
- Comprehensive test suite for custom type registration

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
 