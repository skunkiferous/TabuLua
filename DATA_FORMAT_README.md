# Data Format Specification

## Naming Conventions

We assume type names are defined using **Pascal Case** convention. We also assume that type names don't contain dashes (`-`), though underscores (`_`) are allowed.

Data file names should usually represent a type name. Since the type name is normally singular (as it represents *one* value of that type), the type name part of the file name should also be singular.

A type/module can be defined inside another type/module, so the type/module name can be in the form `A.B`, where `B` is a type/module defined inside the type/module `A`.

## Directory Structure

The position in the directory structure should represent the type hierarchy:

- The root of a type hierarchy should be defined directly in the root of the data directory.
- A type extending another type should be in the sub-directory named like that type.
- A type/module `C` defined inside another type/module `B`, in the form `A/B.C` does **not** mean that `B.C` extends `A`. In that case, it just means that `C` is defined in `B`, and `B` extends `A`.

Despite the use of a directory hierarchy, **each complete file name (without its directory) should still be unique**.

## TSV File Format

The file content is defined following the **TSV** (tab-separated-value) convention:

- Column separator is always tab (`\t`)
- String values are never quoted (note: strings need to be quoted if defined inside "complex" types)
- The first row is always the "table headers"
- Character-set is always **UTF-8**
- A single newline (`\n`) should be preferred as a line separator (unlike in normal TSV files)

Since the data files represent tables of values of the same type, and the file name is normally the type name, the column header should represent "fields" of the given type.

To support particular cases, where you would have many columns but just one or a few rows, we also support a "vertical"/"transposed" TSV format. In this case, the first column should be the "table headers", and the other column(s) should be the values. The system recognize this format automatically, by naming the file filename.transposed.tsv instead of filename.tsv

## Column Headers

While the actual type definition will contain all the details about that type, the data file header should contain at least the field names and field types, so someone can competently edit a data file without looking up/knowing the details of the type definition.

- Field names should use **camelCase**, starting with a lower-case letter
- A colon (`:`) separates the field name and the field type
- The field type uses our own type-definition syntax, described below

## Default Values

Columns can specify a default value that applies when a cell is empty. The syntax extends the column header format:

```text
fieldName:fieldType:defaultValue
```

- `defaultValue` is optional
- If present, it is used when a cell in that column is empty
- The default can be a literal value or an expression (starting with `=`)

### Examples

```tsv
quantity:integer:1           # Default to 1
status:string:Unknown        # Default to "Unknown"
total:number:=price*qty      # Computed default using expression
area:number:=self.width*self.height  # Expression referencing other columns
```

### Behavior

| Cell Content | Column Default | Result               |
|--------------|----------------|----------------------|
| Has value    | Any            | Cell value used      |
| Empty        | None           | Empty string         |
| Empty        | Literal        | Default literal      |
| Empty        | Expression     | Evaluated expression |

### Notes

- Default expressions can reference other columns using `self.columnName` or `self[index]`
- Default expressions are subject to the same sandbox restrictions as cell expressions
- The default expression is preserved in reformatted output
- Columns with complex type specs (containing colons like `{a:number,b:string}`) can still have defaults

## Exploded Columns

For complex nested data structures, you can "explode" record and tuple fields across multiple columns using dot-separated column names. This makes data entry easier while still allowing the system to reconstruct the nested structure.

### Syntax

Column names can use dots to represent nested paths:

```text
id:string  location.level:name  location.position._1:integer  location.position._2:integer  location.position._3:integer
item1      zone_a               10                            20                            30
item2      zone_b               -5                            15                            0
```

This implicitly defines a `location` field as:

```text
{level:name, position:{integer,integer,integer}}
```

### Tuple Recognition

Tuple fields are recognized by using `_1`, `_2`, `_3`, etc. as field names. These must be consecutive starting from `_1`.

| Column Pattern | Resulting Type |
|----------------|----------------|
| `pos._1:number`, `pos._2:number` | `pos:{number,number}` (tuple) |
| `data.x:number`, `data.y:number` | `data:{x:number,y:number}` (record) |
| `nested.coords._1:integer`, `nested.coords._2:integer` | `nested:{coords:{integer,integer}}` |

