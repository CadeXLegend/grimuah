# ideas backlog

## parser: clean over 44k real files (commits 0ada195, 7af0fd9)

stage 2 slice 2 of `.rpiv/artifacts/designs/native-engine.md`. `zig build test` ran
zero tests until commit c0871ee, so the five failures the last session left behind
were fixed first: two were parser bugs (a return annotation read the function body
as part of the type, so every statement in the body was invisible; a `type X = {} |
null` alias was truncated at the closing brace) and three were stale fixtures (two
preset parses used a surface with no `dagOrder`, which the schema requires, so they
failed with `MissingField` before the unknown-field behaviour they target;
`isTextFile` listed `.gitignore`, which never matches the template's `_gitignore`).

`.auto/parse-sweep.txt` + a gated `zig build test` case now parse every source file
under the 29 bench repos and sleepy's sources and fail on any unknown node. first
run: **34,820 unknown files / 1.75M unknown nodes**. now: **0 of 44,237 files**
(106MB). the gaps, in the order they mattered:

- **call arguments tracked their own paren depth** while also calling
  `parseExpression`, which consumes every bracketed group it meets. an argument
  like `(a, b) => c` made the loop read the call's own `)` as nested, so the tail
  came back unknown. that one bug was most of the 1.75M nodes and it hit every
  `reduce`/`find` with an arrow argument
- **`async (params) => body`** read `async` as an identifier called with the
  parameters, so every annotated parameter became an unknown `:`. fixed for
  parenthesised lists, single parameters and `async function`
- **ternary** `cond ? a : b` was not an expression at all: new `conditional` node
  with three children, parsed below assignment
- **`...spread`** in an array or call argument (the IR had the kind, only object
  literals used it)
- **`new Map<string, T>()`**: type arguments were scanned with `skipType`, whose
  terminators include `,`, so it stopped inside the arguments and left `>`
  unknown. `matchingAngle` walks to the closing `>` (handling `>>`/`>>>` and only
  accepting punctuation a type argument list can contain, so `a < b && c > (d)`
  cannot be mistaken for a generic call)
- **`export default { ... }`** was parsed as a block, turning every method in the
  object into a statement

not yet exercised: `.tsx` (no JSX in the sweep roots), decorators, `satisfies`,
`using`, class fields with generics. the parser is not wired to `check`, so none of
this touches `check_ms`, and no measurement is worth running for it (the exe does
not even import `lang/ts.zig`; only the test step does).

## next: the rules are still token-level (design stage 2, unfinished)

`src/lint.zig` enforces grimuah's 14 rules over tokens; `src/ir.zig` + `src/lang/ts.zig`
now parse real code cleanly, but no rule uses the IR yet. worth knowing before
finishing it: most of the 14 rules are token-shaped (em-dash, `let`, `switch`,
`throw`, `==`, null, `as any`, chained casts, re-export), so moving them to the IR is
an **architecture** change, not a speed one, and the full parse can only make `check`
slower. the payoff is stage 3 (a second front-end) and the structural rules that need
scope analysis (`noUnusedVariables`, unreachable code), which the token engine cannot
do at all.

the decision the design still marks as open: what `check` enforces once biome's
built-in ruleset is optional. the built-in lever was already declined (the bench is
blind to it and dropping it is a silent false-negative machine), so "check spawns no
subprocess on the default path" is not reachable without revisiting that.

## the ignore list still lives in biome.json, and the native walk reads none of it

(unchanged from the previous session's note) `lint.zig`'s walk prunes `node_modules`
and `.git`; biome honours `files.includes`. so `grimuah check` reports findings from
`dist/` while biome skips it. the fix needs biome's glob semantics (`!**/dist`,
`**/*.ts`), which is discovery work, so it belongs with the engine slice, and a
partial matcher would risk *under*-reporting, the failure mode that matters.

## done (run 9, commit 5cc3526)
split GritQL rules one-per-file + drop the no-op structural plugin.
`check_ms` 60606 -> 24628, `biome_ms` 60874 -> 24213 (2.5x).

the mechanism, for anyone revisiting plugin cost:

- biome prunes plugin matching by the root node kind of each plugin FILE
- a top-level `` or { A, B, ... } `` with DISTINCT patterns defeats that pruning.
  on 250 files: `or{8}` distinct = 243ms, the same 8 patterns as 8 files = 147ms,
  no plugins = 90ms
- `` or{9} `` of nine *identical* cheap patterns = 98ms, so the cost is pattern
  diversity inside the wrapper, not the wrapper itself
- biome rejects a plugin file with no patterns, so the old structural layer had to
  carry `` `undefined` where {} `` to load at all. that no-op cost 745ms on 5000
  files (9% of biome) and enforced nothing, so it is gone
- one rule per file (14 files) is the max-pruning layout. merging same-root-kind
  rules back into one file only helps if biome can prove the roots are identical,
  which it cannot, so do not bother


## done (run 12, commits 5e780c9 / 29e20dd)
native rule engine. `check_ms` 24724 -> **14071** (1.76x), `overhead_ms` 20.
grimuah's own rules run in-process (`src/lint.zig`, TS tokeniser) and biome is
invoked with `--skip=plugin` whenever biome.json lists exactly the canonical rule
files. `check_ms` is now *below* `biome_ms` (26408) because biome no longer runs
plugin matching; `biome_ms` stops being a floor for grimuah's runs.

the mechanism, for anyone revisiting:
- `biome lint . --profile-rules` on repo-size-1000: 14 plugin rules = 6088ms CPU
  (64%), ~290-910us *per file each*; ~140 built-in rules = 3488ms, 1-2us per file each
- a plugin costs the same whether or not it can match: no file in repo-size-1000
  contains a `switch`, yet `plugin/resilience-switch` burns 311us/file
- verified with `.auto/native-diff.sh` (30 projects: 29 bench repos + a canonical
  overlay of sleepy's sources) and `.auto/lint-corpus/` (105 committed fixtures);
  the harness reads rule messages from `src/gritql.zig` and diffs
  (file, severity, message) against biome's plugin diagnostics

## done: the three dead rules now fire (commit aad2a34)
`cosmetic-em-dash`, `resilience-let` and `resilience-switch` matched nothing in
biome 2.5.11. the cause is not the pattern syntax: biome's GritQL subset cannot
compile those patterns and discards them without a word (12 variants measured,
including `let $n = $v`, `var $n = $v`, `switch ($e) { $c }`,
`switch ($e) { ... }` and a deliberately bogus pattern: all zero diagnostics, no
error on stderr). `const $n = $v` and `throw $e` in the same harness match, so
the pattern language works and these three shapes are what it cannot express.

they are now native-only: `Rule.engine = .native_only` in `src/gritql.zig`, and
`src/lint.zig` enforces em-dash (raw byte scan, it has to reach inside strings,
templates and comments), `let` (declaration forms: `let x`, `let x;`,
`let {a}`, `let [a]`, `for (let i...)`) and `switch`. their `.grit` files keep
shipping so the scaffold documents the rule and biome.json's plugin list stays
stable across the change (no migration needed).

verification: `.auto/native-diff.sh` now diffs the 11 biome-enforceable rules
exactly AND asserts biome reports nothing for the 3 native-only ones, instead of
assuming it. 20 native-only findings on `lint-corpus`, 6 on sleepy's sources (so
real code was carrying live violations that never surfaced). the corpus
expectations are pinned in a unit test because there is no biome oracle to diff
them against, and `.auto/biome-integration.sh` gained a biome-only violation
(`noAssignInExpressions`) so a no-op biome step can no longer hide.

## converged at the biome-built-in floor (run 14, commit e79aeb4)
`check_ms` 13155 and, per repo, equal to raw `biome lint . --skip=plugin`:

    repo        check   biome_skip
    size-5000    1554      1582
    size-3900    1217      1219
    fuzz-08       723       689
    sleepy        233       128 (fallback path: legacy rule layout, biome still
                             runs the 4 legacy plugins)

grimuah's own work is now fully hidden under biome, and what is left is the
built-in `recommended` ruleset over every file (~3.5ms CPU/file, ~36% of biome's
CPU; parse ~18%). that is the project's own biome.json to set, so it is not
grimuah's to shrink. treat the metric as converged; the remaining items are not
speed levers (see the handoff under .rpiv/artifacts/handoffs/).

last 3% came from `maybeTrigger` in `src/lint.zig`: a word-boundary test for
null/for/as/throw/catch plus `==` plus an `export`+ws/comments+`{` scan. the old
needle list included `const` and `export`, which every TS file contains, so it
filtered nothing. any file that passes is tokenised, and a file that cannot
contain a live rule's literal is never read twice.

## measuring a small effect on this box (runs 13/14)
the machine drifts **4-8% over a session of benchmark passes** (12th-gen mobile
CPU, repeated 20-thread biome runs). unpaired samples of the same code, minutes
apart: 12863, 13577. the harness's single-pass verdict resolves ~+/-4%, so a 3%
change cannot be judged by comparing two `measure.sh` runs -- run 13 was
discarded on a number that the paired test later contradicted.

use an interleaved paired A/B instead: keep both binaries, alternate them per
repo (both see the same thermal state), compare medians.

    cp zig-out/bin/grimuah /tmp/grimuah-baseline && git apply <patch>
    zig build -Doptimize=ReleaseSafe && cp zig-out/bin/grimuah /tmp/grimuah-filter
    # per repo: for i in 1 2 3; do time baseline; time filter; done; compare medians

run 14 reported -427ms (-3.2%) that way, improving on 26/30 repos and every repo
over 100 files, while the unpaired `check_ms` samples of the same two binaries
were 13577 vs 13155 -- i.e. noise alone would have decided it wrong.

footgun: `test-e2e.sh` can leave a Debug binary in `zig-out/bin` (~18MB vs 4.8MB
ReleaseSafe), which makes `grimuah check` ~4x slower. `measure.sh` rebuilds first
so the benchmark is safe, but re-run `zig build -Doptimize=ReleaseSafe` before
timing by hand.


## the metric is at the floor (run 15, `df0fbb4`)
`.auto/native-gap.sh` times `check` and raw `biome lint . --skip=plugin` alternately
inside each repo, so drift hits both and the delta is grimuah's own cost:

    repo          check   biome    gap
    sleepy          254      72    +182   <- legacy 4-file layout: biome still runs plugins
    size-5000      1594    1546     +48
    size-3900      1256    1192     +64
    size-2864       929     898     +31
    fuzz-11         687     657     +30
    ... 24 more repos               0..+23
    TOTAL         12804   12288    +516   (4.0% of check_ms)

the ~334ms that is not sleepy is spawn + one read of every lintable file (the
trigger test needs the bytes) + pipe drain. **it is not compute**: two hot-path
rewrites measured neutral over all 30 repos in an interleaved A/B (-7ms) --

- `extractImports` used to run six prefix `mem.eql` calls at *every* source byte;
  hopping between `f`/`i` candidates (every prefix starts with one) is the same
  result for a fraction of the work
- the tokeniser's operator matcher scanned a 60-entry table per punctuation byte,
  i.e. every `)`, `,` and `;` walked ~50 comparisons before the single-char default;
  a first-byte dispatch returns the same operators with a handful of `startsWith`

so the cost is I/O and process spawn, which no amount of scan tuning removes. do
not re-derive this. `check_ms` can only move if something *outside* grimuah
changes: the project's own biome ruleset, or a biome daemon (rejected -- it leaves
a server running, and a one-shot check pays the startup anyway).

