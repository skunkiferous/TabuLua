# Non-Table Files: Declaring Assets and Ignored Files Explicitly

## Status

**Done** (2026-07-12). All four phases landed: `asset_file` + the single `fileRole`
resolver, the manifest `asset_files` / `ignored_files` globs (new `util/glob.lua`),
role typeNames exempted from the table-type checks, and the tutorial's
`theme.json`. Specs: `spec/non_table_files_spec.lua`, `spec/glob_spec.lua`.

Where the plan below was ambiguous or wrong, what shipped:

- **Undeclared `.json`/`.xml`: warned and dropped**, per "Decisions taken" §2 —
  *not* the implicit-asset reading that Design §1's rules
  3–4 imply (those two sections contradicted each other). Declaring the file is the
  escape hatch, and the warning names all three routes. `fileRole` therefore keeps a
  "looks like data" extension guess, consulted *inside* the one function, for
  undeclared files only — the two GATES are unified, which was the actual bug.
- **`ignored` was not merely missing a glob form — it was broken.** An
  `IgnoredFile`-tagged file was being *exported*: the loader nil'd it from
  `raw_files`, and the asset pass (walking the caller's unfiltered file list) put it
  straight back. Ignored now means not loaded *and* not exported.
- **Role-tag membership must be by NAME.** `parsers.isMemberOfTag` also matches by
  SHAPE, and every record extends the empty record — so `asset_file` aliased to `{}`
  (the obvious mirror of `patch`) briefly made *every table in the package* an asset.
- **A declared asset is streamed verbatim**, not read as text: the text path
  EOL-normalises on read and the export writes text, so "byte-for-byte" was not
  actually achievable through it. Implicit `.md`/`.txt` assets keep the text path
  (COG templates and `--strip-cog` need a string), so the guarantee is precisely
  what *declaring* the file buys.

Answers to the Open questions below:

- **Glob syntax/matcher** — no reusable matcher existed (`content_pipeline`'s is
  basename-only and its `*` crosses `/`), so `util/glob.lua` is new: `*` within a
  segment, `**` across segments, `?` one char, and the gitignore rule that a glob
  with no `/` matches the basename at any depth. Package-relative, so globs are
  relocatable like a `Files.tsv`.
- **One copy per export format** — unchanged (still one per format subdirectory).
  Pre-existing, and out of scope for this thread.
- **Archive members** — unchanged: a zip streams verbatim as one asset, and its
  members are inputs only (the exporter already skips them), so an `asset_file`
  member needs no separate copy.

## Summary

TabuLua has no way to say **"this file is not a table."** Today a file's role is
inferred from its **extension**, and the inference is inconsistent: `.md` is always an
asset, `.tsv` is always a table, and `.json` / `.xml` are *sometimes* a table (only if
a `Files.tsv` row gives them a `transcoder` id) but are *always required to be
declared*. So an `.md` asset is copied to the export and a `.json` asset is dropped —
for no reason a user could explain.

The fix is to stop inferring and let a package **declare** the role, via two
complementary mechanisms:

- a **`Files.tsv` marker typeName** for per-file precision, and
- **manifest glob lists** for bulk cases (and for the temporary files that started
  this whole thread).

A declaration beats the extension **for every extension**, so this is not merely a
`.json`/`.xml` patch: a `.tsv` can be declared an asset too, and is then copied
byte-for-byte and *never reformatted in place* — something the pipeline cannot express
at all today.

## How we got here

The immediate trigger: reformatting a package **errored** on temporary `.tsv` files
that were not in `Files.tsv`. That was fixed (they now warn and are skipped — see the
`[Unreleased]` "An undeclared data file is now reported and skipped" entry), but the
fix classified data **by extension**, which put `.json` / `.xml` in the must-declare
set. Those extensions had *never* been parsed without a `transcoder`, so files that
used to be copied verbatim to the export are now dropped.

**This is a live regression in the current (uncommitted) working tree.** See
[Release gate](#release-gate) below.

## The two "is it data?" questions, and why they disagree

There are two gates, written independently, asking what should be one question:

| | parsed as a table? | must be declared? |
| --- | --- | --- |
| `.tsv` / `.csv` (incl. `.tsv.gz`) | yes, always | yes |
| `.eav` | yes (extension auto-transcodes) | yes |
| `.json` / `.xml` | **only with a `transcoder` id from `Files.tsv`** | **yes** ← contradiction |
| `.md` / `.txt` / `.lua` / `.zip` | no | no |

- **Parse gate** — [manifest_loader.lua:583](../loader/manifest_loader.lua#L583)
  (`loadOtherFiles`): a file is parsed iff it is `.tsv`/`.csv`, or a compressed
  `.tsv`/`.csv`, or `Files.tsv` assigned it a `transcoder`, or its extension
  auto-transcodes (`.eav`). **Everything else** goes to `processUnknownFile` →
  `raw_files` → copied verbatim to the export.
- **Declaration gate** — `DATA_EXTENSIONS` / `isDataFileName`
  ([manifest_loader.lua:127](../loader/manifest_loader.lua#L127)): data is
  `.tsv`/`.csv`/`.json`/`.xml`/`.eav` **by extension**, and undeclared data is dropped.

A `.json` is a table *only because a `Files.tsv` row says so*, which means an
**undeclared `.json` is by definition not a table** — yet the declaration gate calls it
data and drops it. Whatever else we build, these two must become **one** function.

Observed today (scratch package, `--file=json`):

```text
stray.json    (undeclared)                 -> WARN "not listed in Files.tsv" -> DROPPED, not exported
theme.json    (declared, no transcoder)    -> WARN "Don't know how to process theme.json" -> copied verbatim
notes.md      (undeclared)                 -> copied verbatim
```

So the "copy, don't parse" *machinery* already works. What is missing is a way to
**say** it: the only current route is to invent a `typeName`, omit the `transcoder`,
and put up with a "Don't know how to process" warning.

## Decisions taken

1. **Both mechanisms** (`Files.tsv` marker + manifest globs). ✅ decided
2. **An undeclared `.json`/`.xml` keeps today's behaviour: warn, and skip.** ✅ decided
   Nothing enters the export that `Files.tsv` did not name. The cost — every asset
   needs a row (or a glob) — is accepted, and is exactly what the two mechanisms below
   are for.
3. **The marker typeName must not be a name a user would plausibly want.** ✅ decided
   `Asset` is rejected: a user may well have an `Asset.tsv` table collecting *metadata
   about* their asset files, and that is a legitimate table type named `Asset`.

## The role model

Every file in a package resolves to exactly one of **three** roles:

| Role | How it gets the role | Parsed? | Exported? |
| --- | --- | --- | --- |
| **table** | `Files.tsv` row with a real `typeName` (+ `transcoder` for `.json`/`.xml`) | yes | yes, in the target format |
| **asset** | *implicitly*, by extension (`.md`, `.txt`, `.lua`, `.zip`); or **declared** on **any** extension — a `Files.tsv` row with `typeName=asset_file`, or a manifest `asset_files` glob | no | yes, copied **byte-for-byte**, never reformatted in place |
| **ignored** | `Files.tsv` row whose typeName is an `IgnoredFile` tag member (e.g. `MigrationScript`), or a manifest `ignored_files` glob | no | **no** |

Plus the one non-role: an **undeclared** file with a data extension (`.tsv`, `.csv`,
`.json`, `.xml`, `.eav`) is warned about and dropped, because it *looks* like a table
nobody declared. That is the only case that loses a file, and declaring it — as either
a table or an `asset_file` — is what resolves it.

The insight is that **asset is already a role we have**; it just could not be *stated*.
`.md` and `.txt` get it implicitly, and the docs and loader comments already call these
files "assets". All `asset_file` does is make the existing role **declarable**. Nothing
new is invented.

**`asset_file` applies to any extension, including `.tsv` / `.csv` / `.eav`.** It is not
a `.json`/`.xml` patch — it is the general statement "do not read this file as a table",
and a declaration always beats the extension guess (see [Precedence](#precedence)).
A `.tsv` declared `asset_file` is therefore:

- **not parsed** — no typeName, no schema, no `loadEnv.files` entry, no validators;
- **copied byte-for-byte** to the export;
- **never rewritten in place by the reformatter** — which is a feature in its own right.
  A hand-formatted lookup table, a sample/fixture `.tsv` shipped for someone else's
  tool, or a file whose exact bytes matter, can now be carried through the pipeline
  untouched. There is currently **no way** to ask for that: any `.tsv` the loader sees
  is either parsed (and reformatted in place) or dropped.

`ignored` is the genuinely separate one — *"pretend it isn't there"* rather than *"keep
it, don't read it"* — and it already exists:
[manifest_loader.lua:438](../loader/manifest_loader.lua#L438) nils the `raw_files` entry.
It just has no glob form and no user-facing docs beyond migration scripts.

### Naming (decided)

- Marker typeName: **`asset_file`** (tag: `AssetFile`, ancestor `table`).
- Manifest fields: **`asset_files`** and **`ignored_files`**, both `{string}|nil`.

`asset` is the word the docs and the loader already use for `.md`/`.txt`/`.lua`/`.zip`,
so a declared `.json` asset is the same concept under the same name — nothing new to
learn. `snake_case` is the house style for *engine-role* typeNames that are not table
types (`custom_type_def`, `type_wiring_def`, `patch`, `bulk_patch`), so `asset_file`
reads as "a role, not your data type".

Note this deliberately leaves the plain name **`Asset` free for user table types** — a
package collecting *metadata about* its assets in an `Asset.tsv` is a perfectly good
table named `Asset`, and it does not collide with the `asset_file` role.

(Rejected: `verbatim_file` — precise about the bytes, but "verbatim" is not a word every
data author reaches for, and it renames a concept the docs already call an asset.
`passthrough_file` is internal jargon; `raw_file` collides with `raw_files`, the loader's
name for *all* unparsed content.)

## Design

### 1. One role function (the actual bug fix)

Replace the two disagreeing gates with a single resolver — roughly:

```lua
-- Returns "table" | "asset" | "ignored"
local function fileRole(file_name, key, lcFn2Type, lcFn2Transcoder, manifestGlobs)
```

with these rules, in order:

1. `Files.tsv` typeName is an `IgnoredFile` member, or matches an `ignored_files`
   glob → **ignored**.
2. `Files.tsv` typeName is `asset_file`, or matches an `asset_files` glob → **asset**
   (declared).
3. `.tsv`/`.csv` (incl. compressed), or has a `transcoder` id, or auto-transcodes →
   **table**.
4. otherwise → **asset** (implicit — `.md`, `.txt`, `.lua`, `.zip`).

Rules 2 and 4 return the same role, which is the point: declaring an asset does not
create a special kind of file, it just overrides the extension guess.

### Precedence

**A declaration always beats the extension.** Rules 1 and 2 are checked *before* rule 3,
and that ordering is the feature, not an accident of implementation — it is what lets
`asset_file` apply to a `.tsv`/`.csv`/`.eav`, not just to the extensions that were
ambiguous anyway. Do not "simplify" the resolver by testing the extension first.

The extension is only ever a **guess for undeclared files**. Stated as one rule:

> A file is a table because something *said* it is (a `typeName`, or a `transcoder`, or
> — for `.tsv`/`.csv`/`.eav` — the extension in the absence of any contrary
> declaration). Never because of its extension alone.

Consequences worth spelling out in the docs:

- A `.tsv` with `typeName=asset_file` is **not** a table: it is not parsed, not
  reformatted in place, and copied byte-for-byte.
- A `.tsv` matching an `ignored_files` glob is neither loaded nor exported, even though
  `.tsv` is the most table-ish extension there is.
- Conversely, an `.md` can never become a table by declaration alone — there is no
  transcoder for it. (`transcoder` on a non-table extension should be an error, not a
  silent no-op; check what the current code does.)

Both `loadOtherFiles` (parse or not) and `rejectUndeclaredDataFiles` (must it be
declared) then ask *this one function*, so they can no longer contradict each other.
Note rule 3 is exactly today's parse gate — it is the definition of "table", and the
declaration requirement follows from it rather than from a parallel extension list.

### 2. Marker typeNames must not be treated as table types

Both of these warnings are category errors when the typeName is a **role**, not a type,
and they fire today:

- `typeName 'X' in Files.tsv should match fileName 'Y' without extension`
  ([files_desc.lua:297](../loader/files_desc.lua#L297))
- `Multiple types with name 'X'` ([files_desc.lua:708](../loader/files_desc.lua#L708)) —
  which exempts only `files`

A package with three `asset_file` rows would get "Multiple types with name
'asset_file'" plus three "should match fileName" warnings. **This is pre-existing**:
the tutorial run today emits eight such warnings for `custom_type_def`, `patch`,
`bulk_patch`, `SchemaOverlay`, `type_wiring_def`. Fix once, for the whole class: exempt
role/marker typeNames from both checks.

### 3. Message quality

`Don't know how to process <file>` (`processUnknownFile`) is the message an *asset*
currently gets — it describes the loader's confusion rather than what happened. It
should say what happened (`Copied as an asset (not a table): X`, at debug/info level for
an implicit asset, silent for a declared one). And the undeclared-data warning should
point at both ways out:

```text
WARN  Not listed in Files.tsv, so NOT loaded: ui/theme.json
      If it is data, add a row with a transcoder (e.g. json:objects).
      If it is an asset, add a row with typeName=asset_file,
      or add it to the manifest's asset_files globs.
```

## Phases

Per repo convention, each phase is a separate commit, `busted spec` green at each.

- **Phase 1 — `asset_file` marker + the single role function.** Built-in `AssetFile`
  tag and `asset_file` member type in `parsers/builtin.lua` (mirroring
  `IgnoredFile`/`MigrationScript`); `fileRole` in `manifest_loader`, replacing both
  gates; a declared asset is not parsed, kept in `raw_files`, copied byte-for-byte, and
  never rewritten in place by the reformatter. Spec: a declared asset survives to the
  export byte-identical **for every extension** — `.json`, `.xml`, **and `.tsv`** (the
  `.tsv` case also asserting the reformatter left the source bytes alone, which is the
  one behaviour no existing test covers). Docs: CHANGELOG + `DATA_FORMAT_README`.
  **This is the phase that closes the regression.**
- **Phase 2 — manifest globs.** `asset_files` and `ignored_files` (`{string}|nil`)
  in `manifest_info`, matched against the input-directory-relative key. Decide glob
  syntax (`*`, `**`, `?` — a small matcher, or reuse an existing one if there is one).
  `ignored_files` is what finally silences temp files (`*.tmp.tsv`, `scratch/**`) with
  no warning at all — the original annoyance, solved at the root.
- **Phase 3 — marker typeNames are not table types.** Exempt role typeNames from the
  "should match fileName" and "Multiple types with name" warnings. Removes eight stale
  warnings from the tutorial run.
- **Phase 4 — tutorial + docs.** An `asset_file` example in the tutorial (a `.json`
  asset copied to the export, next to the existing `DraftItem.tsv` undeclared-file
  demo), and the role table in `DATA_FORMAT_README`.

## Release gate

The current working tree drops undeclared `.json`/`.xml` files that 0.30.0 copied to
the export. Options:

- **Land Phase 1 before releasing** the undeclared-data-file change (preferred: the two
  belong together — one takes an escape hatch away, the other gives it back).
- Or ship the undeclared-data change alone and accept that, until Phase 1, a `.json`
  asset must be declared with a dummy `typeName` and no `transcoder` (which works today,
  but warns "Don't know how to process").

Either way the CHANGELOG's `[Unreleased]` "undeclared data file" entry needs a
migration note naming `.json`/`.xml` assets explicitly, since silent removal from an
export is the kind of thing a user finds out about late.

## Open questions

- **Glob syntax and matcher** (Phase 2). Is there an existing glob in the codebase to
  reuse, or is this a new ~30-line matcher? Do we need `**`, or is a per-directory `*`
  enough?
- **One copy per export format, or one at the root?** Assets are currently copied into
  each format's subdirectory (`json-json-natural/`, `lua-lua/`, …), so `notes.md` is
  duplicated per format. Is that right, or should assets land once at the export root?
  (Pre-existing question, but declaring assets makes it more visible.)
- **Archive members**: an `asset_file` inside a `.zip` — copy the member out, or is
  the containing zip (already streamed verbatim) sufficient?
