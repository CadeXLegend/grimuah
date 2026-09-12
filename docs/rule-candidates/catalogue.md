# grimuah rule guide

the recommended rules, one entry each, with the evidence and the argument behind it

this is the readable version of a 160 KB research record produced against the sleepy corpus
the record itself, the work order derived from it, and the session instruments stayed in the sleepy checkout
what travelled is the rules, the argument for each, and the detectors that measured them

## how to read this

**the corpus.** sleepy `src/`, `lib/` and `gateway/`, 129 TypeScript files, 24,514 lines, read-only
every count below is measured against it, never estimated

**evidence format** `hits / files`
a hit is one place a rule fires
a file count below two means the corpus holds too few examples to prove the rule, not that the rule is wrong

**status markers**

| marker | meaning |
| --- | --- |
| `measured` | passes every gate: actionable, at least 3 hits across 2 files, novel against the shipped rules, free of domain vocabulary, distinct from the other rules, and these 31 carry the metric |
| `below the gate` | real sites, too few of them in a corpus this size |
| `clean` | zero violations, because the corpus already follows the convention |

**the holdout.** every detector also runs against grimuah's own `examples/`, 28 independently generated TypeScript files across 5 projects
`holdout 0` means the rule stayed silent on code it had never seen
one rule fires there and it is right to: the 42 hits are grimuah's own preset configuration, and all 42 entries in it are dead

**examples.** the code shows the shape each rule reacts to, written in the corpus's own style
the `file:line` cites are real sites, measured

---

## start here

ten rules, ordered by how much they buy and how little judgement the fix needs

| rule | signal | why this one | the decision it needs |
| --- | --- | --- | --- |
| `no-export-without-consumer` | 168 / 35 | the largest signal in the set, and the fix is deleting one keyword | exempt the root library, or trim the template's unused helpers |
| `no-duplicated-function-body` | 48 / 23 | identical bodies are identical, so precision costs no argument | none, ship it |
| `max-parameters` | 45 / 19 | every parameter is a position the caller must fill in order | none, ship it |
| `require-capitalised-user-facing-copy` | 38 / 5 | the project wrote this convention into its own style guide | does the tool own copy review at all |
| `require-readonly-collection-signatures` | 30 / 12 | the defect is silent and the damage lands in a file the reader never opened | none, ship it |
| `require-enum-in-config-file` | 29 / 25 | an enum in an implementation module splits one vocabulary across two files | none, ship it |
| `no-optional-properties` | 28 / 5 | an optional field multiplies the states a consumer must guard | none, ship it |
| `no-unread-scalar-result` | 25 / 7 | a failure channel that exists only in the signature | read the result, or narrow the callee to `void` |
| `no-discarded-outcome` | 21 / 7 | the exact silent failure the `Outcome` pattern was built to prevent | none, ship it |
| `no-duplicated-computation` | 26 / 20 | the repo mandate already says extract the formula | whether the gateway may import `lib/` |

**before you add any of them**, repair the shipped rules first
nine defects in grimuah's own checks were still live when this research ran, and five of them are a ban whose matcher is narrower than the ban's own message
the list, with the fix for each, is step 0 of the work order in the sleepy checkout (`GRIMUAH-RULE-PRIORITIES.md`)
a new rule catches less than a broken rule hides

---

# part 1: rules with measured signal

31 rules that pass every gate, 676 hits across 96 files

## types

### no-optional-properties

**flags** an object type that declares an optional property
**evidence** `measured` · 28 hits / 5 files · holdout 0 · `gateway/member-join-bridge.ts:48`
**tier** grit · **severity** warn

```ts
// what it flags: two states the compiler cannot tell apart
type BridgePayload = {
  readonly t?: string;
  readonly d?: unknown;
};

// write this: the states are named
type BridgePayload =
  | { readonly kind: "message"; readonly text: string }
  | { readonly kind: "reaction"; readonly data: unknown };
```

**why it matters** an optional property splits one type into two states that share a name, so every read downstream has to ask what absence means here
the absence is not part of the type's name either, so a reader cannot see which subset of fields is valid together
in practice the field is required on some flows and missing on others, and that difference is a real domain distinction the type is refusing to state
**fix** make the property required and default it at the boundary, or model the states as a discriminated union, reserving `?` for third-party payload shapes you do not control

### require-readonly-collection-signatures

**flags** a mutable array in a parameter, a return type or an object-type property
**evidence** `measured` · 30 hits / 12 files · holdout 0 · `gateway/music-bot.ts:613`
**tier** grit · **severity** warn

```ts
// what it flags
const queueTracks = async (tracks: Track[]): Promise<Track[]> => { /* may sort, may push */ };

// write this
const queueTracks = async (tracks: readonly Track[]): Promise<readonly Track[]> => { /* reads only */ };
```

**why it matters** a parameter typed `Track[]` hands the callee the caller's array and the caller's permission to reorder it
nothing in the signature says whether the function only reads, so a mutation travels back through an alias and surfaces far from the call
on the return side a mutable array claims the caller owns the producer's buffer
on an object type the `readonly` modifier only stops reassignment, leaving `push` and `sort` free to run on data every importer already holds
**fix** type the parameter, the return and the property as `readonly T[]`, widening a downstream api signature when it rejects readonly input rather than dropping the guarantee
class fields are deliberately out of scope: a mutable field is state the class owns rather than a value it was handed
**pair it with** `require-readonly-exported-tables` for the exported table form

### require-readonly-type-members

**flags** a mutable property on an object type
**evidence** `measured` · 13 hits / 5 files · holdout 0 · `gateway/member-join-bridge.ts:131`
**tier** grit · **severity** warn

```ts
// what it flags
type BridgeState = {
  heartbeatTimer: ReturnType<typeof setInterval> | undefined;
  heartbeatIntervalMs: number;
};

// write this
type BridgeState = {
  readonly heartbeatTimer: ReturnType<typeof setInterval> | undefined;
  readonly heartbeatIntervalMs: number;
};
```

**why it matters** a mutable property lets any consumer edit a value another layer still holds, which makes the mutation site invisible and the data flow untraceable
the type stops describing a shape and becomes a mutable cell
**fix** add `readonly` to every property signature
when a layer genuinely needs a changed copy, build a new object of the same type rather than editing one in place

### require-enum-over-literal-union

**flags** a union of two or more string literals
**evidence** `measured` · 3 hits / 3 files · holdout 0 · `src/services/music.service.ts:92`
**tier** grit · **severity** warn

```ts
// what it flags
type MusicControlRequest = { readonly direction: "up" | "down" };

// write this
export enum VolumeDirection {
  Up = "up",
  Down = "down",
}
type MusicControlRequest = { readonly direction: VolumeDirection };
```

**why it matters** a literal union carries the type and no runtime value, so every comparison against it is a retyped magic string
the set of allowed values is invisible at the call site, and adding a member is a text edit nobody can search for
it is the weaker half of the construct the shipped `as const` ban exists to close
**fix** declare a string enum beside the config it belongs to and use its members as the discriminant, so the values exist once as a value and once as a type
the union form is only correct where the value must survive a boundary that cannot execute an enum, which is why process entry modules are out of scope

## resilience

### no-discarded-outcome

**flags** a call that returns an `Outcome` whose result is dropped as a bare statement
**evidence** `measured` · 21 hits / 7 files · holdout 0 · `src/bot.ts:235`, `src/commands/sleep.command.ts:226`
**tier** grit · **severity** warn

```ts
// what it flags: the failure branch is now unreachable
await creditAccountBalance(env, userId, wagerDreams);

// write this
const credited = await creditAccountBalance(env, userId, wagerDreams);
if (!credited.succeeded) {
  return { succeeded: false, reason: credited.reason };
}
```

**why it matters** the behavioural layer routes every failure through an `Outcome` so a caller cannot forget it
an `Outcome` used as a bare statement is discarded before it is read, so the failure branch becomes unreachable and the error disappears with no log and no return
that is the exact silent failure the pattern was introduced to prevent
the rule cross-references declared return types across the whole corpus, so it needs no type checker, and it only fires when every declaration of a name agrees it returns an outcome, which is what keeps the corpus's 20 duplicate function names from producing a false hit
**fix** assign the result and branch on `succeeded`, returning a matching failure when the call fails
where the call is genuinely best effort, say so by logging the failure instead of dropping the value

### no-unread-scalar-result

**flags** a call whose declared result is a bare `boolean` or `number`, where nothing reads that result
**evidence** `measured` · 25 hits / 7 files · holdout 0 · `src/bot.ts:84`, `src/services/spirit-chase.service.ts:656`
**tier** prepass · **severity** warn

