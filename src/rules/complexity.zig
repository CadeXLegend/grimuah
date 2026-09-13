const std = @import("std");
const root = @import("../rules.zig");
const ir = @import("../ir.zig");
const tokens_mod = @import("tokens.zig");

const Token = tokens_mod.Token;

/// the complexity rules: how much a reader has to hold while reading one body,
/// and how many paths a test has to cover

/// the deepest a statement container may nest inside one function, method or
/// class body
const nesting_limit = 3;

/// a statement container deeper than `nesting_limit` layers inside one function,
/// method or class body
///
/// what does not count as a layer, and why: the innate brace of a function,
/// method, class or arrow body, so a nested function starts its own count at
/// zero. the block body of a control statement, because `if (x) { ... }` is one
/// layer and not two. the case bodies of a switch, because the cases are
/// alternatives at one layer rather than a descent. an `else if` continuation,
/// because a ladder is flat
///
/// what counts: a block that stands on its own, and a control statement that
/// owns a body. braces are not required, because a braceless `if` nests the
/// reader exactly as a braced one does
///
/// object literals are deliberately out of scope. `{ }` also means data, and a
/// data table nested four deep costs a reader a scroll rather than a condition
pub fn checkMaxNestingDepth(context: *const root.Context) !void {
    const module = context.module orelse return;
    var nesting = Nesting{ .module = module, .context = context };
    try nesting.visit(module.root, 0, false, false);
}

const Nesting = struct {
    module: *const ir.Module,
    context: *const root.Context,

    /// `visit` and `visitBranches` are mutually recursive, and Zig cannot infer
    /// an error set across the cycle
    const Error = error{OutOfMemory};

    /// `depth` is the layer count at `index`. `owns_block` says the node is the
    /// brace of the container around it, so a block directly inside it is that
    /// container's own body. `chain_tail` says the node is an `else if` that
    /// continues a chain already counted
    fn visit(self: *Nesting, index: ir.NodeIndex, depth: usize, owns_block: bool, chain_tail: bool) Error!void {
        const kind = self.module.kindOf(index);

        if (isInnateBody(kind)) {
            var child = self.module.firstChildOf(index);
            while (child) |current| : (child = self.module.nextSiblingOf(current)) {
                try self.visit(current, 0, true, false);
            }
            return;
        }

        const is_own_body = kind == .block and owns_block;
        const is_layer = !is_own_body and (kind == .block or isContainer(kind));
        const layer_depth = if (is_layer and !chain_tail) depth + 1 else depth;
        if (is_layer and !chain_tail and layer_depth > nesting_limit) {
            const message = try std.fmt.allocPrint(self.context.allocator, root.max_nesting_depth, .{layer_depth});
            defer self.context.allocator.free(message);
            try self.context.report(self.module.spanOf(index).line, .resilience, message, .warn);
        }

        if (kind == .if_stmt) {
            try self.visitBranches(index, layer_depth);
            return;
        }

        const child_owns_block = ownsBody(kind);
        var child = self.module.firstChildOf(index);
        while (child) |current| : (child = self.module.nextSiblingOf(current)) {
            try self.visit(current, layer_depth, child_owns_block, false);
        }
    }

    /// an `if` holds its condition first, then the branch it runs and then the
    /// branch it skips. the condition is not a container, and an `else if`
    /// continues the same chain at the same layer, so only the head of a chain
    /// is a layer of its own
    fn visitBranches(self: *Nesting, index: ir.NodeIndex, layer_depth: usize) Error!void {
        var branches: [2]ir.NodeIndex = .{ ir.none, ir.none };
        var branch_count: usize = 0;

        var child = self.module.firstChildOf(index);
        while (child) |current| : (child = self.module.nextSiblingOf(current)) {
            if (branch_count == 0 and !self.module.kindOf(current).isStatement()) {
                try self.visit(current, layer_depth, false, false);
                continue;
            }
            if (branch_count == 2) break;
            branches[branch_count] = current;
            branch_count += 1;
        }

        if (branch_count > 0) try self.visit(branches[0], layer_depth, true, false);
        if (branch_count > 1) {
            const continues_chain = self.module.kindOf(branches[1]) == .if_stmt;
            try self.visit(branches[1], layer_depth, !continues_chain, continues_chain);
        }
    }
};

