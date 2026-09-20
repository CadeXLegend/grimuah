---
name: "grimuah-architecture"
description: "Design the surface graph of a grimuah project: choose the preset, decide which surfaces exist, place a type or a constant, keep the dag acyclic, and know what the config validation refuses. Use before adding a file to a new area, when an import is refused, or when a directory has no obvious surface."
version: 1
created: "2026-09-20"
updated: "2026-09-20"
---
## When to Use
Use this skill when the question is where code belongs rather than how to write it: choosing or changing a preset, adding a surface, splitting a directory, deciding where a shared type lives, or reading `architecture.config.json` for the first time.

Do not use it to scaffold the project (that is the setup skill), to write the code inside an agreed surface (that is the compliance skill), or to triage findings you already have (that is the fix-findings skill).

## Procedure
1. Read the graph before you place anything. Each surface in `architecture.config.json` carries `path`, `depth`, `dagOrder`, `suffixes`, `innateMembers` and `allowedImports`. `depth` is physical, it is where the directory sits in the tree (`lib` is 0, `src/db` is 1). `dagOrder` is logical, it is where the surface sits in the import graph, and it is the one the gate reads. The two are independent: `utils` and `services` are both depth 1 in the webapp preset with `dagOrder` 1 and 2.

2. Apply the import direction, which is the whole model in three lines.
   - a surface may import from itself, always
   - a surface may import from any surface with a lower `dagOrder`, always, and this is implicit
   - everything else needs the target named in the importer's `allowedImports`: a shallow surface importing a deeper one, and two surfaces at the same level importing each other

3. Choose the preset by archetype, then refine. `default` (utils, services, components, no root lib), `webapp` (lib, utils, services, components, pages), `cli` (lib, utils, services, commands), `backend` (lib, db, middleware, services), `bot` (lib, db, services, middleware, components, commands, tasks, handlers). The interactive questions add `lib`, `db`, `pages`, `commands`, `middleware`, `tasks` on top, and adding `lib` shifts it to depth 0.

4. Decide a surface by role, not by feature. A surface is a set of files with one identity: an orchestrator role (`services`), a persistence role (`db`), a presentation role (`components`), a request-pipeline role (`middleware`). One feature spans several surfaces, and that is the point. Two directories named after features, each holding its own services and its own db access, are the shape the model exists to prevent.

5. Add a surface with `grimuah add <surface> [--path <dir>]`. It creates the directory, writes `example<suffix>.ts`, and appends the surface at the deepest `dagOrder` plus one, with no `allowedImports`, because a surface at the deepest `dagOrder` already reaches everything. Pass `--path` for a directory outside `src/`, since a surface may be a root-level program such as `gateway/` or `lib/`. The suffix comes from a name heuristic: `validators` gets `.validator.ts`, `guards` gets `.guard.ts`, `states` gets `.state.ts`, `repositories` gets `.repo.ts`, and any other name gets `.<singular>.ts`.

6. Place shared code by the shallowest common ancestor rule. A type two sibling surfaces need moves up, never down: a type used by `services` and `components` belongs in `lib` or in an existing shallow surface both may import. A type one surface owns lives in that surface's `<name>.types.ts` and inherits the surface's `dagOrder`, so a deeper surface cannot reach it. Moving a type upward is a deliberate act of sharing.

7. Place the innate members inside the owning surface, never in a central tree. `<name>.types.ts` holds its contracts, `<name>.config.ts` holds its constants and enums, `<name>.spec.ts` holds its tests, `<name>.regex-patterns.ts` holds its documented patterns. A `config/`, `types/` or `models/` directory under `src/` is flagged by name. An innate member inherits its surface's `dagOrder` and may not import from a deeper surface, because that would drag implementation detail into a contract.

8. Keep every surface real. The singleton rule reports any surface holding one file or fewer, and an empty surface directory is reported the same way. When a surface only ever holds one file, either merge it into the surface that consumes it, lift the file up, or drop the surface from the config. Leaving a directory the config no longer names is the worst option: files there are outside every surface.

9. Check what actually gets linted. Only paths under `sourceRoots`, plus `rootLib.path` when `rootLib.enabled`, are linted at all. A config with no `sourceRoots` derives one lint root per surface from the surfaces' paths. A tree that nobody declares is invisible to `grimuah check`, so a new top-level directory needs either a `sourceRoots` entry or a surface whose path covers it.

10. Validate the config before trusting a run. `grimuah check` refuses to start when surface names repeat, when two surfaces share a `dagOrder`, when the `dagOrder` values are not sequential from 0, when an `allowedImports` entry names a surface that does not exist, when `sourceRoots` carries an empty string, or when `rootLib` is enabled with an empty path.

11. Let the graph stay acyclic. Two files that import each other are an error, because module initialisation order would decide what each one sees. When a cycle appears, lift the shared symbols to the shallower of the two files, or invert one direction with a callback.

## Pitfalls
- `allowedImports` granting a lower `dagOrder` target is dead configuration and is reported as `redundant-allowed-import`. Only same-level grants and shallow-to-deep grants belong in the list.
- `depth` is bookkeeping. Nothing is refused for a wrong `depth`, while a wrong `dagOrder` changes what the import firewall allows, so fix the logical field when a boundary is wrong.
- Changing `dagOrder` is a renumbering, not an edit of one number: the values must stay sequential from 0 with no duplicates, so moving a surface to the front shifts every surface after it.
- Two surfaces whose paths nest resolve to the longest matching path, so a file under `src/db/migrations` belongs to whichever surface path is longer.
- A surface whose configured path does not exist on disk is a structural finding naming the directory. Deleting a directory without updating the config is the usual cause.
- Renaming a file changes its obligation. A file moved from `services` to `utils` must also change suffix from `.service.ts` to `.util.ts`, and the innate members do not follow automatically.
- Don't widen the boundary to silence a finding. Adding an `allowedImports` entry for every complaint produces a config where the graph says nothing. If two surfaces need each other constantly, one of them is in the wrong place.

## Verification
1. `grimuah check` runs, which proves the config passed validation.
2. Every file you added sits under a declared `sourceRoots` path or the `rootLib` path, and inside a declared surface directory.
3. Every new import either points down the `dagOrder`, stays inside its surface, or matches a deliberate `allowedImports` entry you can justify in one sentence.
4. Every surface you touched holds two or more files.
5. `architecture.schema.json` is present, so an editor autocompletes rule keys and flags a rule name the binary does not have.
