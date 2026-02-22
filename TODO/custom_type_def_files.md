# Custom Type Definition Files

**Status: Implemented** (version 0.10.0) — `manifest_loader.lua`, `DATA_FORMAT_README.md`, `spec/manifest_loader_custom_type_def_files_spec.lua`

## Problem Statement

Custom types (aliases, range-restricted numbers, constrained strings, expression validators, type tags, etc.) are currently only definable inline in `Manifest.transposed.tsv` via the `custom_types:{custom_type_def}|nil` field. The value must be written as a single Lua table literal in one manifest cell, for example:

```
custom_types:{custom_type_def}|nil	{name="positiveInt",parent="integer",min=1},{name="percentage",parent="number",min=0,max=100}
```

This is workable for a handful of types, but becomes unwieldy when a package defines many custom types: the single cell grows very long, is hard to read, and cannot benefit from TSV tooling (column alignment, per-row comments, default values, etc.).

---

## Proposed Solution

Allow users to define custom types in a dedicated TSV file, where **each row is a `custom_type_def` record**. The system detects such files via the existing Files.tsv `superType` mechanism and auto-registers their rows, exactly as it currently auto-registers type aliases from "type files" and labels from "enum files".

### User-Facing Behavior

A file is treated as a **custom type definition file** when its `typeName` in `Files.tsv` is `custom_type_def`, or a type that (directly or transitively) has `superType=custom_type_def`.

#### Minimal example

`CustomTypes.tsv`:
```tsv
name:name	parent:type_spec|nil	min:number|nil	max:number|nil	validate:string|nil
positiveInt	integer	1
percentage	float	0	100
nonEmptyStr	string			predicates.isNonEmptyStr(value) or 'must not be empty'
```

`Files.tsv` entry:
```tsv
CustomTypes.tsv	custom_type_def		true			1	Custom type definitions
```

After this file is loaded, `positiveInt`, `percentage`, and `nonEmptyStr` are registered types and can be used as column types in all subsequently loaded files.

#### Sub-typing example

A user may extend `custom_type_def` with additional game-specific metadata columns:

`Files.tsv` (one entry defines the sub-type, another uses it):
```tsv
GameCustomTypes.tsv	GameCustomType	custom_type_def	false			2	Game-specific custom types
...
```

`GameCustomTypes.tsv`:
```tsv
name:name	parent:type_spec|nil	min:number|nil	max:number|nil	gameCategory:string
health	integer	0	9999	Stats
mana	integer	0	999	Stats
```

The `gameCategory` column is parsed and stored in each row (useful for any downstream COG code or validators), but is **ignored** during type registration — only the `custom_type_def` fields (`name`, `parent`, `min`, `max`, `minLen`, `maxLen`, `members`, `pattern`, `validate`, `values`) feed into `registerTypesFromSpec`.

### Column Omission

Since every optional field in `custom_type_def` is typed as `T|nil`, you only need to include a column in the header if at least one row requires a non-nil value for it. Columns absent from the header are treated as nil for all rows, which is the correct default. This keeps minimal custom type definition files short.

### Load Ordering

**The user is responsible for ordering.** A custom type definition file must have a lower `loadOrder` than any file that uses the types it defines. This is the same contract as all other inter-file dependencies (e.g., publishing a constant that another file uses in an expression). The system does not detect or warn about ordering violations at the metadata level — a wrong-order situation manifests as an "unknown type" parse error when the dependent file is loaded.

Recommended convention: use `loadOrder=1` (or another low value) for custom type definition files and higher values for files that reference those types.

### Interaction with Manifest-Defined Custom Types

Types defined in the manifest's `custom_types` field are registered first (during dependency resolution, before any data files are loaded). Types registered from a custom type definition file supplement the manifest-defined types. Redefining a type name with a different parent type is an error (see Decisions §1). Redefining with the same parent is idempotent.

### Cascading Custom Type Files

A custom type definition file may itself reference types defined in an earlier custom type definition file (by `loadOrder`). For example, file A defines `positiveInt`, and file B defines `highPositiveInt` with `parent=positiveInt` — as long as file A has a lower `loadOrder` than file B, this works correctly.

---

## Implementation

### Files to Modify

#### 1. `manifest_loader.lua` (primary change)

**a) Add `isCustomTypeDef(typeName, extends)` after `isEnum` (~line 393)**

Analogous to `isType` and `isEnum`. Follows the manifest-level `extends` chain until it finds `"custom_type_def"` or exhausts the chain.

```lua
local CUSTOM_TYPE_DEF = "custom_type_def"

-- Recursively search the extends table to see if typeName maps to "custom_type_def",
-- directly or indirectly.
local function isCustomTypeDef(typeName, extends)
    while typeName do
        if typeName:lower() == CUSTOM_TYPE_DEF then
            return true
        end
        typeName = extends[typeName]
    end
    return false
end
```

