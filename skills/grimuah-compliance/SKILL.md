---
name: "grimuah-compliance"
description: "Write TypeScript that passes grimuah on the first run, in a repo that has architecture.config.json. Covers where a file belongs, which imports are legal, the banned constructs and their replacements, the outcome pattern, type shape, size limits, and the copy rules."
version: 1
created: "2026-09-20"
updated: "2026-09-23"
---
## When to Use
Use this skill for any TypeScript you write or review in a repo carrying `architecture.config.json`. Read it before the first line, not after `grimuah check` complains, because most of its rules change the shape of a function rather than the spelling of a line.

Do not use it to install or scaffold a project (that is the setup skill), to design the surface graph (that is the architecture skill), or to triage a finding you already have (that is the fix-findings skill).

## Procedure
1. Place the file before writing it. Every file must sit in a surface declared in `architecture.config.json` and carry a legal suffix for that surface: `.service.ts` in `services`, `.repo.ts` in `db`, `.component.ts` in `components`, `.command.ts` in `commands`, `.util.ts` in `utils`. The innate members are legal in every surface: `.types.ts`, `.config.ts`, `.spec.ts`, and `.regex-patterns.ts` where the surface declares it. A file in a surface directory with a suffix the surface does not declare is a finding, so check the surface's `suffixes` list rather than assuming the convention.

2. Co-locate, never centralize. Surface-owned types live in `<name>.types.ts`, configuration constants and enums in `<name>.config.ts`, test files in `<name>.spec.ts`, regular expressions in `<name>.regex-patterns.ts`, all beside the code that owns them. A config has to earn its file: the rules that point at one count the entries the file would hand it, treat an enum member and a string literal written outside an enum as one entry each, and stay quiet below four, so a constant or two and a small enum stay in the module that reads them. A config the surface already has is the destination either way. A `src/config/`, `src/types/` or `src/models/` directory is a cosmetic finding by name alone. Lift something to a shared location only when a second consumer exists, and then lift it to the shallowest surface both consumers may import.

3. Keep the import direction. A surface may always import from a surface with a lower `dagOrder`, and may import from itself. A shallow surface importing a deeper one, or two surfaces at the same level importing each other, needs the target named in the importer's `allowedImports`. The error prints both `dagOrder` values and the missing entry.

4. Return outcomes, never throw. Every fallible function returns the shipped type from `lib/outcome.ts` (`Outcome`, `Success`, `Failure`) and narrows on `.succeeded` before reading `.result`. `throw` is an error-severity finding. A `catch` block must either log the error or return a failure, because an empty catch and a discarded catch parameter are both findings. Absence travels the same way: a value that may not be there is an `Outcome`, not a `null`, an `undefined`, an optional property, or an optional parameter. Lift it where it enters with `fromUndefined(value, reason)`, read it with `getOrElse`, `matchOutcome`, or `isSuccess`, and reach for `attempt` or `attemptAsync` instead of writing a `try`/`catch` at a call site. `lib/outcome.ts` is the one file the absence rules let name `undefined`, because it has to, so do not restate it elsewhere. A value that genuinely arrives as a third-party boundary, a database row or a `RegExp` result, is the one case the config is for: declare an `exemptions` entry naming the rule, the file and the reason rather than weakening the code.

```ts
type ParseFailureReason = "EmptyInput" | "NotJson";

export const parsePayload = (raw: string): Outcome<ParseFailureReason, Payload> => {
  if (raw.length === 0) {
    return { succeeded: false, reason: "EmptyInput" };
  }
  const parsed = safeJsonParse(raw);
  if (!parsed.succeeded) {
    log.warn("payload was not json", { raw });
    return { succeeded: false, reason: "NotJson" };
  }
  return { succeeded: true, result: parsed.result };
};
```

5. Write the banned constructs as their replacements, because each one is an error-severity finding.

| Write this instead                  | Not this                                |
| ----------------------------------- | --------------------------------------- |
| `const`                             | `let` (module-level mutable caches excepted) |
| `Record` or `Map` dispatch table    | `switch` statement                      |
| `map`, `filter`, `reduce`, `for..of` | C-style `for (;;)`, and `for..of` that pushes into an array |
| `===`, `!==`                        | `==`, `!=`                              |
| an `Outcome` from `lib/outcome.ts`  | `null`, and `undefined` in any position |
| `fromUndefined`, `getOrElse`        | `x === undefined`, and an explicit `undefined` in a union |
| the type you mean                   | `as any`, `any`, `any[]`, `Array<any>`  |
| one cast                            | a chain of casts                        |
| an import from the defining module  | a re-export proxy                       |
| an `enum`                           | `{ ... } as const`                      |

