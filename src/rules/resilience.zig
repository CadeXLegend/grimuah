const std = @import("std");
const root = @import("../rules.zig");
const tokens_mod = @import("tokens.zig");
const ir = @import("../ir.zig");
const naming = @import("naming.zig");
const typemodel = @import("../lang/typemodel.zig");

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

/// `any` used as a type anywhere, which is the `as any` cast's sibling: the
/// annotation escape and the cast escape defeat the same check
///
/// a word is a type until it is a name, so three places are left alone: a member
/// access (`o.any`), an object or type-literal key (`{ any: 1 }`), and the tail
/// of the `as any` cast, which the ban beside this one reports. `any[]`,
/// `Array<any>`, `Promise<any>` and a return annotation all hold the word in
/// type position and are all reported, one finding per occurrence
///
/// this one stays on the token stream: the tree models a type only as an extent,
/// so a property key and a property's type look the same to it. the plugin era
/// reported `: any` and biome's recommended set owned it, and the native engine
/// then reported nothing at all for an annotation, which is the gap this closes
pub fn checkAnyType(context: *const root.Context) !void {
    const tokens = context.tokens;
    for (tokens, 0..) |token, i| {
        if (!token.isWord("any")) continue;
        if (tokens_mod.isMemberAccess(tokens, i)) continue;
        if (i > 0 and tokens[i - 1].isWord("as")) continue;
        if (i + 1 < tokens.len and tokens[i + 1].isPunct(":")) continue;
        try context.report(token.line, .resilience, root.any_type, .err);
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

/// a run of three or more branches that all test one subject
///
/// the shipped switch ban says to use a dispatch table, and an if-chain of
/// predicate tests and early returns is the same construct with the same
/// properties: one linear scan, one place to edit to add a case, and no place
/// that lists the cases. it passes the ban, which is why it needs its own rule
///
/// the run is recognisable without types, because every branch tests the same
/// subject and every branch returns. two shapes count: sibling `if` statements
/// that return and carry no `else`, grouped into runs of one subject so a single
/// unrelated guard in front of the run does not hide it, and an `else if` chain,
/// counted once at its head and only when every link of it is an `if`
pub fn checkIfChainDispatch(context: *const root.Context) !void {
    const module = context.module orelse return;
    var dispatch = Dispatch{ .module = module, .context = context };

    for (context.walk) |entry| {
        switch (entry.kind) {
            .block, .case_clause => try dispatch.scanStatements(entry.index),
            .if_stmt => try dispatch.scanChain(entry.index),
            else => {},
        }
    }
}

const Dispatch = struct {
    module: *const ir.Module,
    context: *const root.Context,
    group_subject: []const u8 = "",
    group_line: u32 = 0,
    group_count: usize = 0,

    /// the run in progress, which the detector groups by subject: a dispatch run
    /// is often preceded by one unrelated guard, and requiring the whole
    /// sequence to agree would hide every such run
    fn scanStatements(self: *Dispatch, container: ir.NodeIndex) !void {
        var child = self.module.firstChildOf(container);
        while (child) |statement| : (child = self.module.nextSiblingOf(statement)) {
            // a `case` clause holds its case value first, which is not a statement
            if (!self.module.kindOf(statement).isStatement()) continue;

            const subject = branchSubject(self.module, statement) orelse {
                try self.flushGroup();
                continue;
            };
            if (self.group_count > 0 and !std.mem.eql(u8, self.group_subject, subject)) try self.flushGroup();
            if (self.group_count == 0) {
                self.group_subject = subject;
                self.group_line = self.module.spanOf(statement).line;
            }
            self.group_count += 1;
        }
        try self.flushGroup();
    }

    fn flushGroup(self: *Dispatch) !void {
        const count = self.group_count;
        const line = self.group_line;
        self.group_count = 0;
        if (count < dispatch_branch_minimum) return;
        try report(self.context, line, count);
    }

    /// an `else if` chain, reported at its head only, because a chain of n
    /// branches would otherwise report itself n minus two times. a chain whose
    /// `else` is not another `if` is not a chain at all, which is what the
    /// detector's own early return says
    fn scanChain(self: *Dispatch, head: ir.NodeIndex) !void {
        if (isElseBranch(self.module, head)) return;

        var count: usize = 0;
        var subject: []const u8 = "";
        var same_subject = true;
        var current: ?ir.NodeIndex = head;
        while (current) |branch| {
            const condition = self.module.firstChildOf(branch) orelse break;
            const branch_subject = subjectText(self.module, condition);
            if (count == 0) subject = branch_subject else if (!std.mem.eql(u8, subject, branch_subject)) same_subject = false;
            count += 1;

            const next = elseBranchOf(self.module, branch) orelse break;
            if (self.module.kindOf(next) != .if_stmt) return;
            current = next;
        }

        if (count < dispatch_branch_minimum or !same_subject) return;
        try report(self.context, self.module.spanOf(head).line, count);
    }
};

const dispatch_branch_minimum = 3;

fn report(context: *const root.Context, line: u32, count: usize) !void {
    const message = try std.fmt.allocPrint(context.allocator, root.if_chain_dispatch, .{count});
    defer context.allocator.free(message);
    try context.report(line, .resilience, message, .warn);
}

/// the subject an `if` statement tests, when that statement is one branch of a
/// dispatch: no `else`, and a branch that returns either the value or nothing
fn branchSubject(module: *const ir.Module, statement: ir.NodeIndex) ?[]const u8 {
    if (module.kindOf(statement) != .if_stmt) return null;

    const condition = module.firstChildOf(statement) orelse return null;
    const then_branch = module.nextSiblingOf(condition) orelse return null;
    if (elseBranchOf(module, statement) != null) return null;
    if (!branchReturns(module, then_branch)) return null;
    return subjectText(module, condition);
}

/// the `else` of an `if`, which the front-end appends after the branch it runs
fn elseBranchOf(module: *const ir.Module, statement: ir.NodeIndex) ?ir.NodeIndex {
    const condition = module.firstChildOf(statement) orelse return null;
    const then_branch = module.nextSiblingOf(condition) orelse return null;
    return module.nextSiblingOf(then_branch);
}

/// whether a statement is the `else` half of the `if` that holds it, which is
/// what tells a chain head from a link in it
fn isElseBranch(module: *const ir.Module, statement: ir.NodeIndex) bool {
    const parent = module.parentOf(statement) orelse return false;
    if (module.kindOf(parent) != .if_stmt) return false;
    const else_branch = elseBranchOf(module, parent) orelse return false;
    return else_branch == statement;
}

/// whether a branch hands back a value: a `return`, or a block whose one
/// statement is a `return`
fn branchReturns(module: *const ir.Module, statement: ir.NodeIndex) bool {
    if (module.kindOf(statement) == .return_stmt) return true;
    if (module.kindOf(statement) != .block) return false;
    const only = module.firstChildOf(statement) orelse return false;
    if (module.nextSiblingOf(only) != null) return false;
    return module.kindOf(only) == .return_stmt;
}

/// the subject a condition tests, which is the whole precision of the rule: a
/// comparison is about its left side, a one-argument predicate call is about its
/// argument, and each of those is unwrapped once, in that order, from a unary
/// operand and from a parenthesised expression
fn subjectText(module: *const ir.Module, condition: ir.NodeIndex) []const u8 {
    var current = condition;
    if (module.kindOf(current) == .unary) current = firstChildOr(module, current);
    if (module.kindOf(current) == .paren) current = firstChildOr(module, current);
    if (module.kindOf(current) == .binary) return module.expressionText(firstChildOr(module, current));

    if (module.kindOf(current) == .call) {
        const callee = module.firstChildOf(current) orelse return module.expressionText(current);
        const argument = module.nextSiblingOf(callee) orelse return module.expressionText(current);
        if (module.nextSiblingOf(argument) != null) return module.expressionText(current);
        return module.expressionText(argument);
    }
    return module.expressionText(current);
}

fn firstChildOr(module: *const ir.Module, index: ir.NodeIndex) ir.NodeIndex {
    return module.firstChildOf(index) orelse index;
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

/// a surface module's stem carries two parts: `<name>.<kind>`, before the
/// extension
const MIN_SURFACE_STEM_PARTS = 2;

/// a union of two or more string literals in a type alias, a property, a
/// parameter or a variable annotation
///
/// the file scope is the suffixed-module convention: a surface module is named
/// `<name>.<kind>.ts`, so an unsuffixed module is the root library or a process
/// entry script, and an entry script cannot use an enum at runtime, which is why
/// the corpus duplicates its string tables there. a `.d.ts` declares a type it
/// does not own, so it is out of scope too
///
/// a return annotation is the one position not read: this detector reports the
/// four above and no function's return, unlike the other three type rules
pub fn checkLiteralUnionEnum(context: *const root.Context) !void {
    if (std.mem.endsWith(u8, context.path, ".d.ts")) return;
    if (naming.stemPartCount(naming.fileNameOf(context.path)) < MIN_SURFACE_STEM_PARTS) return;
    const module = context.module orelse return;

    var table = try typemodel.analyze(context.allocator, context.tokens, module, context.walk);
    defer table.deinit();

    for (table.items) |annotation| {
        if (annotation.position == .return_type) continue;
        const member_count = typemodel.stringLiteralUnionCount(context.tokens, annotation.type_start, annotation.type_end);
        if (member_count == 0) continue;
        const message = try std.fmt.allocPrint(context.allocator, root.literal_union_enum, .{member_count});
        defer context.allocator.free(message);
        // the detector reports the type node's own start, which for each of these
        // positions is the type rather than the declaration that carries it
        try context.report(context.tokens[annotation.type_start].line, .resilience, message, .warn);
    }
}

/// an optional property, in an interface and in a type literal
///
/// the detector has no file scope at all: `detect` does not even receive the
/// path, so a `.d.ts` declares its optionals under the same ban as any other
/// file
///
/// a parameter's `?` is not a property's `?`, which is the correctness risk this
/// reader removes by construction: the annotation carries `optional` only for a
/// member of an object type, so `function send(name?: string)` is silent while
/// `{ name?: string }` is not
pub fn checkOptionalProperties(context: *const root.Context) !void {
    const module = context.module orelse return;

    var table = try typemodel.analyze(context.allocator, context.tokens, module, context.walk);
    defer table.deinit();

    for (table.items) |annotation| {
        if (annotation.position != .property_type) continue;
        if (!annotation.optional) continue;
        // the detector reports the property signature's own start, which is the
        // member rather than its annotation
        try context.report(context.tokens[annotation.report_start].line, .resilience, root.optional_property, .warn);
    }
}

/// a mutable array in a parameter, a function's return type or an object type's
/// property
///
/// a type alias and a local binding are out of scope on purpose: a separate rule,
/// `require-readonly-type-alias`, covers that form. a class field is out of scope
/// for the opposite reason, because a mutable field is state the class owns
/// rather than a value it was handed, and the reader never reads a field's
/// annotation, so that exclusion comes for free
pub fn checkReadonlyCollectionSignatures(context: *const root.Context) !void {
    const module = context.module orelse return;

    var table = try typemodel.analyze(context.allocator, context.tokens, module, context.walk);
    defer table.deinit();

    for (table.items) |annotation| {
        const report_token = switch (annotation.position) {
            // a return annotation is reported at the type itself, while a
            // parameter and a property are reported at the declaration that
            // carries them
            .return_type => annotation.type_start,
            .parameter_type, .property_type => annotation.report_start,
            .alias_type, .variable_type => continue,
        };
        if (!typemodel.isMutableArrayType(context.tokens, annotation.type_start, annotation.type_end)) continue;
        try context.report(context.tokens[report_token].line, .resilience, root.readonly_collection_signature, .warn);
    }
}

/// a mutable property of a type literal
///
/// the detector walks `TypeLiteral` nodes only, so a property of an interface is
/// never reported. that is its own narrowing rather than an oversight, and the
/// reader keeps it as written: the annotation records which object type the
/// member belongs to, and only a type literal's members are read here
pub fn checkReadonlyTypeMembers(context: *const root.Context) !void {
    const module = context.module orelse return;

    var table = try typemodel.analyze(context.allocator, context.tokens, module, context.walk);
    defer table.deinit();

    for (table.items) |annotation| {
        // only a property of a type literal carries the object kind, so the test
        // on it also decides the position
        if (annotation.object != .type_literal) continue;
        if (annotation.readonly) continue;
        try context.report(context.tokens[annotation.report_start].line, .resilience, root.readonly_type_member, .warn);
    }
}

/// an exported async operation whose declared result is a bare boolean or number
///
/// a scalar result carries no failure channel, so a caller cannot tell the
/// operation's real answer from its error case and the reason the operation
/// already holds is dropped at the boundary that had it. an operation the file
/// does not export is out of scope: the detector requires the `export` modifier,
/// so a module-private helper's failure is read by the file that declares it
///
/// the detector walks function declarations and variable statements, which is
/// three shapes here: an exported `async function`, an exported declarator whose
/// initializer is an async arrow, and the same with a function expression
pub fn checkScalarFailureReturn(context: *const root.Context) !void {
    const module = context.module orelse return;

    for (context.walk) |entry| {
        switch (entry.kind) {
            .function_decl => try checkScalarDeclaration(context, module, entry.index),
            .variable_decl => try checkScalarDeclarator(context, module, entry.index),
            else => {},
        }
    }
}

/// `export async function f(): Promise<boolean>`
///
/// the reported line is the declaration's own `getStart()` in the detector, and
/// its modifiers are part of that node, so an `export` on a line of its own is
/// where the finding lands
fn checkScalarDeclaration(context: *const root.Context, module: *const ir.Module, index: ir.NodeIndex) !void {
    // an anonymous `export default async function (): Promise<boolean>` declares
    // no name, and the detector requires one
    if (module.nodeOf(index).name.len == 0) return;

    // the detector's export test is the modifier on the declaration itself. a
    // class method and an object literal's method reach this tree as callables
    // too, and neither is exported, so this keeps them out as well
    const wrapper = module.parentOf(index) orelse return;
    if (module.kindOf(wrapper) != .export_decl) return;
    if (!declaresScalarPromise(context, module, index)) return;

    try context.report(module.spanOf(wrapper).line, .resilience, root.scalar_failure_return, .warn);
}

/// `export const f = async (): Promise<boolean> => ...`
///
/// the reported node is the declarator, which the detector reads as a
/// `VariableDeclaration`: the modifiers belong to the statement around it, so the
/// finding lands on the name rather than on the `const`. a destructured
/// declarator names no identifier and is skipped, the same way the detector's own
/// `isIdentifier` test skips it
fn checkScalarDeclarator(context: *const root.Context, module: *const ir.Module, index: ir.NodeIndex) !void {
    const wrapper = module.parentOf(index) orelse return;
    if (module.kindOf(wrapper) != .export_decl) return;

    // the parser appends a declarator's initializer as the child straight after
    // that declarator's name, so the name's next sibling is its own value
    var child = module.firstChildOf(index);
    while (child) |current| : (child = module.nextSiblingOf(current)) {
        if (module.kindOf(current) != .identifier) continue;
        if (module.nodeOf(current).binding != .variable) continue;

        const initializer = module.nextSiblingOf(current) orelse continue;
        if (!module.kindOf(initializer).isCallable()) continue;
        if (!declaresScalarPromise(context, module, initializer)) continue;

        try context.report(module.spanOf(current).line, .resilience, root.scalar_failure_return, .warn);
    }
}

/// whether a callable is async and declares a `Promise<boolean>` or
/// `Promise<number>`, which is the pair the detector reports on
fn declaresScalarPromise(context: *const root.Context, module: *const ir.Module, index: ir.NodeIndex) bool {
    const span = module.spanOf(index);
    const callable_start = typemodel.tokenAtOrAfter(context.tokens, span.start);
    if (!isAsyncCallable(context.tokens, callable_start)) return false;

    const declared = typemodel.returnTypeOfNode(module, context.tokens, index) orelse return false;
    return isScalarPromise(context.tokens, declared);
}

/// whether a callable carries the `async` modifier
///
/// the statement parser consumes `async` before it hands an `async function`
/// declaration to the function parser, so a declaration's span begins at its own
/// keyword while an arrow or a function expression begins at `async` itself. the
/// scan covers the token before the span as well as the span's first token, which
/// answers both shapes without asking which one it is, and the two are the whole
/// window: only `abstract` can stand between an `async` modifier and the keyword
/// in a statement position
fn isAsyncCallable(tokens: []const Token, callable_start: usize) bool {
    const from = if (callable_start == 0) 0 else callable_start - 1;
    for (tokens[from..@min(callable_start + 1, tokens.len)]) |token| {
        if (token.isWord("async")) return true;
    }
    return false;
}

/// `Promise`, `<`, the settled type, `>`: four tokens and no more, so
/// `Promise<boolean[]>` and `Promise<boolean | undefined>` are other results
const PROMISE_SCALAR_TOKENS = 4;

/// whether a return type is a reference named `Promise` over a bare `boolean` or
/// `number`
///
/// the detector reads the settled type as its own source text and compares that
/// with the two scalars, so the scalar has to be the whole of it and the
/// reference has to be named `Promise` exactly: `globalThis.Promise<boolean>` is
/// a different name, and `Promise<Array<boolean>>` a different result
fn isScalarPromise(tokens: []const Token, declared: typemodel.Extent) bool {
    if (declared.end - declared.start != PROMISE_SCALAR_TOKENS) return false;

    const name = tokens[declared.start];
    const settled = tokens[declared.start + 2];
    if (!name.isWord("Promise")) return false;
    if (!tokens[declared.start + 1].isPunct("<")) return false;
    if (!settled.isWord("boolean") and !settled.isWord("number")) return false;
    return tokens[declared.start + 3].isPunct(">");
}

/// the number of distinct files that must declare one body for the copy to be a defect
/// one other file is enough: the same implementation written twice is one decision written
/// twice, which is the whole rule
const DUPLICATE_BODY_FILE_THRESHOLD = 2;

/// a function body written byte for byte into another file under the same name
/// the run's index holds one count per `name|body` fingerprint, so the verdict is one
/// lookup per declaration rather than a walk of the run
/// the count is of distinct files and
/// the declaring file always counts itself, so a count under the threshold is a body
/// nothing outside this file writes
/// the reported line is the body's own start, which is where the detector's
/// `body.getStart()` lands: the `{` of a block, or the first token of an arrow's expression
/// body
pub fn checkDuplicatedFunctionBody(
    allocator: std.mem.Allocator,
    index: *const root.FingerprintIndex,
    project: *const root.Project,
    path: []const u8,
    rule: *const root.Rule,
    findings: *std.ArrayList(root.Finding),
) std.mem.Allocator.Error!void {
    for (project.body_fingerprints.items) |fingerprint| {
        const owners = index.body_files.get(fingerprint.key) orelse continue;
        if (owners.files < DUPLICATE_BODY_FILE_THRESHOLD) continue;

        // the message names the function, so it is formatted rather than taken from the
        // table as a finished string
        // the format is the same constant the table names, so
        // the wording still has one source
        const message = try std.fmt.allocPrint(allocator, root.duplicated_function_body, .{fingerprint.name});
        defer allocator.free(message);
        try findings.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .line = fingerprint.line,
            .message = try allocator.dupe(u8, message),
            .layer = rule.layer.name(),
            .severity = rule.severity,
        });
    }
}

const probe = @import("probe.zig");

test "a mutable property of a type literal is reported, and an interface's is not" {
    const message = "This property is mutable. Add `readonly`, and build a new object when a layer needs a changed copy.";
    const source =
        \\export type Options = {
        \\  readonly kept: string;
        \\  changed: number;
        \\  spread:
        \\    boolean;
        \\};
        \\
        \\export interface Draft {
        \\  changed: string;
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "3: " ++ message,
        // a property is reported where it starts, not where its type starts
        "4: " ++ message,
    });
}