the rewrites are worth re-applying only if the pre-pass ever becomes the critical
path; it is single-threaded, so a monorepo far larger than the 5000-file bench
would get there before the benchmark does.

## remaining levers

**superseded (user decision, this session): the native engine replaces biome.**
the bullet below is what the next phase attacks. "nothing to do here without
changing what gets linted" still holds for the biome path, but the plan is now to
stop depending on biome for canonical projects entirely, which takes `check_ms`
from ~13.1s to the cost of grimuah's own scan. see
`.rpiv/artifacts/designs/native-engine.md`.

- **built-in linter + file discovery is now ~47% of biome's cost** (5000 files:
  1567ms of 3340ms with no plugins at all). it is driven by the project's own
  ruleset in biome.json, not by grimuah. nothing to do here without changing
  what gets linted
- **sleepy cannot pick up the new layout**: its `.grimuah-rules/` are frozen and
  `gen-bench.sh` points the synthetic repos at grimuah's scaffold, not sleepy's.
  `generateRules` now rewrites a legacy biome.json plugin list and only fires when
  upgrade actually applies changes, so a project that is already up to date never
  migrates. if sleepy needs the win, either make `upgrade` regenerate rules even
  when there are no new surfaces, or migrate by hand
- **biome daemon (`biome start` + `--use-server`)**: still rejected. a one-shot
  `grimuah check` (pre-commit) would pay daemon startup instead, and leaving a
  server running is an unwanted side effect
