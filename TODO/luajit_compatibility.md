# LuaJIT Compatibility

## Status

**Full parity reached (2026-07-16), with documented, deliberate exceptions.** Of the
suite's 3253 tests, LuaJIT 2.1 (current rolling release) passes 3250 with 0 failures /
0 errors; the remaining 3 are `pending` on LuaJIT only, because they assert behaviour
LuaJIT cannot provide (sandbox instruction quotas — see below). The host Lua 5.4 run
passes all 3253, unchanged. Working tree, not yet committed.

| Lua Version                               | Result                                        |
|-------------------------------------------|-----------------------------------------------|
| Lua 5.3 / 5.4 / 5.5                       | full pass (see `TODO/lua55_compatibility.md`) |
| LuaJIT 2.1 (LUA52COMPAT build + compat53) | 3250 pass / 0 fail / 3 pending (quota tests)  |

Historical context: when this document was first written the suite stood at
1512 successes / 19 failures / 74 errors on LuaJIT (of 1605 tests). By 2026-07 the
zip/archive work had made it far worse — ~30 whole spec FILES died at `require` time
(bitwise syntax), leaving 2819 / 12 / 402 on a suite of ~3240. All of it traced to
four root causes, all fixed below.

## What LuaJIT needs to run TabuLua

1. **A LuaJIT built with `-DLUAJIT_ENABLE_LUA52COMPAT`.** Non-negotiable, see root
   cause 3: without it, `#proxy` on every read-only table silently answers 0. The
   stock LuaJIT (and the stock `nickblah/luajit` Docker image) is NOT built with it;
   [Docker/Dockerfile.luajit](../Docker/Dockerfile.luajit) rebuilds LuaJIT from source
   with the flag and asserts the capability took.
2. **`compat53`** (the lua-compat-5.3 rock), loaded before anything else — e.g.
   `LUA_INIT=require("compat53")`. Provides `utf8`, `math.type`, `math.maxinteger`,
   `table.move`, `string.pack`, and patches `pairs`/`ipairs` to honour metamethods.
3. The same rocks as any other Lua (busted, semver, lpeg, libdeflate, …).

## Testing with Docker

```bash
# Build the image (rebuilds LuaJIT with LUA52COMPAT — takes a few minutes)
MSYS_NO_PATHCONV=1 wsl docker build -t luajit-test -f /mnt/c/Code/TabuLua/Docker/Dockerfile.luajit /mnt/c/Code/TabuLua

# Run the full suite
MSYS_NO_PATHCONV=1 wsl docker run --rm -e 'LUA_INIT=require("compat53")' -v /mnt/c/Code/TabuLua:/app luajit-test \
    busted --lpath=?.lua --lpath=?/init.lua -p spec

# One spec / interactive shell
MSYS_NO_PATHCONV=1 wsl docker run --rm -e 'LUA_INIT=require("compat53")' -v /mnt/c/Code/TabuLua:/app luajit-test \
    busted --lpath=?.lua --lpath=?/init.lua spec/serialization_spec.lua
MSYS_NO_PATHCONV=1 wsl docker run --rm -it -e 'LUA_INIT=require("compat53")' -v /mnt/c/Code/TabuLua:/app -w /app luajit-test sh
```

## The four root causes (all fixed 2026-07-16)

### 1. Lua 5.3 bitwise OPERATOR syntax — ~30 spec files dead at require time

LuaJIT parses Lua 5.1 syntax; `&`, `|`, `~`, `<<`, `>>` are **syntax errors**, and no
runtime shim can fix a file that won't compile. The zip/gzip work
(`TODO/archive_files.md`, post-dating this doc) used them in
`content/compression.lua` (CRC-32 kernel, gzip flag tests, `u32le`) and
`content/archive_formats.lua` — and since `manifest_loader` requires
`archive_formats`, every spec that touches the loader died at load. Six specs used
the operators in little-endian byte-encoder helpers too.

