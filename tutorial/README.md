# Chronicles of Tabulua - Tutorial

A comprehensive tutorial for **TabuLua** (v0.11.0), themed as an RPG game data system.
It demonstrates virtually every feature of the TabuLua typed TSV format through two
interconnected packages: a core game and an expansion mod.

## Prerequisites

- **Lua 5.4** with TabuLua dependencies installed
- Run from the TabuLua project root directory

## Directory Structure

```
tutorial/
  core/                              # Package: tutorial.core (base game)
    Manifest.transposed.tsv          # Package manifest with custom types
    Files.tsv                        # File registry with validators
    CoreTypes.tsv                    # Custom type definition file (v0.10.0)
    Element.tsv                      # Enum: elemental damage types
    Rarity.tsv                       # Enum: item rarity tiers
    Constant.tsv                     # Published game constants + expressions
    Item.tsv                         # Items: long IDs, enums, arrays, unions
    Item.en.tsv                      # Localization: file joining demo
    Icon.tsv                         # Icons: hexbytes + base64bytes binary types
    Creature.tsv                     # Creatures: all 4 exploded column types
    Spell.tsv                        # Spells: defaults + percent type
    Recipe.tsv                       # Crafting: exploded maps + ratio type
    WorldConfig.transposed.tsv       # Transposed: singleton config record
    LevelScale.tsv                   # COG code generation
    libs/
      gameLib.lua                    # Code library for expressions
  expansion/                         # Package: tutorial.expansion (mod)
    Manifest.transposed.tsv          # Dependencies + custom type chaining
    Files.tsv                        # Expansion file registry
    ExpansionTypes.tsv               # Custom types with column redefinition and omission (v0.11.0)
    BossType.tsv                     # Enum: boss encounter types
    Boss.tsv                         # Bosses: type inheritance + column redefinition
    ExpansionItem.tsv                # Cross-package type references
    ExpansionSpell.tsv               # Expansion library expressions
    libs/
      bossLib.lua                    # Expansion code library
```

## Running the Tutorial

All commands are run from the TabuLua project root:

```bash
# Validate and reformat all tutorial data (no export):
lua reformatter.lua tutorial/core/ tutorial/expansion/

# Export to JSON:
lua reformatter.lua --file=json tutorial/core/ tutorial/expansion/

# Export to Lua tables:
lua reformatter.lua --file=lua tutorial/core/ tutorial/expansion/

# Export to multiple formats at once:
lua reformatter.lua --file=json --file=lua --file=xml tutorial/core/ tutorial/expansion/

# Collapse exploded columns into composite values during export:
lua reformatter.lua --file=json --collapse-exploded tutorial/core/ tutorial/expansion/

# Clean export directory before exporting:
lua reformatter.lua --file=json --clean tutorial/core/ tutorial/expansion/
```

See `REFORMATTER.md` for the full list of export formats and options.

## File-by-File Walkthrough

### Core Package

#### Manifest.transposed.tsv

The package manifest defines metadata, custom types, code libraries, and validators.
It uses **transposed format** (one field per row), ideal for single-record configurations.

**Custom fields:** Manifests support user-defined fields beyond the standard schema.
These fields are preserved during reformatting and can store project-specific metadata.
In this tutorial, we define `gameGenre` and `targetAudience` as custom fields to demonstrate
this capability. Custom fields generate a warning during loading (to alert about typos)
but are otherwise fully supported.

**Custom types defined here** (scalar / enum types and the `CurrencyType` tag; complex record/tuple
types have been moved to `CoreTypes.tsv` — see next section):