```ts
// what it flags
await deleteChaseMessage(context, chaseId);

// write this, option one: read it
const deleted = await deleteChaseMessage(context, chaseId);
if (!deleted) context.logger.warn("chase message already gone", { chaseId });

// write this, option two: stop claiming a signal the caller never consumes
const deleteChaseMessage = async (context: ChaseContext, chaseId: string): Promise<void> => { /* ... */ };
```

**why it matters** a function that settles to a scalar can only report failure by returning the value that also means a real answer
when the caller drops the result the operation has neither reported its failure nor been told to, so the failure channel exists only in the signature
the reader of the call site cannot tell whether the author decided the result did not matter or never noticed there was one
`deleteChaseMessage` is the clearest case: it distinguishes a 404, where the message is already gone and that is success, from any other failure, logs the real one, and collapses both into `true`/`false`
none of its five callers reads it, so the distinction the function took care to draw is discarded at every call site
**fix** read the result and act on it, or log the failure at the call site so the intent is stated, or narrow the callee to `Promise<void>`
**note** this is the call-site half of the sentinel finding and a separate rule from `no-async-scalar-failure-return`, not the same idea twice
the declaration rule sees five exported functions, this one sees every scalar-settling callee including module-private helpers, and the two have different fixes

### no-async-scalar-failure-return

**flags** an async operation that can fail but reports its failure as a bare `boolean` or `number`
**evidence** `measured` · 5 hits / 3 files · holdout 0 · `lib/kv-register.ts:50`, `src/services/xp.service.ts:92`
**tier** prepass · **severity** warn

```ts
// what it flags: false conflates a failed read with a failed write, and the reason is gone
export const addRegisterId = async (kv: KVNamespace, id: string): Promise<boolean> => { /* ... */ };

// write this
export const addRegisterId = async (kv: KVNamespace, id: string): Promise<RegisterOutcome> => {
  const ids = await readRegisterIds(kv);
  if (!ids.succeeded) return { succeeded: false, reason: ids.reason };
  return writeRegisterIds(kv, [...ids.result, id]);
};
```

**why it matters** `false` and `1` are valid business values, so the caller cannot separate the answer from the error, and the reason the operation already held is dropped at the boundary that had it
`readXpBoostMultiplier(): Promise<number>` is the sharpest case: a KV failure returns `1`, which silently under-awards xp and looks exactly like a multiplier of one
**fix** declare the result as the outcome value carrying both branches, so the settled type names a failure reason beside the data
a caller with no use for the outcome can narrow it out explicitly instead of guessing at a scalar
**note** precision rests on the corpus's own convention rather than the rule's taste: 55 of 55 exported async functions in `src/db/` and every message-handling helper in `src/services/` already return an `Outcome`, so these five are recognisable deviations
`Promise<void>` returns are deliberately out of scope: a void operation makes no claim about success where a boolean makes a false one

## sql

### require-limit-on-collection-reads

**flags** a query that reads a collection without a `LIMIT`
**evidence** `measured` · 7 hits / 5 files · holdout 0 · `src/db/catches.repo.ts:130`
**tier** grit · **severity** warn

```ts
// what it flags
env.DREAMS_DB.prepare("SELECT user_id FROM catches WHERE fish_id = ? AND quantity > 0").all();

// write this
env.DREAMS_DB.prepare("SELECT user_id FROM catches WHERE fish_id = ? AND quantity > 0 LIMIT 100").all();
```

**why it matters** a `prepare` chain that ends in `.all()` returns every matching row
a `where` clause bounds the result only by today's data, so one prolific account turns a lookup into a full table transfer, and the cost grows silently because the query text never changes when the row count does
**fix** add an explicit `LIMIT` and paginate with an offset or a keyset cursor when the caller genuinely needs everything

### no-duplicated-statement-text

**flags** one SQL statement written in two places
**evidence** `measured` · 6 hits / 2 files · holdout 0 · `src/db/accounts.repo.ts:127`
**tier** prepass · **severity** warn

```ts
// what it flags: the same statement, against two handles named for different tables
// src/db/accounts.repo.ts
accounts.prepare("UPDATE accounts SET balance = balance - ? WHERE user_id = ? AND balance >= ?");
// src/db/consumables.repo.ts
env.DREAMS_DB.prepare("UPDATE accounts SET balance = balance - ? WHERE user_id = ? AND balance >= ?");

// write this: one declaration both call sites name
// src/db/accounts.repo.ts
export const DEBIT_BALANCE_STATEMENT =
  "UPDATE accounts SET balance = balance - ? WHERE user_id = ? AND balance >= ?";
```

**why it matters** a statement is the contract a module keeps with the shape of its rows, so two copies are two contracts that drift
a column added to one and not the other leaves two spellings of the same fact, and the failure is silent because both copies run
a different receiver hides the repeat from every other duplication check, since one call site prepares it on a handle named for one table and the other on a handle named for another, which leaves the statement text as the only part that must not be written twice
**fix** declare the statement once as a module-level constant, or as one exported helper both call sites call

## declarative

### no-for-of-push-accumulation

**flags** a `for..of` loop that builds an array through `push` or `unshift`
**evidence** `measured` · 6 hits / 6 files · holdout 0 · `src/services/family-tree.service.ts:161`
**tier** grit · **severity** error

```ts
// what it flags
const names: string[] = [];
for (const member of members) {
  names.push(member.name);
}

// write this
const names = members.map((member) => member.name);
```

**why it matters** a loop that pushes into an array is a `map`, a `filter` or a `reduce` written the long way
the reader has to run the loop in their head to learn what the result contains, the accumulator is a mutable binding the rule set otherwise forbids, and the body hides whether elements are kept, dropped or transformed
**fix** express the transformation with `map`, `filter`, `flatMap` or `reduce`
when the body is genuinely side-effecting, keep the `for..of` and drop the accumulator

### no-if-chain-dispatch

**flags** a run of three or more branches that test one subject
**evidence** `measured` · 3 hits / 3 files · holdout 0 · `src/handlers/interaction.handler.ts:121`, `gateway/member-join-bridge.ts:316`
**tier** grit · **severity** warn

```ts
// what it flags
if (action.kind === "join") return onJoin(action);
if (action.kind === "leave") return onLeave(action);
if (action.kind === "move") return onMove(action);

// write this
const handlers: Record<ActionKind, (action: Action) => void> = {
  [ActionKind.Join]: onJoin,
  [ActionKind.Leave]: onLeave,
  [ActionKind.Move]: onMove,
};
handlers[action.kind](action);
```

**why it matters** the shipped switch ban states the intent as use a dispatch table, and an if-chain of predicate tests and early returns is the same construct with the same properties: one linear scan, one function to edit to add a case, and no place that lists the cases
it also passes the ban, which is why the loophole survived
the run is recognisable without types because every branch tests the same subject and every branch returns, which is what separates a dispatch from a run of unrelated guards
**fix** declare a `Record` or `Map` from the subject's value to the handler
keep the if-chain when the branches test genuinely different conditions rather than different values of one subject

## complexity

### max-parameters

**flags** a callable with more than four parameters
**evidence** `measured` · 45 hits / 19 files · holdout 0 · `src/commands/dream-fishing.command.ts:41`
**tier** grit · **severity** warn

```ts
// what it flags
const grant = async (env, guildId, userId, level, heldRoleIds) => { /* ... */ };

// write this
type GrantInput = {
  readonly env: CommandEnv;
  readonly guildId: string;
  readonly userId: string;
  readonly nextLevel: number;
  readonly heldRoleIds: readonly string[];
};
const grant = async (input: GrantInput) => { /* ... */ };
```

**why it matters** each parameter is a position the caller must fill in the right order, so a long parameter list makes every call site a puzzle and every reordering a silent bug
it is also the shape that appears when a function has grown to need data from several layers instead of receiving one cohesive value
**fix** group the parameters into a named readonly type and pass one object, or split the function until each part needs fewer inputs

### no-nested-ternary

**flags** a conditional expression containing another conditional expression
**evidence** `measured` · 18 hits / 4 files · holdout 0 · `src/commands/music.command.ts:133`
**tier** grit · **severity** warn

```ts
// what it flags
const label = isPlaylist
  ? isShuffled ? ShuffledPlaylist : PlainPlaylist
  : isQueued ? QueuedSingle : Idle;

// write this
const labelByShape: Record<QueueShape, string> = {
  [QueueShape.ShuffledPlaylist]: ShuffledPlaylist,
  [QueueShape.PlainPlaylist]: PlainPlaylist,
  [QueueShape.QueuedSingle]: QueuedSingle,
  [QueueShape.Idle]: Idle,
};
const label = labelByShape[shapeOf(queue)];
```

**why it matters** a nested ternary turns a two-branch decision into a tree the reader must evaluate branch by branch
the conditions read in one direction and the results in another, so the reader holds two conditions at once just to know which branch they are standing in
**fix** extract the inner decision into a named helper, look the branch up in a `Record`, or replace the chain with early returns when it chooses between statements

