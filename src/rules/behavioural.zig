const std = @import("std");
const root = @import("../rules.zig");
const ir = @import("../ir.zig");
const tokens_mod = @import("tokens.zig");

const Token = tokens_mod.Token;

/// `` `throw $expr` ``. a property named throw (`{ throw: 1 }`, `o.throw`) is
/// not a throw statement, and neither the tree nor a node kind can see the
/// shorthand property `{ throw }`, which the token rule reports
pub fn checkThrow(context: *const root.Context) !void {
    const tokens = context.tokens;
    for (tokens, 0..) |token, i| {
        if (!token.isWord("throw")) continue;
        if (tokens_mod.isMemberAccess(tokens, i)) continue;
        if (i + 1 < tokens.len and tokens[i + 1].isPunct(":")) continue;
        try context.report(token.line, .behavioural, root.throw_stmt, .err);
    }
}

/// `try { } catch {}` -> the bare-catch error. `try { } catch (e: unknown) {}`
/// produces nothing at all: biome's `catch ($err)` pattern does not match a
/// parameter carrying a type annotation, and the differential guard holds this
/// engine to that behaviour
pub fn checkBareCatch(context: *const root.Context) !void {
    try eachCatchClause(context, .bare);
}

/// `try { } catch { body }` whose body never returns, throws or logs. an empty
/// body trips this warning as well as the bare-catch error, exactly as the two
/// separate plugin files do
pub fn checkSilentCatch(context: *const root.Context) !void {
    try eachCatchClause(context, .silent);
}

const CatchRule = enum { bare, silent };

fn eachCatchClause(context: *const root.Context, which: CatchRule) !void {
    const tokens = context.tokens;
    for (tokens, 0..) |token, i| {
        if (!token.isWord("catch")) continue;
        if (tokens_mod.isMemberAccess(tokens, i)) continue;

        var body_open = i + 1;
        var bound = false;
        if (body_open < tokens.len and tokens[body_open].isPunct("(")) {
            const params_close = tokens_mod.matchingBracket(tokens, body_open) orelse continue;
            if (tokens_mod.hasTopLevelColon(tokens, body_open + 1, params_close)) continue;
            body_open = params_close + 1;
            bound = true;
        }
        if (body_open >= tokens.len or !tokens[body_open].isPunct("{")) continue;

        const body_close = tokens_mod.matchingBracket(tokens, body_open) orelse continue;
        const body = tokens[body_open + 1 .. body_close];

        switch (which) {
            .bare => {
                if (bound or body.len != 0) continue;
                try context.report(token.line, .behavioural, root.bare_catch, .err);
            },
            .silent => {
                if (handlesError(body)) continue;
                try context.report(token.line, .behavioural, root.silent_catch, .warn);
            },
        }
    }
}

/// `not contains return|throw|console`. `return;` counts, a string "return"
/// does not, since strings never reach the token stream
fn handlesError(body: []const Token) bool {
    for (body) |token| {
        if (token.kind != .word) continue;
        if (std.mem.eql(u8, token.text, "return")) return true;
        if (std.mem.eql(u8, token.text, "throw")) return true;
        if (std.mem.eql(u8, token.text, "console")) return true;
    }
    return false;
}

/// a loop whose body holds an `await`, reported once per loop
///
/// the search stops at a nested function, which owns its own suspension: an
/// arrow defined inside a loop is called somewhere else, or not at all. a loop
/// already reported is not searched again, so a loop inside it is not a second
/// finding, and only the body is searched, because an `await` in a loop's own
/// head runs once rather than once per element
pub fn checkAwaitInLoop(context: *const root.Context) !void {
    const module = context.module orelse return;
    try visitLoops(module, context, module.root);
}

fn visitLoops(module: *const ir.Module, context: *const root.Context, index: ir.NodeIndex) anyerror!void {
    if (isLoop(module.kindOf(index))) {
        if (loopBody(module, index)) |body| {
            if (holdsAwait(module, body)) {
                try context.report(module.spanOf(index).line, .behavioural, root.await_in_loop, .warn);
                return;
            }
        }
    }
    var child = module.firstChildOf(index);
    while (child) |current| : (child = module.nextSiblingOf(current)) {
        try visitLoops(module, context, current);
    }
}

