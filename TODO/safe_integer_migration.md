# Safe Integer Migration Plan

## Overview

This document describes an intermediate step towards LuaJIT compatibility that changes the semantics of the `integer` and `long` types to better align with the limitations of double-precision floating-point numbers while preserving compatibility with existing user data.

## Motivation

### The Problem

In Lua 5.3+, `integer` can represent the full 64-bit signed integer range:
- Min: `-9223372036854775808` (−2^63)
- Max: `9223372036854775807` (2^63 − 1)

In LuaJIT (and JSON), all numbers are represented as IEEE 754 double-precision floats, which can only exactly represent integers in the "safe integer" range:
- Min: `-9007199254740992` (−2^53)
- Max: `9007199254740992` (2^53)

Values outside this range lose precision when stored as doubles. For example:
```lua
-- In LuaJIT or when parsing JSON:
local big = 9223372036854775807  -- Intended: max 64-bit signed integer
print(big)                       -- Actual: 9223372036854775808 (wrong!)
```

### Current State

Currently in TabuLua:
- `integer` extends `number` and validates using `math.type(num) == 'integer'`
- `long` restricts `integer` to the range `[-9223372036854775808, 9223372036854775807]`

This works on Lua 5.3+ but causes issues on LuaJIT because:
1. `math.type()` (via compat53) treats all doubles as "float" unless they're integer-valued
2. Large integers lose precision when stored as doubles
3. Parser names differ between platforms due to how large numbers are represented

### The Migration Goal

Most user data contains integers well within the safe integer range (±2^53). Only specific cases like:
- Database auto-increment IDs
- 64-bit timestamps
- Snowflake IDs
- Very large counters

...require full 64-bit precision. This migration provides a path that:
1. Preserves compatibility for the vast majority of existing data
2. Clearly identifies data that requires special handling
3. Aligns `integer` with what JSON and LuaJIT can represent natively

## Proposed Type Hierarchy Changes

### New Type Definitions

| Type | Range | Description |
|------|-------|-------------|
| `number` | All IEEE 754 doubles | Base numeric type (unchanged) |
| `integer` | ±9,007,199,254,740,992 (±2^53) | Any integer exactly representable as a double |
| `long` | Full 64-bit range (Lua 5.3+) or same as `integer` (LuaJIT) | Large integers requiring full precision |

### Type Hierarchy

**Before:**
```
number
  └── integer
        ├── byte, ubyte, short, ushort, int, uint
        └── long (restricts integer to 64-bit range)
```

**After:**
```
number
  ├── integer (safe integer range ±2^53)
  │     └── byte, ubyte, short, ushort, int, uint
  └── long (full 64-bit range, does NOT extend integer)
```

Key change: `long` extends `number` directly, not `integer`. This is necessary because `long` accepts values OUTSIDE the range of `integer`.

### Rationale: "integer" as the Default

In C, `int` represents the "native" or "default" integer size, with larger types like `long` available when needed. Similarly:
- `integer` should represent the "safe default" that works everywhere (including JSON/LuaJIT)
- `long` is the explicit choice when full 64-bit precision is required

This naming convention:
1. Matches programmer intuition from C-family languages
2. Makes the common case (`integer`) work seamlessly across all platforms
3. Requires explicit opt-in (`long`) for cases that need special handling

## Implementation Plan

### Phase 1: Define Safe Integer Constants

Add constants to track safe integer boundaries:

```lua
-- In a new numbers.lua module or in predicates.lua
local SAFE_INTEGER_MIN = -9007199254740992  -- -(2^53)
local SAFE_INTEGER_MAX = 9007199254740992   -- 2^53

-- Detect if we're on LuaJIT
local IS_LUAJIT = (jit ~= nil)

-- Detect if we have native 64-bit integers
local HAS_NATIVE_INTEGERS = (math.type ~= nil and math.type(1) == "integer")
```

### Phase 2: Modify the `integer` Parser