test "a nested type literal is read and a method or index signature is not a property" {
    const message = "This property is mutable. Add `readonly`, and build a new object when a layer needs a changed copy.";
    const source =
        \\export type Nested = {
        \\  readonly inner: {
        \\    changed: string;
        \\  };
        \\  read(key: string): string;
        \\  [key: string]: string;
        \\};
        \\
        \\export class Holder {
        \\  changed = "x";
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "3: " ++ message,
    });
}

test "a readonly member, a signature and a declared class field are out of scope" {
    const source =
        \\export type Guarded = {
        \\  readonly first: string;
        \\  readonly second: number;
        \\  readonly third: readonly string[];
        \\};
        \\
        \\export class Holder {
        \\  private changed: string = "x";
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{});
}

test "a mutable array in a parameter, a return and a property is reported" {
    const message = "This signature hands over a mutable array. Declare it as `readonly T[]` or `ReadonlyArray<T>`.";
    const source =
        \\export type Tracks = {
        \\  readonly queue: Track[];
        \\  readonly done: Array<Track>;
        \\};
        \\
        \\export interface Player {
        \\  readonly history: Track[];
        \\}
        \\
        \\export type Handoff = (rows: Track[]) => Track[];
        \\
        \\export function order(queue: Track[]): Track[] {
        \\  return queue;
        \\}
        \\
        \\export function gather(entries: Array<Track>): Array<Track> {
        \\  return entries;
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "2: " ++ message,
        "3: " ++ message,
        "7: " ++ message,
        "10: " ++ message,
        "10: " ++ message,
        "12: " ++ message,
        "12: " ++ message,
        "16: " ++ message,
        "16: " ++ message,
    });
}

