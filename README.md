# TabuLua

A typed TSV (Tab-Separated Values) data system for Lua with schema validation, inheritance, expressions, and code generation.

## Why TabuLua?

TabuLua provides a robust way to define, validate, and manage structured data in TSV files. It's particularly suited for game development, configuration management, and any domain where human-readable data files, appropriate for non-technical users, need strong typing and validation. Additionally, a line-oriented format is ideal for tracking changes over time in a version control system.

## Features

- **Rich Type System** - Primitives, arrays, maps, tuples, records, unions, and enums
- **Type Inheritance** - Extend existing types with additional fields
- **Expression Evaluation** - Compute cell values dynamically (e.g., `=baseValue * 2`)
- **Code Generation (COG)** - Generate rows programmatically with embedded Lua
- **Module System** - Organize data into modules with dependencies and versioning
- **Multi-Format Export** - Export to JSON, Lua tables, XML, SQL, and MessagePack
- **Comprehensive Validation** - Catch type errors before runtime

## Quick Example

A simple TSV data file with typed columns:

```tsv
name:name	displayName:text	count:integer	price:number	available:boolean
sword	Iron Sword	5	25.99	true
shield	Wooden Shield	3	12.50	true
potion	Health Potion	50	5.00	true
```

With expression evaluation:

```tsv
name:name	value:number	computed:number
base	100.0	=base
multiplier	2.5	=multiplier
result	0	=base * multiplier
```

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
| [DATA_FORMAT_README.md](DATA_FORMAT_README.md) | Complete data format specification |
| [MODULES.md](MODULES.md) | Module reference with dependencies |
| [CLAUDE.md](CLAUDE.md) | Detailed architecture guide |

## Project Structure

```
tabulua/
├── parsers/              # Type system implementation
│   ├── builtin.lua       # Built-in types (string, number, etc.)
│   ├── type_parsing.lua  # Core parsing logic
│   ├── introspection.lua # Type querying utilities
│   └── ...
├── demo/                 # Example package demonstrating all features
│   ├── Manifest.transposed.tsv  # Package manifest
│   ├── Files.tsv         # File registry
│   ├── Constant.tsv      # Expression examples
│   ├── Item.tsv          # Complex types example
│   ├── Generated.tsv     # COG code generation example
│   └── Status.tsv        # Enum example
├── spec/                 # Test suite
├── parsers.lua           # Main type system API
├── manifest_loader.lua   # Package loading orchestration
├── tsv_model.lua         # TSV parsing with validation
└── reformatter.lua       # Data file reformatter and exporter
```

## Key Modules

| Module | Purpose |
|--------|---------|
| `parsers` | Type parsing, validation, and introspection |
| `manifest_loader` | Load packages with dependency resolution |
| `tsv_model` | Parse TSV files with type validation |
| `manifest_info` | Handle `Manifest.transposed.tsv` files for package metadata |
| `reformatter` | Reformat and export data files |
| `exporter` | Export to JSON, Lua, XML, SQL, MessagePack |

See [MODULES.md](MODULES.md) for the complete module reference.

## Type System

### Basic Types

```
boolean, integer, number, string
```

### Integer Range Types

```
ubyte (0-255), ushort, uint, byte, short, int, long
```

### Container Types

```lua
{string}              -- Array of strings
{string:number}       -- Map from string to number
{number,string}       -- Tuple (number, string)
{name:string,age:number}  -- Record with named fields
```

### Union and Optional Types

```lua
string|nil            -- Optional string
number|string         -- Number or string
```

### Enums

```lua
{enum:Active|Inactive|Pending}
```

### Type Inheritance

```lua
-- Extend a record type
{extends:Vehicle,wheels:integer}

-- Extend a tuple type
{extends,Point2D,number}
```

### Extended String Types

| Type | Description |
|------|-------------|
| `text` | Supports `\t`, `\n`, `\\` escapes |
| `markdown` | Markdown-formatted text |
| `identifier` | Valid Lua identifier |
| `name` | Dotted identifier (e.g., `Foo.Bar`) |
| `version` | Semantic version (`1.0.0`) |
| `http` | HTTP(S) URL |

## Demo Module

The `demo/` directory contains a complete example module showcasing all TabuLua features:

### Constant.tsv - Expression Evaluation

```tsv
name:name	value:number
pi	3.14159265359
radius	10.0
circumference	=2*pi*radius
area	=pi*radius*radius
```

Expressions (prefixed with `=`) are evaluated in a sandbox. Earlier rows become available to later expressions via the `publishColumn` mechanism.

### Item.tsv - Complex Types

```tsv
name:name	tags:table|nil	composition:ratio|nil	metadata:table|nil
sword	{"weapon","melee"}		{damage=15}
alloy	{"material"}	Copper="88%",Tin="12%"	{hardness=80}
```

Demonstrates arrays, records, optional fields, and the `ratio` type (percentages that must sum to 100%).

### Generated.tsv - Code Generation

```tsv
name:name	level:integer
###[[[
###local rows = {}
###for i = 1, 5 do
###    rows[#rows+1] = "item" .. i .. "\t" .. (i * 10)
###end
###return table.concat(rows, "\n")
###]]]
item1	10
item2	20
item3	30
item4	40
item5	50
###[[[end]]]
```

COG blocks generate rows dynamically. The code between `###[[[` and `###]]]` runs as Lua, and its output replaces the content before `###[[[end]]]`.

### Status.tsv - Enums

```tsv
id:name	label:string
Active	Active
Inactive	Inactive
Pending	Pending
Archived	Archived
```

Defines an enum type that can be referenced in other files as `Status`.

## Package System

### Creating a Package

Create a `Manifest.transposed.tsv` file with package metadata:

```tsv
package_id:package_id	my.package
name:string	My Package
version:version	1.0.0
description:markdown	A description of what this package does.
dependencies:{{package_id,cmp_version}}|nil	{{'core','>=1.0.0'}}
custom_types:{custom_type_def}|nil	{name="MyAlias",parent="string|nil"}
```

### Files.tsv Registry

Every package needs a `Files.tsv` to register its data files:

```tsv
fileName:string	typeName:type_spec	loadOrder:number	description:text
Item.tsv	Item	100	Game items
Recipe.tsv	Recipe	200	Crafting recipes (can reference Items)
```

The `loadOrder` determines processing sequence, which matters for expressions that reference data from other files.

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
# Windows (from the .antlr directory)
cd .antlr
build_test.cmd

# Linux/macOS/WSL (from the .antlr directory)
cd .antlr
./build_test.sh
```

**Prerequisites:**
- Java JDK installed
- Download `antlr-4.13.2-complete.jar` from https://www.antlr.org/download/antlr-4.13.2-complete.jar into the `.antlr` directory
- Run the reformatter with an export option first to generate `exported/schema.tsv`

The test scripts will:
1. Generate the ANTLR parser from `TypeSpec.g4`
2. Compile the parser and test harness
3. Parse all type specifications from `exported/schema.tsv` and report any failures

## Basic Usage

### Command Line (Recommended)

The easiest way to use TabuLua is via the `reformatter.lua` CLI tool:

```bash
# Validate and reformat files in-place
lua reformatter.lua demo/ demo/

# Export to JSON
lua reformatter.lua --json demo/

# Export to multiple formats
lua reformatter.lua --json --lua --xml --export-dir=output demo/

# See all options
lua reformatter.lua
```

### Programmatic Usage

```lua
local manifest_loader = require("manifest_loader")
local parsers = require("parsers")

-- Process all files in directories (validates, parses, evaluates expressions)
local result = manifest_loader.processFiles({"./data", "./demo"})

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

### Export Formats

TabuLua can export to multiple formats via CLI flags or the `exporter` module:

| Flag | Format | Output |
|------|--------|--------|
| `--json` | JSON arrays | `[[headers],[row1],...]` |
| `--lua` | Lua tables | `return {{headers},{row1},...}` |
| `--xml` | XML document | `<file><header>...</header><row>...</row></file>` |
| `--jsontsv` | TSV with JSON values | TSV where complex cells are JSON |
| `--luatsv` | TSV with Lua values | TSV where complex cells are Lua literals |
| `--jsonsql` | SQL with JSON columns | INSERT statements, tables as JSON |
| `--msgpack` | MessagePack binary | Compact binary format |

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