### Accessing Exploded Data

After parsing, you can access the data in two ways:

**Flat access** (original column names):
```lua
row["location.level"]           -- returns the cell
row["location.position._1"]     -- returns the cell
```

**Assembled access** (reconstructed structure):
```lua
row.location                    -- returns {level="zone_a", position={10, 20, 30}}
row.location.level              -- returns "zone_a"
row.location.position[1]        -- returns 10
row.location.position._1        -- returns 10 (tuple alias)
```

The assembled access is computed lazily on first access.

### Export Behavior

When exporting TSV files, the `exportExploded` parameter controls the output format:

| `exportExploded` | Header Output | Cell Output |
|------------------|---------------|-------------|
| `true` (default) | Individual columns: `location.level:name`, `location.position._1:integer`, ... | Individual values: `zone_a`, `10`, `20`, `30` |
| `false` | Collapsed column: `location:{level:name,position:{integer,integer,integer}}` | Lua table literal: `{level="zone_a",position={10,20,30}}` |

Using `exportExploded=true` (the default) preserves round-trip fidelity with the original file format.

### Restrictions

- Each path segment must be a valid identifier (letters, digits, underscores; starting with letter or underscore)
- Tuple indices must start at `_1` and be consecutive (no gaps)
- You cannot have both an exploded column (e.g., `location.level`) and a non-exploded column with the same root name (e.g., `location`)
- All columns in an exploded group share the same root and are processed together

## Type System

The type system is based on the types of Lua. The basic types, which are expected to be the types of most fields/columns, are the following:

### Primitive Types

| Type | Description |
|------|-------------|
| `boolean` | Boolean value (`true` or `false`) |
| `integer` | Integer number |
| `number` | Floating-point value (technically the super-type of integers) |
| `string` | Text string |

### Integer Range Types

The following integer types with range restrictions are available:

| Type | Range |
|------|-------|
| `ubyte` | 0 to 255 |
| `ushort` | 0 to 65,535 |
| `uint` | 0 to 4,294,967,295 |
| `byte` | -128 to 127 |
| `short` | -32,768 to 32,767 |
| `int` | -2,147,483,648 to 2,147,483,647 |
| `long` | 64-bit signed integer |

### Container Types

| Type | Syntax | Description |
|------|--------|-------------|
| Array | `{<type>}` | Ordered collection of values of the same type |
| Map | `{<type1>:<type2>}` | Key-value mapping |
| Tuple | `{<type1>,<type2>,...}` | Fixed-length sequence (must have at least two types) |
| Record | `{<name>:<type>,...}` | Named fields (must have at least two fields) |
| Table | `{}` | Any table (untyped) |

### Union and Enum Types

| Type | Syntax | Description |
|------|--------|-------------|
| Union | `<type1>\|<type2>\|...` | One of several types. Use `nil` as last type for "optional" values. `string` if present must be last (but before `nil`) |
| Enum | `{enum:<label1>\|<label2>\|...}` | Enumerated set of valid string labels |

### Special Types

| Type | Description |
|------|-------------|
| `raw` | Pre-defined union: `boolean\|number\|table\|string\|nil` |
| `nil` | Just the nil value (only used in unions for "optional" values) |
| `true` | Just the true value (only valid as `<type2>` in maps, for Lua-style "sets") |

## Type Inheritance (Extends)

There is another way to define tuples and records using the `extends` syntax:

```
# Tuple inheritance
{extends,<existing-tuple-type>,<type>,...}

# Record inheritance
{extends:<existing-record-type>,<name>:<type>,...}
```

The purpose is to build types using inheritance. Tuples are required to contain at least two types, but since the "parent" tuple must have at least two itself, the extended tuple requires only a single additional type. Similarly, the extended record requires only a single additional field.

**Example:** If you have a record that defines a "vehicle" base type, you can define a "land vehicle" type that extends it:

```
{extends:vehicle,wheels:integer}
```

## String Extension Types

There are multiple types extending `string`:

| Type | Description |
|------|-------------|
| `ascii` | ASCII-only string (all bytes must be in the range 0-127) |
| `asciitext` | Extends `ascii`; can contain escaped tabs and newlines like `text`, but restricted to ASCII characters |
| `asciimarkdown` | Extends `asciitext`; used for markdown-formatted ASCII-only text |
| `comment` | Any string with "comment" semantics (can be optionally stripped from exported data) |
| `text` | Can contain escaped tabs and newlines. Tab is encoded as `\t`, newline as `\n`, and backslash as `\\` |
| `markdown` | Extends `text`; used for markdown-formatted text |
| `cmp_version` | Extends `ascii`; version comparison format: `<op>x.y.z` (e.g., `>=1.0.0`), used for version requirements |
| `http` | Standard HTTP(S) URL format |
| `identifier` | Extends `name`; standard identifier format: `[_a-zA-Z][_a-zA-Z0-9]*` |
| `name` | Extends `ascii`; dotted identifier: `<identifier1>.<identifier2>...<identifierN>` |
| `type` | Extends `ascii`; a `type_spec` which is validated against previously-defined types |
| `type_spec` | Extends `ascii`; represents a type specification using the syntax defined here |
| `version` | Extends `ascii`; standard `x.y.z` version format |

## Numeric Extension Types

| Type | Description |
|------|-------------|
| `percent` | Either `<number>%` (e.g., `50%`) OR `<integer>/<integer>` (e.g., `3/5`). Parsed to a number (50% => 0.5, 3/5 => 0.6) |
| `ratio` | Map `{name:percent}` where all percent values must sum to 1.0 (100%) |

## Comments in Data Files

A comment line can be added anywhere in the data files (except the first line) using the Unix shell comment character (`#`). This must be the first character on that line. By convention, the comment applies to the line below, as in most programming languages. Since the TSV files should always have their header as the first line, that means you cannot "comment" on them that way. Instead, place the comment right under the header, and start it with the caret ^ character, to imply the comment applies to the line *above*. That way, the header line can also have a comment describing the meaning/usage of individual fields.

## Primary Keys

Normally, the first field/column is the "primary key" of the line/row, and its value must be unique among all the lines/rows in that file. Furthermore, the "primary key" should be unique among all instances of a type *or its sub-types*.

When a type has sub-types, all fields of all types should have unique names, unless several fields with the same name in several sub-types also have the same type and the same meaning. This enables a design where a single database table can represent all instances of all sub-types of a type.

## Expression Evaluation

Data files support computed expressions in cell values. An expression is indicated by the `=` prefix:

```
=baseValue * multiplier
=2 * pi * radius
```

Expressions are evaluated in a sandbox context. Data from files with lower `loadOrder` values becomes available for use in expressions in files with higher `loadOrder` values. This is controlled via the `publishContext` and `publishColumn` fields in `Files.tsv`.

## COG Code Generation

TSV files can contain dynamic row generation blocks using COG (Code Generation). Example:

```
###[[[
###local rows = {}
###for i = 1, 5 do
###    rows[#rows+1] = "Row" .. i .. "\t" .. i
###end
###return table.concat(rows, "\n")
###]]]
<generated text comes here>
###[[[end]]]
```

Lines prefixed with `###` inside the COG block are executed as Lua code. The returned string is inserted between the "closing marker" and the "end marker", replacing any previously generated content.

## Type Aliases and Extensions

It is possible to "extend" types in code to add additional validations. The `ratio` type was built this way. It is also possible to define "aliases" for types. Technically, an alias is not a new type, but just a shortcut to save on typing and/or add meaning to the type definition.