/// a body whose brace is part of the declaration rather than a layer of nesting.
/// a nested function body starts its own count at zero, which is what makes the
/// rule measure one body at a time
fn isInnateBody(kind: ir.Kind) bool {
    return switch (kind) {
        .function_decl, .function_expr, .arrow, .class_decl => true,
        else => false,
    };
}

/// a statement that owns a body, so descending into it costs a layer
fn isContainer(kind: ir.Kind) bool {
    return switch (kind) {
        .if_stmt, .for_stmt, .while_stmt, .switch_stmt, .try_stmt => true,
        else => false,
    };
}

/// a node whose brace belongs to it, so a block directly inside it is that
/// node's own body and not a layer. a `catch` and a `case` own theirs too
fn ownsBody(kind: ir.Kind) bool {
    if (isContainer(kind)) return true;
    return switch (kind) {
        .catch_clause, .case_clause => true,
        else => false,
    };
}

/// the most independent paths a reader may be asked to hold at once
const cyclomatic_limit = 15;

/// a callable whose body holds more than `cyclomatic_limit` paths
///
/// only a body that is a block is measured, which leaves an expression-bodied
/// arrow out: the detector reads a function type's paths, and a one-line arrow
/// is a value rather than a run of decisions. a nested function's branches count
/// into the one that declares it, which is what makes the number a measure of
/// the body rather than of the file
pub fn checkMaxCyclomaticComplexity(context: *const root.Context) !void {
    const module = context.module orelse return;
    for (context.walk) |entry| {
        if (!entry.kind.isCallable()) continue;
        const body = module.bodyOf(entry.index) orelse continue;
        if (module.kindOf(body) != .block) continue;

        const complexity = 1 + pathsIn(module, body);
        if (complexity <= cyclomatic_limit) continue;

        const message = try std.fmt.allocPrint(context.allocator, root.max_cyclomatic_complexity, .{complexity});
        defer context.allocator.free(message);
        try context.report(module.spanOf(entry.index).line, .resilience, message, .warn);
    }
}

/// the decisions in a subtree: each branch or short circuit is one more path
fn pathsIn(module: *const ir.Module, index: ir.NodeIndex) usize {
    var paths: usize = 0;
    if (isBranch(module, index)) paths += 1;
    if (module.kindOf(index) == .binary and isShortCircuit(module.nodeOf(index).operator)) paths += 1;

    var child = module.firstChildOf(index);
    while (child) |current| : (child = module.nextSiblingOf(current)) {
        paths += pathsIn(module, current);
    }
    return paths;
}

/// whether a node is one of the decisions a reader counts
fn isBranch(module: *const ir.Module, index: ir.NodeIndex) bool {
    return switch (module.kindOf(index)) {
        .if_stmt, .conditional, .catch_clause, .for_stmt, .while_stmt => true,
        // `default` is not a decision, and the front-end models `case` and
        // `default` as one kind: a clause that carries a case value is a `case`
        .case_clause => if (module.firstChildOf(index)) |first| !module.kindOf(first).isStatement() else false,
        else => false,
    };
}

/// `a && b`, `a || b` and `a ?? b` are each two paths through one expression
fn isShortCircuit(operator: []const u8) bool {
    return std.mem.eql(u8, operator, "&&") or
        std.mem.eql(u8, operator, "||") or
        std.mem.eql(u8, operator, "??");
}

/// the most lines a module may hold before it has almost certainly grown a
/// second responsibility
const file_line_limit = 500;

/// a file longer than `file_line_limit` lines
///
/// the count is the source's own newlines plus one, which is the line the end of
/// the file sits on, and a declaration file is out: `.d.ts` is generated and its
/// length is not a reader's cost
pub fn checkMaxFileLines(context: *const root.Context) !void {
    if (std.mem.endsWith(u8, context.path, ".d.ts")) return;

    var lines: usize = 1;
    for (context.source) |byte| {
        if (byte == '\n') lines += 1;
    }
    if (lines <= file_line_limit) return;

    const message = try std.fmt.allocPrint(context.allocator, root.max_file_lines, .{lines});
    defer context.allocator.free(message);
    try context.report(1, .resilience, message, .warn);
}

