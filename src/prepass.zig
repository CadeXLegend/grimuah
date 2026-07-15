const std = @import("std");
const config = @import("config.zig");

/// result of a single pre-pass check
pub const Finding = struct {
    file: []const u8,
    line: u32,
    message: []const u8,
    layer: []const u8, // "cosmetic" | "structural"
};

/// run all enabled pre-pass checks against the project
/// returns slice of findings, caller must free each finding's strings and the slice
pub fn runAll(io: std.Io, 
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    project_root: []const u8,
) ![]Finding {
    var findings: std.ArrayList(Finding) = .empty;

    if (cfg.layers.cosmetic) {
        try checkFolderSuffixes(io, allocator, cfg, project_root, &findings);
        try checkCentralizedDirs(io, allocator, cfg, project_root, &findings);
    }

    if (cfg.layers.structural) {
        try checkImportFirewall(io, allocator, cfg, project_root, &findings);
        try checkInnateMemberDepth(io, allocator, cfg, project_root, &findings);
        try checkSingletonFolders(io, allocator, cfg, project_root, &findings);
    }

    return findings.toOwnedSlice(allocator);
}

/// check every file in a surface directory matches one of that surface's legal suffixes
fn checkFolderSuffixes(io: std.Io, 
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    project_root: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    for (cfg.surfaces) |surface| {
        var dir = std.Io.Dir.cwd().openDir(io, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, surface.path }), .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;

            const matched = for (surface.suffixes) |suffix| {
                if (std.mem.endsWith(u8, entry.basename, suffix)) break true;
            } else for (surface.innateMembers) |innate| {
                if (std.mem.endsWith(u8, entry.basename, innate)) break true;
            } else false;

            if (!matched) {
                const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ project_root, surface.path, entry.path });
                const suffixes_formatted = try formatStringSlice(allocator, surface.suffixes);
                defer allocator.free(suffixes_formatted);
                const msg = try std.fmt.allocPrint(allocator, "file '{s}' in surface '{s}' does not match any legal suffix — allowed: {s}", .{ entry.basename, surface.name, suffixes_formatted });
                try findings.append(allocator, .{
                    .file = file_path,
                    .line = 1,
                    .message = msg,
                    .layer = "cosmetic",
                });
            }
        }
    }
}

/// flag centralized config/, types/, or models/ directories
fn checkCentralizedDirs(io: std.Io, 
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    project_root: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    const forbidden = [_][]const u8{ "config", "types", "models" };

    var src_dir = std.Io.Dir.cwd().openDir(io, try std.fmt.allocPrint(allocator, "{s}/src", .{project_root}), .{ .iterate = true }) catch return;
    defer src_dir.close(io);

    var walker = try src_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        const dir_name = entry.basename;
        for (forbidden) |forbidden_name| {
            if (std.mem.eql(u8, dir_name, forbidden_name)) {
                const dir_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}", .{ project_root, entry.path });
                const msg = try std.fmt.allocPrint(allocator, "centralized '{s}/' directory detected — config, types, and models must be co-located with consumers, not centralized", .{dir_name});
                try findings.append(allocator, .{
                    .file = dir_path,
                    .line = 1,
                    .message = msg,
                    .layer = "cosmetic",
                });
                break;
            }
        }
        _ = cfg; // unused in this function but kept for symmetry
    }
}

/// verify import graph firewall — no file imports from a surface not in its allowed_imports
fn checkImportFirewall(io: std.Io, 
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    project_root: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    // walk all surface directories, read each .ts file, extract import paths, verify depth
    for (cfg.surfaces) |surface| {
        var dir = std.Io.Dir.cwd().openDir(io, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, surface.path }), .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".ts")) continue;

            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ project_root, surface.path, entry.path });
            const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(1024 * 1024)) catch continue;
            defer allocator.free(content);

            // extract import paths from the file
            const imports = try extractImports(allocator, content);
            defer {
                for (imports) |imp| allocator.free(imp);
                allocator.free(imports);
            }

            for (imports) |import_path| {
                // find which surface this import targets
                const target_surface = resolveImportSurface(cfg, import_path);
                if (target_surface) |target| {
                    if (!cfg.canImport(surface.name, target.name) and !std.mem.eql(u8, surface.name, target.name)) {
                        const msg = try std.fmt.allocPrint(allocator, "surface '{s}' (depth {d}) importing from '{s}' (depth {d}) — '{s}' is not in '{s}'s allowedImports", .{ surface.name, surface.depth, target.name, target.depth, target.name, surface.name });
                        try findings.append(allocator, .{
                            .file = file_path,
                            .line = 0,
                            .message = msg,
                            .layer = "structural",
                        });
                    }
                }
            }
        }
    }
}

