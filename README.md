# grimuah 📖👩‍🍳💋🤌

[![Zig](https://img.shields.io/badge/language-Zig-%23F7A41D)](https://ziglang.org/)
[![TypeScript](https://img.shields.io/badge/TypeScript-6.0-3178C6)](https://www.typescriptlang.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Build](https://img.shields.io/github/actions/workflow/status/CadeXLegend/grimuah/build.yml)](https://github.com/CadeXLegend/grimuah/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/CadeXLegend/grimuah?color=blue)](https://github.com/CadeXLegend/grimuah/releases)

the grimoire for codebase architecture 🤌

summon projects with linter-enforced architecture and dag-driven scaffolding

one self-contained zig binary, zero runtime dependencies

under a megabyte stripped, no subprocess, no other linter, no plugin directory to keep in step

most projects treat folders as glorified buckets with hidden social contracts

nothing stops a component from reaching into the database layer, or a service from handling presentation logic

grimuah gives every folder an identity, an import firewall, and enforceable obligations

the import graph is declared in `architecture.config.json`

`grimuah check` validates every import against this graph

imports flow from deep surfaces to shallow ones, never back

the graph stays acyclic

the rest is scaffolding, a rule engine, and a chef's kiss

---

## documentation map

| document                           | what it covers                                                                                 |
| ---------------------------------- | ---------------------------------------------------------------------------------------------- |
| [README.md](README.md)             | this page: install, quickstart, presets, commands, and the language story                       |
| [CONCEPTS.md](CONCEPTS.md)         | identity, surfaces, innate members, the dag, the config file, and the two enforcement tiers     |
| [RULES.md](RULES.md)               | every rule, grouped by layer, with its severity, plus how to turn a single rule off             |
| [PHILOSOPHY.md](PHILOSOPHY.md)     | why the rules exist and what the generator optimises for                                        |

---

## table of contents

- [quickstart](#quickstart)
- [languages](#languages)
- [core principles](#core-principles)
- [presets](#presets)
- [commands](#commands)
- [how a check runs](#how-a-check-runs)
- [config examples](#config-examples)

---

## quickstart

### install

grab the prebuilt binary from [releases](https://github.com/CadeXLegend/grimuah/releases), or build from source

```
git clone https://github.com/CadeXLegend/grimuah.git
cd grimuah
zig build -p ~/.local
```

requires zig 0.16

each platform ships two release builds

- **`release-safe`**: optimised for speed with every safety check kept, so a bounds or overflow violation traps instead of reading undefined memory, this is the recommended one, ~858 kb on linux x86_64
- **`release-small`**: optimised for size with the safety checks removed, so it is ~44% smaller and ~9% slower than `release-safe`, ~478 kb on linux x86_64

both are stripped, so a shipped binary is under a megabyte against the ~6 mb an unstripped one carries

a local `zig build` is a debug build, so it keeps its symbols and full panic stack traces

pass `-Dstrip=false` to a release build to keep both, which is what you want when debugging a release-mode bug

the binary lands in `~/.local/bin/grimuah`

make sure that directory is on your PATH

### summon a project

```
grimuah summon my-project --preset webapp
cd my-project
pnpm install
```

`init` and `summon` are the same command

pick whichever flavour you like

`summon` scaffolds:

- the folder structure
- `architecture.config.json` and `architecture.schema.json`
- the `tsconfig.json`
- `package.json`
- `.gitignore`
- husky pre-commit hooks

five presets ship with the binary: `default`, `webapp`, `cli`, `backend`, `bot`

no `--preset` flag means the default preset

up to six yes or no questions add optional surfaces on top

### enforce the architecture

```
grimuah check        # the pre-passes plus the rule engine, in one process
grimuah rules        # every rule name a config can turn off
grimuah add guard    # new surface, rules regenerate
grimuah upgrade      # sync to the closest preset
```

`pnpm check` runs `grimuah check` in a scaffolded project

the scaffolded husky hook runs `pnpm typecheck` and the em-dash guard, so a fresh project commits clean before its architecture rules are tuned

`grimuah check` needs no subprocess and no other linter installed, so it is the only lint step a project needs

other commands are documented in [commands](#commands)

---

## languages

grimuah is language-agnostic by design

a front-end turns source into a shared intermediate representation, and the rule engine reads only that representation

every rule declares the languages it supports, so a rule with no language-specific syntax runs on any front-end that produces the same tree

TypeScript is the first front-end and the only one shipping today

it reads `.ts`, `.tsx`, `.mts`, `.cts`, `.js`, `.jsx`, `.mjs`, and `.cjs`, so plain JavaScript and JSX ride the same front-end as TypeScript

adding a language means adding a front-end beside `src/lang/ts.zig`, not rewriting the rules

`src/lang/` holds the front-ends, `src/ir.zig` holds the representation they build, and `src/rules/` holds the rules that read it

---

## core principles

the short version, with the long version in [PHILOSOPHY.md](PHILOSOPHY.md)

**everything must justify its existence**: no speculative abstractions, no pattern applied before its scale earns it

**identity defines the boundary**: a file's suffix tells you the role, the surface's contract tells you the rules, the surface's scope tells you the responsibility

**co-location is the default, abstraction is the exception**: types, config, tests, and patterns live next to the code that owns them, and lifting to a shared location is a deliberate, gated act

**living rules over documentation**: a rule that blocks a violating import before it lands beats a style guide that decays with every PR

---

## presets

five presets ship with the binary

each preset defines a surface configuration for a common project archetype

| Preset  | Surfaces                                                             | Root lib |
| ------- | -------------------------------------------------------------------- | -------- |
| default | utils, services, components                                          | No       |
| webapp  | lib, utils, services, components, pages                              | Yes      |
| cli     | lib, utils, services, commands                                       | Yes      |
| backend | lib, db, middleware, services                                        | Yes      |
| bot     | lib, db, services, middleware, components, commands, tasks, handlers | Yes      |

no `--preset` flag uses the default preset

interactive refinement adds optional surfaces not already in the chosen preset

the tool asks up to six yes or no questions covering lib, db, pages, commands, middleware, and tasks

each question is skipped when the surface is already present in the preset

adding lib shifts it to depth 0 and shifts existing surfaces down

adding middleware inserts it between services and components in the dag order

---

## commands

**`init [name] [--preset <name>]`** (alias `summon`)

scaffolds a new project: folder structure, architecture config and schema, tsconfig, `package.json`, `.gitignore`, and husky pre-commit hooks

interactive refinement asks only about surfaces not already in the chosen preset

templates produce output that needs no reformatting

**`check`**

runs the CLI pre-passes for the cosmetic and structural rules, then the rule engine for the rest

both tiers run in one process and both must pass for a zero exit code

an error-severity finding fails the run, a warning-severity finding is reported without failing it

pre-passes can be skipped by disabling the corresponding layer in the config

**`rules`**

prints every rule the engine can report, grouped by layer, with its name, severity, and the sentence a run prints

the names are the keys `architecture.config.json` turns a rule off with

**`skills list`**

prints every agent skill the binary carries, with the sentence an agent matches on

**`skills install [name...] [--path <dir>] [--force]`**

writes each named skill, or all of them, to `<dir>/<name>/SKILL.md`

`<dir>` defaults to `.agents/skills`, and an existing file is kept unless `--force` is passed

the skills are embedded in the binary, so an upgrade hands over the version it shipped with and no network is needed

**`add <surface-name> [--path <dir>]`**

creates a new surface directory with an example file and updates `architecture.config.json`

suffixes come from a name heuristic:

- `validators` → `.validator.ts`
- `guards` → `.guard.ts`
- `states` → `.state.ts`
- `repositories` → `.repo.ts`
- anything else → `.<singular>.ts`

every surface also gets `.config.ts` as an innate member

**`remove <surface-name>`**

deletes the surface directory

strips the surface from `architecture.config.json`, including every `allowedImports` entry across all surfaces

compacts the dagOrder values

**`upgrade`**

detects the closest matching preset

adds any preset surfaces not already in the current config

preserves user modifications, including layer toggles, rule toggles, and custom surfaces

reports when the config is already up to date

---

## how a check runs

`grimuah check` reads `architecture.config.json`, then runs two tiers in the same process

the CLI pre-passes handle file-path and file-content rules on a worker thread

the rule engine handles token-level and tree-level rules on the remaining cores

neither tier spawns a subprocess, and neither needs a linter installed

findings print in `path:line: [layer] message` form, errors fail the run, and warnings are reported without failing it

[CONCEPTS.md](CONCEPTS.md#the-enforcement-tiers) describes what each tier enforces, and [RULES.md](RULES.md) lists every rule

---

## config examples

every layer is `true` and every rule is on by default

`grimuah init` writes a config with all four layers enabled and no `rules` block at all, because a rule the `rules` object omits keeps running

so the config a fresh project gets needs no rule keys to run all 51 rules

### every layer on

this is the config the default preset scaffolds

```
{
  "sourceRoots": ["src"],
  "surfaces": [
    {
      "name": "utils",
      "path": "src/utils",
      "depth": 1,
      "dagOrder": 0,
      "suffixes": [".util.ts"],
      "innateMembers": [".types.ts", ".config.ts", ".spec.ts", ".regex-patterns.ts"],
      "allowedImports": []
    },
    {
      "name": "services",
      "path": "src/services",
      "depth": 1,
      "dagOrder": 1,
      "suffixes": [".service.ts"],
      "innateMembers": [".types.ts", ".config.ts", ".spec.ts"],
      "allowedImports": []
    },
    {
      "name": "components",
      "path": "src/components",
      "depth": 1,
      "dagOrder": 2,
      "suffixes": [".component.ts"],
      "innateMembers": [".types.ts", ".config.ts", ".spec.ts"],
      "allowedImports": []
    }
  ],
  "layers": {
    "cosmetic": true,
    "structural": true,
    "resilience": true,
    "behavioural": true
  }
}
```

### some rules off

the `rules` object turns a single rule off by name, and the layer it belongs to stays on

add it beside `layers`, keeping every surface entry as it is

```
"layers": {
  "cosmetic": true,
  "structural": true,
  "resilience": true,
  "behavioural": true
},
"rules": {
  "switch-statement": false,
  "max-file-lines": false,
  "nested-ternary": false
}
```

this project keeps every other rule, so it still gets `null-literal`, `throw-statement`, and the rest of the resilience layer

[`grimuah rules`](#commands) prints the name every rule is switched with

### a whole layer off

a layer is the gate and a rule only narrows it

turning a layer off silences every rule inside it, and a rule named `true` inside a disabled layer stays off

```
"layers": {
  "cosmetic": true,
  "structural": true,
  "resilience": true,
  "behavioural": false
},
"rules": {
  "throw-statement": true
}
```

the `throw-statement` rule stays off here, because `behavioural` is `false` and the layer is the outer switch

set the layer back to `true` to turn it on, the schema requires all four layer keys

the hygiene layer has no key at all, so it runs whenever the engine runs and `rules` is the only switch over its rules

---

## license

MIT, see [LICENSE](LICENSE)
