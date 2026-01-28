# TabuLua - Claude Reference Guide

## Project Overview

TabuLua is a "TSV data system" project written in Lua. The project includes a sophisticated data-driven type system for managing application configuration data, with a focus on game data, via TSV files.

## Project Structure

### Core Modules

#### Type System (Parsers)
The type parsing system is now modular, split across multiple files in the `parsers/` directory:

- **[parsers.lua](parsers.lua)** (~122 lines) - Main entry point and public API
  - Assembles all submodules and initializes the type system
  - Provides a clean, read-only API for type parsing, validation, and introspection

- **[parsers/state.lua](parsers/state.lua)** - Shared state and configuration
  - Central registry for parsers and type definitions
  - Logger configuration
  - Forward reference placeholders

- **[parsers/lpeg_parser.lua](parsers/lpeg_parser.lua)** - LPEG-based grammar
  - Lexing and parsing of type specification strings
  - Type spec serialization (`parsedTypeSpecToStr`)

- **[parsers/type_parsing.lua](parsers/type_parsing.lua)** - Core type parsing logic
  - Main `parseType()` and `parse_type()` functions
  - Type validation and resolution
  - Handles complex types: tuples, records, arrays, maps, unions, enums
  - Inheritance support via `extends` keyword

- **[parsers/introspection.lua](parsers/introspection.lua)** - Type introspection utilities
  - Query type information: `getTypeKind()`, `arrayElementType()`, `mapKVType()`
  - Field extraction: `recordFieldNames()`, `recordFieldTypes()`, `tupleFieldTypes()`
  - Type relationships: `extendsOrRestrict()`, `typeParent()`, `unionTypes()`

- **[parsers/registration.lua](parsers/registration.lua)** - Type registration system
  - Register type aliases and custom parsers
  - Restrict types: `restrictNumber()`, `restrictString()`, `restrictEnum()`, `restrictUnion()`
  - Default value creation and comparator management

- **[parsers/generators.lua](parsers/generators.lua)** - Parser generator functions
  - Factory functions for creating specialized parsers
  - Parser spec lookup and validation

- **[parsers/builtin.lua](parsers/builtin.lua)** - Built-in type parsers
  - Core types: boolean, number, integer, string, text, markdown
  - Extended string types: identifier, name, version, type_spec, http
  - Derived parsers registration

- **[parsers/utils.lua](parsers/utils.lua)** - Utility functions
  - Version management
  - Helper functions

#### Utility Modules
Formerly part of `app_utils.lua`, now split into focused modules:

- **[comparators.lua](comparators.lua)** - Value comparison functions
  - Custom comparators for different types
  - Sorting and equality testing

- **[error_reporting.lua](error_reporting.lua)** - Error handling and reporting
  - Custom error collection system (badVal)
  - Structured error messages

- **[number_identifiers.lua](number_identifiers.lua)** - Numeric identifier utilities
  - Converting between numeric and string identifiers
  - ID validation and formatting

- **[read_only.lua](read_only.lua)** - Immutable table wrappers
  - Read-only table enforcement
  - Protection against accidental mutations

- **[serialization.lua](serialization.lua)** - Data serialization
  - Convert Lua values to/from string representations
  - Handles complex nested structures

- **[sparse_sequence.lua](sparse_sequence.lua)** - Sparse array implementation
  - Efficient storage for arrays with gaps
  - Sequence operations and utilities

- **[string_utils.lua](string_utils.lua)** - String manipulation
  - Common string operations
  - Text processing utilities

- **[table_parsing.lua](table_parsing.lua)** - Table parsing utilities
  - Depth-based table parsing
  - Nested structure handling

- **[table_utils.lua](table_utils.lua)** - Table manipulation
  - Common table operations
  - Array and map utilities

#### Data System Modules

- **[tsv_model.lua](tsv_model.lua)** - TSV/CSV file loading and parsing
  - Loads data files in TSV format (tab-separated, despite .csv extension)
  - Integrates with parsers.lua for type validation

- **[manifest_info.lua](manifest_info.lua)** - Package manifest system
  - Handles Manifest.transposed.tsv files for package metadata
  - Supports versioning, dependencies, type aliases

