const std = @import("std");
const root = @import("../rules.zig");
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
