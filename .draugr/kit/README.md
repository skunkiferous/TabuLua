# TabuLua sbx kit

What `spec.yaml` next to this file sets up, and why. The stock sandbox image has **no Lua
at all** — no `lua`, no `luarocks`, no `busted` — so without this kit nothing in the test
suite can run.

The install steps — `capabilities[lifecycle@1].config.install` since the v3 migration, and
`commands.install` before it — are `Docker/Dockerfile.lua54` translated from Alpine to the
sandbox image, plus the rocks the suite uses that the Dockerfile never needed.

```bash
sbx run claude --kit .draugr/kit      # or: dr-up
```

Then, inside:

```bash
./run_tests.sh          # busted suite
./pre_commit_check.sh   # suite + tutorial export checks + bad-input tests
```

## What it installs

| Source | Contents |
|---|---|
| apt | `lua5.4`, `liblua5.4-dev`, `luarocks`, `build-essential`, `libreadline-dev`, `libsqlite3-dev`, `unzip`, `git`, `curl` |
| LuaRocks | `lpeg`, `luafilesystem`, `lualogging`, `dkjson`, `lua-messagepack`, `tableshape`, `semver`, `libdeflate`, `luasocket`, `lsqlite3`, `busted`, `luassert`, `luacov` |
| Upstream repos | `lua-sandbox` (GitHub rockspec), `ltcn` (gitlab.com/craigbarnes/ltcn) |

Beyond what `Docker/Dockerfile.lua54` lists:

- **luafilesystem** (`lfs`) — used by `loader/` and `infra/file_util.lua`
- **dkjson** — the JSON transcoders
- **luasocket** (`socket`, `ltn12`) — `ollama_batch.lua`
- **luacov** — `run_tests.sh` passes `--coverage`; busted aborts without it
- **luassert** — arrives with busted; listed so a busted change can't silently drop it
- **lsqlite3** (+ `libsqlite3-dev`) — see below

## Three traps this kit exists to work around

Each fails *quietly*, which is why they are worth writing down.

### 1. `luarocks` targets Lua 5.1, not 5.4

The distribution's `luarocks` package depends on liblua5.1, and `/usr/bin/luarocks` is a
`#!/usr/bin/env lua-any` script whose `-- Lua-Versions: 5.1 5.3 5.4` comment makes
`lua-any` pick the **first** installed interpreter — 5.1.

So a plain `luarocks install lpeg` compiles against `/usr/include/lua5.1` and installs into
`/usr/local/{share,lib}/lua/5.1/`, where `lua5.4` never looks. **The install reports
success**; only the later `require()` fails. Step 2 reorders that version list — the
mechanism Debian's `lua-any` is built around — so `luarocks` means 5.4 while `luarocks-5.1`
still works for anyone who wants it.

### 2. `lua` is Lua 5.1

`/usr/bin/lua` is an alternatives symlink that also resolves to 5.1. `pre_commit_check.sh`
probes `lua54` → `lua5.4` → `lua` and lands on `lua5.4`, but `run_tests.sh` calls bare
`lua extract_test_errors.lua`, which would parse the TAP output under 5.1.

### 3. `luarocks.org` is not in the machine-wide default allow rules

sbx's default rules — 213 of them on sbx 0.53 — already cover the apt archive of the image,
`github.com`, `raw.githubusercontent.com` and `gitlab.com`, all verified reachable from
inside the sandbox, so the kit's `runtime.allow` only needs the one host they miss.

Re-checked on sbx 0.53, because a default list can grow: `luarocks.org` is in none of the
213 rules, and a probe kit carrying no network rule at all was answered `403` for it. The
trap is still real.

The failure is soft: luarocks warns `Failed downloading .../manifest-5.4` and falls back to
the moonrocks mirror on `raw.githubusercontent.com`. Stable rocks still install that way,
which is exactly why this is easy to miss — but the mirror doesn't carry everything, and
every `luarocks` call pays for a doomed manifest fetch first.

`ltcn` is the casualty: it is registry-hosted **only** on the dev server
(`luarocks.org/dev`, as `scm-1`), which the mirror does not carry, so the Dockerfiles'
`luarocks install --server=https://luarocks.org/dev ltcn` fails with *"No results matching
query were found for Lua 5.4"*. Step 4 installs the identical rockspec from
`gitlab.com/craigbarnes/ltcn` — the repo that rockspec's `source.url` points at anyway —
so ltcn resolves the same way even if the allow rule is later dropped.

## Why `lsqlite3` is in here

`serde/importer.lua`'s `importSQLFileWithSQLite` path only executes when the rock is
present; without it the code falls back to the text SQL parser and logs *"SQLite3 not
available"*. `spec/exporter_spec.lua:24` selects `it` vs `pending` on
`pcall(require, "lsqlite3")`, so two tests would report as passing without ever running:

```
ok 555 - exporter exportSQL should emit SQL a real engine can execute
ok 916 - importer parseSQLContent should CAST int64 columns to TEXT in the SQLite query
```

