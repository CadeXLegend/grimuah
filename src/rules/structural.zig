const std = @import("std");
const root = @import("../rules.zig");
const ir = @import("../ir.zig");

/// the rules about what a file of a given name is allowed to be
///
/// these are the first file-level rules the table holds: the structural layer's
/// other members run in `src/prepass.zig`, which walks the project rather than a
/// file and reports without a severity. a rule here reads `context.path` and the
/// tree, and carries a severity like every other rule

/// a function exported from a `.config.ts` file
///
/// a config file sits at the lowest dagOrder of its surface, so an exported
/// function there is callable from every layer above it with no firewall rule
/// describing the dependency: the file stops being a declaration and becomes a
/// module of behaviour that bypasses the surface which owns it
///
/// only a top-level export counts, and only two shapes of it: a function
/// declaration, and a variable whose initializer is a function. `export default
/// () => {}` is neither, because it is an assignment of an expression rather
/// than a declaration, and a class, a call or a conditional that happens to hold
/// an arrow is left alone for the same reason
pub fn checkConfigBehaviour(context: *const root.Context) !void {
    if (!std.mem.endsWith(u8, context.path, ".config.ts")) return;
    const module = context.module orelse return;

    var child = module.firstChildOf(module.root);
    while (child) |current| : (child = module.nextSiblingOf(current)) {
        if (module.kindOf(current) != .export_decl) continue;
        try reportDeclaredBehaviour(module, context, current);
    }
}

/// what one exported statement declares. a `const` with several declarators gets
/// one finding per function value, which is what the detector counts: one per
/// declarator whose initializer is a function
fn reportDeclaredBehaviour(module: *const ir.Module, context: *const root.Context, statement: ir.NodeIndex) !void {
    var child = module.firstChildOf(statement);
    while (child) |current| : (child = module.nextSiblingOf(current)) {
        switch (module.kindOf(current)) {
            .function_decl => try report(module, context, current),
            .variable_decl => {
                var value = module.firstChildOf(current);
                while (value) |candidate| : (value = module.nextSiblingOf(candidate)) {
                    if (module.kindOf(candidate) != .arrow and module.kindOf(candidate) != .function_expr) continue;
                    try report(module, context, current);
                }
            },
            else => {},
        }
    }
}

fn report(module: *const ir.Module, context: *const root.Context, index: ir.NodeIndex) !void {
    try context.report(module.spanOf(index).line, .structural, root.config_behaviour, .warn);
}

const probe = @import("probe.zig");

test "a function exported from a config file is reported, and the data-only shapes are not" {
    const source =
        \\export enum Message {
        \\  Ready = "Ready",
        \\}
        \\
        \\export const Key = "key";
        \\
        \\export function buildKey(): string {
        \\  return Key;
        \\}
        \\
        \\export const currentDateKey = (): string => Key;
        \\
        \\export const makeKey = function (): string {
        \\  return Key;
        \\};
        \\
        \\const localHelper = (): string => Key;
        \\
        \\export const LocalKey = localHelper();
        \\
        \\export { localHelper };
        \\
    ;
    try probe.expect(.structural, "probe.config.ts", source, &.{
        "7: This .config.ts file declares a function. Move the behaviour into the surface's own module.",
        "11: This .config.ts file declares a function. Move the behaviour into the surface's own module.",
        "13: This .config.ts file declares a function. Move the behaviour into the surface's own module.",
    });
}

test "the same file under another name is left alone" {
    const source =
        \\export function buildKey(): string {
        \\  return "key";
        \\}
        \\
    ;
    try probe.expect(.structural, "probe.ts", source, &.{});
}
