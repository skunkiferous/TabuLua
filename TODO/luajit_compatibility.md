# LuaJIT Compatibility Testing and Analysis

## Prerequisites

This document assumes the **Safe Integer Migration** has been completed. See [safe_integer_migration.md](safe_integer_migration.md) for details.

The Safe Integer Migration changes:
- `integer` type now means "any integer exactly representable as a double" (±2^53)
- `long` type extends `number` directly (not `integer`) and supports full 64-bit range on Lua 5.3+
- On LuaJIT, `long` values outside the safe range generate warnings about potential precision loss

This document describes additional changes needed for full LuaJIT compatibility, including the `numbers.lua` abstraction module.

---

## Quick Start: Testing with LuaJIT Docker

### Prerequisites

- Docker installed in WSL
- Docker daemon running (`sudo service docker start` in WSL)

### Build the Test Image

```bash
# From Windows terminal (Git Bash/MSYS)
MSYS_NO_PATHCONV=1 wsl docker build -t luajit-test -f /mnt/c/Code/lua/game/Dockerfile.luajit /mnt/c/Code/lua/game
```

### Run Tests

```bash
# Run full test suite with compat53 loaded
MSYS_NO_PATHCONV=1 wsl docker run --rm -e 'LUA_INIT=require("compat53")' -v /mnt/c/Code/lua/game:/app luajit-test busted --lpath=?.lua --lpath=?/init.lua spec/
```

### Run Specific Test File

```bash
MSYS_NO_PATHCONV=1 wsl docker run --rm -e 'LUA_INIT=require("compat53")' -v /mnt/c/Code/lua/game:/app luajit-test busted --lpath=?.lua --lpath=?/init.lua spec/serialization_spec.lua
```

### Interactive Shell for Debugging

```bash
MSYS_NO_PATHCONV=1 wsl docker run --rm -it -e 'LUA_INIT=require("compat53")' -v /mnt/c/Code/lua/game:/app luajit-test sh
# Then inside container:
cd /app
luajit -e "require('your_module')"
```

## Current Test Results

| Lua Version | Successes | Failures | Errors | Status |
|-------------|-----------|----------|--------|--------|
| Lua 5.3     | 1605      | 0        | 0      | ✓ Full pass |
| Lua 5.4     | 1605      | 0        | 0      | ✓ Full pass |
| Lua 5.5     | 984       | 0        | 22     | ✗ ltcn incompatibility |
| LuaJIT 2.1  | 1512      | 19       | 74     | ✗ Partial support |

## Critical Requirement: compat53

