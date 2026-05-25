# Add Matrix Market / COO Coordinate-List Format Support to `raw_tsv`

## Summary

Add reader/writer/validator functions to [raw_tsv.lua](../raw_tsv.lua) for the
**Matrix Market exchange format** (`.mtx`), the canonical text encoding of
the **coordinate list (COO)** representation of sparse matrices. Each
non-zero entry is stored as a `(row, col, value)` triple on its own line,
preceded by a typed header line and an optional block of `%` comments.

The format is plain text and tabular, so it fits cleanly alongside the
existing TSV reader. Cells stay as strings (matching `stringToRawTSV`); type
coercion is left to the caller.

## Why This Module

The user's stated motivation is "we could read files using multiple
different file extensions, as long as they represent data the same way."
Matrix Market is the most widely deployed COO encoding (NIST, SciPy,
MATLAB, Octave, Eigen, SuiteSparse all read/write it), so it is the right
spec to target. Other extensions occasionally seen for the same content
(`.coo`, `.ijv`) carry no separate spec and can be read by the same
function — the parser is content-driven, not extension-driven.

The chemistry `.xyz` format that prompted the question is *not* a COO
format (it stores `element_symbol x y z` rows with an atom-count header)
and is **out of scope** here. See "Non-Goals" below.

## Format Specification (Reference)

Source: https://math.nist.gov/MatrixMarket/formats.html

```
%%MatrixMarket matrix coordinate real general
% Any number of comment lines, each starting with '%'.
% Comments may also be blank (just '%').
5  5  8
1  1  1.000e+00
2  2  1.050e+01
3  3  1.500e-02
1  4  6.000e+00
4  2  2.505e+02
4  4 -2.800e+02
4  5  3.332e+01
5  5  1.200e+01
```

Key rules:

- **Header (line 1):** `%%MatrixMarket <object> <format> <field> <symmetry>`,
  case-insensitive per the spec. Tokens are whitespace-separated.
  - `object`   ∈ `{matrix}` (the only object currently defined)
  - `format`   ∈ `{coordinate, array}` — this plan covers **coordinate** only
  - `field`    ∈ `{real, complex, integer, pattern}`
  - `symmetry` ∈ `{general, symmetric, skew-symmetric, hermitian}`
- **Comment lines:** start with `%`. Zero or more, between the header and
  the size line. The spec does not permit comments interleaved with data.
- **Size line:** `M N L` for coordinate format — rows, columns, number of
  stored entries (whitespace-separated integers).
- **Data lines:** `L` lines after the size line. Column count per line
  depends on `field`:
  - `real` / `integer` → 3 columns: `I J value`
  - `pattern`          → 2 columns: `I J`
  - `complex`          → 4 columns: `I J re im`
- **Indices are 1-based.** `1 ≤ I ≤ M`, `1 ≤ J ≤ N`.
- **Symmetric / skew-symmetric / hermitian:** only the lower triangle
  (`I ≥ J`) is stored. This module preserves the on-disk layout and
  does **not** auto-expand the upper triangle — callers who need a dense
  view do that themselves.
- **Separators in data lines:** any run of whitespace (spaces and/or tabs).
  Not strictly tab-separated like TSV.

## Data Representation

The same shape `raw_tsv` already uses — a sequence whose elements are
either strings (comments/blank lines) or sequences of cells. This keeps
COO data interoperable with `transposeRawTSV`, `rawTSVToString`,
`isRawTSV`, and the rest of the module surface.

Mapping a `.mtx` file into that shape:

1. The header line `%%MatrixMarket matrix coordinate real general`
   is preserved as a comment row, **prefixed with `#`** so it survives a
   round-trip through `rawTSVToString` (which uses `#` as its comment
   marker). The full original text is kept after the `#`:
   `"# %%MatrixMarket matrix coordinate real general"`.
2. Each `%` comment becomes a `# ...` comment row (the `%` is rewritten
   to `# ` so the structure validates as a normal raw TSV).
3. The size line becomes the **first data row**: `{"5", "5", "8"}`.
4. Each data line becomes a row of 2/3/4 string cells (per `field`).

Cells stay as strings, matching `stringToRawTSV` behavior. A caller who
wants numeric triples calls `tonumber` themselves, or uses the
`parseCOOHeader` helper plus the high-level `tsv_model` parsers.

The writer `cooToString` does the inverse mapping. The `#` → `%`
rewrite is done by recognising lines that begin with `# %%MatrixMarket`
(emit as `%%MatrixMarket ...`) or `# ` (emit as `% ...`).

## Proposed API Additions

All added to [raw_tsv.lua](../raw_tsv.lua) and exported through the same
`API` table / callable dispatcher.

