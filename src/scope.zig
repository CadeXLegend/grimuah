const std = @import("std");
const ir = @import("ir.zig");
const ts = @import("lang/ts.zig");

/// the declarations a file makes, and what references them
///
/// this is the pass `noUnusedImports`, `noUnusedVariables` and `useConst`
/// share. it reads the tree for the declarations, because a declaration is a
/// syntactic position the parser already records, and the token stream for the
/// references, because the tree deliberately drops two things a reference can
/// live in: type positions and shorthand object properties. a binding used only
/// as a type, or only as `{ name }`, is used. `jsx_names` carries the third
/// place a reference hides: a JSX tag leaves no token, so a component written
/// as `<Panel />` is referenced only through the name the lexer recorded
///
/// the analysis is file-level, not scope-level: a name used anywhere in the file
/// keeps every binding of that name alive. shadowing can therefore only hide a
/// finding, never invent one, which is the direction a lint gate has to fail in

pub const BindingKind = enum {
    variable,
    function,
    class,
    import_binding,
    /// function and arrow parameters. `noUnusedVariables` leaves these alone:
    /// biome splits them into `noUnusedFunctionParameters`, which is not part of
    /// this subset
    parameter,
};

pub const Binding = struct {
    name: []const u8,
    kind: BindingKind,
    decl_kind: ir.DeclKind,
    /// the statement a finding points at, and what `useConst` dedupes on
    declaration: ir.NodeIndex,
    /// index into the file's token slice of the name being declared
    token: u32,
    line: u32,
    /// an `export` names the symbol to the whole project, so the file's own
    /// references are not the whole audience
    exported: bool,
    /// the declaration has an initialiser, which counts as its first assignment
    initialised: bool,
    /// a destructuring sibling of a rest element (`const { a, ...rest } = x`),
    /// which is the idiom for dropping fields. biome leaves those names alone,
    /// and reporting them would fail code biome passed
    rest_sibling: bool,
};

/// how often a binding is written after its declaration. `useConst` needs the
/// two apart: an initialised `let` that is never written again is a `const`
/// wherever the write sits, while an uninitialised one only is when its single
/// write is a statement of the same block
pub const AssignmentCounts = struct {
    anywhere: u32 = 0,
    in_declaration_block: u32 = 0,
};

pub const Table = struct {
    allocator: std.mem.Allocator,
    bindings: []Binding,
    /// parallel to `bindings`: some token in the file reads the name
    referenced: []bool,
    /// parallel to `bindings`: writes after the declaration, `++` and `--`
    /// included
    assignment_counts: []AssignmentCounts,

    pub fn deinit(self: *Table) void {
        self.allocator.free(self.bindings);
        self.allocator.free(self.referenced);
        self.allocator.free(self.assignment_counts);
    }
};