/// extract relative import paths from a TypeScript source file
/// handles single/multi-line static imports, dynamic import(), and side-effect imports
fn extractImports(allocator: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var imports: std.ArrayList([]const u8) = .empty;

    // scan for all patterns that introduce a quoted path:
    //   from "..." / from '...' (static imports)
    //   import("...") / import('...') (dynamic imports)
    //   import "..." / import '...' (side-effect imports, no from clause)
    const prefixes = [_][]const u8{ "from \"", "from '", "import(\"", "import('", "import \"", "import '" };

    // manual linear scan — simple enough that a regex engine isn't worth it
    var pos: usize = 0;
    while (pos < content.len) : (pos += 1) {
        for (prefixes) |prefix| {
            if (pos + prefix.len > content.len) continue;
            if (!std.mem.eql(u8, content[pos .. pos + prefix.len], prefix)) continue;

            // determine the quote character (last byte of prefix)
            const quote_char = prefix[prefix.len - 1];

            // skip leading prefix to get to the path start
            const path_start = pos + prefix.len;
            if (path_start >= content.len) break;

            // scan for closing quote, allowing backslash escapes
            const path_end = findClosingQuote(content, path_start, quote_char) orelse break;
            const import_path = content[path_start..path_end];

            // only track relative imports
            if (std.mem.startsWith(u8, import_path, "./") or std.mem.startsWith(u8, import_path, "../")) {
                try imports.append(allocator, try allocator.dupe(u8, import_path));
            }

            // advance past the found prefix so we don't re-match it
            pos = path_start;
            break;
        }
    }

    return imports.toOwnedSlice(allocator);
}

/// find the end of a quoted string, handling backslash escapes
fn findClosingQuote(content: []const u8, start: usize, quote: u8) ?usize {
    var i = start;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\\') {
            i += 1; // skip escaped char
            continue;
        }
        if (content[i] == quote) return i;
    }
    return null;
}

/// resolve a relative import path to a surface name, or null if not in any surface
fn resolveImportSurface(cfg: *const config.Config, import_path: []const u8) ?*const config.Surface {
    // handles ../db/index.ts → db surface
    // handles ./sibling.ts → same surface as caller (skip — self-imports allowed)

    // simple heuristic: the first non-dot directory segment gives us the surface name
    var iter = std.mem.splitScalar(u8, import_path, '/');
    while (iter.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) continue;
        // found the first real directory — check if it's a surface
        return cfg.getSurface(segment);
    }

    return null;
}

/// verify innate member depth scoping — types/config defined in deeper surfaces
/// must not be imported by shallower surfaces; they must be lifted to the shallowest common ancestor
fn checkInnateMemberDepth(io: std.Io, 
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    project_root: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    for (cfg.surfaces) |surface| {
        var dir = std.Io.Dir.cwd().openDir(io, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, surface.path }), .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".ts")) continue;

            // skip non-innate-member files
            const is_innate = for (surface.innateMembers) |innate| {
                if (std.mem.endsWith(u8, entry.basename, innate)) break true;
            } else false;
            if (!is_innate) continue;

            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ project_root, surface.path, entry.path });
            const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(1024 * 1024)) catch continue;
            defer allocator.free(content);

            // check if any import from this innate member file goes to an even deeper surface
            const imports = try extractImports(allocator, content);
            defer {
                for (imports) |imp| allocator.free(imp);
                allocator.free(imports);
            }

            for (imports) |import_path| {
                const target_surface = resolveImportSurface(cfg, import_path);
                if (target_surface) |target| {
                    // flag: innate member in THIS surface imports from an even DEEPER surface
                    if (target.depth > surface.depth) {
                        const msg = try std.fmt.allocPrint(allocator, "innate member '{s}' in surface '{s}' (depth {d}) imports from deeper surface '{s}' (depth {d}) — lift this type to the shallowest common ancestor", .{ entry.basename, surface.name, surface.depth, target.name, target.depth });
                        try findings.append(allocator, .{
                            .file = file_path,
                            .line = 1,
                            .message = msg,
                            .layer = "structural",
                        });
                    }
                }
            }
        }
    }
}

/// warn when a surface folder contains only one file
fn checkSingletonFolders(io: std.Io, 
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    project_root: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    for (cfg.surfaces) |surface| {
        var dir = std.Io.Dir.cwd().openDir(io, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, surface.path }), .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        var file_count: u32 = 0;
        while (try walker.next(io)) |entry| {
            if (entry.kind == .file) file_count += 1;
        }

        if (file_count <= 1) {
            const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, surface.path });
            const msg = try std.fmt.allocPrint(allocator, "surface '{s}' contains only {d} file(s) — a set of 1 is a leaf node that shouldn't carry folder overhead; consider lifting or expanding", .{ surface.name, file_count });
            try findings.append(allocator, .{
                .file = dir_path,
                .line = 0,
                .message = msg,
                .layer = "structural",
            });
        }
    }
}