### max-function-lines

**flags** a function body longer than 80 lines
**evidence** `measured` · 20 hits / 15 files · holdout 0 · `gateway/music-bot.ts:892`, 166 lines
**tier** grit · **severity** warn

```ts
// what it flags: 166 lines, and the name only describes the first dozen
private async dispatchCommand(guild: Guild, command: ControlCommand): Promise<ControlEnvelope> { /* ... */ }

// write this: ordered calls, each with a name that says what it does
const dispatchCommand = async (guild: Guild, command: ControlCommand): Promise<ControlEnvelope> => {
  const resolved = resolveControlCommand(command);
  const authorized = await authorizeControlCommand(guild, resolved);
  const applied = await applyControlCommand(resolved);
  return replyWithControlResult(applied);
};
```

**why it matters** a long function accumulates responsibilities because every addition looks local, and the name stops describing the whole body
the only way to test one branch is to reproduce the state the earlier branches built, so the deepest branches are the least tested
length is the cheapest proxy for how many jobs a function is doing
**fix** extract each distinct job into a named function with its own return type and leave the original as an ordered sequence of calls

### max-file-lines

**flags** a module longer than 500 lines
**evidence** `measured` · 12 hits / 12 files · holdout 0 · `gateway/music-bot.ts:1`, 1323 lines
**tier** grit · **severity** warn

```ts
// what it flags: 1323 lines in one module, with section comments marking the seams
// gateway/music-bot.ts
// ---- queue handling ----
// ---- playback control ----
// ---- query resolution ----

// write this: one module per seam, each named for what it owns
// gateway/music-queue.ts      gateway/music-playback.ts      gateway/music-query.ts
```

**why it matters** a module past the cap has almost always grown a second responsibility, because the first one no longer fits the file's name
every reader pays the whole file's cost to find one function, and the file becomes the place changes are made by default rather than the place one concern is expressed
**fix** split along the responsibilities already visible in the section comments, giving each extracted part a name that says what it does and an import edge that shows who needs it

### max-cyclomatic-complexity

**flags** a function body with more than 15 independent paths
**evidence** `measured` · 7 hits / 6 files · holdout 0 · `gateway/music-bot.ts:892`, complexity 29
**tier** grit · **severity** warn

```ts
// what it flags: complexity 29, each branch doubling the states to reason about
if (kind === "play") { /* ... */ } else if (kind === "pause") { /* ... */ } else if (kind === "skip") { /* ... */ }

// write this
const controlHandlers: Record<ControlKind, ControlHandler> = {
  [ControlKind.Play]: handlePlay,
  [ControlKind.Pause]: handlePause,
  [ControlKind.Skip]: handleSkip,
};
controlHandlers[kind](input);
```

**why it matters** cyclomatic complexity counts the independent paths a reader must hold in their head at once
past the threshold, tests stop covering the branches and start covering the happy path, and the function is usually several decisions that were never separated
**fix** extract each decision into a named predicate or lookup, replace branch chains with a `Record` dispatch table, and move the removed cases into their own functions with their own names

## performance

### no-await-in-loop

**flags** an `await` inside a loop body
**evidence** `measured` · 11 hits / 5 files · holdout 0 · `src/services/family-consent.service.ts:582`, `src/services/family.service.ts:235`
**tier** grit · **severity** warn

```ts
// what it flags: n items, n sequential round trips
for (const targetId of activeTargetIds) {
  const record = await familyKv.get<ConsentRecord>(buildConsentKey(targetId), "json");
  /* ... */
}

// write this: one round trip's worth of latency
const records = await Promise.all(
  activeTargetIds.map((targetId) => familyKv.get<ConsentRecord>(buildConsentKey(targetId), "json")),
);
```

**why it matters** an `await` in a loop body suspends once per element, so the latency is n times the slowest dependency and the pattern silently turns a linear scan into the dominant cost of the request
**fix** map the items to promises and await `Promise.all` once, or use `Promise.allSettled` when one rejection must not cancel the rest
keep the loop only when iteration n truly depends on iteration n minus one

## patterns

### no-duplicated-function-body

**flags** a function whose body is byte-identical to a same-named function in another file
**evidence** `measured` · 48 hits / 23 files · holdout 0 · `gateway/bridge.smoke.ts:21`, 4 copies of `assert`
**tier** prepass · **severity** warn

```ts
// what it flags: the same four lines, copied into four smoke modules
// gateway/bridge.smoke.ts, gateway/market-price.smoke.ts, ...
const assert = (condition: unknown, message: string): void => {
  if (!condition) throw new Error(message);
};

// write this: one declaration everyone imports
// lib/assert.ts
export const assert = (condition: unknown, message: string): void => { /* ... */ };
```

**why it matters** an identical copy is not a coincidence, it is the same decision written twice
a fix or a rule change has to be found and applied in every copy, and the copies drift one bug report at a time because nothing marks them as related
the compiler sees two independent functions, and so does every reader
**fix** move the implementation into the shared library and import it, keeping one declaration whose name is the single answer to what the helper does

### no-duplicated-computation

**flags** one computation written twice, in two files
**evidence** `measured` · 26 hits / 20 files · holdout 0 · `gateway/music-messages.ts:37`, `src/services/music.service.ts`
**tier** prepass · **severity** warn

```ts
// what it flags: the same formula, two files
// gateway/music-messages.ts              // src/services/music.service.ts
Math.floor(totalSeconds / 60);            Math.floor(elapsedSeconds / 60);
Math.floor(totalSeconds % 60);            Math.floor(elapsedSeconds % 60);

// write this
// lib/duration.ts
export const toMinutes = (totalSeconds: number): number => Math.floor(totalSeconds / 60);
export const toRemainingSeconds = (totalSeconds: number): number => Math.floor(totalSeconds % 60);
```

**why it matters** an identical expression in two modules is one decision written twice, so a change to the unit, the rounding or the route has to be found and applied in both copies
the compiler sees two independent expressions, and so does the reader, which makes the second copy invisible to any search that looks for a call by name
the repo's own mandate states it plainly: do not write the same derived computation twice, extract it
**fix** extract the expression into a named function in the shared module at the bottom of the dependency order and call it from both places
**scope** the rule keeps an expression that builds a value and leaves predicates alone
a census started at 100 sites and kept 26, because the largest groups are the project's dialect: a type guard written ten times, a 404 check written ten times, an option-type test written six times

### no-renamed-duplicate-body

**flags** a function body copied into another file under a new name
**evidence** `measured` · 8 hits / 7 files · holdout 0 · `src/services/afk.service.ts:187`, 8 copies of one predicate
**tier** prepass · **severity** warn

```ts
// what it flags: one predicate, eight declarations, three spellings
// src/services/afk.service.ts
const isRecordWithId = (value: unknown) => isRecord(value) && typeof value.id === "string";
// src/services/dream-journey.service.ts
const isMessageWithId = (value: unknown) => isRecord(value) && typeof value.id === "string";
// and five more files
const isChannelWithId = (value: unknown) => isRecord(value) && typeof value.id === "string";

// write this
// lib/is-record-with-id.ts
export const isRecordWithId = (value: unknown): value is { readonly id: string } =>
  isRecord(value) && typeof value.id === "string";
```

**why it matters** the identity of a helper is its body and not its name, so a copy whose author renamed the declaration is still one decision written twice
a search for the helper's name finds only the copy that kept it, and the copies drift one bug report at a time
this is the blind spot of `no-duplicated-function-body`, which keys on the name as well as the body
that key is what makes it exact, and the same key is why a renamed copy is invisible to it
five of the eight copies are called `isMessageWithId`
**fix** keep one declaration in the shared module at the lowest layer both callers can reach, and give it the name both call sites can read

### no-duplicated-user-facing-copy

**flags** the same user-facing sentence written out in three or more files
**evidence** `measured` · 19 hits / 19 files · holdout 0 · `"This command only works in a server."` in 19 config files
**tier** prepass · **severity** warn

```ts
// what it flags: one sentence, nineteen files
// src/commands/afk.command.config.ts
export const AfkMessages = { GuildOnly: "This command only works in a server." } as const;
// src/commands/buy.command.config.ts
export const BuyMessages = { GuildOnly: "This command only works in a server." } as const;

// write this: declare it once and import it
// lib/guild-only-message.ts
export const GuildOnlyMessage = "This command only works in a server.";
```

**why it matters** copy pasted into each file drifts the moment one site is edited, and a wording change becomes a search across the codebase instead of one edit at the owning constant
the reader also cannot tell whether two identical sentences are the same message or two messages that happen to match today
**fix** declare the sentence once in the owning surface's `.config.ts` enum and import it, or lift it to `lib` when several surfaces share it
**threshold** three distinct files, chosen so the deliberate command-description mirroring between `src/commands/*.command.ts` and `gateway/register-commands.ts`, 48 strings across 2 files, is not flagged

