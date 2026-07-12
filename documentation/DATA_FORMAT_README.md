# Data Format Specification

## Naming Conventions

We assume type names are defined using **Pascal Case** convention. We also assume that type names don't contain dashes (`-`), though underscores (`_`) are allowed. The name `self` is reserved and cannot be used as a type name, type alias, record field name, or enum label. Names matching the tuple field pattern `_<INTEGER>` (e.g., `_0`, `_1`, `_2`) are also reserved.

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

### Omitting the type

If the type is left empty, the column defaults to **`string`**. Two forms:

- `name:` — a trailing colon with no type. Defaults to `string` silently. Use this
  when you deliberately want an untyped (string) column.
- `name` — no colon at all. Also defaults to `string`, but logs a **warning** on
  every load (a missing `:` is usually a mistake), so prefer the explicit `name:`.

The default is `string`, not `string|nil` — but an empty cell in a `string` column
is still valid (it parses to the empty string `""`, not an error), so a plain
`string` column tolerates blanks. Use `string|nil` only when you must distinguish a
*nil* value from an *empty string*.

> Note: the reformatter **canonicalises** an omitted type to its explicit form, so an
> in-place reformat rewrites `name:` to `name:string`. The two are equivalent; the
> bare form is just less to type when authoring.

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

### Inherited Defaults

When a file extends a parent file (via `superType` in `Files.tsv`), columns that have no default value automatically inherit the default from the matching parent column. This avoids repeating the same default in every child file.

**Example:** if the parent file header declares `parent:{extends:float}:float`, child files only need `parent:{extends:float}` — the `:float` default is inherited automatically.

- A child's own default always takes precedence over the inherited one
- Transitive inheritance is supported (grandparent → parent → child)
- Only columns with the same name are matched; columns unique to the child are unaffected
- Alternatively, the child can omit the column entirely, in which case the inherited default is still used.

## Column Omission

When a file's type definition contains optional fields (typed as `T|nil`), you do not need to include a column for every optional field in the header. Any field absent from the header is treated as `nil` for every row — which is the correct default for an optional field.

This keeps files concise: only include columns that have at least one non-nil value in the actual data.

**Example:** given a type with fields `name:name`, `min:number|nil`, `max:number|nil`, and `validate:string|nil`, a file that only constrains minimum values can use:

```tsv
name:name    min:number|nil
positiveInt  1
nonNegative  0
```

The absent `max` and `validate` columns default to `nil` for all rows.

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

- Each path segment must be a valid identifier (letters, digits, underscores; starting with letter or underscore). A single `_` is not a valid identifier
- The name `self` and tuple field patterns (`_0`, `_1`, `_2`, ...) are reserved and cannot be used as field names, type names, type aliases, or enum labels
- Type names and type aliases cannot end with `_` (record field names can, ensuring they never collide with type names)
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

> **Type hierarchy:** A union type is considered to extend a base type when **all** of its member types extend that base type. For example, `integer|float` extends `number`, and `ubyte|ushort` extends `integer`. Unions containing `nil` do not extend any base type (since `nil` itself does not extend anything).
>
> **SQL Export:** When all member types of a union share a common base type, the union column is mapped to that base type's SQL type (e.g., `integer|float` maps to `REAL`, `ubyte|ushort` maps to `BIGINT`). Otherwise, union columns are exported as `TEXT` in SQL. When all member types are basic (non-table) types, values are serialized as strings. When the union contains a table type, values are JSON-encoded (same as standalone `table` columns). If the union includes `nil`, the column is nullable; otherwise it is `NOT NULL`.

### Special Types

