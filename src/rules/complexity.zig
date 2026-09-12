const std = @import("std");
const root = @import("../rules.zig");
const ir = @import("../ir.zig");

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
            if (branch_count == 0 and !isStatement(self.module.kindOf(current))) {
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

/// whether a node is one of the statements the parser produces in statement
/// position. it tells an `if`'s condition from the branch that follows it
fn isStatement(kind: ir.Kind) bool {
    return switch (kind) {
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

const probe = @import("probe.zig");

test "a body four layers deep is reported once per layer past the limit" {
    const source =
        \\function deep(xs: number[]): void {
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
        \\function ok(xs: number[]): void {
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
        \\const shallow = (xs: number[]): void => {
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
        \\function outer(xs: number[]): void {
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