### no-repeated-inline-copy

**flags** user-facing copy written out twice inside one file
**evidence** `measured` · 15 hits / 5 files · holdout 0 · `src/bot.ts:69,113`, `gateway/music-bot.ts:928,1022`
**tier** prepass · **severity** warn

```ts
// what it flags: the cross-file rule cannot see this until it spreads three ways
await reply("Nothing is playing right now.");
// ... 90 lines later
await reply("Nothing is playing right now.");

// write this
const NothingPlayingMessage = "Nothing is playing right now.";
```

**why it matters** this is the smallest and most common form of the copy defect, and the cross-file rule is blind to it by construction
a wording change updates one copy and leaves the other saying something the author no longer means
**fix** declare the sentence once, as an entry in the owning `.config.ts` or as a module-level constant, and let every statement name that entry
**scope** a `.config.ts` file is out of scope by construction rather than by convenience: declaring the sentence there is the first half of the fix, so a repeat inside one is a duplicate data entry and a different rule's problem

### no-literal-duplicating-config-value

**flags** a string literal that retypes a value the same surface's config declares
**evidence** `measured` · 16 hits / 2 files · holdout 0 · `src/commands/music.command.ts:94`
**tier** prepass · **severity** warn

```ts
// what it flags: "play" duplicates MusicSubcommandName.Play
if (subcommand === "play") { /* ... */ }

// write this
if (subcommand === MusicSubcommandName.Play) { /* ... */ }
```

**why it matters** the enum is the single source of truth for the value and the literal is a second copy the compiler cannot keep in step
changing the enum silently leaves the literal comparing against the old text, and a reader cannot tell whether the match is deliberate or whether it used to be a different value
**fix** import the enum and reference the declaration, so a rename or a value change is a one-line edit that every comparison follows

### no-boolean-flag-argument

**flags** a bare boolean literal passed as an argument
**evidence** `measured` · 21 hits / 4 files · holdout 0 · `src/services/family-consent.service.ts:271,441`
**tier** grit · **severity** warn

```ts
// what it flags: the call site reads as a bare false
buildConsentButtonRow(false);

// write this: name the behaviour the caller asked for
buildConsentButtonRow(ConsentPrompt.Ask);
// or give the two behaviours their own names
buildConsentRequestRow();
```

**why it matters** a boolean argument makes one function do two jobs and hides which job the call site asked for
`true` and `false` read identically at the call, so the reader has to open the callee to learn what the position means, and every new variant adds another positional flag only the callee can decode
**fix** give the two behaviours their own named functions, or pass a named enum or union value
keep a boolean parameter when the callee is a third-party api whose signature you do not control

### require-capitalised-user-facing-copy

**flags** user-facing copy that does not start with a capital letter
**evidence** `measured` · 38 hits / 5 files · holdout 0 · `src/commands/music.command.config.ts:68`
**tier** grit · **severity** warn

```ts
// what it flags
export const MusicMessages = { Hidden: "and {hiddenCount} more queued" } as const;
export const GuideMessages = { Campfire: "the campfire of the land, where the whole server talks" } as const;

// write this
export const MusicMessages = { Hidden: "And {hiddenCount} more queued" } as const;
export const GuideMessages = { Campfire: "The campfire of the land, where the whole server talks" } as const;
```

**why it matters** copy that starts lowercase reaches the user as a sentence fragment, and the same message renders differently depending on whether it is shown alone or spliced after another line
the rule the project already documents stops being enforceable the moment it lives only in a style guide
**fix** capitalise the first letter, keeping proper nouns and inline identifiers as they are, and keep template placeholders out of the first position so the capital is not swallowed by substitution

## architecture

### no-export-without-consumer

**flags** an exported binding that no other module ever names
**evidence** `measured` · 168 hits / 35 files · holdout 0 · `src/db/accounts.repo.ts:8`, `src/db/catches.repo.ts:3`
**tier** prepass · **severity** warn

```ts
// what it flags: the export promises an audience that does not exist
// src/db/accounts.repo.ts
export type GetAccountBalanceOutcome = Outcome<number>;   // no other module names this

// write this
type GetAccountBalanceOutcome = Outcome<number>;
export const getAccountBalance = async (/* ... */): Promise<GetAccountBalanceOutcome> => { /* ... */ };
```

**why it matters** the `export` keyword widens a symbol's audience to the whole project, so a reader who finds one has to assume something outside can depend on its shape
when no other module ever names the symbol, that promise is false, the declaration is really module-private, and every future edit carries a compatibility question the project cannot answer
this is the visibility half of dead code and a different defect from a declaration nothing uses at all: the symbol stays live inside its own module and only the keyword is wrong, which is why the fix is one word
**fix** drop the `export` keyword when only this module names the symbol
keep it when another module is meant to, then have that module name it, which is what makes the contract visible
**scope** top-level root modules, the shared library and process entry points, are out of scope
their export list is an api no single application can prove unconsumed

### require-enum-in-config-file

**flags** an exported enum declared outside a `.config.ts` module
**evidence** `measured` · 29 hits / 25 files · holdout 0 · `src/db/accounts.repo.ts:3`, `src/db/catches.repo.ts:3`
**tier** prepass · **severity** warn

```ts
// what it flags: the vocabulary lives in the module that implements the behaviour
// src/db/accounts.repo.ts
export enum AccountFailureReason {
  NotFound = "not-found",
  InsufficientFunds = "insufficient-funds",
}

// write this
// src/db/accounts.config.ts
export enum AccountFailureReason { /* ... */ }
// src/db/accounts.repo.ts
import { AccountFailureReason } from "./accounts.config.ts";
```

**why it matters** an enum is a configuration constant, and grimuah gives configuration its own innate member so its dag order is declared rather than inherited from whatever module happened to declare it
when the enum lives in the repository or service that raises it, every consumer imports an implementation module to read a constant, and the declaration drifts into an import cycle because the module that owns the behaviour ends up owning the vocabulary too
29 exported enums across 25 files is the largest architectural finding in the set
**fix** move the enum into the surface's `.config.ts` file, creating it when the surface has none, so the constant has a declaration home and the implementing module exports behaviour only

### require-shared-type-placement

**flags** a type consumed from another directory while declared in an implementation module
**evidence** `measured` · 6 hits / 3 files · holdout 0 · `src/db/liked-tracks.repo.ts:20`, `src/db/spirit-chase.repo.ts:15`
**tier** prepass · **severity** warn

```ts
// what it flags: a shared shape living inside the module that implements behaviour
// src/db/liked-tracks.repo.ts
export type LikedTrack = { readonly trackId: string; readonly title: string };

// write this
// src/db/liked-tracks.types.ts
export type LikedTrack = { readonly trackId: string; readonly title: string };
```

**why it matters** when the shared type sits inside the module that also implements behaviour, every consumer of the type imports the implementation
the dependency the import firewall reasons about is no longer the one the reader sees, the consumer is coupled to that module's other exports, and the type and the behaviour can no longer change independently
**fix** declare the type in the surface's `.types.ts` file, which gives the shared shape its own module, keeps the import edge pointing at a declaration, and lets the implementing module keep its behaviour private
**note** enums are handled by `require-enum-in-config-file` instead, so the two rules never offer the same fix twice

### no-import-cycles

**flags** two files that import each other, even inside one surface
**evidence** `measured` · 5 hits / 5 files · holdout 0 · `gateway/music-messages.ts:18`, `src/services/family.types.ts`
**tier** prepass · **severity** error

```ts
// what it flags
// gateway/music-messages.ts
import { formatNowPlaying } from "./music-bot.ts";
// gateway/music-bot.ts
import { buildQueueMessage } from "./music-messages.ts";

// write this: the shared symbols get their own module
// gateway/music-format.ts
export const formatNowPlaying = (track: Track): string => { /* ... */ };
```

**why it matters** the import firewall keeps imports flowing from deep surfaces to shallow ones, but two files at the same `dagOrder` can still import each other
a cycle makes module initialisation order load-bearing, hides the true dependency direction, and lets a value read at module scope be `undefined` depending on which file the runtime reached first
**fix** lift the shared symbols into a third module at or above the shallower of the two, or invert one direction with a callback or a parameter so the dependency points one way

### config-declares-data-only

**flags** a function exported from a `.config.ts` module
**evidence** `measured` · 4 hits / 3 files · holdout 0 · `src/services/divination.service.config.ts:13`, `src/services/spirit-chase.service.config.ts:72`
**tier** grit · **severity** warn

