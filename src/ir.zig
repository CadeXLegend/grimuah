const std = @import("std");

/// the intermediate representation rules match over
///
/// a front-end (`src/lang/ts.zig` and later siblings) turns source into a tree
/// of nodes in a flat array. nodes carry indices rather than pointers, so the
/// array can grow while a front-end is building the tree, and rules can hold on
/// to an index for as long as they hold on to the module.
///
/// the tree is deliberately shallow in expression position: a binary chain is
/// left-nested with the operator recorded, so a rule can see every operator and
/// every operand without a precedence table. rules that need real grouping
/// (scope analysis, unreachable code) get it from statement nesting, which is
/// exact.

/// a half-open token index range, plus the 1-based line its first token is on
pub const Span = struct {
    start: u32,
    end: u32,
    line: u32,

    /// the smallest span covering both inputs
    pub fn merge(first: Span, second: Span) Span {
        return .{
            .start = @min(first.start, second.start),
            .end = @max(first.end, second.end),
            .line = first.line,
        };
    }
};

pub const NodeIndex = u32;

/// one node's place in walk order, with its kind next to it, so a rule can filter
/// a whole file by kind while reading sequentially
pub const WalkEntry = struct {
    index: NodeIndex,
    kind: Kind,
};

/// an absent index. every link in `Node` uses it instead of an optional, so the
/// links stay 4 bytes each
pub const none: NodeIndex = std.math.maxInt(NodeIndex);

/// the keyword a binding was declared with
pub const DeclKind = enum {
    @"const",
    @"let",
    @"var",
    unknown,

    pub fn fromKeyword(keyword: []const u8) DeclKind {
        if (std.mem.eql(u8, keyword, "const")) return .@"const";
        if (std.mem.eql(u8, keyword, "let")) return .@"let";
        if (std.mem.eql(u8, keyword, "var")) return .@"var";
        return .unknown;
    }
};

/// the kind of name an identifier node introduces. a rule that reports an
/// unused declaration must tell a binding the file has to use from a parameter
/// the signature already accounts for, and from a name that is only a value
pub const BindingKind = enum {
    /// not a binding: a plain reference
    none,
    /// a `const` / `let` / `var` declarator, a destructured name in one, or a
    /// catch clause's parameter
    variable,
    /// a function or arrow parameter
    parameter,
    /// a name an `import` clause introduces
    import_binding,
    /// a name a named import clause introduces: `import { a, b as c }` binds `a` and
    /// `c`. the default and namespace forms introduce a binding of their own shape,
    /// which a rule that reads the module's imports has to tell apart: only a named
    /// clause lists names, and `import Default from` and `import * as ns from` do not
    named_import_binding,
};

pub const Kind = enum {
    /// the file
    module,
    import_decl,
    export_decl,
    /// `export { a, b } from "module"` and `export * from "module"`. a proxy
    /// re-export, which is what the rule bans
    reexport,
    /// a binding declaration: `const` / `let` / `var`, one node per declarator
    variable_decl,
    function_decl,
    class_decl,
    /// a type-only declaration the front-end did not model: `interface`,
    /// `type`, `enum`, `namespace`, `declare`. its span is exact, its children
    /// are empty
    type_decl,
    block,
    if_stmt,
    for_stmt,
    while_stmt,
    switch_stmt,
    case_clause,
    try_stmt,
    catch_clause,
    return_stmt,
    throw_stmt,
    break_stmt,
    continue_stmt,
    expression_stmt,
    identifier,
    literal,
    template,
    member,
    call,
    /// `expr = expr` and the compound forms
    assignment,
    binary,
    /// `cond ? when_true : when_false`
    conditional,
    unary,
    /// `expr as type`
    as_expr,
    paren,
    object_literal,
    array_literal,
    arrow,
    function_expr,
    /// `name: value` inside an object literal, or a key in a class body
    property,
    spread,
    /// source the front-end could not model. a rule that needs structure treats
    /// it as unsupported_node, and the front-end's tests assert it never appears on the
    /// corpus
    unknown,

    /// something a caller invokes and a reader reads as a unit of behaviour: a
    /// function declaration, a function expression, a class method or an arrow
    /// the front-end appends a method to its `class_decl` as one of these, so a
    /// rule that measures callables covers methods without naming them
    pub fn isCallable(self: Kind) bool {
        return switch (self) {
            .function_decl, .function_expr, .arrow => true,
            else => false,
        };
    }

    /// whether a node is one of the statements the front-end produces in
    /// statement position
    ///
    /// it is what tells an `if`'s condition from the branch that follows it, and
    /// a loop's condition from its body
    pub fn isStatement(self: Kind) bool {
        return switch (self) {
            .block,
            .if_stmt,
            .for_stmt,
            .while_stmt,
            .switch_stmt,
            .try_stmt,
            .return_stmt,
            .throw_stmt,
            .break_stmt,
            .continue_stmt,
            .expression_stmt,
            .variable_decl,
            .function_decl,
            .class_decl,
            .type_decl,
            .import_decl,
            .export_decl,
            .case_clause,
            => true,
            else => false,
        };
    }
};

