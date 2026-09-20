# skills

ready to use agent skills for working in a grimuah project

each folder is a self-contained skill, one `SKILL.md` with frontmatter and no dependencies

copy a folder into wherever your agent reads skills from, or point the agent at the file directly

```
grimuah skills install
grimuah skills install grimuah-compliance --path ~/.claude/skills
```

the binary carries these files, so `grimuah skills install` writes the version that binary shipped with, and no network is needed

## the skills

| Skill                     | Use it when                                                                                                |
| ------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `grimuah-setup`           | installing the binary, scaffolding a project, choosing a preset, and understanding a fresh scaffold         |
| `grimuah-compliance`      | writing TypeScript in a repo with `architecture.config.json`, before the first line rather than after a run |
| `grimuah-architecture`    | deciding where a file, a type, or a constant belongs, and what the import graph should look like           |
| `grimuah-fix-findings`    | `grimuah check` printed something and you need to know what to change, and whether to silence a rule        |
| `grimuah-migrate-existing` | bringing grimuah into a repository that already exists, one layer at a time                                 |

## scope

the skills describe the binary as it ships, so they carry no copy of the rule table

`grimuah rules` prints every rule name with its layer, severity, and message, and `RULES.md` explains the layers

these skills are for projects grimuah generates or gates, not for work on grimuah itself, which has its own skill at `.agents/skills/optimise-grimuah-performance`