/// a conditional expression whose enclosing expression is another one
///
/// the walk up steps over parentheses, so `(a ? b : c) ? d : e` counts as
/// nested: the wrapping does not make the inner decision any easier to read
/// the inner conditional is the one reported, so a ladder of three reports
/// twice rather than once per pair
pub fn checkNestedTernary(context: *const root.Context) !void {
    const module = context.module orelse return;
    for (context.walk) |entry| {
        if (entry.kind != .conditional) continue;
        if (!isInsideConditional(module, entry.index)) continue;
        try context.report(module.spanOf(entry.index).line, .resilience, root.nested_ternary, .warn);
    }
}

/// whether the nearest enclosing expression of a conditional, ignoring
/// parentheses, is another conditional
fn isInsideConditional(module: *const ir.Module, index: ir.NodeIndex) bool {
    var parent = module.parentOf(index) orelse return false;
    while (module.kindOf(parent) == .paren) {
        parent = module.parentOf(parent) orelse return false;
    }
    return module.kindOf(parent) == .conditional;
}

/// the most lines a function body may run to before its length is the only thing
/// telling a reader how many jobs it does
const function_line_limit = 80;

/// a callable whose body runs past `function_line_limit` lines
///
/// the extent is the body's own, first line to last, so a signature spread over
/// several lines does not count against the function and a one-line arrow is
/// never long however much text sits on its line. the last line comes from the
/// token the body ends at rather than from a scan of the source, because a
/// token already carries its line
pub fn checkMaxFunctionLines(context: *const root.Context) !void {
    const module = context.module orelse return;
    for (context.walk) |entry| {
        if (!entry.kind.isCallable()) continue;
        const body = module.bodyOf(entry.index) orelse continue;
        const last = lastTokenOf(module, context.tokens, body) orelse continue;
        const lines = context.tokens[last].line - module.spanOf(body).line;
        if (lines <= function_line_limit) continue;

        const message = try std.fmt.allocPrint(context.allocator, root.max_function_lines, .{lines});
        defer context.allocator.free(message);
        try context.report(module.spanOf(entry.index).line, .resilience, message, .warn);
    }
}

/// the most parameters a callable may take before every call site becomes a
/// puzzle of positional slots
const parameter_limit = 4;

/// a callable that declares more than `parameter_limit` parameters
///
/// only a callable with a body counts, which is what leaves an overload
/// signature and every function type out: `(a, b, c, d, e) => void` in a type
/// position describes what a caller must pass and takes nothing itself
///
/// the count comes from the token stream rather than the tree, because the tree
/// binds one identifier per name and a destructured parameter binds several:
/// `({ a, b })` is one parameter to a reader and two bindings to the parser. the
/// slots are the top-level commas in the parameter list, so a default value
/// holding its own brackets, a rest parameter and a trailing comma all count the
/// way the signature reads
pub fn checkMaxParameters(context: *const root.Context) !void {
    const module = context.module orelse return;
    for (context.walk) |entry| {
        if (!entry.kind.isCallable()) continue;
        if (module.bodyOf(entry.index) == null) continue;
        const slots = parameterCount(module, context, entry.index) orelse continue;
        if (slots <= parameter_limit) continue;

        const message = try std.fmt.allocPrint(context.allocator, root.max_parameters, .{slots});
        defer context.allocator.free(message);
        try context.report(module.spanOf(entry.index).line, .resilience, message, .warn);
    }
}

/// the parameter slots a callable declares, or null when it declares no list
/// only modifiers, the name and a type-parameter list can precede the `(`, so
/// the scan stops at the first one it meets
fn parameterCount(module: *const ir.Module, context: *const root.Context, index: ir.NodeIndex) ?usize {
    const stream = context.tokens;
    var i = firstTokenOf(module, stream, index) orelse return null;

    while (i < stream.len) : (i += 1) {
        const token = stream[i];
        if (token.kind != .punct) continue;
        if (std.mem.eql(u8, token.text, "(")) return countSlots(stream, i);
        // `x => body` declares one parameter and has no list to scan, and a `{`
        // or `;` before any `(` means the node carries no parameter list
        if (std.mem.eql(u8, token.text, "=>")) return 1;
        if (std.mem.eql(u8, token.text, "{") or std.mem.eql(u8, token.text, ";")) return null;
    }
    return null;
}

