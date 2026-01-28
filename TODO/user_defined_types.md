# TODO: Safe User-Defined Types via Code Libraries

## Background

We want to allow users to register custom types using the `parsers` module, leveraging the existing "code library" sandboxing functionality. This would enable users to define domain-specific validation beyond what's possible with pure data in TSV files.

## Security Analysis

### The Problem

The `lua-sandbox` library (kikito/lua-sandbox) has a critical limitation: **functions returned by sandboxed code are NOT sandboxed when called later**.

Current flow:
1. Code libraries execute in a sandbox (`manifest_info.lua:329-367`)
2. Libraries return a table of exports (including functions)
3. These exported functions become **regular Lua functions** once returned
4. If passed to `parsers.restrictWithValidator()`, they execute **outside any sandbox**

This means a malicious library could return a validator function that executes arbitrary code when invoked during parsing.

### Why `restrictWithValidator` Can't Directly Use Library Functions

```lua
-- registration.lua:110-138
function M.restrictWithValidator(badVal, parentName, newParserName, validator)
    -- ...
    state.PARSERS[newParserName] = function(badVal2, value, context)
        -- ...
        local err = validator(parsed)  -- Called later, OUTSIDE sandbox
        -- ...
    end
end
```

The validator is stored and called during normal parsing operations, with no sandboxing.

## Proposed Solutions

### Option 1: Data-Driven Validators (Recommended)

Accept declarative validation rules as structured data that trusted code interprets.

**User library would return:**
```lua
return {
    types = {
        positiveInt = { extends = "integer", min = 1 },
        percentage = { extends = "number", min = 0, max = 100 },
        shortCode = { extends = "string", minLen = 2, maxLen = 5, pattern = "^[A-Z]+$" },
        myEnum = { extends = "enum", values = {"alpha", "beta", "gamma"} },
    }
}
```

**Implementation would add:**
```lua
-- New function in registration.lua or a new module
function M.registerTypesFromSpec(badVal, typeSpecs)
    for name, spec in pairs(typeSpecs) do
        if spec.extends and (spec.min or spec.max) then
            -- Numeric type with range
            M.restrictNumber(badVal, spec.extends, spec.min, spec.max, name)
        elseif spec.extends and (spec.minLen or spec.maxLen or spec.pattern) then
            -- String type with constraints
            M.restrictString(badVal, spec.extends, spec.minLen, spec.maxLen, spec.pattern, name)
        elseif spec.extends and spec.values then
            -- Restricted enum
            M.restrictEnum(badVal, spec.extends, spec.values, name)
        -- ... handle other cases
        end
    end
end
```

**Pros:**
- Safest approach - no code execution from user input
- Leverages existing `restrictNumber`, `restrictString`, `restrictEnum` functions
- Easy to validate and document the schema

**Cons:**
- Limited to validation patterns you explicitly support
- Users can't express arbitrary logic

### Option 2: Expression-Based Validators

Allow validators as string expressions that get sandboxed at call time.

**User library would return:**
```lua
return {
    types = {
        positiveInt = { extends = "integer", validate = "value > 0" },
        evenNumber = { extends = "integer", validate = "value % 2 == 0" },
        coordinates = { extends = "string", validate = "value:match('^%-?%d+,%-?%d+$')" },
    }
}
```

**Implementation:**
```lua
function M.restrictWithExpression(badVal, parentName, newParserName, exprString)
    local parent = parseType(badVal, parentName)
    if not parent then return nil end

    state.PARSERS[newParserName] = function(badVal2, value, context)
        local parsed, reformatted = generators.callParser(parent, badVal2, value, context)
        if parsed == nil then return nil, reformatted end

        -- Sandbox the expression at call time
        local code = "return (" .. exprString .. ")"
        local expr_env = {value = parsed, math = math, string = string}
        local opt = {quota = 1000, env = expr_env}
        local ok, result = pcall(sandbox.protect(code, opt))

        if not ok or not result then
            utils.log(badVal2, newParserName, value, "validation failed")
            return nil, reformatted
        end
        return parsed, reformatted
    end
    -- ...
end
```

**Pros:**
- More flexible than pure data
- Still sandboxed (with quota)

**Cons:**
- Performance overhead (sandbox.protect called on every parse)
- More complex error handling
- Expression syntax may be limiting for complex validations

### Option 3: Predicate Combinators

Provide pre-built, composable predicates that users reference by name.

**User library would return:**
```lua
return {
    types = {
        positiveInt = { extends = "integer", checks = {{"gt", 0}} },
        bounded = { extends = "number", checks = {{"gte", 0}, {"lte", 100}} },
        nonEmpty = { extends = "string", checks = {{"minLen", 1}} },
        combined = { extends = "integer", checks = {{"gt", 0}, {"lt", 1000}, {"divisibleBy", 5}} },
    }
}
```

**Implementation would define a registry of safe predicates:**
```lua
local PREDICATES = {
    gt = function(threshold) return function(v) return v > threshold end end,
    gte = function(threshold) return function(v) return v >= threshold end end,
    lt = function(threshold) return function(v) return v < threshold end end,
    lte = function(threshold) return function(v) return v <= threshold end end,
    minLen = function(n) return function(v) return #v >= n end end,
    maxLen = function(n) return function(v) return #v <= n end end,
    pattern = function(p) return function(v) return v:match(p) ~= nil end end,
    divisibleBy = function(n) return function(v) return v % n == 0 end end,
    -- ... more predicates
}
```

**Pros:**
- Safe - only trusted predicates execute
- Composable for complex validations
- Good performance (no runtime sandboxing)

**Cons:**
- Limited to predicates you define
- Slightly more verbose than expressions

## Recommendation

**Start with Option 1 (Data-Driven Validators)** because:
1. It's the safest and simplest
2. It reuses existing registration functions
3. Most real-world type restrictions fit this model (ranges, lengths, patterns, enum subsets)

If users need more flexibility later, Option 3 (Predicate Combinators) can be added incrementally.

## Implementation Steps

1. Define the type specification schema (what fields are allowed)
2. Add `registerTypesFromSpec()` function to `registration.lua`
3. Modify `loadCodeLibraries()` in `manifest_info.lua` to detect and process `types` exports
4. Add validation that type specs contain only safe data (no functions)
5. Document the feature in `DATA_FORMAT_README.md`
6. Add tests for various type specifications

## Open Questions

- Should type registration happen before or after library loading?
- How to handle type dependencies (one user type extending another user type)?
- Should we support union types in the spec? (`{ extends = "string|nil", ... }`)
- Error message customization for validation failures?
