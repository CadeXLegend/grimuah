---
name: "optimise-grimuah-performance"
description: "Speed up the Zig code in this repository. This skill also makes sure that a wall-clock measurement on this machine is trustworthy. It covers the bench scripts, the paired A/B protocol, callgrind instruction counts, the measured dead ends and the gates a change must pass."
version: 7
created: "2026-09-12"
updated: "2026-09-12"
---
## When to Use
Use this skill for performance work on the Zig code of this repository. It covers the `check` path and its front-end:

- `src/lang/ts.zig`
- `src/ir.zig`
- `src/scope.zig`
- `src/engine.zig`
- `src/prepass.zig`
- `src/rules/**`
- `src/lint.zig`

Use it also when a change needs a wall-clock claim, and when you must trust a measurement on this machine. Read it before you touch a rule, because the differential guards and the no-false-negative rule live here.

The bench scripts are in `.auto/`, which git ignores on this machine. The scripts do not travel with the repository, but this skill does. On a fresh clone, rebuild the scripts from the protocol in the check-speed record, which commit 6d0b617 still carries (`git show 6d0b617 --stat` names its files), before you trust a number. On this machine, restore a lost script with `git show 302384d:.auto/<file>` while that commit is still reachable.

Do not use this skill for a correctness-only change that carries no measurement claim. Do not make `check` lint less to shrink `check_ms`. The bench cannot detect that loss, so the metric rewards a check that misses findings. The biome ruleset of a user project belongs to that project, not to this one, and the user declined that lever in the check-speed record, at commit 6d0b617.

## Procedure
1. Build the binary that you will measure. Run `zig build -Doptimize=ReleaseSafe`. Then run `ls -la zig-out/bin/grimuah`. ReleaseSafe is about 5.4 MB. Debug is about 19.7 MB and about 4x slower. `bash test-e2e.sh` leaves a Debug binary in `zig-out/bin`, and every number after it is wrong.

2. Take a baseline. Run `bash .auto/measure.sh`. The script rebuilds the binary and prints `METRIC check_ms=<ms>`. On the first run it generates the 30-repo bench under `/tmp/grimuah-bench`, from the vendored `.auto/bench-architecture.config.json`. Treat one pass as ±4%.

3. Read the `SKIP:` and `FAIL:` lines before you read the number. A repo whose check stops before the scan prints `SKIP <repo>: error: ...`. The script drops that repo from the totals and exits 1. A `FAIL:` line means that a sample came from a run that reported an abort. Findings are not failures: `check` exits 1 whenever it reports a violation, and the fuzz repos always report violations.

4. Find the hot leaf before you change anything. Count instructions instead of guessing. Run `valgrind --tool=callgrind --callgrind-out-file=/tmp/cg.out zig-out/bin/grimuah check`, then run `callgrind_annotate --threshold=0.15 --show-percs=no /tmp/cg.out src/lang/ts.zig`. Annotate one file at a time and sort by instruction count. The check takes about 40s on `repo-size-250`, and it does not disturb the machine the way the wall-clock counters do.

5. Change one thing. Change the leaf that the profile named, not the leaf that looks expensive.

6. Judge the change with the interleaved paired A/B. Never compare two `measure.sh` runs. Run `cp zig-out/bin/grimuah /tmp/grimuah-baseline`, change the code, and rebuild. Then run `cp zig-out/bin/grimuah /tmp/grimuah-candidate`, and finally run `BASELINE_BIN=/tmp/grimuah-baseline CANDIDATE_BIN=/tmp/grimuah-candidate PASSES=3 bash .auto/paired.sh`. Both binaries alternate per repo, so drift hits both. `PASSES=3` over all 30 repos resolves about 1-2%. `PASSES=7` over 8 repos resolves about 2%. Pass repo directories as arguments to shrink the sample.

7. Count work when the two methods disagree. Run `valgrind --tool=callgrind --callgrind-out-file=/tmp/cg.out <binary> check`, then run `grep Collected /tmp/cg.out`. Instruction counts do not drift. The bench no longer prints a reference engine beside `check_ms`. Sample the unchanged baseline binary twice with `measure.sh` instead. The spread between those two readings is the machine's noise for that session.

8. Make sure that the change is behaviour-neutral before you keep it. Save the `grimuah check` output from the baseline and the candidate binary in every bench repo and in `/home/cade/dev/sleepy`. Compare the files byte for byte. The fuzz repos are the sensitive ones, with 704, 851 and 1515 lines of output.

9. Run the gates. Run `zig build test`, which reports 241 tests, and `bash test-e2e.sh`, which reports 93 checks. Both counts only grow, so a number below either one means tests were lost rather than that the note is stale. The e2e suite ends with the frozen oracle, so a change that alters a corpus finding fails there. The script `bash .auto/checks.sh` runs both.

