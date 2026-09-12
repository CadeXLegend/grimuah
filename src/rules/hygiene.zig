const std = @import("std");
const root = @import("../rules.zig");
const ir = @import("../ir.zig");
const scope = @import("../scope.zig");
const ts = @import("../lang/ts.zig");

/// the curated native equivalent of biome's `recommended` built-in ruleset
///
/// the subset is the five rules that catch a defect a compiler will not: an
/// import nothing reads, a declaration nothing reads, a `let` that never
/// changes, a condition that ignores its own test, and a statement that cannot
/// run. biome's remaining recommended rules are deliberately not reimplemented,
/// and `--biome` hands the whole built-in pass back to biome for a project that
/// wants them
///
/// every rule here reads the tree, and three of them read the shared scope pass
/// (`src/scope.zig`). they are all warnings except the two flow rules, which
/// biome makes errors, so the exit code a project sees is the one biome gave it

/// a component or an import referenced only inside JSX looks unreferenced: the
/// lexer folds a whole element into a skipped region, so `<Panel />` leaves no
/// token behind. an unused-declaration rule that cannot see those references
/// would report a live import, which is the one failure a lint gate must not
/// have, so the two rules stay quiet on a JSX file and their coverage there is
/// biome's job
fn isJsxFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".tsx") or std.mem.endsWith(u8, path, ".jsx");
}

/// `_ignored` is the project saying it knows
fn isIntentionallyUnused(name: []const u8) bool {
    return name.len > 0 and name[0] == '_';
}

pub fn checkUnusedImports(context: *const root.Context) !void {
    if (isJsxFile(context.path)) return;
    const table = context.scopes orelse return;

    for (table.bindings, 0..) |binding, i| {
        if (binding.kind != .import_binding) continue;
        if (table.referenced[i]) continue;
        if (isIntentionallyUnused(binding.name)) continue;
        try context.report(binding.line, .hygiene, root.unused_import, .warn);
    }
}

pub fn checkUnusedVariables(context: *const root.Context) !void {
    if (isJsxFile(context.path)) return;
    const table = context.scopes orelse return;

    for (table.bindings, 0..) |binding, i| {
        switch (binding.kind) {
            .parameter, .import_binding => continue,
            else => {},
        }
        if (table.referenced[i]) continue;
        if (binding.exported) continue;
        if (binding.rest_sibling) continue;
        if (isIntentionallyUnused(binding.name)) continue;

        const message = switch (binding.kind) {
            .function => try std.fmt.allocPrint(context.allocator, root.unused_function, .{binding.name}),
            .class => try std.fmt.allocPrint(context.allocator, root.unused_class, .{binding.name}),
            else => try std.fmt.allocPrint(context.allocator, root.unused_variable, .{binding.name}),
        };
        defer context.allocator.free(message);
        try context.report(binding.line, .hygiene, message, .warn);
    }
}

/// a `let` whose binding is written once and never again is a `const`. the two
/// shapes differ: an initialised binding that is never written again qualifies
/// wherever a later write would sit, and an uninitialised one qualifies only
/// when its single write is a statement of the same block, because a write
/// inside a branch or a nested function is not an initialiser
pub fn checkUseConst(context: *const root.Context) !void {
    const table = context.scopes orelse return;
    const module = context.module orelse return;

    var reported: std.AutoHashMapUnmanaged(ir.NodeIndex, void) = .empty;
    defer reported.deinit(context.allocator);

    for (table.bindings, 0..) |binding, i| {
        if (binding.kind != .variable) continue;
        if (binding.decl_kind != .@"let") continue;
        if (binding.declaration == ir.none) continue;
        if (binding.exported) continue;

        const counts = table.assignment_counts[i];
        const assigned_once = if (binding.initialised)
            counts.anywhere == 0
        else
            counts.anywhere == 1 and counts.in_declaration_block == 1;
        if (!assigned_once) continue;

        const seen = try reported.getOrPut(context.allocator, binding.declaration);
        if (seen.found_existing) continue;
        try context.report(module.spanOf(binding.declaration).line, .hygiene, root.use_const, .warn);
    }
}

pub fn checkConstantCondition(context: *const root.Context) !void {
    const module = context.module orelse return;
    const dirty = try dirtyRegions(context.allocator, module, context.walk);
    defer if (dirty) |regions| context.allocator.free(regions);

    for (context.walk) |entry| {
        const index = entry.index;
        if (isDirty(dirty, index)) continue;
        const condition = conditionOf(module, context.tokens, index) orelse continue;
        if (!isConstant(module, condition)) continue;
        // `while (true)` is how a program writes a loop it intends to leave by
        // `break`, so biome leaves it alone. every other constant test is a bug
        if (module.kindOf(index) == .while_stmt and isLiteralTrue(module, context.tokens, index, condition)) continue;
        try context.report(module.spanOf(condition).line, .hygiene, root.constant_condition, .err);
    }
}