Update [parsers/builtin.lua:532-544](parsers/builtin.lua#L532-L544):

```lua
-- Any integer within the safe range
local SAFE_INTEGER_MIN = -9007199254740992
local SAFE_INTEGER_MAX = 9007199254740992

registration.extendParser(ownBadVal, 'number', 'integer',
function (badVal, num, _reformatted, _context)
    if not isIntegerValue(num) then
        utils.log(badVal, 'integer', num)
        return nil, tostring(num)
    end
    -- Validate within safe integer range
    if num < SAFE_INTEGER_MIN or num > SAFE_INTEGER_MAX then
        utils.log(badVal, 'integer', num,
            "value outside safe integer range (±2^53)")
        return nil, tostring(num)
    end
    -- Ensure we return an integer on Lua 5.3+
    if math.type and math.type(num) ~= 'integer' then
        num = math.floor(num)
    end
    return num, tostring(num)
end)
```

### Phase 3: Redefine the `long` Type

Update [parsers/builtin.lua:655-657](parsers/builtin.lua#L655-L657):

```lua
-- "long" type: full 64-bit signed integer range
-- Note: Does NOT extend "integer" since its range is larger
if HAS_NATIVE_INTEGERS then
    -- Lua 5.3+: Support full 64-bit range
    local LONG_MIN = math.mininteger  -- -9223372036854775808
    local LONG_MAX = math.maxinteger  -- 9223372036854775807

    registration.extendParser(ownBadVal, 'number', 'long',
    function (badVal, num, _reformatted, _context)
        if not isIntegerValue(num) then
            utils.log(badVal, 'long', num)
            return nil, tostring(num)
        end
        if num < LONG_MIN or num > LONG_MAX then
            utils.log(badVal, 'long', num, "value outside 64-bit range")
            return nil, tostring(num)
        end
        if math.type(num) ~= 'integer' then
            num = math.floor(num)
        end
        return num, tostring(num)
    end)
else
    -- LuaJIT: "long" is limited to safe integer range with a warning
    -- Full 64-bit support would require FFI int64_t, which is out of scope
    registration.extendParser(ownBadVal, 'number', 'long',
    function (badVal, num, _reformatted, _context)
        if not isIntegerValue(num) then
            utils.log(badVal, 'long', num)
            return nil, tostring(num)
        end
        if num < SAFE_INTEGER_MIN or num > SAFE_INTEGER_MAX then
            utils.log(badVal, 'long', num,
                "LuaJIT cannot precisely represent 64-bit integers; value may lose precision")
            -- Still accept the value, but warn about potential precision loss
        end
        return math.floor(num), tostring(math.floor(num))
    end)
end

-- Mark that "long" extends "number" directly (NOT "integer")
generators.extendsOrRestrictsType('long', 'number')
```

### Phase 4: Update Derived Integer Types

The types `byte`, `ubyte`, `short`, `ushort`, `int`, `uint` are already subsets of the safe integer range, so they continue to extend `integer` without changes.

Verify their ranges fit within ±2^53:
| Type | Min | Max | Within ±2^53? |
|------|-----|-----|---------------|
| byte | -128 | 127 | ✓ |
| ubyte | 0 | 255 | ✓ |
| short | -32768 | 32767 | ✓ |
| ushort | 0 | 65535 | ✓ |
| int | -2147483648 | 2147483647 | ✓ |
| uint | 0 | 4294967295 | ✓ |

### Phase 5: Update restrictNumber Function

Update [parsers/registration.lua:200-231](parsers/registration.lua#L200-L231) to use safe integer bounds when the parent is `integer`:

```lua
if parentInteger then
    -- For "integer" type, use safe integer range as default bounds
    local defaultMin = SAFE_INTEGER_MIN
    local defaultMax = SAFE_INTEGER_MAX

    if t_min ~= 'nil' then
        if not isIntegerValue(min) then
            utils.log(badVal, 'number', min,
                'min must be an integer or nil, to extend ' .. numberType)
            return nil, newParserName
        end
        min = math.floor(min)
    else
        min = defaultMin
    end
    if t_max ~= 'nil' then
        if not isIntegerValue(max) then
            utils.log(badVal, 'number', max,
                'max must be an integer or nil to extend ' .. numberType)
            return nil
        end
        max = math.floor(max)
    else
        max = defaultMax
    end
end
```

## Export Format Implications

### TSV Format

No changes needed. Numbers are exported as strings, which can represent any value exactly.

### JSON Format

JSON numbers are IEEE 754 doubles, same as the new `integer` range. This is already a perfect match.

For `long` values outside the safe range on Lua 5.3+, consider:
1. **Option A**: Export as strings (e.g., `"9223372036854775807"`)
2. **Option B**: Export as-is and let consumers handle precision loss
3. **Option C**: Provide a schema option to choose behavior

Recommendation: Option A for typed-JSON exports where precision matters.

### Lua Serialization

Lua 5.3+ can serialize full 64-bit integers. LuaJIT serialization will use doubles, which may lose precision for large `long` values.

## Migration Impact on User Data

### Data That Continues to Work

- All integers in the range ±9,007,199,254,740,992
- All uses of `byte`, `ubyte`, `short`, `ushort`, `int`, `uint`
- Any data that was already JSON-compatible

### Data That May Need Attention

- Data using `long` with values > 2^53 or < -2^53
- Database IDs that exceed the safe integer range
- 64-bit timestamps stored as integers

### Migration Path for Affected Data

Users with data containing large integers have options:
1. **Keep using `long`**: Works on Lua 5.3+, with precision warnings on LuaJIT
2. **Store as strings**: Use a string type with a pattern like `^\-?\d+$`
3. **Use a bigint custom type**: Implement expression-based validation for string-encoded integers

## Testing Strategy

### Unit Tests

1. Test `integer` accepts values at ±2^53 boundaries
2. Test `integer` rejects values just outside ±2^53
3. Test `long` accepts full 64-bit range on Lua 5.3+
4. Test `long` warns but accepts large values on LuaJIT
5. Test derived types (`int`, `uint`, etc.) still work correctly

### Cross-Platform Tests

Run the same test data through Lua 5.3, Lua 5.4, and LuaJIT to verify:
- Consistent parsing results for safe integers
- Appropriate warnings for unsafe integers on LuaJIT
- Export/import round-trips preserve values correctly

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Breaking existing data with large integers | Document the change; provide migration guidance |
| Performance impact of range checks | Range checks are simple comparisons; negligible impact |
| Confusion about `long` not extending `integer` | Clear documentation; type hierarchy diagrams |
| LuaJIT users expecting full 64-bit support | Clear error messages; document limitations |

## Success Criteria

1. All existing tests pass (except those specifically testing full 64-bit `integer` range)
2. New tests cover safe integer boundary conditions
3. LuaJIT test failures related to integer parsing are reduced
4. Documentation clearly explains the type hierarchy and limitations

## Future Considerations

This migration is a stepping stone. Future work may include:
- A `numbers.lua` module for centralized number handling (as described in luajit_compatibility.md)
- Optional FFI-based `int64` type for LuaJIT users needing full 64-bit precision
- Column-type-aware serialization for optimal JSON export

## References

- [IEEE 754 Safe Integer Range](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Number/MAX_SAFE_INTEGER)
- [LuaJIT Compatibility Analysis](luajit_compatibility.md)
- [TabuLua Type System](../MODULES.md)
