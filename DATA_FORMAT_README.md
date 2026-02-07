# Data Format Specification

## Naming Conventions

We assume type names are defined using **Pascal Case** convention. We also assume that type names don't contain dashes (`-`), though underscores (`_`) are allowed.

Data file names should usually represent a type name. Since the type name is normally singular (as it represents *one* value of that type), the type name part of the file name should also be singular.

A type/package can be defined inside another type/package, so the type/package name can be in the form `A.B`, where `B` is a type/package defined inside the type/package `A`.

## Directory Structure

The position in the directory structure should represent the type hierarchy:

- The root of a type hierarchy should be defined directly in the root of the data directory.
- A type extending another type should be in the sub-directory named like that type.
- A type/package `C` defined inside another type/package `B`, in the form `A/B.C` does **not** mean that `B.C` extends `A`. In that case, it just means that `C` is defined in `B`, and `B` extends `A`.

Despite the use of a directory hierarchy, **each complete file name (without its directory) should still be unique**.

## TSV File Format

The file content is defined following the **TSV** (tab-separated-value) convention:

- Column separator is always tab (`\t`)
- String values are never quoted (note: strings need to be quoted if defined inside "complex" types)
- The first row is always the "table headers"
- Character-set is always **UTF-8**
- A single newline (`\n`) should be preferred as a line separator (unlike in normal TSV files)

Since the data files represent tables of values of the same type, and the file name is normally the type name, the column header should represent "fields" of the given type.

