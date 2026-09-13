const std = @import("std");
const root = @import("../rules.zig");
const config = @import("../config.zig");
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
    if (!isEnumPlacementModule(context.path)) return;
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

/// whether the module is named for a behaviour kind rather than for a declaration,
/// and is not the tree's own top level. a module at the top of the tree is the shared
/// root library or an entry point, and its enums belong to it
fn isEnumPlacementModule(path: []const u8) bool {
    return naming.isImplementationModule(naming.fileNameOf(path)) and !naming.isRootModule(path);
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
    for (typemodel.leadingWords(tokens, from)) |word| {
        if (word.isWord("enum")) return true;
    }
    return false;
}

/// one file's import cycle, from the graph the merge built
///
/// the rule has no per-file matcher: whether a file sits in a cycle is a property
/// of the whole run, so the merge reads every file's imports first and calls this
/// as it walks them
///
/// the row is the file's first import that points back into its own component, in
/// statement order. an earlier import that points at a cycle *of another component*
/// is not the closing edge, which is why the graph labels components rather than
/// asking whether a target sits on some cycle
pub fn resolveImportCycle(
    allocator: std.mem.Allocator,
    graph: *const root.ProjectIndex,
    file: usize,
    path: []const u8,
    rule: *const root.Rule,
    findings: *std.ArrayList(root.Finding),
) std.mem.Allocator.Error!void {
    const cycle = graph.cycle_of[file];
    if (cycle == root.no_cycle) return;

    for (graph.imports[file]) |import| {
        if (graph.cycle_of[import.target] != cycle) continue;
        try findings.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .line = import.line,
            .message = try allocator.dupe(u8, rule.message),
            .layer = rule.layer.name(),
            .severity = rule.severity,
        });
        return;
    }
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

/// the line a whole-surface finding is anchored at. the entry is a fact about the
/// configured surface rather than about the file the row lands on, so the row names
/// the surface and the entry in its message instead
const SURFACE_FINDING_LINE = 1;

/// an allowedImports entry the dag already implies: the checker grants every import
/// to a surface with a lower dagOrder before it reads that surface's own list, so an
/// entry naming a shallower surface is never consulted
///
/// the report is once per surface rather than once per file, anchored at the
/// surface's first file in byte order, because the entry is one fact about the
/// configuration and a forty-file surface would otherwise repeat it forty times
///
/// the surface is the deepest one that owns the file AND carries a list. a file can
/// belong to a nested surface whose own list is empty, and the grant that applies to
/// it is then the enclosing surface's
pub fn checkRedundantAllowedImport(context: *const root.Context) !void {
    const surface = grantingSurface(context.cfg, context.path) orelse return;
    if (!isFirstFileOfSurface(context, surface)) return;

    for (surface.allowedImports) |allowed_name| {
        const target = context.cfg.getSurface(allowed_name) orelse continue;
        if (target.dagOrder >= surface.dagOrder) continue;
        const message = try std.fmt.allocPrint(context.allocator, root.redundant_allowed_import, .{
            surface.name,
            surface.dagOrder,
            allowed_name,
            target.dagOrder,
        });
        defer context.allocator.free(message);
        try context.report(SURFACE_FINDING_LINE, .structural, message, .warn);
    }
}

/// the deepest declared surface that owns `path` and carries an allowedImports list,
/// or null. `Config.owningSurface` answers the deepest owner, and this answers the
/// one whose list the checker would read, which is the same surface unless the
/// deepest owner's own list is empty
fn grantingSurface(cfg: *const config.Config, path: []const u8) ?*const config.Surface {
    var owner: ?*const config.Surface = null;
    for (cfg.surfaces) |*surface| {
        if (surface.allowedImports.len == 0) continue;
        if (!config.pathIsWithin(path, surface.path)) continue;
        if (owner == null or surface.path.len > owner.?.path.len) owner = surface;
    }
    return owner;
}

/// whether this file is the first of its surface in byte order, which is where the
/// surface's own finding is reported
///
/// byte order rather than the locale's: the row has to be the same on any machine,
/// and the research's runner sorts the same way
fn isFirstFileOfSurface(context: *const root.Context, surface: *const config.Surface) bool {
    var first: ?[]const u8 = null;
    for (context.paths) |candidate| {
        if (!config.pathIsWithin(candidate, surface.path)) continue;
        if (first == null or std.mem.lessThan(u8, candidate, first.?)) first = candidate;
    }
    return if (first) |path| std.mem.eql(u8, path, context.path) else false;
}