Type aliases and custom types can be defined at the package level via the `custom_types` field in `Manifest.transposed.tsv` files. See the [Custom Types](#custom-types) section for details.

## Code Libraries

Packages can define Lua code libraries that are available in expression evaluation and COG code blocks. Libraries provide reusable functions and constants that enhance the expressiveness of data files.

### Declaring Libraries

Libraries are declared in the package manifest via the `code_libraries` field:

| Field | Type | Description |
|-------|------|-------------|
| `code_libraries` | `{{name,string}}\|nil` | Library definitions as name-path pairs |

Example in `Manifest.transposed.tsv`:
```
code_libraries:{{name,string}}|nil	{{'utils','libs/utils.lua'},{'calc','libs/calc.lua'}}
```

- `name`: The key used to access the library in expressions (e.g., `utils.myFunc()`)
- `path`: Relative path from the package directory to the `.lua` file

### Library File Format

Libraries must be Lua files that return a table of exports:

```lua
-- libs/utils.lua
local M = {}

function M.double(x)
    return x * 2
end

M.CONSTANT = 42

return M
```

### Security Constraints

Libraries run in a sandboxed environment with:
- **Limited globals**: Only `math`, `string`, `table`, `pairs`, `ipairs`, `type`, `tostring`, `tonumber`, `select`, `unpack`, `next`, `pcall`, `error`, `assert` are available
- **Operation quota**: 10,000 operations maximum during loading
- **No I/O access**: Cannot read files, access network, or use `require`
- **Immutable exports**: Library exports are made read-only after loading

### Sandbox API

In addition to Lua built-ins, the sandbox exposes a subset of the TabuLua API for use in library code:

#### predicates

All predicate functions are available for validation. These are pure functions that return `true` or `false`.

| Function | Description |
|----------|-------------|
| `isBasic(v)` | Value is number, string, boolean, or nil |
| `isBoolean(v)` | Value is boolean |
| `isNumber(v)` | Value is number |
| `isInteger(v)` | Value is integer type |
| `isIntegerValue(v)` | Value is number with integer value |
| `isPositiveNumber(v)` | Value > 0 |
| `isPositiveInteger(v)` | Value is positive integer |
| `isNonZeroNumber(v)` | Value ~= 0 |
| `isNonZeroInteger(v)` | Integer and value ~= 0 |
| `isString(v)` | Value is string |
| `isNonEmptyStr(v)` | String with length > 0 |
| `isNonBlankStr(v)` | String with non-whitespace content |
| `isBlankStr(s)` | Blank string |
| `isTable(v)` | Value is table |
| `isNonEmptyTable(v)` | Table with at least one key |
| `isFullSeq(t)` | Table is valid sequence (no gaps) |
| `isMixedTable(t)` | Table has both sequence and map parts |
| `isCallable(v)` | Value is function or has `__call` |
| `isDefault(v)` | Value is nil, false, 0, 0.0, "", or {} |
| `isNonDefault(v)` | Value is not a default value |
| `isTrue(v)` | Value is literally `true` |
| `isFalse(v)` | Value is literally `false` |
| `isComparable(v)` | Value is string or number |
| `isIdentifier(s)` | Valid Lua identifier format |
| `isName(s)` | Valid name (identifier or dot-separated identifiers) |
| `isFileName(s)` | Valid file name |
| `isPath(v)` | Valid Unix-style file path |
| `isVersion(v)` | Valid semantic version string |
| `isValidUTF8(s)` | Valid UTF-8 encoding |
| `isValidASCII(s)` | ASCII-only characters |
| `isValidRegex(p)` | Valid Lua pattern |
| `isValidHttpUrl(u)` | Valid HTTP/HTTPS URL |
| `isPercent(v)` | Valid percent format |
| `isValueKeyword(v)` | String is Lua keyword ("nil", "false", "true") |

**Example:**
```lua
local M = {}

function M.isValidScore(v)
    return predicates.isPositiveInteger(v) and v <= 100
end

return M
```

#### stringUtils

Safe string utility functions.

| Function | Description |
|----------|-------------|
| `trim(s)` | Remove leading/trailing whitespace |
| `split(source, delimiter)` | Split string by delimiter into array |
| `parseVersion(version)` | Parse semantic version string into components |

**Example:**
```lua
local M = {}

function M.parseCSV(line)
    return stringUtils.split(line, ",")
end

return M
```

#### tableUtils

Read-only table inspection functions.

| Function | Description |
|----------|-------------|
| `keys(t)` | Return sorted keys of a table |
| `values(t)` | Return values in sorted key order |
| `pairsCount(t)` | Count key-value pairs |
| `longestMatchingPrefix(seq, str)` | Find longest matching prefix in sequence |
| `sortCaseInsensitive(a, b)` | Case-insensitive string comparator |

**Example:**
```lua
local M = {}

function M.hasMinimumFields(t, minCount)
    return tableUtils.pairsCount(t) >= minCount
end

return M
```

#### equals

Deep content equality comparison.

| Function | Description |
|----------|-------------|
| `equals(a, b)` | Deep equality check for any values |

**Example:**
```lua
local M = {}

function M.sameConfig(a, b)
    return equals(a, b)
end

return M
```

### Using Libraries

**In expressions:**
```
=myUtils.double(baseValue)
=mathLib.lerp(0, 100, 0.5)
```

**In COG blocks:**
```
###[[[
###local result = myUtils.double(10) + mathLib.PI
###return tostring(result)
###]]]
```

Note: Library names cannot conflict with existing Lua globals (e.g., don't use `math`, `string`, `table` as library names).

### Library Loading Order

1. Libraries are loaded after the manifest is processed
2. Libraries from dependency packages are available when loading dependent packages
3. Within a package, libraries are loaded in declaration order

## Files.tsv Metadata

The header alone does not give all information about the "type" of a file. The `Files.tsv` file associates metadata with data files. All files must be described in some `Files.tsv` file. Since it is also used to define the order in which files are processed, `Files.tsv` can refer to files in the current directory AND in sub-directories.

### Files.tsv Fields

| Field | Type | Description |
|-------|------|-------------|
| `fileName` | `string` | The path to the file, possibly in a sub-directory |
| `typeName` | `type_spec` | The type of the "records" in this file |
| `superType` | `type_spec\|nil` | The optional super-type of the type of this file |
| `baseType` | `boolean` | Is this file a base-type file? (No super-type) |
| `publishContext` | `name\|nil` | The optional "context" under which the file data is "published" |
| `publishColumn` | `name\|nil` | The optional column of the file that is "published" |
| `loadOrder` | `number` | A number defining the processing order (affects computed expressions) |
| `description` | `text` | The optional description of the file |
| `joinInto` | `name\|nil` | The fileName of the primary file this file joins into |
| `joinColumn` | `name\|nil` | The column name used for joining (defaults to first column if nil) |
| `export` | `boolean\|nil` | Whether to export this file independently (defaults based on joinInto) |
| `joinedTypeName` | `type_spec\|nil` | The type name for the joined result |

### Publishing Data

A data file can define values which are "published" for the purpose of computing expressions. "Published" means that the parsed data becomes available in the Lua context in which expressions are computed.

- If `publishContext` is defined, data is made available in that named context; otherwise, it's in the global context
- If `publishColumn` is defined, the row key is mapped to the value of that column
- Otherwise, if `publishContext` is defined, the row key is mapped to the whole row

It is important that files be processed in an order that guarantees required data is already processed before dependent files.

### File Joining

File joining allows secondary files to be merged into a primary file at export time, using a shared key column. This is useful for:

1. **Multi-Language Translations**: Keep translation files separate for parallel editing while producing a unified export.
2. **Wide Table Management**: Split wide tables with many exploded columns into multiple files for easier editing.
3. **Collaborative Editing**: Allow different team members to work on separate aspects of the data without merge conflicts.

#### Join Configuration

Configure file joining in `Files.tsv`:

- **`joinInto`**: Specifies the primary file this secondary file joins into
- **`joinColumn`**: The column used for matching rows (defaults to first column)
- **`export`**: Whether to export this file independently (defaults to `false` for secondary files)
- **`joinedTypeName`**: Optional type name for the joined result

#### Example: Translations

**Primary file** (`Items.tsv`):
```tsv
id:name	baseValue:integer	weight:number
sword	100	2.5
shield	75	5.0
```

**Secondary file** (`Items.en.tsv`):
```tsv
id:name	description:markdown
sword	A sharp blade for combat.
shield	A sturdy defense tool.
```

**Files.tsv configuration**:
```tsv
fileName:string	typeName:type_spec	...	joinInto:name|nil	joinColumn:name|nil	export:boolean|nil
Items.tsv	Item	...
Items.en.tsv	Item.en	...	Items.tsv	id
```

**Exported result** (when `Items.tsv` is exported):
The export includes columns from both files, merged by the `id` column.

#### Join Semantics

- **LEFT JOIN**: All rows from the primary file are included; matching rows from secondary files add their columns
- **Column Conflicts**: Duplicate column names (except the join column) are errors
- **Unmatched Rows**: Rows in secondary files without a match in the primary file are reported as errors
- **Missing Matches**: If a primary row has no match in a secondary file, those columns are `nil`
- **No Chaining**: Secondary files cannot join into other secondary files (only into primary files)

#### Naming Convention

Recommended naming patterns for secondary files:
- `<Primary>.<purpose>.tsv` for feature splits (e.g., `Items.drops.tsv`)
- `<Primary>.<locale>.tsv` for translations (e.g., `Items.en.tsv`, `Items.de.tsv`)

## Package Manifest (Manifest.transposed.tsv)

Data files can be grouped in "packages" which can be created independently or depend on each other. A `Manifest.transposed.tsv` file can be defined in the package directory to specify package metadata.

Since the file has only a single data row and multiple values can be quite long, a "vertical structure" is used instead of the horizontal TSV format. The first column contains the field name and the second column is the value. This "transposed" TSV format is indicated by the `.transposed.tsv` extension.

### Manifest Fields

| Field | Type | Description |
|-------|------|-------------|
| `package_id` | `package_id` | Package identifier (alias for `name` type) |
| `name` | `string` | Human-readable package name |
| `version` | `version` | Package version (`x.y.z` format) |
| `description` | `markdown` | Package description |
| `url` | `http\|nil` | Source URL for this package |
| `custom_types` | `{custom_type_def}\|nil` | Custom types with data-driven validators (also used for simple type aliases) |
| `code_libraries` | `{{name,string}}\|nil` | Code libraries for expressions and COG |
| `dependencies` | `{{package_id,cmp_version}}\|nil` | Package dependencies with version requirements |
| `load_after` | `{package_id}\|nil` | IDs of packages that must be loaded before this one (if present) |

### Custom Types

Packages can define custom types with data-driven validators. Custom types extend a parent type with optional validation constraints. When no constraints are specified, the custom type acts as a simple type alias.

#### Custom Type Definition

Each custom type is defined as a record with the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `name` | `name` | The name of the custom type (required) |
| `parent` | `type_spec` | The parent type to extend (required) |
| `min` | `number\|nil` | Minimum value (for numeric types) |
| `max` | `number\|nil` | Maximum value (for numeric types) |
| `minLen` | `integer\|nil` | Minimum string length (for string types) |
| `maxLen` | `integer\|nil` | Maximum string length (for string types) |
| `pattern` | `string\|nil` | Lua pattern that strings must match (for string types) |
| `values` | `{string}\|nil` | Allowed values (for enum types) |

#### Constraint Types

Custom types support three categories of constraints, which cannot be mixed:

1. **Numeric constraints** (`min`, `max`): For types extending `number` or `integer`
2. **String constraints** (`minLen`, `maxLen`, `pattern`): For types extending `string`
3. **Enum constraints** (`values`): For types extending an enum type

If no constraints are specified, the custom type becomes a simple alias to the parent type.

#### Example

In `Manifest.transposed.tsv`:

```text
custom_types:{custom_type_def}|nil  {name="positiveInt",parent="integer",min=1},{name="percentage",parent="number",min=0,max=100},{name="shortName",parent="string",minLen=1,maxLen=20}
```

This defines three custom types:

- `positiveInt`: An integer that must be >= 1
- `percentage`: A number between 0 and 100 (inclusive)
- `shortName`: A string with 1 to 20 characters

#### Using Custom Types

Once defined, custom types can be used in file headers just like built-in types:

```text
id:name  level:positiveInt  score:percentage  label:shortName
player1  5                  87.5              Hero
```

#### Type Registration Order

Custom types are registered after the manifest is processed but before code libraries are loaded. This means:

- Custom types can extend built-in types or types from dependency packages
- Custom types from one package are available to dependent packages
- Within a package, custom types are registered in declaration order, so later types can extend earlier ones
