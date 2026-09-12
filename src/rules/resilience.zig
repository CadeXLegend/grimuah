const std = @import("std");
const root = @import("../rules.zig");
const tokens_mod = @import("tokens.zig");
const ir = @import("../ir.zig");

const Token = tokens_mod.Token;

/// `` `null` `` matches the literal keyword anywhere in code, including property
/// names (`o.null`, `{ null: 1 }`) and type positions (`| null`). strings,
/// templates text and comments never match
///
/// this stays on the token stream on purpose: the tree models no type positions
/// and no property names, so a tree version would silently stop reporting
/// `const x: null = null` and `{ null: 1 }`
pub fn checkNullLiteral(context: *const root.Context) !void {
    for (context.tokens) |token| {
        if (token.kind != .word) continue;
        if (!std.mem.eql(u8, token.text, "null")) continue;
        try context.report(token.line, .resilience, root.null_literal, .err);
    }
}

/// a `let` declaration. a `let` used as a name (`o.let`, `{ let: string }`) or
/// in a type position is not a declaration and produces no node, which is
/// exactly the condition the token rule tests for
pub fn checkLetDeclaration(context: *const root.Context) !void {
    const module = context.module orelse return;
    for (context.walk) |entry| {
        if (entry.kind != .variable_decl) continue;
        if (module.nodeOf(entry.index).decl_kind != .@"let") continue;
        try context.report(module.spanOf(entry.index).line, .resilience, root.let_decl, .err);
    }
}

/// `switch ($expr) { ... }` -- a property or method named switch never parses as
/// a statement, so the node kind is the whole condition
pub fn checkSwitchStatement(context: *const root.Context) !void {
    const module = context.module orelse return;
    for (context.walk) |entry| {
        if (entry.kind != .switch_stmt) continue;
        try context.report(module.spanOf(entry.index).line, .resilience, root.switch_stmt, .err);
    }
}

/// `for ($init; $cond; $update) { $body }` -- C-style only. for..of and for..in
/// carry their keyword in the node instead, and a non-block body is left alone,
/// which is what the token rule's "`{` right after the `)`" test means
pub fn checkImperativeFor(context: *const root.Context) !void {
    const module = context.module orelse return;
    for (context.walk) |entry| {
        const index = entry.index;
        if (entry.kind != .for_stmt) continue;
        if (!std.mem.eql(u8, module.nodeOf(index).operator, ";")) continue;
        const body = module.lastChildOf(index) orelse continue;
        if (module.kindOf(body) != .block) continue;
        try context.report(module.spanOf(index).line, .resilience, root.imperative_for, .err);
    }
}

/// `` `$left == $right` ``. the tokeniser keeps `==` distinct from `===`/`!==`.
/// the tree records the operator on the binary node but not the operator's own
/// span, so the reported line would drift to the start of the left operand
pub fn checkDoubleEquals(context: *const root.Context) !void {
    for (context.tokens) |token| {
        if (token.kind != .punct) continue;
        if (!std.mem.eql(u8, token.text, "==")) continue;
        try context.report(token.line, .resilience, root.double_equals, .err);
    }
}

/// `` `$expr as any` `` -- the cast names `any`, whether it stands alone
/// (`as any`), carries a collection (`as any[]`) or joins a union
/// (`as any | T`). the ban's message covers all three, and matching only the
/// bare form left the escape hatch one word wide. `: any` annotations and
/// `import type` clauses are not casts and stay out
pub fn checkAsAny(context: *const root.Context) !void {
    const tokens = context.tokens;
    for (tokens, 0..) |token, i| {
        if (!token.isWord("as")) continue;
        if (tokens_mod.inImportClause(tokens, i)) continue;
        if (i + 1 >= tokens.len or !tokens[i + 1].isWord("any")) continue;
        try context.report(token.line, .resilience, root.as_any, .err);
    }
}

/// `` `$expr as $t1 as $t2` `` -- nested as-expressions with nothing between the
/// type and the next `as`. a parenthesis, comma or statement terminator ends the
/// search, which is why `(x as A) as B` and `f(x as A) as B` do not match
pub fn checkChainedCast(context: *const root.Context) !void {
    const tokens = context.tokens;
    for (tokens, 0..) |token, i| {
        if (!token.isWord("as")) continue;
        if (tokens_mod.inImportClause(tokens, i)) continue;
        if (tokens_mod.findAsEndingType(tokens, i + 1) == null) continue;
        try context.report(token.line, .resilience, root.chained_cast, .err);
    }
}

/// `` `export { $names } from $module` `` and `` `export * from $module` ``,
/// which re-export code the file does not define. `export type { ... } from`
/// and a local `export { a }` stay silent. the star form is one word wide of
/// the `{ ... }` form and the ban's message covers it, so it is a match
pub fn checkReexport(context: *const root.Context) !void {
    const tokens = context.tokens;
    for (tokens, 0..) |token, i| {
        if (!token.isWord("export")) continue;
        if (tokens_mod.isMemberAccess(tokens, i)) continue;
        if (i + 1 >= tokens.len) continue;

        if (tokens[i + 1].isPunct("*")) {
            try context.report(token.line, .resilience, root.reexport, .err);
            continue;
        }
        if (!tokens[i + 1].isPunct("{")) continue;

        const close = tokens_mod.matchingBracket(tokens, i + 1) orelse continue;
        if (close + 1 >= tokens.len or !tokens[close + 1].isWord("from")) continue;

        try context.report(token.line, .resilience, root.reexport, .err);
    }
}

/// `` `const $name = { $members } as const` ``. a type annotation on the name
/// (`const X: T = { ... } as const`) does not match, a binding pattern
/// (`const { a } = { ... } as const`) does. the tree does not record the
/// annotation, so a tree version would start reporting the annotated form
pub fn checkAsConst(context: *const root.Context) !void {
    const tokens = context.tokens;
    for (tokens, 0..) |token, i| {
        if (!token.isWord("const")) continue;
        if (tokens_mod.isMemberAccess(tokens, i)) continue;

        const eq = tokens_mod.findDeclaratorEquals(tokens, i + 1) orelse continue;
        if (eq + 1 >= tokens.len or !tokens[eq + 1].isPunct("{")) continue;

        const obj_close = tokens_mod.matchingBracket(tokens, eq + 1) orelse continue;
        if (obj_close + 2 >= tokens.len) continue;
        if (!tokens[obj_close + 1].isWord("as")) continue;
        if (!tokens[obj_close + 2].isWord("const")) continue;

        try context.report(token.line, .resilience, root.as_const, .err);
    }
}
