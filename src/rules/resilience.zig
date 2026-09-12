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

/// a call that passes a bare `true` or `false`, one finding per argument
///
/// `true` and `false` parse as literals, and a call's children are its callee
/// followed by its arguments, so a boolean binding (`f(flag)`) and a boolean
/// inside an argument (`f({ flag: true })`) are both left alone, which is what
/// the rule means: the call site has to say which job it asked for
///
/// a constructor is not a call and its arguments are not this rule's business,
/// so the call `new` wraps is skipped
pub fn checkBooleanFlagArgument(context: *const root.Context) !void {
    const module = context.module orelse return;
    for (context.walk) |entry| {
        if (entry.kind != .call) continue;
        if (isConstructed(module, entry.index)) continue;

        const callee = module.firstChildOf(entry.index) orelse continue;
        var argument = module.nextSiblingOf(callee);
        while (argument) |current| : (argument = module.nextSiblingOf(current)) {
            if (module.kindOf(current) != .literal) continue;
            const text = module.nodeOf(current).operator;
            if (!std.mem.eql(u8, text, "true") and !std.mem.eql(u8, text, "false")) continue;
            try context.report(module.spanOf(current).line, .resilience, root.boolean_flag_argument, .warn);
        }
    }
}

/// whether the front-end read this call as the operand of a `new`
fn isConstructed(module: *const ir.Module, index: ir.NodeIndex) bool {
    const parent = module.parentOf(index) orelse return false;
    if (module.kindOf(parent) != .unary) return false;
    return std.mem.eql(u8, module.nodeOf(parent).operator, "new");
}

/// a `for..of` whose body builds an array by pushing into it
///
/// a loop that pushes is a map, a filter or a reduce written the long way: the
/// reader has to run the loop in their head to learn what the result holds, and
/// the accumulator is a mutable binding the rest of the rule set forbids. only a
/// `for..of` counts, a property call is what counts as pushing (`push(item)` on a
/// plain function is not this rule's business), and a nested function's `push`
/// belongs to that function
pub fn checkForOfAccumulation(context: *const root.Context) !void {
    const module = context.module orelse return;
    try visitForOf(module, context, module.root);
}

fn visitForOf(module: *const ir.Module, context: *const root.Context, index: ir.NodeIndex) anyerror!void {
    if (isForOf(module, index)) {
        // a for..of appends its body last, after the declaration and the iterable
        if (module.lastChildOf(index)) |body| {
            if (holdsAccumulatorCall(module, body)) {
                try context.report(module.spanOf(index).line, .resilience, root.for_of_accumulation, .err);
                return;
            }
        }
    }

    var child = module.firstChildOf(index);
    while (child) |current| : (child = module.nextSiblingOf(current)) {
        try visitForOf(module, context, current);
    }
}

fn isForOf(module: *const ir.Module, index: ir.NodeIndex) bool {
    if (module.kindOf(index) != .for_stmt) return false;
    return std.mem.eql(u8, module.nodeOf(index).operator, "of");
}

/// whether a `push` or `unshift` call sits in `index`'s subtree, skipping the
/// subtrees of nested functions
fn holdsAccumulatorCall(module: *const ir.Module, index: ir.NodeIndex) bool {
    if (module.kindOf(index) == .call) {
        const callee = module.firstChildOf(index) orelse return false;
        if (module.kindOf(callee) == .member) {
            const name = module.nodeOf(callee).name;
            if (std.mem.eql(u8, name, "push") or std.mem.eql(u8, name, "unshift")) return true;
        }
    }

    var child = module.firstChildOf(index);
    while (child) |current| : (child = module.nextSiblingOf(current)) {
        if (module.kindOf(current).isCallable()) continue;
        if (holdsAccumulatorCall(module, current)) return true;
    }
    return false;
}

const probe = @import("probe.zig");

test "a for..of that pushes into an array is reported, and the neighbouring shapes are not" {
    const source =
        \\export function collect(records: readonly string[]): string[] {
        \\  const names: string[] = [];
        \\  for (const record of records) {
        \\    names.push(record);
        \\  }
        \\  while (names.length < 3) {
        \\    names.push(records[names.length]);
        \\  }
        \\  for (const record of records) {
        \\    const take = (): void => {
        \\      names.push(record);
        \\    };
        \\    handTo(take);
        \\  }
        \\  for (const record of records) {
        \\    push(record);
        \\  }
        \\  names.unshift("");
        \\  return names;
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "3: This for..of loop builds an array by pushing into it. Use map, filter, flatMap or reduce instead.",
    });
}

