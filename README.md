# grimuah 📖👩‍🍳💋🤌

[![Zig](https://img.shields.io/badge/language-Zig-%23F7A41D)](https://ziglang.org/)
[![TypeScript](https://img.shields.io/badge/TypeScript-6.0-3178C6)](https://www.typescriptlang.org/)
[![Biome](https://img.shields.io/badge/linter-Biome-8f36c9)](https://biomejs.dev/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Build](https://img.shields.io/github/actions/workflow/status/CadeXLegend/grimuah/build.yml)](https://github.com/CadeXLegend/grimuah/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/CadeXLegend/grimuah?color=blue)](https://github.com/CadeXLegend/grimuah/releases)

the grimoire for typescript architecture 🤌

summon typescript projects with linter-enforced architecture and dag-driven scaffolding

one ~260kb zig binary, zero runtime dependencies

most projects treat folders as glorified buckets with hidden social contracts

nothing stops a component from reaching into the database layer, or a service from handling presentation logic

grimuah gives every folder an identity, an import firewall, and enforceable obligations

the import graph is declared in `architecture.config.json`

`grimuah check` validates every import against this graph

imports flow from deep surfaces to shallow ones, never back

the graph stays acyclic

the rest is scaffolding, lint rules, and a chef's kiss

---

## table of contents

- [quickstart](#quickstart)
- [core principles](#core-principles)
- [the four rule layers](#the-four-rule-layers)
- [identity](#identity)
- [surfaces](#surfaces)
- [innate members](#innate-members)
- [the dag in practice](#the-dag-in-practice)
- [the enforcement tiers](#the-enforcement-tiers)
- [presets and commands](#presets-and-commands)

---

## quickstart

### install

grab the prebuilt binary from [releases](https://github.com/CadeXLegend/grimuah/releases), or build from source

```sh
git clone https://github.com/CadeXLegend/grimuah.git
cd grimuah
zig build -p ~/.local
```

requires zig 0.16

the binary lands in `~/.local/bin/grimuah`

make sure that directory is on your PATH

### summon a project

```sh
grimuah summon my-project --preset webapp
cd my-project
pnpm install
```

`init` and `summon` are the same command

pick whichever flavour you like

`summon` scaffolds:

- the folder structure
- the architecture config
- the biome config
- the tsconfig
- `package.json`
- `.gitignore`
- husky pre-commit hooks
- the GritQL rule files

five presets ship with the binary: `default`, `webapp`, `cli`, `backend`, `bot`

no `--preset` flag means the default preset

up to six yes or no questions add optional surfaces on top

### enforce the architecture

```sh
grimuah check        # pre-passes plus biome lint, both must pass
grimuah add guard    # new surface, rules regenerate
grimuah upgrade      # sync to the closest preset
```

to enforce the architecture on every commit, add `grimuah check` to the husky pre-commit hook

```sh
# .husky/pre-commit
pnpm typecheck
grimuah check
```

`grimuah check` runs biome lint itself, so it replaces the `pnpm lint` line

other commands are documented in [presets and commands](#presets-and-commands)

---

## core principles

### everything must justify its existence

no speculative abstractions, no pattern applied before its scale earns it

a folder with one file has not earned its place as a surface

it is a leaf node that belongs at a higher scope

a config option that never changes is not config

it is a hardcoded value with extra indirection

a lint rule that never fires is noise

justification does not mean aggressive deletion

it means awareness

every surface, every file, every abstraction should carry a mental note of why it exists

when the justification is gone, the thing should go with it

### identity defines the boundary

a folder that only groups files by category is a bucket

buckets are managed through hidden social contracts

so instead of buckets, we use identities

identity has three parts

- **naming contract**: a file's suffix must match its folder's name
- **contractual obligation**: the file must follow its surface's rules
- **scope of operation**: the file operates within its surface's linguistic boundary

the suffix tells you the role, the contract tells you the rules, the scope tells you the responsibility

without identity, every folder is equally addressable

there is no structural reason one folder should not import from another

with identity, the boundary is declared and enforced

### co-location is the default, abstraction is the exception

types live next to the surface that owns them

config lives next to the code that reads it

tests live next to the code they test

patterns live next to the surface that matches them

lifting to a shared location is a deliberate act, gated by proven need

the shallowest common ancestor rule governs when sharing is warranted

two surfaces that need the same type lift it to their shared parent

they do not lift it to a global namespace

a type in a central `types/` folder is accessible to the entire project, whether it belongs there or not

a type in `services/subscription.types.ts` is accessible only to surfaces with an edge to `services/`

scoping is the default, exposure is earned

### living rules over documentation

architecture that is not enforced is aspirational

a style guide in a wiki decays with every PR

a rule that blocks a violating import before it lands is worth a hundred paragraphs of documentation

this generator encodes architectural rules as static analysis

the import graph is declared in `architecture.config.json`

file naming, suffix conventions, and surface membership are checked by CLI pre-passes

AST-level patterns are enforced by GritQL plugins running in Biome

---

## the four rule layers

architectural rules are grouped into four layers

each layer targets a distinct class of problem

each layer can be toggled independently in `architecture.config.json`

a project can adopt the layers it needs without committing to all four at once

### cosmetic

surface-level readability and naming consistency

| Rule                                                                               | Why                                                                                                                                                                             |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Files must use a suffix declared for their surface                                 | a `.handler.ts` file in `services/` violates the surface's suffix list                                                                                                          |
| Centralised `config/`, `types/`, or `models/` directories under `src/` are flagged | these group by category instead of by identity                                                                                                                                  |
| Em-dashes are banned in strings, templates, and comments                           | they serve no structural purpose and create inconsistency across the codebase                                                                                                   |

### structural

graph integrity and surface membership

| Rule                                                                                             | Why                                                                                                                                           |
| ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| The import firewall blocks files from importing from surfaces not in their `allowedImports` list | a component importing directly from a database repository is a structural violation                                                           |
| Innate members inherit their hosting surface's depth and dagOrder                                | a `.types.ts` file in `components/` cannot be imported by `services/` because it sits deeper in the graph                                      |
| Surfaces with a single file trigger a warning                                                    | a folder with one file has not earned its place as a surface, the file could be lifted to a higher scope                                      |

this layer is the core of the architecture

without it the graph is aspirational, with it every import is validated against the declared DAG

### resilience

change-proofing patterns that prevent codebase fractures over time

| Pattern                           | Replacement                            | Why                                                                                                                                                          |
| --------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `switch`                          | Dispatch table using `Record` or `Map` | a switch decouples the discriminant from its handler, every new case requires editing an existing block, exhaustiveness becomes a runtime concern            |
| C-style `for`                     | `map`, `filter`, `reduce`, `for..of`   | every for loop re-implements a generalised operation, a named operator has a clear contract and known semantics                                              |
| `let`                             | `const`                                | a `let` binding signals mutability without saying what mutates or why, `const` makes the invariant explicit at the declaration site                           |
| `null`                            | `undefined`                            | `undefined` is the language's native signal for absence, using it aligns with the language's fundamental construction                                        |
| `as any`                          | Proper types                           | `as any` removes the type system at the call site that needs it most, the unchecked value erases type information for every downstream consumer               |
| Chained `as unknown as T`         | Single cast                            | two casts first erase all type information, then assert a specific type, bypassing every structural safeguard the compiler provides                           |
| Proxy re-exports                  | Direct imports                         | a pass-through file creates an indirect dependency, the consumer is coupled to a file that hides the original module behind an indirection                    |
| `const + as const + keyof typeof` | `enum`                                 | five lines of boilerplate with a self-referential type alias, an enum provides the same with better tooling and no type gymnastics                           |
| `==`                              | `===`                                  | loose equality coerces both sides, making `0 == ''` and `false == '0'` true, strict equality compares type and value matching the programmer's mental model   |

### behavioural

runtime safety and error handling discipline

| Rule                                 | Why                                                                                                                                                                                        |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `throw` is banned                    | every fallible operation returns `Outcome`, a discriminated union narrowed on `succeeded`, this makes error handling explicit at every call site                                   |
| Bare `catch {}`                      | an empty catch swallows every error, including ones the developer did not anticipate, there is no path to observability or recovery                                                        |
| `catch { $_ }`                       | a discarded parameter does not make the silence acceptable, same structural problem as a bare catch, with the added misdirection of naming the ignored error                               |
| Input validation at trust boundaries | untrusted input causes most runtime failures in practice, validating at the boundary stops malformed data from reaching deeper layers where the original context is lost                    |

---

## identity

identity describes the structural role a file plays in the codebase

defining identity for a folder means encoding three things

**naming contract**: any file in this set must be named with a suffix matching the folder's name

a service file has `.service.ts`, a component file has `.component.ts`

the suffix tells you the role before you open the file

**contractual obligation**: the file must follow the rules of its surface

a service does not throw errors, it returns `Outcome`

a component does not import from deeper surfaces than its own

these are not recommendations, they are enforced by a static check

**scope of operation**: the file operates within what the surface's name means linguistically

a service orchestrates business logic, a component renders presentation, a guard checks permissions

when the scope is clear, so is responsibility

consider `sync-subscription.service.ts` in `services/`

the suffix tells you it is a service

its contract says it returns outcomes instead of throwing

its scope says it orchestrates subscription logic

it does not render UI, does not write raw database queries, does not define its own permission model

three pieces of information available before you read a single line of implementation

a folder with identity stops being a bucket and becomes a boundary

the boundary has rules, everything inside is subject to them

---

## surfaces

a folder with identity is a surface

a surface is a boundary with declared rules about what lives inside, who can cross the boundary, and what obligations the citizens carry

think of `src` as a set

each subfolder is a subset at a specific resolution

`services/` is the set of service-citizens, `components/` is the set of component-citizens

the two sets do not share edges by default

a citizen of a surface inherits three things from its hosting surface

**identity**: the citizen must match the surface's naming contract, contractual obligation, and scope

a file cannot call itself a service-citizen if it is named `*.component.ts`

**position**: the citizen sits at the surface's depth in the filesystem and its order in the import DAG

depth controls where the directory lives, dagOrder controls who can import from whom

depth and dagOrder are two distinct parameters because the file tree and the dependency graph are different things

**constraints**: the citizen may only import from surfaces listed in the surface's `allowedImports`

the citizen's own exports flow downstream to surfaces with a higher dagOrder, never upstream

this creates a directed graph where every edge carries a contract

when `services/` exports a type consumed by `components/`, that type defines the shape of data crossing the edge

the consumer depends on the producer

the producer cannot depend on the consumer

here is the default graph

```mermaid
graph LR

    L[lib/] --> U[utils/]

    L --> S[services/]

    L --> C[components/]

    U --> S

    S --> C

    C --> P[pages/]
```

each arrow is an allowed import direction

components can import from services, the reverse is a structural violation

surfaces at the same dagOrder level do not see each other unless explicitly configured

the graph is not documentation

it is declared in `architecture.config.json`

`grimuah check` validates every import against it

---

## innate members

some file types do not have a natural home in any single surface

a type definition belongs to the surface that owns the data, not to a global `types/` folder

config belongs to the surface that uses it, not to a central `config/` directory

tests belong alongside the code they test, not in a separate `tests/` tree

regex patterns belong to the surface that matches them, not in a shared `regex/` file

the traditional approach creates a folder for each of these

the grimuah approach is different

these file types become citizens of whichever surface needs them

they follow the same naming rules, import constraints, and scope obligations as any other citizen

they provide only the context and nuance required to justify their existence

there are four such types

**`.types.ts`**: type definitions and contracts

when `services/` defines a `SubscriptionStatus` type, it lives in `services/subscription.types.ts`

the type inherits the surface's dagOrder

it cannot be imported by surfaces with a lower dagOrder

**`.config.ts`**: config, constants, and enums

config lives next to its consumer

a config file follows the same import constraints as any other file in its surface

**`.spec.ts`**: tests

tests live alongside the code they test

lifting tests to a central `tests/` directory breaks the co-location principle

**`.regex-patterns.ts`**: documented regular expressions in a single source of truth

every regex is a named constant with a JSDoc comment explaining what it matches

no inline regex littered through the surface's code

innate members inherit their hosting surface's depth and dagOrder

a type defined in `components/` cannot be imported by `services/`

it is not a global type, it is a local contract

the shallowest common ancestor rule governs sharing

if a type is needed by two sibling surfaces, lift it to their shared parent

if `services/` and `components/` both need the same type, it moves to `lib/` or the appropriate utility surface

the type never moves downward

moving a type up is a deliberate act of sharing, not the default position

---

## the dag in practice

### depth and dagOrder

two parameters control where a surface sits in the project

**depth** is physical, it describes where the directory lives in the file tree

`lib/` at the project root has depth 0, `src/services/` has depth 1

this is purely filesystem layout

**dagOrder** is logical, it describes where the surface sits in the import DAG

a surface with dagOrder 3 can import from surfaces with dagOrder 0, 1, or 2

it cannot import from dagOrder 4, 5, or 6

depth and dagOrder are independent because the file tree and the dependency graph are different things

multiple surfaces can share the same file depth with different dagOrders

`utils/` and `services/` are both at depth 1

`utils/` has dagOrder 0 and `services/` has dagOrder 1

services can import from utils, utils cannot import from services

the file tree has nothing to do with it

here is the default graph for a webapp preset

```mermaid
graph LR

    L[lib/\ndepth 0, dagOrder 0] --> U[utils/\ndepth 1, dagOrder 0]

    L --> S[services/\ndepth 1, dagOrder 1]

    L --> C[components/\ndepth 1, dagOrder 2]

    L --> P[pages/\ndepth 1, dagOrder 3]

    U --> S

    S --> C

    C --> P
```

each arrow is an allowed import direction

surfaces at the same dagOrder do not share an edge unless `allowedImports` explicitly lists it

`utils/` and `services/` are at different dagOrders so the edge runs one way

two surfaces at the same dagOrder would not see each other at all

### allowed imports

the `allowedImports` field on each surface declares which surfaces it may import from

this is the edge table of the graph

```json
{
  "name": "services",
  "path": "src/services",
  "depth": 1,
  "dagOrder": 1,
  "suffixes": [".service.ts", ".config.ts"],
  "innateMembers": [".types.ts", ".config.ts", ".spec.ts"],
  "allowedImports": ["utils"]
}
```

this declaration says that `services/` may import from `utils/`

any import from `services/` to any other surface is a structural violation

every edge in the DAG is declared here, there is no implicit connectivity between surfaces

### the config file

the full `architecture.config.json` includes surfaces, layers, and an optional rootLib

grimuah generates this file into every scaffolded project, it is not part of this repository

```json
{
  "surfaces": [
    {
      "name": "utils",
      "path": "src/utils",
      "depth": 1,
      "dagOrder": 0,
      "suffixes": [".util.ts", ".config.ts"],
      "innateMembers": [".types.ts", ".config.ts", ".spec.ts", ".regex-patterns.ts"],
      "allowedImports": []
    },
    {
      "name": "services",
      "path": "src/services",
      "depth": 1,
      "dagOrder": 1,
      "suffixes": [".service.ts", ".config.ts"],
      "innateMembers": [".types.ts", ".config.ts", ".spec.ts"],
      "allowedImports": ["utils"]
    },
    {
      "name": "components",
      "path": "src/components",
      "depth": 1,
      "dagOrder": 2,
      "suffixes": [".component.ts", ".config.ts"],
      "innateMembers": [".types.ts", ".config.ts", ".spec.ts"],
      "allowedImports": ["utils", "services"]
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

the config is the single source of truth for the architecture

the CLI reads it to validate imports, check naming, and run pre-passes

the [schema](architecture.schema.json) validates it at authoring time with editor autocomplete

the same schema runs during every `grimuah check`

there is no second config file, no hidden convention, no documentation that contradicts the graph

---

## the enforcement tiers

architectural rules fall into two tiers that compose into a single check run

not all rules can be enforced at the same level

### tier one: GritQL plugins

AST-level rules run inside Biome as GritQL plugins

these operate on the parsed syntax tree and detect patterns in the code itself

the resilience and behavioural layers are enforced here

switch statements, c-style for loops, let bindings, null literals, `as any` casts, chained casts, proxy re-exports, const-as-enum patterns, and loose equality are detected by matching their AST structure

throw statements, bare catches, and silent discards are detected the same way

each layer produces a `.grit` file in `.grimuah-rules/` referenced from `biome.json`

the plugins ship with every scaffolded project and run as part of `biome lint`

### tier two: CLI pre-passes

file-path-level rules run as CLI pre-passes before Biome is invoked

these operate on the filesystem and file content rather than the syntax tree

the cosmetic and structural layers rely on this tier for rules that GritQL cannot express

| Pre-pass                        | What it checks                                                                                               |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Folder suffix validation        | Every file in a surface directory must use one of the surface's declared suffixes or an innate member suffix |
| Centralised directory detection | Directories named `config/`, `types/`, or `models/` under `src/` are flagged                                 |
| Import firewall                 | Every import in every file is resolved to a surface and checked against the surface's `allowedImports` list  |
| Innate member depth scoping     | A `.types.ts` file in a deeper surface cannot import from or be imported by a shallower surface              |
| Singleton warnings              | Surfaces containing exactly one file trigger a warning                                                       |

the import firewall pre-pass extracts imports by scanning file content for six import patterns

it handles multi-line imports, dynamic imports, side-effect imports, and backslash-escaped paths

this is a linear scan, not a full parser

it covers the patterns that appear in practice

### how they compose

`grimuah check` runs the CLI pre-passes first, then invokes `biome lint`

both must pass for the check to succeed

each tier enforces the rule layers that are enabled in `architecture.config.json`

if structural is disabled, the pre-pass skips the import firewall and singleton checks

if resilience is disabled, Biome skips the `.grit` file for that layer

---

## presets and commands

### presets

five presets ship with the binary

each preset defines a surface configuration for a common project archetype

| Preset  | Surfaces                                            | Root lib |
| ------- | --------------------------------------------------- | -------- |
| default | utils, services, components                         | No       |
| webapp  | lib, utils, services, components, pages             | Yes      |
| cli     | lib, utils, services, commands                      | Yes      |
| backend | lib, db, middleware, services                       | Yes      |
| bot     | lib, db, services, middleware, components, commands, tasks, handlers | Yes      |

no `--preset` flag uses the default preset

interactive refinement adds optional surfaces not already in the chosen preset

the tool asks up to six yes or no questions covering lib, db, pages, commands, middleware, and tasks

each question is skipped when the surface is already present in the preset

adding lib shifts it to depth 0 and shifts existing surfaces down

adding middleware inserts it between services and components in the DAG order

### commands

**`init [name] [--preset <name>]`** (alias `summon`)

scaffolds a new project: folder structure, architecture config, biome config, tsconfig, `package.json`, `.gitignore`, husky pre-commit hooks, and generated GritQL rule files

interactive refinement asks only about surfaces not already in the chosen preset

templates produce output that passes Biome format without modification

**`check`**

runs CLI pre-passes for cosmetic and structural rules, then invokes `biome lint` for resilience and behavioural rules

both tiers must pass for a zero exit code

pre-passes can be skipped by disabling the corresponding layer in the config

**`add <surface-name>`**

creates a new surface directory with an example file, updates `architecture.config.json`, and regenerates GritQL rules

suffixes come from a name heuristic:

- `validators` → `.validator.ts`
- `guards` → `.guard.ts`
- `states` → `.state.ts`
- `repositories` → `.repo.ts`
- anything else → `.<singular>.ts`

every surface also gets `.config.ts`

**`remove <surface-name>`**

deletes the surface directory

strips the surface from `architecture.config.json`, including every `allowedImports` entry across all surfaces

compacts the dagOrder values

regenerates GritQL rules

**`upgrade`**

detects the closest matching preset

adds any preset surfaces not already in the current config

preserves user modifications, including layer toggles and custom surfaces

reports when the config is already up to date