6. Shape the types the way the resilience layer wants them: `readonly` on every type-literal member, `readonly T[]` or `ReadonlyArray<T>` on parameters, returns and properties, no optional properties, parameters, methods or class members (a `?` says the value may not be there without naming `undefined`; give it a default at the boundary, or take an `Outcome`), and a string enum instead of a union of two or more string literals. Declare exported enums in the surface's `.config.ts`, one enum per config file, once the file's vocabulary would fill one: a small enum beside a constant or two stays where it is, and an enum moves into a config the surface already holds.

7. Stay inside the size limits. Three levels of nesting in a function body, four parameters (a destructured parameter is one slot), 80 lines per function, 500 lines per module, cyclomatic complexity 15. Exceeding any of these is a warning that still prints on a clean run, so read the output rather than the exit code.

8. Name behaviour instead of passing a bare boolean, and replace a chain of three or more branches over one subject with a dispatch table keyed on that subject. Both are warnings, and a `Map` keyed on the payload library's own enum is the usual fix in a bot or backend project.

9. Read the results you ask for. An `Outcome` nobody reads, or a `Promise<boolean>` nobody reads, is a finding: assign it and narrow `succeeded`, or narrow the callee to a `void` result. Add an explicit `LIMIT` to any query that reads a collection and paginate at the caller.

10. Write the copy the way the cosmetic layer wants it. Em-dashes are banned everywhere in source, including comments and template literals. User-facing copy in a `.config.ts` starts with a capital letter. A sentence written twice in one file becomes one named constant, and a sentence written in three or more files lives once in the owning `.config.ts`, or as a named constant the other files import while the file's vocabulary does not yet earn a config. Comments and docs stay lowercase with no full stops.

11. Export only what another module names. An exported binding no other module imports is a finding, so a helper you have not wired up yet stays unexported until its consumer lands.

12. Run the gate before you claim the work is done: `grimuah check` (or `pnpm check`) and `pnpm typecheck`.

## Pitfalls
- The run has two tiers and they read differently. Pre-pass findings print as `./src/utils/example.util.ts:0: [structural] ...` with a `./` prefix and line 0, and every one of them fails the run whatever its severity. Engine findings print as `src/utils/example.util.ts:4: [resilience] ...` and only the error-severity ones fail the run. So a pre-pass warning is not safe to ignore.
- Warnings print on a run that still exits 0 and still ends with `grimuah check: clean`, because only error-severity engine findings and pre-pass findings count as violations. Read the printed lines, not just the exit code.
- `export-without-consumer` fires on a lone exported helper in a file nobody imports yet. Dropping `export` is the fix, not a changed config.
- The scaffolded `tsconfig.json` sets `exactOptionalPropertyTypes: true` and `noPropertyAccessFromIndexSignature: true`, so the `optional-property` rule and the compiler agree: normalize at the boundary instead of spreading optionality through your types.
- `throw-statement` prints a message naming `OperationOutcome`, and the shipped `lib/outcome.ts` declares `Outcome`, `Success` and `Failure` narrowed on `succeeded`. Use the shipped names. In a generic signature name `ValuedOutcome<R, T>` or `EmptyOutcome<R>` rather than `Outcome<R, T>`, because the bare alias defers its success branch while `R` is still generic and no caller can then read `.result`.
- `string | undefined` in a signature is an `undefined-literal` finding, so the lift belongs where the value enters: `fromUndefined(value, reason)` turns a library's `undefined` into an `Outcome` once, at the seam, and the types inward never carry the union.
- `null-literal` and `undefined-literal` are two toggles over one idea, and the second one is the broader of the two: the `undefined` token reports in a value position and a type position alike, so `x === undefined`, `T | undefined` in a signature, and `return undefined` are all findings. An `undefined` inside a string, a template, or a comment is not a token and never reports. The single exemption is `lib/outcome.ts` itself, which is the file allowed to name one.
- You do not have to name the token to hold a union the standard library inferred: `array.find`, `array.at` and `map.get` all return one without a line of your own saying so. Naming that type in a signature is what reports, which is why the lift belongs at the point the value enters rather than where the type is written.
- A `?` is reported in four places, and which rule catches it depends on what it decorates: `optional-property` reads a member of an object type, `optional-method` reads one whose `?` sits on a call signature rather than a property, `optional-parameter` reads a parameter on any callable, and `optional-class-member` reads a field or a method in a class body. A `?` in a comment, a string or a template is not a token and never reports.
- A class body is the one container the type model does not read, so `optional-class-member` is the only rule that reports inside one. A class field is written where the class is constructed, and the fix is to initialise it there rather than to take an `Outcome`.
- Hygiene rules have no layer toggle, so `unused-import`, `unused-variable`, `prefer-const`, `constant-condition` and `unreachable-code` run in every configuration.
- A surface holding one file is reported, so a new surface is not finished until it holds a second file.

## Verification
1. `grimuah check` prints `grimuah check: clean` and exits 0.
2. `pnpm typecheck` exits 0.
3. Every new file sits in a declared surface and carries one of that surface's legal suffixes.
4. Every import in the new code either points down the `dagOrder`, points at the same surface, or is granted by an `allowedImports` entry you deliberately added.