```ts
// what it flags: behaviour at the lowest layer of the surface
// src/services/divination.service.config.ts
export const currentDateKey = (): string => new Date().toISOString().slice(0, 10);

// write this
// src/services/divination.service.ts
const currentDateKey = (): string => new Date().toISOString().slice(0, 10);
```

**why it matters** a config file sits at the lowest `dagOrder` of its surface, so an exported function there is callable from every layer above it with no firewall rule describing the dependency
the file stops being a declaration and becomes a module of behaviour that bypasses the surface that owns it, and because the function usually needs types or constants from the surface, it pulls the config into an import cycle the graph cannot express
**fix** move the function into the surface's own module, or into `lib` when several surfaces need it, and keep the config file exporting enums and constants only

### no-redundant-allowed-import

**flags** an `allowedImports` entry naming a shallower surface
**evidence** `measured` · 13 hits / 5 files · **holdout 42** · `src/commands/afk.command.config.ts:1`
**tier** prepass · **severity** warn

```jsonc
// what it flags: the dag already permits commands -> lib, so the entry is never read
{
  "name": "commands",
  "path": "src/commands",
  "dagOrder": 5,
  "allowedImports": ["lib", "db"]
}

// write this
{
  "name": "commands",
  "path": "src/commands",
  "dagOrder": 5,
  "allowedImports": []
}
```

**why it matters** the import firewall already permits every import from a deeper surface to a shallower one, because `canImport` returns true before it consults the allowlist
an entry naming a shallower surface is therefore dead configuration the checker never reads, and once those entries are indistinguishable from the default, a reader cannot tell which grants are load bearing and the allowlist stops adding up to anything
this is the one rule that fires on the holdout, and it fires correctly: all 42 entries across grimuah's five presets are DAG-implied
**fix** delete the entry and keep only the grants that permit a real backward edge
**read priority 5 of the work order in the sleepy checkout before adopting it**: fix the mechanism or empty the preset lists first, or the rule reports grimuah's own configuration

---

# part 2: conventions worth locking in

40 rules the corpus already satisfies
each measured zero violations, which is the point: they encode conventions the project follows by discipline today, so they cost nothing now and stop the discipline eroding
they are also the natural fixtures for a conformance suite, which is the test gap the shipped rules leave

## types

### require-readonly-exported-tables · `clean`

**flags** an exported array literal without `as const` or a readonly annotation
**evidence** 19 of 19 exported tables already comply

```ts
// what it flags: one push anywhere changes the table for the whole process
export const FishRarities = ["common", "uncommon", "rare"];

// write this
export const FishRarities = ["common", "uncommon", "rare"] as const;
```

**why it matters** every exported array literal is a mutable reference handed to every importer, so a single `push` anywhere changes the table for all of them, and the drift is untraceable because no call site looks wrong
this is the obligation that pairs with the shipped `as const` ban: the ban exempts arrays deliberately, so the array form needs an obligation rather than a ban

### require-readonly-type-alias · `clean`

**flags** a type alias whose value is a mutable collection
**evidence** 0 violations, every collection alias in the corpus spells `readonly T[]`

```ts
// what it flags
type FishNames = string[];

// write this
type FishNames = readonly string[];
```

**why it matters** `type Tags = string[]` is a mutable reference in a signature position, the same defect `require-readonly-collection-signatures` reports on parameters and properties
that detector covers neither aliases nor local bindings, so the alias form needs its own check

### no-value-import-used-only-as-type · `clean`

**flags** an import used only in type positions that is not written `import type`
**evidence** 0 violations, the corpus writes `import type` wherever it means it

```ts
// what it flags: a runtime dependency the module does not have
import { AccountRecord } from "./accounts.types.ts";
const keyOf = (record: AccountRecord): string => record.userId;

// write this
import type { AccountRecord } from "./accounts.types.ts";
```

**why it matters** the value import survives erasure, so the module claims a runtime dependency it does not have, which is a load-time cost and a false statement about the module's edges

### require-unsuppressed-duplicate-enum-values · `clean`

**flags** an enum whose members repeat a value without a stated reason
**evidence** 2 duplicate-value enums exist, `PillowFightTtlSeconds` and `FeatureXp`, and both carry `biome-ignore-start` with a written reason

```ts
// what it flags: the repetition is unexplained, so it reads as a copy-paste error
export enum FeatureXp {
  ChatCredit = 15,
  VoiceCredit = 15,
}

// write this
// biome-ignore-start lint/suspicious/noDuplicateEnumValues: both credits award the same xp on purpose
export enum FeatureXp {
  ChatCredit = 15,
  VoiceCredit = 15,
}
// biome-ignore-end lint/suspicious/noDuplicateEnumValues
```

**why it matters** an enum with repeated values is only safe when the repetition is deliberate, and the declaration that says so is the directive beside it
requiring the directive turns a judgement call into a checkable one, and the check is what keeps the reason in the file

### require-handle-name-suffix · `clean`

**flags** a parameter or property typed `D1Database` or `KVNamespace` whose name does not say which resource it reaches
**evidence** 10 raw hits, 0 real: 6 are the platform's own binding names (`AFK_KV`, `FAMILY_KV`, `DREAMS_DB`) and 4 are `kv: KVNamespace` inside the generic `lib/kv-register.ts`

```ts
// what it flags: which namespace?
const readChase = (kv: KVNamespace, chaseId: string): Promise<Chase | undefined> => { /* ... */ };

// write this
const readChase = (sleepKv: KVNamespace, chaseId: string): Promise<Chase | undefined> => { /* ... */ };
```

**why it matters** a handle type names the kind of resource and never which one
the corpus's own convention (`dreamsDb`, `sleepKv`, `fishingKv`) is what makes a call site readable without opening the signature

## resilience

### require-catch-binding-used · `clean`

**flags** a `catch` that declares a binding and never reads it
**evidence** 0 violations across 149 catch clauses that declare a binding, plus 5 that use optional binding

```ts
// what it flags: the only thing that can say what happened, thrown away
try {
  await saveRecord(env, record);
} catch (error) {
  return { succeeded: false, reason: RecordFailureReason.WriteFailed };
}

// write this
} catch (error) {
  logger.error("failed to write record", { error, recordId: record.id });
  return { succeeded: false, reason: RecordFailureReason.WriteFailed };
}
```

**why it matters** the operation reports that it failed and loses why, which is the diagnostic the shipped catch bans exist to protect and the half they cannot see

### require-failure-reason · `below the gate`

**flags** a failure outcome that carries no reason
**evidence** 4 sites, all in `src/services/music.service.ts:307`

```ts
// what it flags: four different causes, one opaque answer
export type MusicBridgeResult =
  | { succeeded: true; envelope: MusicEnvelope }
  | { succeeded: false };

// write this
export type MusicBridgeResult =
  | { succeeded: true; envelope: MusicEnvelope }
  | { succeeded: false; reason: MusicBridgeFailureReason };
```

**why it matters** a failure outcome with no reason collapses distinct causes into one `succeeded: false`, so the caller can only report that it did not work and the operator cannot tell a configuration fault from a network fault from a rejection
`MusicBridgeResult` returns the reason-less branch for four different causes: missing env keys, a non-ok response, an unparsable envelope, and a thrown fetch
the census is what makes this worth shipping despite the low count: across the corpus there are 116 failure branches that carry the reason forward, 100 that render user-facing copy, and 6 that short-circuit with `return`, against 0 that log without a reason
every other consumer idiom preserves it, and this is the one place in the corpus that re-invents the outcome contract instead of importing it
**fix** give the failure branch a `reason`, and declare the reason vocabulary in the surface's `.config.ts` like every other failure enum

### require-outcome-return-from-repository · `clean`

**flags** a repository function returning a raw row or a bare promise
**evidence** 0 violations across 9 `*.repo.ts` modules, 55 of 55 exported functions declare an outcome

```ts
// what it flags: the failure decision moves to every caller
export const getAccountBalance = async (db: D1Database, userId: string) =>
  db.prepare("SELECT balance FROM accounts WHERE user_id = ?").bind(userId).first();

// write this
export const getAccountBalance = async (
  db: D1Database,
  userId: string,
): Promise<GetAccountBalanceOutcome> => { /* ... */ };
```

**why it matters** a raw row or a bare promise moves the failure decision to every caller, which is exactly the thing the outcome contract exists to prevent

### require-interval-cleanup · `clean`

**flags** a `setInterval` with no matching `clearInterval`
**evidence** 0 violations, every file that calls `setInterval` also clears in the same module

```ts
// what it flags: the closure, its captured state and its timer live on
setInterval(() => heartbeat(), HeartbeatIntervalMs);

// write this
const heartbeatTimer = setInterval(() => heartbeat(), HeartbeatIntervalMs);
// on shutdown
clearInterval(heartbeatTimer);
```