pub fn analyze(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    tokens: []const ts.Token,
    jsx_names: []const []const u8,
    walk: []const ir.WalkEntry,
) !Table {
    var bindings: std.ArrayList(Binding) = .empty;
    errdefer bindings.deinit(allocator);

    for (walk) |entry| {
        const index = entry.index;
        const node = module.nodeOf(index);

        if (node.binding != .none) {
            if (node.name.len == 0) continue;
            const token_index = tokenIndexAt(tokens, node.span.start) orelse continue;
            const declaration = declarationOf(module, index);
            const declaration_node = if (declaration == ir.none) index else declaration;
            try bindings.append(allocator, .{
                .name = node.name,
                .kind = switch (node.binding) {
                    .variable => .variable,
                    .parameter => .parameter,
                    .import_binding => .import_binding,
                    .none => unreachable,
                },
                .decl_kind = declarationKind(module, declaration),
                .declaration = declaration,
                .token = token_index,
                .line = node.span.line,
                .exported = isExported(module, declaration_node),
                .initialised = declarationHasInitialiser(module, tokens, declaration),
                .rest_sibling = restSibling(module, tokens, index),
            });
            continue;
        }

        if (node.kind != .function_decl and node.kind != .class_decl) continue;
        if (node.name.len == 0) continue;
        const token_index = nameTokenIn(module, tokens, index, node.name) orelse continue;
        try bindings.append(allocator, .{
            .name = node.name,
            .kind = if (node.kind == .function_decl) .function else .class,
            .decl_kind = .unknown,
            .declaration = index,
            .token = token_index,
            .line = node.span.line,
            .exported = isExported(module, index),
            .initialised = false,
            .rest_sibling = false,
        });
    }

    const referenced = try allocator.alloc(bool, bindings.items.len);
    errdefer allocator.free(referenced);
    const assignment_counts = try allocator.alloc(AssignmentCounts, bindings.items.len);
    errdefer allocator.free(assignment_counts);
    @memset(referenced, false);
    @memset(assignment_counts, .{});

    const blocks = try blocksOf(allocator, module, walk);
    defer allocator.free(blocks);

    var names: std.StringHashMapUnmanaged(NameState) = .empty;
    defer names.deinit(allocator);
    var name_filter = NameFilter{};
    for (bindings.items) |binding| {
        name_filter.add(binding.name);
        const entry = try names.getOrPut(allocator, binding.name);
        if (entry.found_existing) {
            entry.value_ptr.duplicated = true;
            continue;
        }
        entry.value_ptr.* = .{};
    }

    const declared = try allocator.alloc(bool, tokens.len);
    defer allocator.free(declared);
    @memset(declared, false);

    // a declaration token is only skippable while the name is the file's alone.
    // two bindings of one name make their declaration tokens ambiguous, and a
    // declaration the parser invented (a mis-read region) would otherwise mask
    // the real reference to the binding that carries the name
    for (bindings.items) |binding| {
        const state = names.getPtr(binding.name) orelse continue;
        if (state.duplicated) continue;
        declared[binding.token] = true;
    }

    const Written = struct { name: []const u8, block: ir.NodeIndex };
    var writes: std.ArrayList(Written) = .empty;
    defer writes.deinit(allocator);

    for (tokens, 0..) |token, i| {
        if (token.kind != .word) continue;
        if (declared[i]) continue;
        if (!name_filter.couldName(token.text)) continue;
        const state = names.getPtr(token.text) orelse continue;
        if (isMemberName(tokens, i)) continue;
        if (isPropertyKey(tokens, i)) continue;

        // an update reads the binding when its value is used: biome reports
        // `let n = 0; n++;` as unused but keeps `const id = n++` alive, because
        // there the value is what the next statement wants
        if (postfixUpdate(tokens, i)) {
            try writes.append(allocator, .{ .name = token.text, .block = blockAt(blocks, token.start) });
            if (!updateValueDropped(module, tokens, i)) state.referenced = true;
            continue;
        }

        if (prefixUpdate(tokens, i)) {
            try writes.append(allocator, .{ .name = token.text, .block = blockAt(blocks, token.start) });
            if (!updateValueDropped(module, tokens, i)) state.referenced = true;
            continue;
        }

        if (assigned(tokens, i)) {
            try writes.append(allocator, .{ .name = token.text, .block = blockAt(blocks, token.start) });
        }

        state.referenced = true;
    }

    // a JSX element name is a read and never a write, so it can only keep a
    // binding alive: `<Panel />` marks `Panel` used without touching its
    // assignment counts
    for (jsx_names) |name| {
        if (!name_filter.couldName(name)) continue;
        const state = names.getPtr(name) orelse continue;
        state.referenced = true;
    }

    for (bindings.items, 0..) |binding, i| {
        if (names.getPtr(binding.name)) |state| referenced[i] = state.referenced;

        const declaration_block = if (binding.declaration == ir.none)
            ir.none
        else
            blockAt(blocks, module.spanOf(binding.declaration).start);

        var counts: AssignmentCounts = .{};
        for (writes.items) |write| {
            if (write.name.len != binding.name.len) continue;
            if (!std.mem.eql(u8, write.name, binding.name)) continue;
            counts.anywhere += 1;
            if (write.block == declaration_block) counts.in_declaration_block += 1;
        }
        assignment_counts[i] = counts;
    }

    return .{
        .allocator = allocator,
        .bindings = try bindings.toOwnedSlice(allocator),
        .referenced = referenced,
        .assignment_counts = assignment_counts,
    };
}

