# frozen oracle

the corpus findings that a real oracle validated, kept as a snapshot so the check
still runs once biome is gone

## provenance

biome was the oracle for both corpora until the native engine replaced it
these fixtures were recorded on 2026-09-12, in a tree where `.auto/native-diff.sh`
(biome's plugin engine over `tests/lint-corpus`) and `.auto/hygiene-diff.sh`
(biome's five built-in rules over `tests/hygiene-corpus`) were both green
the verdict those two harnesses produced is what these files freeze

a snapshot is not a proof, and it cannot answer a question biome could
when a rule changes on purpose, update the fixture in the same commit and say why
in the message
never re-record to make a failure disappear, because only an oracle can tell a
finding that was fixed from a finding that was lost

## files

| file | corpus | rows |
|---|---|---|
| `lint-corpus.tsv` | `tests/lint-corpus` (139 fixtures, grimuah's own rules) | 193 |
| `hygiene-corpus.tsv` | `tests/hygiene-corpus` (8 fixtures, the 5 rules that mirror biome's built-ins) | 20 |

one row per finding, as `path:line: [layer] message`, sorted, with the pre-pass's
`./` prefix stripped
the path is relative to the scaffolded project, so the canonical corpus rows read
`src/probe/...`

## running it

    bash tests/oracle/check.sh            # compare against the fixtures
    bash tests/oracle/check.sh --record   # rewrite the fixtures

`test-e2e.sh` runs the compare mode, so the e2e suite is the gate
the script scaffolds a `grimuah init --preset default` project per corpus, copies
the fixtures in, and diffs the rows

- `lint-corpus` keeps every architecture layer on, so a regression in any of the
  four layers or in hygiene shows up
- `hygiene-corpus` turns all four layers off and scopes the run to `src`, so
  hygiene is the only thing that can report

## what the fixtures see, and what they cannot

they see a change in every rule that reports on a corpus file, and each of the
three ways a rule can break was proven against them: a row removed from a fixture
fails, and so does a rule message changed in `src/rules.zig`

they cannot see the pre-pass's structural rules
the pre-pass reports nothing on `src/probe`, because the corpus sits inside one
source root with no surfaces of its own, so a change to the import firewall, the
suffix rules or the singleton warning leaves every row identical
the structural rows they do see are the missing-directory warning, made by the
lint-corpus harness deleting the scaffold's three surface directories, and
the file-level rules in `src/rules/structural.zig`, which read a path and a tree
rather than the project: `src/<surface>:0:` and
`src/probe/config-declares-data-only.config.ts:12:` are both rows
`test-e2e.sh` covers those cases, and no oracle ever covered them here: the
structural rules are CLI passes, not GritQL, so biome was never their oracle
line numbers are part of a row, so the same finding reported on a different line
is a diff

## what this replaced

`.auto/native-diff.sh` and `.auto/hygiene-diff.sh` compare grimuah against biome
live, over the corpora, the bench repos and a sleepy overlay
they stay useful while biome is installed, and they are the wider net
this directory is the part that survives without it