10. Write the Zig under the rules in `AGENTS.md`. Name every derived value instead of inlining a magic number. Use a dispatch table instead of `switch` on a discriminant. Declare every function return type. Write comments in lower case, with no full stops and no em dashes. Then do the QA pass that `AGENTS.md` requires.

11. Add a rule under `src/rules.zig`'s table and a per-rule toggle comes with it, because the table is where rule identity lives. A new entry needs a unique kebab-case `.name`, an entry under `rules.properties` in `src/architecture.schema.json`, and a row in the README's rule table; a unit test asserts the schema and the table hold the same set both ways, so a rule with no name fails the build and a rule with no schema entry fails the suite. The names are public config API: renaming one silently breaks every project that turned that rule off. `rules.enabled` takes a rule index rather than a name because `needsTree`, `needsProject`, and the family gates loop all 50 entries once PER FILE, so a name lookup there would put a string compare on the scan beside every cheap test the scan already has. The mask is written once by `rules.resolveToggles` at startup and is derived state, never a second source of truth. The 50 loops must stay `for (&all, 0..) |*rule, rule_index|`: the by-value form copies the entry on every iteration of every per-file gate.

11. Re-run `measure.sh` for the record. If the paired A/B beats the noise, keep the change. If it does not, revert, because a neutral rewrite is not a win. The session parked a rewrite that measured neutral in runs 15 and 31.