pub const Node = struct {
    kind: Kind,
    span: Span,
    parent: NodeIndex = none,
    first_child: NodeIndex = none,
    last_child: NodeIndex = none,
    next_sibling: NodeIndex = none,
    /// declaration name, binding name, property key or member name
    name: []const u8 = "",
    /// operator or keyword text for binary, assignment, unary, as and binding
    /// nodes
    operator: []const u8 = "",
    decl_kind: DeclKind = .unknown,
    /// set on the identifier nodes a front-end created as declarations
    binding: BindingKind = .none,
};

pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node),
    root: NodeIndex,
    source: []const u8,
    /// constructs the front-end skipped, so callers can report coverage instead
    /// of silently linting less
    unsupported: u32 = 0,

    pub fn init(child_allocator: std.mem.Allocator, source: []const u8) !Module {
        var module = Module{
            .arena = std.heap.ArenaAllocator.init(child_allocator),
            .nodes = .empty,
            .root = none,
            .source = source,
        };
        module.root = try module.add(.module, .{ .start = 0, .end = 0, .line = 1 });
        return module;
    }

    pub fn deinit(self: *Module) void {
        self.nodes.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }

    /// all nodes live in one list, keyed by index
    pub fn add(self: *Module, kind: Kind, span: Span) !NodeIndex {
        const index: NodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(self.arena.child_allocator, .{ .kind = kind, .span = span });
        return index;
    }

    pub fn appendChild(self: *Module, parent: NodeIndex, child: NodeIndex) void {
        const child_node = &self.nodes.items[child];
        if (child_node.parent != none) return;
        child_node.parent = parent;

        const parent_node = &self.nodes.items[parent];
        if (parent_node.last_child == none) {
            parent_node.first_child = child;
        } else {
            self.nodes.items[parent_node.last_child].next_sibling = child;
        }
        parent_node.last_child = child;
    }

    pub fn kindOf(self: *const Module, index: NodeIndex) Kind {
        return self.nodes.items[index].kind;
    }

    pub fn spanOf(self: *const Module, index: NodeIndex) Span {
        return self.nodes.items[index].span;
    }

    pub fn nodeOf(self: *const Module, index: NodeIndex) *const Node {
        return &self.nodes.items[index];
    }

    pub fn parentOf(self: *const Module, index: NodeIndex) ?NodeIndex {
        const parent = self.nodes.items[index].parent;
        return if (parent == none) null else parent;
    }

    pub fn firstChildOf(self: *const Module, index: NodeIndex) ?NodeIndex {
        const child = self.nodes.items[index].first_child;
        return if (child == none) null else child;
    }

    /// the last child, which is where the body of a statement lands
    pub fn lastChildOf(self: *const Module, index: NodeIndex) ?NodeIndex {
        const child = self.nodes.items[index].last_child;
        return if (child == none) null else child;
    }

    pub fn nextSiblingOf(self: *const Module, index: NodeIndex) ?NodeIndex {
        const sibling = self.nodes.items[index].next_sibling;
        return if (sibling == none) null else sibling;
    }

    pub fn childCount(self: *const Module, index: NodeIndex) usize {
        var total: usize = 0;
        var child = self.firstChildOf(index);
        while (child) |current| : (child = self.nextSiblingOf(current)) total += 1;
        return total;
    }

    /// the source text a node covers
    pub fn textOf(self: *const Module, index: NodeIndex) []const u8 {
        const span = self.spanOf(index);
        return self.source[span.start..span.end];
    }

    /// an ancestor of `index`, or `null` at the root
    pub fn ancestorOf(self: *const Module, index: NodeIndex, kind: Kind) ?NodeIndex {
        var current = index;
        while (self.parentOf(current)) |parent| {
            if (self.kindOf(parent) == kind) return parent;
            current = parent;
        }
        return null;
    }

    /// whether `index` sits inside a node of `kind`
    pub fn isInside(self: *const Module, index: NodeIndex, kind: Kind) bool {
        return self.ancestorOf(index, kind) != null;
    }

    /// depth-first pre-order, root first
    pub fn iterator(self: *const Module) Iterator {
        return .{ .module = self, .current = self.root };
    }

    /// the whole tree in walk order, each node with its kind copied beside it.
    /// `iterator()` follows first_child / next_sibling links through 80-byte
    /// nodes, so every visit is a dependent load; a rule that visits every node
    /// reads this array instead (measured: 20ns per node walked, 7 walks per file
    /// across the rules and the scope pass). the order is exactly `iterator()`'s
    /// and the length is exactly the node count, so a caller can index it
    pub fn walkOrder(self: *const Module, allocator: std.mem.Allocator) ![]WalkEntry {
        const entries = try allocator.alloc(WalkEntry, self.nodes.items.len);

        var count: usize = 0;
        var walker = self.iterator();
        while (walker.next()) |index| : (count += 1) {
            entries[count] = .{ .index = index, .kind = self.kindOf(index) };
        }
        std.debug.assert(count == entries.len);
        return entries;
    }

    /// the end of the last byte any node other than the root covers. a front-end
    /// that stops early leaves the tail of the file outside this, which is how a
    /// truncated parse is told apart from a clean one
    pub fn coveredEnd(self: *const Module) u32 {
        var end: u32 = 0;
        var walker = self.iterator();
        while (walker.next()) |index| {
            if (index == self.root) continue;
            end = @max(end, self.spanOf(index).end);
        }
        return end;
    }

    pub fn unknownCount(self: *const Module) usize {
        var total: usize = 0;
        var walker = self.iterator();
        while (walker.next()) |index| {
            if (self.kindOf(index) == .unknown) total += 1;
        }
        return total;
    }

    pub const Iterator = struct {
        module: *const Module,
        current: NodeIndex,

        pub fn next(self: *Iterator) ?NodeIndex {
            const current = self.current;
            if (current == none) return null;

            if (self.module.firstChildOf(current)) |child| {
                self.current = child;
                return current;
            }

            var node = current;
            while (true) {
                if (self.module.nextSiblingOf(node)) |sibling| {
                    self.current = sibling;
                    return current;
                }
                const parent = self.module.parentOf(node) orelse break;
                if (parent == self.module.root) break;
                node = parent;
            }

            self.current = none;
            return current;
        }
    };

    /// the children of one node, in order
    pub const Children = struct {
        module: *const Module,
        current: NodeIndex,

        pub fn next(self: *Children) ?NodeIndex {
            if (self.current == none) return null;
            const current = self.current;
            self.current = self.module.nodes.items[current].next_sibling;
            return current;
        }
    };

    pub fn childrenOf(self: *const Module, index: NodeIndex) Children {
        return .{ .module = self, .current = self.nodes.items[index].first_child };
    }

    /// the body a callable was declared with, or null for anything else: a node
    /// that is not callable, or a signature that declares no body
    ///
    /// the front-end appends a body last, so an arrow's is its last child
    /// whether that child is a block or an expression, while a declaration or a
    /// method that declares no body at all has no block to find
    pub fn bodyOf(self: *const Module, index: NodeIndex) ?NodeIndex {
        if (!self.kindOf(index).isCallable()) return null;
        if (self.kindOf(index) == .arrow) return self.lastChildOf(index);
        var child = self.firstChildOf(index);
        while (child) |current| : (child = self.nextSiblingOf(current)) {
            if (self.kindOf(current) == .block) return current;
        }
        return null;
    }
};