```lua
--- Parses a Matrix Market coordinate-format string into a raw TSV structure.
--- Header and '%' comments are translated to '#' comments; the size line
--- becomes the first data row; each entry becomes a row of 2/3/4 string cells.
--- @param s string The .mtx file contents (must be valid UTF-8, must start with '%%MatrixMarket')
--- @return table A raw TSV structure
--- @error Throws if s is not a valid Matrix Market coordinate-format string
local function stringToCOO(s) ... end

--- Reads a file and converts it to a raw TSV structure using stringToCOO.
--- Extension-agnostic: dispatch is on the '%%MatrixMarket' header, not the suffix.
--- @param file string The file path to read (.mtx, .coo, .ijv, etc.)
--- @return table|nil The raw TSV structure, or nil on error
--- @return string|nil Error message on failure, nil on success
local function fileToCOO(file) ... end

--- Converts a raw TSV structure back to a Matrix Market coordinate string.
--- The first comment row may be a serialised '%%MatrixMarket' header; if absent,
--- one is synthesised from the optional `header` argument (default
--- {object="matrix", format="coordinate", field="real", symmetry="general"}).
--- @param t table The raw TSV structure (typically produced by stringToCOO)
--- @param header table|nil Optional header overrides {object, format, field, symmetry}
--- @return string The .mtx file contents
--- @error Throws on structural problems (missing size line, wrong entry width,
---        non-integer indices, indices out of range, count mismatch, etc.)
local function cooToString(t, header) ... end

--- Validates that a raw TSV structure is a well-formed COO payload:
---  - first non-comment row is a 3-integer size line {M, N, L}
---  - exactly L subsequent data rows
---  - each data row has 2, 3, or 4 cells (consistent within the file)
---  - all I,J are integers in 1..M, 1..N
--- Does not require a '%%MatrixMarket' header comment.
--- @param t any The value to check
--- @return boolean True if t is a valid COO structure, false otherwise
local function isCOO(t) ... end

--- Parses a single Matrix Market header line into its four tokens.
--- Case-insensitive per the spec; tokens are lowercased in the result.
--- @param line string A '%%MatrixMarket ...' header line
--- @return table|nil {object, format, field, symmetry}, or nil on parse failure
--- @return string|nil Error message on failure, nil on success
local function parseCOOHeader(line) ... end
```

Public-API table additions (alphabetical, preserve existing layout):

```lua
local API = {
    cooToString    = cooToString,    -- NEW
    fileToCOO      = fileToCOO,      -- NEW
    fileToRawTSV   = fileToRawTSV,
    getVersion     = getVersion,
    isCOO          = isCOO,          -- NEW
    isRawTSV       = isRawTSV,
    parseCOOHeader = parseCOOHeader, -- NEW
    rawTSVToString = rawTSVToString,
    stringToCOO    = stringToCOO,    -- NEW
    stringToRawTSV = stringToRawTSV,
    transposeRawTSV = transposeRawTSV,
}
```

## Parser Behaviour Details

- **Whitespace splitting.** Data and size lines split on `%s+`, not on
  `\t`. A new helper `splitWS(line)` (private to the module) keeps the
  parser tidy and avoids touching `string_utils`.
- **Line endings.** Reuse `file_util.unixEOL` exactly as `stringToRawTSV`
  does (handles CR, LF, CRLF transparently).
- **UTF-8 validity.** Same `isValidUTF8` assertion at the top of
  `stringToCOO` as in `stringToRawTSV`.
- **Header strictness.** Reject anything where the first non-blank
  byte sequence is not `%%MatrixMarket`. Reject unknown `format`
  values (including `array` — dense format is explicitly out of
  scope; emit a clear error: `"array (dense) format not supported; use coordinate"`).
  Reject unknown `field` or `symmetry` tokens. Lowercase tokens
  before matching.
- **Size-line validation.** All three cells must parse as
  non-negative integers; `L == 0` is allowed (empty matrix).