| Type | Parent | Constraints | Rationale |
| --- | --- | --- | --- |
| `gold` | `uint` | (none) | Simple alias. Game currencies are non-negative integers, so `uint` (0 to 4,294,967,295) fits naturally. Aliasing it as `gold` makes column definitions self-documenting. |
| `hitPoints` | `integer` | `min=0` | HP cannot be negative. Using `integer` with `min=0` gives the full positive integer range. |
| `level` | `ubyte` | `min=1, max=99` | Levels are small positive numbers. Chaining onto `ubyte` (0-255) and restricting to 1-99 demonstrates numeric range constraints. |
| `itemCode` | `ascii` | `minLen=3, maxLen=50`, `pattern=^[A-Z]{3}%-[0-9]+$` | Item catalog codes follow a strict format (e.g., `SWD-001`). This demonstrates string constraints: min/max length and regex pattern validation. |
| `evenLevel` | `integer` | `validate="value >= 0 and value % 2 == 0"` | Demonstrates expression-based validation. The Lua expression is evaluated at parse time. |
| `CurrencyType` | `number` | `members={"gold"}` | **Type tag**: a named group of types. Accepts only `gold` (and subtypes). The expansion extends this tag with `bossGem`, demonstrating cross-package tag merging. |

**Code library:** `gameLib` loaded from `libs/gameLib.lua`, providing math utilities
(`circleArea`, `lerp`, `clamp`, `percentToMultiplier`) available in expressions and COG blocks.

**Package validator:** A `warn`-level check that the package contains at least one data file.

---

#### CoreTypes.tsv (Custom Type Definition File)

A dedicated custom type definition file (v0.10.0 feature), registered in `Files.tsv` with
`typeName=custom_type_def` and `loadOrder=5`. Each row in this file is automatically registered
as a custom type, without needing inline `custom_types` entries in the manifest.

**Types defined here:**

| Type | Parent | Purpose |
| --- | --- | --- |
| `BaseStats` | `{attack:integer,defense:integer,speed:integer}` | Named record alias for standard creature stats. Defined here so that the expansion can **extend** it. |
| `Point2D` | `{float,float}` | Named tuple alias for 2D coordinates. Defined here so the expansion can **extend** it to 3D. |
| `FlexStats` | `{attack:integer,critRate:float\|nil,defense:integer,speed:integer}` | Extended stat block with an **optional** `critRate` field. Used by the expansion as the parent for `BossStats` and `EliteBossStats`, demonstrating column omission and column redefinition (v0.11.0). |

*Rationale:* Moving complex record/tuple type definitions out of the manifest into a dedicated file
keeps the manifest concise and makes the type definitions themselves easier to review. Types defined
here are available to all files loaded after this file (including the expansion package).

---

#### Files.tsv

The file registry declares every data file in the package, its type name, load order,
validators, and special behaviors (enum registration, data publishing, file joining).

**Key configurations:**

- **Element.tsv** and **Rarity.tsv** use `superType=enum`, which registers them as enum types
  available for use in column type declarations throughout all loaded packages.

- **Constant.tsv** uses `publishColumn=value` with an empty `publishContext`, which publishes
  each row's `value` field as a bare name in the global expression scope. This means other
  files can write `=baseDamage*2` instead of needing a qualified reference.

  *Rationale:* Game balance constants (base damage, crit multiplier, etc.) are referenced
  frequently in expressions across many files. Publishing them globally keeps expressions
  readable.

- **Item.tsv** has **row validators** (price must be positive, weight must be positive, high
  price warning) and a **file validator** (item count warning). It also sets
  `publishContext=Item` for potential cross-file references.

- **Item.en.tsv** is configured with `joinInto=Item.tsv`, `joinColumn=name`, and
  `joinedTypeName=ItemLocalized`. This makes it a secondary file that merges into Item.tsv
  by matching on the `name` column, producing a combined `ItemLocalized` type on export.

  *Rationale:* Localization files naturally join into the base data. The join system avoids
  duplicating all item columns in the translation file.

---

#### Element.tsv (Enum)

Defines six elemental types: Fire, Water, Earth, Air, Shadow, Light.

