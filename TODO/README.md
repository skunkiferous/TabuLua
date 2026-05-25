# TODOs

Poor man's issue management for TabuLua.

## Index

| File | Summary |
| --- | --- |
| [lua55_compatibility.md](lua55_compatibility.md) | Lua 5.5 compatibility issues with the ltcn library |
| [luajit_compatibility.md](luajit_compatibility.md) | LuaJIT compatibility issues and proposed `numbers.lua` abstraction layer |
| [graph_types.md](graph_types.md) | Plan for built-in `basic_graph_node` / `graph_node` / `tree_node` types with auto-wired completion and validators, plus optional edge files |
| [mod_overrides.md](mod_overrides.md) | Research and plan for child-package modifications to parent data (mod-style overrides: add/remove/update rows, filter-and-transform, validation re-run) |
| [type_wiring.md](type_wiring.md) | Refactor (post-graphs): collapse hard-wired super-type behaviour branches (`Type`/`enum`/`custom_type_def`/graph wiring) into a single type-wiring registry. Per-typeName `register` (cascade: `onLoad`, processors, validators) and module-level `registerModule` (`enginePostPasses`, `sandboxHelpers`, `descriptorColumns`). Shrinks core `Files.tsv` to six intrinsic columns; the other ten become feature-module registrations. User packages reach the registry via a new manifest `bootstrap` field (code library, reaches all slots except `onLoad`) and via optional `TypeWiring.tsv` (pure-data, expression slots only) |
| [read_only_next_bypass.md](read_only_next_bypass.md) | Close the `next()` bypass in `read_only.lua` by moving the proxy→original mapping into a module-private weak table |
| [matrix_market_coo.md](matrix_market_coo.md) | Extend `raw_tsv` with Matrix Market / COO (`.mtx`) reader, writer, validator, and header parser for sparse-matrix coordinate-list files |
| [pk_lookup_audit.md](pk_lookup_audit.md) | Audit the codebase for places that rebuild a name→row map or linear-scan for a PK that the parsed dataset already indexes natively, and fix them via three documented patterns |
| [data_mutation_integrity.md](data_mutation_integrity.md) | Make all data writes go through `setCell` (stop `wrapRowForProcessor` handing out mutable tables), close the cell-expression/COG sandbox escape via `loadEnv`'s `__index = _G`, and centralize the scattered sandbox-environment definitions into a single `sandbox_env.lua` |