Both run for real with this kit.

## The sandbox image is Debian, not Ubuntu

Measured from inside a sandbox built with this kit:

```
PRETTY_NAME="Docker Hardened Images/Debian GNU/Linux 13 (trixie)"
URIs: http://deb.debian.org/debian
URIs: http://deb.debian.org/debian-security
URIs: http://dhi.io/deb/debian/main
```

So the step names and comments no longer say "Ubuntu", and the `update-alternatives` and
`lua-any` mechanisms step 2 relies on are Debian's own — which is where Ubuntu inherited
them from, so the steps needed no change at all. Every package step 1 installs exists in
trixie, and step 5 — the `require()` assertion over all sixteen modules — passes.

**`apt-get update` in step 1 works here for a reason that is not obvious.** Those sources
are plain `http://`, and the machine-wide sbx policy allows `**.debian.org:443` and not port
80. A sandbox built on the bare `shell` image therefore gets `403 Forbidden` from the proxy
and the create dies — which is exactly what happened to Draugr's forge gateway. It works in
this kit because the agent is claude, and the claude agent kit opens port 80 for its own
sandboxes, in the install phase included. A kit for an agent-less image has to rewrite its
apt sources to `https://` first, and must not simply delete the `dhi.io` source: the base
packages are DHI builds, and without that repository apt replaces the hardened base and
then fails.

## The two phases of a v3 network policy

v3 splits a `network-policy@1` into `install:` — the creation commands — and `runtime:`, the
agent's session. The first version of this migration listed `luarocks.org` in both, assuming
they were independent. Four one-command probe kits on sbx 0.53, each fetching
`https://luarocks.org/manifest-5.4` and recording the HTTP code, say otherwise:

| kit rule | install phase | agent session |
|---|---|---|
| none | 403 | — |
| `runtime:` allow | **200** | 200 |
| `install:` allow | 200 | **403** |
| `install:` allow + `runtime:` deny | 403 | — |

A `runtime:` allow covers **both** phases. An `install:` allow covers only the install. A
`runtime:` deny closes both, beating an explicit `install:` allow. So this kit needs the one
`runtime.allow` entry it had in v2 and nothing more, and a kit that wants a host *only*
while being built is the one case `install:` is for.

If a later sbx stops letting a runtime allow reach the install phase, the symptom here will
be quiet rather than loud: step 3 falls back to the moonrocks mirror, which carries the
stable rocks, so the create still succeeds and merely pays for a doomed manifest fetch each
time. The fix is to add `install: { allow: [luarocks.org] }` back to the capability.

## Verification

The install steps were extracted from `spec.yaml` and run against a clean `ubuntu:26.04`
container, then TabuLua was run inside the resulting image:

- `run_tests.sh` — **3409 passed, 0 failed** (1 skip: a LuaJIT-only test, correctly skipped on 5.4)
- `pre_commit_check.sh` — all 6 steps pass, including **38/38** bad-input tests

That build ran with `luarocks.org` **still blocked**, so the allow rule is an optimisation
rather than a hard dependency.

Install step 5 asserts every dependency is `require()`-able under Lua 5.4 and fails sandbox
creation otherwise — a rock that landed in the wrong Lua tree still exits 0, so the check is
on `require()`, not on exit codes.

Re-verified at create on sbx 0.53, after the v3 migration, on a throwaway sandbox with the
same agent and workspace as the real mound:

```
✓ Install Lua 5.4, LuaRocks, build toolchain and SQLite headers   34.1s
✓ Make `lua` and `luarocks` resolve to 5.4                        168ms
✓ Install TabuLua's LuaRocks dependencies for Lua 5.4             42.6s
✓ Install lua-sandbox and ltcn from their upstream repositories     3.2s
✓ Assert every dependency loads under Lua 5.4                      29ms
```

`lua -v` reported 5.4.7 and `luarocks config lua_version` 5.4, and `luarocks-5.4 show ltcn`
reported `scm-1` from gitlab.com, as step 4 intends.

## Version pinning

Rock versions are deliberately **unpinned**, matching `Docker/Dockerfile.lua54`. To pin,
give each entry in step 3 an explicit version:

```yaml
luarocks-5.4 install lpeg 1.1.0-2
```

`ltcn` is `scm-1` and tracks git master by design; pin it with `--branch <tag>` or a
`git checkout <sha>` after the clone in step 4. Upstream ltcn has moved since
`Docker/ltcn-lua55.patch` was written — that patch cites commit `abde2ef8` (2024-11-04),
master is now `4188c4c` (2026-07-14). That patch is a Lua **5.5** fix and is not applied
here; this kit is Lua 5.4, where the bug it fixes does not bite.

## Relationship to `Docker/`

`Docker/Dockerfile.lua5{3,4,5}` and `Dockerfile.luajit` remain the cross-version test matrix
on Alpine. This kit covers one environment — Lua 5.4 on the sandbox image — and does
not replace them. **A new dependency needs adding in both places.**
