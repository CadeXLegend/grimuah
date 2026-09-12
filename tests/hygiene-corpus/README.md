# hygiene corpus

fixtures for the native equivalent of biome's built-in `recommended` ruleset:
`noUnusedImports`, `noUnusedVariables`, `useConst`, `noConstantCondition` and
`noUnreachable`.

`.auto/hygiene-diff.sh <dir>` runs `grimuah check` over a copy of the fixtures
with every architecture layer disabled, so the only findings are hygiene ones,
and diffs `(file, line, rule)` against `biome lint` filtered to those five
categories. run it with this directory as the argument:

    bash .auto/hygiene-diff.sh .auto/hygiene-corpus

biome is the oracle for all five, unlike the 13 architecture rules whose oracle
is `.auto/lint-corpus`. two biome behaviours are normalised rather than matched:

- `noUnreachable` writes `This code will never be reached ...` and appends the
  reason as advice. grimuah prints no advice, so the ellipsis is dropped
- one statement with several unused imports is `Several of these imports are
  unused` in biome and one finding per binding here. the comparison is on
  `(file, line, rule)`, and the raw per-binding count is printed beside it

the corpus carries no self-recursive declaration on purpose. biome reports one
(a binding read only from inside its own definition is unused to it, as it is to
typescript-eslint) and grimuah does not, because telling that apart needs real
scope resolution. the deviation is pinned by a unit test in
`src/rules/hygiene.zig` instead, and it only ever hides a finding.
