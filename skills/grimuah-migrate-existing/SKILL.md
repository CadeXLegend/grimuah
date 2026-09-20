---
name: "grimuah-migrate-existing"
description: "Adopt grimuah inside an existing TypeScript repository, layer by layer, without a big-bang rewrite: build the config, register existing directories as surfaces, rename to suffixes, and turn the layers on as the code converges."
version: 1
created: "2026-09-20"
updated: "2026-09-20"
---
## When to Use
Use this skill when the repository already exists and grimuah must move in: a legacy `src/` tree, a service that predates the rules, or a monorepo where only one package is ready to be gated.

Do not use it for a greenfield project, where scaffolding is faster (that is the setup skill).

## Procedure
1. Inventory the trees before touching anything. List the top-level source directories and what each one does, and note which ones already have a single role (routers, repositories, UI) and which are drawers holding everything. The drawers are the ones that need split work rather than a surface entry.

2. Generate a reference config in a scratch directory, so the templates come from the binary rather than from memory: `grimuah summon scratch --preset backend` in `/tmp`. Keep the scratch project's `architecture.config.json`, `architecture.schema.json`, `.husky/pre-commit` and `.husky/check-em-dash.sh`, and take its `tsconfig.json` only as a reference. Do not overwrite your own `tsconfig.json` or `package.json`.

3. Put the config, the schema, and the hooks into the repository root and commit them, so the migration has a baseline. `grimuah check` reads `architecture.config.json` from the current directory, so it must run at the repo root. Add `"check": "grimuah check"` to the existing `package.json` scripts, keeping whatever name the project already uses for other gates.

4. Declare what gets linted first, because this is the lever that makes the migration incremental. `sourceRoots` lists the trees grimuah looks at, and `rootLib` adds one shared root. Only paths under those roots are linted at all, so a repo with a legacy `scripts/` or a generated `vendor/` tree can simply not declare it. Start with the one subtree you intend to converge this week, and extend `sourceRoots` as each tree goes clean. A config with no `sourceRoots` derives one lint root per surface instead.

5. Register the existing directories as surfaces with `grimuah add <surface> --path <dir>`, once per directory you keep. This registers the path in the config, appends the surface at the deepest `dagOrder`, and writes an `example<suffix>.ts` into the directory. Delete that example file immediately in an existing directory, it is generator noise there.

6. Start with the layers that describe the shape of the code, not the code itself:

| Stage | Layers | What it asks of you |
| ----- | ------ | ------------------- |
| 1 | `cosmetic`, `structural` | file names, file locations, and the direction of imports |
| 2 | plus `resilience` | rewrite `let`, `switch`, C-style `for`, `==`, `null`, `as any`, `as const` |
| 3 | plus `behavioural` | convert `throw` into returned outcomes, handle every `catch` |
| 4 | plus the pre-commit gate | add `grimuah check` to the hook once the tree is clean |

Set the stage in `architecture.config.json` by turning the not-yet-adopted layers off. Nothing else changes, and the checks that do run report the truth about the tree.

7. Land stage one as one mechanical pass per surface: rename files to the surface's suffixes (`.service.ts`, `.repo.ts`, `.component.ts`, `.util.ts`), update the imports that named the old paths, and dissolve any central `config/`, `types/` or `models/` directory into the surfaces that consume its contents. That last step is the one that usually changes the code rather than the paths, and it is worth splitting across pull requests per surface.

8. Give every surface two or more files as you go, since the singleton rule reports a one-file surface and an empty one. A directory whose single file is real has three honest endings: it gains a second real file, it merges into the surface that consumes it, or it stops being a surface and its file moves somewhere that is.

9. Land stage two file by file, since each banned construct is a local rewrite: `let` to `const` (a module-level mutable cache is the one exception the rule allows), `switch` to a `Record` dispatch table, `for (;;)` to `map`/`filter`/`reduce`/`for..of` where the loop does not accumulate, `null` to `undefined` (keeping `null` only where a third-party boundary returns it), `as any` to the type you mean, and `{ ... } as const` to an enum in the surface's `.config.ts`.

10. Land stage three last, because it is the only stage that changes function signatures. Move the shipped `lib/outcome.ts` in as-is, then convert the fallible functions one surface at a time, starting at the deepest surface so the callers can be updated in the same pass.

11. Turn `grimuah check` on in the pre-commit hook only when the tree is clean, and keep the hook's existing commands. Until then, run it in CI as an informational step or not at all, but never as a blocking gate that everyone learns to bypass.

## Pitfalls
- The generator leaves one `example<suffix>.ts` per added surface. Delete it in an existing directory, and remember the surface still counts as a singleton until a real second file lands.
- `grimuah add` never moves or renames files. Registering a surface and renaming its contents are two separate passes.
- `grimuah check` in a directory with no config, or in a subdirectory of the repo, does not walk upward looking for one. Run it at the root.
- Turning a layer off does not silence the surface and edge model entirely: the firewall and singleton checks live in the pre-pass tier, and the structural toggle is the switch over them, so keep `structural` on from stage one.
- A `depth` value that does not match the real nesting is harmless, while `dagOrder` decides what the firewall allows. Expect to spend the time on `dagOrder` and to leave `depth` approximate.
- Monorepo paths work as surfaces exactly as they are: `packages/core` and `apps/web` are legal surface paths, and each needs a place in the `dagOrder` sequence.
- An import firewall failure in a legacy tree is usually a real cycle or a genuine layering violation, not a config gap. Adding `allowedImports` entries until it goes quiet converts the gate into decoration, so fix the direction instead.
- The 500-line file limit and the duplication family will fire constantly on old code. They are warnings, so they do not block the migration, but extracting the shared helper once clears several of them at a time.

## Verification
1. `grimuah check` exits 0 at the repository root, with every remaining printed line deliberate.
2. `pnpm typecheck` exits 0, which proves the renames did not break imports.
3. Every adopted tree is covered by a `sourceRoots` entry or the `rootLib` path, and every tree left out is left out on purpose.
4. Every surface in the config holds two or more files, or has been removed from the config.
5. The commit or pull request that turns a layer on says which layer and which surface it covered.
