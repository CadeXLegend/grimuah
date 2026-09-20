---
name: "grimuah-setup"
description: "Install grimuah and scaffold a project with it: binary install, preset choice, the interactive surface questions, and the exact state a fresh scaffold is in. Use when starting a new grimuah project, when choosing a preset, or when a fresh scaffold reports violations the first time check runs."
version: 1
created: "2026-09-20"
updated: "2026-09-20"
---
## When to Use
Use this skill to install the binary and to run `grimuah summon` (alias: `init`) for a new project. Also use it when a freshly scaffolded project reports findings on its first `grimuah check`, because that state is expected and this skill says why.

Do not use it for an existing TypeScript repo that must adopt grimuah, that is the migrate skill. Do not use it to decide what belongs in a surface, that is the architecture skill.

## Procedure
1. Install the binary. Grab a prebuilt build from the releases page, or build from source with `git clone https://github.com/CadeXLegend/grimuah.git && cd grimuah && zig build -p ~/.local` (needs zig 0.16). The binary lands in `~/.local/bin/grimuah`, so that directory must be on `PATH`. Each platform ships `release-safe` (every safety check kept, about 858 kb on linux x86_64, the recommended one) and `release-small` (checks removed, about 44% smaller and about 9% slower). A local `zig build` is a debug build with symbols and full panic traces, and it is about 4x slower, so do not judge `check` speed from it.

2. Pick the preset before you run anything.

| Preset  | Surfaces                                                              | Root lib |
| ------- | --------------------------------------------------------------------- | -------- |
| default | utils, services, components                                            | no       |
| webapp  | lib, utils, services, components, pages                                | yes      |
| cli     | lib, utils, services, commands                                         | yes      |
| backend | lib, db, middleware, services                                          | yes      |
| bot     | lib, db, services, middleware, components, commands, tasks, handlers    | yes      |

3. Scaffold: `grimuah summon my-project --preset webapp`. No `--preset` flag uses `default`. An unknown preset name stops with the five valid names. A surface that the preset already carries is not asked about, and the remaining optional surfaces are offered as up to six yes or no questions in this order: `lib`, `db`, `pages`, `commands`, `middleware`, `tasks`. Redirect stdin from `/dev/null` when a script must run unattended, every question then takes its default of no.

4. Read `architecture.config.json` before writing any code. It declares the surfaces, their `dagOrder`, their legal suffixes, their innate members, and their `allowedImports`, plus the four layer toggles and the `rootLib` block. The architecture skill explains what those fields mean.

5. Install dependencies and commit the scaffold as one commit, so the generator output and your first hand-written file stay separable later. `pnpm install` runs the generated `prepare` script, which wires husky.

6. Expect the first `grimuah check` to fail, and do not treat that as a broken install. `init` writes exactly one `example<suffix>.ts` per surface, and a surface holding one file is a leaf node the singleton rule reports. A three-surface `default` project prints three findings and exits 1 straight out of the generator. Each surface goes quiet once it holds a second real file, including an innate member such as `.types.ts` or `.config.ts`.

7. Keep `grimuah check` out of the pre-commit hook while the project is young. The scaffolded hook runs `pnpm typecheck` and `.husky/check-em-dash.sh` only, for exactly the reason in step 6. Add `grimuah check` to the hook once the repo is clean and stays clean.

8. Grow and shrink the project with the config commands rather than by hand. `grimuah add <surface> [--path <dir>]` creates the directory, a `example<suffix>.ts` file, and the config entry at the deepest `dagOrder`. `grimuah remove <surface>` deletes the directory and strips the surface from every `allowedImports` list. `grimuah upgrade` finds the closest preset, adds the surfaces it has and the project lacks, and leaves custom surfaces and layer or rule toggles alone.

9. Verify the install before writing code: `grimuah rules` prints the rule table, which proves the binary runs.

## Pitfalls
- `grimuah check` in a directory with no `architecture.config.json` prints that it could not load the config and tells you to scaffold, it does not lint anything else.
- The `default` preset has no `rootLib`, so it has no `lib` surface and no `lib/outcome.ts`. A project that wants the outcome pattern needs a preset with `rootLib` enabled, or an added surface.
- `grimuah add` writes `// TODO: implement` as the example file body. A surface left with only that file still fails the singleton check, and the comment is not a plan.
- The generated `.gitignore` ignores `.pi` and `.rpiv`, and keeps `.env.example` while ignoring the other `.env` files.
- The generated `package.json` declares only husky, typescript and commit-and-tag-version. Nothing else, no test runner and no bundler, so add those yourself.
- `upgrade` reports `upgrade: already up to date` when the closest preset is fully present. It does not upgrade a custom surface into a preset surface.

## Verification
1. `grimuah rules` prints the grouped rule table and exits 0.
2. `grimuah check` in the scaffolded project prints `grimuah check: clean` once every surface holds two or more files.
3. `pnpm check` runs the same check through the generated script.
4. `pnpm typecheck` exits 0 on the scaffold as generated.
5. The first commit passes the hook, which runs typecheck and the em-dash guard.
