# TabuLua

A typed TSV (Tab-Separated Values) data system for Lua with schema validation, inheritance, expressions, and code generation.

## Why TabuLua?

TabuLua provides a robust way to define, validate, and manage structured data in TSV files. It's particularly suited for game development, configuration management, and any domain where human-readable data files, appropriate for non-technical users, need strong typing and validation. Additionally, a line-oriented format is ideal for tracking changes over time in a version control system.

## Features

- **Rich Type System** - Primitives, arrays, maps, tuples, records, unions, and enums
- **Type Inheritance** - Extend existing types with additional fields
- **Expression Evaluation** - Compute cell values dynamically (e.g., `=baseValue * 2`)
- **Code Generation (COG)** - Generate rows programmatically with embedded Lua
- **Package System** - Organize data into packages with dependencies and versioning
- **Multi-Format Export** - Export to JSON, Lua tables, XML, SQL, and MessagePack
- **Comprehensive Validation** - Custom types, row/file/package validators

## Quick Example

A simple TSV data file with typed columns:

```tsv
name:name	displayName:text	count:integer	price:float	available:boolean
sword	Iron Sword	5	25.99	true
shield	Wooden Shield	3	12.50	true
potion	Health Potion	50	5.00	true
```

Column headers use the format `fieldName:fieldType`. The first column is the primary key. See [DATA_FORMAT_README.md](DATA_FORMAT_README.md) for the full type system and data format specification.

## Installation

### Requirements

- **Lua 5.4**
- **LuaRocks** (for dependency management)

### Dependencies

Install the required LuaRocks packages:

```bash
# Core dependencies
luarocks install lpeg
luarocks install luafilesystem
luarocks install lualogging
luarocks install dkjson
luarocks install lua-messagepack
luarocks install tableshape
luarocks install lua-sandbox
luarocks install ltcn
luarocks install semver

# For running tests
luarocks install busted
luarocks install luassert
luarocks install luacov
```

### Clone and Use

```bash
git clone https://github.com/skunkiferous/tabulua.git
cd tabulua
```

## Documentation

| Document | Description |
|----------|-------------|
| [DATA_FORMAT_README.md](DATA_FORMAT_README.md) | Complete data format and type system specification |
| [tutorial/README.md](tutorial/README.md) | Hands-on tutorial with RPG-themed example packages |
| [REFORMATTER.md](REFORMATTER.md) | CLI tool and export format reference |
| [AGENTS.md](AGENTS.md) | Detailed architecture guide, designed to help AI Agents |
| [CHANGELOG.md](CHANGELOG.md) | List of changes in each version |
| [MODULES.md](MODULES.md) | Module reference with dependencies |

## Basic Usage

### Command Line (Recommended)

The easiest way to use TabuLua is via the `reformatter.lua` CLI tool:

```bash
# Validate and reformat files in-place (specify package directories directly)
lua reformatter.lua tutorial/core/ tutorial/expansion/

# Export to JSON
lua reformatter.lua --file=json tutorial/core/ tutorial/expansion/

# Export to multiple formats
lua reformatter.lua --file=json --file=lua --file=xml --export-dir=output tutorial/core/ tutorial/expansion/

# See all options
lua reformatter.lua
```

**Note:** Always specify package directories (containing `Manifest.transposed.tsv` or `Files.tsv`) directly, not parent directories.

Refer to [REFORMATTER.md](REFORMATTER.md) for the full list of export formats and options.

### Running from a Separate Data Directory (Windows)

If your data lives in its own repository or folder outside the TabuLua directory, copy [`reformatter_example.cmd`](reformatter_example.cmd) into your data directory and rename it to `reformatter.cmd`. Then open it and set the two variables at the top:

```bat
REM Path to your TabuLua installation
set TABULUA_DIR=%~dp0..\TabuLua

REM Lua 5.4 executable name (adjust if needed)
set LUA=lua54
```

After that, run it from your data directory:

```bat
REM Validate and reformat files in-place
reformatter.cmd .

REM Export to JSON
reformatter.cmd --file=json .

REM Export to multiple formats
reformatter.cmd --file=json --file=lua --export-dir=build\data .
```