test "a readonly array, a readonly reference, a union and a qualified name are not reported" {
    const message = "This signature hands over a mutable array. Declare it as `readonly T[]` or `ReadonlyArray<T>`.";
    const source =
        \\export type Held = {
        \\  readonly frozen: readonly Track[];
        \\  readonly ref: ReadonlyArray<Track>;
        \\  readonly either: Track[] | undefined;
        \\  readonly qualified: globalThis.Array<Track>;
        \\  readonly element: Track[][];
        \\};
        \\
        \\export function keep(queue: readonly Track[], done: ReadonlyArray<Track>): readonly Track[] {
        \\  return queue;
        \\}
        \\
        \\export type Predicate = {
        \\  readonly maybe: Track extends string ? string : Track[];
        \\  readonly spread:
        \\    Track[];
        \\  readonly guarded: string & {}[];
        \\  readonly make: () => Track[];
        \\};
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        // an array of arrays is still an array, so that one member reports
        "6: " ++ message,
        // a property is reported where it starts, not where its type starts
        "15: " ++ message,
        // the property's own type is a function, so the one report here is the
        // function's return type, and the guard keeps it from being counted twice
        "18: " ++ message,
    });
}

test "a class field, a type alias and a local binding are out of scope" {
    const source =
        \\export type Buffer = Track[];
        \\export const shared: Track[] = [];
        \\
        \\export class Holder {
        \\  private readonly queue: Track[] = [];
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{});
}

