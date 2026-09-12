# lint-corpus

verification fixtures for the native rule engine in `src/lint.zig`.

every file here is deliberately violating or deliberately clean, and each one
pins a specific edge case of biome 2.5.11's plugin semantics: em-dash / `let` /
`switch` are dead rules, `null` matches property names and type positions but
never strings or regexes, `as any` only matches a bare `any` type, chained casts
need nesting with no parenthesis between them, `const ... = { ... } as const`
tolerates a binding pattern but not a type annotation, `catch (e: unknown)` is
never flagged while `catch (e)` is, jsx text is never matched but jsx expression
containers are, and import aliases (`import { a as b }`) are not casts.

`.auto/native-diff.sh` copies this directory into a scratch `grimuah init`
project and diffs the native engine's findings against biome's plugin engine
over it. do not tidy these files, their shape is the test.

`sleepy`'s rules are frozen in the legacy four-file layout, so it never takes
the native path; the largest real-code coverage for the diff comes from the
synthetic bench repos (`$BENCH_ROOT`) plus the `sleepy-overlay` project the
harness scaffolds.