/// the token a node ends at. a span ends at a token and the stream is in source
/// order, so a binary search finds it
fn lastTokenOf(module: *const ir.Module, stream: []const Token, index: ir.NodeIndex) ?usize {
    const end = module.spanOf(index).end;
    var low: usize = 0;
    var high: usize = stream.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (stream[middle].end < end) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low < stream.len and stream[low].end == end) return low;
    return null;
}

/// the token a node starts at. a span begins at a token and the stream is in
/// source order, so a binary search finds it
fn firstTokenOf(module: *const ir.Module, stream: []const Token, index: ir.NodeIndex) ?usize {
    const start = module.spanOf(index).start;
    var low: usize = 0;
    var high: usize = stream.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (stream[middle].start < start) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low < stream.len and stream[low].start == start) return low;
    return null;
}

/// the parameter slots between `open` and its matching `)`: the commas at the
/// list's own depth plus one, less a trailing comma. `({ a, b })` is one slot
/// although it binds two names, and `(a: Map<string, number>)` is one slot in
/// spite of the comma inside its type
///
/// a comparison in a default value reads as an opening angle bracket and would
/// undercount the slots after it, which is the one shape this cannot see
fn countSlots(stream: []const Token, open: usize) usize {
    const close = tokens_mod.matchingBracket(stream, open) orelse return 0;
    if (close == open + 1) return 0;

    var depth: usize = 0;
    var separators: usize = 0;
    var trailing_comma = false;
    var i = open + 1;
    while (i < close) : (i += 1) {
        const token = stream[i];
        if (token.kind != .punct) {
            trailing_comma = false;
            continue;
        }
        switch (token.text[0]) {
            '(', '[', '{', '<' => {
                depth += 1;
                trailing_comma = false;
            },
            ')', ']', '}', '>' => {
                if (depth > 0) depth -= 1;
                trailing_comma = false;
            },
            ',' => {
                if (depth == 0) {
                    separators += 1;
                    trailing_comma = true;
                } else {
                    trailing_comma = false;
                }
            },
            else => trailing_comma = false,
        }
    }
    return if (trailing_comma) separators else separators + 1;
}

const probe = @import("probe.zig");

test "a callable past four parameters is reported with its count" {
    const source =
        \\export function five(a: string, b: string, c: string, d: string, e: string): string {
        \\  return a + b + c + d + e;
        \\}
        \\
        \\export const six = (a: string, b: string, c: string, d: string, e: string, f: string): string =>
        \\  a + b + c + d + e + f;
        \\
        \\export function four(a: string, b: string, c: string, d: string): string {
        \\  return a + b + c + d;
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "1: This function takes 5 parameters. Group them into a named readonly type, or split the function.",
        "5: This function takes 6 parameters. Group them into a named readonly type, or split the function.",
    });
}

test "a function type, a signature and a destructured parameter are not extra slots" {
    const source =
        \\export type Wide = (a: string, b: string, c: string, d: string, e: string) => string;
        \\
        \\export interface Slim {
        \\  handle(a: string, b: string, c: string, d: string, e: string): string;
        \\}
        \\
        \\export function patterns(
        \\  { left, right }: Record<string, string>,
        \\  { up, down }: Record<string, string>,
        \\  { near, far }: Record<string, string>,
        \\  sizes: readonly number[] = [1, 2, 3],
        \\): string {
        \\  return `${left}${right}${up}${down}${near}${far}${sizes.length}`;
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{});
}

test "a method counts, and the brackets inside a default value do not" {
    const source =
        \\export class Handlers {
        \\  handle(a: string, b: string, c: string, d: string, e: string): string {
        \\    return a + b + c + d + e;
        \\  }
        \\}
        \\
        \\export function defaults(
        \\  first: string = "a",
        \\  second: readonly number[] = [1, 2, 3],
        \\  third: Record<string, number> = { a: 1, b: 2 },
        \\  fourth: string = "d",
        \\  fifth: string = "e",
        \\  sixth: string = "f",
        \\): string {
        \\  return `${first}${second.length}${third.a}${fourth}${fifth}${sixth}`;
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "2: This function takes 5 parameters. Group them into a named readonly type, or split the function.",
        "7: This function takes 6 parameters. Group them into a named readonly type, or split the function.",
    });
}