test "an optional property is reported in an interface and a type literal, and an optional parameter is not" {
    const source =
        \\export interface Draft {
        \\  readonly channel?: string;
        \\}
        \\
        \\export type Options = { readonly retries?: number };
        \\
        \\export function fill(suffix?: string): string {
        \\  return suffix ?? "";
        \\}
        \\
        \\export class Holder {
        \\  readonly channel?: string;
        \\}
        \\
    ;
    const rows = &.{
        "2: This property is optional. Make it required and default it at the boundary, or model the states as a discriminated union.",
        "5: This property is optional. Make it required and default it at the boundary, or model the states as a discriminated union.",
    };
    try probe.expect(.resilience, "probe.ts", source, rows);
    // a declaration file is in scope, unlike the literal-union rule's
    try probe.expect(.resilience, "probe.d.ts", source, rows);
}

test "a nested type literal is read and an optional method is not a property" {
    const source =
        \\export type Outer = {
        \\  readonly inner: { readonly deep?: string };
        \\  run?(): void;
        \\};
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "2: This property is optional. Make it required and default it at the boundary, or model the states as a discriminated union.",
    });
}

test "a readonly modifier does not hide an optional property" {
    const source =
        \\export type Options = {
        \\  readonly first?: string;
        \\  second?: number;
        \\  third: boolean;
        \\};
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "2: This property is optional. Make it required and default it at the boundary, or model the states as a discriminated union.",
        "3: This property is optional. Make it required and default it at the boundary, or model the states as a discriminated union.",
        // the two members without `readonly` are the readonly rule's business
        "3: This property is mutable. Add `readonly`, and build a new object when a layer needs a changed copy.",
        "4: This property is mutable. Add `readonly`, and build a new object when a layer needs a changed copy.",
    });
}