*Rationale:* Elements are a classic enum use case -- a fixed set of named values referenced
throughout the data (creatures, items, spells). Registering via `superType=enum` in Files.tsv
makes `Element` available as a column type everywhere, including the expansion package.

Columns: `name:identifier`, `displayName:text`, `description:text`

The `identifier` type is the required first-column type for enum files.

---

#### Rarity.tsv (Enum)

Defines five rarity tiers: Common, Uncommon, Rare, Epic, Legendary.

Columns: `name:identifier`, `displayName:text`, `dropWeight:float`

*Rationale:* This enum demonstrates that enums can carry **additional data columns** beyond
the required `name` key. The `dropWeight` column stores the probability weight for each
rarity tier, making the enum a data table rather than just a list of names.

---

#### Constant.tsv (Published Constants)

Game balance constants with expressions and library function calls.

Columns: `name:name`, `displayName:text`, `value:float`, `unit:name`, `comment:comment`

**Notable rows:**
- `baseDamage=10.0`, `critMultiplier=2.5` -- simple numeric constants
- `scaledDamage` with `=baseDamage*critMultiplier` -- expression referencing other constants
- `circleArea` with `=gameLib.circleArea(10)` -- library function call
- `lerpValue` with `=gameLib.lerp(0,baseDamage,0.75)` -- mixing constants and library calls

*Rationale:* Centralizing game balance values in one file and publishing them globally
enables a data-driven design. Changing `baseDamage` here automatically updates every
creature's `attackPower` expression in Creature.tsv.

The `comment` type is a strippable annotation: it is preserved during reformatting but
automatically excluded from all exports, keeping production data clean of dev notes.

---

#### Item.tsv (Complex Types)

Demonstrates the richest variety of column types in a single file.

**Column highlights:**
| Column | Type | Feature Demonstrated |
|--------|------|---------------------|
| `catalogId` | `long` | 64-bit integer IDs (note extreme values like `9223372036854775807`) |
| `code` | `itemCode` | Custom type with regex pattern validation (`^[A-Z]{3}%-[0-9]+$`) |
| `rarity` | `Rarity` | Enum reference (defined in Rarity.tsv) |
| `price` | `gold` | Custom type alias for `uint` |
| `element` | `Element\|nil` | Union type: optional enum. `nil` means no elemental affinity |
| `tags` | `{name}` | Array of names. Values listed as `"weapon","melee","iron"` (no outer braces) |
| `devNotes` | `comment\|nil` | Optional developer comment (automatically stripped from exports) |

*Rationale:* Items are the central data entity in any RPG. Having items reference enums
(`Rarity`, `Element`), use custom validated types (`itemCode`, `gold`), support optional
unions (`Element|nil`), and carry arrays (`{string}`) makes this file a natural showcase
for TabuLua's type system.

---

#### Item.en.tsv (File Joining)

English localization file that joins into Item.tsv by the `name` column.

Columns: `name:name`, `displayName:text`, `description:text`

The `text` type supports escape sequences: `\n` for newline, `\t` for tab, `\\` for
literal backslash. Several descriptions use `\n` for multi-line text and `\t` for
tab-indented content.

*Rationale:* Localization is a natural use case for file joining. Translators work on
a separate file containing only the text columns, while the primary file keeps all the
mechanical data. On export, both are merged into a single `ItemLocalized` record.

---

#### Icon.tsv (Binary Data Types)

Demonstrates the `hexbytes` and `base64bytes` types for storing binary data
in TSV files. Each row represents an 8x8 monochrome pixel art icon (1 bit per
pixel = 8 bytes).

Columns: `name:name`, `bitmap:hexbytes`, `bitmapB64:base64bytes`

- **`hexbytes`**: Hex-encoded binary data, always reformatted to uppercase.
  Each byte is two hex characters (e.g., `FF` = 255).
- **`base64bytes`**: The same binary data encoded as RFC 4648 base64.