const testing = std.testing;

test "a body is found for an arrow and for a declaration that has one" {
    var module = try Module.init(testing.allocator, "");
    defer module.deinit();

    const arrow = try module.add(.arrow, .{ .start = 0, .end = 10, .line = 1 });
    const expression = try module.add(.identifier, .{ .start = 8, .end = 9, .line = 1 });
    module.appendChild(arrow, expression);
    try testing.expectEqual(expression, module.bodyOf(arrow).?);

    const declaration = try module.add(.function_decl, .{ .start = 10, .end = 20, .line = 1 });
    const parameter = try module.add(.identifier, .{ .start = 19, .end = 20, .line = 1 });
    module.appendChild(declaration, parameter);
    try testing.expect(module.bodyOf(declaration) == null);

    const block = try module.add(.block, .{ .start = 20, .end = 30, .line = 1 });
    module.appendChild(declaration, block);
    try testing.expectEqual(block, module.bodyOf(declaration).?);

    // a node that is not a callable has no body, however many blocks hang off it
    const statement = try module.add(.if_stmt, .{ .start = 30, .end = 40, .line = 1 });
    const branch = try module.add(.block, .{ .start = 31, .end = 39, .line = 1 });
    module.appendChild(statement, branch);
    try testing.expect(module.bodyOf(statement) == null);
}

