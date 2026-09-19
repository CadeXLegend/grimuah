# philosophy

why grimuah is built the way it is

[README.md](README.md) has the quickstart, [CONCEPTS.md](CONCEPTS.md) defines the vocabulary, and [RULES.md](RULES.md) lists the rules

this document is the reasoning behind the rules, and behind the shape of the tool itself

---

## table of contents

- [everything must justify its existence](#everything-must-justify-its-existence)
- [identity defines the boundary](#identity-defines-the-boundary)
- [co-location is the default, abstraction is the exception](#co-location-is-the-default-abstraction-is-the-exception)
- [living rules over documentation](#living-rules-over-documentation)
- [the binary is the engine](#the-binary-is-the-engine)
- [language-agnostic by design](#language-agnostic-by-design)

---

## everything must justify its existence

no speculative abstractions, no pattern applied before its scale earns it

a folder with one file has not earned its place as a surface

it is a leaf node that belongs at a higher scope, and the singleton warning says so

a config option that never changes is not config

it is a hardcoded value with extra indirection

a lint rule that never fires is noise

justification does not mean aggressive deletion

it means awareness

every surface, every file, every abstraction should carry a mental note of why it exists

when the justification is gone, the thing should go with it

the same test applies to the tool

the rule engine exists because a project needs one lint gate, not one lint gate per plugin, and a rule that costs a syntax-tree traversal on every file whether or not it can match is a rule that has not justified its cost

---

## identity defines the boundary

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

[CONCEPTS.md](CONCEPTS.md#identity) defines the three parts in full

---

## co-location is the default, abstraction is the exception

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

---

## living rules over documentation

architecture that is not enforced is aspirational

a style guide in a wiki decays with every PR

a rule that blocks a violating import before it lands is worth a hundred paragraphs of documentation

this generator encodes architectural rules as static analysis

the import graph is declared in `architecture.config.json`

file naming, suffix conventions, and surface membership are checked by CLI pre-passes

AST-level and token-level patterns are enforced in-process by grimuah's own rule engine

the documentation in this repository is for the humans who need to understand the rules, not for the tool that enforces them

the config is the source of truth, and the schema travels with every project

---

## the binary is the engine

grimuah ships as one self-contained zig binary

a rule that needs a syntax tree does not shell out to a parser, and a rule that needs the whole project does not shell out to a linter

the front-end, the rule engine, and the pre-passes are all in the same process

this is a deliberate trade

the alternative is a plugin directory that has to stay in step with the tool that reads it, and a lint gate whose behaviour changes when a plugin version changes

that trade costs flexibility, and the engine pays it back with one thing a plugin architecture cannot offer: the rules and the mode that runs them are versioned together in the binary, so a project's findings are reproducible from the tool it pinned

---

## language-agnostic by design

the architecture rules are not about TypeScript

a DAG is a DAG in any language, a folder with an identity is a folder with an identity, and a surface that may not import from a deeper one is a structural statement rather than a syntax one

grimuah is built around that split

a front-end parses a language into a shared intermediate representation

the rules read the representation, not the source

every rule declares the languages it supports, so a rule with no language-specific syntax runs on any front-end that produces the same tree

TypeScript is the first front-end, because that is where the tool started and where the audience is today

it is not the boundary of the design

adding a language means adding a front-end beside `src/lang/ts.zig`, not rewriting the rules or the architecture config

the [schema](src/architecture.schema.json) and the CLI carry no TypeScript assumption beyond the suffixes a project chooses for itself