**why it matters** an interval that is never cleared holds its closure, its captured state and its timer alive for the life of the process, and the leak is invisible because nothing looks wrong at the call site

### require-promise-catch-reason · `clean`

**flags** a `.catch()` callback that discards the error
**evidence** 2 `.catch(` sites, both log with context, 0 violations

```ts
// what it flags: the promise form of the silent-catch ban, unreachable by the shipped pattern
void loadEnvelope().catch(() => undefined);

// write this
void loadEnvelope().catch((error) => {
  logger.warn("failed to load the envelope", { error, guildId });
});
```

**why it matters** `.catch(() => {})` and `.catch(() => undefined)` are the promise form of the shipped silent-catch ban
that ban's GritQL pattern matches a `catch` clause node, so the method form is unreachable by it

### no-catch-returns-success · `clean`

**flags** a `catch` that returns a success outcome
**evidence** 0 sites across 129 files, with a positive control

```ts
// what it flags: the failure branch is now unreachable and the work never happened
try {
  return { succeeded: true, result: await dissolveChase(env, chaseId) };
} catch {
  return { succeeded: true, result: undefined };
}

// write this
} catch (error) {
  logger.error("failed to dissolve the chase", { error, chaseId });
  return { succeeded: false, reason: ChaseFailureReason.DissolveFailed };
}
```

**why it matters** it makes the failure branch unreachable while the operation silently did not happen
it is the one shape the outcome contract cannot express and no narrowing can detect

### no-unguarded-outcome-result · `clean`

**flags** `.result` read without narrowing `.succeeded` first
**evidence** 0 hits, sleepy always narrows first

```ts
// what it flags: the failure branch becomes reachable at the wrong time
const name = outcome.result.displayName;

// write this
if (!outcome.succeeded) return { succeeded: false, reason: outcome.reason };
const name = outcome.result.displayName;
```

**why it matters** it is the complement of `no-discarded-outcome`
reading `.result` before narrowing `.succeeded` reaches into a value that may be the failure branch's placeholder

### no-nested-try-in-catch · `clean`

**flags** a `try` inside a `catch`
**evidence** 0 violations

```ts
// what it flags: the recovery path can fail while the original failure is still in hand
} catch (error) {
  try {
    await rollback(env, patch);
  } catch (rollbackError) {
    log("both failed", { error, rollbackError });
  }
}

// write this
} catch (error) {
  const rolledBack = await rollback(env, patch);
  if (!rolledBack.succeeded) {
    logger.error("patch and rollback both failed", { error, rollbackError: rolledBack.reason });
  }
}
```

**why it matters** a `try` inside a `catch` means the recovery path can itself fail while the original failure is still in hand, and the two failures then share one log line and one outcome

### no-process-exit-outside-entry · `clean`

**flags** `process.exit` or `process.abort` outside an entry script
**evidence** 0 violations, all 12 sites are in `gateway/` entry scripts

```ts
// what it flags: mid-request termination, every in-flight operation dies with it
// src/services/bot-config.service.ts
if (!env.DISCORD_BOT_TOKEN) process.exit(1);

// write this
if (!env.DISCORD_BOT_TOKEN) {
  return { succeeded: false, reason: EnvFailureReason.MissingBotToken };
}
```

**why it matters** `process.exit` in a service terminates the process mid-request, so every other in-flight operation dies with no response and no chance to log, which is the opposite of the outcome contract this corpus is built on
the entry scripts are the one place it is a contract

### no-raw-json-parse · `below the gate`

**flags** a direct `JSON.parse` instead of the shipped wrapper
**evidence** 2 real hits, below the gate. `lib/outcome.ts` already ships `safeJsonParse`

```ts
// what it flags: throws on the path tests miss
const payload = JSON.parse(rawBody) as BridgePayload;

// write this
const parsed = safeJsonParse<BridgePayload>(rawBody);
if (!parsed.succeeded) return { succeeded: false, reason: parsed.reason };
```

**why it matters** `JSON.parse` throws, and a throw inside a request handler is a crash rather than a returned failure
the project already wrote the value-returning wrapper, so the rule is asking for the convention the library was built for

### no-floating-async-array-callback · `below the gate`

**flags** an `async` callback passed to a method that discards the promise
**evidence** 3 async callbacks, all correctly wrapped

```ts
// what it flags: the promise is discarded, so nothing awaits the work and nothing sees a rejection
chaseIds.forEach(async (chaseId) => {
  await dissolveChase(env, chaseId);
});

// write this
await Promise.all(chaseIds.map((chaseId) => dissolveChase(env, chaseId)));
```

**why it matters** `.forEach(async ...)` is always wrong, and `.map(async ...)` is wrong unless it is wrapped in `await Promise.all`
both forms drop the returned promise, so a rejection becomes an unhandled rejection and the work may still be in flight when the response is sent

## sql

### require-sql-inside-repository · `clean`

**flags** a `prepare` call outside a repository or schema module
**evidence** 0 violations, every `prepare` in the corpus sits in a `*.repo.ts` module

```ts
// what it flags: query text spreading through the layers that consume results
// src/services/sleep.service.ts
const rows = await env.DREAMS_DB.prepare("SELECT * FROM accounts WHERE user_id = ?").all();

// write this
// src/db/accounts.repo.ts
export const listAccounts = async (db: D1Database): Promise<ListAccountsOutcome> => { /* ... */ };
```

**why it matters** query text outside a repository spreads through the layers that are supposed to consume results, so a schema change becomes a search across surfaces instead of one edit beside the schema it queries

### require-bind-argument-count-match · `clean`

**flags** a placeholder count that does not match the bind argument count
**evidence** 0 defects in sleepy

```ts
// what it flags: three placeholders, two binds. this fails at runtime, not at build time
accounts
  .prepare("INSERT INTO accounts (user_id, balance) VALUES (?, ?) ON CONFLICT(user_id) DO UPDATE SET balance = ?")
  .bind(userId, balance);

// write this
accounts
  .prepare("INSERT INTO accounts (user_id, balance) VALUES (?, ?) ON CONFLICT(user_id) DO UPDATE SET balance = ?")
  .bind(userId, balance, balance);
```

**why it matters** the mismatch fails at runtime, on the path the tests miss, and the compiler cannot see it because the statement is a string
it is a cheap build-time guard for a runtime-only failure

## declarative

### no-else-after-return · `clean`

**flags** an `else` block after a branch that always returns
**evidence** 0 sites in the whole corpus, with a positive control that fires

```ts
// what it flags: dead indentation, and one more condition to hold
if (!chase.succeeded) {
  return { succeeded: false, reason: chase.reason };
} else {
  return dissolve(chase.result);
}

// write this
if (!chase.succeeded) return { succeeded: false, reason: chase.reason };
return dissolve(chase.result);
```

**why it matters** the reader has to hold a condition the `return` above already settled, and the deeper nesting is what pushes a function past the complexity gate

### no-index-mutation · `clean`

**flags** an assignment through a collection position
**evidence** 0 element-access assignments in the corpus, detector proven against 2 constructed sites

```ts
// what it flags: mutation even a readonly annotation cannot stop
const buffer: readonly number[] = new Array(8).fill(0);
buffer[0] = 1;

// write this
const buffer = [1, ...new Array(7).fill(0)];
```

**why it matters** `buffer[0] = value` mutates a collection in place through a position, which is the imperative accumulation the declarative mandate exists to replace, and it is the one mutation a `readonly` annotation cannot stop

### no-map-accumulation-in-loop · `clean`

**flags** a loop that fills a `Map` or `Set` through `.set()` or `.add()`
**evidence** 0 violations, no loop in the corpus accumulates into a `Map` or a `Set`

```ts
// what it flags: the push rule's blind spot, against a different collection
const byId = new Map<string, Member>();
for (const member of members) {
  byId.set(member.id, member);
}

// write this
const byId = new Map(members.map((member) => [member.id, member]));
```

**why it matters** it is the same imperative accumulation as `no-for-of-push-accumulation`, written against a different collection, and that rule can only see `push` and `unshift`

### no-assignment-dispatch-chain · `clean`

**flags** a run of branches that test one subject and assign the same target
**evidence** 0 violations

```ts
// what it flags: the if-chain dispatch's blind spot, minus the return it keys on
let label = "";
if (shape === QueueShape.Idle) label = IdleLabel;
else if (shape === QueueShape.Playing) label = PlayingLabel;

// write this
const labelByShape: Record<QueueShape, string> = { /* ... */ };
const label = labelByShape[shape];
```

**why it matters** it is the same dispatch written as control flow, minus the `return` the accepted `no-if-chain-dispatch` rule keys on

## complexity

### max-nesting-depth-three · `below the gate`

