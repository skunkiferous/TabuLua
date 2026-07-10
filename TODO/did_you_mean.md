# Did-You-Mean Audit: Suggestions for Identifier-Not-Found Diagnostics

**Status: 🚧 In progress — surveyed 2026-07-10. Phase 1 committed (helper +
all high-value data-error sites). Phase 2 landed (CLI + tooling + data_set /
archive sites), pending user commit. Phase 3 not started.**

## Summary

`string_utils` now has two general-purpose functions (added with the
mod_ecosystem Phase 7 follow-up):

- **`editDistance(a, b)`** — Damerau-Levenshtein (optimal string alignment):
  insertions, deletions, substitutions, and *adjacent transpositions* each
  cost 1. Byte-based, case-sensitive.
- **`closestMatch(value, candidates, opt_maxDistance)`** — nearest candidate
  under a length-scaled distance limit (default `min(3, floor(#value/4)+1)`);
  first of equally-close candidates wins, so callers pass **sorted**
  candidates for deterministic output.

Their first consumer is `manifest_info.unknownGateIds` (the `onlyIfPackages`
typo check in `--check-conflicts`), which uses the case-insensitive recipe:
lowercase the value and a sorted lowercased candidate list, then map the
winner back to its original casing.

The same "you wrote X, did you mean Y?" upgrade applies to **dozens of other
diagnostics**: everywhere we error/fail/warn because an identifier was not
found in a known, enumerable set (a column name, package id, file name,
type name, PK, CLI option...). A typo today produces a bare "not found";
with one extra line at the error site it can name the probable fix. This
TODO is the audit of those sites.

## When a site qualifies

A diagnostic is a candidate if **all** of these hold:

1. The failed lookup is of a **user-typed identifier** (from a TSV cell, a
   manifest field, a Files.tsv column, a CLI argument) — not a computed value
   or an internal invariant.
2. The **candidate set is enumerable at the error site** (a header's column
   names, the loaded package ids, a file's PK index, the registered option
   names) and reasonably bounded.