- **[manifest_loader.lua](manifest_loader.lua)** - Package loading orchestration
  - Find, load, parse and validate all packages and data files
  - Dependency resolution

- **[reformatter.lua](reformatter.lua)** - Data file formatter
  - Uses manifest_loader to load all data files
  - Cleans and reformats data files in-place before committing to git

- **[raw_tsv.lua](raw_tsv.lua)** - Low-level TSV/CSV parsing
  - Basic TSV file reading and writing
  - No type validation (pure data handling)

#### Other Modules

- **[lua_cog.lua](lua_cog.lua)** - Cogwheel-style code generation/templating
- **[file_util.lua](file_util.lua)** - File system utilities
- **[predicates.lua](predicates.lua)** - Type checking predicates
- **[regex_utils.lua](regex_utils.lua)** - Regular expression utilities
- **[files_desc.lua](files_desc.lua)** - Discovers files used in mods
- **[named_logger.lua](named_logger.lua)** - Logging system with named loggers

### Data System

The project uses a sophisticated data-driven architecture described in [DATA_FORMAT_README.md](DATA_FORMAT_README.md).

**File Format**: TSV (tab-separated values) with .tsv extension
- First row: headers in format `fieldName:fieldType`
- Encoding: UTF-8
- Line separator: `\n`
- Comments: lines starting with `#`

**Type System Syntax**:
- Basic types: `boolean`, `integer`, `number`, `string`
- Integer range types: `ubyte`, `ushort`, `uint`, `byte`, `short`, `int`, `long`
- Arrays: `{type}`
- Maps: `{keyType:valueType}`
- Tuples: `{type1,type2,...}` (min 2 types)
- Records: `{name:type,...}` (min 2 fields)
- Unions: `type1|type2|...`
- Enums: `{enum:label1|label2|...}`
- **Inheritance**:
  - Tuples: `{extends,ParentTuple,additionalType,...}`
  - Records: `{extends:ParentRecord,newField:type,...}`

**Extended String Types**:
- `comment` - String with comment semantics (can be stripped from exports)
- `text` - Supports escaped tabs/newlines (`\t`, `\n`, `\\`)
- `markdown` - Markdown text (extends text)
- `identifier` - Standard identifier format
- `name` - Dotted identifier (e.g., `Foo.Bar.Baz`)
- `type_spec` - Type specification string
- `type` - Validated type specification
- `version` - Semantic version (x.y.z)
- `cmp_version` - Version comparison (e.g., `>=1.0.0`)
- `http` - HTTP(S) URL

**Numeric Extension Types**:
- `percent` - Either `50%` or `3/5` format, parsed to decimal (0.5 or 0.6)
- `ratio` - Record `{name:percent}` that must sum to 1.0

**Dynamic Features**:
- **Expression evaluation**: Cells prefixed with `=` are computed (e.g., `=baseValue*2`)
- **COG code generation**: Dynamic row generation via `###[[[...###]]]` blocks

**Data Organization**:
- Files represent record types
- File names use PascalCase (singular)
- Directory hierarchy represents type hierarchy
- [data/Files.tsv](data/Files.tsv) - Metadata and load order for all data files
- [data/Manifest.transposed.tsv](data/Manifest.transposed.tsv) - Core package definition

### Test Suite

All modules have comprehensive test coverage using the Busted framework:

#### Type System Tests
- **[spec/parsers_spec.lua](spec/parsers_spec.lua)** - Comprehensive type system tests
  - Tests all type parsing, validation, and utility functions
  - Type inheritance and extension tests
  - Complex type composition scenarios

#### Utility Module Tests
- **[spec/comparators_spec.lua](spec/comparators_spec.lua)** - Comparator function tests
- **[spec/error_reporting_spec.lua](spec/error_reporting_spec.lua)** - Error handling tests
- **[spec/number_identifiers_spec.lua](spec/number_identifiers_spec.lua)** - Number ID tests
- **[spec/read_only_spec.lua](spec/read_only_spec.lua)** - Immutability tests
- **[spec/serialization_spec.lua](spec/serialization_spec.lua)** - Serialization tests
- **[spec/sparse_sequence_spec.lua](spec/sparse_sequence_spec.lua)** - Sparse array tests
- **[spec/string_utils_spec.lua](spec/string_utils_spec.lua)** - String utility tests
- **[spec/table_depth_parsing_spec.lua](spec/table_depth_parsing_spec.lua)** - Table parsing tests
- **[spec/table_utils_spec.lua](spec/table_utils_spec.lua)** - Table utility tests