/// the surfaces the redundancy tests run under: `src/commands` carries two entries,
/// one the dag already implies and one at its own dagOrder, which the checker reads;
/// `lib` is shallower and carries none; `src/commands/tasks` is nested inside
/// `commands` and carries none either, so the grant that applies to a task file is
/// the enclosing surface's
var redundancy_surfaces = [_]config.Surface{
    .{ .name = "lib", .path = "lib", .depth = 0, .dagOrder = 0, .suffixes = &.{".ts"} },
    .{ .name = "services", .path = "src/services", .depth = 1, .dagOrder = 1, .suffixes = &.{".service.ts"} },
    .{ .name = "commands", .path = "src/commands", .depth = 1, .dagOrder = 1, .suffixes = &.{".command.ts"}, .allowedImports = &.{ "lib", "services", "ghost" } },
    .{ .name = "tasks", .path = "src/commands/tasks", .depth = 2, .dagOrder = 2, .suffixes = &.{".task.ts"} },
};

const redundancy_cfg = config.Config{
    .surfaces = &redundancy_surfaces,
    .layers = .{ .cosmetic = false, .structural = true, .resilience = false, .behavioural = false },
};

test "a grant the dag already implies is reported once, at the surface's first file" {
    const source =
        \\export const Name = "commands";
        \\
    ;
    try probe.expectConfigured(&redundancy_cfg, &.{
        // the surface's first file in byte order, which is inside a nested surface:
        // the nested surface carries no list of its own, so the grant that applies
        // to this file is the enclosing surface's, and the row lands here rather
        // than on the first file of `src/commands` itself
        .{ .path = "src/commands/aaa.task.ts", .content = source },
        .{ .path = "src/commands/afk.command.config.ts", .content = source },
        .{ .path = "src/commands/zeta.command.ts", .content = source },
        // a surface whose own list is empty reports nothing
        .{ .path = "src/services/afk.service.ts", .content = source },
        .{ .path = "lib/thing.ts", .content = source },
    }, &.{
        "src/commands/aaa.task.ts:1: Surface 'commands' (dagOrder 1) grants 'lib' (dagOrder 0), which the dag already permits. Delete the entry from its allowedImports list.",
    });
}

test "the surface's first file is the one that reports, whatever order the run read them in" {
    const source =
        \\export const Name = "commands";
        \\
    ;
    // the same project, with the files handed over in the other order: the anchor is
    // byte order rather than the run's, so the row does not move
    try probe.expectConfigured(&redundancy_cfg, &.{
        .{ .path = "src/commands/zzz.command.ts", .content = source },
        .{ .path = "src/commands/tasks/aaa.task.ts", .content = source },
    }, &.{
        "src/commands/tasks/aaa.task.ts:1: Surface 'commands' (dagOrder 1) grants 'lib' (dagOrder 0), which the dag already permits. Delete the entry from its allowedImports list.",
    });
}

test "a grant at the surface's own dagOrder is read by the checker and is not reported" {
    const source =
        \\export const Name = "commands";
        \\
    ;
    // `services` sits at the same dagOrder as `commands`, so `canImport` reads that
    // entry when the deeper-to-shallower shortcut does not apply. only the entry
    // naming a shallower surface is dead configuration
    var surfaces = [_]config.Surface{
        .{ .name = "services", .path = "src/services", .depth = 1, .dagOrder = 1, .suffixes = &.{".service.ts"} },
        .{ .name = "commands", .path = "src/commands", .depth = 1, .dagOrder = 1, .suffixes = &.{".command.ts"}, .allowedImports = &.{"services"} },
    };
    const cfg = config.Config{
        .surfaces = &surfaces,
        .layers = .{ .cosmetic = false, .structural = true, .resilience = false, .behavioural = false },
    };
    try probe.expectConfigured(&cfg, &.{
        .{ .path = "src/commands/afk.command.ts", .content = source },
    }, &.{});
}