/// the four loop kinds the front-end produces: `do..while` is a `while_stmt`
/// whose body comes first
fn isLoop(kind: ir.Kind) bool {
    return switch (kind) {
        .for_stmt, .while_stmt => true,
        else => false,
    };
}

/// the statement a loop runs. the front-end appends a `for` body last and a
/// `while` condition after its body, so the body is the child that is a
/// statement
fn loopBody(module: *const ir.Module, index: ir.NodeIndex) ?ir.NodeIndex {
    if (module.kindOf(index) == .for_stmt) return module.lastChildOf(index);

    var child = module.firstChildOf(index);
    while (child) |current| : (child = module.nextSiblingOf(current)) {
        if (module.kindOf(current).isStatement()) return current;
    }
    return null;
}

/// whether an `await` sits in `index`'s subtree, skipping the subtrees of
/// nested functions
fn holdsAwait(module: *const ir.Module, index: ir.NodeIndex) bool {
    if (module.kindOf(index) == .unary) {
        if (std.mem.eql(u8, module.nodeOf(index).operator, "await")) return true;
    }

    var child = module.firstChildOf(index);
    while (child) |current| : (child = module.nextSiblingOf(current)) {
        if (module.kindOf(current).isCallable()) continue;
        if (holdsAwait(module, current)) return true;
    }
    return false;
}

/// a call that returns an outcome whose result is dropped as a bare statement
///
/// the behavioural layer routes every failure through an outcome so a caller
/// cannot forget it, but an outcome used as a bare statement is discarded before
/// it is read: the failure branch becomes unreachable and the error disappears
/// with no log and no return. whether the callee returns an outcome is a question
/// about its declaration, which may sit in any file of the run, so the call site is
/// recorded and the engine reports it once every declaration is known
///
/// one divergence the tree cannot express: `credit(id)!;` is a call node here, and
/// a non-null assertion to the detector, which reports neither it nor any other
/// expression that wraps the call. the front-end records no node for a postfix
/// `!`, so a bare call a `!` was appended to reads as a bare call
pub fn checkDiscardedOutcome(context: *const root.Context) !void {
    try deferBareCalls(context, .await_only, declaresOutcome, .warn, root.discarded_outcome);
}

/// a call whose declared result is a bare boolean or number, where nothing reads
/// that result
///
/// a function that settles to a scalar can only report failure by returning the
/// value that also means a real answer, so a caller that drops the result has
/// neither been told nor been able to tell. `void f()` is the explicit marker of a
/// dropped result, so the detector reads it as the same defect stated on purpose
/// rather than a different one
pub fn checkUnreadScalarResult(context: *const root.Context) !void {
    try deferBareCalls(context, .await_or_void, declaresScalarSettled, .warn, root.unread_scalar_result);
}

/// the operands a call site may carry that a detector reads through
const CallPrefix = enum {
    /// only `await`, which both call-site detectors see through
    await_only,
    /// `await` and `void`, in that order: `void await f()` states the dropped result
    /// on a call that already awaits it, and the scalar detector reads that as the
    /// same defect rather than a different one
    await_or_void,
};

/// record every call this file makes as a bare statement, for the engine to judge
/// once the project's declarations are known
///
/// both call-site rules report the same node: an expression statement that is a
/// call. the detector reports that statement's own start, so the line is the
/// statement's rather than the call's, and an `await` on its own line belongs to
/// the finding
fn deferBareCalls(
    context: *const root.Context,
    prefix: CallPrefix,
    passes: *const fn (declared_return: []const u8) bool,
    severity: root.Severity,
    message: []const u8,
) !void {
    const module = context.module orelse return;

    for (context.walk) |entry| {
        if (entry.kind != .expression_stmt) continue;

        const call = callOf(module, entry.index, prefix) orelse continue;
        const name = calleeName(module, call) orelse continue;

        try context.deferToProject(.{
            .name = name,
            .line = module.spanOf(entry.index).line,
            .passes = passes,
            .layer = .behavioural,
            .severity = severity,
            .message = message,
        });
    }
}