**Fix:** new [util/bit_ops.lua](../util/bit_ops.lua) — `band`/`bor`/`bxor`/`lshift`/`rshift`
working on every supported Lua. The 5.3+ implementation is compiled from a *string*
(`load`), so the file itself stays parseable everywhere; LuaJIT falls back to its
`bit` library with results normalized to unsigned `[0, 2^32)` (LuaJIT's `bit.*`
returns SIGNED 32-bit values, which would corrupt CRC comparisons). The CRC-32
kernel goes through it; the trivial flag tests and byte encoders became plain
arithmetic (`%`, `math.floor`). Known-answer coverage in
[spec/bit_ops_spec.lua](../spec/bit_ops_spec.lua) (canonical `"123456789"` →
`0xCBF43926`), asserted identical on every version.

### 2. Sandbox `quota` raises on LuaJIT — every sandboxed feature broken

kikito's sandbox implements instruction quotas with `debug.sethook` count hooks,
which LuaJIT does not support: `sandbox.protect(code, {quota = n})` **raises**
(`sandbox.quota_supported == false`). Two old call sites (`tsv_model`, `data_set`)
guarded this; the seven modules written since did not (`manifest_info` code
libraries, `parsers/registration` validate exprs, `lua_cog`, `lua_transcoder`,
`validator_executor` — which `patch_executor` rides through — `processor_executor`,
and `serialization.serializeInSandbox`). So on LuaJIT every validator, processor,
code library, COG block and `.lua` data file failed.

**Fix:** one helper, `sandbox_env.protectOptions(quota, env)`
([infra/sandbox_env.lua](../infra/sandbox_env.lua)) — applies the quota only where
the library can enforce it; all ten call sites route through it. **Consequence: on
LuaJIT, sandboxed user code runs without an operation limit** (still sandboxed for
API surface, just not instruction-counted). Three tests that assert quota-abort
behaviour (`while true do end` aborting, "quota exceeded" messages) are `pending` on
LuaJIT via an `it_quota` gate — on LuaJIT the first two would genuinely hang.

### 3. The read-only layer's empty proxies — `#header` answered 0 (401 of 402 errors)

`util/read_only.lua` wraps every table in an **empty** proxy table whose length,
iteration and lookups come from `__len` / `__pairs` / `__ipairs` / `__index`
metamethods (the emptiness is the point: `next(proxy)` must not leak the original).
LuaJIT only honours `__len` on **tables** when compiled with
`-DLUAJIT_ENABLE_LUA52COMPAT`; `compat53` can patch the `pairs`/`ipairs` *functions*
but nothing can patch the `#` *operator*. On a stock LuaJIT build, `#proxy` is 0 —
so `processTSV`'s per-row loop (`while done_count < #header`) never ran, `new_row[1]`
stayed nil, and `tsv/tsv_model.lua:884` crashed in 401 tests (this is the very
"unknown tsv_model issue" the old version of this doc left uninvestigated).

**Fix:** [Docker/Dockerfile.luajit](../Docker/Dockerfile.luajit) rebuilds LuaJIT from
source (git master, i.e. the current rolling release) with
`XCFLAGS=-DLUAJIT_ENABLE_LUA52COMPAT`, installs it over the stock one (same ABI and
soname, so C rocks are unaffected), and asserts `#setmetatable({}, {__len=…})`
works — the build fails loudly if the flag ever stops taking. This makes the compat
build a hard requirement for running TabuLua on LuaJIT; there is no code-level
workaround short of redesigning the read-only layer around explicit `len()` calls.

### 4. `tostring()` rounds big integral numbers — silent data corruption