/// a type alias an implementation module exports and another directory consumes
///
/// when the shared type sits inside the module that also implements behaviour, every
/// consumer of the type imports the implementation, the edge the import firewall
/// reasons about is no longer the one a reader sees, and the type and the behaviour
/// can no longer change independently. the detector leaves enums to
/// `require-enum-in-config-file`, so the two never offer the same fix twice
///
/// the file scope is the name alone: an implementation module is in scope wherever it
/// sits, including the tree's top level, which is where this rule and the enum rule
/// part company
///
/// a consumer has to sit in another directory, and it has to name the type in a named
/// import clause. an import bound under another name does not count, because the
/// detector reads the binding's local name and the declaration is keyed by its own
pub fn checkSharedTypePlacement(
    allocator: std.mem.Allocator,
    index: *const root.ProjectIndex,
    file: usize,
    path: []const u8,
    rule: *const root.Rule,
    findings: *std.ArrayList(root.Finding),
) std.mem.Allocator.Error!void {
    if (!naming.isImplementationModule(naming.fileNameOf(path))) return;

    for (index.exports[file]) |exported| {
        if (exported.kind != .type_alias) continue;
        if (!consumedFromAnotherDirectory(index, file, exported.name)) continue;
        // the message carries the declaration file's name, so it is formatted rather
        // than taken from the table as a finished string. the table names the same
        // constant this reads, so the wording still has one source
        const message = try std.fmt.allocPrint(
            allocator,
            root.shared_type_placement,
            .{naming.stemParentOf(naming.fileNameOf(path))},
        );
        defer allocator.free(message);
        try findings.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .line = exported.line,
            .message = try allocator.dupe(u8, message),
            .layer = rule.layer.name(),
            .severity = rule.severity,
        });
    }
}

/// whether some file in another directory imports this name from this file
fn consumedFromAnotherDirectory(index: *const root.ProjectIndex, file: usize, name: []const u8) bool {
    for (index.importers[file]) |importer| {
        if (sameDirectory(index.paths[importer.file], index.paths[file])) continue;
        for (importer.names) |bound| {
            if (std.mem.eql(u8, bound, name)) return true;
        }
    }
    return false;
}

/// whether two paths sit in one directory, which is the detector's own test: the
/// directories compared as text
fn sameDirectory(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, directoryOf(left), directoryOf(right));
}

fn directoryOf(path: []const u8) []const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..separator];
}

/// the declaration a placement test's rows are anchored on, so the expected row is
/// built from the table's message and a wording change is one edit
fn placementRow(allocator: std.mem.Allocator, path: []const u8, line: u32, declaration: []const u8) ![]const u8 {
    const message = try std.fmt.allocPrint(allocator, root.shared_type_placement, .{declaration});
    defer allocator.free(message);
    return std.fmt.allocPrint(allocator, "{s}:{d}: {s}", .{ path, line, message });
}

test "a type an implementation module exports and another directory imports is reported" {
    const allocator = std.testing.allocator;
    const consumed = try placementRow(allocator, "src/db/accounts.repo.ts", 3, "accounts");
    defer allocator.free(consumed);

    try probe.expectProject(.structural, &.{
        .{ .path = "src/db/accounts.repo.ts", .content =
        \\export const Row = "account";
        \\
        \\export type Account = { readonly id: string };
        \\

        },
        .{ .path = "src/services/billing.service.ts", .content =
        \\import { Account } from "../db/accounts.repo";

        \\export function charge(account: Account): string {
        \\  return account.id;
        \\}
        \\
        },
    }, &.{consumed});
}

test "the placement rule reads the directory the consumer sits in, and the name it binds" {
    const allocator = std.testing.allocator;
    const consumed = try placementRow(allocator, "src/db/accounts.repo.ts", 1, "accounts");
    defer allocator.free(consumed);

    // the declaration module's own name is a declaration module's, so a type there is
    // already placed; the sibling in the same directory is not another directory; the
    // consumer that names it is in one, so exactly one row
    try probe.expectProject(.structural, &.{
        .{ .path = "src/db/accounts.repo.ts", .content =
        \\export type Account = { readonly id: string };
        \\
        \\export type Pending = { readonly id: string };
        \\

        },
        // the same directory: `src/db`, so this consumes nothing
        .{ .path = "src/db/rows.repo.ts", .content =
        \\import { Pending } from "./accounts.repo";

        \\export function rows(pending: Pending): string {
        \\  return pending.id;
        \\}
        \\
        },
        .{ .path = "src/services/billing.service.ts", .content =
        \\import { Account } from "../db/accounts.repo";

        \\export function charge(account: Account): string {
        \\  return account.id;
        \\}
        \\
        },
    }, &.{consumed});
}

