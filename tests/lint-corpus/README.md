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

`require-enum-in-config-file.repo.ts` carries a suffix for the same reason, and
the copied path supplies the other half of the rule's scope: the module lands at
`src/probe/<name>`, which is an implementation module, while a file with no
behaviour kind is an entry point, a file at the tree's top level is the shared
root library, and a `.config.ts` is where the enum belongs rather than where it
violates anything. the declarations it leaves alone are the three the detector
decides on: an unexported enum, the enum inside a `declare module` block, and the
enum inside a bare block. the one row it reports is the `export enum` at line 18,
and the rule's own unit test pins the other three shapes the same declaration
arrives in: `export declare enum`, an `export` on a line of its own, and
`export const enum`, which the front-end models as a const declaration whose
leading words still carry `enum`

`no-optional-properties.ts` also pins the two type positions the parser does not
model, so the fixture fails if the reader stops reaching them: an optional
property inside an `as` assertion's type, and one inside a `declare module` block

`readonly-collection-signatures.ts` pins the array shapes the rule must tell
apart, which a token extent does not distinguish on its own: an array, an
indexed access, a tuple, a union that names one, a function type that returns
one, a conditional type and a type predicate. fourteen rows in the oracle come
from fixtures that pin another rule and hold a mutable array incidentally, in a
parameter or a return type

`readonly-type-members.ts` pins the rule's own narrowing as written: a property of
a type literal is reported and a property of an interface is not, because the
detector walks `TypeLiteral` nodes only. seven more rows come from fixtures that
pin another rule and hold a mutable type literal incidentally, in a cast or a
parameter

`shared-type-placement.repo.ts` and `consumer/uses-shared-type.util.ts` are the only
fixtures in two directories, which is what a rule about a declaration consumed from
another directory needs: the consumer sits under `src/probe/consumer`, so its import
of the declaration crosses a boundary. the declaration module is the one judged, and
its row names `shared-type-placement.types.ts`, the file name minus its kind

`no-import-cycles-a.repo.ts` and `no-import-cycles-b.repo.ts` are one of the corpus's
two pairs: a cycle needs two files, and the two import each other so the run has to read
both before either can be judged. each one's row lands on its own import statement,
and the pair is the only place the corpus reaches the project pass from a fixture
rather than from a single file

`duplicate-function-body/first.ts` and `duplicate-function-body/second.ts` are the
other pair, and the boundary the duplicate-body rule needs: it keys on a declaration's
name beside its collapsed body, so it can only fire across two files that declare the
same thing. the first writes the body on one line and the second splits it and puts the
`{` on a line of its own, which pins both the whitespace collapse and the body's own
line as the reported one. five more fixtures pin another rule and hold an identical
named body incidentally, which is what their own rows are not: `barecatch.ts` and
`barecatch-ws.ts` are byte-identical files, and `c-return-bare.ts`,
`handled-catch-multiline.ts` and `handled-return-bare.ts` declare `f` three times over
with one body between them. those five carry five of the rule's seven rows, and the pair
above carries the other two

`no-export-without-consumer.repo.ts` carries a suffix for the corpus's own reason:
the rule reads the suffixed-module convention, `<name>.<kind>.ts`, rather than a
directory, so only a suffixed fixture is judged at all. its two rows land on the
declared names rather than on the `export` keyword, and the run is the whole
directory, so a name any sibling fixture spells counts as a consumer. fourteen more
rows come from suffixed fixtures that pin another rule and hold an unfollowed export
incidentally: `config-declares-data-only.config.ts`, `lowercase-copy.config.ts`,
`require-enum-in-config-file.repo.ts`, `require-enum-over-literal-union.service.ts`
and `consumer/uses-shared-type.util.ts`

`asany-param.ts`, `asany-type.ts` and the annotation in `asany-union.ts` used to
pin the silence of `: any`: the plugin era warned on it, biome's recommended set
owned it, and the native engine reported nothing at all for an annotation. the
`any` type ban replaced that silence, so those files carry its rows as well as
the rows that were already there, and `any-type.ts` pins the shapes it reads
(`any[]`, `Array<any>`, a return annotation) against the names it must not
(`named.any`, `{ any: "any" }`)

`no-duplicated-statement-text.ts` is the statement-text rule's only fixture, and it is
the corpus's one fixture that needs no second file: the rule counts OCCURRENCES rather
than distinct files, so a single module that writes the same statement twice is the whole
defect. the two copies also disagree on how they are written, one on a single line and one
across three with `\n` escapes and indentation, which is the collapse's half of the rule:
the two key the same only after the escapes cook and the whitespace folds. both rows land
on the literal's own line rather than on the call that prepares it

`duplicated-user-facing-copy/first.ts`, `second.ts` and `third.ts` are the corpus's
three-file fixture, and the rule is the reason: it counts DISTINCT FILES rather than
occurrences, and its threshold is three, so a pair of files reports nothing at all. the
sentence the three share reports one row per file, at the literal's own line, and the
second sentence the fixture holds is written into two of the three on purpose, which is
the exclusion that pair pins

`no-repeated-inline-copy.ts` is the corpus's only single-file copy fixture, and the
sentence it holds is written twice inside the one module on purpose: this rule's verdict
is the file's, so no second file takes part in it. the sentence is deliberately one no
other fixture writes, because the cross-file copy rule counts distinct files and would
report on this one too
