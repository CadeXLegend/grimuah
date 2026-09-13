# Changelog

All notable changes to this project will be documented in this file. See [commit-and-tag-version](https://github.com/absolute-version/commit-and-tag-version) for commit guidelines.

## [Unreleased]

### ⚠ BREAKING CHANGES

* biome is gone. `grimuah check` no longer takes `--biome` and spawns no subprocess, and `init` writes no `biome.json` and no `.grimuah-rules/` directory. A project that wants biome's own recommended ruleset now runs biome itself, and a project that wants the old GritQL plugin files keeps its own copy. The generated `package.json` drops the `lint` and `format` scripts in favour of `check` running `grimuah check`, and the generated husky hook drops `pnpm lint` and `format-on-commit.sh`.

### Features

* enforce every rule in-process and freeze the findings biome validated in `tests/oracle/`, so the corpus check runs without biome
* add `require-enum-over-literal-union`: a union of two or more string literals must be a string enum. a type alias, a property, a parameter and a variable annotation are read, and a return annotation is not. the module has to be named `<name>.<kind>.ts`, because a process entry script cannot use an enum at runtime
* add `no-optional-properties`: an object type may not declare an optional property. an interface, a type literal, an `as` assertion's type and a `declare module` block are read, and an optional parameter, a class field and an optional method are not
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