Both types extend `ascii` and store their encoded representation in TSV. When
exporting to **binary targets** (MessagePack or SQL), the encoded strings are
automatically converted to native binary:

- **MessagePack**: raw binary bytes in the `.mpk` file
- **SQL**: `BLOB` column type with `X'...'` hex literal values

In text exports (JSON, Lua, XML), the values remain as encoded strings.

---

#### Creature.tsv (Exploded Columns)

Demonstrates all four kinds of **exploded columns** -- composite types spread across
multiple TSV columns for easy editing.

**Exploded column groups:**

| Pattern | Type | Example Columns |
|---------|------|----------------|
| `stats.*` | Record `{attack:integer,defense:integer,speed:integer}` | `stats.attack`, `stats.defense`, `stats.speed` |
| `spawnPos._*` | Tuple `{float,float,float}` | `spawnPos._1`, `spawnPos._2`, `spawnPos._3` |
| `drops[*]` | Array `{name\|nil}` (up to 3) | `drops[1]`, `drops[2]`, `drops[3]` |
| `resistances[*]` | Map `{Element:integer}` | `resistances[1]`, `resistances[1]=`, `resistances[2]`, `resistances[2]=` |

The file also includes:
- `immunities:{Element}|nil` -- a **non-exploded** array for comparison with the exploded
  `drops` array. Values like `Earth,Fire` are listed without outer braces.
- `attackPower:float` with `=baseDamage*N` -- an expression referencing the published
  `baseDamage` constant from Constant.tsv.

*Rationale:* Game creatures have structured data (stat blocks, positions, loot tables,
resistance maps) that naturally decomposes into multiple columns. Exploded columns let
designers edit each component in its own cell while TabuLua reconstructs the composite
type. The `attackPower` expression demonstrates how published constants create data
dependencies across files.

---

#### Spell.tsv (Defaults and Percent)

Demonstrates column-level default values and the `percent` type.

**Key columns:**
- `scalingPercent:percent` -- accepts `150%` (parsed as 1.5) or fractional `1/2` (parsed as 0.5)
- `cooldown:float:5.0` -- **literal default**: empty cells get `5.0`
- `areaRadius:float:0.0` -- **literal default**: empty cells get `0.0`
- `totalDamage:float:=self.baseDamage*gameLib.percentToMultiplier(self.scalingPercent)` --
  **expression default** using `self` references and library functions

*Rationale:* Spells share common default values (standard cooldown, zero area radius).
Column-level defaults eliminate repetitive data entry. The expression default for
`totalDamage` auto-computes a derived value from other columns, but can be overridden
explicitly (see `iceShield` with `=0`).

Note that empty cells trigger the default; explicitly writing a value (even one matching
the default) overrides it.

---

#### Recipe.tsv (Exploded Maps and Ratio)

Demonstrates exploded map columns and the `ratio` type.

**Key columns:**
- `recipeCode:ascii` -- ASCII-only string type (bytes 0-127)
- `craftTime:ushort` -- unsigned 16-bit integer (0-65535), representing seconds
- `successRate:ratio` -- a map of names to percentages that **must sum to 100%**.
  Format: `Skill="60%",Luck="40%"`. The system validates the sum.
- `materials[1]:name`, `materials[1]=:integer`, ... -- **exploded map** using bracket
  notation. `[N]` is the key, `[N]=` is the value.

*Rationale:* Crafting recipes naturally involve ingredient maps (item name to quantity)
and success rate breakdowns. The `ratio` type enforces that rate components sum to 100%,
catching data entry errors. Exploded maps make ingredient lists easy to read in a
spreadsheet.

---

#### WorldConfig.transposed.tsv (Transposed Singleton)

A single-record configuration file in **transposed format** (one field per line).

*Rationale:* Some game data is singleton (one world config, one settings record).
Transposed format is ideal for these: each field gets its own line with `fieldName:type`
followed by the value, making it easy to read and edit. This is the same format used by
Manifest files, here applied to a data file.