/// the call an expression statement makes, with the operands `prefix` names read
/// through
///
/// a statement that is anything else is not a dropped call: an assignment, a
/// `return`, a nested call inside another expression and a `new` expression all
/// leave the call somewhere other than the statement's own expression
fn callOf(module: *const ir.Module, statement: ir.NodeIndex, prefix: CallPrefix) ?ir.NodeIndex {
    var expression = module.firstChildOf(statement) orelse return null;

    expression = withoutUnary(module, expression, "await");
    if (prefix == .await_or_void) expression = withoutUnary(module, expression, "void");

    if (module.kindOf(expression) != .call) return null;
    return expression;
}

/// `expression` itself, or its operand when it is a unary of this operator
fn withoutUnary(module: *const ir.Module, expression: ir.NodeIndex, operator: []const u8) ir.NodeIndex {
    if (module.kindOf(expression) != .unary) return expression;
    if (!std.mem.eql(u8, module.nodeOf(expression).operator, operator)) return expression;
    return module.firstChildOf(expression) orelse expression;
}

/// the name a call's callee is spelled with, which is what a detector looks up:
/// an identifier's own name, or the last name of a member access
///
/// a computed access (`handlers[key]()`) is a `member` here with no name of its
/// own, and the detector's own property-access test skips it too. no declaration
/// can be named nothing, so the empty name finds nothing in the index rather than
/// needing a test of its own
fn calleeName(module: *const ir.Module, call: ir.NodeIndex) ?[]const u8 {
    const callee = module.firstChildOf(call) orelse return null;

    switch (module.kindOf(callee)) {
        .identifier, .member => return module.nodeOf(callee).name,
        else => return null,
    }
}

/// whether a declared return type is an outcome
///
/// the detector substring-tests the declared text, so a name that merely contains
/// the word counts as an outcome and a type that never spells it does not
fn declaresOutcome(declared_return: []const u8) bool {
    return std.mem.indexOf(u8, declared_return, "Outcome") != null;
}

/// whether a declared return type is one of the two scalars that carry no failure
/// channel, compared as the whole text the detector compares
fn declaresScalarSettled(declared_return: []const u8) bool {
    return std.mem.eql(u8, declared_return, "Promise<boolean>") or
        std.mem.eql(u8, declared_return, "Promise<number>");
}

const probe = @import("probe.zig");

test "an await in a loop body is reported, and a nested function's await is not" {
    const source =
        \\export async function loadEach(ids: string[]): Promise<void> {
        \\  for (const id of ids) {
        \\    await loadRecord(id);
        \\  }
        \\}
        \\
        \\export async function loadDeferred(ids: string[]): Promise<void> {
        \\  for (const id of ids) {
        \\    const close = async (): Promise<void> => {
        \\      await loadRecord(id);
        \\    };
        \\    pushTask(close);
        \\  }
        \\}
        \\
        \\export async function drain(queue: string[]): Promise<void> {
        \\  while (queue.length > 0) {
        \\    await pop(queue);
        \\  }
        \\}
        \\
    ;
    try probe.expect(.behavioural, "probe.ts", source, &.{
        "2: This loop awaits inside its body, so every iteration runs in sequence. Map the items to promises and await Promise.all once.",
        "17: This loop awaits inside its body, so every iteration runs in sequence. Map the items to promises and await Promise.all once.",
    });
}