const Block = struct { start: u32, end: u32, node: ir.NodeIndex };

/// what the file does with one declared name: whether some token reads it, and
/// whether more than one binding carries it. one map holds all three of the old
/// ones (`binding_names`, `counted_names`, `shared_names`, `reference_names`),
/// because the reference scan has to ask "is this word a declared name" anyway,
/// and answering it from the same entry that records the reference halves the
/// hash lookups a file's tokens pay
const NameState = struct {
    /// some token in the file reads the name
    referenced: bool = false,
    /// more than one binding in the file carries the name, so their declaration
    /// tokens are ambiguous
    duplicated: bool = false,
};

/// the lengths and first bytes the file's binding names cover
///
/// the reference scan asks the name map about every word token, and almost none
/// of them can be a declaration: the file's names are a few dozen out of every
/// identifier it writes. this answers "could this be one of them" from two loads,
/// so the hash lookup only runs for a token that still can match. a name in the
/// map always passes, because every name added to the map is added here too
const NameFilter = struct {
    first_bytes: [4]u64 = .{ 0, 0, 0, 0 },
    shortest: usize = std.math.maxInt(usize),
    longest: usize = 0,

    fn add(self: *NameFilter, name: []const u8) void {
        if (name.len == 0) return;
        const byte = name[0];
        self.first_bytes[byte >> 6] |= @as(u64, 1) << @intCast(byte & 63);
        self.shortest = @min(self.shortest, name.len);
        self.longest = @max(self.longest, name.len);
    }

    fn couldName(self: *const NameFilter, text: []const u8) bool {
        if (text.len < self.shortest or text.len > self.longest) return false;
        const byte = text[0];
        return self.first_bytes[byte >> 6] & (@as(u64, 1) << @intCast(byte & 63)) != 0;
    }
};

/// every statement block in the file, so a token can be attributed to the block
/// it is written in
fn blocksOf(allocator: std.mem.Allocator, module: *const ir.Module, walk: []const ir.WalkEntry) ![]Block {
    var blocks: std.ArrayList(Block) = .empty;
    errdefer blocks.deinit(allocator);

    for (walk) |entry| {
        if (entry.kind != .block) continue;
        const span = module.spanOf(entry.index);
        try blocks.append(allocator, .{ .start = span.start, .end = span.end, .node = entry.index });
    }
    return blocks.toOwnedSlice(allocator);
}

/// the innermost block holding `offset`, or `none` at module level
fn blockAt(blocks: []const Block, offset: u32) ir.NodeIndex {
    var innermost: ir.NodeIndex = ir.none;
    var smallest: u32 = std.math.maxInt(u32);
    for (blocks) |block| {
        if (offset < block.start or offset >= block.end) continue;
        const size = block.end - block.start;
        if (size >= smallest) continue;
        smallest = size;
        innermost = block.node;
    }
    return innermost;
}

/// `o.name` and `o?.name` are the object's property, not a reference to a
/// binding named `name`
fn isMemberName(tokens: []const ts.Token, i: usize) bool {
    if (i == 0) return false;
    const previous = tokens[i - 1];
    return previous.isPunct(".") or previous.isPunct("?.");
}