3. The message does **not already print the full candidate list**. (The enum
   parser at [generators.lua:586-595](../parsers/generators.lua#L586-L595)
   already appends `valid values: a, b, c` — a did-you-mean adds little
   there unless the list is long.)

It is **not** a candidate when:

- The failure is an internal `assert`/invariant (nobody typed the name).
- The "identifier" is arbitrary data (a cell *value* of type `string`).
- The candidate set is unavailable where the error is raised (would require
  threading new parameters through several layers — weigh per site).
- A fuzzy suggestion could be **misleading**: e.g. `ifMissing`-tolerated
  patch misses are *expected* version drift, not typos — only the
  `error`-policy path should suggest.

## Design

### One shared formatting helper

Add to [error_reporting.lua](../infra/error_reporting.lua) (it may depend on
`string_utils`; both are leaf-ish infra):

```lua
-- Returns " (did you mean 'X'?)" for the closest candidate, or "".
-- Case-insensitive: candidates are matched lowercased but reported in
-- their original casing. Sorts a COPY of candidates for determinism.
-- opt_maxDistance forwards to string_utils.closestMatch.
function didYouMean(value, candidates, opt_maxDistance)
```

Accepting either a sequence or a set (`{[name]=...}`) for `candidates` would
fit the call sites best — most have a set/map at hand. Every adopted site
then becomes `msg .. didYouMean(bad, known)`.

### Guardrails

- **Error path only.** `closestMatch` is O(#candidates × |value|²) — trivial
  for a one-off diagnostic, but never compute suggestions on the happy path,
  and beware sites that fire **per cell** (e.g. unknown type specs — the
  existing `state.UNKNOWN_TYPES` once-only cache already bounds that one).
- **Determinism** (per package_order_determinism): sort candidates before
  matching; the helper should own this so no call site forgets.
- **bad_input pins**: `run_bad_input_tests` matches expected message
  patterns; appending a suffix is additive, but any test pinning the *end*
  of a message needs updating. Check `bad_input/*/expected*` when adopting.
- Suffix only, never replace: keep the existing message text (specs and
  users grep for it) and append the suggestion.

## Surveyed sites

### High value — user-facing data errors (Phase 1)

| Site | Message today | Candidate set |
| --- | --- | --- |
| [patch_executor.lua:1126](../overrides/patch_executor.lua#L1126) & [manifest_loader.lua:727](../loader/manifest_loader.lua#L727) | patch/overlay target `not found (must match a loaded file by basename...)` | loaded file basenames (fn2pkg / lcFn2File keys) |
| [patch_executor.lua:1119](../overrides/patch_executor.lua#L1119) & [manifest_loader.lua:724](../loader/manifest_loader.lua#L724) | qualified target: package `is not loaded or owns no such file` | loaded package ids; that package's basenames |
| [patch_executor.lua:648](../overrides/patch_executor.lua#L648), [:672](../overrides/patch_executor.lua#L672) | `update`/patch-op key `not found in target` | target file's PK index keys (**only under `ifMissing=error`** — warn/silent are expected drift, see above) |
| [manifest_info.lua:542](../loader/manifest_info.lua#L542) | `Missing dependency: X for package Y` | loaded package ids |
| [manifest_info.lua:472](../loader/manifest_info.lua#L472), [:478](../loader/manifest_info.lua#L478) | bootstrap library `not loaded` / fn `not exported by library` | the package's `code_libraries` names; the library's export keys |
| [manifest_info.lua:302](../loader/manifest_info.lua#L302) | `Unknown column 'X' in manifest file` (warn) | MANIFEST_SPEC field names |
| [processor_executor.lua:237](../wiring/processor_executor.lua#L237) | `setCell: column 'X' does not exist in header` | header column names |
| [generators.lua:480](../parsers/generators.lua#L480) | record parser `Unknown field: k` | the record's field names |
| [type_parsing.lua:913](../parsers/type_parsing.lua#L913) | header type `unknown/bad type` | registered **named** parsers + aliases — must filter generated keys (`integer._R_GE_...`, `{...}` composites); fires once per spec thanks to `UNKNOWN_TYPES` |
| [type_parsing.lua:89](../parsers/type_parsing.lua#L89), [registration.lua:777](../parsers/registration.lua#L777) | ancestor type `does not exist` / `is not registered` | same filtered parser-name set |
| [type_parsing.lua:732](../parsers/type_parsing.lua#L732) | record self-ref field `does not exist` | the record's own field names |
| [graph_helpers.lua:432](../wiring/graph_helpers.lua#L432) | `row 'X' ... references unknown node 'Y'` | the node file's PK names (already indexed; may be large — fine on error path) |
| [builtin_wiring.lua:485](../wiring/builtin_wiring.lua#L485) | `joinInto` target `does not exist (must match an entry in fileName)` | the Files.tsv `fileName` entries |
| [file_joining.lua:40](../tsv/file_joining.lua#L40), [:171](../tsv/file_joining.lua#L171) | `Join column 'X' not found` | header column names |
| [exporter.lua:402](../serde/exporter.lua#L402) | `Secondary file not found` (warn) | loaded file names |

### Medium value — CLI + tooling (Phase 2)

| Site | Message today | Candidate set |
| --- | --- | --- |
| [reformatter.lua:1088](../reformatter.lua#L1088) | `Unknown option: --x` | the option names. **No central table exists** — the parser is an if/elseif chain, so adopting means writing the (small) list once; keep it next to the usage text so they can't drift |
| [reformatter.lua:1012](../reformatter.lua#L1012), [:1026](../reformatter.lua#L1026), [:1063](../reformatter.lua#L1063) | `Unknown file format` / `data format` / `log level` | the respective known-value lists |
| [migration.lua:448](../migration.lua#L448), [:453](../migration.lua#L453); [tsv_diff.lua:1101](../tsv_diff.lua#L1101), [:1106](../tsv_diff.lua#L1106); [export_tester.lua:471](../export_tester.lua#L471), [:527](../export_tester.lua#L527), [:533](../export_tester.lua#L533); extract_test_errors; ollama_batch | same option/level/format pattern per tool | per-tool lists |
| [migration.lua:172-323](../migration.lua#L172-L323), [data_set.lua:219-691](../tsv/data_set.lua#L219-L691) | `file not loaded` / `column not found` / `row not found` (returned as `nil, err` strings) | loaded file names; header columns; PK keys. These return errors rather than logging — the suffix goes into the returned string |
| [file_util.lua:470](../infra/file_util.lua#L470), [:547](../infra/file_util.lua#L547), [archive_formats.lua:340](../content/archive_formats.lua#L340) | `member not found in archive` | the archive's member list (central directory is already parsed and cached) |
| [manifest_loader.lua:650-654](../loader/manifest_loader.lua#L650-L654) | Files.tsv entry `does not exist on disk` | actual files in the package directory (needs a directory listing — only worth it if one is already at hand or cheap) |

### Investigate first

- **Variant-name typos.** `validateVariantGroups`
  ([manifest_info.lua:749-833](../loader/manifest_info.lua#L749-L833))
  reports an unsatisfied group (and lists its allowed values), but a
  *provided* variant matching nothing is silently ignored — the same
  hazard class as `onlyIfPackages` gate ids. Before flagging unknown
  provided variants, check whether variants legitimately exist outside
  declared groups (file-variant selection machinery); if they can, the
  "known" set must include those uses, mirroring how `unknownGateIds`
  counts manifest mentions as known.
- **Enum values** ([generators.lua:595](../parsers/generators.lua#L595)):
  message already ends with the full `valid values:` list. Only worth a
  did-you-mean if the list is truncated for large enums someday.

### Low value — deliberate non-goals for now

- The `Unknown operation:` in every module's `apiCall` (~30 copies of the
  same idiom) — dev-facing, and the fix is a per-module copy-paste. If the
  idiom is ever centralised, add `didYouMean(op, API-keys)` there once.
- XML deserialization `Unknown tag` ([deserialization.lua:308](../serde/deserialization.lua#L308),
  [:438](../serde/deserialization.lua#L438)) — tiny fixed tag set, and the
  input is usually machine-generated.
- `sandbox`/expression `undefined_reference` errors — raised inside the
  sandboxed Lua runtime, not by our lookup code; no candidate set at the
  raise site.

## Re-audit recipe

The survey greps (rerun after major features land):

```
Grep pattern='Unknown |not found|not loaded|not registered|not exported|does not exist|no such' glob='*.lua'
Grep pattern='Missing |not defined|not declared|is not a valid' glob='*.lua'
```

Rank hits by whether a candidate set is in scope at the site; ignore
`spec/`, `Unknown operation` apiCall boilerplate, and value-shaped (not
identifier-shaped) failures.

## Phases

1. **Phase 1 — helper + data errors.** `error_reporting.didYouMean` (+ spec)
   and adoption at the high-value table's sites. Update any bad_input
   expected patterns that pin message endings. CHANGELOG + MODULES.md
   (error_reporting entry).
2. **Phase 2 — CLI + tooling.** The per-tool option/format/level lists and
   the `nil, err`-returning data_set/migration sites. The reformatter needs
   its options captured in one table first.
3. **Phase 3 — investigations.** Variant-name typo check (after resolving
   the "variants outside groups" question); anything new the re-audit
   recipe turns up.

Each phase per the standing workflow: code + spec + CHANGELOG + MODULES.md,
verified with `.\pre_commit_check.cmd`, user commit between phases.

## Progress

- **Phase 1 — DONE (pending user commit).** Added
  `error_reporting.didYouMean(value, candidates, opt_maxDistance)` (+ spec, 8
  cases) and adopted every high-value site:
  - patch/overlay target resolution: `patch_executor.newTargetResolver` now
    returns `info.base` + `info.candidates` (all basenames for `not_found`, the
    package's basenames for `not_in_package`); `patch_executor` (target +
    `patchOp=update` key under the `error` policy only) and `manifest_loader`
    (overlay target) append the suffix from that.
  - `manifest_info`: missing dependency, bootstrap library / exported fn,
    unknown manifest column.
  - `processor_executor` setCell column; `generators` record unknown field;
    `type_parsing` record self-ref field; unknown/ancestor type names in
    `type_parsing` + `registration` via new **`parsers.utils.namedTypeCandidates`**
    (+ `unknownTypeSuffix`) which filters generated registry keys
    (`integer._R_GE_0`, composites, unions).
  - `graph_helpers` unknown node; `builtin_wiring` `edgesFor` target;
    `file_joining` join columns (×2); `exporter` secondary-file lookup.
  - New `bad_input` fixture `type_errors/unknown_type_suggestion` pins the
    end-to-end suggestion. `pre_commit_check.cmd` green (all unit + export +
    bad_input). CHANGELOG + MODULES.md updated (error_reporting gains
    `string_utils`; patch_executor / graph_helpers / file_joining gain
    error_reporting).
  - **Gotcha:** `didYouMean` distinguishes sequence vs. name-keyed set by
    `candidates[1] ~= nil`, so never pass a header table keyed by BOTH index and
    name — extract the string keys first (done in `processor_executor`).

- **Phase 2 — DONE (pending user commit).** CLI + tooling + data-mutation
  errors:
  - Every CLI tool suggests the closest option / format / log level on a typo:
    `reformatter` (unknown `--option` — now backed by a single `KNOWN_OPTIONS`
    table beside the usage text — plus `--file=`/`--data=` format and
    `--log-level=`), `migration`, `tsv_diff`, `export_tester`,
    `extract_test_errors`, `ollama_batch` (each with its own hand-kept option
    list next to its arg parser).
  - `data_set`: suggestions centralised in the `assertFileLoaded` /
    `assertColumnExists` guards (used ~50×) + row-not-found paths (new
    `dataRowKeys` helper) → loaded file names / header columns / PK keys. Every
    delegating `migration` command benefits; `migration`'s own file/column
    checks (`addColumn`/`moveColumn`/`copyColumn`/`assert`/`assertColumn`) also
    suggest. These return `nil, err`, so the suffix goes into the string.
  - `file_util` / `archive_formats` member-not-found → closest archive member
    (central directory already parsed); `manifest_loader` "does not exist on
    disk" → closest actual on-disk path (`filesOnDisk` already built).
  - New `bad_input/cli_errors/unknown_option_suggestion` fixture pins the CLI
    suggestion end-to-end. Docs updated (error_reporting added as a dependency
    to data_set, file_util, archive_formats, migration, tsv_diff, ollama_batch,
    extract_test_errors).
  - **Gotcha:** `pre_commit_check.cmd`'s unit-test step runs `run_tests.cmd`
    with RELATIVE paths (no pushd) — run it from the project root or it
    falsely reports unit-test failure (the PowerShell cwd can drift after a
    Bash `cd`).
