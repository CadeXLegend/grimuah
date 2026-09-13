# Changelog

All notable changes to this project will be documented in this file. See [commit-and-tag-version](https://github.com/absolute-version/commit-and-tag-version) for commit guidelines.

## [Unreleased]

### ⚠ BREAKING CHANGES

* biome is gone. `grimuah check` no longer takes `--biome` and spawns no subprocess, and `init` writes no `biome.json` and no `.grimuah-rules/` directory. A project that wants biome's own recommended ruleset now runs biome itself, and a project that wants the old GritQL plugin files keeps its own copy. The generated `package.json` drops the `lint` and `format` scripts in favour of `check` running `grimuah check`, and the generated husky hook drops `pnpm lint` and `format-on-commit.sh`.

### Features

* add `no-import-cycles`: two files that import each other are a cycle, even inside one surface, because a cycle makes module initialisation order load-bearing and lets a value read at module scope be undefined depending on which file the runtime reached first. this one is **error** severity, so it fails a build. the whole project's import graph is resolved before any verdict: a bare specifier, a path outside the source roots, a self-import, a dynamic `import()` and `export ... from` are all no edge at all, and a file reports its own first import that points back into its own component
* add `require-enum-in-config-file`: an exported enum in an implementation module is a configuration constant declared in the wrong place, because every consumer imports the module that owns the behaviour to read the vocabulary. a bare `export enum`, an `export declare enum` and an `export const enum` are all read, an `export` on a line of its own reports on that line, and an unexported enum, an enum inside a `declare module` block or a bare block, a `.config.ts`, a `.types.ts`, a `.d.ts`, a module with no behaviour kind and a module at the top of the tree are all out of scope. this is the first rule of the import and export graph group, and the first that reads a module's name as well as its declarations
* add `no-discarded-outcome`: a call that returns an Outcome may not be a bare statement, because the result is dropped before it is read and the failure branch becomes unreachable. the callee's declaration is looked up across the whole project, a member access by its last name, and a name two declarations disagree about is not reported
* add `no-unread-scalar-result`: a call whose declared result is `Promise<boolean>` or `Promise<number>` must have that result read. `void f()` states the dropped result on purpose, so it is reported as the same defect, and an assignment, a `Promise<void>` result and a disagreement between two declarations of one name are out of scope
* add `no-async-scalar-failure-return`: an exported async operation must not report its failure as a bare boolean or number, so a result declared `Promise<boolean>` or `Promise<number>` is what it reports on. a function declaration, an arrow and a function expression are all read, and an unexported operation, a non-async one and a result of any other type are out of scope
* enforce every rule in-process and freeze the findings biome validated in `tests/oracle/`, so the corpus check runs without biome
* add `require-enum-over-literal-union`: a union of two or more string literals must be a string enum. a type alias, a property, a parameter and a variable annotation are read, and a return annotation is not. the module has to be named `<name>.<kind>.ts`, because a process entry script cannot use an enum at runtime
* add `no-optional-properties`: an object type may not declare an optional property. an interface, a type literal, an `as` assertion's type and a `declare module` block are read, and an optional parameter, a class field and an optional method are not
* add `require-readonly-collection-signatures`: a parameter, a return type and an object type's property must not be a mutable array. a class field, a type alias and a local binding are out of scope, and `readonly T[]`, `ReadonlyArray<T>`, `undefined | T[]` and `() => T[]` are all left alone
* add `require-readonly-type-members`: every property of a type literal must be `readonly`. an interface's properties are never reported, which is the detector's own narrowing rather than an oversight
* add `any-type`: `any` used as a type is an error, wherever it stands: `: any`, `any[]`, `Array<any>` and a return annotation. `o.any` and `{ any: 1 }` are names rather than types, and the `as any` cast keeps its own message
* add `max-nesting-depth-three`: a statement container may not nest more than three layers deep inside one function, method or class body
* add `max-parameters`: a function may not declare more than four parameters, counted from the signature so a destructured parameter stays one slot
* add `require-capitalised-user-facing-copy`: user-facing copy in a `.config.ts` file must start with a capital letter
* add `no-boolean-flag-argument`: a call may not pass a bare `true` or `false`
* add `max-function-lines`: a function body may not run past 80 lines
* add `no-nested-ternary`: a conditional expression may not contain another one
* add `max-file-lines`: a module may not run past 500 lines, and a `.d.ts` file is out
* add `no-await-in-loop`: an `await` in a loop body serialises its iterations
* add `max-cyclomatic-complexity`: a function may not hold more than 15 independent paths
* add `require-limit-on-collection-reads`: a query that reads a collection must carry a LIMIT
* add `no-for-of-push-accumulation`: a `for..of` loop may not build an array by pushing into it
* add `config-declares-data-only`: a `.config.ts` file may declare data, never a function
* add `no-if-chain-dispatch`: a run of three or more branches over one subject is a dispatch table

### Bug Fixes

* stop scaffolding dead config: the presets and the `add` and `init` generators no longer write an `allowedImports` entry that the DAG already implies. a grant to a surface with a lower dagOrder comes from the graph itself, so all 42 entries in the shipped presets were entries `canImport` never read, and every config those presets generated carried them too. a same-dagOrder or a shallow-to-deep grant is still written down
* read JSX files again: a self-closing element consumed every byte after it, and a binding referenced only by a tag looked unreferenced, so `noUnusedImports` and `noUnusedVariables` now work on `.tsx` and `.jsx`
* report the escapes from two shipped bans: `as any[]` (and `as any | T`) is a `as any` cast, and `export * from` is a proxy re-export
* warn when a configured surface's directory is absent, where a typo in `architecture.config.json` used to disable the whole surface in silence

## [0.1.2](https://github.com/CadeXLegend/grimuah/compare/v0.1.1...v0.1.2) (2026-09-01)


### Bug Fixes

* update stale 'arch check' reference in structural.grit comment ([4eac8e0](https://github.com/CadeXLegend/grimuah/commit/4eac8e0543a899f919b9c8bb718d2f07537db073))

## [0.1.1](https://github.com/CadeXLegend/grimuah/compare/v0.1.0...v0.1.1) (2026-09-01)


### Bug Fixes

* rename .arch-rules to .grimuah-rules in repo config ([2e379ad](https://github.com/CadeXLegend/grimuah/commit/2e379ad57b70931af6e4ce8247babe043ccfa671))

## 0.1.0 (2026-09-01)


### Features

* dagOrder DAG with biome 2.5 GritQL and Outcome pattern ([5e899a3](https://github.com/CadeXLegend/grimuah/commit/5e899a3367ec11fd68b7b8da1a45baeb0e5b6f5f))
* extract architecture generator alpha from testbed project ([b095b92](https://github.com/CadeXLegend/grimuah/commit/b095b92ff3ea7582e146619b93af078c253cc455))
* rebrand as grimuah with summon alias and release pipeline ([9f7ea0d](https://github.com/CadeXLegend/grimuah/commit/9f7ea0d7e78a02e29e52010bf40fa4c58e0e7ea2))


### Bug Fixes

* generated projects biome-format-clean ([d2a8351](https://github.com/CadeXLegend/grimuah/commit/d2a835170b66800ede6a09562433e7c3276514c2))
* validation issues, biome 2.5 GritQL, unit and e2e tests ([324d879](https://github.com/CadeXLegend/grimuah/commit/324d879c3582689f6e181e08c9e626dff9e5f07c))