Notable: `area:float` uses `=self.width*self.height`, a self-referencing expression that
computes the area from other fields in the same record.

---

#### LevelScale.tsv (COG Code Generation)

Demonstrates **COG (Code Generation)** blocks that programmatically generate data rows.

The `###[[[...###]]]` block contains Lua code that:
1. Loops from 1 to 10
2. Uses `gameLib.lerp()` for stat interpolation
3. Generates formatted TSV rows as a return string
4. The output replaces the content between `###]]]` and `###[[[end]]]`

After the generated block, a manual `bossBonus` row demonstrates that generated and
hand-authored rows coexist in the same file.

*Rationale:* Level scaling tables follow mathematical formulas. Writing 100 rows by hand
is error-prone. COG blocks generate data from code while keeping the result visible and
editable in the TSV. Re-running the reformatter regenerates the block.

---

#### libs/gameLib.lua (Code Library)

A Lua module providing functions available in expressions and COG blocks:

- `M.PI` -- mathematical constant
- `M.circleArea(radius)` -- used in Constant.tsv
- `M.lerp(a, b, t)` -- used in COG and expressions
- `M.clamp(value, minVal, maxVal)` -- general utility
- `M.percentToMultiplier(pct)` -- used in Spell.tsv default expression
- `M.levelScale(base, level, growth)` -- scaling formula

*Rationale:* Complex formulas repeated across expressions benefit from library functions.
Libraries run in a sandbox, ensuring data files can't execute arbitrary code.

---

### Expansion Package

The expansion demonstrates **multi-package support**: how a mod or DLC can depend on,
extend, and reuse types from a core package.

#### Manifest.transposed.tsv

**Key multi-package features:**

- `dependencies: {'tutorial.core','>=1.0.0'}` -- Hard requirement. Loading fails if the
  core package is missing or its version is below 1.0.0.

- `load_after: "tutorial.core"` -- Guarantees core is fully loaded before the expansion.
  This ensures core's enums, custom types, and published constants are available.

**Custom field:** `contentRating` demonstrates that expansion manifests can also have
user-defined fields (e.g., for age ratings, mod categories, or other metadata).

**Custom types defined inline** (scalar / enum types only; complex boss stat record types have
been moved to `ExpansionTypes.tsv` — see below):

| Type | Parent | Constraints | Rationale |
| --- | --- | --- | --- |
| `advancedElement` | `{enum:Fire\|Light\|Shadow}` | (inline enum) | A focused subset of elements for shadow realm content. Defined as an inline enum rather than restricting the core Element enum. |
| `bossGem` | `uint` | (none) | A new numeric currency type for the expansion (boss encounter rewards). |
| `intTypeName` | `{extends,integer}` | (bare extends) | Accepts only names of types that extend `integer` (e.g., `hitPoints`, `bossHp`, `bossLevel`, `ubyte`). Demonstrates the ancestor-constraint syntax. |
| `CurrencyType` | `number` | `members={"bossGem"}` | **Cross-package tag merge**: extends core's `CurrencyType` tag with the new `bossGem` member. After merging, `CurrencyType` accepts both `gold` (from core) and `bossGem` (from expansion). |

---

#### Files.tsv

Registers expansion data files. Notable entries:

- **ExpansionTypes.tsv** has `typeName=custom_type_def` and `loadOrder=5`, registering each
  of its rows as a custom type — the same mechanism as `CoreTypes.tsv` in the core package.
- **ExpansionItem.tsv** has a **row validator**: `"self.price > 0 or 'price must be positive'"`,
  showing that validators work identically in expansion packages.

---

#### ExpansionTypes.tsv (Custom Type Definition File + Column Redefinition)

A custom type definition file demonstrating three v0.10.0 / v0.11.0 features together.

**Types defined here:**