To support particular cases, where you would have many columns but just one or a few rows, we also support a "vertical"/"transposed" TSV format. In this case, the first **column** should be the "table headers", and the other column(s) should be the values. The system recognize this format automatically, by naming the file filename.transposed.tsv instead of filename.tsv

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
total:float:=price*qty      # Computed default using expression
area:float:=self.width*self.height  # Expression referencing other columns
```

### Behavior

| Cell Content | Column Default | Result               |
|--------------|----------------|----------------------|
| Has value    | Any            | Cell value used      |
| Empty        | None           | Depends on type def. |
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
It is specified with the `--collapse-exploded` flag (meaning `exportExploded=false`) when reformatting.

### Collection Columns (Bracket Notation)

In addition to dot-separated paths for records and tuples, exploded columns support **bracket notation** for arrays and maps:

**Array elements:**

```text
items[1]:string  items[2]:string  items[3]:string
apple            banana           cherry
```

This defines `items` as `{string}` (an array of strings).

**Map key-value pairs:**

```text
stats[1]:string  stats[1]=:integer  stats[2]:string  stats[2]=:integer
health           100                mana             50
```

This defines `stats` as `{string:integer}` (a map from string to integer). The `=` suffix on a bracket column marks it as the map value; the column without `=` is the map key.

**Nested collections:**

```text
player.inventory[1]:string  player.inventory[2]:string
sword                       shield
```

This defines `player` as a record containing an `inventory` array: `{inventory:{string}}`.

#### Collection Rules

- Indices must be positive integers starting at 1
- Indices must be consecutive (no gaps)
- For maps, each index must have both a key column (`name[N]`) and a value column (`name[N]=`)
- All elements in an array must have the same type
- All keys and all values in a map must have consistent types

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
| `integer` | Integer number (safe range for JSON/LuaJIT compatibility: ±2^53) |
| `float` | Floating-point number (input can be any numeric format; always reformatted with a decimal point, e.g., `5` becomes `5.0`) |
| `string` | Text string |

> **Note:** The `number` type exists as the parent type of both `integer`, `float`, and `long`, but direct usage of `number` in column types is deprecated. Use `float` for decimal values, `integer` for common whole numbers, or `long` when full 64-bit precision is required. This ensures consistent formatting and better compatibility across Lua versions.

### Integer Range Types

The following integer types with range restrictions are available:

| Type | Range | Notes |
|------|-------|-------|
| `ubyte` | 0 to 255 | Extends `integer` |
| `ushort` | 0 to 65,535 | Extends `integer` |
| `uint` | 0 to 4,294,967,295 | Extends `integer` |
| `byte` | -128 to 127 | Extends `integer` |
| `short` | -32,768 to 32,767 | Extends `integer` |
| `int` | -2,147,483,648 to 2,147,483,647 | Extends `integer` |
| `long` | Full 64-bit signed integer | **Extends `number` directly** |

#### The `integer` vs `long` Distinction

The `integer` type is restricted to the "safe integer" range (±9,007,199,254,740,992 or ±2^53). This range ensures that values can be exactly represented as IEEE 754 double-precision floating-point numbers, making them compatible with:

- **JSON**: All JSON numbers are IEEE 754 doubles
- **LuaJIT**: Uses doubles for all numeric values
- **JavaScript**: Uses doubles for all numbers

The `long` type extends `number` directly (not `integer`) and supports the full 64-bit signed integer range on Lua 5.3+. Use `long` only when you specifically need values outside the safe integer range, such as:

- Database auto-increment IDs that exceed 2^53
- 64-bit timestamps
- Snowflake IDs
- Very large counters

> **Platform Note:** On LuaJIT, `long` is limited to the safe integer range because LuaJIT cannot precisely represent 64-bit integers without using FFI.

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
| `any` | Tagged union: `{type,raw}` — a tuple storing both the type name and the raw value, validated to ensure the value matches the declared type |
| `nil` | Just the nil value (only used in unions for "optional" values) |
| `true` | Just the true value (only valid as `<type2>` in maps, for Lua-style "sets") |
| `package_id` | Alias for `name`; used as the package identifier in manifests |

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
| `base64bytes` | Extends `ascii`; base64-encoded binary data (RFC 4648 standard alphabet with `=` padding). Normalized via decode+encode round-trip. Exported as native binary in MessagePack and BLOB in SQL |
| `comment` | Any string with "comment" semantics (can be optionally stripped from exported data) |
| `hexbytes` | Extends `ascii`; hex-encoded binary data (characters `0-9`, `A-F`, even length). Always reformatted to uppercase. Exported as native binary in MessagePack and BLOB in SQL |
| `text` | Can contain escaped tabs and newlines. Tab is encoded as `\t`, newline as `\n`, and backslash as `\\` |
| `markdown` | Extends `text`; used for markdown-formatted text |
| `cmp_version` | Extends `ascii`; version comparison format: `<op>x.y.z` (e.g., `>=1.0.0`), used for version requirements |
| `http` | Standard HTTP(S) URL format |
| `identifier` | Extends `name`; standard identifier format: `[_a-zA-Z][_a-zA-Z0-9]*` |
| `name` | Extends `ascii`; dotted identifier: `<identifier1>.<identifier2>...<identifierN>` |
| `type` | Extends `ascii`; a `type_spec` which is validated against previously-defined types |
| `type_spec` | Extends `ascii`; represents a type specification using the syntax defined here |
| `regex` | Extends `string`; a valid Lua pattern string (validated and translated to PCRE for export) |
| `version` | Extends `ascii`; standard `x.y.z` version format |

## Numeric Extension Types

| Type | Description |
|------|-------------|
| `percent` | Either `<number>%` (e.g., `50%`) OR `<integer>/<integer>` (e.g., `3/5`). Parsed to a number (50% => 0.5, 3/5 => 0.6) |
| `ratio` | Map `{name:percent}` where all percent values must sum to 1.0 (100%) |

### Validation-Related Types

| Type | Description |
|------|-------------|
| `expression` | A string containing a valid Lua expression (syntax-validated at parse time by compiling with `load()`) |
| `error_level` | Enum: `"error"` or `"warn"` |
| `validator_spec` | Union: `expression\|{expr:expression,level:error_level\|nil}` — either a plain expression string (defaults to error level) or a record with explicit level |
| `super_type` | Alias for `type_spec\|nil`; used in the `superType` column of `Files.tsv` |

## Cell Value Formatting

This section describes how to write actual cell values for each type in TSV data files.

### Primitive Values

| Type | How to Write | Examples |
|------|--------------|----------|
| `boolean` | `true` or `false` | `true`, `false` |
| `integer` | A whole number | `42`, `-7`, `0` |
| `float` | A number (decimal point not required on input; always reformatted with one, e.g., `5` becomes `5.0`) | `3.14`, `5`, `-0.5` |
| `string` | Plain text (never quoted at the cell level) | `Hello World` |
| `text` | Like string, but supports escape sequences: `\t` (tab), `\n` (newline), `\\` (backslash) | `Line one\nLine two` |

### Nil and Optional Values

For optional types (unions ending in `|nil`), an **empty cell** (no content between tab separators) represents `nil`.

### Container Values

**Important:** Container values in cells must be written **without** outer `{}` braces, to keep boilerplate to a minimum. The parser adds them internally based on the column's type definition.

- **Array** — Comma-separated values: `"sword","shield","potion"`
- **Map** — Comma-separated key=value pairs: `Skill="60%",Luck="40%"`
- **Tuple** — Comma-separated values (positional): `-20.0,50.0,10.0`
- **Record** — Comma-separated field=value pairs: `attack=80,defense=40,speed=30`

### Quoting Rules for Container Values

- **Single values** in arrays can be unquoted: `Fire` is valid for type `{Element}`.
- **Multiple values** in arrays must be individually quoted: `"Fire","Light"` not `Fire,Light`. Without quotes, the parser issues a warning about assuming a **single** unquoted string.
- **String values** inside maps and records follow the same rule: `key="value"`.
- **Numeric and boolean values** inside containers are never quoted: `attack=80`.

### Enum Values

Enum values are written as plain text matching one of the enum's defined labels:

```
Fire
```

When a file is registered with `superType=enum` in `Files.tsv`, the file's primary key values become the enum labels, and the file's type name becomes usable as a column type in other files.

### Percent and Ratio Values

- `percent`: Write as `<number>%` (e.g., `150%`, parsed as 1.5) or as a fraction `<integer>/<integer>` (e.g., `3/2`, parsed as 1.5).
- `ratio`: Write as a map of names to percent values: `Skill="60%",Luck="40%"`. All percentages must sum to 100%.

## Comments in Data Files

A comment line can be added anywhere in the data files (except the first line) using the Unix shell comment character (`#`). This must be the first character on that line. By convention, the comment applies to the line below, as in most programming languages. Since the TSV files should always have their header as the first line, that means you cannot "comment" on them that way. Instead, place the comment right under the header, and start it with the caret ^ character, to imply the comment applies to the line *above*. That way, the header line can also have a comment describing the meaning/usage of individual fields.