LuaJIT is based on Lua 5.1 and lacks many Lua 5.3+ features. The [lua-compat-5.3](https://github.com/lunarmodules/lua-compat-5.3) library provides:

- `utf8` library (used by `predicates.lua`, `string_utils.lua`)
- `math.type()` function (integer vs float detection)
- `table.move()`, `table.pack()` with proper `n` field
- String packing functions (`string.pack`, `string.unpack`)

**Without compat53:** 364 successes, 129 failures, 1112 errors
**With compat53:** 1512 successes, 19 failures, 74 errors

The `LUA_INIT=require("compat53")` environment variable loads it before any script runs.

## Fixes Already Applied

### 1. Number Serialization (`serialization.lua:90-98`)

**Problem:** LuaJIT's `string.format("%q", 123)` outputs `"123"` (quoted string), while Lua 5.3+ outputs `123` (unquoted number).

**Fix:** Use `tostring()` for numbers instead of `%q`:

```lua
if isBasic(v) then
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    else
        -- For numbers, booleans, and nil, use tostring()
        -- Note: LuaJIT's %q quotes numbers which breaks round-trip serialization
        return tostring(v)
    end
end
```

### 2. Special Float Handling (`serialization.lua:77-89`)

**Problem:** Both Lua 5.3 and LuaJIT produce invalid Lua syntax for `math.huge` with `%q`.

**Fix:** Handle special floats explicitly before the `isBasic` check:

```lua
if type(v) == "number" then
    if v ~= v then  -- NaN check
        return "(0/0)"
    elseif v == math.huge then
        return "(1/0)"
    elseif v == -math.huge then
        return "(-1/0)"
    end
end
```

### 3. Sandbox Quota (`tsv_model.lua:701-704`)

**Problem:** The `sandbox` library doesn't support `quota` option on LuaJIT.

**Fix:** Check `sandbox.quota_supported` before using quota:

```lua
local opt = {env = expr_env}
if sandbox.quota_supported then
    opt.quota = EXPRESSION_MAX_OPERATIONS
end
```

## Remaining Issues Analysis

### Errors by Test File (74 total)

| Test File | Errors | Primary Issue |
|-----------|--------|---------------|
| `tsv_model_spec.lua` | 30 | Unknown - needs investigation |
| `manifest_loader_spec.lua` | 13 | Depends on tsv_model |
| `manifest_info_spec.lua` | 13 | Depends on tsv_model |
| `files_desc_spec.lua` | 11 | Depends on tsv_model |
| `reformatter_spec.lua` | 8 | Depends on tsv_model |
| `export_tester_spec.lua` | 1 | Depends on tsv_model |

### Failures by Test File (19 total)

| Test File | Failures | Primary Issue |
|-----------|----------|---------------|
| `lua_cog_spec.lua` | 11 | Sandbox execution differences |
| `read_only_spec.lua` | 3 | Unknown |
| `number_identifiers_spec.lua` | 3 | Integer/float edge cases |
| `parsers_simple_spec.lua` | 2 | Parser behavior differences |

### Root Cause Categories

#### 1. Integer vs Float Handling

LuaJIT uses doubles for all numbers. While `compat53` provides `math.type()`, some edge cases remain:

- Large integers (64-bit) lose precision as doubles
- The `long` type alias generates different parser names:
  - Lua 5.3+: `integer._R_GE_I_9223372036854775808_LE_I9223372036854775807`
  - LuaJIT: `integer._R_GE_F_9223372036854775808__LE_F9223372036854775808_`

#### 2. Sandbox Library Limitations

The `sandbox` library on LuaJIT:

- Does not support `quota` (execution limit) - **Fixed**
- May have different behavior for code execution
- The `lua_cog` module relies on sandbox for safe code execution

#### 3. Unknown tsv_model Issues

The 30 errors in `tsv_model_spec.lua` need investigation. The error at line 640 (`new_row[1].evaluated`) suggests cells aren't being processed, but the sandbox quota fix didn't fully resolve it.

## Key Differences: LuaJIT vs Lua 5.3+

| Feature | LuaJIT | Lua 5.3+ |
|---------|--------|----------|
| Number type | All doubles | Integers and floats |
| `math.type()` | Via compat53 | Native |
| `utf8` library | Via compat53 | Native |
| `string.format("%q", num)` | Quotes numbers | Unquoted for integers |
| 64-bit integers | Limited precision | Full precision |
| `sandbox.quota` | Not supported | Supported |
| Bitwise operators | `bit` library | Native `&`, `|`, etc. |

## Files Most Likely Needing Changes

1. **`tsv_model.lua`** - Expression evaluation, cell processing
2. **`lua_cog.lua`** - Sandbox usage for code generation
3. **`number_identifiers.lua`** - Number/identifier detection
4. **`parsers.lua`** - Type parser generation (especially for integers)

## Debugging Tips

### Check if a specific module loads

```bash
MSYS_NO_PATHCONV=1 wsl docker run --rm -e 'LUA_INIT=require("compat53")' -v /mnt/c/Code/lua/game:/app luajit-test luajit -e "local m = require('tsv_model'); print('OK')"
```

### Compare behavior between versions

```bash
# LuaJIT
MSYS_NO_PATHCONV=1 wsl docker run --rm -e 'LUA_INIT=require("compat53")' -v /mnt/c/Code/lua/game:/app luajit-test luajit -e "print(math.type(123), math.type(123.5))"

# Lua 5.4
MSYS_NO_PATHCONV=1 wsl docker run --rm -v /mnt/c/Code/lua/game:/app lua54-test lua -e "print(math.type(123), math.type(123.5))"
```

### Run tests with verbose output

```bash
MSYS_NO_PATHCONV=1 wsl docker run --rm -e 'LUA_INIT=require("compat53")' -v /mnt/c/Code/lua/game:/app luajit-test busted -v --lpath=?.lua --lpath=?/init.lua spec/tsv_model_spec.lua 2>&1 | head -100
```

---

## Proposed Solution: Number Abstraction Layer

### The Core Problem

In Lua 5.3+, `1` and `1.0` are different types (`math.type()` returns `"integer"` vs `"float"`). In LuaJIT, ALL numbers are doubles, so `1` and `1.0` are indistinguishable by value alone. This breaks:

1. **Serialization**: Can't tell if `1.0` should be written as `1` (integer) or `1.0` (float)
2. **Type validation**: Can't distinguish integer columns from float columns by examining values
3. **Large integers**: 64-bit integers lose precision when stored as doubles (safe range: ±2^53)

### Two Approaches to Integer Handling

#### Approach A: Safe Integers (Recommended for Most Cases)

Work within double's exact integer range (±2^53 = ±9,007,199,254,740,992). This covers most practical use cases and keeps values as regular Lua numbers that work seamlessly with all Lua operations.

**Pros:**
- Values remain regular Lua numbers
- Works with all standard Lua operations and libraries
- No special handling needed for arithmetic, comparisons, table keys
- Simple implementation

**Cons:**
- Cannot represent full 64-bit integer range
- Values outside ±2^53 lose precision silently

#### Approach B: FFI int64_t (For True 64-bit Integers)

Use LuaJIT's FFI with `int64_t`/`uint64_t` cdata types for values that need full 64-bit precision.

```lua
local ffi = jit and require("ffi")

-- LuaJIT: Parse string to FFI int64_t digit-by-digit
function stringToInt64(s)
    local result = ffi.new("int64_t", 0)
    local ten = ffi.new("int64_t", 10)
    for i = 1, #s do
        local digit = s:byte(i) - 48
        result = result * ten + digit
    end
    return result
end

-- Lua 5.3+: Use native math.tointeger
function stringToInt64(s)
    return math.tointeger(s)
end
```

**Pros:**
- Full 64-bit integer precision
- Exact round-trip for values like `9223372036854775807`

**Cons:**
- FFI cdata objects don't mix freely with Lua numbers
- Can't use as table keys directly
- Standard `math` functions don't work with cdata
- Requires separate code paths for LuaJIT vs Lua 5.3+
- More complex implementation and testing

#### Recommendation

Use **Approach A (Safe Integers)** for the `numbers.lua` module, with:
- Clear documentation that values outside ±2^53 may lose precision
- Warnings emitted when parsing values outside the safe range
- The `long` type restricted to safe integer range on LuaJIT

Consider **Approach B (FFI int64_t)** only for specific use cases where full 64-bit precision is required (e.g., database IDs, timestamps), implemented as a separate optional module.

### Design Principle: Column-Type-Driven Handling

Instead of inspecting values with `math.type()`, we should propagate **column type information** through the entire pipeline. The column definition (e.g., `age:integer`) should determine how values are formatted, serialized, and compared—not the runtime type of the value itself.

---

## Implementation Plan

### Phase 1: Number Abstraction Module (`numbers.lua`)

Create a centralized module for all number-related operations that need to behave consistently across Lua versions.

#### 1.1 Safe Integer Range Constants

```lua
local numbers = {}

-- Safe integer range for double-precision floats (IEEE 754)
-- Doubles can exactly represent integers in the range -(2^53) to (2^53)
numbers.SAFE_INTEGER_MIN = -9007199254740992  -- -(2^53)
numbers.SAFE_INTEGER_MAX = 9007199254740992   -- 2^53

-- Lua 5.3+ native integer range (for reference/compatibility flags)
numbers.LUA_INTEGER_MIN = math.mininteger or numbers.SAFE_INTEGER_MIN
numbers.LUA_INTEGER_MAX = math.maxinteger or numbers.SAFE_INTEGER_MAX

-- Runtime detection
numbers.HAS_NATIVE_INTEGERS = (math.type ~= nil and math.type(1) == "integer")
numbers.IS_LUAJIT = (jit ~= nil)
```

#### 1.2 Type Detection Functions

```lua
-- Check if value is a number
function numbers.isNumber(v)
    return type(v) == "number"
end

-- Check if value has an integer value (works on both Lua 5.3+ and LuaJIT)
-- This checks the VALUE, not the type
function numbers.hasIntegerValue(v)
    return type(v) == "number" and v == math.floor(v) and v == v  -- exclude NaN
end

-- Check if value is within safe integer range for doubles
function numbers.isSafeInteger(v)
    return numbers.hasIntegerValue(v)
       and v >= numbers.SAFE_INTEGER_MIN
       and v <= numbers.SAFE_INTEGER_MAX
end

-- Check if value is a "native" integer (Lua 5.3+) or would be (LuaJIT)
-- Note: On LuaJIT, this falls back to checking integer value within safe range
function numbers.isInteger(v)
    if numbers.HAS_NATIVE_INTEGERS then
        return type(v) == "number" and math.type(v) == "integer"
    else
        return numbers.isSafeInteger(v)
    end
end

-- Check if value is a float (has fractional part OR is outside safe integer range)
function numbers.isFloat(v)
    return type(v) == "number" and not numbers.hasIntegerValue(v)
end

-- Special value checks
function numbers.isNaN(v)
    return v ~= v
end

function numbers.isInfinity(v)
    return v == math.huge or v == -math.huge
end

function numbers.isSpecial(v)
    return numbers.isNaN(v) or numbers.isInfinity(v)
end
```

#### 1.3 Conversion Functions

```lua
-- Convert to integer if possible (preserves nil for invalid input)
-- Returns: integer, wasConverted (true if had to truncate/round)
function numbers.toInteger(v)
    if not numbers.isNumber(v) then
        return nil, false
    end
    if numbers.isNaN(v) or numbers.isInfinity(v) then
        return nil, false
    end
    local floored = math.floor(v)
    return floored, (floored ~= v)
end

-- Convert to safe integer (clamps to safe range)
function numbers.toSafeInteger(v)
    local int, wasConverted = numbers.toInteger(v)
    if int == nil then return nil, false end

    if int < numbers.SAFE_INTEGER_MIN then
        return numbers.SAFE_INTEGER_MIN, true
    elseif int > numbers.SAFE_INTEGER_MAX then
        return numbers.SAFE_INTEGER_MAX, true
    end
    return int, wasConverted
end

-- Ensure value is stored as float (for Lua 5.3+ consistency)
function numbers.toFloat(v)
    if not numbers.isNumber(v) then return nil end
    return v + 0.0
end
```

#### 1.4 Formatting Functions (Column-Type-Aware)

```lua
-- Format number based on intended type (integer vs float)
-- This is the KEY function for LuaJIT compatibility
function numbers.format(v, asInteger)
    if not numbers.isNumber(v) then return nil end

    -- Handle special values
    if numbers.isNaN(v) then return "nan" end
    if v == math.huge then return "inf" end
    if v == -math.huge then return "-inf" end

    if asInteger then
        -- Format as integer regardless of actual type
        return string.format("%.0f", math.floor(v))
    else
        -- Format as float
        if numbers.hasIntegerValue(v) then
            -- Integer-valued float: show with .0
            return string.format("%.1f", v)
        else
            -- True float: show full precision, strip trailing zeros
            local s = string.format("%.14f", v)
            s = s:gsub("0+$", ""):gsub("%.$", ".0")
            return s
        end
    end
end

-- Format for Lua serialization
function numbers.toLuaLiteral(v, asInteger)
    if not numbers.isNumber(v) then return nil end

    if numbers.isNaN(v) then return "(0/0)" end
    if v == math.huge then return "(1/0)" end
    if v == -math.huge then return "(-1/0)" end

    if asInteger then
        return string.format("%.0f", math.floor(v))
    else
        return tostring(v)
    end
end

-- Format for JSON (returns value suitable for JSON encoder)
function numbers.toJSONValue(v, asInteger, preserveType)
    if numbers.isNaN(v) then
        return preserveType and {float = "nan"} or "NAN"
    end
    if v == math.huge then
        return preserveType and {float = "inf"} or "INF"
    end
    if v == -math.huge then
        return preserveType and {float = "-inf"} or "-INF"
    end

    if preserveType and asInteger then
        return {int = string.format("%.0f", math.floor(v))}
    end

    return v
end
```

#### 1.5 Comparison Functions

```lua
-- Compare two numbers (handles NaN correctly)
function numbers.compare(a, b)
    -- NaN handling: NaN is considered greater than all other values
    local aNaN, bNaN = numbers.isNaN(a), numbers.isNaN(b)
    if aNaN and bNaN then return 0 end
    if aNaN then return 1 end
    if bNaN then return -1 end

    if a < b then return -1 end
    if a > b then return 1 end
    return 0
end

-- Equality check (type-aware for Lua 5.3+, value-based for LuaJIT)
function numbers.equals(a, b, strictType)
    if not numbers.isNumber(a) or not numbers.isNumber(b) then
        return false
    end

    -- NaN is never equal to anything, including itself
    if numbers.isNaN(a) or numbers.isNaN(b) then
        return false
    end

    if strictType and numbers.HAS_NATIVE_INTEGERS then
        -- In Lua 5.3+, 1 and 1.0 might need to be considered different
        return a == b and math.type(a) == math.type(b)
    end

    return a == b
end
```

#### 1.6 Parsing Functions

```lua
-- Parse string to number
function numbers.parse(s)
    return tonumber(s)
end

-- Parse string as integer (validates it's integer-valued)
function numbers.parseInteger(s)
    local n = tonumber(s)
    if n == nil then return nil end
    if not numbers.hasIntegerValue(n) then return nil end
    return math.floor(n)  -- Ensure integer type on Lua 5.3+
end

-- Parse string as float (ensures float type)
function numbers.parseFloat(s)
    local n = tonumber(s)
    if n == nil then return nil end
    return n + 0.0  -- Ensure float type on Lua 5.3+
end
```

---

### Phase 2: Refactor Existing Code to Use `numbers.lua`

#### 2.1 Files to Modify

| File | Current Pattern | New Pattern |
|------|-----------------|-------------|
| `predicates.lua` | `math.type(v) == "integer"` | `numbers.isInteger(v)` |
| `serialization.lua` | Direct `math.type()` checks | `numbers.format(v, isInteger)` |
| `deserialization.lua` | `math.type()` validation | `numbers.isInteger(v)` |
| `parsers/builtin.lua` | `math.type(num) ~= 'integer'` | `numbers.hasIntegerValue(num)` |
| `parsers/registration.lua` | `math.type(v) == "integer"` | `numbers.isInteger(v)` |
| `number_identifiers.lua` | `math.type(n)` for encoding | `numbers.isInteger(n)` |

#### 2.2 Integration with Parser System

The parser system already knows the column type. We need to ensure this information flows to serialization:

```lua
-- In parsers/builtin.lua, modify integer parser to tag values:
-- Option A: Use a wrapper table (more intrusive)
-- Option B: Store column type in cell metadata (current approach)
-- Option C: Pass column type to serialization functions (recommended)
```

**Recommended approach**: Modify serialization functions to accept an optional `columnType` parameter:

```lua
-- In serialization.lua
local function serializeValue(v, columnType)
    if type(v) == "number" then
        local asInteger = (columnType == "integer" or
                          columnType == "int" or
                          columnType == "long" or
                          columnType == "byte" or
                          columnType == "ubyte" or
                          columnType == "short" or
                          columnType == "ushort")
        return numbers.toLuaLiteral(v, asInteger)
    end
    -- ... rest of serialization
end
```

---

### Phase 3: Column-Type Propagation

#### 3.1 Current Data Flow

```
TSV Input → Parse Headers → Column Objects (with type) → Parse Cells → Store
                                    ↓
                              cell.parsed (value only, no type info)
```

#### 3.2 Enhanced Data Flow (Option A: Type-Aware Cells)

Add type info to cell storage:

```lua
-- Cell structure becomes:
{
    value = "123",           -- Original string
    evaluated = 123,         -- After expression
    parsed = 123,            -- Parsed value
    reformatted = "123",     -- String for output
    column_type = "integer"  -- Column type (new field)
}
```

**Pros**: Type info available everywhere
**Cons**: Memory overhead per cell

#### 3.3 Enhanced Data Flow (Option B: Type Lookup at Export)

Keep cells as-is, but pass column info during export:

```lua
-- In export functions, iterate with column info:
for col_idx, col in ipairs(columns) do
    local cell = row[col_idx]
    local formatted = numbers.format(cell.parsed, isIntegerType(col.type))
end
```

**Pros**: No memory overhead, minimal changes
**Cons**: Requires column context at export time (already available in most cases)

#### 3.4 Recommendation

**Use Option B** for most cases since column information is already available during:
- TSV export (iterates columns)
- JSON export (iterates columns)
- SQL generation (uses column types)

Only consider Option A if there are cases where values are serialized without column context.

---

### Phase 4: Handle Edge Cases

#### 4.1 Large Integers Outside Safe Range

For values outside ±2^53 (common in 64-bit IDs, timestamps):

**Option A: String representation**
```lua
-- Store as string, mark as "bigint"
if not numbers.isSafeInteger(v) then
    return tostring(math.floor(v)), "bigint"
end
```

**Option B: Warn and truncate**
```lua
if not numbers.isSafeInteger(v) then
    badVal:emit("Integer %s may lose precision in LuaJIT", tostring(v))
end
```

**Option C: Use a bigint library** (e.g., lbc, lua-bn) - likely overkill

**Recommendation**: Option B for now (warn), with Option A as future enhancement for specific use cases.

#### 4.2 Integer Ranges in Parser Names

**Note:** This issue is addressed by the [Safe Integer Migration](safe_integer_migration.md), which redefines `integer` to use the safe range (±2^53) and makes `long` extend `number` directly instead of `integer`.

After the Safe Integer Migration:
- `integer` uses consistent bounds across all platforms: ±9,007,199,254,740,992
- `long` extends `number` directly and has platform-specific behavior
- Parser names are consistent because `integer` no longer uses `math.mininteger`/`math.maxinteger`

#### 4.3 Expression Evaluation Results

When expressions like `=row.a + row.b` produce numbers, we need to determine if result should be integer or float:

**Rule**: If all operands are from integer columns, result is integer. Otherwise, float.

This requires tracking type through expression evaluation - complex but doable with a custom evaluator or by analyzing the expression AST.

**Simpler alternative**: Always treat expression results based on the TARGET column's type.

---

### Phase 5: Testing Strategy

#### 5.1 Add LuaJIT-Specific Tests

```lua
-- spec/numbers_spec.lua
describe("numbers module", function()
    describe("safe integer range", function()
        it("correctly identifies safe integers", function()
            assert.is_true(numbers.isSafeInteger(0))
            assert.is_true(numbers.isSafeInteger(9007199254740992))
            assert.is_true(numbers.isSafeInteger(-9007199254740992))
            assert.is_false(numbers.isSafeInteger(9007199254740993))  -- 2^53 + 1
        end)

        it("handles precision loss", function()
            -- This test documents behavior, not necessarily desired outcome
            local big = 9007199254740993
            assert.equals(9007199254740992, big)  -- Precision loss in double
        end)
    end)

    describe("formatting", function()
        it("formats integers without decimal", function()
            assert.equals("123", numbers.format(123, true))
            assert.equals("123", numbers.format(123.0, true))
        end)

        it("formats floats with decimal", function()
            assert.equals("123.0", numbers.format(123, false))
            assert.equals("123.5", numbers.format(123.5, false))
        end)
    end)
end)
```

#### 5.2 Cross-Version Compatibility Matrix

| Test Case | Lua 5.3 | Lua 5.4 | LuaJIT |
|-----------|---------|---------|--------|
| `numbers.isInteger(1)` | true | true | true |
| `numbers.isInteger(1.0)` | false | false | true* |
| `numbers.format(1, true)` | "1" | "1" | "1" |
| `numbers.format(1.0, false)` | "1.0" | "1.0" | "1.0" |
| Large int precision | exact | exact | lossy |

*On LuaJIT, `1.0` is indistinguishable from `1`, so `isInteger(1.0)` returns true.

---

### Implementation Priority

1. **HIGH**: Create `numbers.lua` module with core functions
2. **HIGH**: Update `serialization.lua` to use column-type-aware formatting
3. **MEDIUM**: Update `parsers/builtin.lua` to use numbers module
4. **MEDIUM**: Fix `long` type range for LuaJIT compatibility
5. **LOW**: Add comprehensive cross-version tests
6. **LOW**: Handle large integers outside safe range (if needed)

---

### Expected Outcome

After implementing both the [Safe Integer Migration](safe_integer_migration.md) and this plan:

| Metric | Before | After Safe Integer Migration | After numbers.lua |
|--------|--------|------------------------------|-------------------|
| LuaJIT Errors | 74 | ~30-40 | ~10-20 |
| LuaJIT Failures | 19 | ~10-15 | ~5-10 |
| Cross-version consistency | Partial | Good | High |

The remaining issues will likely be:

- Sandbox-related (not fixable without library changes)
- Genuine feature differences (e.g., 64-bit integer precision for `long` type)

---

## References

- [lua-compat-5.3 on GitHub](https://github.com/lunarmodules/lua-compat-5.3)
- [LuaJIT Documentation](https://luajit.org/luajit.html)
- [kikito/lua-sandbox](https://github.com/kikito/lua-sandbox)
- [Dockerfile.luajit](Dockerfile.luajit) - Docker build configuration
- [IEEE 754 Double Precision](https://en.wikipedia.org/wiki/Double-precision_floating-point_format) - Safe integer range explanation