#### Data System Tests
- **[spec/tsv_model_spec.lua](spec/tsv_model_spec.lua)** - TSV loading and parsing tests
- **[spec/manifest_info_spec.lua](spec/manifest_info_spec.lua)** - Package manifest system tests
- **[spec/manifest_loader_spec.lua](spec/manifest_loader_spec.lua)** - Package loading tests
- **[spec/files_desc_spec.lua](spec/files_desc_spec.lua)** - File discovery tests

#### Other Tests
- **[spec/lua_cog_spec.lua](spec/lua_cog_spec.lua)** - Code generation tests
- **[spec/file_util_spec.lua](spec/file_util_spec.lua)** - File utility tests
- **[spec/predicates_spec.lua](spec/predicates_spec.lua)** - Predicate function tests
- **[spec/regex_utils_spec.lua](spec/regex_utils_spec.lua)** - Regex utility tests

#### Test Infrastructure
- **Test Runners**: [run_tests.cmd](run_tests.cmd) (Windows), [run_tests.sh](run_tests.sh) (Unix/WSL)
- **Coverage**: Luacov for code coverage analysis
- **Test Utilities**: [create_test_files.lua](create_test_files.lua), [extract_test_errors.lua](extract_test_errors.lua)

### Data Files

Resource hierarchy in [data/](data/) directory:
- `Resource.tsv` - Base resource types
- `Resource/Bulk.tsv` - Bulk resources
- `Resource/Bulk/Food/` - Food items (Cooked, Drink, Fruit, Vegetable, etc.)
- `Resource/Bulk/Substance/` - Materials (Metal, Mineral, Liquid, Textile, etc.)
- `Resource/Counted.tsv` - Countable resources
- `Type/Unit/` - Unit system (SI, Imperial, custom units)
- `Type/CustomType.tsv` - Custom type definitions
- `Shape.tsv` - Shape definitions
- `Constant.tsv` - Game constants

## Key Dependencies

From [wanted-libs.txt](wanted-libs.txt):
- **busted** - Unit testing framework (lunarmodules/busted)
- **luassert** - Assertion library
- **semver** - Semantic versioning (kikito/semver.lua)
- **lpeg** - Pattern matching library
- **lua-sandbox** - Sandboxed execution (kikito/lua-sandbox)
- **luafilesystem** - File system operations

## Game Concept

See [scenario.txt](scenario.txt) for the game narrative:
- Player is a criminal whose clone is sent for survival training
- Respawn mechanic explained by cloning
- Goal: Leave the training area or build self-sustaining base
- Progressive tutorial system ("level gated" training data)
- Alternative revenge-based narrative included

## Working with the Type System

### Inheritance Syntax

**Tuple Inheritance**:
```lua
-- Given: Point2DT = {number,number}
-- Extend to 3D: {extends,Point2DT,number}
-- Results in: {number,number,number}
```

**Record Inheritance**:
```lua
-- Given: Person = {name:string,age:number}
-- Extend: {extends:Person,job:string}
-- Resolves to: {name:string,age:number,job:string}
```

### Parser Architecture

The modular parser architecture provides separation of concerns:

1. **Lexing/Parsing** ([parsers/lpeg_parser.lua](parsers/lpeg_parser.lua))
   - LPEG-based grammar parses type spec strings into tables
   - Serialization back to strings

2. **Type Parsing** ([parsers/type_parsing.lua](parsers/type_parsing.lua))
   - Main `parse_type()` and `parseType()` functions
   - Type validation and resolution
   - Inheritance expansion

3. **Registration** ([parsers/registration.lua](parsers/registration.lua))
   - Type aliases and custom parser registration
   - Type restriction and validation
   - Default value creation

4. **Introspection** ([parsers/introspection.lua](parsers/introspection.lua))
   - Query type properties and relationships
   - Field extraction and type analysis

