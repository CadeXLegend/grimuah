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
