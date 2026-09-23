---
name: "grimuah-fix-findings"
description: "Read and triage the output of grimuah check: the two tiers and their different formats, which findings fail the run, the order to fix them in, when silencing a rule is right, and how to tell a real finding from a wrong one."
version: 1
created: "2026-09-20"
updated: "2026-09-23"
---
## When to Use
Use this skill when `grimuah check` prints findings and you must decide what to change: the code, the file's location, the surface graph, or the config.

Do not use it to write new code so that it passes in the first place (that is the compliance skill), or to design a boundary the findings keep pointing at (that is the architecture skill).

## Procedure
1. Read the exit code and the last line together, because they mean less than they look like.
   - `grimuah check: clean` with exit 0 means no error-severity engine finding and no pre-pass finding at all. Warnings may still have printed above that line.
   - `grimuah check: N violation(s) found` with exit 1 means at least one error-severity engine finding, or any pre-pass finding whatever its severity.
   - So a printed line is always work, even on a run that says clean.

2. Tell the two tiers apart by the shape of the line, because they behave differently.

| Shape | Tier | Fails the run |
| ----- | ---- | ------------- |
| `./src/services:0: [structural] surface 'services' contains only 1 file(s) ...` | pre-pass, note the `./` prefix and line 0 | yes, always, warning or not |
| `src/services/foo.service.ts:4: [resilience] do not use let; use const ...` | engine, note the missing prefix and the real line number | yes when the severity is err, no when it is warn |

3. Map the message back to the rule name when you need the config key. The run prints the layer and the message, never the rule name. `grimuah rules` prints every name with its layer, severity and message, grouped by layer, so match the message there. That name is the key `architecture.config.json` turns the rule off with.

4. Fix in this order, because earlier steps delete later findings. Structural first (a file in the wrong surface produces an import finding and a suffix finding at once), then the error-severity resilience and behavioural findings, then the warnings, then the duplication family last, since extracting a shared function can clear several duplication findings in one move.

5. Choose the fix from the message, which usually names it.

| Finding | Fix |
| ------- | --- |
| `surface 'x' ... importing from 'y' ... not in allowedImports` | move the file, move the symbol up to a shallower surface, or add a deliberate `allowedImports` entry |
| `does not match any legal suffix` | rename to one of the surface's suffixes, or move the file to the surface whose suffix it carries |
| `contains only N file(s)` | give the surface a second file, merge it into its consumer, or drop the surface from the config |
| `innate member ... imports from deeper surface` | lift the type to the shallowest common ancestor and import it from there |
| `centralized 'types/' directory detected` | co-locate the contents into the surfaces that own them, then delete the directory |
| `do not use let` / `==` / `as any` / `any` / chained cast / proxy re-export / `as const` | use the replacement the message names |
| `do not use null` / `names an absence` | return an `Outcome`, or lift the value with `fromUndefined` from `lib/outcome.ts` where it enters |
| `This property is optional` / `This parameter is optional` | give it a default at the boundary, or take an `Outcome` the caller has to read |
| `This method is optional` / `This class member is optional` | make it required and implemented on every path, or initialise it where the class is constructed; a class field is state the class owns rather than a value it was handed |
| `do not use switch` / `imperative for loops` / `if..else` chain over one subject | a `Record` or `Map` dispatch table, or `map`/`filter`/`reduce`/`for..of` |
| `do not use throw` | return an `Outcome` and narrow on `succeeded` |
| `do not use bare catch` / `catch block must handle or log` | log the error or return a failure |
| `is exported but no other module names it` | drop the `export` keyword until a consumer exists |
| `duplicated ...` family | lift the body or the constant into one module and import it from both sites |

6. Silence a rule only when the project has decided the rule is wrong for it, and write down why. In `architecture.config.json`:

```json
"layers": { "resilience": true },
"rules": { "switch-statement": false }
```

When the rule is right for the tree and wrong for one file, carve that file out instead of turning the rule off. `null-literal` is the case it was written for, because a driver and `RegExp.exec` hand back `null`:

```json
"exemptions": [
  { "rule": "null-literal", "paths": ["src/db", "src/util/regex.util.ts"],
    "reason": "a driver and RegExp.exec hand back null at this boundary" }
]
```

A path is a file or a directory, and a directory covers every file under it. All three fields are required, a rule name the table does not have stops the run, and a carve-out covering no file is reported by `stale-exemption`, so a moved file cannot leave the rule reading as silenced while it applies to everything again.

A rule the config omits is on. A rule named `true` in a disabled layer stays off, because the layer gates the rule. The hygiene rules (`unused-import`, `unused-variable`, `prefer-const`, `constant-condition`, `unreachable-code`) have no layer of their own, so `rules` is the only switch they have. The surface and edge model, meaning the import firewall, the suffix check, the singleton check and the innate member scoping, has no per-rule key at all, so those findings can only be fixed or avoided by changing the graph. A layer turned off skips its pre-passes too: with `structural` off, the firewall and the singleton check stop running.

7. Prefer the smallest honest change. Turning off a warning rule to get a green run is the one move that makes the gate useless, because the finding it hides will come back as an error somewhere else. When you do turn a rule off, name it in the commit message.

8. Re-run after each batch of edits rather than after every line, and read the count. Findings can cascade: clearing an import cycle or lifting a duplicated body removes several lines at once, and the file that gains a second file clears its surface's singleton finding.

9. Report a wrong finding rather than working around it. Reduce it to the smallest file that still reproduces it, keep the exact `grimuah check` output, and file it against the grimuah repository with the reproducing file. Working around a false positive usually means weakening the config for everyone on the project.

## Pitfalls
- The unknown-rule guard stops the whole run: `architecture.config.json` naming a rule grimuah does not have prints `Error: architecture.config.json names the rule 'x', which grimuah has no rule for.` and exits 1 without linting anything. A typo there looks like a broken install.
- Pre-pass findings are printed before engine findings, so the first line of output is usually the surface-level complaint and the code-level complaint is further down. Read to the end before deciding the scope of the fix.
- A pre-pass finding carries line 0 or line 1 rather than a real line, since it is a path or file-level check. Do not go looking for a defect on line 0 of a directory.
- Pre-pass findings print with a `./` prefix and engine findings print without one, so a naive dedupe or sort that strips prefixes mixes the two tiers together.
- `export-without-consumer` shows up constantly while a module is being built and disappears once the consumer lands. It is a warning, and it is not worth a config change mid-feature.
- `redundant-allowed-import` means the DAG already grants that edge, so delete the entry rather than disabling the rule.
- Do not fix a `json`-shaped problem with a source edit: `depth` in the config is bookkeeping, and the field the gate reads is `dagOrder`.
- Fixing the same warning in ten files by hand is the signal that the shared helper is missing, not that the rule is noisy.

## Verification
1. `grimuah check` exits 0, and you can say for every line that no longer prints where it went: fixed, moved, or deliberately silenced with a named rule and a reason.
2. `grimuah rules` was consulted, so any `rules` key in the config matches a real rule name.
3. `pnpm typecheck` exits 0 after the edits.
4. Any rule you silenced appears in the commit message with the reason.