5. **State Management** ([parsers/state.lua](parsers/state.lua))
   - Centralized parser registry
   - Forward reference resolution
   - Shared configuration

Key functions:
- `parseType()` - Public API for parsing type specifications
- `parse_type()` - Internal parsing implementation
- `parsedTypeSpecToStr()` - Serializes parsed types back to strings
- `extendsOrRestrict()` - Identifies inheritance/restriction in types
- `getTypeKind()` - Returns the kind of type (record, tuple, array, etc.)
- `recordFieldNames()`, `recordFieldTypes()` - Extract record information
- `tupleFieldTypes()` - Extract tuple field types
- `arrayElementType()`, `mapKVType()` - Extract container type information

## Running Lua and Tests

**IMPORTANT FOR AI ASSISTANTS**: Commands like `lua`, `lua54`, and `busted` are NOT in PATH.
You must use full paths when running from BASH/MSYS2.

### From BASH/MSYS2 (AI Assistant Environment)

```bash
# Run a Lua script
lua54 script.lua
# OR with full path if lua54 doesn't work:
/c/lua/lua54.exe script.lua

# Run ALL tests in spec/ directory
/c/lua/systree/bin/busted.bat

# Run a specific test file
/c/lua/systree/bin/busted.bat spec/round_trip_spec.lua

# Run tests matching a pattern
/c/lua/systree/bin/busted.bat --pattern=parsers

# Run Lua with inline code
lua54 -e "print('hello')"
```

### From Windows CMD (Recommended for Full Test Suite)

```cmd
REM Run all tests with coverage
game\run_tests.cmd
```

**Note**: The project dependencies don't install properly via luarocks in BASH/MSYS2.
Use Windows CMD with `run_tests.cmd` for reliable full test execution with coverage.

### Checking Test Coverage
```bash
# Coverage stats in luacov.stats.out
# Report generation with luacov
```

### Testing Type Parser Manually
```lua
local parsers = require("parsers")
local result = parsers.parseType("{name:string,age:number}")
```

## Notes for AI Assistant

1. **Modular Architecture**: The codebase is now highly modular:
   - Type system split across 8 files in `parsers/` directory
   - Former `app_utils.lua` split into 9 focused modules
   - Each module has a single, clear responsibility

2. **Test-Driven**: The codebase has comprehensive test coverage:
   - Each module has corresponding spec file
   - Use Busted framework for testing
   - Check relevant spec files for expected behavior

3. **Error Handling**: Uses a custom error collection system
   - `badVal` errors instead of exceptions
   - Implemented in [error_reporting.lua](error_reporting.lua)

4. **Logging**: Uses custom `named_logger` module with log levels

5. **Forward References**: The parsers module uses forward references for mutual recursion
   - References wired up in [parsers.lua](parsers.lua) initialization
   - See `state.refs` in [parsers/state.lua](parsers/state.lua)

6. **Read-Only Tables**: Exported tables use `readOnly()` wrapper for immutability
   - Implemented in [read_only.lua](read_only.lua)
   - All public APIs are read-only

7. **Type System Philosophy**: The type system mimics Lua's native types but adds structure for data validation

8. **TSV Format**: Files are in TSV (tab-separated) format

9. **Modular Development**: When working with the type system:
   - State and configuration: [parsers/state.lua](parsers/state.lua)
   - Parsing logic: [parsers/type_parsing.lua](parsers/type_parsing.lua)
   - Type queries: [parsers/introspection.lua](parsers/introspection.lua)
   - Type registration: [parsers/registration.lua](parsers/registration.lua)
   - Built-in types: [parsers/builtin.lua](parsers/builtin.lua)

## Benefits of the Refactoring

1. **Improved Maintainability**: Each module has a clear, focused purpose
2. **Better Testability**: Smaller modules are easier to test comprehensively
3. **Reduced Coupling**: Dependencies are explicit and minimal
4. **Enhanced Readability**: ~100-700 line modules vs ~3000+ line monoliths
5. **Easier Collaboration**: Multiple developers can work on different modules
6. **Clearer API**: Public API clearly separated from internal implementation