- **cache lint results keyed by file hash**: rejected outright, a stale cache
  would let violations slip through
- **startup of the native biome binary (~5ms) + config/plugin load (~20ms/run)**:
  irreducible without a daemon. it is the new floor
- **multiple biome processes**: ruled out. biome already saturates all 20 cores
  (5000 files: 8.4s at 20 cores, 8.4s with 16 concurrent processes over disjoint
  file lists, 64s at 1 core). splitting adds no throughput. passing an explicit
  file list to one process was also measured slower than `.`
- **rule micro-rewrites**: the 9 resilience patterns each cost 5-13ms on 250
  files, roughly uniform. no hot rule to attack
- **dropping the `` `$left == $right` `` rule because biome's built-in
  `suspicious/noDoubleEquals` already errors**: saves ~1/14 of plugin cost but
  replaces grimuah's guidance message with biome's. not worth the UX loss
- **fix the violation count line**: `grimuah check: N violation(s) found` counts
  only pre-pass findings, so a biome-only failure prints `0`. cosmetic, not a
  speed issue, but user-visible now that biome diagnostics actually surface

## dead ends confirmed this session (measurements, not guesses)

- **plugin load is free**: a 1-file project with 14 plugins costs the same as with
  0 plugins (14ms vs 18ms, noise). the cost is all per-pattern *matching*. so the
  biome daemon (whose only real saving is per-run config/plugin load) saves nothing
- **cost is ~linear in plugin count**: repo-size-1000 with 0/1/4/7/14 plugins =
  331/348/394/479/666ms, i.e. ~24ms per rule per 1000 files
- **no hot rule**: each rule measured alone costs 0-46ms (null 38, as-const 46,
  as-any 36, reexport 30, chained-cast 20, the rest 0-15). broadly uniform, so
  there is no single rule to rewrite for a big win
- **`BIOME_THREADS` is a wash**: size-5000 default 3303ms, and 4/8/12/16/24/32
  threads gave 3382/3494/3484/3324/3270/3523ms. biome already saturates the cores
- **`sequential { ... }` is not a way to merge rules**: biome's own parse error
  suggests it ("Grit files may only contain a single pattern. Use `sequential`"),
  but on biome 2.5.11 it panics `grit-pattern-matcher` (index out of bounds) per
  worker and biome still exits 0, so the check would silently report clean
- **split built-in vs plugin runs**: `lint --only=plugin` 468ms and
  `lint --skip=plugin` 350ms vs 692ms combined on repo-size-1000. the parts sum
  to more than the whole (parse is shared), so two processes lose
- **plugin `includes` scoping**: only ~1.7% of the bench files are non-JS, so
  scoping plugins to JS extensions is worth less than measurement noise, and it
  risks dropping coverage on `.js`/`.jsx`

the honest conclusion: ~49% of biome's remaining time is GritQL matching and
~32% is biome's built-in recommended ruleset, ~18% parse. biome's native rules
cost ~1.1ms per rule per 1000 files vs ~24ms for a GritQL rule, i.e. grit is
~20x more expensive per rule. the only way past this floor is to stop using
GritQL for grimuah's own rules, which is a rewrite with real false-positive and
coverage risk. not worth it.

## re-tested after the rule-layout change (run 11)

run 9 changed the plugin cost profile by 2.5x, so the earlier rejections were
retested rather than assumed:

- **multi-process splitting, retested**: still no gain. repo-size-5000 with the
  per-rule layout: 1 process 3207ms; taskset 1 core 24750ms (7.7x on 20 hardware
  threads, i.e. ~55% of 14 physical cores); 2/4/8 concurrent processes over
  disjoint file lists = 3213/3211/3196ms. the box is saturated, so more
  processes cannot help
- **non-source files cost nothing**: biome processes 1017 files for repo-size-1000
  = 1000 TS + 14 `.grimuah-rules/*.grit` + 3 json (68KB of 5.2MB). excluding
  them changes nothing: includes `[**]` 675ms, `[**/*.ts]` 679ms,
  `[**,"!.grimuah-rules"]` 676ms, `[**,"!.grimuah-rules","!*.json"]` 680ms
- **`language js` header**: accepted by biome, no effect (687 -> 696ms)
- **single-file combinators are a trap**: `or{14}` 2792ms, `any{14}` 2910ms vs
  14 separate files 686ms, and both drop one plugin diagnostic (first-match-wins).
  one rule per file stays optimal
- **grimuah's generated biome.json is missing sleep's `files.includes`**
  (`["**","!.pi","!.rpiv","!dist"]`). measured effect on the bench is zero (the
  synthetic repos have no dist/.pi/.rpiv), but for a real project that has run a
  build, biome lints `dist/` because biome only ignores node_modules by default.
  real wasted work and likely false violations on build output. worth fixing as a
  robustness change, but it cannot move `check_ms` and the harness reverts
  non-improving changes

## closed (the GritQL prize was taken in run 12)

plugin matching was 342ms of 692ms on repo-size-1000 (49%), built-in recommended
rules 224ms (32%), parse 126ms (18%). biome's native rules cost ~1.1ms per rule
per 1000 files; a GritQL rule costs ~24ms, i.e. ~20x. run 12 replaced GritQL for
grimuah's 14 rules with native matching (`src/lint.zig`, `--skip=plugin`):
check_ms 24724 -> 14071, then run 14 hid the residual scan cost
(`maybeTrigger` fast path) -> 13155. that idea is done, not pending.

## the built-in ruleset is the last prize, and the bench is blind to it
decided: do not take it (user, this session)

`biome lint . --skip=plugin` over the 29 synthetic bench repos: **11923ms**, of
which the built-in *ruleset* is **8085ms (67%)**; parse + discovery + startup is
3838ms (measured with `rules.recommended: false`). so ~8.1s of `check_ms` 13155
is spent running rules that emit **zero** diagnostics on every bench repo and on
sleepy (`--reporter=json --max-diagnostics=none`, only the biome.json schema
mismatch info appears).

on real TypeScript the same ruleset fires hard, which is why the bench cannot
vote on it: `ndis-invoice-app` (476 files) = 32510 diagnostics
(`noAssignInExpressions` 5472, `noCommaOperator` 5419, `useConst` 4848,
`useArrowFunction` 2606, `noDoubleEquals` 2501, `noUnusedVariables` 2360),
ChatFreak = 20, librelink = 1.

consequences, for whoever revisits:

- ceiling if the built-in rules cost grimuah zero: `check_ms` 13155 -> ~4.6k
  (2.9x). realistically 2-2.5x: `noUnusedVariables`/`useConst`/`noCommaOperator`
  need a real parser + scope analysis, our tokeniser has no AST, and biome 2.5's
  schema carries 539 rule definitions
- every diagnostic dropped is a silent false negative that `check_ms` *rewards*.
  the two existing guards (`biome-integration.sh`, `biome-error-count.sh`) only
  exercise grimuah's own plugin rules, so neither one can catch it either. this
  is the one lever the harness structurally cannot verify
- the scoped alternative (ship an explicit rule list in the generated biome.json
  and enforce it natively, biome only for customized configs) was offered as
  ~2-8x, and declined: it is the same coverage reduction, just with an engine
  built to hide it