test "spans merge to the smallest range covering both" {
    const first = Span{ .start = 10, .end = 20, .line = 3 };
    const second = Span{ .start = 25, .end = 30, .line = 4 };
    const merged = Span.merge(first, second);
    try testing.expectEqual(@as(u32, 10), merged.start);
    try testing.expectEqual(@as(u32, 30), merged.end);
    try testing.expectEqual(@as(u32, 3), merged.line);
}

test "declaration kinds come from the keyword" {
    try testing.expectEqual(DeclKind.@"const", DeclKind.fromKeyword("const"));
    try testing.expectEqual(DeclKind.@"let", DeclKind.fromKeyword("let"));
    try testing.expectEqual(DeclKind.@"var", DeclKind.fromKeyword("var"));
    try testing.expectEqual(DeclKind.unknown, DeclKind.fromKeyword("function"));
}

test "children link in order and report their parent" {
    var module = try Module.init(testing.allocator, "const a = 1;\n");
    defer module.deinit();

    const block = try module.add(.block, .{ .start = 0, .end = 10, .line = 1 });
    const first = try module.add(.identifier, .{ .start = 6, .end = 7, .line = 1 });
    const second = try module.add(.literal, .{ .start = 10, .end = 11, .line = 1 });
    module.appendChild(block, first);
    module.appendChild(block, second);

    try testing.expectEqual(@as(usize, 2), module.childCount(block));
    try testing.expectEqual(first, module.firstChildOf(block).?);
    try testing.expectEqual(second, module.nextSiblingOf(first).?);
    try testing.expectEqual(block, module.ancestorOf(second, .block).?);
    try testing.expect(module.nextSiblingOf(second) == null);

    // a second parent cannot claim an attached node
    module.appendChild(module.root, first);
    try testing.expectEqual(block, module.parentOf(first).?);
}

test "the iterator walks pre-order and counts unknown nodes" {
    var module = try Module.init(testing.allocator, "");
    defer module.deinit();

    const block = try module.add(.block, .{ .start = 0, .end = 4, .line = 1 });
    const statement = try module.add(.expression_stmt, .{ .start = 0, .end = 2, .line = 1 });
    const unsupported_node = try module.add(.unknown, .{ .start = 2, .end = 4, .line = 1 });
    const sibling = try module.add(.expression_stmt, .{ .start = 4, .end = 6, .line = 1 });
    module.appendChild(module.root, block);
    module.appendChild(block, statement);
    module.appendChild(statement, unsupported_node);
    module.appendChild(block, sibling);

    var order: [5]NodeIndex = undefined;
    var total: usize = 0;
    var walker = module.iterator();
    while (walker.next()) |index| : (total += 1) order[total] = index;

    try testing.expectEqual(@as(usize, 5), total);
    try testing.expectEqual(module.root, order[0]);
    try testing.expectEqual(block, order[1]);
    try testing.expectEqual(statement, order[2]);
    try testing.expectEqual(unsupported_node, order[3]);
    try testing.expectEqual(sibling, order[4]);
    try testing.expectEqual(@as(usize, 1), module.unknownCount());
}

test "textOf slices the source the node covers" {
    var module = try Module.init(testing.allocator, "const total = 1;");
    defer module.deinit();

    const node = try module.add(.identifier, .{ .start = 6, .end = 11, .line = 1 });
    try testing.expectEqualStrings("total", module.textOf(node));
}

test "isInside finds an enclosing node" {
    var module = try Module.init(testing.allocator, "");
    defer module.deinit();

    const block = try module.add(.block, .{ .start = 0, .end = 4, .line = 1 });
    const statement = try module.add(.expression_stmt, .{ .start = 0, .end = 2, .line = 1 });
    module.appendChild(block, statement);

    try testing.expect(module.isInside(statement, .block));
    try testing.expect(!module.isInside(module.root, .block));
}