**b) Add `buildCustomTypesSet(lcFn2Type, extends)` after `findAllTypes` (~line 408)**

Iterates `lcFn2Type` (the map of `lcfn → typeName` built from Files.tsv) and identifies every `typeName` that is, or transitively extends, `custom_type_def`.

The function must handle two cases:
- `typeName` is exactly `"custom_type_def"` (direct use, no superType entry in `extends`)
- `typeName` is a user-named sub-type, and `extends[typeName]` chains to `"custom_type_def"`

```lua
local function buildCustomTypesSet(lcFn2Type, extends)
    local s = {}
    for _, fileType in pairs(lcFn2Type) do
        if fileType and (fileType:lower() == CUSTOM_TYPE_DEF
            or isCustomTypeDef(extends[fileType], extends)) then
            s[fileType] = true
            logger:info("Found custom type definition file type: " .. fileType)
        end
    end
    return s
end
```

**c) Add `registerCustomTypesFromFile(file, badVal)` after `registerFileType` (~line 203)**

Reads all data rows from the parsed TSV, extracts the `custom_type_def` fields from each row's cells (using `.parsed`), builds a `typeSpecs` sequence, and calls `parsers.registerTypesFromSpec`.

```lua
local CUSTOM_TYPE_DEF_FIELDS = {
    'name', 'parent', 'min', 'max', 'minLen', 'maxLen',
    'members', 'pattern', 'validate', 'values'
}

local function registerCustomTypesFromFile(file, badVal)
    local typeSpecs = {}
    for i, row in ipairs(file) do
        if i > 1 and type(row) == "table" then
            local spec = {}
            for _, field in ipairs(CUSTOM_TYPE_DEF_FIELDS) do
                local cell = row[field]
                if cell ~= nil then
                    spec[field] = cell.parsed
                end
            end
            typeSpecs[#typeSpecs + 1] = spec
        end
    end
    parsers.registerTypesFromSpec(badVal, typeSpecs)
end
```

**d) Update `logFile` signature and body (~line 264)**

Add `customTypesSet` parameter. Add a branch for custom type definition files before the existing branches:

```lua
local function logFile(file_name, fileType, enumsSet, typesSet, customTypesSet, table_subscribers)
    if enumsSet[fileType] then
        logger:info("Processing enum file: " .. file_name)
    elseif typesSet[fileType] then
        logger:info("Processing type file: " .. file_name)
    elseif customTypesSet[fileType] then
        logger:info("Processing custom type definition file: " .. file_name)
    elseif type(table_subscribers) == "table" then
        logger:info("Processing constants file: " .. file_name)
    else
        logger:info("Processing ordinary file:" .. file_name)
    end
end
```

**e) Update `processSingleTSVFile` signature and body (~line 302)**

Add `customTypesSet` parameter. Pass it to `logFile`. Add the new registration block after the existing enum/type checks. Update the `registerFileType` call to also skip custom type definition files:

```lua
local function processSingleTSVFile(file_name, file2dir, contexts, lcFn2Type, lcFn2Ctx, lcFn2Col,
    typesSet, enumsSet, customTypesSet, extends, raw_files, files_cache,
    options_extractor, expr_eval, loadEnv, badVal)
    -- ... (unchanged preamble) ...

    local fileType = lcFn2Type[lcFNKey]
    logFile(file_name, fileType, enumsSet, typesSet, customTypesSet, table_subscribers)

    local file = processTSV(...)
    -- ...

    if file then
        if enumsSet[fileType] then
            registerEnumParser(file, fileType, badVal)
        end
        if typesSet[fileType] then
            registerAliases(file, fileType, extends, badVal)
        end
        if customTypesSet[fileType] then                        -- NEW
            registerCustomTypesFromFile(file, badVal)           -- NEW
        end                                                     -- NEW
        -- Register the file's column structure as a type
        -- (skip for type/enum/customTypeDef files — they are handled above)
        registerFileType(file, fileType, typesSet, enumsSet, customTypesSet, badVal)
    end
end
```

**f) Update `registerFileType` signature (~line 180)**

Add `customTypesSet` parameter. Add it to the early-return guard:

```lua
local function registerFileType(file, fileType, typesSet, enumsSet, customTypesSet, badVal)
    if not fileType or #fileType == 0 then return end
    if typesSet[fileType] or enumsSet[fileType] or customTypesSet[fileType] then
        return  -- Type/enum/customTypeDef definitions are handled separately
    end
    -- ... (rest unchanged) ...
end
```

**g) Update `loadOtherFiles` signature (~line 356)**