- the legacy-layout fallback is the largest single grimuah-owned cost left
  (+182ms of the +516ms gap, sleepy paying biome's 4 frozen plugins) and it is
  not available: sleepy is read-only, and migrating its rules would rewrite its
  diagnostics (its rule text is project-customised)

what is left is spawn + one read per file + drain, ~334ms over 29 repos
(20.5MB of source, ~11ms/repo of process and pipe overhead). no scan rewrite can
touch it: two hot-path rewrites measured -7ms over all 30 repos (run 15).

## done (commit b697ea5): the engine owns the lint scope

the ignore list no longer lives in biome.json. `architecture.config.json` declares
`sourceRoots` and that is the whole scope:

    { "sourceRoots": ["src"], "rootLib": { ... }, "surfaces": [ ... ] }

a file outside every root is not part of the declared architecture, so nothing
lints it. no glob language, no negation patterns, no reimplementation of biome's
`files.includes`: `dist/`, `.rpiv/`, `.pi/` and `.auto/` are excluded because they
are not roots. `mayContainLintedFile` prunes the walk too, so those trees are
never opened rather than opened and filtered.

a config with no `sourceRoots` derives one root per surface, from the surface's
container: its parent, or the surface itself when the parent is the project root.
`src/db` gives `src` (so a file sitting directly in `src` is still linted), a
root-level surface like `gateway` gives `gateway` rather than the repo root.
sleepy's read-only config keeps its intended scope with no migration.

### what this does not cover, and the trap in it

- **biome still scopes itself with `files.includes`.** the two engines therefore
  disagree on any file the roots exclude and biome does not ignore. verified: with
  `sourceRoots: ["src"]`, biome lints a root-level `.rpiv-proof.mjs` and grimuah
  does not. the design's "hand the same list to anything it still shells out to"
  is the remaining half, and the fix is to generate `files.includes` from the
  roots at `init`/`upgrade` time, not to pass paths on the command line (an
  explicit file list was measured slower than `.` in run 11)
- **a root-level source file is no longer linted.** `vitest.config.ts`,
  `playwright.config.ts`, `scripts/*.ts` outside a declared root, and this repo's
  own `test-e2e.sh` style helpers are all outside every root. `init` puts
  everything under `src/` so the scaffold is unaffected, and no bench repo has a
  file outside its surfaces. but there is currently **no way to declare the
  project root itself** as a root: `"."` does not work, because `pathIsWithin`
  does a text-prefix test and `"vitest.config.ts"` does not start with `"."`.
  if a real project hits this, either allow `"."` to mean the project root in
  `lintsFile`/`mayContainLintedFile`, or have `init` add one root per top-level
  directory that has no surface

### measured

interleaved paired A/B over the 30 bench repos against the pre-change engine:
11933ms -> 11922ms, -0.1%. no bench repo has a file outside its surfaces, so the
change cannot move `check_ms` there; the win is `dist/` false positives and not
walking excluded trees at all on real projects

## done: the built-in ruleset is native, and `--biome` is the opt-in

the direction change in `.rpiv/artifacts/designs/native-engine.md` (replace biome,
language-agnostic rules) reached its first paying stage. `grimuah check` no longer
spawns a subprocess on the default path. biome moves behind `--biome`, which is
for a project that wants biome's remaining recommended rules or has its own
plugins.

the subset is the five biome built-ins that catch what a compiler will not:
`noUnusedImports`, `noUnusedVariables`, `useConst`, `noConstantCondition`,
`noUnreachable`. the rest of biome's recommended set is deliberately not
reimplemented (option B in the design: most of the value, a defined and testable
contract).

### what was built

- `src/scope.zig` (new): the file's declarations and what references them. the
  tree supplies declarations, the token stream supplies references, because the
  tree deliberately drops the two places a reference can hide: a type position
  (`import type { T }` used only as `: T`) and an object shorthand (`{ name }`).
  a pure-tree version reports both as unused, i.e. it fails code that is correct
- `src/rules/hygiene.zig` (new): the five rules, each declared `.syntax = .ir`
- `src/ir.zig`: `BindingKind` and `Node.binding`, so a rule can tell a declaration
  the file must use from a parameter the signature already accounts for
- `src/rules.zig`: a `hygiene` layer (not a config layer: on whenever the native
  engine is), `Context.scopes`/`Context.hygiene`, and findings that own their
  message so a rule can name the binding
- `src/commands/check.zig`: `--biome` gates the spawn; **warnings now print**
  instead of waiting for something else to fail (see below)
- `src/engine.zig`: builds the scope table once per file, and the word-boundary
  needle test is bypassed when hygiene is on, because a declaration can be named
  anything

### three parser bugs the migration surfaced

- `import { a as b, c }` recorded only `a`: the clause walk never reset its
  "expect a binding" flag at a comma. it now treats `,` and `as` as clause
  starts, and the name before `as` is not a binding (the module's export is)
- `(value: number) => ...` lost `value`: a `word` followed by `:` was read as an
  object key. now only a key inside a destructuring pattern (`brace_depth > 0`)
- `readonly x = 1;` style class bodies are unaffected, but real projects showed a
  desync that invented a parameter binding, which masked a genuine reference and
  produced a false "unused import". declarations no longer suppress references
  when two bindings share the name: the tokens are ambiguous then, so all of them
  count, which cannot hide a real read

### biome behaviours pinned by the differential harness

`.auto/hygiene-diff.sh <dir>` runs `grimuah check` with every architecture layer
off and diffs `(file, line, rule)` against `biome lint` filtered to the five
categories. `.auto/hygiene-corpus/` is the committed fixture set and
`.auto/checks.sh` runs it. identical on the corpus, sleepy, ChatFreak,
librelink and ndis-invoice-app (476 files, an Angular app the parser only partly
models). the behaviours worth keeping:

- `useConst` is two shapes, not one. an initialised `let` never written again is
  a `const` wherever the later write would sit; an uninitialised one only is when
  its single write is a statement of the same block. sleepy proved it: three
  module-level caches assigned inside an arrow or a try block, which biome leaves
  alone and a name-level count flags
- `x++` is a write, but only when its value is dropped (`n++` alone).
  `const id = n++` and `${++n}` read it. `const sourceCounter = 0; sourceId =
  sourceCounter++` is therefore alive, while `let postIncrement = 1;
  postIncrement++` is unused, and both are biome's answers
- `{ a, ...rest }` spares `a` (typescript-eslint's `ignoreRestSiblings`); an array
  pattern spares nobody
- `while (true)` is exempt from `noConstantCondition`, `do..while (true)` and
  `for (; true; )` are not
- exported bindings, `_`-prefixed names and parameters are exempt

### the two deliberate deviations

- a binding read only from inside its own definition (`function f() { f(); }`)
  counts as used, where biome reports it. telling them apart needs real scope
  resolution, and this is the safe direction: it hides a finding, never invents
  one. pinned by a unit test
- `noUnreachable` prints `This code will never be reached.`; biome appends
  ` because ...` as advice and writes ` ...` into the message. the harness
  normalises the ellipsis

### the structural rules refuse to report in a region the parser could not model

`noUnreachable` reported a real `case` clause in `invoice.component.ts` as dead
code, because the file's mis-parse had nested the switch inside a mis-read block.
both structural rules now skip any node under an `unknown`, which is the contract
`src/ir.zig` already states for `unknown`. that file has 78 unknowns; 327 of
ndis-invoice-app's 476 files have at least one, so the parser's real-project
coverage is the next engine-shaped gap: the sweep (`/tmp/grimuah-bench` +
sleepy) reports 0 of 44,245 files, and an Angular codebase disagrees.

## done: the scan runs on several cores (run 17)

`check_ms` 10445 -> **2453** (4.26x), paired A/B 4.37x over 13 repos, uniform from
250 to 5000 files (3.75x-4.50x). every repo improved, none regressed.

run 16 left the whole scan single-threaded, so a 5000-file repo spent 1.4s of
wall-clock on one core while 19 hardware threads sat idle. the front-end is per
file and shares nothing, so it parallelises cleanly.

the two versions, and why the second one mattered:

- batched, reads on the calling thread: **2.1x**. 8 workers spawning per batch,
  and a serial read phase before each batch. the arithmetic (Amdahl, s + (1-s)/8
  = 1/2.1) put ~40% of the run in the serial part, and the read phase was it
- flat work queue, reads inside the worker: **4.37x**. `std.Io` is documented
  thread-safe, so the read moved to the thread that needs the bytes, batches
  disappeared, and each queue index is claimed once from an atomic counter, so no
  lock is needed anywhere on the hot path

### the details that make it safe

- findings are built with `std.heap.smp_allocator` (thread-safe) by the worker and
  copied into the caller's allocator at the merge, so the caller still owns what
  it frees. the front-end's tokens, tree and scope table stay on a per-worker
  arena, reset with `retain_capacity` per file so a worker does not re-map a
  tree-sized allocation 600 times
- each index is claimed by exactly one worker, so a result slot and its failure
  slot are written by one thread and read after the join. no mutex
- findings are merged in walk order, which is the order the single-core path
  produced, so output does not depend on core count. verified byte-identical
  against the sequential binary on the findings-heavy fuzz repos (704, 851 and
  1515 lines of output)
- below 64 files the run stays on one core: spawning costs more than the scan
  there, and `check_size_10` is unchanged at 8ms. if `Thread.spawn` fails the
  calling thread drains the queue itself
- 8 workers is the cap. a check runs on the machine the editor runs on, so it
  takes a slice of the cores rather than all 20 threads

### what is serial now, and what is left

the walk (directory iteration + one dupe per path) and the merge. on a 5000-file
repo that is now ~330ms total, of which process start is a few ms. the pre-pass
(`src/prepass.zig`) is still single-threaded and still reads every file, so it is
the next candidate if the number needs to move again -- it is now a larger share
of a much smaller total.

## done: the parallel width matched the machine (run 18)

`check_ms` 2453 -> 2184 in the harness sample, but the harness number is the
pessimistic one: a repeat pass gave **2050**, and a paired interleaved A/B over 13
repos gave **1.30x** (uniform, 1.14x-1.35x). the harness's `size-766` read 128ms
against a paired median of 49ms, so one loaded sample moved the sum by ~150ms.

run 17 capped the workers at 8, which was half of this box's 14 physical cores
(20 logical, 6P+8E). the work is per file and memory-bound, so raising the cap to
16 recovered the idle cores: `size-5000` 347 -> 266ms in the paired test.

the ceiling stays, at 16. past the physical core count the workers contend for the
same cores rather than adding throughput, and it keeps a check on a 64-core server
from starting 64 threads for a few hundred milliseconds of work.

### the pre-pass is next, and it is the last single-threaded walk

measured by building a variant with the pre-pass skipped (paired, 3 samples each):
**44ms of 341ms on size-5000 (13%)**, 44 of 271 on size-3900 (16%), 26 of 145 on
fuzz-08 (18%), 12 of 75 on size-1000 (16%). it is 13-19% on every repo with work
to do, and it reads every file in the surface, extracts imports, and walks each
surface directory separately. it has its own Finding type and its own walk, so
parallelising it is a second walk to restructure rather than a flag.

## done: the pre-pass runs while the engine works (run 19)

`check_ms` 2184 -> **1594** (1.37x). paired interleaved A/B over 13 repos: 1.34x,
uniform (1.18x-1.41x). `size-5000` 261 -> 197ms, `size-3900` 208 -> 156,
`fuzz-08` 118 -> 86.

the two stages are independent: the pre-pass walks the tree and reads every file
for suffixes and the import firewall, the engine walks it again and reads every
file for the rules, and neither reads the other's output. running them back to
back put the smaller one on the critical path, so it moved to its own thread
while the engine takes the cores.

**the win is bigger than the pre-pass's own wall time** (measured at 44ms of
341ms on size-5000, 13%). the saving there is 64ms. the reason is that the
pre-pass is mostly I/O, and reads overlap CPU work far better than they overlap
nothing: serialised, its reads were dead time the moment the engine went parallel.

shape, for anyone copying it:

- `PrepassJob` in `src/commands/check.zig`, spawned before the engine and joined
  after. if `Thread.spawn` fails the job runs inline, so a machine that cannot
  thread still checks correctly
- the job gets its own `ArenaAllocator` over `std.heap.smp_allocator`, because the
  caller's allocator is not thread-safe. nothing is copied: the findings print
  before the arena dies, so the ownership contract is unchanged
- findings still print pre-pass first, then native, which is the order they had
  when the two stages ran back to back

verification: output byte-identical to the sequential binary on the fuzz repos
(704, 851, 1515 lines), `test-e2e.sh` 125 (which is what exercises the pre-pass
paths at all: suffix, centralized dirs, firewall, singleton), and the full chain
in `.auto/checks.sh`.

### what is left

the serial parts are now the walk (twice: once per stage), the merge, and process
start. on `size-5000` the total is 203ms, of which ~40ms is process start and
config. the engine's own scan is ~150ms across 16 threads. the remaining ideas
are all smaller than this one was, and one of them is a quality item rather than a
speed one: the parser's real-project coverage (327 of `ndis-invoice-app`'s 476
files carry an unknown node).

## profiling method that works now (run 23)

the scan is CPU-bound and parallel, and the earlier "profile with atomics" approach
is misleading: per-file `fetchAdd` on a shared counter from 16 workers is
cache-line ping-pong, which inflated a *measured* 370ms parse into 919ms and made
every instrumented wall-clock comparison wrong by 20%.

what to do instead:

- **phase breakdown**: copy the tree, add wall-clock accumulators (per worker
  index, no atomics) around tokenise / parse / scope / rules and print them at the
  end of one run. for a contention-free split, run the same instrumented binary
  under `taskset -c 3` (one core, so no atomics contention and no turbo drop)
- **wall-clock truth**: an interleaved paired A/B of two *uninstrumented* binaries
  (`/tmp/paired2.sh`, `PASSES=7`, both alternate per repo). the harness's single
  pass resolves ~±4%, this resolves ~±1-2%
- never time an instrumented binary against a clean one

## where the time is (run 22 state, 5000 files, 16 workers, per-worker wall)

    rules 370ms   scope 331ms   parse 272ms   lex 232ms
    read   32ms   arena reset 2ms   unaccounted ~123ms (9%)
    worker total 1328ms, scan wall 87ms, workers 96.5% busy

reads are 2.4% and the workers are saturated, so the metric moves only when the
per-file CPU does. the ~123ms unaccounted is `readSource`'s allocPrint + the
ArrayList setup + the timer calls themselves.

## scaling curve on this box (size-5000, run 23 binary)

    1 core 1056ms   2: 650   4: 337   8: 185   12: 139   16: 120   20: 116

so 16 workers give 8.8x, not 16x: 6 P-cores + 8 E-cores with SMT, and the last
cores add little. the engine's cap is 16 (`max_lint_workers`); raising it to 20
measured ~5% once, worth retrying only if the box's core count is the target again.

## done (runs 20-23): CPU cuts in the front-end, -32% from 1195 to 924

four changes, each measured with the paired A/B:

- **run 20**: `ts.parse` lexed the file itself, so every file was lexed twice (once
  for the token rules, once inside the parse). `parseTokens` takes the stream the
  engine already built. 1540 -> 1195 (1.29x)
- **run 21**: `matchPunctuation` walked the 60-entry operator table for every
  punctuation byte; first-byte dispatch. 1195 -> 979 (1.22x). this is the same
  rewrite run 15 measured as neutral -- it was neutral because the scan was hidden
  under biome then, not because the rewrite was wrong
- **run 22**: precompute the tree walk order once per file (`ir.WalkEntry` +
  `Module.walkOrder`) instead of making seven consumers chase first_child /
  next_sibling links through 80-byte nodes. a full walk measured 20ns per node;
  the rules and the scope pass paid it seven times. 979 -> 949 (1.043x paired)
- **run 23**: the expression loop's per-token `contains(&binary_operators, ...)`
  (25 strings) and `contains(&assignment_operators, ...)` (16) became
  length-and-first-byte tests. 949 -> 924 (1.026x paired)

## saved, not taken yet: the parser's bracket scans

`/tmp/scanner-fast.patch` (against ts.zig at run 23) rewrites `skipType`,
`matchingParen` and `hasArrowAfter` to first-byte tests. single-core measurement
said 111ms of the parse's 476ms, and the first cut measured 1.042x paired, but
after the exactness fixes it was 1.016x -- inside the noise for a 390-line diff
with three ways to be subtly wrong (`>` vs `>>`, `>>=` vs `>>>`, `==` vs `=>`;
all three were hit while writing it). take it only if the parse becomes the
critical path again, and keep the `angleClosers` helper it introduces.

## session 2026-09-12 (afternoon): the front-end's CPU, runs 25-30

`check_ms` 896 -> **556** (1.61x), eight experiments, all measured with a paired
interleaved A/B before the harness run. `biome_ms` is informational, `overhead_ms`
is 0 (grimuah is faster than raw biome on every repo).

what paid, in order:

- **run 25**: the pre-pass's per-surface file work moved to a flat worker queue
  (8 workers, gated at 64 files/surface). 896 -> 738. the pre-pass was the last
  serial walk and it was on the critical path
- **run 26**: the lexer answered "does `/` start a regex" for *every* word and
  punctuation token. `regex_allowed: bool` became a three-state `RegexState`
  where a word or punctuation token sets `.deferred` and the answer is computed
  on the first read. 738 -> 670. canEndExpression was 13.7% of a run; almost
  every call was avoidable
- **run 27**: `Token.isWord`/`isPunct` and `Parser.peek`/`atEnd`/`atWord`/`atPunct`
  are `inline`, and a one-character punctuation needle is answered from the byte.
  670 -> 638
- **run 28**: `contains(set, text)` compares the length and the first byte before
  `std.mem.eql`, so a keyword lookup stops walking 53 candidates. 638 -> 613
- **run 29**: `engine.lintContent` gained `Teardown = enum { owned, reclaimed }`.
  the worker reclaims its region wholesale, so the front-end's four deferred frees
  were poisoning blocks nobody reads. 613 -> 569. a probe (delete the frees,
  accept the leak) measured 1.069x before the safe version was written
- **run 30**: `scope.analyze` answers "could this word be a declaration" from a
  length-and-first-byte bitmap, and holds every name fact in one map instead of
  four. 569 -> 556

### how to profile this now

`valgrind --tool=callgrind` on `repo-size-250` (about 40s) then
`callgrind_annotate --auto=no --inclusive=yes`. it is the fastest way to see the
real split, and it does not disturb the machine the way the counters do. the state
at run 30, per 250 files, single-core instructions:

    total      247M   (418M before this session)
    prepass     47M   19%   <- overlaps the scan on its own thread
    scope       69M   28%   (hash maps 44M, now much less)
    parse       74M   30%
    lex         17M    7%
    memset      18M    7.6% <- the undefined fill on every allocation

### what is left

- **memset (7.6%) is the `undefined` fill `std.mem.Allocator.alloc` writes**, not
  the frees (run 29 removed those). it cannot be removed through the Allocator
  interface: the fill is in the wrapper, and every backend pays it. reaching it
  means the front-end's hot arrays (`Lexer.tokens`, `Module.nodes`) allocate
  through `rawAlloc` instead of `std.ArrayList`, i.e. a small append-only list
  type. estimated ~1.08x, real risk
- **the pre-pass is 19% of the instructions but runs beside the scan.** it is also
  24 threads on a 14-core box (16 scan + 8 pre-pass). lowering
  `max_prepass_workers` or skipping the pre-pass entirely is a cheap A/B worth
  running before optimising its internals
- **the small repos are startup-dominated**: 12 bench repos under 1050 files sum
  to ~115ms of the 556, and the 10-file repo is 4ms on its own. the empty-project
  cost and what `check` does before it walks anything is worth a look

### harness note (important)

`log_experiment` runs `git add -A && git commit` on keep with a **10s timeout**,
and this repo's husky `pre-commit` runs the 125-check e2e suite (~90-100s). so the
commit is always killed and every keep lands **staged in the index, never
committed** -- which is why runs 20-30 all report `fe22e79`. `discard` is
unaffected: `git checkout -- .` restores from the index, so staged work survives.
do not "fix" this by committing by hand mid-experiment; the staged index is what
protects the previous runs.

## runs 31-34, and how to settle a harness sample the machine disagreed with

- **run 31**: the pre-pass's `extractImports` ran six `std.mem.eql` calls at every
  source byte. `std.mem.indexOfAnyPos(content, pos, "fi")` hops between the only
  two bytes a prefix can start with. 556 -> 551, paired **1.085x**. this rewrite
  was measured neutral in run 15 and parked in the notes: what changed is that the
  pre-pass became the critical path (probe: disabling it entirely was 1.278x)
- **run 32**: `max_prepass_workers` 8 -> 2. 8 threads beside the scan's 16 on a
  14-core box is contention, not throughput. 551 -> 462, paired 1.148x; 1 worker
  measured *worse* than 2 (0.932x), so 2 is the knee. after this, disabling the
  pre-pass entirely is only 1.037x, i.e. that lever is spent
- **runs 33/34**: three leaf rewrites (em-dash hop, identifier byte tables,
  `StaticStringMap` for the 53 keywords) 462 -> 447; then `signal_stack_size = null`
  in `src/main.zig`, which removes the 256KB per-thread TLS block `std.Thread`
  zeroes for every spawned thread. paired **1.120x**, 6.05M instructions removed

### deterministic instruction counts settle what the harness cannot

the harness's `check_ms` moved 447 -> 454 -> 466 across two samples of a change the
paired A/B read as 1.12x, because the *machine* drifted: the control line
`biome_ms` read 23,383 / 25,712 / 26,833 in the same window. when that happens, do
what the paired test cannot do and count work instead of time:

    valgrind --tool=callgrind --callgrind-out-file=/tmp/cg.out <binary> check
    grep Collected /tmp/cg.out

instruction counts do not drift. 180,154,177 -> 174,098,964 is the change, and the
memset attribution (`tls.prepareArea`) says which work went away. use callgrind
totals as the tiebreak and the paired A/B as the wall-clock evidence; treat a
single `measure.sh` sample on a drifting machine as unusable.

### the alloc fill is now the largest leaf, and it needs `rawAlloc`

`std.mem.Allocator.alloc` writes `undefined` over every block it hands out
(`std/mem/Allocator.zig:301`), for every backend and every safe mode. after run 29
removed the *free*-side fill, the alloc side is 6.5% of a run: the file-read buffer
(`Io.Threaded.dirOpenFilePosix`, 2.8M), the token array growth (`Lexer.push`, 1.25M),
the scope name map (1.03M). reaching it means `Lexer.tokens` and `ir.Module.nodes`
allocate through `rawAlloc` instead of `std.ArrayList` (a ~40-line append-only list),
which trades the `undefined` poison for speed: estimated ~1.05-1.08x, and it is the
only remaining item that deletes a safety affordance rather than redundant work.
