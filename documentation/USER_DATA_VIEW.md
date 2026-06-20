# User Data View Reference

This is a unified reference for how data objects appear from the user's perspective in **cell expressions**, **COG scripts**, and **validators**. All user code contexts provide the same view: field names and indexes map directly to parsed values.

For the internal Lua table structures behind these objects, see [INTERNAL_MODEL.md](INTERNAL_MODEL.md).

## The Cell Object

A cell represents a single value in a data row. Internally it has four forms:

| Property | Description |
|----------|-------------|
| `.value` | Original TSV string (empty if a default was used) |
| `.evaluated` | After expression evaluation (same as `.value` if not an expression) |
| `.parsed` | **The final typed value** — a number, boolean, string, table, etc. |
| `.reformatted` | Reformatted for TSV output |

`tostring(cell)` returns the reformatted value.

**In all user code contexts, you work with parsed values directly.** When you write `self.price` in a validator or expression, you get the parsed value (e.g., the number `100`), not the internal cell object. The cell's four-form structure is an implementation detail handled by the engine.

## The Row Object

In all user code contexts (expressions, validators), a row provides direct access to parsed values by column index or name.

| Access | Returns |
|--------|---------|
| `row[1]`, `row[2]`, ... | Parsed value at that column index |
| `row.colName` or `row["colName"]` | Parsed value for that column |
| `row.explodedRoot` | Assembled nested value for exploded columns (e.g., `row.location` returns a record) |

## Context: Cell Expressions

Cell expressions start with `=` and run during parsing. The key variable is `self`, which provides **direct parsed values**.

**Available variables:**

| Variable | Description |
|----------|-------------|
| `self.colName` | Parsed value of column `colName` in the current row |
| `self[i]` | Parsed value of column at index `i` |
| `self.__idx` | Row index (1-based, header is row 1) |
| `<Context>.<key>` | Published data from earlier-loaded files (e.g., `Item.sword`) |
| `<globalKey>` | Globally published values (from files with `publishColumn` but no `publishContext`) |
| `<libName>.<func>()` | Code library functions (e.g., `gameLib.circleArea(10)`) |

**Lua built-ins available:** `math`, `string`, `table`, `pairs`, `ipairs`, `type`, `tostring`, `tonumber`, `select`, `unpack`, `next`, `pcall`, `predicates`, `stringUtils`, `tableUtils`, `equals`.

**Examples:**

```text
=self.baseDamage * 2
=self.width * self.height
=gameLib.percentToMultiplier(self.scalingPercent)
=baseDamage * critMultiplier
```

**Important:** `self.colName` returns the parsed value, not a cell. So `self.price` gives you `100` (a number), not a cell object.

**Dependency resolution:** Expressions can reference columns that appear *later* in the header. The system automatically detects `self` references and processes cells in dependency order.

**Operation quota:** 10,000 operations per expression.

## Context: COG Scripts

COG code blocks execute Lua code in a sandbox and replace a section of the file with the returned string.

**Available variables:**

The COG environment contains whatever is passed as the `env` parameter. When used within the file-loading pipeline, this is the `loadEnv` table, which includes:

- All code libraries (by name)
- All published data (by context name or globally)
- `files.TypeName` — previously-loaded datasets, keyed by their `typeName` from `Files.tsv`. COG scripts in files with a higher `loadOrder` can access earlier-loaded datasets (e.g., `files.Item`). View-of-view chains are supported provided `loadOrder` values are ordered correctly.
- Standard Lua globals (`math`, `string`, `table`, etc.)

**COG does NOT have a `self` variable** — it runs at the file level, not the cell/row level.

**Example:**

```
###[[[
###local rows = {}
###for i = 1, 5 do
###    rows[#rows+1] = "item" .. i .. "\t" .. (i * 10)
###end
###return table.concat(rows, "\n")
###]]]
<generated rows appear here>
###[[[end]]]
```

**Operation quota:** 10,000 operations per code block.

## Context: File Pre-Processors

File pre-processors run on each file after all cells are parsed but **before** any validator. Unlike validators, they can **mutate** the parsed rows (via `setCell`). Typical uses: deriving bidirectional references, normalising data across rows, filling in back-references for graph- or tree-shaped data.

**Available variables:**