/// `{ name: value }` in an object literal, a destructuring pattern or a type is
/// a key. a ternary's middle operand and a `case` label are not: the previous
/// token tells them apart
fn isPropertyKey(tokens: []const ts.Token, i: usize) bool {
    if (i + 1 >= tokens.len or !tokens[i + 1].isPunct(":")) return false;
    if (i == 0) return false;
    const previous = tokens[i - 1];
    return previous.isPunct("{") or previous.isPunct(",");
}

/// `name++` / `name--` write without reading when their value is dropped, which
/// is why biome reports `let count = 0; count++;` as an unused variable
fn postfixUpdate(tokens: []const ts.Token, i: usize) bool {
    if (i + 1 >= tokens.len) return false;
    return tokens[i + 1].isPunct("++") or tokens[i + 1].isPunct("--");
}

/// `++name` / `--name`
fn prefixUpdate(tokens: []const ts.Token, i: usize) bool {
    if (i == 0) return false;
    return tokens[i - 1].isPunct("++") or tokens[i - 1].isPunct("--");
}

/// whether the update's result is thrown away, i.e. the whole statement is
/// `n++`. the tree is what tells a dropped value from a consumed one: an
/// identifier directly under an expression statement, or under a unary that is
fn updateValueDropped(module: *const ir.Module, tokens: []const ts.Token, i: usize) bool {
    const node = nodeStartingAt(module, tokens[i].start) orelse return false;
    const parent = module.parentOf(node) orelse return false;
    if (module.kindOf(parent) == .expression_stmt) return true;
    if (module.kindOf(parent) != .unary) return false;
    const grandparent = module.parentOf(parent) orelse return false;
    return module.kindOf(grandparent) == .expression_stmt;
}

/// the node whose span begins at `offset`. updates are rare enough that a scan
/// of the node list beats keeping an index for every file
fn nodeStartingAt(module: *const ir.Module, offset: u32) ?ir.NodeIndex {
    for (module.nodes.items, 0..) |node, index| {
        if (node.span.start == offset) return @intCast(index);
    }
    return null;
}

/// `name = value` and the compound forms. the declaration's own initialiser is
/// not counted: its name token is a declaration, so it never reaches here
fn assigned(tokens: []const ts.Token, i: usize) bool {
    if (i + 1 >= tokens.len) return false;
    const next = tokens[i + 1];
    if (next.kind != .punct) return false;
    const assignment_operators = [_][]const u8{
        "=",   "+=",  "-=",  "*=",  "/=",  "%=",   "**=",
        "<<=", ">>=", ">>>=", "&=", "|=",  "^=",   "&&=",
        "||=", "??=",
    };
    for (assignment_operators) |operator| {
        if (next.isPunct(operator)) return true;
    }
    return false;
}

/// whether a binding is one of the names a rest element spares. an array
/// pattern's other bindings are not spared: biome reports `const [a, ...rest]`
/// for `a`
fn restSibling(module: *const ir.Module, tokens: []const ts.Token, index: ir.NodeIndex) bool {
    const pattern = patternOf(module, index) orelse return false;
    if (module.kindOf(pattern) != .literal) return false;
    if (!patternHasRest(tokens, module.spanOf(pattern))) return false;

    const token_index = tokenIndexAt(tokens, module.spanOf(index).start) orelse return false;
    if (token_index > 0 and tokens[token_index - 1].isPunct("...")) return false;
    return true;
}

/// the binding pattern a name sits directly in, when it sits in one at all
fn patternOf(module: *const ir.Module, index: ir.NodeIndex) ?ir.NodeIndex {
    const parent = module.parentOf(index) orelse return null;
    return switch (module.kindOf(parent)) {
        .literal, .array_literal => parent,
        else => null,
    };
}