test "an enum, an unimported alias and a renamed import are all out of scope" {
    // the enum sits in the root library, which the enum rule leaves alone, so the
    // only question this test asks is the placement rule's: an enum is that rule's
    // own case and is never reported here. `Local` is imported from its own
    // directory and `Unread` from nowhere. the consumer binds `Renamed` under a name
    // of its own, and the detector reads the binding's local name, so a renamed
    // import does not make a type shared either
    try probe.expectProject(.structural, &.{
        .{ .path = "lib/reasons.repo.ts", .content =
        \\export enum Reason {
        \\  Ready = "ready",
        \\}
        \\
        },
        .{ .path = "src/db/accounts.repo.ts", .content =
        \\export type Local = { readonly id: string };
        \\
        \\export type Unread = { readonly id: string };
        \\
        \\export type Renamed = { readonly id: string };
        \\
        },
        .{ .path = "src/db/rows.repo.ts", .content =
        \\import { Local } from "./accounts.repo";

        \\export function rows(local: Local): string {
        \\  return local.id;
        \\}
        \\
        },
        .{ .path = "src/services/billing.service.ts", .content =
        \\import { Renamed as Chargeable } from "../db/accounts.repo";
        \\import { Reason } from "../../lib/reasons.repo";

        \\export function charge(chargeable: Chargeable, reason: Reason): string {
        \\  return chargeable.id + reason;
        \\}
        \\
        },
    }, &.{});
}

test "a declaration module and a module with no behaviour kind export nothing the rule reads" {
    // the file scope is the name: `accounts.types.ts` is a declaration module and
    // `accounts.ts` carries no behaviour kind, so neither is judged. the root library
    // is not excluded here, which is where this rule and the enum rule part company
    const allocator = std.testing.allocator;
    const consumed = try placementRow(allocator, "lib/shared.repo.ts", 1, "shared");
    defer allocator.free(consumed);

    try probe.expectProject(.structural, &.{
        .{ .path = "src/db/accounts.types.ts", .content =
        \\export type Account = { readonly id: string };
        \\
        },
        .{ .path = "src/db/accounts.ts", .content =
        \\export type Account = { readonly id: string };
        \\
        },
        .{ .path = "lib/shared.repo.ts", .content =
        \\export type Shared = { readonly id: string };
        \\
        },
        .{ .path = "src/services/billing.service.ts", .content =
        \\import { Account } from "../db/accounts.types";
        \\import { Account as Other } from "../db/accounts";
        \\import { Shared } from "../../lib/shared.repo";

        \\export function charge(account: Account, other: Other, shared: Shared): string {
        \\  return account.id + other.id + shared.id;
        \\}
        \\
        },
    }, &.{consumed});
}

/// an expected row for the import-cycle rule, built from the table's message so a
/// wording change is one edit and the test stays readable
fn cycleRow(allocator: std.mem.Allocator, path: []const u8, line: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}:{d}: {s}", .{ path, line, root.import_cycle });
}

test "two files that import each other report at each file's own closing import" {
    const allocator = std.testing.allocator;
    const accounts = try cycleRow(allocator, "src/db/accounts.repo.ts", 1);
    defer allocator.free(accounts);
    const rows = try cycleRow(allocator, "src/db/rows.repo.ts", 1);
    defer allocator.free(rows);

    try probe.expectProject(.structural, &.{
        .{ .path = "src/db/accounts.repo.ts", .content =
        \\import { readRow } from "./rows.repo.ts";
        \\
        \\export function readAccount(): string {
        \\  return readRow();
        \\}
        \\
        },
        .{ .path = "src/db/rows.repo.ts", .content =
        \\import { readAccount } from "./accounts.repo.ts";
        \\
        \\export function readRow(): string {
        \\  return readAccount();
        \\}
        \\
        },
    }, &.{ accounts, rows });
}

test "a one-way import is not a cycle, and neither is one that only points into one" {
    const allocator = std.testing.allocator;
    const first = try cycleRow(allocator, "src/db/a.repo.ts", 1);
    defer allocator.free(first);
    const second = try cycleRow(allocator, "src/db/b.repo.ts", 1);
    defer allocator.free(second);

    // a is reached by both b and c, and imports back into neither, so only the
    // pair that closes the cycle reports. c points into the cycle from outside it
    // and is not part of it
    try probe.expectProject(.structural, &.{
        .{ .path = "src/db/a.repo.ts", .content =
        \\import { fromB } from "./b.repo.ts";
        \\
        \\export function fromA(): string {
        \\  return fromB();
        \\}
        \\
        },
        .{ .path = "src/db/b.repo.ts", .content =
        \\import { fromA } from "./a.repo.ts";
        \\
        \\export function fromB(): string {
        \\  return fromA();
        \\}
        \\
        },
        .{ .path = "src/db/c.repo.ts", .content =
        \\import { fromA } from "./a.repo.ts";
        \\
        \\export function fromC(): string {
        \\  return fromA();
        \\}
        \\
        },
    }, &.{ first, second });
}

