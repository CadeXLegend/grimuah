# lint-corpus

verification fixtures for the native rule engine in `src/lint.zig`.

every file here is deliberately violating or deliberately clean, and each one
pins a specific edge case of biome 2.5.11's plugin semantics: em-dash / `let` /
`switch` are dead rules, `null` matches property names and type positions but
never strings or regexes, `as any` matches the type the cast names (`as any`,
`as any[]`, `as any | T`) while `: any` annotations stay out, chained casts need
nesting with no parenthesis between them, `const ... = { ... } as const`
tolerates a binding pattern but not a type annotation, `catch (e: unknown)` is
never flagged while `catch (e)` is, jsx text is never matched but jsx expression
containers are, and import aliases (`import { a as b }`) are not casts. the proxy
re-export ban covers `export { a } from` and `export * from`, and a local
`export { a }` is not a re-export at all.

`tests/oracle/check.sh` copies this directory into a scratch `grimuah init`
project and diffs the findings against `tests/oracle/lint-corpus.tsv`, the rows
biome's plugin engine validated on 2026-09-12. it deletes the scaffold's three
surface directories first, so the run also records three structural rows: the
warning a surface whose directory is absent produces. do not tidy these files,
their shape is the test.

`asany-arr.ts`, `asany-union.ts`, `d-as-union.ts`, `reexport-star.ts` and
`reexport-star-namespace.ts` report against that 2026-09-12 snapshot on purpose.
they used to pin the two narrow matchers the plugin era had, where `as any[]`
escaped the `as any` ban and `export * from` escaped the proxy re-export ban, and
the rule research records both as defects: a ban whose matcher is narrower than
its own message. the snapshot's rows for them were extended rather than
re-recorded, so every other row still carries biome's verdict.

the largest real-code coverage came from the synthetic bench repos plus a
`sleepy` overlay, both filtered through biome while biome was the oracle. those
harnesses went with biome; the committed corpora are what still replay.

the 12 rules ported from `docs/rule-candidates/catalogue.md` have fixtures here
too: `await-in-loop.ts`, `boolean-flag-argument.ts`,
`config-declares-data-only.config.ts`, `cyclomatic-complexity.ts`,
`for-of-accumulation.ts`, `if-chain-dispatch.ts`, `lowercase-copy.config.ts`,
`max-file-lines.ts`, `max-function-lines.ts`, `max-parameters.ts`,
`nested-ternary.ts` and `unbounded-collection-read.ts`
each one trips its rule and pins the shapes that rule must leave alone, and the
two named `.config.ts` are the pair whose rules read the file's own name

`require-enum-over-literal-union.service.ts` carries a suffix in its own name on
purpose: the rule reads the file's name as well as its types, so only a module
named `<name>.<kind>.ts` is in scope, and an unsuffixed fixture would report
nothing

`asany-param.ts`, `asany-type.ts` and the annotation in `asany-union.ts` used to
pin the silence of `: any`: the plugin era warned on it, biome's recommended set
owned it, and the native engine reported nothing at all for an annotation. the
`any` type ban replaced that silence, so those files carry its rows as well as
the rows that were already there, and `any-type.ts` pins the shapes it reads
(`any[]`, `Array<any>`, a return annotation) against the names it must not
(`named.any`, `{ any: "any" }`)