/// whether the pattern itself carries a `...rest`, which is what makes its other
/// names deliberate omissions. a nested pattern's rest does not spare the outer
/// names, so only depth 1 counts
fn patternHasRest(tokens: []const ts.Token, span: ir.Span) bool {
    var i = tokenIndexAt(tokens, span.start) orelse return false;
    var depth: usize = 0;
    while (i < tokens.len and tokens[i].start < span.end) : (i += 1) {
        const token = tokens[i];
        if (token.kind != .punct) continue;
        if (token.isPunct("{")) {
            depth += 1;
            continue;
        }
        if (token.isPunct("}")) {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth == 1 and token.isPunct("...")) return true;
    }
    return false;
}

/// the declaration a binding belongs to. a destructuring pattern sits between
/// the declaration and its names, and a parameter or an import has no
/// `variable_decl` above it at all
fn declarationOf(module: *const ir.Module, index: ir.NodeIndex) ir.NodeIndex {
    var current = index;
    while (module.parentOf(current)) |parent| {
        switch (module.kindOf(parent)) {
            .literal, .array_literal => current = parent,
            .variable_decl => return parent,
            else => return ir.none,
        }
    }
    return ir.none;
}

fn declarationKind(module: *const ir.Module, declaration: ir.NodeIndex) ir.DeclKind {
    if (declaration == ir.none) return .unknown;
    return module.nodeOf(declaration).decl_kind;
}

/// whether the declaration sits directly under an `export`. an inner binding of
/// an exported declaration is not itself exported, so the check is one level
fn isExported(module: *const ir.Module, declaration: ir.NodeIndex) bool {
    const parent = module.parentOf(declaration) orelse return false;
    return module.kindOf(parent) == .export_decl;
}

/// whether a top-level `=` appears inside the declaration, which is what makes
/// `let x = 1` an assigned binding and `let x;` an unassigned one
fn declarationHasInitialiser(module: *const ir.Module, tokens: []const ts.Token, declaration: ir.NodeIndex) bool {
    if (declaration == ir.none) return false;

    const span = module.spanOf(declaration);
    var i = tokenIndexAt(tokens, span.start) orelse return false;
    var depth: usize = 0;
    while (i < tokens.len and tokens[i].start < span.end) : (i += 1) {
        const token = tokens[i];
        if (token.kind != .punct) continue;
        if (token.isPunct("(") or token.isPunct("[") or token.isPunct("{")) depth += 1;
        if (token.isPunct(")") or token.isPunct("]") or token.isPunct("}")) {
            if (depth == 0) return false;
            depth -= 1;
            continue;
        }
        if (depth == 0 and token.isPunct("=")) return true;
        if (depth == 0 and token.isPunct(";")) return false;
    }
    return false;
}

/// the token a declaration's name is spelled with. `function foo` and
/// `class Bar` keep their name on the node rather than as a child, so it is
/// found by text inside the node's own span
fn nameTokenIn(module: *const ir.Module, tokens: []const ts.Token, index: ir.NodeIndex, name: []const u8) ?u32 {
    const span = module.spanOf(index);
    var i = tokenIndexAt(tokens, span.start) orelse return null;
    while (i < tokens.len and tokens[i].start < span.end) : (i += 1) {
        if (tokens[i].kind == .word and std.mem.eql(u8, tokens[i].text, name)) return i;
    }
    return null;
}

/// the token that starts at `offset`. spans begin on a token boundary, so an
/// exact match is the whole lookup
pub fn tokenIndexAt(tokens: []const ts.Token, offset: u32) ?u32 {
    var low: usize = 0;
    var high: usize = tokens.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (tokens[middle].start < offset) low = middle + 1 else high = middle;
    }
    if (low < tokens.len and tokens[low].start == offset) return @intCast(low);
    return null;
}

const testing = std.testing;