test "a call whose callee returns an outcome is reported once the project declares it" {
    // the declaration and the call sit in different files, which is the whole
    // reason this rule needs the project: `credit` is innocuous here and an
    // outcome there. `ambiguous` is declared twice and the two disagree, and
    // `settle` spells the word inside a longer name, which the detector's
    // substring test accepts
    const declarations =
        \\export function credit(userId: string): OperationOutcome<number> {
        \\  return { succeeded: true, result: 1 };
        \\}
        \\
        \\export function read(userId: string): boolean {
        \\  return true;
        \\}
        \\
        \\export function ambiguous(): Outcome {
        \\  return {};
        \\}
        \\
        \\export function settle(userId: string): Promise<SleepOutcome> {
        \\  return Promise.resolve({ succeeded: true });
        \\}
        \\
    ;
    const second =
        \\export function ambiguous(): boolean {
        \\  return true;
        \\}
        \\
    ;
    const calls =
        \\export async function creditAll(ids: string[]): Promise<void> {
        \\  await credit(ids[0]);
        \\  const kept = await credit(ids[1]);
        \\  await read(ids[2]);
        \\  await ambiguous();
        \\  await settle(ids[3]);
        \\  await missing(ids[4]);
        \\  logger.info(await credit(ids[5]));
        \\  await db.credit(ids[6]);
        \\  await credit(
        \\    ids[7],
        \\  );
        \\  handlers[7](ids[8]);
        \\  return;
        \\}
        \\
    ;
    try probe.expectProject(.behavioural, &.{
        .{ .path = "declarations.ts", .content = declarations },
        .{ .path = "second.ts", .content = second },
        .{ .path = "calls.ts", .content = calls },
    }, &.{
        // a bare statement, which is the defect
        "calls.ts:2: This call returns an Outcome and nothing reads the result, so its failure branch is unreachable. Assign the result and narrow `succeeded`, or log the failure where the call is best effort.",
        // the name spelled inside a longer one
        "calls.ts:6: This call returns an Outcome and nothing reads the result, so its failure branch is unreachable. Assign the result and narrow `succeeded`, or log the failure where the call is best effort.",
        // a member access looks the callee up by its last name
        "calls.ts:9: This call returns an Outcome and nothing reads the result, so its failure branch is unreachable. Assign the result and narrow `succeeded`, or log the failure where the call is best effort.",
        // the statement's own start is the reported line, so a call spread over
        // four lines lands on the line its `await` is on
        "calls.ts:10: This call returns an Outcome and nothing reads the result, so its failure branch is unreachable. Assign the result and narrow `succeeded`, or log the failure where the call is best effort.",
    });
}

test "a call whose declared result is a bare scalar is reported, and `void` states it" {
    // `void clear(...)` is the same dropped result stated on purpose, so the
    // detector reads it as the same defect. the outcome rule beside this one does
    // not look through `void`, which is why the line appears once and not twice
    const declarations =
        \\export function clear(chaseId: string): Promise<boolean> {
        \\  return Promise.resolve(true);
        \\}
        \\
        \\export function count(chaseId: string): Promise<number> {
        \\  return Promise.resolve(1);
        \\}
        \\
        \\export function load(chaseId: string): Promise<void> {
        \\  return Promise.resolve();
        \\}
        \\
        \\export function ambiguous(): Promise<boolean> {
        \\  return Promise.resolve(true);
        \\}
        \\
    ;
    const second =
        \\export function ambiguous(): Promise<void> {
        \\  return Promise.resolve();
        \\}
        \\
    ;
    const calls =
        \\export async function sweep(chaseIds: string[]): Promise<void> {
        \\  await clear(chaseIds[0]);
        \\  void clear(chaseIds[1]);
        \\  const gone = await clear(chaseIds[2]);
        \\  await count(chaseIds[3]);
        \\  await load(chaseIds[4]);
        \\  await ambiguous(chaseIds[5]);
        \\  await absent(chaseIds[6]);
        \\  await clear(
        \\    chaseIds[7],
        \\  );
        \\  return;
        \\}
        \\
    ;
    try probe.expectProject(.behavioural, &.{
        .{ .path = "declarations.ts", .content = declarations },
        .{ .path = "second.ts", .content = second },
        .{ .path = "calls.ts", .content = calls },
    }, &.{
        "calls.ts:2: This call's declared result is a bare boolean or number and nothing reads it, so the failure channel exists only in the signature. Read the result and act on it, or narrow the callee to a `void` result.",
        "calls.ts:3: This call's declared result is a bare boolean or number and nothing reads it, so the failure channel exists only in the signature. Read the result and act on it, or narrow the callee to a `void` result.",
        "calls.ts:5: This call's declared result is a bare boolean or number and nothing reads it, so the failure channel exists only in the signature. Read the result and act on it, or narrow the callee to a `void` result.",
        "calls.ts:9: This call's declared result is a bare boolean or number and nothing reads it, so the failure channel exists only in the signature. Read the result and act on it, or narrow the callee to a `void` result.",
    });
}