### Comments in Transposed Files

Comments are fully supported in transposed files (`.transposed.tsv`). When a transposed file is loaded, comment lines are internally converted to placeholder columns with names like `__comment1`, `__comment2`, etc. (1-indexed, consistent with Lua conventions). These placeholder columns have the type `comment` and preserve the original comment content.

When the file is reformatted and saved, these `__comment` placeholders are automatically converted back to proper comment lines in their original positions.

**Reserved prefix:** The `__comment` prefix is reserved for internal use by the system. User-defined column names should not start with `__comment` to avoid conflicts with comment handling.

## Primary Keys

The first field/column is the "primary key" of the line/row, and its value must be unique among all the lines/rows in that file. Furthermore, the "primary key" should be unique among all instances of a type *or its sub-types*.

When a type has sub-types, all fields of all types should have unique names, unless several fields with the same name in several sub-types also have the same type and the same meaning. This enables a design where a single database table can represent all instances of all sub-types of a type.

## Expression Evaluation

Data files support computed expressions in cell values. An expression is indicated by the `=` prefix:

```text
=baseValue * multiplier
=2 * pi * radius
```

Expressions are evaluated in a sandboxed Lua environment.

### Available References in Expressions

The `self` variable provides access to other columns in the **same row** (by name or numeric index). Within a cell expression, `self.columnName` returns the **parsed value** directly (a number, string, boolean, etc.):

```text
=self.width * self.height
=self.baseDamage * 2
```

### Published Data from Other Files

Data from files with lower `loadOrder` values can be made available for use in expressions in files with higher `loadOrder` values. This is controlled via the `publishContext` and `publishColumn` fields in `Files.tsv`.

Within the **same file**, rows are processed top-to-bottom, so earlier rows' published values are available to later rows' expressions. For example, if a file publishes its `value` column globally (`publishColumn=value`, empty `publishContext`), then row 3 can reference row 1's primary key as a variable that resolves to row 1's `value`.

### Expression Context vs Validator Context

In **cell expressions** (values starting with `=`), `self.columnName` returns the parsed value directly:

```text
=self.price * 1.1
```