test "a literal union is reported in the four positions, and a return annotation is not" {
    const source =
        \\export type Wave = "left" | "right";
        \\
        \\export interface Bearing {
        \\  readonly side: "port" | "starboard";
        \\}
        \\
        \\export const limit: "low" | "high" = "low";
        \\
        \\export function steer(direction: "up" | "down"): "forward" | "back" {
        \\  return "forward";
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.service.ts", source, &.{
        "1: This union of 2 string literals carries no runtime value. Declare a string enum and use its members as the discriminant.",
        "4: This union of 2 string literals carries no runtime value. Declare a string enum and use its members as the discriminant.",
        "7: This union of 2 string literals carries no runtime value. Declare a string enum and use its members as the discriminant.",
        "9: This union of 2 string literals carries no runtime value. Declare a string enum and use its members as the discriminant.",
    });
}

test "a union written across lines with a leading bar is reported at the bar" {
    const source =
        \\export type Wave =
        \\  | "left"
        \\  | "right";
        \\
    ;
    try probe.expect(.resilience, "probe.service.ts", source, &.{
        "2: This union of 2 string literals carries no runtime value. Declare a string enum and use its members as the discriminant.",
    });
}

test "a union inside a type literal is reported and the alias that holds it is not" {
    const source =
        \\export type Heading = { readonly turn: "near" | "far" };
        \\
    ;
    try probe.expect(.resilience, "probe.service.ts", source, &.{
        "1: This union of 2 string literals carries no runtime value. Declare a string enum and use its members as the discriminant.",
    });
}