/// a `.all()` read whose `prepare` chain carries no LIMIT
///
/// the chain is walked down from the `.all()` call rather than up from the
/// query, which is what the detector does: `all` is the read, and the statement
/// it runs is the `prepare` call it hangs off through its members, parentheses
/// and `await`. the query text is the literal's own source text, quotes and all,
/// which is then what the two patterns read: any `select`, and a `limit` that is
/// a word of its own
pub fn checkUnboundedCollectionRead(context: *const root.Context) !void {
    const module = context.module orelse return;
    for (context.walk) |entry| {
        if (entry.kind != .call) continue;
        if (!isMemberCall(module, entry.index, "all")) continue;

        const prepare_call = prepareCallOf(module, entry.index) orelse continue;
        const query = queryText(module, prepare_call) orelse continue;
        if (!holds(query, "select", false)) continue;
        if (holds(query, "limit", true)) continue;

        try context.report(module.spanOf(chainStartOf(module, entry.index)).line, .resilience, root.unbounded_collection_read, .warn);
    }
}

/// the node a callee chain begins at. `a.b().c()` is one expression to a reader
/// and the detector reports it where it starts, but a front-end span begins each
/// member and call at the token before it, so the chain is followed down to the
/// value it hangs off
fn chainStartOf(module: *const ir.Module, index: ir.NodeIndex) ir.NodeIndex {
    var current = index;
    while (true) {
        const kind = module.kindOf(current);
        if (kind != .call and kind != .member) return current;
        current = module.firstChildOf(current) orelse return current;
    }
}

/// whether a call invokes the property `name` of something, as `rows.all()` does
fn isMemberCall(module: *const ir.Module, index: ir.NodeIndex, name: []const u8) bool {
    const callee = module.firstChildOf(index) orelse return false;
    if (module.kindOf(callee) != .member) return false;
    return std.mem.eql(u8, module.nodeOf(callee).name, name);
}

/// the `prepare(...)` call a chain hangs off, or null when the chain reaches
/// something else first. each step follows the callee of a call, the object of a
/// member, the operand of an `await` or the inner expression of a parenthesis
fn prepareCallOf(module: *const ir.Module, index: ir.NodeIndex) ?ir.NodeIndex {
    var current = index;
    while (true) {
        switch (module.kindOf(current)) {
            .call => {
                if (isMemberCall(module, current, "prepare")) return current;
                current = module.firstChildOf(current) orelse return null;
            },
            .member, .paren => current = module.firstChildOf(current) orelse return null,
            .unary => {
                if (!std.mem.eql(u8, module.nodeOf(current).operator, "await")) return null;
                current = module.firstChildOf(current) orelse return null;
            },
            else => return null,
        }
    }
}

/// the SQL a `prepare` call was handed. an argument that is not a quoted string
/// or a template is not a query the rule can read, so it is left alone rather
/// than guessed at
fn queryText(module: *const ir.Module, prepare_call: ir.NodeIndex) ?[]const u8 {
    const callee = module.firstChildOf(prepare_call) orelse return null;
    const argument = module.nextSiblingOf(callee) orelse return null;

    return switch (module.kindOf(argument)) {
        .literal => if (isQuoted(module.nodeOf(argument).operator)) module.textOf(argument) else null,
        .template => module.textOf(argument),
        else => null,
    };
}

fn isQuoted(text: []const u8) bool {
    if (text.len < 2) return false;
    return text[0] == '"' or text[0] == '\'';
}

/// whether `text` holds `word`, ignoring case. `whole_word` requires the bytes
/// around it not to continue a word, which is what the `\b` in the pattern
/// means: a column named `delimited` is not a LIMIT
fn holds(text: []const u8, word: []const u8, whole_word: bool) bool {
    var i: usize = 0;
    while (i + word.len <= text.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(text[i .. i + word.len], word)) continue;
        if (!whole_word) return true;
        const before_continues = i > 0 and isWordByte(text[i - 1]);
        const after_continues = i + word.len < text.len and isWordByte(text[i + word.len]);
        if (!before_continues and !after_continues) return true;
    }
    return false;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "a collection read with no LIMIT is reported, and the exclusions hold" {
    const source =
        \\export const each = database.prepare("SELECT fish_id FROM catches").all();
        \\export const bounded = database.prepare("SELECT fish_id FROM catches LIMIT 1").all();
        \\export const delimited = database.prepare("SELECT fish_id FROM delimited").all();
        \\export const wrapped = withRetry(database.prepare("SELECT x FROM y")).all();
        \\export const named = database.prepare(query).all();
        \\export const first = database.prepare("SELECT x FROM y").first();
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "1: This query reads a collection with no LIMIT, so it returns every matching row. Add an explicit LIMIT and paginate when the caller needs everything.",
        "3: This query reads a collection with no LIMIT, so it returns every matching row. Add an explicit LIMIT and paginate when the caller needs everything.",
    });
}

test "a bare boolean argument is reported once per argument" {
    const source =
        \\export const first = callWith(true, value, false);
        \\export const constructed = new Panel(true);
        \\export const named = callWith(flag);
        \\export const nested = callWith({ flag: true });
        \\export const chosen = callWith(flag ? true : false);
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "1: This call passes a bare boolean literal. Name the behaviour instead, or pass a named enum value.",
        "1: This call passes a bare boolean literal. Name the behaviour instead, or pass a named enum value.",
    });
}
