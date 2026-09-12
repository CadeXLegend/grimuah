# check-speed autoresearch session, 2026-09-11 / 2026-09-12

the record behind the `perf(check): native lint engine, parallel scan, and a 52x
faster check` commit on `main`. two files, both carried over from the session
folder that the autoresearch branch lived in:

- `log.jsonl` : 37 experiments, one JSON object per line. each carries the
  primary metric, the status (`keep` / `discard` / `crash` / `checks_failed`),
  and an `asi` block with the hypothesis, the measurement and what was verified
- `ideas.md` : the running backlog, 773 lines. dead ends with their numbers, the
  measurement methods that work on this machine, and the one deferred item

## what moved

`check_ms` went 24628 ms to 466 ms across a 30 repo bench, run 9 to run 34. the
bench is one repo per size class (10 to 5000 files) plus 17 fuzzed error and
warning sweeps, and `grimuah check` ended up spawning no subprocess on its
default path at all.

## two things worth reading before redoing any of this

- **the harness cannot judge a small effect on its own.** a single
  `measure.sh` pass resolves about 4%, and this box drifts 4 to 8% over a
  session. every small change in this session was judged with an interleaved
  paired A/B of two binaries over all 30 repos, and settled with `callgrind`
  instruction totals, which do not drift at all. `ideas.md` has the method
- **the log's commit hashes are wrong from run 19 on.** the harness commits with
  `git add -A && git commit` under a 10 second timeout, and this repo's husky
  `pre-commit` hook runs the 125 check e2e suite, so the commit is always killed
  and the work stayed staged. runs 19 to 34 therefore all report one hash. the
  measurements are sound, the hashes are not

## what is not here

the benchmark and differential harness (`measure.sh`, `gen-bench.sh`,
`native-diff.sh`, `hygiene-diff.sh`, `checks.sh`, `biome-*.sh`, `test-unit.sh`,
`prompt.md`) stayed with the autoresearch branch, which has since been deleted.
`tests/lint-corpus/` and `tests/hygiene-corpus/` did come across, because the
unit tests read them at runtime.