test "the complexity limit is the fifteenth decision" {
    const allocator = std.testing.allocator;

    const at_limit = try sourceWithBranches(allocator, 14);
    defer allocator.free(at_limit);
    try probe.expect(.resilience, "probe.ts", at_limit, &.{});

    const past_limit = try sourceWithBranches(allocator, 15);
    defer allocator.free(past_limit);
    try probe.expect(.resilience, "probe.ts", past_limit, &.{
        "1: This function has a cyclomatic complexity of 16. Extract each decision into a named predicate or a lookup.",
    });
}

test "a nested function's branches count into the one that declares it" {
    const allocator = std.testing.allocator;
    const source = try sourceWithNestedBranches(allocator, 14);
    defer allocator.free(source);

    // 1 + 14 + 1: an arrow's branches belong to the body that holds it, and the
    // arrow alone would be two paths, so the two readings are 16 and 15
    try probe.expect(.resilience, "probe.ts", source, &.{
        "1: This function has a cyclomatic complexity of 16. Extract each decision into a named predicate or a lookup.",
    });
}

test "a default clause is not a decision and a switch clause is" {
    const source =
        \\export function chooser(seed: number): number {
        \\  switch (seed) {
        \\    case 1:
        \\      return 1;
        \\    default:
        \\      return 0;
        \\  }
        \\}
        \\
    ;
    // the switch itself trips the shipped dispatch-table ban, which runs in the
    // same layer, and that row is the only one this fixture should produce
    try probe.expect(.resilience, "probe.ts", source, &.{
        "2: do not use switch; use a dispatch table (Record/Map) instead",
    });
}

/// a function whose body is `branch_count` `if` statements, so its complexity is
/// `branch_count + 1`
fn sourceWithBranches(allocator: std.mem.Allocator, branch_count: usize) ![]const u8 {
    return sourceWithBranchBody(allocator, branch_count, "");
}

/// the same function with one nested arrow holding a branch of its own, so a
/// nested function's branches tell the two readings apart
fn sourceWithNestedBranches(allocator: std.mem.Allocator, branch_count: usize) ![]const u8 {
    const nested =
        \\  const pick = (other: boolean): number => {
        \\    if (other) { return 1; }
        \\    return 0;
        \\  };
        \\  void pick;
        \\
    ;
    return sourceWithBranchBody(allocator, branch_count, nested);
}

fn sourceWithBranchBody(allocator: std.mem.Allocator, branch_count: usize, tail: []const u8) ![]const u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "export function branchy(seed: number): number {\n");
    for (0..branch_count) |_| try source.appendSlice(allocator, "  if (seed > 1) { seed = seed + 1; }\n");
    try source.appendSlice(allocator, tail);
    try source.appendSlice(allocator, "  return seed;\n}\n");
    return source.toOwnedSlice(allocator);
}

test "a file past the line cap is reported, and a declaration file is not" {
    const allocator = std.testing.allocator;

    // the count is the newlines plus one, which is the line the end of the file
    // sits on, so 499 newlines is a 500 line file
    const at_limit = try sourceWithNewlines(allocator, 499);
    defer allocator.free(at_limit);
    try probe.expect(.resilience, "probe.ts", at_limit, &.{});

    const past_limit = try sourceWithNewlines(allocator, 500);
    defer allocator.free(past_limit);
    try probe.expect(.resilience, "probe.ts", past_limit, &.{
        "1: This file is 501 lines long. Split it along the responsibilities its sections already show.",
    });

    const declaration = try sourceWithNewlines(allocator, 500);
    defer allocator.free(declaration);
    try probe.expect(.resilience, "probe.d.ts", declaration, &.{});
}

/// `newline_count` lines, each one ending in a newline
fn sourceWithNewlines(allocator: std.mem.Allocator, newline_count: usize) ![]const u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    for (0..newline_count) |_| try source.appendSlice(allocator, "export const filler = 1;\n");
    return source.toOwnedSlice(allocator);
}