test "an unsuffixed module and a declaration file are out of scope" {
    const source =
        \\export type Wave = "left" | "right";
        \\
        \\export const limit: "low" | "high" = "low";
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{});
    try probe.expect(.resilience, "probe.d.ts", source, &.{});
    try probe.expect(.resilience, "probe/service.ts", source, &.{});
}

test "one literal, a mixed union and a parenthesised literal are not reported" {
    const source =
        \\export type Single = "left";
        \\export type Mixed = "left" | "right" | number;
        \\export type Wrapped = ("left") | "right";
        \\export type Named = Left | Right;
        \\
    ;
    try probe.expect(.resilience, "probe.service.ts", source, &.{});
}

test "a for..of that pushes into an array is reported, and the neighbouring shapes are not" {
    const source =
        \\export function collect(records: readonly string[]): readonly string[] {
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

test "a run of three branches over one subject is reported, and shorter or mixed runs are not" {
    const source =
        \\export function labelFor(kind: string): string {
        \\  if (kind === "slam") {
        \\    return "Slam";
        \\  }
        \\  if (kind === "sweep") {
        \\    return "Sweep";
        \\  }
        \\  if (kind === "swipe") {
        \\    return "Swipe";
        \\  }
        \\  return "Unknown";
        \\}
        \\
        \\export function pairFor(kind: string): string {
        \\  if (kind === "a") {
        \\    return "A";
        \\  }
        \\  if (kind === "b") {
        \\    return "B";
        \\  }
        \\  return "Unknown";
        \\}
        \\
        \\export function mixedFor(kind: string, other: string): string {
        \\  if (kind === "a") {
        \\    return "A";
        \\  }
        \\  if (other === "b") {
        \\    return "B";
        \\  }
        \\  if (kind === "c") {
        \\    return "C";
        \\  }
        \\  return "Unknown";
        \\}
        \\
        \\export function chainFor(kind: string): string {
        \\  if (kind === "a") {
        \\    return "A";
        \\  } else if (kind === "b") {
        \\    return "B";
        \\  } else if (kind === "c") {
        \\    return "C";
        \\  }
        \\  return "Unknown";
        \\}
        \\
        \\export function handledFor(kind: string): string {
        \\  if (kind === "a") {
        \\    return "A";
        \\  } else if (kind === "b") {
        \\    return "B";
        \\  } else {
        \\    return "C";
        \\  }
        \\}
        \\
        \\export function assignedFor(kind: string): string {
        \\  var label = "Unknown";
        \\  if (kind === "a") {
        \\    label = "A";
        \\  }
        \\  if (kind === "b") {
        \\    label = "B";
        \\  }
        \\  if (kind === "c") {
        \\    label = "C";
        \\  }
        \\  return label;
        \\}
        \\
        \\export function guardedFor(kind: string, blocked: boolean): string {
        \\  if (blocked) {
        \\    return "blocked";
        \\  }
        \\  if (kind === "a") {
        \\    return "A";
        \\  }
        \\  if (kind === "b") {
        \\    return "B";
        \\  }
        \\  if (kind === "c") {
        \\    return "C";
        \\  }
        \\  return "Unknown";
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "2: These 3 branches dispatch on one subject. Declare a Record or Map from the subject's value to the handler.",
        "38: These 3 branches dispatch on one subject. Declare a Record or Map from the subject's value to the handler.",
        "76: These 3 branches dispatch on one subject. Declare a Record or Map from the subject's value to the handler.",
    });
}

test "any in type position is reported, and a name spelled any is not" {
    const source =
        \\export function widen(values: any[]): Array<any> {
        \\  return values;
        \\}
        \\
        \\export const narrow = (value: unknown): any => value;
        \\
        \\export type Loose = { field: any };
        \\
        \\export const named = { any: "any" };
        \\
        \\export const read = named.any;
        \\
        \\export function keyed(): { any: string } {
        \\  return { any: "value" };
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "1: This `any` type bypasses type safety. Write the type you mean instead.",
        "1: This `any` type bypasses type safety. Write the type you mean instead.",
        "5: This `any` type bypasses type safety. Write the type you mean instead.",
        "7: This `any` type bypasses type safety. Write the type you mean instead.",
        // the two `any` types above are also arrays, so the collection rule
        // reports the parameter and the return separately
        "1: This signature hands over a mutable array. Declare it as `readonly T[]` or `ReadonlyArray<T>`.",
        "1: This signature hands over a mutable array. Declare it as `readonly T[]` or `ReadonlyArray<T>`.",
        // `Loose` is a type literal, so its member belongs to the readonly rule
        "7: This property is mutable. Add `readonly`, and build a new object when a layer needs a changed copy.",
        // and so is the object literal this function returns
        "13: This property is mutable. Add `readonly`, and build a new object when a layer needs a changed copy.",
    });
}

