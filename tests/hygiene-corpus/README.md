# hygiene corpus

fixtures for the native equivalent of biome's built-in `recommended` ruleset:
`noUnusedImports`, `noUnusedVariables`, `useConst`, `noConstantCondition` and
`noUnreachable`.

`tests/oracle/check.sh` runs `grimuah check` over a copy of the fixtures with
every architecture layer disabled, so the only findings are hygiene ones, and
diffs the rows against `tests/oracle/hygiene-corpus.tsv`, which biome's own
built-in ruleset validated for all five rules on 2026-09-12. two biome
behaviours are normalised in that fixture rather than matched:

- `noUnreachable` writes `This code will never be reached ...` and appends the
  reason as advice. grimuah prints no advice, so the ellipsis is dropped
- one statement with several unused imports is `Several of these imports are
  unused` in biome and one finding per binding here. the fixture compares the
  printed rows, so the difference is recorded rather than reconciled

the corpus carries no self-recursive declaration on purpose. biome reports one
(a binding read only from inside its own definition is unused to it, as it is to
typescript-eslint) and grimuah does not, because telling that apart needs real
scope resolution. the deviation is pinned by a unit test in
`src/rules/hygiene.zig` instead, and it only ever hides a finding.

`jsx-component.tsx` is the one fixture that pins behaviour biome had and the
lexer did not. a JSX tag leaves no token, so the lexer records the element name
it reads and the scope pass counts it as a reference: the import used only as
`<Panel.Content />` is not reported, the one nothing names is. the same file
carries a `let` after the self-closing element, because a self-closing element
used to consume every byte that followed it and hid the rest of the file from
every rule. the rows for this fixture were added by hand, and the shape they pin
is the shape biome's `noUnusedImports` reports.