**flags** a statement container more than three layers deep inside one function
**evidence** 2 sites in 1 file · `src/services/sleep.service.ts:436`, the dreamcatcher doubling · `:528`, the jarred-theft refund
**tier** grit · **severity** warn

```ts
// what it flags: four conditions to hold at once
if (chase.succeeded) {
  if (chase.result.state === "active") {
    for (const entry of chase.result.entries) {
      if (entry.expiresAt < now) {
        await dissolve(entry);   // layer four
      }
    }
  }
}

// write this: early returns flatten the ladder
if (!chase.succeeded) return;
if (chase.result.state !== "active") return;
const expired = chase.result.entries.filter((entry) => entry.expiresAt < now);
await Promise.all(expired.map((entry) => dissolve(entry)));
```

**why it matters** the reader pays for every layer
a body four deep means holding four conditions at once to know when the innermost line runs, and each layer multiplies the paths a test must cover, so the deepest body is the least tested part of the file
the shipped rules cannot see it: a short function with three branches passes both `max-function-lines` and `max-cyclomatic-complexity` while carrying the hardest code in the module to read
**fix** return early at every failure branch
**note** the corpus holds two deep bodies because it returns early everywhere else, so the rule cannot clear the recurrence gate
that is a property of sleepy, not a fault in the rule
object-literal depth is deliberately out of scope: `{ }` also means data, and sleepy nests object literals four deep in 14 places, which is a scroll for the reader and not a condition

### no-shadowed-binding · `clean`

**flags** a declaration that reuses an enclosing name
**evidence** 0 violations across 129 files, and the detector is proven against a positive fixture

```ts
// what it flags: userId now means something else for the rest of the function
const processChase = (userId: string): void => {
  const chase = loadChase(userId);
  for (const entry of chase.entries) {
    const userId = entry.ownerId;
  }
};

// write this
const processChase = (userId: string): void => {
  const chase = loadChase(userId);
  for (const entry of chase.entries) {
    const ownerId = entry.ownerId;
  }
};
```

**why it matters** a shadowed declaration silently replaces the outer value for the rest of the function, so a reader who learned what the name holds has to re-learn it partway down
**fix** name the inner binding for what it is

## patterns

### no-unused-imports · `clean`

**flags** an import binding nothing in the file reads
**evidence** 0 violations in sleepy, and the reason is measurable: the corpus leaves biome's recommended lint set on, which already reports `noUnusedImports`

```ts
// what it flags: a false claim about what the module needs
import { formatDuration } from "./music-messages.ts";
import { buildQueueMessage } from "./music-messages.ts";   // never named

// write this
import { buildQueueMessage } from "./music-messages.ts";
```

**why it matters** an unused import is a false claim about the module's dependencies, it survives erasure as a load-time module reference, and the repair is mechanical, which makes it one of the few rules with no review cost
the rule matters for a project that turns the recommended set off, and for the gap grimuah leaves when it runs biome with `--skip=plugin`
**care needed** a property name is not a read, so `{ unusedThing: 1 }` does not save an import
a shorthand property is a read, and a type position is a read

### require-suppression-reason · `clean`

**flags** a `biome-ignore`, `@ts-ignore` or `@ts-expect-error` with no stated reason
**evidence** 4 directives exist, all 4 carry a written reason

```ts
// what it flags: an opt-out from every rule in the system, unexplained
// biome-ignore lint/suspicious/noDuplicateEnumValues:
export enum FeatureXp { ChatCredit = 15, VoiceCredit = 15 }

// write this
// biome-ignore lint/suspicious/noDuplicateEnumValues: both credits award the same xp on purpose
export enum FeatureXp { ChatCredit = 15, VoiceCredit = 15 }
```

**why it matters** an unexplained suppression is an opt-out from every rule in the system, which is the one thing an obligation-enforcing architecture cannot audit
requiring the reason is what keeps the judgement in the file rather than in someone's memory

### no-unused-parameters · `clean`

**flags** a parameter nothing reads
**evidence** 0 violations across 1,556 parameters, 22 of which are `_`-prefixed deliberately

```ts
// what it flags: every caller must invent an argument
const renderEntry = (entry: Entry, index: number, context: RenderContext): string => entry.label;

// write this
const renderEntry = (entry: Entry): string => entry.label;
// or, when the position is part of a required signature:
const renderEntry = (_entry: Entry, index: number): string => String(index);
```

**why it matters** a parameter nothing reads forces every caller to invent an argument, and it hides which inputs the function actually depends on

### require-unit-suffix-on-time-constants · `clean`

**flags** a duration-named numeric constant with no unit in its name
**evidence** 13 duration constants across 4 config files, all 13 carry a suffix

```ts
// what it flags: milliseconds to its author, seconds to its reader
export const SleepCooldown = 86_400_000;

// write this
export const SleepCooldownMs = 86_400_000;
export const NightmareHauntIntervalMinMs = 5 * 60 * 1000;
```

**why it matters** the unit belongs in the identifier, because the error is invisible at the call site
`setTimeout(fn, cooldown)` reads correctly whether the number means seconds or milliseconds, and the bug only appears as a timer that fires too early or never

### require-terminal-punctuation-on-copy · `clean`

**flags** the other half of the project's user-facing text convention: a sentence with no terminal punctuation, or a short label that ends with one
**evidence** about 200 copy strings carry terminal punctuation, 0 short labels do

```ts
// what it flags: the same sentence losing its full stop is invisible to every tier
export const SleepMessages = { Done: "You slept well" } as const;

// write this
export const SleepMessages = { Done: "You slept well." } as const;
```

**why it matters** the shipped copy rule enforces only the first-letter half of the convention, so a sentence that loses its full stop is invisible while the same sentence losing its capital is an error
the ban direction is the same idea read backwards: a label is a descriptor and must not carry a full stop, and the corpus holds no label that does

### no-duplicated-declaration-text · `clean`

**flags** two exported declarations with identical text
**evidence** 0 violations across 712 exported declarations, census controlled

```ts
// what it flags: the non-function half of the exact-duplication rule
// src/db/accounts.repo.ts
export type BalanceOutcome = Outcome<number>;
// src/db/consumables.repo.ts
export type BalanceOutcome = Outcome<number>;

// write this
// lib/balance-outcome.ts
export type BalanceOutcome = Outcome<number>;
```

**why it matters** unlike a shared shape, where two modules may legitimately describe the same fields, two declarations with identical text have no reading on which they are two things

### require-regex-in-patterns-module · `below the gate`

**flags** a regular expression literal outside the patterns module
**evidence** 1 violation, `/ado|唱/i` in `gateway/music-bot.smoke.ts:96`

```ts
// what it flags: the pattern vocabulary scattered at call sites
const isJapanese = /ado|唱/i.test(query);

// write this
// src/patterns/regex-patterns.ts
export const JapaneseQueryPattern = /ado|唱/i;
```

**why it matters** the project's own convention puts every regular expression in one dedicated, documented patterns module, and a regex inlined at a call site is invisible to every reader looking for the project's pattern vocabulary

### no-abbreviated-binding-name · `clean`

**flags** a binding named `msg`, `req`, `idx` or similar
**evidence** 0 violations across 129 files: parameters and locals are spelled out (`dreamsDb`, `botToken`, `activeUserIds`), and even the catch binding is `error`

```ts
// what it flags: decodes only for a reader who already knows the codebase
const idx = activeUserIds.indexOf(userId);

// write this
const memberPosition = activeUserIds.indexOf(userId);
```

**why it matters** the naming mandate asks for self-documenting names, and an abbreviation only decodes for a reader who already knows the codebase

### require-guide-command-coverage · `below the gate`

**flags** a command missing from the guide's player-facing index
**evidence** 5 raw hits, 2 real defects

```ts
// what it flags: the index is a hand-maintained list of the same facts as the registry
// src/commands/guide.command.config.ts
export enum GuidePage { Dreams = "dreams", Family = "family" }   // GuidePage.Map is missing

// write this: declare the exclusion where a check can read it, then the invariant is exact
export enum GuideCommandIndexExcluded {
  Ping = "ping",
  Grant = "grant",
  Guide = "guide",
}
```

**why it matters** the guide's index is a third hand-maintained list of the same facts as the gateway's registration, and its own copy asserts completeness, so an omission makes a user-facing sentence false
**why it is not verified** 3 of its 5 hits are excluded deliberately, and the reason lives in a source comment a rule cannot read: a player manual lists only what a member can run

## architecture

### types-declares-types-only · `clean`

**flags** a runtime value in a `*.types.ts` module
**evidence** 0 violations, all 9 `*.types.ts` modules hold nothing but `import type` and `export type`

