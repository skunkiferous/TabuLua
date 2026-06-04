# Skill Tree (generated)

This page is **generated from the data** by TabuLua's COG engine (v0.22.0). The skill
DAG below is rendered directly from [SkillTree.tsv](SkillTree.tsv) (the nodes and their
prerequisites) and [SkillEdges.tsv](SkillEdges.tsv) (the level you need in a parent skill
before you can train its child). Edit the data, re-run the generator, and this page
updates itself — there is no hand-maintained copy to drift out of sync.

How it works:

- The block below is wrapped in TabuLua's **hidden Markdown COG marker**,
  `<!---[[[ … ]]]--->`. It is a valid HTML comment, so it is invisible when this file is
  rendered and does not pollute the raw source with `###`/`---` heading or rule markup.
- The COG block is a **one-liner that calls a code library**:
  `return skillDoc.skillTreeAscii(files)`. The real rendering logic lives in
  [libs/skillDoc.lua](libs/skillDoc.lua) — not out of necessity (COG doc blocks and code
  libraries share the same safe sandbox as of v0.22.0), but to keep the template a
  readable one-liner and the renderer reusable and testable on its own.
- `files` exposes every loaded dataset, keyed by file name (`files["SkillTree.tsv"]`) or
  type name (`files["SkillTree"]`). Generation runs after the data is fully loaded, so the
  graph's derived `graphChildren` back-references are already filled in.

Refresh this page in place (markers kept) with:

```bash
lua reformatter.lua --cog-docs tutorial/core/ tutorial/expansion/
```

Or export a clean, marker-free copy (COG scaffolding stripped) with:

```bash
lua reformatter.lua --file=json --strip-cog tutorial/core/ tutorial/expansion/
```

## Prerequisite graph

<!---[[[
return skillDoc.skillTreeAscii(files)
]]]--->
```text
perception (max 5)
|-- aim (max 5)  -- needs perception lvl 2
|-- tracking (max 3)  -- needs perception lvl 3
`-- huntersMark (max 3)  -- needs perception lvl 4
stealth (max 5)
|-- sneakAttack (max 5)  -- needs stealth lvl 2
`-- tracking (max 3)  -- needs stealth lvl 2
dexterity (max 5)
`-- huntersMark (max 3)  -- needs dexterity lvl 3
```
<!---[[[end]]]--->

Each line shows a skill and its `(max <level>)` cap; a child line's
`-- needs <parent> lvl <n>` annotation is the per-edge `requiredLevel` from
SkillEdges.tsv. Skills with more than one prerequisite (`tracking`, `huntersMark`) appear
under each of their parents — that is what makes this a DAG rather than a plain tree.