Add `customTypesSet` parameter and thread it through to `processSingleTSVFile`:

```lua
local function loadOtherFiles(files, files_cache, file2dir, lcFn2Type, lcFn2Ctx, lcFn2Col,
    typesSet, enumsSet, customTypesSet, extends, raw_files, loadEnv, badVal)
    local expr_eval, contexts, options_extractor = setupLoadEnvironment(loadEnv)
    for _, file_name in ipairs(files) do
        if hasExtension(file_name, CSV) or hasExtension(file_name, TSV) then
            processSingleTSVFile(file_name, file2dir, contexts, lcFn2Type, lcFn2Ctx, lcFn2Col,
                typesSet, enumsSet, customTypesSet, extends, raw_files, files_cache,
                options_extractor, expr_eval, loadEnv, badVal)
        else
            processUnknownFile(file_name, raw_files, badVal)
        end
    end
end
```

**h) Update `processOrderedFiles` (~line 440)**

After `findAllTypes`, build `customTypesSet` and pass it to `loadOtherFiles`:

```lua
findAllTypes(extends, typesSet, enumsSet)
local customTypesSet = buildCustomTypesSet(lcFn2Type, extends)   -- NEW
-- ...
loadOtherFiles(files, tsv_files, file2dir, lcFn2Type,
    lcFn2Ctx, lcFn2Col, typesSet, enumsSet, customTypesSet, extends,  -- customTypesSet added
    raw_files, loadEnv, badVal)
```

#### 2. `DATA_FORMAT_README.md`

Add a new sub-section "Custom Type Definition Files" under the existing [Custom Types](#custom-types) section, after the "Using Custom Types" sub-section. It should document:

- The `typeName=custom_type_def` (or sub-type) pattern in Files.tsv
- Column omission (only include columns used by at least one row)
- The load ordering requirement
- A minimal TSV example with `Files.tsv` configuration
- The sub-type extension pattern (extra columns ignored during registration)

#### 3. New spec: `spec/manifest_loader_custom_type_def_files_spec.lua`

Use the same temp-directory pattern as `spec/manifest_loader_spec.lua`. Key test scenarios:

| # | Scenario | Expected Result |
|---|---|---|
| 1 | File with `typeName=custom_type_def` (no superType) → rows define types | Types registered; usable as column types in next file |
| 2 | File with `typeName=MyTypeDefs, superType=custom_type_def` → rows define types | Same as above |
| 3 | Sub-type with extra columns (e.g., `gameCategory:string`) | Extra columns parsed; only `custom_type_def` fields registered |
| 4 | Cascaded files: file A defines `myBase`, file B uses `parent=myBase` | Works if `loadOrder(A) < loadOrder(B)` |
| 5 | Empty custom type definition file (zero data rows) | No error; no types registered |
| 6 | Row with only `name` and `parent` (all other columns absent) | Alias registered successfully |
| 7 | Row with numeric constraints (`min`, `max`) | Range-restricted type registered |
| 8 | Row with `validate` expression | Expression-validated type registered |
| 9 | Row with `members` (type tag) | Type tag registered |
| 10 | Invalid row (bad `parent`) | Error logged; other rows still attempted |

---

## Decisions

### 1. Duplicate name collision

**Decision: Error on collision.** Registering a type name that is already registered with a different parent type is an error. This is consistent with the existing behavior of `registerAlias` in `parsers/registration.lua` (lines 65–76), which already errors on redefinition with a different type and is idempotent for the same type. No additional code is required — the collision is caught naturally by `registerTypesFromSpec` → `registerAlias`.

### 2. Validation of custom_type_def row structure

**Decision: Use existing behavior.** `parsers.registerTypesFromSpec` validates each spec internally and logs errors via `badVal`. If a required column (such as `name`) is missing from the file, every row produces an error from `registerTypesFromSpec`. This is clear enough in practice.

### 3. Export behavior

**Decision: Suggest `export=false`, do not change the default.** Custom type definition files are structural (type registration only) and typically should not be exported as data. The recommended practice — documented in `DATA_FORMAT_README.md` — is to set `export=false` explicitly in `Files.tsv`. (A file with no `joinInto` value defaults to `export=true`, so omitting the column is not sufficient.) The system default is not changed.

---

## Related Files

| File | Role |
|---|---|
| `manifest_loader.lua` | Primary implementation site |
| `manifest_info.lua` | Current manifest-based custom type registration (reference for approach) |
| `parsers/builtin.lua:776` | Where `custom_type_def` alias is registered |
| `parsers/registration.lua` | `registerTypesFromSpec` — the function called by both manifest and file paths |
| `files_desc.lua` | Builds the `extends` table from Files.tsv `superType` column |
| `DATA_FORMAT_README.md` | Documentation site for the new feature |