test "an exported async scalar result is reported, and the shapes around it are not" {
    const source =
        \\export
        \\async function load(): Promise<boolean> {
        \\  return true;
        \\}
        \\
        \\export const retry =
        \\  async (attempts: number): Promise<number> => attempts;
        \\
        \\export const shifted: () => Promise<boolean> = async () => true;
        \\
        \\async function hidden(): Promise<boolean> {
        \\  return false;
        \\}
        \\
        \\export function plain(): Promise<boolean> {
        \\  return true;
        \\}
        \\
        \\export async function quiet(): Promise<void> {}
        \\
        \\export async function nested(): Promise<Array<boolean>> {
        \\  return [];
        \\}
        \\
        \\export async function unioned(): Promise<boolean | undefined> {
        \\  return undefined;
        \\}
        \\
        \\export default async function (): Promise<boolean> {
        \\  return true;
        \\}
        \\
        \\export class Worker {
        \\  async run(): Promise<boolean> {
        \\    return true;
        \\  }
        \\}
        \\
        \\export const named = async function (attempts: number): Promise<number> {
        \\  return attempts;
        \\};
        \\
        \\export async function aliased(): Settled<boolean> {
        \\  return true;
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        // the declaration's modifiers are its own node's start, so the `export`
        // on a line of its own is where the finding lands
        "1: This async operation reports its failure as a bare boolean or number, so a caller cannot tell the answer from the error. Return an outcome value that names the failure reason.",
        // a declarator is reported at its name, not at the `const`, and its
        // arrow sits on the next line
        "6: This async operation reports its failure as a bare boolean or number, so a caller cannot tell the answer from the error. Return an outcome value that names the failure reason.",
        "39: This async operation reports its failure as a bare boolean or number, so a caller cannot tell the answer from the error. Return an outcome value that names the failure reason.",
    });
}

/// the row a duplicate-body finding produces, built from the table's message so a wording
/// change is one edit
fn duplicateBodyRow(allocator: std.mem.Allocator, path: []const u8, line: u32, name: []const u8) ![]const u8 {
    const message = try std.fmt.allocPrint(allocator, root.duplicated_function_body, .{name});
    defer allocator.free(message);
    return std.fmt.allocPrint(allocator, "{s}:{d}: {s}", .{ path, line, message });
}

test "a body written into another file under the same name is reported, and the shapes the detector does not collect are not" {
    const allocator = std.testing.allocator;

    // the four names that pair up
    // `charge` and `settle` put the body's `{` on a line of its
    // own in the second file, `makeCharge` is a function expression in one and an arrow in
    // the other, and the two are keyed on the variable's name whichever shape the
    // initializer has
    const charge = try duplicateBodyRow(allocator, "src/a.service.ts", 1, "charge");
    defer allocator.free(charge);
    const split_charge = try duplicateBodyRow(allocator, "src/b.service.ts", 2, "charge");
    defer allocator.free(split_charge);
    const settle = try duplicateBodyRow(allocator, "src/a.service.ts", 5, "settle");
    defer allocator.free(settle);
    const split_settle = try duplicateBodyRow(allocator, "src/b.service.ts", 8, "settle");
    defer allocator.free(split_settle);
    const make_charge = try duplicateBodyRow(allocator, "src/a.service.ts", 9, "makeCharge");
    defer allocator.free(make_charge);
    const arrow_charge = try duplicateBodyRow(allocator, "src/b.service.ts", 13, "makeCharge");
    defer allocator.free(arrow_charge);

    try probe.expectProject(.resilience, &.{
        // `shadow` is declared twice in this file under one name and one body, so the count
        // of FILES is one and neither declaration is a site
        // `alpha` and `beta` share a body under two names in the two files, which is the
        // renamed rule's case and not this one
        // `tiny` is under the minimum
        // the class method's body is a byte-identical copy of `charge`'s, and the detector
        // collects no method
        // the second file writes its bodies across more lines than the first, which the
        // collapse folds into the same key
        .{ .path = "src/a.service.ts", .content =
        \\export function charge(amount: number, rate: number): number {
        \\  return Math.round(amount * rate) + Math.floor(amount / rate);
        \\}
        \\
        \\export const settle = (amount: number, rate: number): number => {
        \\  return Math.min(amount, rate) + Math.max(amount, rate);
        \\};
        \\
        \\export const makeCharge = function (amount: number, rate: number): number {
        \\  return Math.max(amount, rate) - Math.min(amount, rate);
        \\};
        \\
        \\function shadow(amount: number, rate: number): number {
        \\  return Math.round(amount - rate) * Math.floor(amount + rate);
        \\}
        \\
        \\export function outer(amount: number, rate: number): number {
        \\  function shadow(amount: number, rate: number): number {
        \\    return Math.round(amount - rate) * Math.floor(amount + rate);
        \\  }
        \\  return shadow(amount, rate);
        \\}
        \\
        \\export function alpha(amount: number, rate: number): number {
        \\  return Math.round(amount / rate) + Math.floor(amount * rate);
        \\}
        \\
        \\export const tiny = (): number => 1 + 1;
        \\
        \\export class Ledger {
        \\  charge(amount: number, rate: number): number {
        \\    return Math.round(amount * rate) + Math.floor(amount / rate);
        \\  }
        \\}
        \\
        },
        .{ .path = "src/b.service.ts", .content =
        \\export function charge(amount: number, rate: number): number
        \\{
        \\  return Math.round(amount
        \\    * rate) + Math.floor(amount / rate);
        \\}
        \\
        \\export const settle = (amount: number, rate: number): number =>
        \\{
        \\  return Math.min(amount,
        \\    rate) + Math.max(amount, rate);
        \\};
        \\
        \\export const makeCharge = (amount: number, rate: number): number => {
        \\  return Math.max(amount, rate) - Math.min(amount, rate);
        \\};
        \\
        \\export function beta(amount: number, rate: number): number {
        \\  return Math.round(amount / rate) + Math.floor(amount * rate);
        \\}
        \\
        \\export const tiny = (): number => 1 + 1;
        \\
        \\export class Ledger {
        \\  charge(amount: number, rate: number): number {
        \\    return Math.round(amount * rate) + Math.floor(amount / rate);
        \\  }
        \\}
        \\
        },
    }, &.{ charge, settle, make_charge, split_charge, split_settle, arrow_charge });
}