const Analyzed = struct {
    module: ir.Module,
    table: Table,

    fn deinit(self: *Analyzed) void {
        self.table.deinit();
        self.module.deinit();
    }

    /// the index of a binding by name, so a test never depends on tree order
    fn indexOf(self: *const Analyzed, name: []const u8) usize {
        for (self.table.bindings, 0..) |declared, i| {
            if (std.mem.eql(u8, declared.name, name)) return i;
        }
        std.debug.panic("no binding named {s}", .{name});
    }

    fn binding(self: *const Analyzed, name: []const u8) Binding {
        return self.table.bindings[self.indexOf(name)];
    }

    fn isReferenced(self: *const Analyzed, name: []const u8) bool {
        return self.table.referenced[self.indexOf(name)];
    }
};

fn analyzeSource(allocator: std.mem.Allocator, source: []const u8) !Analyzed {
    var module = try ts.parse(allocator, source);
    errdefer module.deinit();
    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    var line: u32 = 1;
    const lexed = try ts.tokenizeAll(allocator, source, &line);
    defer allocator.free(lexed.tokens);
    defer allocator.free(lexed.jsx_names);

    const walk = try module.walkOrder(allocator);
    defer allocator.free(walk);

    const table = try analyze(allocator, &module, lexed.tokens, lexed.jsx_names, walk);
    return .{ .module = module, .table = table };
}

test "a name used only as a type is referenced" {
    const a = testing.allocator;
    const source =
        \\import type { Beta } from "./beta";
        \\const only: Beta = {} as Beta;
        \\
    ;
    var analyzed = try analyzeSource(a, source);
    defer analyzed.deinit();

    try testing.expectEqual(BindingKind.import_binding, analyzed.binding("Beta").kind);
    try testing.expect(analyzed.isReferenced("Beta"));
}

test "an aliased import declares only the local name" {
    const a = testing.allocator;
    const source =
        \\import { remote as local, other } from "./mod";
        \\void local;
        \\void other;
        \\
    ;
    var analyzed = try analyzeSource(a, source);
    defer analyzed.deinit();

    try testing.expectEqual(@as(usize, 2), analyzed.table.bindings.len);
    try testing.expectEqualStrings("local", analyzed.table.bindings[0].name);
    try testing.expectEqualStrings("other", analyzed.table.bindings[1].name);
    try testing.expect(analyzed.isReferenced("local"));
    try testing.expect(analyzed.isReferenced("other"));
}

test "a name used only as an object shorthand is referenced" {
    const a = testing.allocator;
    const source =
        \\const size = 1;
        \\export const bag = { size };
        \\
    ;
    var analyzed = try analyzeSource(a, source);
    defer analyzed.deinit();

    try testing.expectEqual(BindingKind.variable, analyzed.binding("size").kind);
    try testing.expect(analyzed.isReferenced("size"));
}

test "a property name or a member is not a reference" {
    const a = testing.allocator;
    const source =
        \\const key = 1;
        \\export const bag = { key: 2 };
        \\export const other = bag.key;
        \\
    ;
    var analyzed = try analyzeSource(a, source);
    defer analyzed.deinit();

    try testing.expect(!analyzed.isReferenced("key"));
}

test "an export keeps a binding alive" {
    const a = testing.allocator;
    const source =
        \\export const published = 1;
        \\const local = 3;
        \\
    ;
    var analyzed = try analyzeSource(a, source);
    defer analyzed.deinit();

    try testing.expect(analyzed.binding("published").exported);
    try testing.expect(!analyzed.isReferenced("published"));
    try testing.expect(!analyzed.binding("local").exported);
}

test "a let counts its initialiser and every later assignment" {
    const a = testing.allocator;
    const source =
        \\let once = 1;
        \\let twice = 1;
        \\twice = 2;
        \\let unassigned;
        \\void once;
        \\void twice;
        \\
    ;
    var analyzed = try analyzeSource(a, source);
    defer analyzed.deinit();

    const once = analyzed.indexOf("once");
    try testing.expectEqual(ir.DeclKind.@"let", analyzed.binding("once").decl_kind);
    try testing.expect(analyzed.binding("once").initialised);
    try testing.expectEqual(@as(u32, 0), analyzed.table.assignment_counts[once].anywhere);

    try testing.expectEqual(@as(u32, 1), analyzed.table.assignment_counts[analyzed.indexOf("twice")].anywhere);
    try testing.expect(!analyzed.binding("unassigned").initialised);
    try testing.expectEqual(@as(u32, 0), analyzed.table.assignment_counts[analyzed.indexOf("unassigned")].anywhere);
}