| Type | Description |
|------|-------------|
| `raw` | Pre-defined union: `boolean\|number\|table\|string\|nil` |
| `any` | Tagged union: `{type,self._1}` — a tuple where the first field is a type name and the second field's type is determined by that name (see [Self-Referencing Field Types](#self-referencing-field-types)). E.g., `"integer",42` validates `42` as an integer |
| `number_type` | A restricted `type_spec` that only accepts names of types extending `number` (e.g., `integer`, `float`, `long`, `percent`, or custom numeric types like `kilogram`) |
| `tagged_number` | Tagged numeric union: `{number_type,self._1}` — like `any` but restricted to numeric types. The first field is a `number_type` name and the second field is validated as that type (see [Self-Referencing Field Types](#self-referencing-field-types)). E.g., `"integer",5` is valid but `"integer",3.5` is rejected |
| `quantity` | Compact string format `<number><number_type>` (e.g., `3.5kilogram`, `100metre`, `-5integer`). Parsed to the same `{type_name, number}` structure as `tagged_number`. Extends `tagged_number` |
| `{extends,<type>}` | Bare extends type spec: values must be **names of registered types** that extend (or are equal to) the specified ancestor type. E.g., `{extends,number}` accepts `integer`, `float`, `kilogram`, etc. Also available in record form `{extends:<type>}`. Useful for constraining fields to type names from a specific family |
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

### Field Redefinition in Child Record Types

A child record type may **re-declare** a field that already exists in the parent, provided the child's declared type is a **compatible subtype** of the parent field's type. The re-declared field replaces the parent's definition for that field in the child type.

```
# Parent — value is any number, max is an optional number
{name="Measurement",parent="{max:number|nil,unit:string,value:number}"}

# Child — narrows value to float, keeps max optional
{extends:Measurement,label:string,value:float}

# Child — narrows value to float AND marks max as unused (always nil)
{extends:Measurement,label:string,max:nil,value:float}
```

**Compatibility rules:**

| Parent field type | Allowed child types | Notes |
| --- | --- | --- |
| `T` | `T` or any subtype of `T` | `integer` and `ubyte` are subtypes of `number` |
| `T\|nil` | `T`, any subtype of `T`, or `nil` | `nil` marks the field as "unused" (column omission) |
| `self.<field>` (self-ref) | *(not allowed)* | Self-ref fields cannot be re-declared |

**Type compatibility for optional fields:** A non-nil type `T` is considered to extend `T|nil`. This means a child may narrow an optional parent field (`number|nil`) to a mandatory one (`float`), removing the ability to store nil.

**Column omission (`max:nil`):** If the parent field is optional (`X|nil`) and the child declares the field as `nil`, the field is treated as permanently unused in the child type. Any value other than nil/empty is rejected. This pattern is useful when a general parent type has optional fields that a specific child type never uses.

**Standalone `nil` as a field type:** `nil` is a valid field type in any record, but using it outside of an inheritance context (i.e., in a plain `{...}` record that does not use `extends`) generates a warning, since such a field can never hold a value.

**Multi-level narrowing:** Re-declaration is validated against the immediate parent only, and the result is itself a valid type that can be further narrowed by grandchildren. For example, if parent has `x:number` and child narrows to `x:integer`, a grandchild may further narrow to `x:ubyte`.

### Multiple Inheritance

A record type can extend **multiple parent records** by specifying a tuple of parent type names in the `extends` field:

```
# Single inheritance (existing)
{extends:<ParentType>,<name>:<type>,...}

# Multiple inheritance (new)
{extends:{<ParentA>,<ParentB>},<name>:<type>,...}
```

All fields from every parent are merged into the child type. The child may also declare its own additional fields.

**Example:**

```text
# Define two parent record types
{name="Localized",parent="{displayName:string,description:string}"}
{name="Measured",parent="{unit:string,precision:integer}"}

# Child extends both — gets all four parent fields plus its own
{name="LocalizedMeasurement",parent="{extends:{Localized,Measured},value:float}"}
```

The `LocalizedMeasurement` type has fields: `description`, `displayName`, `precision`, `unit`, and `value`.

**Field conflict resolution:**

| Scenario | Result |
| --- | --- |
| Both parents define the same field with the **same type** | No conflict — field appears once |
| Both parents define the same field with **compatible types** (one extends the other) | The **narrower** type wins (e.g., `integer` beats `number`) |
| Both parents define the same field with **incompatible types** | **Error** |
| Both parents define a `self.X` field targeting the **same** reference | No conflict |
| Both parents define a `self.X` field targeting **different** references | **Error** |

**Rules:**

- Each parent must be a **named type** (a registered alias) that resolves to a record. Inline record specs in the parent tuple are not allowed.
- Duplicate parents (e.g., `{extends:{A,A}}`) are an error.
- Parent order does not affect the result — conflicts are errors, not resolved by ordering.
- The child may re-declare an inherited field to narrow its type, following the same compatibility rules as single inheritance.
- Diamond inheritance (two parents sharing a common ancestor) works naturally: overlapping fields have identical types from the shared ancestor.
- `extendsOrRestrict` recognizes a multi-extends child as extending each of its parents individually.

**Bare multi-extends:**

The bare form `{extends:{<ParentA>,<ParentB>}}` — without additional child fields — creates a merged record type containing all fields from both parents. This is useful for "joining" two record types into one.

```text
# Two complementary record types
{name="CoreData",parent="{id:string,value:number}"}
{name="Translation",parent="{displayName:string,description:string}"}

# Merged type — all four fields, no additional child fields
{name="FullData",parent="{extends:{CoreData,Translation}}"}
```

> **Note:** `{extends:{A}}` with a single type in braces is **not** treated as multiple inheritance — a single element in braces is parsed as an array type, not a tuple. Use `{extends:A}` for single inheritance.

### Bare Extends (Ancestor Constraint)

The bare forms `{extends,<type>}` (tuple syntax) and `{extends:<type>}` (record syntax) — without additional fields — define a type whose values must be **names of registered types** extending the specified ancestor. This is useful for constraining a field to only accept type names from a specific type family.

```text
# As an inline column type — accepts "integer", "float", "kilogram", etc.
unitType:{extends,number}

# As a custom type alias in the manifest
{name="numericUnit",parent="{extends,number}"}

# Then use it in column headers
reward.unit:numericUnit  reward.value:float
kilogram                 3.5
metre                    100.0
```

The built-in `number_type` type is equivalent to `{extends,number}`.

### Type Tags (Named Type Groups)

A **type tag** is a named group of types sharing a common ancestor, declared via the `members` field in a custom type definition. Unlike enums (which group string labels), type tags group **registered types** under a curated name.

**Declaration:**

```text
# In Manifest custom_types:
{name="CurrencyType",parent="number",members={"gold"}}
```

This creates a type tag `CurrencyType` whose members must all extend `number`. The tag itself acts as `{extends,number}` restricted to the listed members (and their subtypes).

**Usage:**

```text
# As a column type — accepts "gold" but rejects "kilogram" or "string"
rewardType:CurrencyType

# With {extends,...} syntax — same membership constraint
paymentType:{extends,CurrencyType}

# In a record type
{unit:CurrencyType, value:float}
```

**Cross-package merging:** Multiple packages can declare the same tag name with the same ancestor. Members are merged additively. For example, a core package defines `CurrencyType` with `{"gold"}`, and an expansion adds `{"bossGem"}`:

```text
# Core manifest:
{name="CurrencyType",parent="number",members={"gold"}}

# Expansion manifest (members are merged):
{name="CurrencyType",parent="number",members={"bossGem"}}

# Result: CurrencyType accepts both "gold" and "bossGem"
```

The ancestor must match across all declarations of the same tag. Members that are subtypes of existing members are also accepted (e.g., if `integer` is a member, `ubyte` which extends `integer` is also accepted).

**Nested tags (tag-of-tag):** A type tag can itself be a member of another tag, enabling hierarchical groupings. Membership is checked transitively:

```text
# Inner tag grouping mass units
{name="MassUnit",parent="number",members={"kilogram","gram"}}

# Outer tag grouping all unit families
{name="Unit",parent="number",members={"MassUnit"}}

# "kilogram" is accepted as a Unit (transitively via MassUnit)
unitCol:Unit
```

When a tag member is itself a tag, its ancestor must be compatible (same or a subtype of the parent tag's ancestor).

**Empty members list:** If the `members` field is left empty, then it is not a type tag definition, but a plain `{extends,...}` constraint.
If you just want to declare a type tag, but not tag any type, just set the `members` field to `true`.

#### Tag Assignment

Instead of listing members when defining a tag, you can assign a type to one or more existing tags using the `tags` field. This is especially useful in files extending `custom_type_def`, where a `tags` column lets each row declare its tag membership:

```tsv
# Tags.tsv (loadOrder=1) — define the tag with initial members
name:name    parent:type_spec|nil    members:{name}|nil
UnitTag      number                  integer

# Types.tsv (loadOrder=2) — assign new types to the tag
name:name    parent:type_spec|nil    min:number|nil    tags:name|{name}|nil
weight       integer                 0                 UnitTag
height       integer                 0                 UnitTag
```

After loading, both `weight` and `height` are members of `UnitTag`.

The `tags` field accepts a single tag name or a list of tag names. It is orthogonal to constraints — a type can have both a constraint (e.g., `min`/`max`) and tag assignments. The referenced tags must already be registered, and the type must be compatible with each tag's ancestor (same rules as `members`).

In the manifest, tag assignment works the same way:

```text
custom_types:{custom_type_def}|nil  {name="UnitTag",parent="number",members={"integer"}},{name="weight",parent="integer",min=0,tags="UnitTag"}
```

**Differences from enums:**

| Aspect | Enum | Type Tag |
|--------|------|----------|
| Groups | String labels | Registered types |
| Defined via | `.tsv` file with `superType=enum` | `members` field in `custom_type_def` |
| Ancestor | Implicit (enum type) | Explicit (`parent` field) |
| Cross-package | Not mergeable | Additively merged |
| Nesting | Not supported | Tags can be members of other tags |
| Introspection | `enumLabels()` | `listMembersOfTag()`, `isMemberOfTag()` |

**Naming restriction:** Type names and type tag names share a single namespace (`state.PARSERS`). A type tag and a regular type (alias, restricted number, enum, etc.) **cannot have the same name**. This is because type tag names can be used as column type specifications (e.g., `myColumn:density`), and all column type resolution goes through a single parser lookup. If you define a type tag `density` (a category of units) and also a custom type `density` (e.g., an alias for `kg/m³`), the second registration will fail with an explicit error message indicating the name collision.

```text
# This will fail — "density" is used as both a tag and a type:
{name="density",parent="number",members={"integer"}},{name="density",parent="number",min=0}

# Fix: use distinct names, e.g., "DensityUnit" for the tag and "density" for the type
{name="DensityUnit",parent="number",members={"integer"}},{name="density",parent="number",min=0}
```

### Ignored files (the `IgnoredFile` tag)

`IgnoredFile` is a **built-in type tag** (ancestor `table`) that marks file
types the loader should recognise but **not** load as data. When a file's
`typeName` in `Files.tsv` is a member of `IgnoredFile`, the loader skips it
before any parsing or validation runs — it never appears in the loaded data,
and no errors are raised for its contents.

This exists for files that live in the data tree but aren't dataset data and
would not survive normal parsing — for example, files whose columns have no
fixed per-row type, or whose primary-key column repeats values.

**Built-in member — `MigrationScript`.** The built-in record type
`MigrationScript` (`{command, p1, p2, p3, p4, p5}`) is tagged `IgnoredFile`.
A migration script (executed by `migration.lua`) is a TSV of command rows whose
`command` primary key repeats and whose `p*` parameters mean different things
per command, so it cannot be loaded as data. To keep such a script in the data
tree, declare it in `Files.tsv` with `typeName=MigrationScript`:

```tsv
fileName:filepath    typeName:type_spec    superType:super_type    baseType:boolean    loadOrder:number    description:text
migrate_v2.tsv       MigrationScript                               false               2                   v1→v2 migration
```

The file's own contents are never parsed against the type, so its header and
rows are free-form as far as the loader is concerned. (Migration scripts run
from *outside* the dataset need no `Files.tsv` entry — they are never scanned.)

**Marking your own types.** Any file type can opt in by adding `IgnoredFile`
to its `tags` field — independent of its own `superType`, because every record
type extends the tag's `table` ancestor:

```tsv
# Types.tsv (extends custom_type_def)
name:name    parent:type_spec|nil                      tags:name|{name}|nil
ScratchFile  {note:text}                               IgnoredFile
```

Files declared with `typeName=ScratchFile` are then recognised and skipped the
same way. Typical uses: scratch/template files, fixtures, or example data kept
in-tree but excluded from the dataset.

## Self-Referencing Field Types

Tuples and records support **self-referencing field types**, where one field's type is determined by the value of another field at parse time. This enables "dependent types" — fields whose validation depends on data in a sibling field.

### Syntax

In tuples, use `self._N` where `N` is the 1-based index of the referenced field:

```text
{number_type,self._1}
```

This means: "the first field is a `number_type` (a type name like `integer` or `float`), and the second field's type is whatever that first field's value says."

In records, use `self.fieldname`:

```text
{unit:number_type,value:self.unit}
```

This means: "the `unit` field is a `number_type`, and the `value` field's type is determined by the parsed value of `unit`."

### How It Works

Self-referencing fields use **two-pass parsing**:

1. **Pass 1**: All non-self-ref fields are parsed normally
2. **Pass 2**: Self-ref fields use the parsed value of the referenced field as a dynamic type name to look up a parser, then validate their own value against that type

For example, given type `{type,self._1}` and value `"integer",42`:
- Pass 1 parses `"integer"` as a `type` (valid type name) -> `"integer"`
- Pass 2 uses `"integer"` to find the integer parser, then parses `42` as an integer -> `42`

### Constraints

The referenced field must have a type that produces **type name strings**. Valid referenced field types are:

- `type` or `type_spec` — unrestricted type names
- `name` — any identifier (used as a type name)
- `{extends,X}` or `{extends:X}` — names of types extending ancestor `X`
- Type tags (e.g., `CurrencyType`) — names from a curated set of types

Self-references cannot form cycles: a field cannot reference itself, and two fields cannot reference each other (no mutual self-refs).

### Built-in Examples

The built-in types `any` and `tagged_number` use self-referencing fields:

- `any` is an alias for `{type,self._1}` — the first field names any type, the second field is validated as that type
- `tagged_number` is an alias for `{number_type,self._1}` — the first field names a numeric type, the second field is validated as that numeric type

### Custom Self-Referencing Types

You can define your own self-referencing types using `registerAlias` or inline in column headers:

```text
# Inline in a column header (2+ fields required for record syntax)
data:{unit:number_type,value:self.unit}

# As a custom type alias in the manifest
{name="TaggedValue",parent="{type,self._1}"}
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
| `identifier` | Extends `name`; standard identifier format: `[_a-zA-Z][_a-zA-Z0-9]*` (a single `_` alone is not valid) |
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
| `expression` | A string holding a Lua expression (syntax-validated at parse time via `load()`). An `expression` column stores the expression **text** — a leading `=` is tolerated (and ignored for the syntax check) so `=foo` and `foo` are accepted alike, and a `=`-prefixed cell is **not** evaluated at load (unlike a value column, where `=` means "compute this cell now"). The text is consumed later by whatever owns the expression (a validator, a `bulk_patch` selector/transform, etc.). |
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

A comment line can be added anywhere in a data file using the Unix shell comment character (`#`).
This must be the first character on that line.

**Preamble (comments before the header row).** Comment and blank lines that appear *before* the
header row are treated as a *preamble* and preserved across reformatting. This is useful for file-
level documentation, authorship notes, or COG script blocks that generate the header and data rows
(see the [COG Code Generation](#cog-code-generation) section). Example:

<!-- markdownlint-disable MD010 -->
```text
# This file is auto-generated by the build pipeline.
# Source: Item.tsv filtered to Fire-element items.
name:name	price:gold	weight:float
ironSword	150	3.5
```
<!-- markdownlint-enable MD010 -->

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

In **validators** (see [Row, File, and Package Validators](#row-file-and-package-validators)), `self.columnName` also returns the parsed value directly:

```text
self.price > 0 or 'price must be positive'
```

All user code contexts provide the same view: field names and indexes map to parsed values.

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

**Reserved names.** A library name must not collide with an existing
expression-environment name — the engine surfaces **`files`**, **`packages`**, and
**`versionSatisfies`**, or another package's library — and loading fails with a clear
error if it does. The same rule applies to `publishContext` names (see
*Detecting Other Packages* under Mod Overrides).

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
| `isIdentifier(s)` | Valid Lua identifier format (single `_` excluded) |
| `isName(s)` | Valid name (identifier or dot-separated identifiers; no component may be a single `_`) |
| `isFileName(s)` | Valid file name |
| `isPath(v)` | Valid Unix-style file path |
| `isVersion(v)` | Valid semantic version string |
| `isValidUTF8(s)` | Valid UTF-8 encoding |
| `isValidASCII(s)` | ASCII-only characters |
| `isValidRegex(p)` | Valid Lua pattern |
| `isValidHttpUrl(u)` | Valid HTTP/HTTPS URL |
| `isPercent(v)` | Valid percent format |
| `isReservedName(s)` | Reserved name (`self`) |
| `isTupleFieldName(s)` | Tuple field name pattern (`_0`, `_1`, `_2`, ...) |
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
| `transcoder` | `string\|nil` | Selects an input transcoder so a non-TSV file (e.g. `.json` / `.xml`) loads as data — e.g. `json:objects`, `xml:tabulua` (see [Alternative Input Formats](#alternative-input-formats-transcoders)) |
| `joinInto` | `name\|nil` | The fileName of the primary file this file joins into |
| `joinColumn` | `name\|nil` | The column name used for joining (defaults to first column if nil) |
| `export` | `boolean\|nil` | Whether to export this file independently (defaults based on joinInto) |
| `joinedTypeName` | `type_spec\|nil` | The type name for the joined result |
| `rowValidators` | `{validator_spec}\|nil` | Validators run on each row after parsing |
| `fileValidators` | `{validator_spec}\|nil` | Validators run on the complete file |
| `preProcessors` | `{processor_spec}\|nil` | Pre-processors run on parsed rows before validation (see [Pre-Processors](#pre-processors)) |
| `variant` | `name\|nil` | Variant tag for conditional file inclusion (see [Variant-Based Conditional File Inclusion](#variant-based-conditional-file-inclusion)) |
| `onlyIfPackages` | `{package_id}\|nil` | Row is active only when every listed package is loaded — optional mod compatibility (see [Conditional Files](#conditional-files-onlyifpackages)) |
| `schemaOverlayOf` | `filepath\|nil` (or `override_target\|nil`) | Marks this file as a schema overlay on the named parent file (see [Mod Overrides](#mod-overrides); the `override_target` spelling allows a `package.id:` qualifier — see *Targeting a Parent File*) |
| `patchOf` | `filepath\|nil` (or `override_target\|nil`) | Marks this file as a row patch on the named parent file (see [Mod Overrides](#mod-overrides)) |
| `bulkPatchOf` | `filepath\|nil` (or `override_target\|nil`) | Marks this file as a filter/transform (bulk) patch on the named parent file (see [Mod Overrides](#mod-overrides)) |
| `ifMissing` | `missing_policy\|nil` | Per override file: tolerance (`error` \| `warn` \| `silent`, default `error`) for a patched key or the whole target file being absent (see [Tolerating Missing Targets](#tolerating-missing-targets-ifmissing)) |

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
fileName:filepath	typeName:type_spec	...	joinInto:filepath|nil	joinColumn:name|nil	export:boolean|nil
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

### Variant-Based Conditional File Inclusion

The `variant` column in `Files.tsv` enables conditional file inclusion at processing time. This is useful when multiple versions of a file exist (e.g., translations for different languages, platform-specific data, debug/release configurations) and only one should be active per export.

#### Variant Activation Rules

- Rows with an **empty** `variant` value are **always active**
- Rows with a **non-empty** `variant` value are **only active** when that variant name is explicitly provided at processing time (via `--variant=<name>` on the command line, or `opt_variants` in the API)
- Inactive rows are **fully skipped**: the file is not loaded, not exported, and not validated for joins

This means adding a variant-tagged row to `Files.tsv` is safe -- it will not affect existing processing unless the variant is explicitly activated.

#### Variant Files.tsv Example

<!-- markdownlint-disable MD010 -->
```text
fileName:filepath	...	joinInto:filepath|nil	joinColumn:name|nil	variant:name|nil
Item.tsv	...
Item.en.tsv	...	Item.tsv	name	en
Item.fr.tsv	...	Item.tsv	name	fr
```
<!-- markdownlint-enable MD010 -->

With no variants specified: only `Item.tsv` and `Item.en.tsv` are loaded (since `Item.en.tsv` has no variant tag). `Item.fr.tsv` is skipped.

With `--variant=fr`: all three files are loaded. Both `Item.en.tsv` and `Item.fr.tsv` are joined into `Item.tsv`.

#### Variant Group Validation

To enforce that exactly one variant from a set of related options is selected, declare **variant groups** in `Manifest.transposed.tsv` using the `variant_groups` field:

<!-- markdownlint-disable MD010 -->
```text
variant_groups:{{name,{name},name|nil}}|nil	{"lang",{"en","fr","de"},"en"},{"platform",{"ios","android"}}
```
<!-- markdownlint-enable MD010 -->

This declares two groups:

- `lang`: exactly one of `en`, `fr`, or `de` must be selected; defaults to `en` if none specified
- `platform`: exactly one of `ios` or `android` must be selected (no default — error if missing)

Each group tuple has three elements: `{groupName, {allowedValues}, default}`. The third element (default) is optional — when provided, it is automatically applied if no variant from that group is explicitly selected.

**Validation rules:**

- For each declared group, **exactly one** of its allowed values must be in the provided variants set
- If no variant from a group is selected and the group has a **default**, the default is applied automatically
- If no variant from a group is selected and there is **no default**, an error is reported
- Variant names must be **globally unique** across all groups within a package
- Variant values not belonging to any declared group are allowed (free-form variants)

**Error examples:**

- No variant from a group (no default): `variant group 'platform' requires exactly one of: ios, android`
- Multiple from same group: `variant group 'lang' has multiple selected variants: en, fr -- expected exactly one`

## Alternative Input Formats (Transcoders)

A data file listed in `Files.tsv` does not have to be a TSV/CSV file. The engine
can read a handful of other formats and convert them to the same wide, typed
table at load time, so the rest of the system (validation, joining, export, …)
sees an ordinary parsed file. The component that performs the conversion is a
**transcoder**.

Transcoding is transparent: the on-disk file stays in its original format, and
the converted wide table is what gets validated and exported. Whether a file is
transcoded at all is decided **before** parsing, by file name and/or the
`transcoder` column — never by guessing from the content.

### Dispatch: extension-auto vs. explicit `transcoder`

There are two ways a file is routed through a transcoder:

- **Auto-matched by extension.** A `.eav` file is recognised by its extension —
  just list it in `Files.tsv` and it loads as data, no `transcoder` column
  needed. Compressed data files (`.tsv.gz`, `.csv.gz`) are likewise decompressed
  automatically.
- **Explicitly selected** via the `transcoder` column in `Files.tsv`. Formats
  like JSON and XML are *ambiguous* — the same extension can hold several
  different layouts, or be an unrelated game asset — so they never auto-fire. You
  opt a specific file in by naming a transcoder id (e.g. `xml:tabulua`). A
  `.json` / `.xml` file **without** a `transcoder` value is treated as an opaque
  asset (copied through on export, not parsed as data).

### Supported transcoders

| `transcoder` id | Extension | Selection | Reversible | Column types from |
|-----------------|-----------|-----------|------------|-------------------|
| *(none)* | `.eav` | auto (by extension) | yes | the file's `typeName` schema |
| `json:objects` | `.json` | explicit | yes¹ | the file's `typeName` schema |
| `json:rows` | `.json` | explicit | yes¹ | the file's `typeName` schema |
| `json:columns` | `.json` | explicit | yes¹ | the file's `typeName` schema |
| `json:objects:typed` | `.json` | explicit | yes | the file's `typeName` schema |
| `json:rows:typed` | `.json` | explicit | yes | the file's `typeName` schema |
| `json:columns:typed` | `.json` | explicit | yes | the file's `typeName` schema |
| `xml:tabulua` | `.xml` | explicit | yes | the file's own `<header>` |
| `tsv:lua` | `.tsv` | explicit | yes² | the file's own header |
| `tsv:json-typed` | `.tsv` | explicit | yes² | the file's own header |
| `tsv:json-natural` | `.tsv` | explicit | yes² | the file's own header |
| `lua:tabulua` | `.lua` | explicit | yes | the file's own header (row 1) |

> A transcode stage may declare an **input-extension guard**: an explicitly
> selected transcoder verifies the file actually has the expected extension and
> errors clearly otherwise (e.g. pointing `json:rows` at a `.txt` file is caught
> early rather than mis-parsed).

### Reversibility and the reformatter

When a file is reformatted in place, a **reversible** transcoder rewrites the
on-disk source back in its own format from the reformatted wide table; a
**non-reversible** one leaves the source untouched (the derived TSV is not the
source of truth, so it is never written back over the original).

- `.eav`, `.xml` (`xml:tabulua`), `.tsv.gz` / `.csv.gz`, the `json:*`, the
  `tsv:*`, and `lua:tabulua` transcoders are reversible — the reformatter rewrites
  the source in its own format from the reformatted wide table.
- ² The `tsv:*` files share the `.tsv` extension with native data, so the
  reformatter routes a `transcoder`-assigned `.tsv` to the transcoder's `encode`
  (re-rendering each cell as a Lua literal / typed-JSON / natural-JSON value)
  rather than down the native-TSV rewrite, which would otherwise silently strip
  the chosen cell encoding. Like JSON, the round-trip is **normalizing** (the cell
  values are canonicalised); `tsv:json-natural` carries the same conventional-JSON
  caveats as the `json-natural` layouts.
- ¹ The JSON round-trip is **normalizing**, not byte-identical: the rewritten
  JSON is canonical (object keys in the schema's header order, canonical number
  and whitespace formatting) and parses back to the same data. The `:typed`
  layouts are **value-lossless** (the self-describing `{"int":…}` form survives
  any JSON toolchain); the bare `json-natural` layouts carry the usual
  conventional-JSON caveats (an int above 2⁵³ only survives a JS-derived
  toolchain in the typed form; `NaN`/`±Inf` are not representable; an exact
  scalar key inside an untyped `table` column is coerced). Reading then writing a
  natural-JSON file re-emits equivalent natural JSON.

### JSON layouts (`json:objects` / `json:rows` / `json:columns`)

JSON has several equally-valid ways to lay out the same tabular data, which an
extension cannot disambiguate, so the author picks one per file with the
`transcoder` column. In **all three**, the column **names, types and order** come
from the file's `typeName` schema (in sorted field order), never from the JSON, so
the table carries a correctly typed header and the normal type/validation
machinery applies unchanged. A missing or `null` value becomes an empty cell.

- **`json:objects`** — a top-level array of objects, one object per row; fields are
  pulled by name:

  ```json
  [{"name":"sword","price":100,"tag":"sharp"},{"name":"shield","price":50}]
  ```

- **`json:rows`** — a top-level array of arrays, one inner array per row; values are
  **positional** to the schema's sorted field order (here `name,price,tag`):

  ```json
  [["sword",100,"sharp"],["shield",50]]
  ```

- **`json:columns`** — a top-level array of arrays, one inner array per **column**
  (the transpose of `json:rows`), one column per schema field:

  ```json
  [["sword","shield"],[100,50],["sharp"]]
  ```

All three load as the same wide table:

<!-- markdownlint-disable MD010 -->
```text
name:identifier	price:integer	tag:string|nil
sword	100	sharp
shield	50
```
<!-- markdownlint-enable MD010 -->

**Composite cell values.** A cell may itself be a table-typed value (an array,
map, tuple, or nested record) matching the column's declared type. It is
reconstructed **type-directed** against that column type, so a `map`'s keys are
typed by the declared key type: a `map<string,…>` key like `"01"` stays the string
`"01"`, while a `map<integer,…>` key `"1"` becomes the number `1` — at any nesting
depth.

```json
[{"name":"hero","skills":["slash","guard"],"stats":{"atk":7,"def":3}}]
```

with `typeName` `{name:identifier,skills:{string},stats:{string:integer}}` loads
`skills` as a list and `stats` as a map.

**Notes / limits.**

- A non-finite number (e.g. an overflowing `1e999`) is reported as an error, but
  the rest of the file still loads, so every offending value is flagged in one
  pass. (`NaN` / `Infinity` are not valid JSON tokens in the first place.)
- A map whose **key type is itself a table** is not a valid column type (the type
  parser rejects it), so it cannot occur here.

**Typed variants (`json:objects:typed` / `json:rows:typed` / `json:columns:typed`).**
The same three row layouts, but cell values use TabuLua's **typed** JSON encoding —
the self-describing read-back of `exportJSON`, where integers are the *string*
`{"int":"…"}`, special floats `{"float":"nan"/"inf"/"-inf"}`, and tables
`[size, …, [key, value]]`. The encoding carries the types, so values survive
independently of the column type and of the JSON toolchain.

The main reason to use it is **64-bit integers**: most JSON producers/consumers are
JavaScript-derived and cannot represent an integer above 2^53 as a number, so a
natural `9223372036854775807` is corrupted before TabuLua ever sees it. The typed
`{"int":"9223372036854775807"}` string form survives any toolchain. A secondary
case is an **untyped `table` / `raw` column**, where natural has no key type to
guide it (and would coerce a key `"1"` to the number `1`) but typed keeps the exact
key `"1"`. For ordinary typed columns the result is identical to natural.

### EAV (Entity–Attribute–Value) long format

A `.eav` file is a header-less, three-column long table of
`entity <tab> attribute <tab> value` triples. The engine pivots it back to the
wide table, typing the rebuilt header from the file's `typeName` schema (so a
`typeName` is required, and each attribute must be a field of that type). The
key column is the schema's first field; an attribute absent for a given entity
becomes an empty cell.

<!-- markdownlint-disable MD010 -->
```text
# Items.eav  (typeName=Item in Files.tsv)
sword	price	100
sword	tag	sharp
shield	price	50
```
<!-- markdownlint-enable MD010 -->

loads as the wide table:

<!-- markdownlint-disable MD010 -->
```text
name:identifier	price:integer	tag:string|nil
sword	100	sharp
shield	50
```
<!-- markdownlint-enable MD010 -->

### XML round-trip format (`xml:tabulua`)

The `xml:tabulua` transcoder reads TabuLua's **own** XML export format back in as
data — the inverse of XML export. The document is `<file>/<header>/<row>`, with
typed cell elements (`<integer>`, `<string>`, `<number>`, `<true/>`, `<null/>`,
nested `<table>` for composite values):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<file xmlns="urn:tabulua:table:1">
<header><string>name:identifier</string><string>n:integer</string><string>loot:{name}</string></header>
<row><string>sword</string><integer>100</integer><table><string>gem</string><string>coin</string></table></row>
</file>
```

Two properties make it distinct from the other transcoders:

- **Namespaced.** The root carries the namespace `urn:tabulua:table:1` (a
  version-tagged URN). This is how a reader tells a TabuLua data file from an
  unrelated `.xml` asset. The transcoder verifies the namespace and rejects a
  document that is not in it — even one explicitly opted in with
  `transcoder=xml:tabulua` — so a mis-pointed asset fails loudly instead of being
  mis-read.
- **Schema-free.** Column names and types come from the file's own `<header>`
  (`name:type` cells), not from a `typeName`. (The `typeName` column in
  `Files.tsv` is still filled in as usual, but it does not drive the XML column
  types.) Composite `<table>` cells round-trip through the same machinery every
  other format uses, so a `table`-typed column reads/writes identically across
  formats.

Because the format is reversible, an `.xml` data file is rewritten in place by
the reformatter from the reformatted wide table — a true XML ⇄ TSV round-trip.

> **XML export is namespaced.** Producing this format (XML export) now emits the
> `urn:tabulua:table:1` namespace on the root `<file>` element. XML files
> exported by older versions (bare `<file>`) must be re-exported before they can
> be read back via `xml:tabulua`.

### TSV with alternate cell encodings (`tsv:lua` / `tsv:json-typed` / `tsv:json-natural`)

These read back the three TSV export variants whose **container** is the ordinary
wide TSV — same `name:type` header, same columns and rows — but whose **cell
values** are rendered in an alternate codec instead of TabuLua's native brace-less
form:

| `transcoder` | cell value example |
|--------------|--------------------|
| `tsv:lua` | `{attack=80,defense=40}` (a Lua literal) |
| `tsv:json-typed` | `[0,["attack",{"int":"80"}],["defense",{"int":"40"}]]` (self-describing typed JSON) |
| `tsv:json-natural` | `{"attack":80,"defense":40}` (conventional JSON) |

In every variant the header cells are themselves serialised (`"name:identifier"`),
so they are read back through the same codec. Because they share the `.tsv`
extension with native data files, they are **id-only** — never auto-fire — and the
author opts a specific file in with `transcoder=tsv:lua` (etc.) in `Files.tsv`.
Like XML they are **schema-free**: column names and types come from the file's own
header, not a `typeName`. They are reversible (see footnote ² above) — the
reformatter rewrites the source in its chosen encoding rather than as native TSV.

A Lua application can therefore export its data with `--file=tsv --data=lua` and
read it straight back; the typed-JSON variant is value-lossless, while the
natural-JSON variant carries the usual conventional-JSON caveats.

### Lua file format (`lua:tabulua`)

The `--file=lua` export is a single Lua table — `return { <header>, <row>, … }`, a
sequence of sequences whose first element is the `name:type` header and whose later
elements are rows of native Lua values:

```lua
return {
{"name:identifier","n:integer","loot:{name}"},
{"sword",100,{"gem","coin"}},
{"shield",50,{"wood"}}
}
```

The `lua:tabulua` transcoder reads it back as a wide, typed table. For a Lua
application this is the natural round-trip pair: it can read its own exported data
with the native `load`, no TSV reader required, and the engine reads the same file
with this stage. Two things make it distinct:

- **Id-only, never auto-fired.** A `.lua` is a **code library** to the loader by
  default (manifest bootstrap / `loadCodeLibrary`). A *data* `.lua` is
  distinguished solely by `transcoder=lua:tabulua` in `Files.tsv`; without it, a
  `.lua` stays a code library exactly as before. (`inputExtensions={"lua"}` is a
  guard, not a matcher.)
- **Executed under a sandbox + quota.** Unlike the parse-only transcoders, this one
  *runs* the file (it is Lua source). It executes in the same restricted sandbox
  with an instruction quota that code libraries use, so a data file that loops
  instead of returning a literal table aborts rather than hanging the load. It is
  **schema-free** (row 1 carries the column types) and **reversible**.

### Compressed data files (gzip)

A `.tsv.gz` / `.csv.gz` file is transparently decompressed and parsed as the
inner TSV/CSV. It is reversible: the reformatter reformats the decoded TSV and
re-compresses it, writing the bytes back over the `.gz` (never clobbering it with
plain text). Decompression is bounded against decompression bombs.

### SVG diagram export (`--file=svg`)

`lua reformatter.lua --file=svg <dirs…>` draws the **graph-family** data files
(`basic_graph_node` / `graph_node` / `tree_node`) as self-contained SVG diagrams,
one `.svg` per node file under `exported/svg-svg/`, mirroring the source layout.
Unlike every other export, it is **selective**: a file that is not a graph family
is skipped (logged at `info`, counted in an end-of-run summary) — a graph-only
picture of a non-graph file is meaningless, so a whole-directory run over mixed
files naturally emits diagrams only for the graphs. A run that finds no graph
files writes nothing and says so; it is not an error.

The layout is a **layered (Sugiyama-style) drawing** — directed families
(`graph_node` / `tree_node`) are ranked by longest path with arrowheads and
root/leaf tinting; undirected (`basic_graph_node`) graphs are laid out from a
deterministic BFS and drawn without arrowheads. Edge crossings are reduced with
the standard median heuristic (the count is *low*, not provably minimal — exact
minimization is NP-hard — and is surfaced in an `<!-- crossings: N -->` comment).
The SVG is pure text: no external stylesheet, web font, or script, and **byte
deterministic** — identical input data produces an identical diagram on every run
and platform, so the output diffs cleanly. Open it in any browser or embed it in
generated Markdown docs.

Colours are configurable per drawable type. `--svg-color-scheme=<name>` selects a
base palette (`default`, `dark`, `mono`, `colorblind`), and `--svg-color=<key>=<color>`
(repeatable) overrides an individual colour on top of it — `node`, `root`, `leaf`,
`isolated` (a node with no edges at all), `border`, `label`, `edge-directed`,
`edge-undirected`, `edge-label`, or `background`, where the value is a `#rgb` /
`#rrggbb` hex, a CSS colour name, or `none` for a transparent canvas. Directed and
undirected links carry separate colours. The canvas is transparent by default (so
the diagram adapts to whatever it is embedded in) except under the `dark` scheme.
There is no built-in title or frame — wrap the `<svg>` yourself for a caption. See
[REFORMATTER.md](REFORMATTER.md#svg-tuning-flags-only-affect---filesvg) for the full
flag list.

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
| `bootstrap` | `{{fn:name,library:name}}\|nil` | Functions invoked once at engine init with the type-wiring registration `api` — see [Type Wiring](#type-wiring-attaching-behaviour-to-a-type) |
| `dependencies` | `{{package_id,cmp_version}}\|nil` | Package dependencies with version requirements |
| `load_after` | `{package_id}\|nil` | IDs of packages that must be loaded before this one (if present) |
| `conflicts` | `{package_id}\|nil` | IDs of packages this package is **incompatible** with: if any listed package is loaded alongside, the load fails with an error. Symmetric — either side declaring the conflict is enough; a conflict naming an absent package is silently vacuous. Use for mods that cannot meaningfully compose (e.g. two total overhauls), instead of letting last-writer-wins silently pick one. A self-conflict is a manifest error. |
| `package_validators` | `{validator_spec}\|nil` | Validators run after all files in the package are loaded |
| `preProcessors` | `{processor_spec}\|nil` | Package-scoped pre-processors that mutate the merged-and-patched state of every file after patches and before validators (see [Mod Overrides](#mod-overrides)) |
| `variant_groups` | `{{name,{name},name\|nil}}\|nil` | Declares groups of mutually exclusive variant names with optional default (see [Variant Group Validation](#variant-group-validation)) |

### Custom Manifest Fields

Manifests support user-defined fields beyond the standard schema listed above. Custom fields are parsed according to their declared type, preserved during reformatting, and generate a warning during loading (to help catch typos). For example, a game project might add `gameGenre:string` or `contentRating:string` to store project-specific metadata.

### Custom Types

Packages can define custom types with data-driven validators. Custom types extend a parent type with optional validation constraints. When no constraints are specified, the custom type acts as a simple type alias.

#### Custom Type Definition

Each custom type is defined as a record with the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `name` | `name` | The name of the custom type (required) |
| `parent` | `type_spec\|nil` | The parent type to extend (required) |
| `min` | `number\|nil` | Minimum value (for numeric types) |
| `max` | `number\|nil` | Maximum value (for numeric types) |
| `minLen` | `integer\|nil` | Minimum string length (for string types) |
| `maxLen` | `integer\|nil` | Maximum string length (for string types) |
| `members` | `{name}\|nil` | Type tag members (see [Type Tags](#type-tags-named-type-groups)) |
| `pattern` | `string\|nil` | Lua pattern that strings must match (for string types) |
| `tags` | `{name}\|nil` | Type tag(s) to add this type to as a member (see [Tag Assignment](#tag-assignment)) |
| `validate` | `string\|nil` | Expression-based validator (see below) |
| `values` | `{string}\|nil` | Allowed values (for enum types) |

#### Constraint Types

Custom types support five categories of constraints, which are **mutually exclusive** (cannot be mixed):

1. **Numeric constraints** (`min`, `max`): For types extending `number` or `integer`
2. **String constraints** (`minLen`, `maxLen`, `pattern`): For types extending `string`
3. **Enum constraints** (`values`): For types extending an enum type
4. **Expression constraints** (`validate`): For any parent type, using a Lua expression
5. **Type tag constraints** (`members`): For grouping registered types under a named tag (see [Type Tags](#type-tags-named-type-groups))

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
custom_types:{custom_type_def}|nil  {name="positiveInt",parent="integer",min=1},{name="percentage",parent="number",min=0,max=100},{name="shortName",parent="string",minLen=1,maxLen=20},{name="numericUnit",parent="{extends,number}"}
```

This defines four custom types:

- `positiveInt`: An integer that must be >= 1
- `percentage`: A number between 0 and 100 (inclusive)
- `shortName`: A string with 1 to 20 characters
- `numericUnit`: A type name that must extend `number` (e.g., `kilogram`, `float`, `integer`), using the `{extends,<type>}` type spec as parent

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

#### Custom Type Definition Files

As an alternative to the inline `custom_types` manifest field, you can define custom types in a dedicated TSV file. When a file's `typeName` in `Files.tsv` is `custom_type_def`, or a type that directly or transitively has `superType=custom_type_def`, each data row is automatically registered as a custom type.

This is especially useful when a package defines many custom types, since a dedicated file supports column alignment, per-row comments, and column omission (see [Column Omission](#column-omission)).

**`Files.tsv` entry:**

```tsv
CustomTypes.tsv  custom_type_def    true    1    Custom type definitions
```

**`CustomTypes.tsv`:**

```tsv
name:name    parent:type_spec|nil    min:number|nil    max:number|nil    validate:string|nil
positiveInt  integer                 1
percentage   float                   0                 100
nonEmptyStr  string                                                       predicates.isNonEmptyStr(value) or 'must not be empty'
```

After this file is loaded, `positiveInt`, `percentage`, and `nonEmptyStr` are registered types and can be used as column types in all subsequently loaded files.

Only the standard `custom_type_def` fields (`name`, `parent`, `min`, `max`, `minLen`, `maxLen`, `members`, `pattern`, `tags`, `validate`, `values`) feed into type registration. Extra columns in a sub-type file (e.g., a `gameCategory:string` annotation column) are parsed and stored but ignored during registration.

**Load ordering:** A custom type definition file must have a lower `loadOrder` than any file that uses the types it defines. The recommended convention is `loadOrder=1` (or another low value). Defining a type after it is referenced produces an "unknown type" parse error. A custom type definition file may itself reference types from an earlier custom type definition file (by `loadOrder`), enabling cascaded type hierarchies.

**Collision behavior:** Registering a type name that is already registered with a different parent type is an error. Registering the same name with the same parent type is idempotent (no error).

**Export:** Custom type definition files are structural (they register types, not data). By default, a file with no `joinInto` value is exported, so set `export=false` explicitly in `Files.tsv` if you do not want the file included in JSON/SQL output.

**Sub-typing example:** You may extend `custom_type_def` with additional project-specific metadata columns. Declare a sub-type in `Files.tsv` and use it for the file's `typeName`:

```tsv
# Files.tsv
GameTypes.tsv  GameCustomType  custom_type_def  false  1  Game-specific custom types
```

```tsv
# GameTypes.tsv
name:name    parent:type_spec|nil    min:number|nil    max:number|nil    gameCategory:string
health       integer                 0                 9999              Stats
mana         integer                 0                 999               Stats
```

## Pre-Processors

Pre-processors are sandboxed expressions that **mutate** the parsed rows of a file
**after** parsing but **before** any row, file, or package validator runs. They
fill the gap between row-local `=expr` (can only read a single row) and file
validators (can see the whole file but cannot write).

Typical use cases:

- **Bidirectional references** — Authors fill in a `prerequisites` column;
  a processor derives the inverse `unlocks` column automatically.
- **Normalisation** that depends on the whole file (e.g. levelling rows
  against a shared baseline, sorting derived arrays).
- **Derived back-references** in graph- or tree-shaped data.

### Configuration

Configure pre-processors in `Files.tsv` via the `preProcessors` column:

| Field | Type | Purpose |
|-------|------|---------|
| `preProcessors` | `{processor_spec}\|nil` | Processors that mutate parsed rows before validation |

A `processor_spec` is either a simple expression string (defaults to error
level, priority 100, no re-run after patches) or a structured record:

```lua
{expr=expression, level=error_level|nil, priority=number|nil, rerunAfterPatches=boolean|nil, requires={name}|nil}
```

| Field | Default | Meaning |
|-------|---------|---------|
| `expr` | (required) | Lua expression run in the processor sandbox |
| `level` | `"error"` | `"error"` aborts on failure; `"warn"` collects a warning |
| `priority` | `100` | Lower runs first within the file (same convention as `loadOrder`) |
| `rerunAfterPatches` | `false` | When `true`, this file processor is **re-run** after mod-override patches are applied, against the patched data — so derived data (inverse back-references, etc.) reaches rows that mods added. Such a processor must be **idempotent**. See [Mod Overrides → Package-Scoped Pre-Processors](#package-scoped-pre-processors) |
| `requires` | `{}` | Only meaningful for **package-scoped** pre-processors: names other packages whose package-scoped pre-processors must run before this one. See [Mod Overrides → Package-Scoped Pre-Processors](#package-scoped-pre-processors) |

### Sandbox Environment

A processor expression runs in the same sandbox as a file validator, with the
same read-side helpers (`unique`, `lookup`, `groupBy`, `all`, `any`, …) and the
same access to `rows`, `fileName`, `ctx`, published contexts, and code
libraries. In addition, processors get these write-side helpers:

| Helper | Purpose |
|--------|---------|
| `setCell(row, column, value)` | Set a parsed value on a row; re-serialises through the column's type so type errors surface immediately. |
| `clearCell(row, column)` | Equivalent to `setCell(row, column, nil)` — only valid for nullable columns. |
| `rowByKey(key)` | O(1) lookup into the current file by primary-key value; returns `nil` for unknown keys (no throw). |
| `dataIndex(row)` | Returns the 1-based data-row position of a wrapped row (header row excluded). |
| `copy(value)` | Returns a fresh, fully-mutable deep copy of a read-only value, so a changed collection can be built and installed via `setCell`. |

Direct field assignment (`row.foo = "bar"`) is **not** supported — the sandbox
forces use of `setCell` so values can be re-validated. Reading still works:
`row.foo` returns the parsed value, exactly like in validators — and, exactly
like in validators, that value is **read-only**. A collection-valued cell
(`row.unlocks`, `row.tags`, …) therefore cannot be mutated in place; doing so
raises `attempt to update a read-only table`. To change a collection, deep-copy
it with `copy`, mutate the copy, and install the result through `setCell`:

```lua
local u = copy(row.unlocks)   -- fresh, fully-mutable deep clone
table.insert(u, newItem)
setCell(row, 'unlocks', u)    -- single audited, re-validated write
```

This guarantees that **every** data write goes through `setCell` — the one path
that re-parses the value against the column's type and is the natural place for
auditing or logging.

Adding or removing rows is not supported in v1.

### Ordering

Within a file, processors are sorted by **ascending `priority`** (default `100`);
ties break in the order written in the `preProcessors` cell. Authors who don't
care about ordering can omit `priority` entirely — every processor gets `100`
and they run in textual order. A later processor sees the effects of earlier
ones.

Across files, pre-processors run per file; the order across files matches the
order in which files appear in the parsed dataset.

### Defensive Contract

Pre-processors run **before** any validator, so input data may be logically
broken (broken refs, duplicate keys, cycles, …) — but it has already passed
**type** parsing, so every cell's type is sound.

1. **Never raise.** A processor that raises (or returns a non-empty string) is
   reported as a failure at the configured level. Default level is `error`.
2. **Be tolerant of missing data.** `rowByKey` returns `nil` for unknown keys;
   processors must handle that themselves and let the validator flag the
   inconsistency.
3. **No order dependence across rows.** Processors run top-down across rows;
   authors should not mix write-then-read across rows in a single processor
   unless they explicitly walk the array twice.

### Quota

`PROCESSOR_QUOTA = 50,000` operations per file — higher than the file-validator
quota (10,000) because mutation work is more expensive than pure checking.
Configurable via the [processor_executor](processor_executor.lua) module API.

### Round-Trip / Reformatter Behaviour

By default, reformatting writes the **original** raw cells, **not** the
processor-mutated values. The reformatter's job is to faithfully preserve
author input; values "computed" by a processor are derived state, not
source-of-truth, and round-tripping them would silently change the on-disk
file every time it loads. This matches how `=expr` defaults are already
preserved in the file.

### Example: Inverse Relation

`Quest.tsv` lists `prerequisites` per row; `unlocks` is left blank and derived
by a processor:

```tsv
name:identifier	prerequisites:{name}|nil	unlocks:{name}|nil	description:text
intro			tutorial_quest
forest_quest	intro		Travel to the forest
cave_quest	forest_quest		Explore the cave
dragon_quest	"forest_quest","cave_quest"		Slay the dragon
```

Files.tsv entry (preProcessors cell):

```
"(function() for _, r in ipairs(rows) do for _, p in ipairs(r.prerequisites or {}) do local target = rowByKey(p); if target then local cur = copy(target.unlocks or {}); table.insert(cur, r.name); setCell(target, 'unlocks', cur) end end end; return true end)()"
```

In memory after pre-processing, `intro.unlocks = {"forest_quest"}`,
`forest_quest.unlocks = {"cave_quest","dragon_quest"}`, and so on. On disk,
`unlocks` remains empty — only the author-written `prerequisites` is the
source of truth. Best put that code in `Code Libraries`.

### Error Reporting

```
[ERROR] Pre-processor failed in Quest.tsv: processor execution error: setCell: column 'no_such_col' does not exist in header
[ERROR] Pre-processor failed in Items.tsv: processor execution error: Quota exceeded: 50000
[WARN]  Pre-processor warning in Items.tsv: derived weights exceed expected range
```

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
- `rowIndex` - 1-based index of the current row
- `ctx` - Writable table shared across all rows in the file, for accumulating state
- Published contexts from earlier-loaded files
- Code libraries defined in the manifest
- `packages` / `versionSatisfies` - the loaded-package set (see *Detecting Other Packages*)
- Standard sandbox utilities (`math`, `string`, etc.)

**Example:**

```tsv
fileName:filepath	typeName:type_spec	rowValidators:{validator_spec}|nil
Items.tsv	Item	{"self.minLevel <= self.maxLevel or 'minLevel must be <= maxLevel'",{expr="self.price < 10000 or 'price seems high'",level="warn"}}
```

More readable Lua format:
```lua
{
    "self.minLevel <= self.maxLevel or 'minLevel must be <= maxLevel'",  -- error (default)
    {expr = "self.price < 10000 or 'price seems unusually high'", level = "warn"},  -- warning
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
- `ctx` - Writable table shared across all file validator expressions
- Published contexts from earlier-loaded files
- Code libraries defined in the manifest
- `packages` / `versionSatisfies` - the loaded-package set (see *Detecting Other Packages*)
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
- `ctx` - Writable table shared across all package validator expressions
- All published contexts (including from dependency packages)
- Code libraries defined in the manifest
- `packages` / `versionSatisfies` - the loaded-package set (see *Detecting Other Packages*)
- Helper functions (see below)

**Example in Manifest.transposed.tsv:**

```tsv
package_validators:{validator_spec}|nil	{"all(files['items.tsv'], function(item) return any(files['categories.tsv'], function(cat) return cat.id == item.category end) end) or 'all items must reference valid category'"}
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

#### Type Introspection Helpers

| Function | Description |
|----------|-------------|
| `listMembersOfTag(tagName)` | Returns sorted array of member type names for a type tag, or `nil` if not a tag |
| `isMemberOfTag(tagName, typeName)` | Returns `true` if `typeName` is a member of the tag (directly, via subtype, or via nested tag) |

### Quota and Performance

| Validator Type | Operation Quota |
|----------------|-----------------|
| Row validators | 1,000 operations per row |
| File validators | 10,000 operations per file |
| Package validators | 100,000 operations per package |
| Pre-processors | 50,000 operations per file |

Row validators run per-row, so complex validators will slow parsing. File and package validators run once, allowing more intensive checks.

### Error Reporting

**Row Validator Messages:**

```
[ERROR] Row validation failed in Items.tsv row 42:
  Validator: self.minLevel <= self.maxLevel or 'minLevel must be <= maxLevel'
  Error: minLevel must be <= maxLevel

[WARN] Row validation warning in Items.tsv row 15:
  Validator: self.price < 10000 or 'price seems unusually high'
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

## Mod Overrides

**Mod overrides** let a child (dependent) package **change data declared by a parent
package without forking the parent's files**. The motivating cases are mod-on-game,
regional config over base config, or a customer tenant on top of product defaults: the
parent ships authoritative data, and a child amends it non-invasively. Every override is
expressed as ordinary TSV the parent never sees, so the parent package stays untouched and
upgradable. (This chapter is the mechanism reference; for the task-oriented view — which
feature fits which modding use-case, and how many mods coexist — see the
[Modding Guide](MODDING.md).)

There are four mechanisms; a child package can use any combination:

| Mechanism | `Files.tsv` / manifest field | What it does |
|-----------|------------------------------|--------------|
| **Schema overlay** | `schemaOverlayOf` (file) | Loosen a parent column: change its default, widen its type, or downgrade/suppress one of its validators. |
| **Row patch** | `patchOf` (file) | Add / remove / update / replace specific parent rows by primary key, including list/map cell deltas. |
| **Bulk patch** | `bulkPatchOf` (file) | Update or remove parent rows selected by a `where` expression (e.g. "double the price of every medicine"). |
| **Package pre-processor** | `preProcessors` (manifest) | Full programmatic mutation of the merged-and-patched state — the escape hatch for what the declarative mechanisms can't express. |

### Pipeline Order

Overrides slot into the load pipeline at fixed points:

```
parse schema overlays  →  widen types / change defaults (before parent cells are typed)
parse all files        →  parent + child files loaded
own-package pre-processors
apply patches          →  row patches + bulk patches, in package load order
recompute =expr        →  re-evaluate downstream same-row =expr cells (so processors see them)
package pre-processors  →  package-scoped processors + rerunAfterPatches re-runs
recompute =expr        →  again, to fold in cells the processors themselves changed
validators             →  re-run once, against the fully overridden state
```

Two consequences worth internalising:

- **Schema overlays run first**, before any cell is type-checked — so a column a mod widened
  to accept negative numbers is already widened by the time a patch sets a negative value.
- **Validators run once, at the end, against the final state.** A parent validator is
  re-applied to the patched data, so a mod that introduces a violation is caught loudly
  (unless a schema overlay downgraded that validator).

### Targeting a Parent File

`schemaOverlayOf` / `patchOf` / `bulkPatchOf` name their parent file by **basename** —
any directory prefix in the value is ignored, and the target binds to exactly **one**
loaded file. When two loaded packages ship the same file name, an unqualified target is
**ambiguous**: it resolves deterministically to the alphabetically-first full name, with
a warning naming every candidate. To bind the target to a specific package's file,
**qualify it with the package id**:

```tsv
fileName:filepath	typeName:type_spec	patchOf:override_target|nil
SharedPatch.tsv	patch	some.mod:Shared.tsv
```

The qualifier is the owning `package_id` before a `:` (matched case-insensitively;
ownership is by directory, the same rule package processors use). Because `:` is not a
legal `filepath` character, the qualified form needs the column declared with the
**`override_target`** type (a filepath optionally prefixed with a package qualifier) —
the plain `filepath|nil` spelling remains valid for unqualified targets, and both
header spellings are recognised. A qualifier naming an unloaded package, or a package
that owns no such file, is a load error; a target basename no loaded file has is a load
error too — unless the file opts into tolerance. Gate the row with `onlyIfPackages`
when the target belongs to an optional **package** (see *Conditional Files*), or set
`ifMissing` to `warn`/`silent` when the target file only exists in some **versions** of
a present package (see *Tolerating Missing Targets*).

(`joinInto` is different: it targets the **full path as listed in `fileName`**, not a
basename, so it does not take a package qualifier.)

### Downstream `=expr` Recompute

When an override changes a cell, any **other `=expr` cell in the same row** that reads it
(via `self.x`) is **re-evaluated**, so derived values stay consistent without the mod having
to patch them too. For example, if a parent column is
`totalDamage:float:=self.baseDamage*…` and a patch changes `baseDamage`, `totalDamage`
recomputes automatically. This covers explicit `=expr` cells and columns with a default
`=expr` (applied to an empty cell); re-evaluation runs in dependency order, so chains
(`a` reads `b` reads a patched `c`) resolve correctly. A cell an override sets **directly**
keeps its explicit value (it is not recomputed), and recomputed values are not baked into
source (the `=expr` is preserved). The recompute runs in **two passes** — once after the
patches (so a package-scoped pre-processor reads consistent derived values) and once after
those processors (to fold in any cells they changed); it is idempotent, so the double pass
is safe. **Cross-row** dependencies and `=expr` cells that read a **published constant** a
patch changed are *not* recomputed — patch those downstream cells explicitly, or use a
package-scoped pre-processor.

### No-Bake Invariant

Overrides mutate the in-memory model for building and validation, but they are **never
written back into the parent's source files**. The reformatter skips any file that was
patched, and schema overlays keep the parent's *declared* type and default in the source
text. Exporters (JSON/SQL/…) **do** see the overridden data; only the on-disk parent TSV
stays byte-for-byte the author's original. This is the same "derived data is not
source-of-truth" rule that governs `=expr` defaults and pre-processor output.

### Detecting Other Packages

Every expression surface — `=expr` cells, COG blocks, row / file / package validators,
bulk-patch `where` selectors, and pre-processors — can inspect the **loaded-package
set**:

- **`packages`** is a read-only table mapping each loaded `package_id` to a
  `{name, version}` record; an absent package indexes to `nil`, so presence is a simple
  truthiness test.
- **`versionSatisfies(op, required, installed)`** compares versions with the same
  operators the manifest `dependencies` field uses (`=`, `>`, `>=`, `<`, `<=`, `~`, `^`).

```lua
packages["tutorial.core"] ~= nil                        -- is the core loaded?
packages["some.mod"] and packages["some.mod"].version    -- its version (a string), or nil
versionSatisfies(">=", "2.0.0", packages["some.mod"].version)
```

This is the *expression half* of optional mod compatibility: a bulk-patch `where`
selector or a validator can branch on another mod's presence or version. The
*declarative half* — skipping a whole file when a package is absent — is
`onlyIfPackages`, below. Two caveats: **manifest-file** COG blocks cannot see
`packages` (manifests load while the package set is still being resolved), and
`packages` / `versionSatisfies` are **reserved names** — a code library or
`publishContext` claiming either fails the load.

### Conditional Files (`onlyIfPackages`)

A `Files.tsv` row may list package ids in an optional `onlyIfPackages` column:

```tsv
fileName:filepath	typeName:type_spec	patchOf:filepath|nil	onlyIfPackages:{package_id}|nil
SeasonalPatch.tsv	patch	Item.tsv	"some.seasons.mod"
```

Terminology: such a row is **gated** — the `onlyIfPackages` condition is its
**gate**, and each listed package id is a **gate id**. Log messages and the
`--check-conflicts` report use these terms.

The row is active only when **every** listed package is loaded (a list is an AND; for
OR, use two rows). When any listed package is absent, the row is skipped exactly like
a variant-filtered row: the file is **not parsed, not exported, and exempt from the
on-disk existence check** — and, crucially for compat patches, a gated `patchOf` /
`bulkPatchOf` / `schemaOverlayOf` target that only exists in the absent package does
**not** produce a "target not found" error. Each skip is logged at info level with the
missing package id.

This is the **optional-compatibility idiom**: a mod ships built-in support for another
mod that activates only when that mod is installed, instead of publishing a separate
"A+B compatibility patch" package. Pair the gate with a manifest
`load_after: {"the.other.mod"}` — `load_after` supplies the *ordering* half (a no-op
when the package is absent), `onlyIfPackages` the *presence* half. The tutorial
demonstrates this with `tutorial/expansion/SeasonalPatch.tsv`, gated on the
not-installed `tutorial.seasons` package.

One sharp edge: a **misspelled package id** is indistinguishable from an absent
package — the file is silently (info-log only) skipped forever. Check the log line if
a compat file unexpectedly fails to apply, or run `--check-conflicts`: it flags gate
ids that match no loaded package and are named by no manifest (likely typos), with a
did-you-mean when a known id is a close spelling match (case slips, swapped or
dropped characters).

`onlyIfPackages` gates on **presence**; for a compat file whose target rows or files
exist only in some **versions** of a present package, add
[`ifMissing`](#tolerating-missing-targets-ifmissing) — together they complete the
compat-patch toolkit.

### Conflict Resolution

When two packages override the same thing, **package load order decides** (derived from
`dependencies` / `load_after`), and the **last writer wins** for row/cell patches. Schema
overlays compose more gently: defaults are last-wins, type widenings are *unioned*, and a
suppressed validator takes the *lowest* severity any overlay asked for — so multiple mods
loosening the same column rarely conflict.

For packages that should never compose at all (say, two total overhauls of the same
base game), a manifest can declare `conflicts` (see *Manifest Fields*): loading both
fails with an explicit error instead of last-writer-wins silently picking a winner.

Package load order is fully deterministic — and, for unrelated packages,
**user-controllable**. Dependency edges (`dependencies` / `load_after`) always dominate:
the engine repeatedly loads the lowest-ranked package whose prerequisites have all
loaded. A package's rank is the position of its **input root directory** in the
directory list passed to the loader (CLI argument order), then alphabetical
`package_id` among packages from the same root. A host application (game launcher, mod
manager) therefore controls the relative order of independent mods simply by the order
it passes their directories — no manifest edits needed. The order is stable across runs
(it never depends on filesystem or hash-table iteration order), so conflict resolution —
and every diagnostic derived from it (`--explain-patch`, `--check-conflicts`,
`--export-merged`) — is reproducible.

### Inspecting Overrides

Three reformatter flags make the override layer observable (see [REFORMATTER.md](REFORMATTER.md)):

- **`--export-merged[=<dir>]`** writes a snapshot of every file with all overrides applied
  (in each file's own format), so you can see — or diff — the final merged data.
- **`--explain-patch[=<file>[:<pk>[:<column>]]]`** prints a **lineage report**: which
  override (which patch/overlay file, attributed as `package.id:File.tsv`, or
  `package:<id>` for a processor) set each cell, row, or column, including the full
  chain when several mods touch the same cell. Lineage tracking is off
  by default and adds no cost to a normal run.
- **`--check-conflicts`** prints a **conflicts-only report**: just the cells, rows, and
  column defaults that two or more sources overwrote (each as its apply-order chain,
  last writer wins), plus rows one mod removed/replaced while another wrote to them.
  Benign composition — list/map deltas, `widenTo` unions, patching a row another mod
  added — is not flagged. It also runs the `onlyIfPackages` typo check (gate ids
  matching no known package id). Conflicts are legal by design, so the exit code
  stays 0; change the winner by reordering input roots or with `load_after`.

---

### Schema Overlays

A schema overlay only ever **loosens** a parent column, so no parent row that used to parse
can stop parsing. Declare it in `Files.tsv` with `typeName=SchemaOverlay` and
`schemaOverlayOf` naming the parent file:

```tsv
fileName:filepath   typeName:type_spec   schemaOverlayOf:filepath|nil   loadOrder:number
ItemPricePolicy.tsv SchemaOverlay        Item.tsv                       2
```

Each row of the overlay file targets **one parent column** (column 1, `column:name`, is the
primary key — so all changes to one column go on a single row):

```tsv
column:name   widenTo:type_spec|nil   newDefault:string|nil   suppressValidator:expression|nil   validatorLevel:overlay_level|nil
price         gold|int                                        self.price > 0 or 'price must be positive'   warn
cooldown                              3.0
```

| Field | Effect | Safety |
|-------|--------|--------|
| `widenTo` | Replace the column type with a wider one (must **strictly extend** the parent's — `gold` → `gold\|int`). Narrowing is rejected at load; an identical type warns as a no-op. | Every value valid under the old type is still valid. |
| `newDefault` | Replace the default applied to **empty** cells (literal or `=expr`). | Populated cells are untouched. |
| `suppressValidator` + `validatorLevel` | Match a parent validator by its expression text; `validatorLevel` is one of `error \| warn \| none` (`overlay_level`). `none` removes it, `warn`/`error` rebinds its severity. | The validator still runs; only its consequence changes. |

What overlays **cannot** do (these are migration-tool territory, not overrides): narrow a
type, rename/drop a column, change the primary key, add a column (use `joinInto`), or
*tighten* a validator. Scope note: validator suppression targets a file's row/file
validators; validators embedded in a `custom_type_def` are out of scope.

### Row Patches

A **patch file** (`typeName=patch`, `patchOf=Target.tsv`) adds, removes, or edits specific
parent rows. Column 1 is the parent's primary-key column (same name); a `patchOp:patch_op`
column carries the operation:

```tsv
name:name   patchOp:patch_op   price:gold|int|nil   weight:float|nil   element:Element|nil
sword2      add                150                  1.5                Fire
oldSword    remove
sword       update                                  =self.weight*2     =nil
```

`patch_op` is the enum `add | remove | update | replace`:

| op | Meaning |
|----|---------|
| `add` | Insert a new row; the key must not already exist. Empty cells use the parent column's default. |
| `remove` | Delete the row with the matching key; other cells ignored. A missing key warns (no-op). |
| `update` | Edit named cells of an existing row. **An empty cell means "leave unchanged"** (not "use default"). A missing key is an error — unless the file opts into tolerance, see [`ifMissing`](#tolerating-missing-targets-ifmissing). |
| `replace` | Wholesale `remove` + `add`. A missing key simply appends (upsert). |

Key rules:

- **Empty = leave unchanged** in an `update` row. To explicitly set a nullable column to
  `nil`, use the expression **`=nil`** (the parent column must be nullable, or it errors).
- A given parent primary key appears **at most once** per patch file — coalesce all edits to
  one row into one patch row.
- The patch column declares its **own** type (conventionally the parent's type made
  nullable). The value is parsed there, then **re-validated against the parent's column** at
  apply time — so a schema-overlay widening already in effect is what lets a patch set an
  otherwise out-of-range value.

#### List and Map Cell Deltas

To **merge into** a parent collection cell instead of replacing it, use verb-prefix
**companion columns** named after the target column. For a list column `<col>`:

| Companion column | Effect |
|------------------|--------|
| `append_<col>` / `prepend_<col>` | Insert values at the tail / head (order preserved). |
| `remove_<col>` / `remove_last_<col>` | Drop the first / last occurrence of each value. |
| `replace_<col>` | Replace the whole list (same as listing `<col>` in the `update` row). |
| `replace_oldvalue_<col>` + `replace_newvalue_<col>` | Replace a value **in place, by value** (position preserved); `replace_last_oldvalue_<col>` / `replace_last_newvalue_<col>` target the last match. |

Map columns support `append_<col>` (merge entries), `remove_<col>` (drop keys), and
`replace_<col>` only (maps are unordered — no `prepend_`, no in-place pair). If a parent
column is *literally* named like a companion (e.g. a real `append_tags` column), the literal
match wins and a warning fires so you can disambiguate. Sub-record fields are patched by
their dotted path (`stats.attack`) with no special syntax — they are ordinary exploded
columns.

#### Tolerating Missing Targets (`ifMissing`)

A compat patch that supports several versions of its target — where a row exists in one
version only — cannot be written under the default severities (a missing `update` key is an
error). The optional `Files.tsv` column `ifMissing:missing_policy|nil` sets a per-file
tolerance, on the same row as `patchOf` / `bulkPatchOf` / `schemaOverlayOf`:

| Policy | Effect when a target is missing |
|--------|--------------------------------|
| `error` (default, same as leaving the column empty) | The standard severities: `update` on a missing key and a `replace_oldvalue_` value not found are load **errors**; `remove` of a missing key warns (no-op); a whole target *file* that matches no loaded file is a load **error**. |
| `warn` | Every such miss becomes a **logged no-op**: the row (or the whole patch/overlay file, when the target file itself is absent) is skipped with a warning. |
| `silent` | Same no-ops, without the log noise (including the `remove`-missing and list-`remove_` warnings). |

Notes:

- The policy is **per override file**, not per row — a compat file is tolerant as a unit.
- `add` on an **existing** key stays an error under every policy: that is a collision,
  not a version gap. `replace` never needed tolerance — a missing key simply appends
  (upsert).
- Whole-file tolerance applies to row patches, bulk patches, **and schema overlays**
  alike; it covers the "target mod is present, but this file only exists in its newer
  versions" case that [`onlyIfPackages`](#conditional-files-onlyifpackages) (package
  granularity) cannot express. Gate on **presence** with `onlyIfPackages`, tolerate
  **version drift within presence** with `ifMissing`.

### Bulk Patches

A **bulk patch** (`typeName=bulk_patch`, `bulkPatchOf=Target.tsv`) edits parent rows chosen
by a selector rather than by key. Column 1 is a unique **rule name**; a required
`where:expression` selects rows; `patchOp` is `update` or `remove`; the remaining
`expression`-typed columns are the transforms:

```tsv
ruleName:name   patchOp:patch_op   where:expression                 price:expression|nil
epicSurcharge   update             row.rarity == 'Epic'             =row.price + 100
dropBroken      remove             row.tags has 'deprecated'
```

- `where` is evaluated for **every** parent row, in the validator sandbox (`self` / `row` is
  the candidate, with helpers like `any` / `count` / `all` and published contexts available).
- For an `update`, each non-empty transform cell is applied to each matched row: a value
  starting with `=` is an **expression evaluated against the matched target row** (`self` =
  that row, so `=row.price + 100` does what you expect); otherwise it is a literal parsed by
  the parent column.
- A selector that matches **zero** rows warns (likely a typo); a `where` that throws is a
  reported error and that rule is skipped.

Row-patch and bulk-patch files can target the same parent and compose — all patches apply
together in package load order.

### Package-Scoped Pre-Processors

When the declarative mechanisms can't express an override, a package can run a **programmatic
pre-processor** declared in its **manifest** (not a `Files.tsv` column):

```tsv
preProcessors:{processor_spec}|nil   {expr="(function() … end)()",requires={"otherMod.id"}}
```

These run **after** all patches are applied and **before** validators, so they see — and the
validators see the effects of — the fully merged-and-patched state. The sandbox is the
package-validator sandbox (`files` keyed by lowercased basename, the read-side helpers, `ctx`,
`packageId`) **plus** the processor write helpers `setCell` / `clearCell` / `copy` and a
two-argument `rowByKey(file, key)`:

```lua
-- bump every Epic item's price across the merged data
(function()
  for _, r in ipairs(files['item.tsv']) do
    if r.rarity == 'Epic' then setCell(r, 'price', r.price + 100) end
  end
  return true
end)()
```

`processor_spec` is documented under [Pre-Processors](#pre-processors); the two fields that
matter at package scope are `requires` (ordering, below) and `rerunAfterPatches` (which makes
a *parent's own file-level* processor re-run here, against the patched data — so derived data
like inverse back-references reaches mod-added rows; those processors must be idempotent).

#### Cross-Package Ordering

Package-scoped processors run in **package load order** by default. A processor can add an
explicit edge with `requires={"pkg.id", …}` — "every package-scoped processor from `pkg.id`
must run before me". The engine topologically schedules the packages (ties broken by load order, so the
schedule is deterministic). A **cycle** in the `requires` graph is a hard error; a `requires`
naming a package that **isn't loaded** is a warning (the constraint is vacuous) and the load
continues.

#### Write Scope — and Why It's Limited

A package-scoped processor may **read** every file, but it may only **write**:

1. files its **own** package declares, and
2. parent files it has **declared a patch for** (a row or bulk patch).

Attempting `setCell` on any other file is a reported error. The rationale follows directly
from the override design:

- **Read is wide, write is narrow** — the same asymmetry as file validators (see everything,
  change nothing) vs. file pre-processors (write only their own file). Reading is safe;
  writing is the conflict-prone operation, so it is the one that is fenced.
- **A patch is an auditable, declared intent.** A patch file is plain TSV — reviewable in a
  PR, diffable across versions, greppable. Requiring a patch declaration before a programmatic
  write means **every cross-package mutation is announced somewhere a human or tool can see**,
  instead of being buried inside an opaque expression. The patch supplies the declarative
  *what/where*; the processor supplies the *how*.
- **Conflict tracking depends on it.** Load-order "last writer wins" and the `requires`
  schedule are keyed on which packages modify which files. A processor silently writing a file
  it never declared would be an invisible writer that escapes that bookkeeping.
- **It preserves the non-invasive boundary** that the whole feature exists to provide: a mod
  shapes its own data freely and refines the parent files it has *announced* it modifies — but
  it cannot silently rewrite arbitrary parent or sibling-mod files.

#### Opening a File Without Changing It

If a package-scoped processor needs to write a parent file for which you have **no actual
patch to make**, grant write scope by declaring a **content-free patch file**. Write scope comes from
the `patchOf` *declaration*, not from the patch's content, and an empty patch applies as a
no-op. The cleanest form is a **header-only patch** — a valid patch header (primary-key
column + `patchOp`) with **zero data rows**:

`Files.tsv`
```tsv
fileName:filepath   typeName:type_spec   patchOf:filepath|nil   loadOrder:number
Open.tsv            patch                Item.tsv               2
```

`Open.tsv` (header only, no rows)
```tsv
name:name	patchOp:patch_op
```

This loads cleanly, changes nothing, and authorises the package's package-scoped processor to
write `Item.tsv`. (A no-op `update` row — naming a real key with all other cells blank — works too,
but must name existing keys.) Note two things: the empty patch is still a **visible, declared
intent**, which is exactly the property the scope rule protects; and declaring it marks the
target as a patched file, so the reformatter will not rewrite that source in place (correct
here anyway, since your processor mutated it).

---

## Graph Types

Three built-in record-type families model graph-shaped data, in increasing
strictness:

| Type | Shape | Engine-owned fields | Cycles | Roots |
| --- | --- | --- | --- | --- |
| `basic_graph_node` | Undirected graph | `graphLinks:{node_name}\|nil` | allowed | n/a |
| `graph_node` | Directed acyclic graph (DAG) | `graphParents:{node_name}\|nil`, `graphChildren:{node_name}\|nil` | forbidden | ≥1 |
| `tree_node` | Tree | same as `graph_node` | forbidden | exactly 1 |

Author files opt in by declaring `superType=<one of the three>` in `Files.tsv`
— the same discovery mechanism `enum` and `custom_type_def` use. Once a file
is marked as a graph family, the engine **auto-wires** a pre-processor that
fills in the inverse link field, plus the structural validators appropriate
for the family (refs-exist, cycle-free, tree shape).

### Field Naming Convention

Per the file's [naming conventions](#naming-conventions) section, field names
use camelCase starting with a lower-case letter. The engine-owned graph
fields all share the `graph` prefix — `graphLinks`, `graphParents`,
`graphChildren` — to mark them as engine-managed and avoid colliding with
author-defined `parents` / `children` fields on user-extended record types.

### The `node_name` Primary-Key Type

`node_name` is a built-in alias of **`composable_name`** — a `name`
(identifier-chain ASCII string) with three additional restrictions, all
of which keep any compound `<a>__<b>` encoding using `__` as a separator
unambiguous:

- **must not contain `__`** — `__` is the separator itself, so a name
  containing `__` would create extra separators inside one half.
- **must not start with `_`** — otherwise a compound key from `"x"` to
  `"_y"` would encode as `"x___y"` (3 underscores), the same string as a
  compound key from `"x_"` to `"y"`. The decoder can't tell them apart
  and silently picks one interpretation; for graph edges, PK uniqueness
  then merges what should be two distinct edges into one.
- **must not end with `_`** — symmetric to the previous case.

Single underscores are still fine anywhere they're not at the start/end of
the whole string: `a_b`, `foo._bar`, `foo_.bar` are all valid.

Together these rules guarantee every compound-key string has exactly one
`__` separator, splits cleanly on the first match, and round-trips
losslessly. The graph edge-key types (`undirected_edge_key`,
`directed_edge_key`) are the first consumer, but the underlying
`composable_name` is useful in any future compound-key context — hence
the general name. `node_name` remains as the readable alias for the
graph-node use case; both names resolve to the same parser, and writing
`name:node_name` in a record type is equivalent to `name:composable_name`.

We considered allowing on `_` in front and/or behind the `node_name`, by
using 3 `_` instead of two as separator, but then we could have the case
where the compound key would have 4 `_` in the middle, and we would not
know where to "cut".

The PK column of every graph-node-family file MUST be `name:node_name`
(directly or via an extension). Error messages naming the type will
say `Bad composable_name ...` — the canonical type name, same convention
as for any other aliased type (e.g. errors for the `gold` alias say
"Bad uint").

### Auto-Wired Completion Pre-Processor

For every file with a graph-family `superType`, the engine prepends a
completion pre-processor (priority 50, `rerunAfterPatches=true`) that
symmetrises the link fields **before** any validator runs:

- `basic_graph_node`: if `A.graphLinks ⊇ {B}`, then `B.graphLinks` is
  ensured to contain `A`.
- `graph_node` / `tree_node`: if `A.graphChildren ⊇ {B}`, then
  `B.graphParents` is ensured to contain `A`; and vice versa. Both passes
  run, so authors can declare edges from either side.

**Author contract:** declare each edge on **one** side only. The engine
fills in the other side at load time. Per the
[Pre-Processors §Round-Trip](#pre-processors) behaviour, the inferred
back-references are **not** written back to disk on reformat — they are
derived state, recomputed on every load. Mixing authored declarations on
both sides is harmless (duplicates are ignored), but the derived additions
won't survive a reformatter round-trip.

### Auto-Wired Validators

Stacked per family, all level `error`:

| Validator | basic | graph_node | tree_node |
| --- | --- | --- | --- |
| Every name in a link field references a row in the file (`graphRefsExist`) | ✓ | ✓ | ✓ |
| No cycle via `graphChildren` (`graphAcyclic`) | | ✓ | ✓ |
| ≤1 parent per node, exactly one root post-completion (`graphTreeShape`) | | | ✓ |

User-authored file validators run **before** the auto-wired ones, so
authoring-specific errors surface before the structural checks fire.

### Edge Files (`edgesFor`)

Many graphs need per-edge data — weights, gating conditions, dialogue
triggers — that doesn't fit on either endpoint. Rather than duplicating
the data on both nodes (and writing a symmetry validator), authors can
attach a dedicated **edge file** that holds one row per edge.

The edge side has its own three-type family that parallels the node side:

| Type | Pairs with | PK column |
| --- | --- | --- |
| `basic_graph_edge` | `basic_graph_node` | `name:undirected_edge_key` |
| `graph_edge` | `graph_node` | `name:directed_edge_key` |
| `tree_edge` | `tree_node` | `name:directed_edge_key` |

Each edge record also carries a `comment:comment|nil` column inherited from
the family root, giving every edge file a free-text description column out
of the box.

The PK of an edge row is the compound key `<a>__<b>`:

- `undirected_edge_key` parses, validates each half as a `node_name`,
  **sorts** ascending lexicographically (so `B__A` and `A__B` parse to the
  same canonical `A__B`, and the engine's normal PK-uniqueness rule catches
  duplicates with no new code path), and warns on reorder.
- `directed_edge_key` parses and validates each half but preserves authored
  order. Self-loops (`A__A`) are syntactically valid; the cycle validator
  flags them for DAG/tree contexts.

Authors **attach** an edge file to a node file by setting the `edgesFor`
column in `Files.tsv`:

```tsv
fileName:filepath  typeName:type_spec  superType:super_type  ...  edgesFor:filepath|nil
Quests.tsv         Quest               graph_node            ...
QuestEdges.tsv     QuestEdge           graph_edge            ...  Quests.tsv
```

The engine then auto-runs four consistency checks against the attached
node file, **after** completion has populated the back-references:

1. The `edgesFor` target file must exist (matched by lower-cased filename).
2. The edge file's family must match the node file's family
   (basic ↔ basic, directed ↔ directed; both `graph_edge` and `tree_edge`
   count as directed).
3. Every edge row's endpoints must reference rows that exist in the node
   file.
4. Every edge row's `(a, b)` must correspond to a declared link in the
   node file — i.e. `b ∈ a.graphChildren` for directed, or
   `b ∈ a.graphLinks` for basic. An edge without a matching link in the
   node file is an error; a link **without** an edge row is fine
   (unannotated links are common).

A node file may have **zero or one** edge file. Multiple edge files for
the same node file is an error — authors who need extra per-edge columns
should extend the edge record type with more columns rather than adding a
second edge file.

### Transitively Extending a Graph Family

User-defined types that extend a graph family inherit the auto-wiring.
Family detection walks the `Files.tsv` superType / extends chain
transitively:

```tsv
# core/Files.tsv
Quest.tsv          Quest          graph_node    ...

# expansion/Files.tsv (extends across packages)
EpicQuest.tsv      EpicQuest      Quest         ...
```

`EpicQuest.tsv` gets the same completion pre-processor and validators as a
direct `graph_node` file. The chain walk is bounded (default depth 32) and
safe against cycles in the extends map.

`tree_node` and `tree_edge` are plain aliases of `graph_node` and
`graph_edge` respectively — at the parser level they're indistinguishable
from their parent. The engine tells trees apart from DAGs by the **literal
`superType=` string** the author wrote in `Files.tsv`, not by parser
identity. This means user-defined `MyTree extends tree_node` is recognised
as a tree-family file (gets the tree-shape validator) while
`MyDag extends graph_node` is not.

### Calling Graph Helpers from Validator and Processor Expressions

The validator sandbox exposes the three structural validators
(`graphRefsExist`, `graphAcyclic`, `graphTreeShape`) so user expressions
can call them too — useful when an extended type wants to re-run a
structural check after additional mutation, or to apply the check
on-demand from a `package_validator`.

The processor sandbox additionally exposes the two completion helpers
(`completeBasicGraph(rows)`, `completeDirectedGraph(rows)`), so a custom
pre-processor that mutates link data can call completion again to
re-symmetrise.

### Example: Skill Tree with Edges

A skill prerequisite DAG with per-edge data. See
[tutorial/README.md §SkillTree.tsv + SkillEdges.tsv](tutorial/README.md)
for the full walkthrough.

`Files.tsv` (excerpt):

```tsv
fileName:filepath  typeName:type_spec  superType:super_type  ...  edgesFor:filepath|nil
SkillTree.tsv      SkillTree           graph_node            ...
SkillEdges.tsv     SkillEdge           graph_edge            ...  SkillTree.tsv
```

`SkillTree.tsv`:

```tsv
name:node_name  graphParents:{node_name}|nil  graphChildren:{node_name}|nil  maxLevel:ubyte  description:text
perception                                                                    5             Notice subtle details
stealth                                                                       5             Move unseen
tracking        "perception","stealth"                                        3             Follow a quarry
```

After load, `perception.graphChildren = {"tracking"}` and
`stealth.graphChildren = {"tracking"}` are filled in by the completion
pre-processor (`graphChildren` cells stay empty on disk on reformat).

`SkillEdges.tsv`:

```tsv
name:directed_edge_key   requiredLevel:ubyte  comment:comment|nil
perception__tracking     3                    Notice subtle tracks
stealth__tracking        2                    Move quietly while following
```

A row like `perception__missing` (where `missing` isn't a row in
`SkillTree.tsv`) would fail the auto-wired endpoint-exists check;
`stealth__perception` (no such link in `SkillTree.tsv`) would fail the
edge-must-match-link check.

## Type Wiring (Attaching Behaviour to a Type)

A package can attach pre-processors, row validators, and file validators
to a typeName so every file extending that type inherits them. There are
two ways to do it — a **pure-data path** (you author a TSV file, no Lua
needed) and a **code-library path** (a manifest-declared function runs
once at engine init with access to a richer registration API).

Both paths feed the same engine-internal registry that the built-in
auto-wiring (Type files, enum files, custom_type_def files, graph_node
families) uses. There is no privileged path for built-ins.

### Pure-Data Path: `type_wiring_def` Files

A file whose `typeName` is (or extends) the built-in record type
`type_wiring_def` is treated as a "wiring file." Each row registers
wiring for one typeName. The record shape:

```text
typeName:name
preProcessors:{processor_spec}|nil
rowValidators:{validator_spec}|nil
fileValidators:{validator_spec}|nil
```

Convention is to name such files `TypeWiring.tsv`, but the engine
recognises them by record type rather than basename — you can name your
file anything you like, as long as `Files.tsv` lists it with the right
typeName.

Example: a package wants every file extending its `Item` type to run a
"non-empty name" file validator and a normalisation pre-processor.

`Files.tsv`:

```tsv
fileName:filepath  typeName:type_spec  superType:super_type  baseType:boolean  loadOrder:number  description:text
ItemWiring.tsv     ItemWiring          type_wiring_def       true              5                 Engine-attached behaviour for Item files
Sword.tsv          Sword               Item                  false             10                Swords
Bow.tsv            Bow                 Item                  false             10                Bows
```

`ItemWiring.tsv`:

```tsv
typeName:name  preProcessors:{processor_spec}|nil  fileValidators:{validator_spec}|nil
Item                                               "count(rows) > 0 or 'item file is empty'"
```

The wiring file's `loadOrder` should be **lower** than the files it
affects, so the registration is in place by the time those files load.
This is the same ordering convention used by `Type` files,
`enum` files, and `custom_type_def` files.

Unknown typeNames register harmlessly: the dispatcher only fires the
contributions when a file's extends chain actually reaches the
registered name. A wiring entry for a never-extended type is a silent
no-op.

`type_wiring_def` files can declare expressions (strings) but cannot
declare Lua function values — for that, use the bootstrap path.

### Code-Library Path: Manifest `bootstrap` Field

A package can declare one or more bootstrap entries in its
`Manifest.transposed.tsv`:

```text
bootstrap   {{library:name, fn:name}}|nil
```

Each entry names a function exported by one of the package's own
`code_libraries`. After every package's code libraries are loaded but
before any descriptor file is parsed, each bootstrap function is
invoked once with an `api` argument that proxies onto the type-wiring
registry. Bootstraps run in package-dependency order, so a child
package can register against typeNames a parent's bootstrap just
declared.

The `api` argument exposes two methods:

| Method | Purpose |
| --- | --- |
| `api.register(typeName, contributions)` | Per-typeName cascade contributions: `onLoad`, `preProcessors`, `rowValidators`, `fileValidators`. |
| `api.registerModule(moduleName, declarations)` | Module-level engine-init declarations: `descriptorColumns` (extra Files.tsv columns), `sandboxHelpers` (functions callable from validator/processor expressions), `enginePostPasses` (cross-file checks). |

After the bootstrap phase ends, the `api` is sealed: any subsequent
call — including one through a proxy reference a bootstrap stashed
into library state for later use — raises an error. The api is meant
to be used inside the bootstrap call only.

Example: a package adds a custom `Files.tsv` column and a post-load
consistency check.

`Manifest.transposed.tsv` (excerpt):

```text
package_id        MyPackage
code_libraries    "wiring",libs/wiring.lua
bootstrap         {library="wiring",fn="bootstrap"}
```

`libs/wiring.lua`:

```lua
local M = {}

function M.bootstrap(api)
    api.registerModule("my_package", {
        descriptorColumns = {
            {name = "tier", type = "integer|nil", fieldOnMeta = "lcFn2Tier"},
        },
        enginePostPasses = {
            function(tsv_files, joinMeta, badVal)
                -- Cross-file consistency check, returning true on success.
                return true
            end,
        },
    })
end

return M
```

### What Each Path Can Contribute

| Slot | Engine code | `bootstrap` (code library) | `type_wiring_def` file |
| --- | --- | --- | --- |
| `onLoad` (Lua function) | Yes | No (cannot mutate parser-registration tables from the sandbox) | No (TSV cells can't encode Lua function values) |
| `preProcessors` / `rowValidators` / `fileValidators` (per typeName) | Yes | Yes via `api.register` | Yes (one row per typeName) |
| `descriptorColumns` (extra Files.tsv columns) | Yes | Yes via `api.registerModule` | No (would be circular: a Files.tsv row can't reference a column Files.tsv itself doesn't yet recognise) |
| `sandboxHelpers` (functions for expression sandbox) | Yes | Yes via `api.registerModule` | No (TSV cells can't encode Lua function values) |
| `enginePostPasses` (cross-file checks) | Yes | Yes via `api.registerModule` | No (same reason as sandbox helpers) |

If your package needs only the per-typeName spec-list slots (the
common case), use a `type_wiring_def` file — it's simpler. Reach for
the bootstrap path only when you need `descriptorColumns`,
`sandboxHelpers`, or `enginePostPasses`.