- **Data-line count.** If fewer than `L` data lines appear → error.
  If more appear → error (don't silently truncate).
- **Index range.** Each `I` must satisfy `1 ≤ I ≤ M`, each `J` must
  satisfy `1 ≤ J ≤ N`. Out-of-range → error citing the line number.
- **Symmetry payload check.** For `symmetric`/`skew-symmetric`/`hermitian`
  the parser does *not* enforce `I ≥ J`. The spec is widely violated in
  practice and the raw module is the wrong layer to police it; a
  higher-level validator can do so if needed. Document this leniency.
- **Blank lines inside the comment block.** Allow them (preserve as
  empty-string comment rows). Reject blank lines once data has started.

## Writer Behaviour Details

- **Detect existing header.** Walk leading comment rows; if any matches
  `^#%s*%%%%MatrixMarket`, reuse it verbatim (after stripping the `# `).
  Otherwise synthesise from the `header` argument (with the documented
  defaults).
- **Comment rewriting.** Each comment row is emitted as a single line.
  - `# %%MatrixMarket …`  →  `%%MatrixMarket …` (header)
  - `# …`                 →  `% …`
  - `""` (blank)          →  `%` (a bare percent — a valid comment)
- **Size line.** First non-comment row, validated by the same checks
  `isCOO` performs.
- **Data lines.** Cells separated by a single space, terminated by `\n`.
  Numbers in cells go through `tostring` (matching `rawTSVToString`),
  so callers can pass either strings or Lua numbers.

## File Extensions

This module is **extension-agnostic**: `fileToCOO` will read any file
whose contents begin with `%%MatrixMarket`. Common extensions seen in
the wild:

| Extension | Source / typical use |
| --------- | -------------------- |
| `.mtx`    | Canonical Matrix Market (NIST, SciPy `scipy.io.mmread`) |
| `.coo`    | Informal, used by some sparse-tensor toolkits |
| `.ijv`    | Some MATLAB workflows (I, J, value) |

If callers want **dispatch by extension** (e.g. a `fileToTabular` that
sniffs `.tsv` vs `.mtx`), that belongs in [files_desc.lua](../files_desc.lua)
or a new wrapper — **not** in `raw_tsv`, which stays low-level.

## Test Plan

Add a new top-level `describe("Matrix Market / COO", function() … end)`
block at the bottom of [spec/raw_tsv_spec.lua](../spec/raw_tsv_spec.lua),
mirroring the structure of the existing `stringToRawTSV` /
`rawTSVToString` / `fileToRawTSV` / `isRawTSV` blocks.

### `stringToCOO`

- **Canonical NIST example** (the 5×5×8 example above) round-trips
  through `stringToCOO` → expected raw TSV structure.
- Header preserved as `"# %%MatrixMarket matrix coordinate real general"`.
- `%` comments translated to `# ` comments (including a bare `%` line
  becoming `""`).
- Header tokens are case-insensitive: `%%MATRIXMARKET MATRIX COORDINATE REAL GENERAL`
  parses identically.
- `field = "pattern"` → data rows have 2 cells.
- `field = "complex"` → data rows have 4 cells.
- `field = "integer"` → data rows have 3 cells, still stored as strings.
- Empty matrix (`L = 0`) → no data rows, just header + size line.
- Various line endings (`\r`, `\n`, `\r\n`) all accepted.
- Trailing blank lines after data → tolerated (matches
  `stringToRawTSV`'s trailing-`""` trim).

**Errors:**

- Non-string input → assertion message includes the actual type.
- Invalid UTF-8 → assertion.
- Missing `%%MatrixMarket` header → clear error.
- `array` format → `"array (dense) format not supported; use coordinate"`.
- Unknown `field` token (e.g. `weird`) → error naming the bad token.
- Unknown `symmetry` token → error naming the bad token.
- Size line not 3 integers → error citing the line number.
- Negative dimensions / `L` → error.
- Fewer than `L` data lines → error showing expected vs found.
- More than `L` data lines → error.
- Data line with wrong column count for the declared `field` → error
  citing line number and expected count.
- Non-integer `I`/`J` → error.
- `I > M` or `J > N` → error citing line number and the offending index.

### `cooToString`

- Round-trip: `cooToString(stringToCOO(x)) == x` for the canonical
  example (modulo whitespace normalisation — assert byte-equal after
  normalising runs of spaces in data lines).
- Synthesised header when no header comment present:
  `cooToString({{"1","1","1"}, ...})` produces a default
  `%%MatrixMarket matrix coordinate real general` header.
- Custom header via argument:
  `cooToString(t, {field="integer"})` emits `integer` in the header.
- Comment rewriting:
  - `"# %%MatrixMarket matrix coordinate real general"` → emitted as
    `%%MatrixMarket matrix coordinate real general` (not double-rewritten).
  - `"# notes about this matrix"` → `% notes about this matrix`.
  - `""` → `%`.
- Cells that are Lua numbers are stringified (matches `rawTSVToString`).
- Errors on the same conditions as `isCOO` (missing size row, wrong
  entry width, index out of range, count mismatch).

### `fileToCOO`

- Reads a `.mtx` written to a tmp file.
- Reads a `.coo` extension with the same content.
- Returns `nil, err` for a non-existent file (matches `fileToRawTSV`
  contract).
- Returns `nil, err` for an empty file (no header).

### `isCOO`

- Accepts a well-formed COO raw TSV structure (with and without a
  header comment).
- Rejects: missing size row; size row with non-integer cells; data row
  with wrong arity; `I > M`; `J > N`; non-integer index; entry count
  ≠ `L`; non-table input.

### `parseCOOHeader`

- Parses `%%MatrixMarket matrix coordinate real general` → 4-token table.
- Case-insensitive.
- Whitespace-tolerant between tokens.
- Returns `nil, "..."` for: missing `%%MatrixMarket` prefix; wrong token
  count; unknown token values.

### Module API

Extend the existing `module API` `describe` block:

- `getVersion`, `__tostring`, `callable API` blocks unchanged but
  exercise the new operations via the callable form:
  `raw_tsv("stringToCOO", "...")` and `raw_tsv("isCOO", t)`.

## Documentation Updates

1. **[MODULES.md L368-L371](../MODULES.md#L368)** — extend the `raw_tsv`
   section:

   > Low-level TSV/CSV file parsing and writing without type validation.
   > Pure data handling. Includes `transposeRawTSV()` …
   > **Also reads and writes the Matrix Market coordinate (COO) format
   > used for sparse matrices (`.mtx`, `.coo`, `.ijv`): the header and
   > `%` comments are translated to `#` comments, the size line becomes
   > the first data row, and each entry becomes a 2/3/4-cell row of
   > strings (per the `field` token). Cells stay as strings — type
   > coercion is the caller's responsibility.**

2. **[CHANGELOG.md](../CHANGELOG.md)** — under `## [Unreleased] ### Added`:

   > - **`raw_tsv` Matrix Market / COO support.** Five new functions —
   >   `stringToCOO`, `cooToString`, `fileToCOO`, `isCOO`,
   >   `parseCOOHeader` — read and write the Matrix Market coordinate
   >   (`.mtx`) format used to exchange sparse matrices. Header and
   >   `%` comments map to `#` comments in the raw TSV structure, so
   >   the existing helpers (`transposeRawTSV`, `rawTSVToString`,
   >   `isRawTSV`) work unchanged. Cells stay as strings; the dense
   >   `array` format is rejected with a clear error.

3. **[tutorial/README.md](../tutorial/README.md)** — add a short section
   *after* the existing raw_tsv coverage demonstrating `fileToCOO` on a
   tiny `.mtx` example. Optional; do it only if the tutorial already
   covers `raw_tsv` end-to-end (check before writing).

4. **No new top-level doc file.** The behaviour is small enough to
   live in the function comments + MODULES.md entry.

## Scope / Non-Goals

- **Matrix Market `array` (dense) format.** Rejected with a clear error.
  Adding it would mean a different in-memory shape (column-major flat
  list, no `I`/`J`) and inflates the surface. Defer until a real use
  case appears.
- **Symmetry expansion.** The parser preserves whatever is on disk; it
  does not synthesise mirrored entries for `symmetric`/`hermitian`
  matrices. A `expandCOOSymmetry(t)` helper could be added later if
  needed.
- **Numeric coercion.** Cells stay as strings, matching
  `stringToRawTSV`. A `cooToNumeric(t)` helper (or use of
  `tsv_model`'s parser layer) is the right place to do typed
  conversion.
- **Chemistry `.xyz` (atom-position) format.** Structurally different
  (atom-count header + comment line + `element x y z` rows). If a real
  need surfaces, add a separate `raw_xyz.lua` module rather than
  overloading `raw_tsv`.
- **Generic dispatcher** that picks the reader from a file extension.
  That belongs in `files_desc` or a new wrapper module — out of scope
  here.
- **`vector` object** (the only other object the Matrix Market grammar
  hints at). Not currently used in the wild; reject with the same
  unknown-`object` error path.

## References

- [raw_tsv.lua](../raw_tsv.lua) — current implementation, surface to extend
- [spec/raw_tsv_spec.lua](../spec/raw_tsv_spec.lua) — test conventions to mirror
- [MODULES.md L368-L371](../MODULES.md#L368) — `raw_tsv` documentation entry
- [file_util.lua](../file_util.lua) — `unixEOL`, `readFile`, `writeFile`
- [predicates.lua](../predicates.lua) — `isValidUTF8`, `isFullSeq`
- [string_utils.lua](../string_utils.lua) — `split`, `trim`
- Matrix Market spec: https://math.nist.gov/MatrixMarket/formats.html
- SciPy reference reader (for cross-checking edge cases):
  `scipy.io.mmread` / `scipy.io.mmwrite`

## After It's Done

- Decide whether `files_desc` should learn to route `.mtx`/`.coo`
  files to `fileToCOO` automatically, so they show up in the standard
  load order alongside `.tsv` files. Likely yes for completeness, but
  it changes load-order semantics — handle as a follow-up task.
- Consider whether `tsv_diff` should special-case COO structures
  (e.g. order-insensitive diffing keyed on `(I, J)` rather than line
  order). Sparse matrices are conceptually unordered, and a line-order
  diff is noisy.