test "a write inside a nested block is not a declaration's initialiser" {
    const a = testing.allocator;
    const source =
        \\declare const cond: boolean;
        \\let sameBlock;
        \\sameBlock = 1;
        \\let nested;
        \\if (cond) { nested = 1; }
        \\void sameBlock;
        \\void nested;
        \\
    ;
    var analyzed = try analyzeSource(a, source);
    defer analyzed.deinit();

    const same_block = analyzed.table.assignment_counts[analyzed.indexOf("sameBlock")];
    try testing.expectEqual(@as(u32, 1), same_block.anywhere);
    try testing.expectEqual(@as(u32, 1), same_block.in_declaration_block);

    const nested = analyzed.table.assignment_counts[analyzed.indexOf("nested")];
    try testing.expectEqual(@as(u32, 1), nested.anywhere);
    try testing.expectEqual(@as(u32, 0), nested.in_declaration_block);
}

test "a rest sibling is not reported as an omission" {
    const a = testing.allocator;
    const source =
        \\const { dropped, ...kept } = { dropped: 1, kept: 2 };
        \\const [stray, ...tail] = [1, 2, 3];
        \\void kept;
        \\void tail;
        \\
    ;
    var analyzed = try analyzeSource(a, source);
    defer analyzed.deinit();

    try testing.expect(!analyzed.isReferenced("dropped"));
    try testing.expect(analyzed.binding("dropped").rest_sibling);
    // the rest element itself is still reported when nothing reads it
    try testing.expect(!analyzed.binding("kept").rest_sibling);
    // an array pattern spares nobody
    try testing.expect(!analyzed.binding("stray").rest_sibling);
}

test "a postfix increment writes without reading, a prefix one also reads" {
    const a = testing.allocator;
    const source =
        \\let counter = 0;
        \\counter++;
        \\let consumed = 0;
        \\const id = consumed++;
        \\let prefix = 0;
        \\void `${++prefix}`;
        \\void id;
        \\
    ;
    var analyzed = try analyzeSource(a, source);
    defer analyzed.deinit();

    try testing.expectEqual(@as(u32, 1), analyzed.table.assignment_counts[0].anywhere);
    try testing.expect(!analyzed.isReferenced("counter"));

    // the value is what the next statement wants, so biome keeps it alive
    try testing.expect(analyzed.isReferenced("consumed"));

    try testing.expectEqual(@as(u32, 1), analyzed.table.assignment_counts[analyzed.indexOf("prefix")].anywhere);
    try testing.expect(analyzed.isReferenced("prefix"));
}

test "a function and a class declaration are bindings with their own token" {
    const a = testing.allocator;
    const source =
        \\function run(): void {}
        \\class Store {}
        \\void run;
        \\
    ;
    var analyzed = try analyzeSource(a, source);
    defer analyzed.deinit();

    try testing.expectEqual(BindingKind.function, analyzed.binding("run").kind);
    try testing.expect(analyzed.isReferenced("run"));

    try testing.expectEqual(BindingKind.class, analyzed.binding("Store").kind);
    try testing.expect(!analyzed.isReferenced("Store"));
}

test "a parameter is a binding the unused-variable rule leaves to its own rule" {
    const a = testing.allocator;
    const source =
        \\export const run = (value: number): number => value;
        \\
    ;
    var analyzed = try analyzeSource(a, source);
    defer analyzed.deinit();

    try testing.expectEqual(BindingKind.parameter, analyzed.binding("value").kind);
    try testing.expect(analyzed.isReferenced("value"));
}