test "a body's text and its line come from its leftmost token, not from its own span" {
    const allocator = std.testing.allocator;
    // the detector reads an expression body's own start, and a chain's outermost node
    // begins at the last member rather than at the value the chain hangs off: this body
    // starts at `text` on line 2 while the node for the whole of it starts on line 4
    const first = try duplicateBodyRow(allocator, "src/a.service.ts", 2, "escapeText");
    defer allocator.free(first);
    const second = try duplicateBodyRow(allocator, "src/b.service.ts", 2, "escapeText");
    defer allocator.free(second);

    // the two files write the same bytes, so the text the keys hold is the same however the
    // body is read, and the line is the only thing this test can be about
    // a body read from
    // its own span reports line 4
    try probe.expectProject(.resilience, &.{
        .{ .path = "src/a.service.ts", .content =
        \\export const escapeText = (text: string): string =>
        \\  text
        \\    .replaceAll("&", "&amp;")
        \\    .replaceAll("<", "&lt;");
        \\
        },
        .{ .path = "src/b.service.ts", .content =
        \\export const escapeText = (text: string): string =>
        \\  text
        \\    .replaceAll("&", "&amp;")
        \\    .replaceAll("<", "&lt;");
        \\
        },
    }, &.{ first, second });
}

test "the body gate is the detector's own, and a body at it is a site" {
    const allocator = std.testing.allocator;
    // `atLimit`'s body collapses to exactly thirty characters and `underLimit`'s to twenty
    // five, so a gate moved in either direction reports the wrong pair: a gate at twenty
    // five adds two rows, one at thirty one drops two
    // `underLimit` is written with two spaces between its tokens on purpose
    // the gate is on
    // the COLLAPSED text, and a raw text the collapse brings under it is the only shape
    // that reaches that gate without the byte-length pre-test dropping it first
    const at_limit = try duplicateBodyRow(allocator, "src/a.service.ts", 1, "atLimit");
    defer allocator.free(at_limit);
    const also_at_limit = try duplicateBodyRow(allocator, "src/b.service.ts", 1, "atLimit");
    defer allocator.free(also_at_limit);

    try probe.expectProject(.resilience, &.{
        .{ .path = "src/a.service.ts", .content =
        \\export const atLimit = (value: number): number => value * value + value * 100000;
        \\export const underLimit = (value: number): number => value  *  value  +  value  *  2;
        \\
        },
        .{ .path = "src/b.service.ts", .content =
        \\export const atLimit = (value: number): number => value * value + value * 100000;
        \\export const underLimit = (value: number): number => value  *  value  +  value  *  2;
        \\
        },
    }, &.{ at_limit, also_at_limit });
}

test "a destructuring declarator whose value is a function is not a body" {
    // the detector reads a declaration's name with `ts.isIdentifier`, so a pattern's
    // declarator has no name and no site
    // its own body is long enough to be one, which is
    // what makes this a test of the identifier test rather than of the length gate
    try probe.expectProject(.resilience, &.{
        .{ .path = "src/a.service.ts", .content =
        \\const { handler } = (value: number): number => {
        \\  return value * 2 + value * 3 + value * 4;
        \\};
        \\
        },
        .{ .path = "src/b.service.ts", .content =
        \\const { handler } = (value: number): number => {
        \\  return value * 2 + value * 3 + value * 4;
        \\};
        \\
        },
    }, &.{});
}
