# Lua 5.5 Compatibility Issues

## Status

**Lua 5.5 now passes at full parity with Lua 5.4 (2026-07-12, since committed). ltcn was
hiding three further bugs; all four are fixed and verified.**

### What was actually wrong (ltcn was only the first layer)

| # | Problem | Fix | Where |
| --- | --- | --- | --- |
| 1 | **ltcn**: Lua 5.5 makes a `for...in` control variable `<const>`; `tokenset_to_list` reassigns it. Assigning to a const is a *compile-time* error, so `require("ltcn")` itself fails — the rock is entirely unloadable on 5.5, not merely broken on its error path. 22 tests dead. | Patch the installed rock in the 5.5 image (see below). | [Docker/ltcn-lua55.patch](../Docker/ltcn-lua55.patch), [Docker/Dockerfile.lua55](../Docker/Dockerfile.lua55) |
| 2 | **semver**: the rock defines `__lt` but **not** `__le`. Lua ≤5.4 emulated `a <= b` as `not (b < a)` (`LUA_COMPAT_LT_LE`); 5.5 removed that emulation, so `>=`/`<=` on a version object raised *"attempt to compare two table values"* — 11 errors, incl. all of `package_preprocessor_spec`. | Express both comparisons through `<` alone. Equivalent for a total order, works on every Lua. | [loader/manifest_info.lua:200-204](../loader/manifest_info.lua#L200-L204) |
| 3 | **`#` over a table with a hole** (ours, not upstream): `rawTSVToString` explicitly supports a nil cell, but read the row width with `#line`. That is a *border* — undefined for a holed table. 5.4 answered 3 for `{nil,false,3.14}`, 5.5 answers 0, and the row **serialized as empty**. A latent data-corruption bug that 5.5 merely exposed. | Take the largest integer key instead of `#`. | [tsv/raw_tsv.lua:68](../tsv/raw_tsv.lua#L68) |
| 4 | **libdeflate required by the wrong name** (ours; **nothing to do with 5.5**): the rock installs `LibDeflate.lua`, the code did `require("libdeflate")`. Windows' case-insensitive FS resolves it; **Linux/macOS do not** — so gzip *and* zip support reported *"libdeflate rock is not installed"* on every case-sensitive host **even when installed**, and silently degraded. This is a real user-facing bug on the two platforms we don't develop on. | Shared `compression.requireLibDeflate()` tries `LibDeflate` first, lowercase as fallback; zip provider reuses it; 4 specs corrected. | [content/compression.lua](../content/compression.lua#L175-L189), [content/archive_formats.lua:411](../content/archive_formats.lua#L411) |

Plus a packaging wrinkle: `luarocks install libdeflate` **fails on 5.5** ("No results matching
query were found for Lua 5.5") because its rockspec declares `lua >= 5.1, < 5.5`. The code is
pure Lua and runs fine on 5.5 (deflate round-trip verified), so `Dockerfile.lua55` builds it
from the rockspec with that stale bound relaxed. Upstream fix would be a 5.5-capable rockspec
from <https://luarocks.org/modules/safeteewow/libdeflate>. The other three Dockerfiles just
gained a plain `luarocks install libdeflate` — it was **never installed in any image**, which
is why the container baselines had ~48 pre-existing failures on *both* 5.4 and 5.5.

### Where this stands

- ✅ **Green everywhere, identical counts — 3187 successes / 0 failures / 0 errors in all
  four environments**: host (Lua 5.4), and the Lua 5.3 / 5.4 / 5.5 containers. Full parity.
  5.5 previously failed 22 tests (ltcn), then a further 13 once ltcn stopped masking them
  (11 semver, 1 knock-on, 1 the `raw_tsv` hole). The 5.3 and 5.4 containers were themselves
  carrying ~48 failures before this work (no `libdeflate` in any image); they are clean now.
- ✅ **The last 7 container-only failures are fixed too** — they were an image artifact, not a
  bug: `migration_spec`'s CLI tests shelled out to a `lua54` binary (`sh: lua54: not found`)
  that exists on the Windows host but not in the images. The spec now probes
  `lua54` → `lua5.4` → `lua`, the same candidates as `bad_input/run_bad_input_tests.sh`.
- ✅ **`spec/table_parsing_spec.lua` on 5.5: 17/17** (was 100% red).

  Re-run either container with:

  ```bash
  MSYS_NO_PATHCONV=1 wsl docker build -t lua55-test -f /mnt/c/Code/TabuLua/Docker/Dockerfile.lua55 /mnt/c/Code/TabuLua
  MSYS_NO_PATHCONV=1 wsl docker run --rm -v /mnt/c/Code/TabuLua:/app lua55-test \
      busted --lpath=?.lua --lpath=?/init.lua -p spec
  ```

- ✅ `documentation/CHANGELOG.md` — entry written under `[Unreleased]` (Changed: 5.5 parity,
  Docker images, interpreter probe; Fixed: libdeflate case-sensitivity, the holed-row
  serialization, the semver comparison).
- ✅ Committed.
- ✅ Optional: file the ltcn issue upstream (nobody has, in 20 months) and a 5.5 rockspec
  request for libdeflate. Neither blocks us. The ltcn issue is **written and ready to paste**:
  [TODO/ltcn_upstream_issue.md](ltcn_upstream_issue.md) — it reproduces the failure with ltcn's
  *own* `make check` and shows the patch passing on Lua 5.1–5.5.

### The ltcn route we took

**Upstream is dormant, so we patch the rock ourselves.**
[Docker/ltcn-lua55.patch](../Docker/ltcn-lua55.patch) carries the three-line fix (Option 1's
code, below), and [Docker/Dockerfile.lua55](../Docker/Dockerfile.lua55) applies it to the
installed rock right after `luarocks install ltcn`, then asserts it took. This was **Option 3
without vendoring**: the rock stays a normal LuaRocks dependency, and only the Lua 5.5 test
image is fixed up.

Consequence to keep in mind: **a user who installs TabuLua on Lua 5.5 via LuaRocks still gets
the broken ltcn.** The patch makes *our* 5.5 test run honest, not the ecosystem. Vendoring a
patched `ltcn.lua` into the repo (ISC — redistribution of modified copies is explicitly
permitted) is the escalation if 5.5 becomes a supported target for users rather than a
compatibility check for us.

The patch is behaviour-preserving, verified on Lua 5.4: for the same token set, the original
and patched `tokenset_to_list` return an identical sorted list, `'` quoting included.

## Upstream Issue Status

**Re-checked 2026-07-12 — nothing has changed since this was written, and still nobody has
filed anything.** Directly against <https://gitlab.com/craigbarnes/ltcn> (the canonical repo;
the GitHub mirror is a "moved" stub):

- **The bug is still on `master`** — `tokenset_to_list` still reassigns its loop variable.
- **Last commit: `abde2ef8`, 2024-11-04** ("Tweak error reporting for invalid escape
  sequences in strings"). `last_activity_at` on the project is the same date, so there has
  been *no* activity since — including none in the 5+ months since this doc was written.
- **Zero issues and zero merge requests**, open or closed (the API returns empty arrays for
  both, so the tracker is enabled and simply empty).
- **No new release** — LuaRocks still lists only `scm-1` (dev), last revised ~9 years ago.
- **No fork carrying a fix** (1 fork, 1 star: an unmaintained personal project).
- CI only tests Lua 5.1, 5.2, 5.3, and 5.4; the ltcn test suite fails on Lua 5.5 with the
  same error.

So "wait for upstream" is not a plan — hence the Status above. Filing the issue upstream is
still worth doing (it costs nothing and nobody has), but it must not gate us.

This is not an ltcn quirk but a common Lua 5.5 casualty: [cosmo](https://github.com/mascarenhas/cosmo/issues/15),
[luaexpat](https://github.com/lunarmodules/luaexpat/issues/42) and
[local-lua-debugger-vscode](https://github.com/tomblind/local-lua-debugger-vscode/issues/86)
all broke the same way and all fixed it by copying the loop variable into a fresh local. There
is [no `LUA_COMPAT_*` escape hatch](https://groups.google.com/g/lua-l/c/SlAG5QfpTac) for it —
the const-ness is deliberate (it lets the VM skip the implicit `local x = x` per loop).

## Summary

The project currently fails 22 tests on Lua 5.5.0 due to an incompatibility in the `ltcn` library (Lua Table Constructor Notation parser).

**Test results as first recorded (January 2026 — the suite has since grown to 3187 tests, so
these counts are historical; see Status for current numbers):**

- Lua 5.3: 1605 successes ✓
- Lua 5.4: 1605 successes ✓
- Lua 5.5: 984 successes, 22 errors ✗ (before the ltcn patch)

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

## The Fix

The fix — in all of the options below — is to copy the loop variable into a fresh local
before rewriting it, so nothing assigns to the `<const>` control variable:

```lua
for s in pairs(set) do
    i = i + 1
    local token = s
    if token:match("^%p$") then
        -- Quote punctuation characters
        token = (token == "'") and '"\'"' or ("'" .. token .. "'")
    end
    list[i] = token
end
```

This is [Docker/ltcn-lua55.patch](../Docker/ltcn-lua55.patch) verbatim, and it is valid on
Lua 5.1–5.5, so it is also exactly what an upstream MR would carry.

### Option 1: Wait for upstream fix — ✗ rejected

Upstream is dormant (see Upstream Issue Status: no commit since 2024-11-04, empty tracker,
1 star, 1 fork). Waiting on it indefinitely blocks our own gate for nothing.

### Option 2: Fork and patch locally — not needed

A fork buys nothing over the in-place patch: we would still have to point the Dockerfile at
it, and we would then own a fork.

### Option 3 (variant): Patch the installed rock — ✅ **CHOSEN, applied**

`luarocks install ltcn` as before, then `patch` the installed `ltcn.lua` inside
[Docker/Dockerfile.lua55](../Docker/Dockerfile.lua55) and assert the patch took (a `pcall` of
a deliberately-malformed parse must not fail with a `const` error). The patch applies to the
file the dev-server rock ships (ltcn master `abde2ef8`), and the build fails loudly if it ever
stops applying — which is the signal that upstream finally moved.

### Option 3 (full): Vendor a patched copy — the escalation, not done

Copy `ltcn.lua` into the project (ISC: modification and redistribution explicitly permitted;
keep the copyright notice), let `./?.lua` shadow the rock, drop `luarocks install ltcn` from
the README. This is the only option that also fixes **users** who install TabuLua on Lua 5.5.
Deferred because it would be the project's first vendored dependency, and 5.5 is currently a
compatibility check for us rather than a supported user target.

## Additional Notes

- Lua 5.5 was released on December 22, 2025, so library ecosystem support is still catching up
- The `compat53` library works fine on Lua 5.5 (it's a no-op since 5.5 already has all 5.3 features)
- No changes are needed to this project's own code for Lua 5.5 compatibility

## References

- [Lua 5.5 Release Notes](https://www.lua.org/manual/5.5/readme.html)
- [ltcn on LuaRocks](https://luarocks.org/modules/craigb/ltcn)
- [ltcn GitLab Repository](https://gitlab.com/craigbarnes/ltcn) (ISC licensed)
- [Docker/ltcn-lua55.patch](../Docker/ltcn-lua55.patch) — our fix, ready to file upstream
- [lua-l: rationale for const for-loop variables in 5.5](https://groups.google.com/g/lua-l/c/SlAG5QfpTac)
