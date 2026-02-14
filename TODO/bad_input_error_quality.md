# Bad Input Error Quality Findings

Findings from reviewing the `bad_input/` test framework output.
Each item describes a gap in error detection or error message quality.

## Missing Error Detection

### files_tsv_errors/nonexistent_file_ref
`Files.tsv` references `Ghost.tsv` which does not exist on disk, but the reformatter only
produces a "Content of Files.tsv has changed" warning. No error or warning is reported about
the missing file. The system should report something like:
`File 'Ghost.tsv' listed in Files.tsv does not exist`.

### header_errors/missing_type_annotation
`Data.tsv` has column headers without type annotations (`name`, `value`, `description` instead
of `name:identifier`, `value:integer`, etc.). The reformatter silently accepts this and only
warns about content changes. It should report:
`Column 'name' in Data.tsv is missing a type annotation (expected format: name:type)`.

## Poor Error Messages — Stack Traces / Lua Internals Exposed

### expression_errors/syntax_error
A cell expression `=1 + + 2` produces a raw Lua stack trace ending with:
`lua54: .../sandbox.lua:148: [string "return (1 + + 2)"]:1: unexpected symbol near '+'`
The user sees internal file paths (`sandbox.lua:148`), Lua string compilation notation
(`[string "..."]`), and a full stack traceback. Should instead report something like:
`Expression error in Data.tsv line 2, column 'value': syntax error near '+' in '=1 + + 2'`.

### expression_errors/undefined_reference
References to `ghost_variable` produce:
`attempt to perform arithmetic on a nil value (global 'ghost_variable')`
with the sandbox file path included. Should say:
`Undefined variable 'ghost_variable' in expression '=ghost_variable * 2'`.
Also, each error is logged twice (once without detail, once with the Lua error).

### validator_errors/row_validator_fails (fixed in test, but message could improve)
The validator error message includes the full validator expression as the "value", which is
technically correct but verbose. The important part — the custom error string `price must be
positive` — is present but could be more prominent.

## Poor Error Messages — Confusing or Jargon-Heavy

### manifest_errors/bad_custom_type
Error message shows internal type notation:
`Bad {custom_type_def}|nil custom_types, col 2 in .../Manifest.transposed.tsv`
The `{custom_type_def}|nil` is internal type system notation meaningless to users. Should say:
`Invalid custom type definition: type 'nonexistent_type_xyz' is unknown`.

### manifest_errors/invalid_version
Message reads `Bad version version, col 2` — the word "version" appears twice because
the type name and field name are both "version". Awkward but technically correct. Could
be improved to: `Invalid version: 'not_a_version' is not a valid semantic version (expected X.Y.Z)`.

### structure_errors/empty_data_file
Error reads: `header_row is neither a string nor a sequence; skipping this file!`
Non-programmers won't understand "string nor a sequence". Should say:
`Data.tsv is empty or has no header row`.

### structure_errors/inconsistent_columns
When a row has fewer columns than the header, the error is:
`Bad string extra, col 3 in Data.tsv on line 2 (item1): 'nil'`
This doesn't explain the structural problem. Should say:
`Row 2 (item1) has 2 columns but the header defines 3 — column 'extra' is missing`.

### type_errors/out_of_range_ubyte
Error says `Bad ubyte value` without explaining the valid range. Non-programmers don't know
what "ubyte" means. Should say:
`Value 999 is out of range for type 'ubyte' (must be 0–255)`.

### type_errors/string_for_integer
The third data row (missing value) produces:
`Bad integer value, col 2 ... 'nil' (context was 'tsv', was expecting a string)`
The parenthetical "context was 'tsv', was expecting a string" is confusing — the column
type is integer, not string. The message should say:
`Column 'value' is empty (missing value) but type 'integer' does not allow nil`.

### type_errors/bad_boolean
Error says `Bad boolean flag ... 'maybe'` but doesn't list valid values. Should say:
`Invalid boolean value 'maybe' — expected 'true' or 'false'`.

### type_errors/bad_enum_value
Error says `Bad Status status ... 'NonExistent'` but doesn't list the valid enum members.
Should say: `Invalid Status value 'NonExistent' — valid values are: Active, Inactive, Pending`.

## Verbose / Noisy Output

### cli_errors/invalid_log_level
Because the log level itself is invalid, the `--log-level=banana` error is followed by 18+
lines of INFO-level parser registration messages. The error detection works, but the actual
error is buried under noise. The log level validation should happen before any module
initialization logging, or at minimum the usage hint should still appear.