test "a second cycle does not answer for the first, so a file reports its own closing import" {
    const allocator = std.testing.allocator;
    const own_cycle_first = try cycleRow(allocator, "src/db/own-a.repo.ts", 3);
    defer allocator.free(own_cycle_first);
    const own_cycle_second = try cycleRow(allocator, "src/db/own-b.repo.ts", 1);
    defer allocator.free(own_cycle_second);
    const other_cycle_first = try cycleRow(allocator, "src/db/other-a.repo.ts", 1);
    defer allocator.free(other_cycle_first);
    const other_cycle_second = try cycleRow(allocator, "src/db/other-b.repo.ts", 1);
    defer allocator.free(other_cycle_second);

    // the first file imports a cycle it is not in before it imports the one it is, so
    // its row is the second import: the graph labels components rather than asking
    // whether a target sits on some cycle
    try probe.expectProject(.structural, &.{
        .{ .path = "src/db/own-a.repo.ts", .content =
        \\import { fromOtherA } from "./other-a.repo.ts";
        \\
        \\import { fromOwnB } from "./own-b.repo.ts";
        \\
        \\export function fromOwnA(): string {
        \\  return fromOtherA() + fromOwnB();
        \\}
        \\
        },
        .{ .path = "src/db/own-b.repo.ts", .content =
        \\import { fromOwnA } from "./own-a.repo.ts";
        \\
        \\export function fromOwnB(): string {
        \\  return fromOwnA();
        \\}
        \\
        },
        .{ .path = "src/db/other-a.repo.ts", .content =
        \\import { fromOtherB } from "./other-b.repo.ts";
        \\
        \\export function fromOtherA(): string {
        \\  return fromOtherB();
        \\}
        \\
        },
        .{ .path = "src/db/other-b.repo.ts", .content =
        \\import { fromOtherA } from "./other-a.repo.ts";
        \\
        \\export function fromOtherB(): string {
        \\  return fromOtherA();
        \\}
        \\
        },
    }, &.{ own_cycle_first, own_cycle_second, other_cycle_first, other_cycle_second });
}

test "a package, an unresolvable path, a self-import, a re-export and a dynamic import are no edges" {
    // b imports a from a bare specifier, from a path the run never read, from
    // itself, and through `export ... from`, which is a re-export rather than an
    // import declaration. `a` reaches b by a dynamic import, which is an
    // expression rather than a declaration. none of those is a dependency the
    // module graph has an edge for, so no pair here is a cycle
    try probe.expectProject(.structural, &.{
        .{ .path = "src/db/a.repo.ts", .content =
        \\export async function fromA(): Promise<string> {
        \\  const loaded = await import("./b.repo.ts");
        \\  return loaded.fromB();
        \\}
        \\
        },
        .{ .path = "src/db/b.repo.ts", .content =
        \\import { fromA } from "./a.repo.ts";
        \\import { helper } from "@lib/helper";
        \\import { gone } from "./missing.repo.ts";
        \\import { itself } from "./b.repo.ts";
        \\import { deep } from "../../../outside/deep.repo.ts";
        \\
        \\export { fromA } from "./a.repo.ts";
        \\
        \\export function fromB(): string {
        \\  return fromA() + helper() + gone() + itself() + deep();
        \\}
        \\
        },
        // d imports e and e re-exports d, which is the other half of the round trip
        // a reader might mistake for a cycle: a re-export is not a dependency the
        // module graph has an edge for, so nothing here closes
        .{ .path = "src/db/d.repo.ts", .content =
        \\import { fromE } from "./e.repo.ts";
        \\
        \\export function fromD(): string {
        \\  return fromE();
        \\}
        \\
        },
        .{ .path = "src/db/e.repo.ts", .content =
        \\export { fromD } from "./d.repo.ts";
        \\
        },
    }, &.{});
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
