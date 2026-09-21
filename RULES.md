# rules

every rule `grimuah check` can report, grouped by the layer that gates it

[README.md](README.md) has the quickstart, [CONCEPTS.md](CONCEPTS.md) defines the surfaces and the dag, and [PHILOSOPHY.md](PHILOSOPHY.md) explains why the rules exist

51 rules ship today: 46 project rules across four configurable layers, plus 5 hygiene rules that run whenever the engine runs

---

## table of contents

- [the layers](#the-layers)
- [severity](#severity)
- [cosmetic](#cosmetic)
- [structural](#structural)
- [resilience](#resilience)
- [behavioural](#behavioural)
- [hygiene](#hygiene)
- [turning a single rule off](#turning-a-single-rule-off)
- [listing the rules](#listing-the-rules)

---

## the layers

architectural rules are grouped into four layers, and each layer targets a distinct class of problem

each layer can be toggled independently in `architecture.config.json`, so a project can adopt the layers it needs without committing to all four at once

a fifth layer, hygiene, holds the curated rules that catch dead code and stale bindings

it has no toggle of its own and runs whenever the engine runs

| Layer       | Toggleable | What it targets                                                                     |
| ----------- | ---------- | ----------------------------------------------------------------------------------- |
| cosmetic    | yes        | surface-level readability, naming consistency, and copy hygiene                      |
| structural  | yes        | graph integrity, surface membership, and the shape of the import graph               |
| resilience  | yes        | change-proofing patterns that keep the codebase from fracturing over time            |
| behavioural | yes        | runtime safety and error-handling discipline                                         |
| hygiene     | no         | unused bindings, single-assignment `let`, constant conditions, and unreachable code  |

---

## severity

every rule carries a severity

| Severity | Effect                                                        |
| -------- | ------------------------------------------------------------- |
| `error`  | the finding fails the run and the exit code is non-zero        |
| `warn`   | the finding is printed, and the run still exits clean          |

warnings are printed even when nothing else failed, because a lint gate that reports less than it knows is the one failure this engine is built to avoid

---

## cosmetic

surface-level readability and naming consistency

| Rule                             | Severity | What it enforces                                                                                                              |
| -------------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `em-dash`                        | error    | strings, templates, and comments carry no em-dashes, use commas, colons, or sentence breaks instead                            |
| `lowercase-copy`                 | warn     | user-facing copy in a `.config.ts` starts with a capital letter                                                                |
| `duplicated-user-facing-copy`    | warn     | a sentence written in three or more files lives once in the owning `.config.ts`, or as a named constant while that config is not yet earned |
| `repeated-inline-copy`           | warn     | a sentence written twice in one file is declared once as a named constant, or in the owning `.config.ts` once that config is earned |
| `literal-duplicating-config-value` | warn   | a literal retyping a value the surface's own `.config.ts` declares references the enum member instead                          |

the two copy rules name the owning `.config.ts` only once the file's own vocabulary earns one, as `enum-placement` does

[CONCEPTS.md](CONCEPTS.md#innate-members) defines what earns it

---

## structural

graph integrity and surface membership

| Rule                       | Severity | What it enforces                                                                                                                                    |
| -------------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `config-behaviour`         | warn     | a `.config.ts` declares data, never a function, so behaviour moves to the surface's own module                                                       |
| `enum-placement`           | warn     | an exported enum in an implementation module moves to the surface's `.config.ts`, once the file's vocabulary earns one                                |
| `import-cycle`             | error    | two files that import each other are a cycle, because module initialisation order becomes load-bearing                                              |
| `redundant-allowed-import` | warn     | an `allowedImports` entry the dag already permits is dead configuration and is deleted                                                               |
| `shared-type-placement`    | warn     | a type an implementation module exports and another directory imports moves to the surface's `.types.ts`                                             |
| `export-without-consumer`  | warn     | an exported binding no other module names drops its `export` keyword                                                                                 |

the import firewall, the folder suffix check, the singleton warning, and the innate member scoping are not rules

they belong to the surface and edge model itself, and the structural layer is the only switch over them

[CONCEPTS.md](CONCEPTS.md#the-enforcement-tiers) covers that pre-pass tier

---

## resilience

change-proofing patterns that prevent codebase fractures over time

### banned constructs

| Rule                  | Severity | Replacement                                        |
| --------------------- | -------- | -------------------------------------------------- |
| `null-literal`        | error    | `undefined`, with third-party boundaries the exception |
| `let-declaration`     | error    | `const`, with module-level mutable caches the exception |
| `switch-statement`    | error    | a `Record` or `Map` dispatch table                  |
| `imperative-for-loop` | error    | `map`, `filter`, `reduce`, or `for..of`             |
| `loose-equality`      | error    | `===` and `!==`                                     |
| `as-any`              | error    | the type you mean                                   |
| `any-type`            | error    | the type you mean, including `any[]` and `Array<any>` |
| `chained-cast`        | error    | a single cast                                       |
| `proxy-reexport`      | error    | a direct import from the source module              |
| `as-const`            | error    | an enum                                             |

### size and complexity

| Rule                       | Severity | Limit                                                                     |
| -------------------------- | -------- | ------------------------------------------------------------------------- |
| `max-nesting-depth`        | warn     | three layers of statement nesting inside one function, method, or class body |
| `max-parameters`           | warn     | four parameters, with a destructured parameter counting as one slot        |
| `max-function-lines`       | warn     | 80 lines in one function body                                              |
| `max-file-lines`           | warn     | 500 lines in one module                                                    |
| `max-cyclomatic-complexity` | warn    | 15 independent paths in one function                                       |

### type shape

| Rule                           | Severity | What it enforces                                                                                    |
| ------------------------------ | -------- | --------------------------------------------------------------------------------------------------- |
| `literal-union-enum`           | warn     | a union of two or more string literals becomes a string enum                                        |
| `optional-property`            | warn     | an object type declares no optional property, default it at the boundary or model a discriminated union |
| `readonly-collection-signature` | warn    | a parameter, return type, or property is `readonly T[]` or `ReadonlyArray<T>`                       |
| `readonly-type-member`         | warn     | every property of a type literal is `readonly`                                                       |

### control flow and data

| Rule                       | Severity | What it enforces                                                                              |
| -------------------------- | -------- | --------------------------------------------------------------------------------------------- |
| `boolean-flag-argument`    | warn     | a call passes no bare `true` or `false`, name the behaviour instead                           |
| `nested-ternary`           | warn     | a conditional expression contains no second conditional expression                            |
| `unbounded-collection-read` | warn    | a query that reads a collection carries a LIMIT                                              |
| `for-of-accumulation`      | error    | a `for..of` loop builds no array by pushing into it                                           |
| `if-chain-dispatch`        | warn     | a run of three or more branches over one subject becomes a dispatch table                      |
| `scalar-failure-return`    | warn     | an exported async operation returns an outcome value rather than a bare boolean or number      |

### duplication

| Rule                        | Severity | What it enforces                                                                                     |
| --------------------------- | -------- | ---------------------------------------------------------------------------------------------------- |
| `duplicated-function-body`  | warn     | a byte-identical function body in two files becomes one shared declaration                            |
| `duplicated-statement-text` | warn     | the same statement, such as a SQL query, written twice becomes one module-level constant              |
| `duplicated-computation`    | warn     | the same expression written in two files becomes one shared function                                   |
| `renamed-duplicate-body`    | warn     | one body declared under two names in two files is one implementation, lifted into one shared place     |

---

## behavioural

runtime safety and error-handling discipline

| Rule                    | Severity | What it enforces                                                                                                                          |
| ----------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `throw-statement`       | error    | every fallible operation returns `Outcome`, a discriminated union narrowed on `succeeded`                                                  |
| `bare-catch`            | error    | an empty catch logs the error or returns an `Outcome`, because a bare catch swallows every error                                            |
| `silent-catch`          | warn     | a discarded catch parameter is the same silence with misdirection, so the error is handled or logged                                       |
| `await-in-loop`         | warn     | a loop body does not await in sequence, map the items to promises and await `Promise.all` once                                              |
| `discarded-outcome`     | warn     | a call returning an `Outcome` has its result read, or the failure branch is unreachable                                                     |
| `unread-scalar-result`  | warn     | a call declared `Promise<boolean>` or `Promise<number>` has its result read, or the callee narrows to a `void` result                       |

input validation at trust boundaries is a project obligation rather than a rule, because the boundary is where the untrusted data arrives and only the project knows where that is

---

## hygiene

the curated rules that catch dead code and stale bindings

they have no toggle of their own and run whenever the engine runs

| Rule                | Severity | What it enforces                                              |
| ------------------- | -------- | ------------------------------------------------------------- |
| `unused-import`     | warn     | an imported binding is named somewhere in the file            |
| `unused-variable`   | warn     | a declared binding is read somewhere in the file              |
| `prefer-const`      | warn     | a `let` binding that is assigned once becomes a `const`       |
| `constant-condition` | error   | a condition does not always evaluate to the same value        |
| `unreachable-code`  | error    | every statement can be reached                                |

---

## turning a single rule off

each layer is a category, and every rule inside one has its own name

a rule runs unless the config names it, so a project that wants `switch` back keeps every other resilience rule

```
"layers": {
  "resilience": true
},
"rules": {
  "switch-statement": false,
  "max-file-lines": false
}
```

the layer is the gate and a rule only narrows it, so a rule named on inside a layer that is off stays off

the `rules` object takes a boolean per rule, `false` turns the rule off and `true` is the default, so a config usually lists only the rules it silences

the hygiene rules have no layer of their own, so `rules` is the only switch they have

`architecture.schema.json` lists every rule name, so an editor autocompletes the key and marks one the table does not have

a name that matches no rule stops the check with the name it could not match, because a typo would otherwise leave the rule it meant to silence running

the surface and edge model is not a rule and carries no per-rule key

the suffix list, the import firewall, the dag order, and the innate member scoping are the declaration a project makes about itself, and their layer is the only switch over them

---

## listing the rules

`grimuah rules` prints the same list in the terminal, grouped by layer with each rule's name, severity, and the sentence it reports

it reads no config, so it answers the same question in every directory

```
grimuah rules
```

use it for a finding you are looking at, where you need the name that silences it rather than an explanation of the rule
