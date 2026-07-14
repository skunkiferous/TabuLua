# ltcn fails to load on Lua 5.5: assignment to `<const>` for-in variable in `tokenset_to_list`

Ready-to-file issue text for <https://gitlab.com/craigbarnes/ltcn/-/issues> (the tracker is
empty and upstream has been dormant since 2024-11-04 — see [lua55_compatibility.md](lua55_compatibility.md)).
Everything below the line is the issue body; paste it as-is.

The reproduction and the verification table were produced by running ltcn's *own* test suite in
the Lua containers, e.g.:

```bash
wsl docker run --rm nickblah/lua:5.5-luarocks-alpine sh -c \
    "apk add --no-cache git build-base make >/dev/null && luarocks install lpeg >/dev/null && \
     git clone -q https://gitlab.com/craigbarnes/ltcn.git /ltcn && cd /ltcn && make check"
```

---

## Summary

On Lua 5.5, `require("ltcn")` fails outright — the module cannot be loaded at all.

Lua 5.5 makes the control variable of a generic `for ... in` loop read-only (implicitly
`<const>`), and `tokenset_to_list()` assigns to it. Assigning to a const is a **compile-time**
error, so this is not confined to the error-reporting path: the chunk never compiles, and
every use of ltcn on 5.5 fails at `require` time.

`make check-all` only covers Lua 5.1–5.4, which is presumably why CI hasn't caught it.

## Reproduction

ltcn `master` @ `abde2ef8995082d7a908f2c8d8ab17be1aa599a0` (2024-11-04), stock `make check`:

```
$ lua -v
Lua 5.5.0  Copyright (C) 1994-2025 Lua.org, PUC-Rio

$ lua -e 'print(pcall(require, "ltcn"))'
false	error loading module 'ltcn' from file './ltcn.lua':
	./ltcn.lua:61: attempt to assign to const variable 's'

$ make check
lua test/compare.lua test/t1.ltcn
lua: error loading module 'ltcn' from file './ltcn.lua':
	./ltcn.lua:61: attempt to assign to const variable 's'
stack traceback:
	[C]: in ?
	[C]: in global 'require'
	test/compare.lua:5: in main chunk
	[C]: in ?
make: *** [Makefile:6: check] Error 1
```

## Cause

`ltcn.lua`, `tokenset_to_list()` (lines ~55-67):

```lua
local function tokenset_to_list(set)
    local list, i = {}, 0
    for s in pairs(set) do
        i = i + 1
        if s:match("^%p$") then
            -- Quote punctuation characters
            s = (s == "'") and '"\'"' or ("'" .. s .. "'")   -- <-- ltcn.lua:61
        end
        list[i] = s
    end
    sort(list)
    return list
end
```

The const-ness of the loop variable is deliberate in 5.5 (it lets the VM skip an implicit
`local x = x` per iteration) and there is no `LUA_COMPAT_*` escape hatch for it, so the
assignment has to go. The same change has broken several other libraries in the same way —
[cosmo#15](https://github.com/mascarenhas/cosmo/issues/15),
[luaexpat#42](https://github.com/lunarmodules/luaexpat/issues/42),
[local-lua-debugger-vscode#86](https://github.com/tomblind/local-lua-debugger-vscode/issues/86)
— all fixed by copying the loop variable into a fresh local.

## Patch

Copies the control variable into a fresh local before rewriting it. Behaviour-preserving
(the same input set produces an identical sorted list, `'` quoting included) and valid on
Lua 5.1 through 5.5.

```diff
--- a/ltcn.lua
+++ b/ltcn.lua
@@ -56,11 +56,12 @@
     local list, i = {}, 0
     for s in pairs(set) do
         i = i + 1
-        if s:match("^%p$") then
+        local token = s
+        if token:match("^%p$") then
             -- Quote punctuation characters
-            s = (s == "'") and '"\'"' or ("'" .. s .. "'")
+            token = (token == "'") and '"\'"' or ("'" .. token .. "'")
         end
-        list[i] = s
+        list[i] = token
     end
     sort(list)
     return list
```

## Verification

`make check` — stock upstream tests, unmodified — on every Lua version ltcn supports:

| Lua | `make check` (unpatched) | `make check` (patched) |
| --- | --- | --- |
| 5.1.5 | PASS | PASS |
| 5.2.4 | PASS | PASS |
| 5.3.6 | PASS | PASS |
| 5.4.8 | PASS | PASS |
| 5.5.0 | **FAIL** (module does not load) | **PASS** |

Suggested follow-up: add `lua5.5` to the `check-all` target so this stays caught.

Happy to open this as a merge request instead, if that's easier.