On LuaJIT every number is a double and `tostring` formats with `%.14g`:
`tostring(9007199254740991)` → `"9.007199254741e+15"` — scientific notation **and
rounded**. Everywhere a large integer was rendered through `tostring`, the value was
corrupted in writing (and often failed range-validation when read back — that's how
it surfaced): parser `reformatted` strings, parser NAMES
(`_I9.007199254741e+15` isn't even a valid identifier), the `{"int":"…"}` typed-JSON
wrapper, the `<integer>` XML tag, SQL export, Lua-literal serialization, and the
JSON→TSV transcode path. Doubles hold integers **exactly** through ±2^53, so this
was pure formatting loss, not a representation limit.

**Fix:** `string_utils.formatInteger(num)` — `tostring` unless that yields an
exponent, then `"%.0f"` (exact for the whole integral-double range). Used by
`parsers/builtin.lua` (integer + long reformat), `util/number_identifiers.lua`
(parser-name encoding), `serde/serialization.lua` (`numberToText` helper: Lua
literal, typed-JSON int wrapper, XML integer tag, SQL numbers), and
`content/json_transcoders.lua` (`scalarToCell`: values entering the wide TSV). On
Lua 5.3+ each of these is byte-identical to before (native-integer `tostring` never
goes scientific), so this fixed LuaJIT without changing any other version's output.

## Genuine, documented differences that remain (by design)

These are semantic limits of an all-doubles runtime, not bugs; the affected specs
assert the LuaJIT-specific behaviour (or skip) behind explicit probes:

- **No 64-bit integers.** `long` is restricted to ±2^53 on LuaJIT and *rejects*
  (never silently rounds) values outside it — an int64 like `9223372036854775807`
  in a `{"int":"…"}` wrapper is a load error there, exact on Lua 5.3+.
- **The ±2^53 boundary itself is soft on input:** `tonumber("9007199254740993")`
  rounds to 2^53 *before any TabuLua code runs*, so the out-of-range rejection the
  integer parser performs on 5.3+ cannot happen — the rounded value is accepted.
- **Integer/float indistinguishability.** `1e6` *is* `1000000` on LuaJIT;
  `math.type` (compat53's) calls every whole double `"integer"`. So e.g.
  `numberToIdentifier(1e6)` is `_I1000000` there and `_F1000000_` on 5.3+. Specs
  probe with `math.type(1.0) == "float"` (compat53 makes plain `math.type ~= nil`
  checks WRONG — one such stale gate in `parsers_simple_spec` was fixed).
- **No sandbox instruction quotas** (root cause 2): hostile/looping user
  expressions are not aborted on LuaJIT.
- **Subnormal doubles don't format:** LuaJIT's `string.format("%.17f", 2^-1074)`
  produces garbage digits, so subnormal round-trip behaviour is undefined there
  (probed and skipped in `number_identifiers_spec`).
- **Natural JSON** numbers still go through dkjson/`tostring` semantics; the typed
  (`:typed`) formats are the exact path, same as on other versions.

## What became of the old plan in this document

The original proposal here was a full `numbers.lua` abstraction module plus
column-type propagation through serialization. That never became necessary:

- The **Safe Integer Migration** (landed `b29230a`, 2026-02-01; plan deleted per the
  then-current convention — `git show b271f0e:TODO/safe_integer_migration.md`) already
  redefined `integer` as ±2^53 with platform-independent parser names, and made
  `long` platform-dependent by declaration.
- Of the module's proposed surface, the only piece reality demanded was **one
  function** — `formatInteger` (root cause 4) — plus the `HAS_NATIVE_INTEGERS`
  probe pattern in specs. Column-type-aware serialization was never needed because
  the parsers' `reformatted` strings already carry the column's formatting decision.
- "Approach B: FFI int64_t" remains rejected — `long` on LuaJIT rejects out-of-range
  values instead. The original write-up is preserved below, in case true 64-bit
  support on LuaJIT ever becomes worth its costs.

### Preserved: Approach B — FFI int64_t (for true 64-bit integers)

*(Kept verbatim from the original version of this document. Rejected, not
implemented; the escalation path if `long`'s reject-on-LuaJIT behaviour ever stops
being acceptable — e.g. database IDs or timestamps that must round-trip exactly on
LuaJIT. It would be a separate optional module, never the default.)*

Use LuaJIT's FFI with `int64_t`/`uint64_t` cdata types for values that need full
64-bit precision.

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

## References

- [lua-compat-5.3 on GitHub](https://github.com/lunarmodules/lua-compat-5.3)
- [LuaJIT extensions — LUA52COMPAT](https://luajit.org/extensions.html) (what the
  build flag enables: `__len` on tables, `__pairs`/`__ipairs`, `goto`, …)
- [kikito/lua-sandbox](https://github.com/kikito/lua-sandbox) (`quota_supported`)
- [Docker/Dockerfile.luajit](../Docker/Dockerfile.luajit)
- [IEEE 754 Double Precision](https://en.wikipedia.org/wiki/Double-precision_floating-point_format) — the ±2^53 exact-integer range