| Variable | Description |
|----------|-------------|
| `rows` / `file` | Array of all data rows. Each entry is a processor-row proxy with read-only field access |
| `fileName` | Name of the file being processed |
| `ctx` | Writable table for accumulating state across processors (see [Writable Context](#writable-context-ctx)) |
| Published contexts | Data from earlier-loaded files |
| Code libraries | By name |
| Helper functions | Same read-side helpers as file validators (`unique`, `sum`, `min`, `max`, `avg`, `count`, `all`, `any`, `none`, `filter`, `find`, `lookup`, `groupBy`, `listMembersOfTag`, `isMemberOfTag`) |
| Write helpers | `setCell`, `clearCell`, `rowByKey`, `dataIndex`, `copy` (see below) |
| Graph helpers | `completeBasicGraph(rows?)`, `completeDirectedGraph(rows?)` |

**Write helpers:**

| Helper | Purpose |
|--------|---------|
| `setCell(row, column, value)` | Set a parsed value on a row; re-validates through the column's type |
| `clearCell(row, column)` | Equivalent to `setCell(row, column, nil)` — only valid for nullable columns |
| `rowByKey(key)` | O(1) lookup into the current file by primary-key value; returns `nil` if missing |
| `dataIndex(row)` | 1-based data-row position (excludes the header row) |
| `copy(value)` | Deep clone of a read-only value, fully mutable |

**Mutating collections:**

Reading a row's column returns the parsed value as **read-only**, exactly like in validators. A collection-valued cell (`row.unlocks`, `row.tags`, ...) therefore cannot be modified in place. To change a collection: deep-copy it with `copy`, mutate the copy, install it via `setCell`:

```text
local u = copy(row.unlocks)
table.insert(u, newItem)
setCell(row, 'unlocks', u)
```

Direct assignment (`row.foo = "bar"`) is not supported — every write goes through `setCell` so values are re-parsed against the column's type.

**Ordering:** Within a file, processors run in ascending `priority` (default `100`); ties break in declaration order. Later processors see the writes of earlier ones.

**Return value:** Generally ignored, but `false` or a non-empty string is treated as a failure (same convention as validators). The spec's `level` field (`"error"` or `"warn"`) controls whether the failure aborts validation or just collects a warning.

**Operation quota:** 50,000 operations per file (higher than validator quotas because mutation work is more expensive than pure checks).

## Context: Package-Scoped Pre-Processors

A package manifest may declare `preProcessors` that run **once per package**, after all files are parsed **and after mod patches are applied**, but before validators. They see the fully merged-and-patched state of every loaded file. Use them for cross-file derivation that must observe the post-patch data (e.g. back-references that should also cover rows a mod added via a patch).

Unlike file pre-processors — which expose a single `rows`/`file` — a package-scoped processor works over the whole loaded set, keyed the same way package validators key it.

**Available variables:**

| Variable | Description |
|----------|-------------|
| `files` / `package` | Map of lowercase file name → that file's row array (each a processor-row proxy with read-only field access) |
| `packageId` | The owning package's identifier string |
| `ctx` | Writable table for accumulating state across this package's processors |
| Published contexts | Data from earlier-loaded files |
| Code libraries | By name |
| Helper functions | Same read-side helpers as file validators |
| Write helpers | `setCell`, `clearCell`, `copy`, and `rowByKey(file, key)` |

**Scoped writes:** a package-scoped processor may only mutate files its package **owns or has declared a patch for**; writing any other file is a reported error.

**`rowByKey` differs from the file-level form:** here it takes **two** arguments — `rowByKey(file, key)`, where `file` is a file key (string) or a wrapped-file array — because the processor can reach into any visible file, not just one. (The file pre-processor form is the single-argument `rowByKey(key)` into the current file.)

**Cross-package ordering:** package-scoped processors run in package load order, refined by each spec's optional `requires` (names of packages whose package-scoped processors must run first). A `requires` cycle is a hard error; requiring an unloaded package warns without failing the load.

**Operation quota:** 50,000 operations per file processed.

## Context: Bulk-Patch Selectors and Transforms

A `bulk_patch` file (a mod that patches parent rows **by a selector** rather than by key) carries two kinds of user expression, both evaluated in the **validator sandbox** at apply time:

- The required `where` expression selects parent rows. It is evaluated **once per candidate parent row**, with `self` / `row` bound to that candidate, plus the validator helpers (`any`, `count`, `all`, …) and published contexts in scope. Return truthy to match.
- For `patchOp=update`, each transform cell starting with `=` is evaluated against the **matched** target row (`self` = that row), so `=row.price * 2` does what you'd expect. A non-`=` transform cell is a literal parsed by the parent column.

These expressions are kept **raw** at load (an `expression`-typed column tolerates a leading `=` and is not load-evaluated), so they survive to run against the target rather than against the rule row.

## Context: Row Validators

Row validators run on each row after all cells are parsed. Like cell expressions, `self.colName` returns the **parsed value** directly.

**Available variables:**

| Variable | Description |
|----------|-------------|
| `self` / `row` | The current row. `self.colName` returns the **parsed value** |
| `rowIndex` | 1-based row index |
| `fileName` | Name of the file being validated |
| `ctx` | Writable table for accumulating state across rows (see [Writable Context](#writable-context-ctx)) |
| Published contexts | Data from earlier-loaded files |
| Code libraries | By name (e.g., `gameLib`) |

**Accessing values:**

```text
self.price                     -- the numeric value
self[1]                        -- first column's parsed value
row.element                    -- alternative alias for self
```

**Example validators:**

```text
self.minLevel <= self.maxLevel or 'minLevel must be <= maxLevel'
self.price > 0 or 'price must be positive'
type(self.tags) == 'table' or 'tags must be an array'
```

**Operation quota:** 1,000 operations per row.

## Context: File Validators

File validators run once per file, after all rows are parsed.

**Available variables:**

| Variable | Description |
|----------|-------------|
| `rows` / `file` | Array of all data rows in the file. Each element is a row object |
| `fileName` | Name of the file |
| `count` | Number of data rows (convenience for `#rows`) |
| `ctx` | Writable table for accumulating state across validator expressions (see [Writable Context](#writable-context-ctx)) |
| Published contexts | Data from earlier-loaded files |
| Code libraries | By name |
| Helper functions | `unique`, `sum`, `min`, `max`, `avg`, `count`, `all`, `any`, `none`, `filter`, `find`, `lookup`, `groupBy`, `listMembersOfTag`, `isMemberOfTag` |

**Using helper functions and predicates:**

```text
-- Helper functions with column name
unique(rows, 'sku') or 'SKU values must be unique'
sum(rows, 'weight') <= 10000 or 'total weight too high'

-- Custom predicates access parsed values directly
all(rows, function(r) return r.price > 0 end) or 'all prices must be positive'
filter(rows, function(r) return r.level > 10 end)
```

**Operation quota:** 10,000 operations per file.

## Context: Package Validators

Package validators run once per package, after all files in the package are loaded.

**Available variables:**

| Variable | Description |
|----------|-------------|
| `files` / `package` | Table mapping lowercase file names to their data row arrays |
| `packageId` | Package identifier string |
| `ctx` | Writable table for accumulating state across validator expressions (see [Writable Context](#writable-context-ctx)) |
| Published contexts | All published data (including from dependency packages) |
| Code libraries | By name |
| Helper functions | Same as file validators (includes `listMembersOfTag`) |

**Accessing data across files:**

```text
-- Access rows of a specific file
files['items.tsv']              -- array of rows from items.tsv
files['items.tsv'][1]           -- first data row
files['items.tsv'][1].name      -- first row's name value

-- Cross-file validation
all(files['items.tsv'], function(item)
    return any(files['categories.tsv'], function(cat)
        return cat.id == item.category
    end)
end) or 'all items must reference a valid category'
```

**Operation quota:** 100,000 operations per package.

## Writable Context (`ctx`)

All validator types provide a writable `ctx` table for accumulating state across invocations. Unlike rows and files (which are read-only), `ctx` is a plain Lua table that validators can freely read and write.

### Scope

| Validator Type | `ctx` Scope |
|----------------|-------------|
| **Row validators** | One `ctx` per file, shared across all rows and all row validator expressions |
| **File validators** | One `ctx` per file, shared across all file validator expressions |
| **Package validators** | One `ctx` per package, shared across all package validator expressions |

### Examples

**Row validator — uniqueness checking:**

```text
(function()
    ctx.ids = ctx.ids or {}
    if ctx.ids[self.sku] then return 'duplicate sku: ' .. tostring(self.sku) end
    ctx.ids[self.sku] = true
    return true
end)()
```

**File validator — caching an expensive computation:**

```text
-- First validator: compute and cache
(function() ctx.totalWeight = sum(rows, 'weight'); return ctx.totalWeight <= 10000 or 'total weight too high' end)()

-- Second validator: reuse cached value
ctx.totalWeight <= sum(rows, 'price') or 'weight must not exceed price sum'
```

**Package validator — cross-file state:**

```text
(function()
    ctx.itemCount = count(files['items.tsv'])
    return ctx.itemCount > 0 or 'package must have items'
end)()
```

## Helper Function Reference

These functions are available in **file validators** and **package validators** (and in **row validators** via the shared sandbox environment).

### Collection Predicate Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `unique` | `unique(rows, column) → boolean` | `true` if all values in `column` are unique |
| `sum` | `sum(rows, column) → number` | Sum of numeric values in `column` |
| `min` | `min(rows, column) → number\|nil` | Minimum numeric value in `column` |
| `max` | `max(rows, column) → number\|nil` | Maximum numeric value in `column` |
| `avg` | `avg(rows, column) → number\|nil` | Average numeric value in `column` |
| `count` | `count(rows [, predicate]) → number` | Count of rows (all, or matching predicate) |

The `column` parameter can be a string (column name) or integer (column index).

### Iteration Helper Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `all` | `all(rows, predicate) → boolean` | `true` if every row satisfies `predicate(row)` |
| `any` | `any(rows, predicate) → boolean` | `true` if at least one row satisfies `predicate(row)` |
| `none` | `none(rows, predicate) → boolean` | `true` if no row satisfies `predicate(row)` |
| `filter` | `filter(rows, predicate) → table` | New array of rows where `predicate(row)` is true |
| `find` | `find(rows, predicate) → row\|nil` | First row where `predicate(row)` is true |

The `predicate` is a function receiving a row object: `function(r) return r.level > 10 end`.

### Lookup Helper Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `lookup` | `lookup(rows, column, value) → row\|nil` | First row where `row[column] == value` |
| `groupBy` | `groupBy(rows, column) → table` | Map of serialized column value → array of rows |

### Type Introspection Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `listMembersOfTag` | `listMembersOfTag(tagName) → table\|nil` | Returns a sorted array of member type names for a type tag, or `nil` if `tagName` is not a tag |
| `isMemberOfTag` | `isMemberOfTag(tagName, typeName) → boolean` | Returns `true` if `typeName` is a member of the tag (directly, via subtype, or transitively via nested tags) |

**Examples:**

```text
-- Check that a tag has expected members
all(listMembersOfTag('CurrencyType'), function(m) return m ~= 'banned' end)

-- Check if a specific type belongs to a tag
isMemberOfTag('Unit', 'kilogram')  -- true if kilogram is in Unit (directly or via nested tag)
```

## Sandbox Built-ins Summary

All expression contexts (cell expressions, validators, COG) share a common set of sandboxed Lua built-ins:

| Category | Available |
|----------|-----------|
| **Lua libraries** | `math`, `string`, `table` |
| **Lua functions** | `pairs`, `ipairs`, `type`, `tostring`, `tonumber`, `select`, `unpack`, `next`, `pcall` |
| **TabuLua API** | `predicates` (all predicate functions), `stringUtils` (`trim`, `split`, `parseVersion`), `tableUtils` (`keys`, `values`, `pairsCount`, `longestMatchingPrefix`, `sortCaseInsensitive`), `equals` (deep comparison) |
| **Validator helpers** | `unique`, `sum`, `min`, `max`, `avg`, `count`, `all`, `any`, `none`, `filter`, `find`, `lookup`, `groupBy`, `listMembersOfTag`, `isMemberOfTag` (validators and pre-processors only) |
| **Pre-processor helpers** | `setCell`, `clearCell`, `rowByKey`, `dataIndex`, `copy`, `completeBasicGraph`, `completeDirectedGraph` (pre-processors only) |
| **Code libraries** | By declared name (e.g., `gameLib`, `utils`) |
| **Published data** | By context name or globally |

## Validator Result Interpretation

All validators (row, file, and package) interpret return values the same way:

| Return Value | Meaning |
|--------------|---------|
| `true` | Valid |
| `""` (empty string) | Valid |
| `false` | Invalid (default error message: "validation failed") |
| `nil` | Invalid (default error message) |
| Non-empty string | Invalid (the string is the error message) |

The idiomatic pattern uses Lua's `or` short-circuit:

```text
self.price > 0 or 'price must be positive'
```

If `self.price > 0` is true, the expression returns `true` (valid). If false, Lua evaluates the right side and returns the error message string.