| Type | Parent | Feature |
| --- | --- | --- |
| `bossLevel` | `level` (min=50) | **Chained custom type**: `level` extends `ubyte` with min=1, max=99; `bossLevel` further restricts to min=50. |
| `bossHp` | `hitPoints` (validate>=1000) | **Expression validator**: extends core's `hitPoints` (min=0), ensuring bosses have at least 1000 HP. |
| `BossStats` | `{extends:FlexStats, critRate:nil, enrageThreshold:integer}` | **Column omission (v0.11.0)**: inherits `FlexStats` fields, marks `critRate` as permanently unused by re-declaring it as `nil`. Standard bosses have no crit mechanic. |
| `EliteBossStats` | `{extends:FlexStats, critRate:float, enrageThreshold:integer}` | **Column narrowing (v0.11.0)**: inherits `FlexStats` fields, **narrows** `critRate` from `float\|nil` (optional) to `float` (mandatory). Elite bosses always have a critical hit rate. |

**Column Omission** (`BossStats`): When a child record re-declares an inherited field as `nil`,
that field is permanently marked as unused. The parser rejects any value provided for it, and
the field is absent from the output. This is useful when a parent type defines an optional field
that does not apply to a specific subtype.

**Column Narrowing** (`EliteBossStats`): When a child record re-declares an inherited field with
a more specific type (here `float` narrowing `float|nil`), the child's type must be compatible
with (a subtype of) the parent's type. The child's stricter parser is used for that field.

Both types extend `FlexStats` from `CoreTypes.tsv`, demonstrating cross-file type extension.

---

#### BossType.tsv (Expansion Enum)

Defines three boss encounter categories: Guardian, Overlord, Ancient.

*Rationale:* Expansions can define their own enums independently of the core package.
`BossType` is registered via `superType=enum` just like core's `Element` and `Rarity`.

---

#### Boss.tsv (Type Inheritance + Column Redefinition)

Demonstrates **type inheritance**, **cross-package references**, and **column redefinition**
via a union of two named record types (`BossStats|EliteBossStats`).

**Key columns:**

| Column | Type | Feature |
| --- | --- | --- |
| `bossType` | `BossType` | References expansion's own enum |
| `level` | `bossLevel` | Chained custom type (expansion -> core -> ubyte) |
| `hitPoints` | `bossHp` | Custom type with expression validator |
| `hpType` | `intTypeName` | Ancestor-constraint: only type names extending `integer` |
| `element` | `advancedElement` | Restricted enum subset |
| `bossStats` | `BossStats\|EliteBossStats` | **Union of named records**: standard bosses (no crit) parse as `BossStats`; elite bosses (with mandatory `critRate`) parse as `EliteBossStats` |
| `spawnPos` | `{extends,Point2D,float}` | **Tuple inheritance**: extends core's `Point2D` (2D) to 3D by appending a float |
| `reward` | `integer\|string` | **Non-trivial union**: gold amount OR named reward |
| `lootTable` | `{name}` | Array referencing core item names |

**How the union disambiguates:** `BossStats` has `critRate:nil` (omitted), so providing a
`critRate` value causes parsing to fail and fall through to `EliteBossStats`. Conversely,
`EliteBossStats` requires `critRate:float`; omitting it fails that branch. Three existing
bosses (no `critRate`) parse as `BossStats`; the new `arachnidQueen` boss (with
`critRate=0.35`) parses as `EliteBossStats`.

Record values are written without outer braces:
`attack=80,defense=40,enrageThreshold=1500,speed=30` (BossStats)
`attack=45,critRate=0.35,defense=55,enrageThreshold=750,speed=35` (EliteBossStats)

Tuple values are also without outer braces: `-20.0,50.0,10.0`

---

#### ExpansionItem.tsv (Cross-Package References)

Uses the same column structure as core Item.tsv, demonstrating that expansion files can
freely reference core types:

- `itemCode`, `gold` -- custom types from core Manifest
- `Rarity` -- enum from core Rarity.tsv
- `advancedElement|nil` -- expansion's restricted enum instead of core's `Element|nil`
- `CurrencyType` -- **type tag** from core, extended with `bossGem` by expansion. The
  `rewardType` column accepts both `gold` (core member) and `bossGem` (expansion member).

*Rationale:* Mod content reuses the base game's type system. New items follow the same
validation rules (pattern-checked item codes, valid enum values) without any extra setup.
The `CurrencyType` column demonstrates how type tags enable cross-package extensibility.

---

#### ExpansionSpell.tsv (Expansion Libraries)

Similar to core Spell.tsv but uses the expansion's own code library:

- `bossLib.bossScaling()` in the default expression (1.2x damage multiplier for boss content)
- Higher default `cooldown:float:8.0` (vs core's 5.0)
- `advancedElement` instead of `Element`

*Rationale:* Each package can define its own code libraries with different balance
parameters. The expansion's spells deal more damage (boss scaling) but have longer
cooldowns, all expressed through the default value system.

---

## Multi-Package Architecture

### How It Works

1. **Each package lives in its own directory** with a `Manifest.transposed.tsv` and
   `Files.tsv`. Packages cannot share a directory.

2. **Dependencies are declared** in the manifest with version constraints:
   `{'tutorial.core','>=1.0.0'}` means "require tutorial.core version 1.0.0 or later."

3. **Load order is explicit** via `load_after`. The expansion declares
   `load_after:"tutorial.core"` to ensure core's enums, types, and published data
   are registered before the expansion's files are processed.

4. **Types flow across packages**: Once core registers `Element` as an enum, `gold` as
   a custom type, and `baseDamage` as a published constant, the expansion can use all
   of these in its own column definitions and expressions.

5. **Type chaining works across packages**: The expansion's `bossLevel` extends core's
   `level`, which extends `ubyte`. Each layer adds constraints.

### What Each Package Provides

| Package | Provides | Used By |
| --- | --- | --- |
| **core** | `Element` enum, `Rarity` enum, `gold`/`hitPoints`/`level`/`itemCode` types (Manifest), `BaseStats`/`Point2D`/`FlexStats` type aliases (CoreTypes.tsv), `CurrencyType` type tag, `baseDamage` and other published constants, `gameLib` library | expansion |
| **expansion** | `BossType` enum, `bossLevel`/`bossHp` types and `BossStats`/`EliteBossStats` record types (ExpansionTypes.tsv), `advancedElement`/`bossGem`/`intTypeName` types (Manifest), extends `CurrencyType` tag, `bossLib` library | (standalone) |

## Feature Reference

Quick lookup: which file demonstrates which feature.

| Feature | File(s) |
|---------|---------|
| Transposed format | Both Manifests, `WorldConfig.transposed.tsv` |
| boolean | Item.tsv (`stackable`) |
| integer | Spell.tsv (`manaCost`), Creature.tsv (stats) |
| float | Item.tsv (`weight`), Spell.tsv (`baseDamage`) |
| string | WorldConfig.transposed.tsv (`biome`) |
| long | Item.tsv (`catalogId`) |
| ubyte | via custom type `level` |
| ushort | Recipe.tsv (`craftTime`) |
| uint | via custom type `gold` |
| text | Item.en.tsv (escape sequences `\n`, `\t`) |
| markdown | Manifests (`description`) |
| comment | Item.tsv (`devNotes`), Constant.tsv (`comment`) |
| identifier | Element.tsv, Rarity.tsv (enum name columns) |
| name | Primary key columns throughout |
| version | Manifests (`version`) |
| cmp_version | Expansion Manifest (`dependencies`) |
| http | Manifests (`url`) |
| ascii | Recipe.tsv (`recipeCode`) |
| hexbytes | Icon.tsv (`bitmap`) |
| base64bytes | Icon.tsv (`bitmapB64`) |
| percent | Spell.tsv (`scalingPercent`) |
| ratio | Recipe.tsv (`successRate`) |
| Array `{type}` | Creature.tsv (`immunities`), Boss.tsv (`lootTable`) |
| Map `{k:v}` | Recipe.tsv (exploded `materials`) |
| Tuple `{t1,t2,...}` | Creature.tsv (exploded `spawnPos`) |
| Record `{n:t,...}` | Creature.tsv (exploded `stats`) |
| Enum | Element.tsv, Rarity.tsv, BossType.tsv |
| Union `type\|nil` | Item.tsv (`element:Element\|nil`) |
| Union `type1\|type2` | Boss.tsv (`reward:integer\|string`) |
| Record extends | Boss.tsv (via `BossStats`/`EliteBossStats` extending `FlexStats`) |
| Tuple extends | Boss.tsv (`{extends,Point2D,float}`) |
| Column omission (`field:nil`) | ExpansionTypes.tsv (`BossStats.critRate:nil`), Boss.tsv |
| Column narrowing (field redefinition) | ExpansionTypes.tsv (`EliteBossStats.critRate:float`), Boss.tsv |
| Union of named record types | Boss.tsv (`BossStats\|EliteBossStats`) |
| Custom type definition file | CoreTypes.tsv, ExpansionTypes.tsv |
| Custom type (alias) | Manifest: `gold = uint` |
| Custom type (numeric) | Manifest: `level`, `hitPoints` |
| Custom type (string) | Manifest: `itemCode` (pattern) |
| Custom type (expression) | Manifest: `evenLevel` |
| Custom type chaining | Expansion: `bossLevel` extends `level` |
| Type tag (members) | Core Manifest: `CurrencyType` with `gold` |
| Type tag merge | Expansion Manifest: adds `bossGem` to `CurrencyType` |
| Expressions `=` | Constant.tsv, Creature.tsv, WorldConfig.transposed.tsv |
| Default (literal) | Spell.tsv (`cooldown:float:5.0`) |
| Default (expression) | Spell.tsv (`totalDamage:float:=self...`) |
| Exploded record | Creature.tsv (`stats.*`) |
| Exploded tuple | Creature.tsv (`spawnPos._*`) |
| Exploded array | Creature.tsv (`drops[*]`) |
| Exploded map | Recipe.tsv (`materials[*]`, `materials[*]=`) |
| File joining | Item.en.tsv into Item.tsv |
| COG code generation | LevelScale.tsv |
| Code libraries | gameLib.lua, bossLib.lua |
| TSV comments | All files (lines starting with `#`) |
| publishColumn | Constant.tsv (global constants) |
| Row validators | Item.tsv, ExpansionItem.tsv |
| File validators | Item.tsv (count limit) |
| Package validators | Both Manifests |
| Multi-package | core/ + expansion/ |
| Dependencies | Expansion Manifest |
| load_after | Expansion Manifest |
| Manifest custom fields | Both Manifests (`gameGenre`, `targetAudience`, `contentRating`) |

## Notes

- **Container values in cells** (arrays, records, tuples) must be written **without**
  outer `{}` braces. The parser adds them internally. For example, write
  `"weapon","melee"` not `{"weapon","melee"}`.

- **Multiple values in arrays** must be quoted when listing more than one value.
  A single unquoted value like `Fire` works fine, but multiple values must be quoted:
  `"Fire","Light"` not `Fire,Light`. Without quotes, the parser issues a warning
  about assuming an unquoted string. See `Creature.tsv` immunities column for examples.

- **Comments** (`# ...` lines) are only supported between the header row and data rows
  or after data rows. The header row must always be line 1 in non-transposed files.

- **Transposed format** (`.transposed.tsv` extension) is used for Manifest files and
  singleton data files like WorldConfig. In transposed format, each line is a
  `fieldName:type` followed by its value, which is ideal for single-record files.