## Pitfalls
- One `measure.sh` pass resolves about 4%. This machine is a 12th-gen mobile CPU with 6 performance cores, 8 efficiency cores and 20 threads, and it drifts 4-8% over a session. Two bench runs cannot judge a 3% change. The session discarded run 13 on that mistake, and the paired test contradicted the number.
- `ReleaseFast` measured about 13% slower than `ReleaseSafe` on this machine, 0.87x over 6 repos. Do not build `ReleaseFast` to go faster.
- `bash test-e2e.sh` can leave a Debug binary in `zig-out/bin`. It is about 19.7 MB against 5.4 MB, and `grimuah check` runs about 4x slower. Rebuild ReleaseSafe before you time anything.
- `zig build test` compiles the test root and never installs the exe, so after it `zig-out/bin/grimuah` is still the previous binary and `bash test-e2e.sh` exercises stale code. A stale binary produced a false e2e failure on 2026-09-18 that read as a regression in `src/commands/remove.zig` and was not one. Run `zig build` (and check its exit code) before `test-e2e.sh`, and remember a failed build leaves the previous binary in place as well.
- A command that rewrites `architecture.config.json` has to re-emit every section it does not own, or the user's settings vanish the first time they run it. `add`, `remove` and `upgrade` each hand-build the file, and both `sourceRoots` and the `rules` section were silently dropped from one of the three before 2026-09-18. When a new config section lands, add its writer to all three and assert in `test-e2e.sh` that a rewrite keeps it. A name a user spelled is not a table-minted name in that path, because the rewrite runs without resolving toggles, so it must be json-encoded rather than copied: an unescaped key carrying a quote wrote a config nothing could parse.
- Never compare an instrumented binary against a clean one. Do not profile with atomics. A per-file `fetchAdd` from 16 workers is cache-line ping-pong, and it inflated a measured 370ms parse to 919ms. Use wall-clock accumulators per worker index. Run under `taskset -c 3` for a split with no contention.
- `std.mem.Allocator.alloc` writes `undefined` over every block that it hands out, and `free` fills as well. The alloc fill was 6.5% of a run after run 29 removed the free fill. Removal needs `rawAlloc` and a rewrite of the container, and it deletes a safety check. The session estimated 1.05-1.08x and left it out.
- Thread count is not a free knob. 16 scan workers plus 8 pre-pass workers on 14 physical cores fight for the same cores. Dropping the pre-pass to 2 workers gained 1.15x, and 1 worker measured worse than 2.
- `std.mem.indexOfAnyPos` with a runtime needle set is a double loop, at about 14 instructions per byte. Hop on one byte with `indexOfScalarPos` instead. It is vectorised and about 5x cheaper.
- `std.mem.eql` on short strings is an out-of-line call, at about 57 instructions. Compare the length and the first byte inline. That took a keyword lookup from 423 instructions to a few. `std.StaticStringMap` is a comptime binary search over sorted keys, at about 208 instructions here.
- Never shrink the metric by linting less. The frozen oracle catches a rule that stops reporting, because its rows disappear. It cannot catch a rule that was never implemented, and biome's remaining recommended ruleset left with biome. A real app of 476 files reported 32,510 findings from that ruleset.
- The bench holds 29 synthetic repos and `/home/cade/dev/sleepy`. Never write to sleepy during a measurement. A sleepy session maintains its config by hand. That config needs a unique `dagOrder` for each surface, because `gateway` shared the 0 of `lib` and `check` stopped with `DuplicateDagOrders`. The fix moved `gateway` to 8 on 2026-09-12.
- The bench repos are generated, so they cannot judge what real code exercises. `repo-size-5000` takes 41ms, and the fuzz repos are the sensitive shapes. Neither one stands in for a real app.
- Dead ends, all measured. Do not run them again without a new assumption. A cache keyed by file hash stays out, because a stale cache passes a violation through. A custom no-op `free` allocator vtable measured neutral. A reorder of the parser bracket scans measured 1.016x, and it is parked in `.auto/scanner-fast.patch`. The biome-era dead ends (its daemon, multi-process splitting, `BIOME_THREADS`, merging the plugin rules into one `or{}` file, scoping plugins by extension) left with biome.
- Tell a spent lever from a live one. A probe that disabled the pre-pass measured 1.278x before run 31 and 1.037x after it. The pre-pass and the scan both read every file, so a change that removes a read is worth more than its instruction count suggests.
- The bench scripts sit in `.auto/`, which git ignores. They need `/tmp/grimuah-bench` for the bench itself and `/home/cade/dev/sleepy` only as one measured repo, because `check` spawns nothing. Git ignores the directory, so the reflog holds the only other copy. Run `git show 302384d:.auto/<file>`, until `git gc` prunes that commit. If the scripts must outlive that commit, keep a copy outside the repository.
- `gen-bench.sh` reads the vendored `.auto/bench-architecture.config.json`. Do not point it at the live config of sleepy. That config went stale, every generated repo failed validation in 2ms, and the bench reported 64ms against a real 430ms.
- A bench repo with a stale `architecture.config.json` makes `check` stop in 2ms. The scripts now print `SKIP <repo>: error: ...`, drop that repo and exit 1, so the failure cannot read as a speedup. Read the SKIP list and both totals before you quote a `check_ms`.
- `tests/lint-corpus/` holds 111 fixtures and `tests/hygiene-corpus/` holds 8. `src/lint.zig` and `src/lang/ts.zig` read them at runtime. Do not move them into a scratch directory. The unit tests and `tests/oracle/check.sh` break, and the parse sweep skips in silence when `.auto/parse-sweep.txt` is absent.
- `tests/oracle/` holds the frozen findings for both corpora, recorded while the two biome differential guards were green. `bash tests/oracle/check.sh` compares grimuah against them and needs no biome, and `test-e2e.sh` runs it. The fixture cannot see the structural layer, because the corpus sits inside one source root and the pre-pass reports nothing there. `test-e2e.sh` covers structural instead.
- The parse sweep covers `/tmp/grimuah-bench` and `/home/cade/dev/sleepy/src`, but not the `lib` and `gateway` directories of sleepy. Those two directories hold 15 files with 1 unknown node each, from a default type parameter on a generic arrow function such as `<T = unknown>(...)`. A function declaration with the same default parameter parses clean, and so does a generic arrow with no default. The rules that read the tree skip any finding under an unknown node, so an unused variable inside such an arrow is missed. The token-level rules still report there, because they read the token stream.
- `src/rules.zig` holds the message each rule prints. `src/lint.zig` carries the same text for the older token engine that the parity test compares against. Change the message in `src/rules.zig`, or the run keeps printing the old text and a check against the frozen oracle still passes.
- `src/lint.zig` is the older token-level engine and the differential oracle. Do not delete it while `src/rules/parity.zig` references it.
- An autoresearch session on this repository meets a commit trap. `log_experiment` runs `git add -A` and `git commit` under a 10s timeout. The hook `.husky/pre-commit` runs `zig build`, `zig build test` and `bash test-e2e.sh`, which take 90-100s. The commit always dies, so every keep stays staged and the logged hashes go stale. Commit by hand, and trust the measurements, not the hashes.

## Verification
1. `zig build test` reports 241 of 241 tests passed.
2. `bash test-e2e.sh` reports 78 passed and 0 failed.
3. `bash tests/oracle/check.sh` prints `corpus findings match the frozen oracle` and exits 0. The fixture holds 91 lint-corpus rows and 18 hygiene rows, and biome validated both sets on 2026-09-12. It is what replaced the two biome differential guards. A deliberate rule change updates the fixture in the same commit. Never re-record to silence a failure.
4. `bash .auto/checks.sh` passes end to end: the unit tests and the e2e suite, which ends with the frozen oracle.
5. The baseline and the candidate binary produce byte-identical output from `grimuah check` in every bench repo and in sleepy. Every change in the session record was proven behaviour-neutral this way.
6. `bash .auto/measure.sh` prints a `check_ms` in the hundreds of milliseconds, prints no `SKIP:` or `FAIL:` line, and exits 0. The run on 2026-09-12 read `check_ms=416` over 30 repos, with `check_sleepy=8ms`. A total in the single digits means that the scan did not run.
7. `bash .auto/paired.sh` prints the median for each repo and a `delta %` against the baseline, and it exits 0.