```ts
// what it flags: an implementation module wearing a declaration's name, whose dag order silently moved
// src/db/accounts.types.ts
export const DEFAULT_BALANCE = 0;
export type AccountRecord = { readonly userId: string; readonly balance: number };

// write this
// src/db/accounts.config.ts
export const DEFAULT_BALANCE = 0;
// src/db/accounts.types.ts
export type AccountRecord = { readonly userId: string; readonly balance: number };
```

**why it matters** the `.config.ts` obligation has no counterpart on the type side, so a `.types.ts` module that grows a runtime value becomes an implementation module wearing a declaration's name, and its dag order moves without anyone noticing

### require-leaf-innate-members · `below the gate`

**flags** an innate member importing an implementation module of its own surface
**evidence** 2 sites, both `import type`: `src/services/family.service.config.ts:1`, `src/services/shop-shelf.service.config.ts:6`

```ts
// what it flags: the layer inverts, and the firewall cannot see a within-surface edge
// src/services/family.service.config.ts
import type { FamilyServiceResult } from "./family.service.ts";

// write this
// src/services/family.service.types.ts
export type FamilyServiceResult = /* ... */;
```

**why it matters** an innate member sits at the lowest layer of its surface, so importing one of its own surface's implementation modules inverts the layer and makes the config part of an implementation graph the firewall cannot see
the first site is the same root cause `require-enum-in-config-file` reports from the other side

### no-orphan-surface-module · `clean`

**flags** a file inside a surface that no other file imports
**evidence** 0 orphans across 7 surfaces

```ts
// what it flags: dead weight carrying folder overhead and a singleton risk
// src/services/legacy-dream.service.ts, and nothing imports it

// write this: delete it, or have its consumer import it
```

**why it matters** a module nothing imports is dead weight, and if it registers a handler at module scope it is also a singleton risk that never runs
entry points live outside surfaces, which is what keeps the check decidable

### require-command-registration · `clean`

**flags** a `*.command.ts` not side-effect imported by the aggregator
**evidence** 24 of 24 imported by `src/bot.ts`

```ts
// what it flags: the command compiles, ships and never registers
// src/commands/sleep.command.ts exists, and src/bot.ts never imports it

// write this
// src/bot.ts
import "./commands/sleep.command.ts";
```

**why it matters** a command module that is never imported silently never registers, so the feature is present in the source and absent from Discord, with no error anywhere

### require-relative-import-extension · `clean`

**flags** a relative import without its file extension
**evidence** 0 violations, every relative specifier in the corpus carries its extension

```ts
// what it flags: unresolvable under node type stripping
import { getAccountBalance } from "./accounts.repo";

// write this
import { getAccountBalance } from "./accounts.repo.ts";
```

**why it matters** the failure is a runtime resolution error rather than a build one, which is why the project's own `.ts` suffixed specifiers exist

### no-unused-exports · `below the gate`

**flags** an exported binding nothing uses at all, as opposed to one nothing names
**evidence** 1 hit in sleepy, `createEphemeralEmbedResponse`, below the gate

```ts
// what it flags: dead weight and a false claim about the module's public surface
export const createEphemeralEmbedResponse = (/* ... */) => { /* ... */ };
```

**why it matters** it is the sibling of `no-export-without-consumer` and the stricter reading: nothing uses the symbol at all, inside or outside its module
**the finding behind it is more useful than the rule**: `lib/outcome.ts` exports 11 symbols and the corpus names 3 of them
of the 8 nobody names, 2 are the actionable kind, the callables `isSuccess` and `isIndexWithinArrayBounds`, each with a ready-made inline idiom the corpus prefers
the other 6 are component types of symbols that are used, and the reason vocabularies of the helpers around them
so the template's real question is two unused callables, not eleven dead symbols

### require-gateway-command-parity · `clean`

**flags** a command, name or description that differs between the bot and the gateway registry
**evidence** 0 violations, all 24 commands appear on both sides with matching names and descriptions

```ts
// what it flags: a rename on one side changes what a player sees, or drops a command
// src/commands/fishing.command.ts   name: FishingSubcommandName.Cast
// gateway/register-commands.ts      name: "Fish"

// write this: one vocabulary, or a check that resolves the config references and compares both sides
```

**why it matters** the gateway's command list is hand-maintained and a `PUT` replaces the whole scope, so a command the bot registers but the list omits is dropped from Discord on the next registration run, silently: the bot still answers the old command and the new one never appears
**the observation worth acting on is one-sidedness rather than drift**: of the gateway's 37 subcommand and option descriptions, 22 exist only in the gateway (`afk:type "The kind of away you are"`), so a surface that renders documentation from `src/` cannot know them, and nothing forces a new option to be described at all

---

# part 3: what was rejected, and the test each one failed

76 entries in the research report, and more than 76 ideas, because one row often names several
recording them matters: each looked like a good rule and failed on precision review
the reasons group into six tests

| the test | what it asks | an example |
| --- | --- | --- |
| recurrence | does the pattern appear three times across two files | `no-mutating-array-methods`: 3 hits, all in one file |
| a reader cannot read a comment | is the deviation declared in a form a matcher can see | thirteen entries fail here |
| the pattern is the platform's shape | would the rule flag the Node or Discord api | `no-boolean-property-argument`: `rmSync({ recursive: true })` |
| the compiler already enforces it | does `tsc` report the same thing | `record-table-omits-enum-member`: `Record<Enum, X>` is the exhaustiveness gate |
| the match is conformity | is the corpus consistent, so the rule measures its own style | `no-near-duplicate-function-body`: five repository functions share one skeleton |
| nothing to measure | does the corpus hold any example at all | `object-built-by-mutation`: 0 sites |

one class deserves its own paragraph, because it is the failure mode the whole architecture has to avoid
**a rule that flags a written justification teaches people to fight the tool**
four things in sleepy look like defects and are decisions, each with a written reason in the source

- `MusicBridgeResult` returns a reason-less failure four times, and every other failure consumer in the corpus carries the reason or renders copy
- the bot-to-gateway string mirror exists because node type stripping cannot execute an enum, and `gateway/register-commands.ts` states the reason
- the `FeatureXp` band values repeat on purpose, and the file suppresses the duplicate-value lint with its reason
- the gateway's `process.exit` calls are a startup contract: `loadEnv` returns an outcome, the entry logs the reason and exits 1

the remedy is to key the rule on the declaration that records the deviation, or give the deviation one
`require-suppression-reason` is the general form of that

---

# appendix: evidence and reproduction

## what the measurement means

**the gates.** a rule counts as measured only when all five hold: it is actionable, on title, rationale, replacement and valid category and severity, it has signal, at least 3 hits across 2 distinct files, it is novel against the shipped rule set, it is free of sleepy domain vocabulary, and it is distinct from the other accepted rules

**the honest limit.** the signal gate measures demonstrated gaps, not rule value
a rule sleepy already satisfies scores zero even when it is the highest-value rule to ship, which is why part 2 exists and why the metric is 31 rather than 71

**anti-overfit.** every detector runs against grimuah's own `examples/`, 28 independently generated files across 5 projects, and every rule scores 0 there except `no-redundant-allowed-import`, whose 42 hits are grimuah's own preset configuration and are correct
the detectors are AST-based, so comments and string literals cannot produce false hits, and no rule keys on a sleepy-specific string

**the instrument is wrong more often than the corpus.** seven mechanism bugs were found and fixed during the research, the sharpest being a scanner that returned `SlashToken` for a regex literal and produced a clean-looking zero across 129 files
a zero needs a positive control, and every clean figure in part 2 has one

## reproduce it

```sh
./docs/rule-candidates/measure.sh   # per-candidate table plus METRIC lines
```

it prints the same table and the same 11 METRIC lines that produced every number above, and it rewrites `evidence.md` as it goes
run it from the grimuah root, or from anywhere, since the harness resolves both checkouts itself
the corpus is a separate checkout, so point it elsewhere when needed:

```sh
GRIMUAH_RESEARCH_CORPUS=/path/to/sleepy ./docs/rule-candidates/measure.sh
```

the instruments that verify the shipped-rule defects and the harness gates themselves stayed in the sleepy checkout at `.auto/`, because they test grimuah from outside rather than the detectors in here

## where the detail lives

| document | what it holds |
| --- | --- |
| `docs/rule-candidates/catalogue.md` | this file: the rules and the argument for each |
| `docs/rule-candidates/evidence.md` | machine-generated per-rule evidence, every hit listed |
| `docs/rule-candidates/candidates/*.mjs` | one detector per rule, 35 files |
| `docs/rule-candidates/harness.mjs` | the gates that count a rule as verified |
| `GRIMUAH-RULE-PRIORITIES.md` | in the sleepy checkout: the work order, and the nine live shipped-rule defects |
| `GRIMUAH-RULES-RESEARCH.md` | in the sleepy checkout: the full record, method, limits, rejection ledger |