pub fn checkUnreachable(context: *const root.Context) !void {
    const module = context.module orelse return;
    const dirty = try dirtyRegions(context.allocator, module, context.walk);
    defer if (dirty) |regions| context.allocator.free(regions);

    for (context.walk) |entry| {
        const index = entry.index;
        if (entry.kind != .block) continue;
        if (isDirty(dirty, index)) continue;

        var terminated = false;
        var child = module.firstChildOf(index);
        while (child) |current| : (child = module.nextSiblingOf(current)) {
            if (terminated) {
                try context.report(module.spanOf(current).line, .hygiene, root.unreachable_code, .err);
                break;
            }
            switch (module.kindOf(current)) {
                .return_stmt, .throw_stmt, .break_stmt, .continue_stmt => terminated = true,
                else => {},
            }
        }
    }
}

/// one flag per node: whether the node's subtree holds a construct the front-end
/// could not model
///
/// the structural rules refuse to report inside one. a source the parser could
/// not model is a source whose statement nesting is not known to be right, and
/// `noUnreachable` reading a mis-nested block is exactly how a real `case` clause
/// gets reported as dead code. silence is the only safe answer there
fn dirtyRegions(allocator: std.mem.Allocator, module: *const ir.Module, walk: []const ir.WalkEntry) !?[]bool {
    if (!hasUnknown(walk)) return null;

    const dirty = try allocator.alloc(bool, walk.len);
    @memset(dirty, false);

    for (walk) |entry| {
        if (entry.kind != .unknown) continue;
        var current: ?ir.NodeIndex = entry.index;
        while (current) |node| {
            if (dirty[node]) break;
            dirty[node] = true;
            current = module.parentOf(node);
        }
    }
    return dirty;
}

fn hasUnknown(walk: []const ir.WalkEntry) bool {
    for (walk) |entry| {
        if (entry.kind == .unknown) return true;
    }
    return false;
}

fn isDirty(dirty: ?[]const bool, index: ir.NodeIndex) bool {
    const regions = dirty orelse return false;
    return regions[index];
}

/// the expression a construct tests: an `if`, a `while` or `do..while`, a
/// ternary, or the middle clause of a C-style `for`. null for everything else
fn conditionOf(module: *const ir.Module, tokens: []const ts.Token, index: ir.NodeIndex) ?ir.NodeIndex {
    switch (module.kindOf(index)) {
        .if_stmt, .conditional => return module.firstChildOf(index),
        .while_stmt => {
            // a `do..while` puts its body first and its test last
            const first = module.firstChildOf(index) orelse return null;
            if (startsAtWord(module, tokens, index, "do")) return module.lastChildOf(index);
            return first;
        },
        .for_stmt => {
            if (!std.mem.eql(u8, module.nodeOf(index).operator, ";")) return null;
            return forCondition(module, tokens, index);
        },
        else => return null,
    }
}

/// the child of a C-style `for` that lies between its two top-level `;`. the
/// header has no fixed child order, because an empty initialiser is no node at
/// all
fn forCondition(module: *const ir.Module, tokens: []const ts.Token, index: ir.NodeIndex) ?ir.NodeIndex {
    const span = module.spanOf(index);
    var i = scope.tokenIndexAt(tokens, span.start) orelse return null;

    // reach the header's first `;` at paren depth 1, counted from the `for (`
    var depth: usize = 0;
    var first_semicolon: ?usize = null;
    while (i < tokens.len and tokens[i].start < span.end) : (i += 1) {
        const token = tokens[i];
        if (token.kind != .punct) continue;
        if (token.isPunct("(")) depth += 1;
        if (token.isPunct(")")) {
            if (depth == 0) return null;
            depth -= 1;
        }
        if (depth == 1 and token.isPunct(";")) {
            first_semicolon = i;
            break;
        }
    }
    const start_of_condition = first_semicolon orelse return null;
    if (start_of_condition + 1 >= tokens.len) return null;
    const condition_token = tokens[start_of_condition + 1];
    if (condition_token.isPunct(";")) return null;

    var child = module.firstChildOf(index);
    while (child) |current| : (child = module.nextSiblingOf(current)) {
        if (module.spanOf(current).start == condition_token.start) return current;
    }
    return null;
}