test "a conditional inside another is reported, and a parenthesised one still is" {
    const source =
        \\export const inner = flag ? (other ? "a" : "b") : "c";
        \\export const wrapped = (flag ? "a" : "b") ? "c" : "d";
        \\export const lone = select(flag ? "a" : "b");
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "1: This conditional expression contains another conditional expression. Extract the inner decision into a named helper or a lookup.",
        "2: This conditional expression contains another conditional expression. Extract the inner decision into a named helper or a lookup.",
    });
}

test "a body one line past the limit is reported, and a body at the limit is not" {
    const allocator = std.testing.allocator;

    const at_limit = try sourceWithBodyLines(allocator, 79);
    defer allocator.free(at_limit);
    try probe.expect(.resilience, "probe.ts", at_limit, &.{});

    const past_limit = try sourceWithBodyLines(allocator, 80);
    defer allocator.free(past_limit);
    try probe.expect(.resilience, "probe.ts", past_limit, &.{
        "1: This function body is 81 lines long. Extract each distinct job into a named function.",
    });
}

/// `export function long(): void {`, then `filler_count` single-line statements,
/// then the closing brace, so the body spans `filler_count + 1` lines
fn sourceWithBodyLines(allocator: std.mem.Allocator, filler_count: usize) ![]const u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "export function long(): void {\n");
    for (0..filler_count) |_| try source.appendSlice(allocator, "  void 0;\n");
    try source.appendSlice(allocator, "}\n");
    return source.toOwnedSlice(allocator);
}

test "a body four layers deep is reported once per layer past the limit" {
    const source =
        \\function deep(xs: readonly number[]): void {
        \\  for (const x of xs) {
        \\    if (x > 0) {
        \\      while (x > 1) {
        \\        if (x > 2) {
        \\          for (const y of xs) {
        \\            void y;
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "5: This block is nested 4 levels deep. Return early or extract a helper.",
        "6: This block is nested 5 levels deep. Return early or extract a helper.",
    });
}

test "three layers are the limit" {
    const source =
        \\function ok(xs: readonly number[]): void {
        \\  for (const x of xs) {
        \\    if (x > 0) {
        \\      while (x > 1) {
        \\        void x;
        \\      }
        \\    }
        \\  }
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{});
}

test "a function body starts at zero and a block that stands alone is a layer" {
    const source =
        \\const shallow = (xs: readonly number[]): void => {
        \\  {
        \\    {
        \\      {
        \\        {
        \\          void xs;
        \\        }
        \\      }
        \\    }
        \\  }
        \\};
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "5: This block is nested 4 levels deep. Return early or extract a helper.",
    });
}

test "an else if ladder and a switch body stay flat" {
    const source =
        \\function ladder(x: number): string {
        \\  if (x === 1) {
        \\    return "one";
        \\  } else if (x === 2) {
        \\    if (x > 1) {
        \\      return "two";
        \\    }
        \\    return "three";
        \\  }
        \\  return "many";
        \\}
        \\
        \\function pick(x: number): string {
        \\  switch (x) {
        \\    case 1:
        \\      if (x > 0) {
        \\        return "one";
        \\      }
        \\      return "none";
        \\    default:
        \\      return "many";
        \\  }
        \\}
        \\
    ;
    // the switch itself trips the shipped dispatch-table ban, which runs in the
    // same layer, and that row is the only one this fixture should produce: the
    // case bodies must not add nesting findings
    try probe.expect(.resilience, "probe.ts", source, &.{
        "14: do not use switch; use a dispatch table (Record/Map) instead",
    });
}

test "a nested function starts its own count" {
    const source =
        \\function outer(xs: readonly number[]): void {
        \\  for (const x of xs) {
        \\    const inner = (): void => {
        \\      for (const y of xs) {
        \\        if (y > 0) {
        \\          while (y > 1) {
        \\            if (y > 2) {
        \\              void y;
        \\            }
        \\          }
        \\        }
        \\      }
        \\    };
        \\    void inner;
        \\    void x;
        \\  }
        \\}
        \\
    ;
    try probe.expect(.resilience, "probe.ts", source, &.{
        "7: This block is nested 4 levels deep. Return early or extract a helper.",
    });
}