The script sets `LUA_PATH` automatically so Lua can find all TabuLua modules — no changes to your system environment are needed.

### Programmatic Usage

```lua
local manifest_loader = require("manifest_loader")
local parsers = require("parsers")

-- Process all files in directories (validates, parses, evaluates expressions)
-- Specify package directories directly, not parent directories
local result = manifest_loader.processFiles({"./tutorial/core", "./tutorial/expansion"})

if result then
    -- result.tsv_files: table mapping file paths to parsed TSV data
    -- result.raw_files: table mapping file paths to raw content
    -- result.packages: table of package metadata keyed by package_id
    -- result.package_order: array of package_ids in load order

    -- Access a specific file's data
    for file_path, tsv in pairs(result.tsv_files) do
        print("File:", file_path)
        -- tsv[1] is the header row
        -- tsv[2..n] are data rows
        for i = 2, #tsv do
            local row = tsv[i]
            -- Access by column name or index
            -- row[1].parsed, row["name"].parsed, etc.
        end
    end
end

-- Parse a type specification directly
local nullBadVal = require("error_reporting").nullBadVal
local type_info = parsers.parseType(nullBadVal, "{name:string,age:integer}")
```

## Project Structure

```
tabulua/
├── parsers/              # Type system implementation
│   ├── builtin.lua       # Built-in types (string, float, etc.)
│   ├── type_parsing.lua  # Core parsing logic
│   ├── introspection.lua # Type querying utilities
│   └── ...
├── tutorial/             # Example packages demonstrating all features
│   ├── core/             # Core game data package
│   │   ├── Manifest.transposed.tsv  # Package manifest
│   │   ├── Files.tsv     # File registry
│   │   └── ...           # Data files (Items, Creatures, Spells, etc.)
│   └── expansion/        # Expansion package (depends on core)
│       ├── Manifest.transposed.tsv  # Expansion manifest
│       ├── Files.tsv     # Expansion file registry
│       └── ...           # Expansion data files
├── spec/                 # Test suite
├── parsers.lua           # Main type system API
├── manifest_loader.lua   # Package loading orchestration
├── tsv_model.lua         # TSV parsing with validation
└── reformatter.lua       # Data file reformatter and exporter
```

## Running Tests

```bash
# Windows
run_tests.cmd

# Unix/WSL
./run_tests.sh

# Or directly with busted
busted spec/
```

### Testing the TypeSpec Grammar

The type specification syntax is defined in an ANTLR4 grammar file (`TypeSpec.g4`). To test the grammar parser against exported schema files:

```bash
# Windows (from the antlr directory)
cd antlr
build_test.cmd

# Linux/macOS/WSL (from the antlr directory)
cd antlr
./build_test.sh
```

**Prerequisites:**
- Java JDK installed
- Download `antlr-4.13.2-complete.jar` from https://www.antlr.org/download/antlr-4.13.2-complete.jar into the `antlr` directory
- Run the reformatter with an export option first to generate `exported/schema.tsv`

The test scripts will:
1. Generate the ANTLR parser from `TypeSpec.g4`
2. Compile the parser and test harness
3. Parse all type specifications from `exported/schema.tsv` and report any failures

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please ensure:

1. All tests pass (`busted spec/`)
2. New features include tests
3. Code follows existing patterns

## Acknowledgments

TabuLua was built with these excellent Lua libraries:

- [LPeg](http://www.inf.puc-rio.br/~roberto/lpeg/) - Parsing Expression Grammars
- [LuaFileSystem](https://lunarmodules.github.io/luafilesystem/) - File system operations
- [lua-sandbox](https://github.com/kikito/lua-sandbox) - Safe expression evaluation
- [tableshape](https://github.com/leafo/tableshape) - Table validation
- [semver](https://github.com/kikito/semver.lua) - Semantic versioning
- [dkjson](http://dkolf.de/src/dkjson-lua.fsl/) - JSON encoding/decoding
