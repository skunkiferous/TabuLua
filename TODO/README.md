# TODOs

Poor man's issue management for TabuLua.

## Index

| File | Summary |
| --- | --- |
| [lua55_compatibility.md](lua55_compatibility.md) | Lua 5.5 compatibility issues with the ltcn library |
| [luajit_compatibility.md](luajit_compatibility.md) | LuaJIT compatibility issues and proposed `numbers.lua` abstraction layer |
| [pre_processors.md](pre_processors.md) | Plan for a new pre-validation processing step that mutates parsed rows (prerequisite for future `graph_node` / `tree_node` types) |
| [graph_types.md](graph_types.md) | Plan for built-in `basic_graph_node` / `graph_node` / `tree_node` types with auto-wired completion and validators, plus optional edge files |
| [mod_overrides.md](mod_overrides.md) | Research and plan for child-package modifications to parent data (mod-style overrides: add/remove/update rows, filter-and-transform, validation re-run) |
| [type_wiring.md](type_wiring.md) | Refactor (post-graphs): collapse hard-wired super-type behaviour branches (`Type`/`enum`/`custom_type_def`/graph types) into a single type-wiring registry, with optional `TypeWiring.tsv` for user packages |