/// join `[]const []const u8` into a comma-separated string, e.g. `.util.ts, .config.ts`
/// caller owns the returned slice (allocator.free)
fn formatStringSlice(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (items, 0..) |item, i| {
        if (i > 0) try result.appendSlice(allocator, ", ");
        try result.appendSlice(allocator, item);
    }

    return result.toOwnedSlice(allocator);
}

const testing = std.testing;

test "extractImports extracts single-line static import" {
    const allocator = testing.allocator;
    const content = "import { foo } from './bar';";
    const imports = try extractImports(allocator, content);
    defer {
        for (imports) |imp| allocator.free(imp);
        allocator.free(imports);
    }
    try testing.expectEqual(@as(usize, 1), imports.len);
    try testing.expectEqualStrings("./bar", imports[0]);
}

test "extractImports extracts multi-line static import" {
    const allocator = testing.allocator;
    const content =
        "import {\n" ++
        "  foo,\n" ++
        "  bar,\n" ++
        "} from '../baz';";
    const imports = try extractImports(allocator, content);
    defer {
        for (imports) |imp| allocator.free(imp);
        allocator.free(imports);
    }
    try testing.expectEqual(@as(usize, 1), imports.len);
    try testing.expectEqualStrings("../baz", imports[0]);
}

test "extractImports extracts dynamic import()" {
    const allocator = testing.allocator;
    const content = "const mod = await import('./mod');";
    const imports = try extractImports(allocator, content);
    defer {
        for (imports) |imp| allocator.free(imp);
        allocator.free(imports);
    }
    try testing.expectEqual(@as(usize, 1), imports.len);
    try testing.expectEqualStrings("./mod", imports[0]);
}

test "extractImports extracts side-effect import" {
    const allocator = testing.allocator;
    const content = "import './polyfill';";
    const imports = try extractImports(allocator, content);
    defer {
        for (imports) |imp| allocator.free(imp);
        allocator.free(imports);
    }
    try testing.expectEqual(@as(usize, 1), imports.len);
    try testing.expectEqualStrings("./polyfill", imports[0]);
}

test "extractImports skips non-relative imports" {
    const allocator = testing.allocator;
    const content = "import { foo } from 'lodash';";
    const imports = try extractImports(allocator, content);
    defer {
        for (imports) |imp| allocator.free(imp);
        allocator.free(imports);
    }
    try testing.expectEqual(@as(usize, 0), imports.len);
}

test "extractImports extracts multiple imports from file" {
    const allocator = testing.allocator;
    const content =
        "import { a } from './a';\n" ++
        "import { b } from '../b';\n" ++
        "import { c } from 'c';";
    const imports = try extractImports(allocator, content);
    defer {
        for (imports) |imp| allocator.free(imp);
        allocator.free(imports);
    }
    try testing.expectEqual(@as(usize, 2), imports.len);
    try testing.expectEqualStrings("./a", imports[0]);
    try testing.expectEqualStrings("../b", imports[1]);
}

test "extractImports handles single quotes" {
    const allocator = testing.allocator;
    const content = "import { foo } from './bar';";
    const imports = try extractImports(allocator, content);
    defer {
        for (imports) |imp| allocator.free(imp);
        allocator.free(imports);
    }
    try testing.expectEqual(@as(usize, 1), imports.len);
    try testing.expectEqualStrings("./bar", imports[0]);
}

test "formatStringSlice joins strings with comma" {
    const allocator = testing.allocator;
    const result = try formatStringSlice(allocator, &.{ ".a.ts", ".b.ts" });
    defer allocator.free(result);
    try testing.expectEqualStrings(".a.ts, .b.ts", result);
}

test "formatStringSlice single item has no comma" {
    const allocator = testing.allocator;
    const result = try formatStringSlice(allocator, &.{".only.ts"});
    defer allocator.free(result);
    try testing.expectEqualStrings(".only.ts", result);
}

test "formatStringSlice empty slice returns empty" {
    const allocator = testing.allocator;
    const result = try formatStringSlice(allocator, &.{});
    defer allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "findClosingQuote finds closing quote" {
    const content = "hello 'world'";
    const pos = findClosingQuote(content, 6, '\'').?;
    try testing.expectEqual(@as(usize, 12), pos);
}

test "findClosingQuote handles backslash escapes" {
    const content = "'hello\\'world'";
    const pos = findClosingQuote(content, 0, '\'').?;
    try testing.expectEqual(@as(usize, 14), pos);
}
