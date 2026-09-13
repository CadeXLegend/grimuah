const std = @import("std");
const root = @import("../rules.zig");
const ir = @import("../ir.zig");
const ts = @import("../lang/ts.zig");
const naming = @import("naming.zig");
const typemodel = @import("../lang/typemodel.zig");

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

/// an implementation module names itself `<name>.<kind>.ts`, so its stem carries
/// a surface name and a behaviour kind before the extension
const IMPLEMENTATION_MODULE_MIN_STEM_PARTS = 2;

/// an exported enum declared in an implementation module
///
/// an enum is a configuration constant, and grimuah gives configuration its own
/// innate member so a surface's dag order is declared rather than inherited from
/// whichever module happened to declare the vocabulary. when the enum lives in
/// the repository or the service that raises it, every consumer imports an
/// implementation module to read a constant, and the module that owns the
/// behaviour ends up owning the vocabulary too
///
/// the file scope is the detector's own: the module has to be an implementation
/// module, so a `.config.ts` is where the enum belongs rather than where it
/// violates anything, and a module at the top of the tree is the shared root
/// library or an entry point
///
/// only a top-level `export enum` counts. a nested one is not read, and for the
/// same reason the detector's top-level statement walk leaves it: `declare
/// module { ... }` parses as one node with no children
pub fn checkEnumPlacement(context: *const root.Context) !void {
    if (!isImplementationModule(context.path)) return;
    const module = context.module orelse return;

    var child = module.firstChildOf(module.root);
    while (child) |current| : (child = module.nextSiblingOf(current)) {
        if (module.kindOf(current) != .export_decl) continue;
        if (!exportedDeclaresEnum(module, context.tokens, current)) continue;
        // the detector reports the declaration's own start and a declaration's
        // modifiers are part of its node, so an `export` on a line of its own is
        // where the finding lands
        try context.report(module.spanOf(current).line, .structural, root.enum_placement, .warn);
    }
}

/// whether the module is named for a behaviour kind rather than for a
/// declaration, and is not the tree's own top level
fn isImplementationModule(path: []const u8) bool {
    const file_name = naming.fileNameOf(path);
    if (!std.mem.endsWith(u8, file_name, ".ts")) return false;
    if (naming.stemPartCount(file_name) < IMPLEMENTATION_MODULE_MIN_STEM_PARTS) return false;
    if (naming.isDeclarationModule(file_name)) return false;
    return !naming.isRootModule(path);
}

/// whether an exported statement declares an enum. the front-end models
/// `interface`, `type`, `enum`, `namespace` and `declare` as one node kind whose
/// children are empty, so the keyword is read off the declaration's own leading
/// words: `export enum X { ... }` and `export declare enum X { ... }` both carry
/// `enum` before the name, and `export type Enum = ...` carries the capitalised
/// name instead
///
/// the child's kind is deliberately not tested. `export const enum X { ... }` is
/// a legal enum declaration and the front-end models it as a const declaration,
/// because `const` is the word its statement dispatch reads first, so the
/// leading words are `const`, `enum`, `X` and the keyword is still there. every
/// other declaration kind leads with its own keyword, and `enum` is reserved and
/// cannot be the name, so the scan is what decides
fn exportedDeclaresEnum(module: *const ir.Module, tokens: []const ts.Token, statement: ir.NodeIndex) bool {
    var child = module.firstChildOf(statement);
    while (child) |current| : (child = module.nextSiblingOf(current)) {
        const from = typemodel.tokenAtOrAfter(tokens, module.spanOf(current).start);
        if (leadsWithEnum(tokens, from)) return true;
    }
    return false;
}

/// whether the words a declaration leads with include `enum`. the scan stops at
/// the first token that is not a word, which is the name's end, the `=` of an
/// alias or the `{` of a body
fn leadsWithEnum(tokens: []const ts.Token, from: usize) bool {
    var index = from;
    while (index < tokens.len) : (index += 1) {
        if (tokens[index].kind != .word) return false;
        if (tokens[index].isWord("enum")) return true;
    }
    return false;
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

test "an exported enum in an implementation module is reported, and the excluded declarations are not" {
    const source =
        \\export enum AccountFailureReason {
        \\  NotFound = "not-found",
        \\}
        \\
        \\enum LocalReason {
        \\  Gone = "gone",
        \\}
        \\
        \\export interface Account {
        \\  id: string;
        \\}
        \\
        \\export type FailureCode = "not-found" | "gone";
        \\
        \\export declare enum DeclaredReason {
        \\  Gone = "gone",
        \\}
        \\
        \\declare module "remote" {
        \\  export enum NestedReason {
        \\    Gone = "gone",
        \\  }
        \\}
        \\
        \\export
        \\enum SplitReason {
        \\  Gone = "gone",
        \\}
        \\
        \\{
        \\  enum BlockLocalReason {
        \\    Gone = "gone",
        \\  }
        \\}
        \\
        \\export const enum ConstReason {
        \\  Gone = "gone",
        \\}
        \\
    ;
    try probe.expect(.structural, "src/db/accounts.repo.ts", source, &.{
        "1: This enum is a configuration constant declared in an implementation module. Move it to the surface's .config.ts file.",
        "15: This enum is a configuration constant declared in an implementation module. Move it to the surface's .config.ts file.",
        "25: This enum is a configuration constant declared in an implementation module. Move it to the surface's .config.ts file.",
        "36: This enum is a configuration constant declared in an implementation module. Move it to the surface's .config.ts file.",
    });
}

test "the enum rule reads the module's name, so a declaration module and a module at the top of the tree are both out of scope" {
    const source =
        \\export enum AccountFailureReason {
        \\  NotFound = "not-found",
        \\}
        \\
    ;
    // the surface's own config file is where the enum belongs
    try probe.expect(.structural, "src/db/accounts.config.ts", source, &.{});
    try probe.expect(.structural, "src/db/accounts.types.ts", source, &.{});
    try probe.expect(.structural, "src/db/accounts.spec.ts", source, &.{});
    try probe.expect(.structural, "src/db/accounts.d.ts", source, &.{});
    // a module with no behaviour kind is not an implementation module
    try probe.expect(.structural, "src/db/accounts.ts", source, &.{});
    // the engine lints `.tsx`, `.js` and the other extensions too, and the
    // detector reads TypeScript declarations only
    try probe.expect(.structural, "src/db/accounts.repo.tsx", source, &.{});
    try probe.expect(.structural, "src/db/accounts.repo.js", source, &.{});
    // the tree's top level is the shared root library or an entry point
    try probe.expect(.structural, "lib/accounts.repo.ts", source, &.{});
    try probe.expect(.structural, "accounts.repo.ts", source, &.{});
}
