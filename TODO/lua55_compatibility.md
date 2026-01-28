# Lua 5.5 Compatibility Issues

## Summary

The project currently fails 22 tests on Lua 5.5.0 due to an incompatibility in the `ltcn` library (Lua Table Constructor Notation parser).

**Current test results:**

- Lua 5.3: 1605 successes ✓
- Lua 5.4: 1605 successes ✓
- Lua 5.5: 984 successes, 22 errors ✗

## Upstream Issue Status

**No existing issue has been filed** for Lua 5.5 compatibility on the ltcn repository as of January 2026.

- Last commit: November 4, 2024 (before Lua 5.5 release)
- CI only tests Lua 5.1, 5.2, 5.3, and 5.4
- The ltcn test suite fails on Lua 5.5 with the same error

## Root Cause

Lua 5.5 introduced a breaking change: **loop variables in `for...in` loops are now implicitly `<const>`** and cannot be reassigned inside the loop body.

The `ltcn` library (version scm-1 from the dev server) has the following code in `ltcn.lua` at line 55-67, function `tokenset_to_list`:

```lua
local function tokenset_to_list(set)
    local list, i = {}, 0
    for s in pairs(set) do
        i = i + 1
        if s:match("^%p$") then
            -- Quote punctuation characters
            s = (s == "'") and '"\'"' or ("'" .. s .. "'")  -- ERROR on Lua 5.5
        end
        list[i] = s
    end
    sort(list)
    return list
end
```

This causes the error:

```text
attempt to assign to const variable 's'
```

## Affected Tests

All tests that use `table_parsing.lua` fail because it depends on `ltcn`:

- `spec/table_parsing_spec.lua` (all tests)
- Various other specs that indirectly use table parsing

## Required Fix

### Option 1: Wait for upstream fix (Preferred)

The `ltcn` library needs to be updated to use a different variable for the modified value:

```lua
for s in pairs(set) do
    ...
    local quoted = (s == "'") and '"\'"' or ("'" .. s .. "'")
    list[i] = quoted
end
```

**Upstream repository:** <https://gitlab.com/craigbarnes/ltcn>

### Option 2: Fork and patch locally

1. Fork the ltcn repository
2. Apply the fix above
3. Update `Dockerfile.lua55` to install from the fork

### Option 3: Vendor a patched copy

1. Copy `ltcn.lua` into the project
2. Apply the fix
3. Adjust the require path

## Additional Notes

- Lua 5.5 was released on December 22, 2025, so library ecosystem support is still catching up
- The `compat53` library works fine on Lua 5.5 (it's a no-op since 5.5 already has all 5.3 features)
- No changes are needed to this project's own code for Lua 5.5 compatibility

## References

- [Lua 5.5 Release Notes](https://www.lua.org/manual/5.5/readme.html)
- [ltcn on LuaRocks](https://luarocks.org/modules/craigb/ltcn)
- [ltcn GitLab Repository](https://gitlab.com/craigbarnes/ltcn)