In **row validators** (see [Row, File, and Package Validators](#row-file-and-package-validators)), `self` is the full row object. Each cell is a record with multiple forms, so you must use `.parsed` to access the value:

```text
self.price.parsed > 0 or 'price must be positive'
```

This difference exists because expressions run during cell parsing (values are plain), while validators run after the full row is parsed (cells retain metadata).

## COG Code Generation

This module implements functionality inspired by [Cog](https://nedbatchelder.com/code/cog/). It scans text files for a "comment pattern" and executes a code block when it finds it, replacing part of the "comment block" with the output of the code block.

The idea is that whenever required, you run this on your text files, and it will replace (update) the parts of the files that need to be updated. It's essentially a very generic "template engine" that can be used inside any file that uses one of the three supported comment styles (`--`, `##`, or `//`).

The code block is executed in a sandbox, and the output is inserted into the file. The code can make use of many functions, like those from the [predicates](predicates.lua) module, that have been added to the sandbox environment. User code in "code libraries" can also be reused.

### COG Block Structure

A COG block is built from 5 parts:

1. **Start marker** - one of:
   - `---[[[`
   - `###[[[`
   - `///[[[`

2. **Code block** - Lua code to execute, each line prefixed with the appropriate comment pattern:
   - `---return "--Hello, world!"`
   - `###return "--Hello, world!"`
   - `///return "--Hello, world!"`

3. **Code block end marker** - one of:
   - `---]]]`
   - `###]]]`
   - `///]]]`

4. **Generated content** - the text that gets replaced by the output of the code block (can be anything)

5. **Block end marker** - one of:
   - `---[[[end]]]`
   - `###[[[end]]]`
   - `///[[[end]]]`

### Example

```
###[[[
###local rows = {}
###for i = 1, 5 do
###    rows[#rows+1] = "Row" .. i .. "\t" .. i
###end
###return table.concat(rows, "\n")
###]]]
<generated content appears here>
###[[[end]]]
```

Lines prefixed with the comment pattern (`###` in this case) inside the COG block are executed as Lua code. The returned string is inserted between the "code block end marker" and the "block end marker", replacing any previously generated content.

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

The header alone does not give all information about the "type" of a file. The `Files.tsv` file associates metadata with data files. All data files in a package must be listed in `Files.tsv`. Since it is also used to define the order in which files are processed, `Files.tsv` can refer to files in the current directory AND in sub-directories.

`Files.tsv` must also include a row describing **itself** (e.g., `Files.tsv	Files	...`). This self-referencing entry is required for consistency.

The system expects a specific set of columns. The first seven columns (`fileName` through `loadOrder`) are required — a warning is issued if any are missing. The remaining columns are optional. Any unrecognized column generates a warning to help catch typos.

### Files.tsv Fields

| Field | Type | Description |
|-------|------|-------------|
| `fileName` | `string` | The path to the file, possibly in a sub-directory |
| `typeName` | `type_spec` | The type of the "records" in this file |
| `superType` | `super_type` | The optional super-type; set to `enum` to register this file as an enum type |
| `baseType` | `boolean` | Is this file a base-type file? (No super-type) |
| `publishContext` | `name\|nil` | The optional "context" under which the file data is "published" |
| `publishColumn` | `name\|nil` | The optional column of the file that is "published" |
| `loadOrder` | `number` | A number defining the processing order (affects computed expressions) |
| `description` | `text` | The optional description of the file |
| `joinInto` | `name\|nil` | The fileName of the primary file this file joins into |
| `joinColumn` | `name\|nil` | The column name used for joining (defaults to first column if nil) |
| `export` | `boolean\|nil` | Whether to export this file independently (defaults based on joinInto) |
| `joinedTypeName` | `type_spec\|nil` | The type name for the joined result |
| `rowValidators` | `{validator_spec}\|nil` | Validators run on each row after parsing |
| `fileValidators` | `{validator_spec}\|nil` | Validators run on the complete file |

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
| `package_validators` | `{validator_spec}\|nil` | Validators run after all files in the package are loaded |

### Custom Manifest Fields

Manifests support user-defined fields beyond the standard schema listed above. Custom fields are parsed according to their declared type, preserved during reformatting, and generate a warning during loading (to help catch typos). For example, a game project might add `gameGenre:string` or `contentRating:string` to store project-specific metadata.

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
| `validate` | `string\|nil` | Expression-based validator (see below) |
| `values` | `{string}\|nil` | Allowed values (for enum types) |

#### Constraint Types

Custom types support four categories of constraints, which are **mutually exclusive** (cannot be mixed):

1. **Numeric constraints** (`min`, `max`): For types extending `number` or `integer`
2. **String constraints** (`minLen`, `maxLen`, `pattern`): For types extending `string`
3. **Enum constraints** (`values`): For types extending an enum type
4. **Expression constraints** (`validate`): For any parent type, using a Lua expression

If no constraints are specified, the custom type becomes a simple alias to the parent type.

#### Expression-Based Validators

The `validate` field allows custom validation logic using a Lua expression. The expression is evaluated in a sandboxed environment with the parsed value available as `value`.

**Return Value Interpretation:**

| Return Value | Result |
|--------------|--------|
| `true` | Valid |
| `""` (empty string) | Valid |
| `false` or `nil` | Invalid (default error message) |
| Non-empty string | Invalid (string used as custom error message) |
| Number | Invalid (number converted to string as error message) |
| Other | Invalid (value serialized as error message) |

**Available in the expression environment:**

- `value` - the parsed value being validated
- `math` - Lua math library
- `string` - Lua string library
- `table` - Lua table library
- `predicates` - all predicate functions (see [Sandbox API](#sandbox-api))
- `stringUtils` - string utility functions
- `tableUtils` - table utility functions
- `equals` - deep equality comparison

**Examples:**

```text
# Even integers only
{name="evenInt",parent="integer",validate="value % 2 == 0"}

# Divisible by 5
{name="mult5",parent="integer",validate="value % 5 == 0"}

# Coordinate string format (note: match returns string, so compare to nil)
{name="coords",parent="string",validate="value:match('^%-?%d+,%-?%d+$') ~= nil"}

# Using predicates
{name="validId",parent="string",validate="predicates.isIdentifier(value)"}

# Complex validation with math
{name="perfectSquare",parent="integer",validate="value >= 0 and math.sqrt(value) == math.floor(math.sqrt(value))"}

# Custom error message using Lua's "or" short-circuit
{name="positiveInt",parent="integer",validate="value > 0 or 'must be positive'"}

# Custom error message with value interpolation
{name="rangeInt",parent="integer",validate="value >= 1 and value <= 100 or 'value ' .. value .. ' out of range [1,100]'"}

# Pattern with custom error message
{name="productCode",parent="string",validate="value:match('^[A-Z][A-Z][A-Z]%d%d$') ~= nil or 'must match XXX00 format'"}
```

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

## Row, File, and Package Validators

Beyond single-cell type validation, the system supports multi-level validation:

1. **Row Validators** - Validate individual rows after all columns are parsed
2. **File Validators** - Validate entire files/tables after all rows are processed
3. **Package Validators** - Validate the entire package after all files are loaded

All validators are expressions that return:
- `true` or empty string `""` → valid
- `false` or `nil` → invalid with default message
- Non-empty string → invalid with custom error message

### Validator Specification Types

Three new types support validators:

| Type | Description |
|------|-------------|
| `expression` | A string containing a valid Lua expression (syntax-validated at parse time) |
| `error_level` | Enum with values `"error"` or `"warn"` |
| `validator_spec` | Either a simple `expression` string or a record `{expr:expression, level:error_level\|nil}` |

### Validator Levels

Validators can have two levels:

| Level | Behavior |
|-------|----------|
| `error` (default) | Validation stops on first failure, reported as error |
| `warn` | Validation continues even on failure, reported as warning |

### Row Validators

Configured in `Files.tsv` via the `rowValidators` column:

| Field | Type | Purpose |
|-------|------|---------|
| `rowValidators` | `{validator_spec}\|nil` | Validators run on each row after parsing |

**Expression Context:**

- `self` / `row` - The current row (columns accessible as `self.columnName`)
- Don't forget that the value of a column is a table containing multiple "forms" of the value. Usually, you will want the "parsed" form.
- `rowIndex` - 1-based index of the current row
- Published contexts from earlier-loaded files
- Code libraries defined in the manifest
- Standard sandbox utilities (`math`, `string`, etc.)

**Example:**

```tsv
fileName:string	typeName:type_spec	rowValidators:{validator_spec}|nil
Items.tsv	Item	{"self.minLevel.parsed <= self.maxLevel.parsed or 'minLevel must be <= maxLevel'",{expr="self.price.parsed < 10000 or 'price seems high'",level="warn"}}
```

More readable Lua format:
```lua
{
    "self.minLevel.parsed <= self.maxLevel.parsed or 'minLevel must be <= maxLevel'",  -- error (default)
    {expr = "self.price.parsed < 10000 or 'price seems unusually high'", level = "warn"},  -- warning
}
```

### File Validators

Configured in `Files.tsv` via the `fileValidators` column:

| Field | Type | Purpose |
|-------|------|---------|
| `fileValidators` | `{validator_spec}\|nil` | Validators run on complete file |

**Expression Context:**

- `rows` / `file` - Array of all parsed rows in the file
- `fileName` - Name of the current file
- `count` - Number of rows
- Published contexts from earlier-loaded files
- Code libraries defined in the manifest
- Helper functions (see below)

**Example:**

```lua
{
    "unique(rows, 'sku') or 'SKU must be unique across all items'",  -- error
    {expr = "sum(rows, 'weight') <= 10000 or 'total weight exceeds limit'", level = "warn"},  -- warning
}
```

### Package Validators

Configured in `Manifest.transposed.tsv` via the `package_validators` field:

| Field | Type | Purpose |
|-------|------|---------|
| `package_validators` | `{validator_spec}\|nil` | Validators run on complete package |

**Expression Context:**

- `files` / `package` - Table mapping file names to their row arrays
- `packageId` - The package identifier
- All published contexts (including from dependency packages)
- Code libraries defined in the manifest
- Helper functions (see below)

**Example in Manifest.transposed.tsv:**

```tsv
package_validators:{validator_spec}|nil	{"all(files['items.tsv'], function(item) return any(files['categories.tsv'], function(cat) return cat.id.parsed == item.category.parsed end) end) or 'all items must reference valid category'"}
```

### Validator Helper Functions

The following helper functions are available in file and package validator expressions:

#### Collection Predicates

| Function | Description |
|----------|-------------|
| `unique(rows, column)` | Check if column values are unique |
| `sum(rows, column)` | Sum numeric column values |
| `min(rows, column)` | Minimum value in column |
| `max(rows, column)` | Maximum value in column |
| `avg(rows, column)` | Average value in column |
| `count(rows, predicate)` | Count rows matching predicate (optional) |

#### Iteration Helpers

| Function | Description |
|----------|-------------|
| `all(rows, predicate)` | All rows satisfy predicate |
| `any(rows, predicate)` | At least one row satisfies predicate |
| `none(rows, predicate)` | No rows satisfy predicate |
| `filter(rows, predicate)` | Return rows matching predicate |
| `find(rows, predicate)` | Return first row matching predicate |

#### Lookup Helpers

| Function | Description |
|----------|-------------|
| `lookup(rows, column, value)` | Find row where column == value |
| `groupBy(rows, column)` | Group rows by column value |

### Quota and Performance

| Validator Type | Operation Quota |
|----------------|-----------------|
| Row validators | 1,000 operations per row |
| File validators | 10,000 operations per file |
| Package validators | 100,000 operations per package |

Row validators run per-row, so complex validators will slow parsing. File and package validators run once, allowing more intensive checks.

### Error Reporting

**Row Validator Messages:**

```
[ERROR] Row validation failed in Items.tsv row 42:
  Validator: self.minLevel.parsed <= self.maxLevel.parsed or 'minLevel must be <= maxLevel'
  Error: minLevel must be <= maxLevel

[WARN] Row validation warning in Items.tsv row 15:
  Validator: self.price.parsed < 10000 or 'price seems unusually high'
  Warning: price seems unusually high
```

**File Validator Messages:**

```
[ERROR] File validation failed in Items.tsv:
  Validator: unique(rows, 'sku') or 'SKU must be unique'
  Error: SKU must be unique

[WARN] File validation warning in Items.tsv:
  Validator: sum(rows, 'weight') <= 10000 or 'total weight exceeds limit'
  Warning: total weight exceeds limit
```

**Package Validator Messages:**

```
[ERROR] Package validation failed in tutorial.core:
  Validator: all items must reference valid category
  Error: Items reference non-existent categories
```