/// a value the compiler can evaluate before the program runs
fn isConstant(module: *const ir.Module, index: ir.NodeIndex) bool {
    switch (module.kindOf(index)) {
        .literal, .array_literal, .object_literal => return true,
        .template => return module.firstChildOf(index) == null,
        .paren => return module.firstChildOf(index) != null and isConstant(module, module.firstChildOf(index).?),
        .unary => {
            if (!isFoldingUnary(module.nodeOf(index).operator)) return false;
            const operand = module.firstChildOf(index) orelse return false;
            return isConstant(module, operand);
        },
        .binary => {
            const left = module.firstChildOf(index) orelse return false;
            const right = module.nextSiblingOf(left) orelse return false;
            return isConstant(module, left) and isConstant(module, right);
        },
        else => return false,
    }
}

/// the unary operators that keep a literal a literal. `typeof`, `void`, `new`
/// and `await` either produce a new value or are not constant at all
fn isFoldingUnary(operator: []const u8) bool {
    const folds = [_][]const u8{ "!", "-", "+", "~" };
    for (folds) |folding| {
        if (std.mem.eql(u8, operator, folding)) return true;
    }
    return false;
}

fn isLiteralTrue(module: *const ir.Module, tokens: []const ts.Token, index: ir.NodeIndex, condition: ir.NodeIndex) bool {
    if (module.kindOf(condition) != .literal) return false;
    if (!std.mem.eql(u8, module.nodeOf(condition).operator, "true")) return false;
    // a `do..while (true)` is a loop with a body before its test, which biome
    // reports, so the exemption is the `while` form only
    return startsAtWord(module, tokens, index, "while");
}

fn startsAtWord(module: *const ir.Module, tokens: []const ts.Token, index: ir.NodeIndex, word: []const u8) bool {
    const token_index = scope.tokenIndexAt(tokens, module.spanOf(index).start) orelse return false;
    return tokens[token_index].isWord(word);
}

const testing = std.testing;
const engine = @import("../engine.zig");
const config = @import("../config.zig");

/// the findings the hygiene layer reports for `source`, as `line: message`
fn findingsFor(allocator: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    const cfg = config.Config{
        .surfaces = &.{},
        .layers = .{ .cosmetic = false, .structural = false, .resilience = false, .behavioural = false },
    };

    var findings: std.ArrayList(engine.Finding) = .empty;
    defer {
        for (findings.items) |finding| {
            allocator.free(finding.path);
            allocator.free(finding.message);
        }
        findings.deinit(allocator);
    }
    try engine.lintContent(allocator, allocator, &cfg, &findings, "probe.ts", source, true, .owned);

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    for (findings.items) |finding| {
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "{d}: {s}", .{ finding.line, finding.message }));
    }
    return lines.toOwnedSlice(allocator);
}

fn expectFindings(source: []const u8, expected: []const []const u8) !void {
    const a = testing.allocator;
    const actual = try findingsFor(a, source);
    defer {
        for (actual) |line| a.free(line);
        a.free(actual);
    }

    for (expected, 0..) |want, index| {
        if (index >= actual.len) {
            std.debug.print("missing finding: {s}\n", .{want});
            return error.TestUnexpectedResult;
        }
        if (!std.mem.eql(u8, want, actual[index])) {
            std.debug.print("finding {d}: want '{s}', got '{s}'\n", .{ index, want, actual[index] });
            return error.TestUnexpectedResult;
        }
    }
    if (actual.len != expected.len) {
        for (actual[expected.len..]) |extra| std.debug.print("unexpected finding: {s}\n", .{extra});
        return error.TestUnexpectedResult;
    }
}

test "the five hygiene rules report what they should" {
    const source =
        \\import { unusedImport } from "./mod";
        \\import { usedImport, type UsedType } from "./other";
        \\const unusedVariable = 1;
        \\class UnusedClass {}
        \\let neverWritten = 1;
        \\let written = 1;
        \\written = 2;
        \\const typed: UsedType = { usedImport };
        \\void typed;
        \\void neverWritten;
        \\if (true) { void written; }
        \\export const flow = (): void => {
        \\  return;
        \\  void 0;
        \\};
        \\
    ;
    try expectFindings(source, &.{
        "1: This import is unused.",
        "3: This variable unusedVariable is unused.",
        "4: This class UnusedClass is unused.",
        "5: This let declares a variable that is only assigned once.",
        "11: This condition always evaluates to the same value.",
        "14: This code will never be reached.",
    });
}

test "a binding read only inside its own definition is not reported" {
    // biome reports both of these, and typescript-eslint's no-unused-vars agrees
    // with biome. grimuah stays quiet: telling a reference inside the definition
    // from one outside it needs real scope resolution rather than a file-level
    // name match, and a missed finding is the failure mode this layer may have,
    // while a wrong one is not
    const source =
        \\function recursive(): void { recursive(); }
        \\const selfArrow = (): void => { selfArrow(); };
        \\
    ;
    try expectFindings(source, &.{});
}
