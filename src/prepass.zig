const std = @import("std");
const config = @import("config.zig");
const paths = @import("paths.zig");

/// result of a single pre-pass check
pub const Finding = struct {
    file: []const u8,
    line: u32,
    message: []const u8,
    layer: []const u8, // "cosmetic" | "structural"
};

/// run all enabled pre-pass checks against the project
/// returns slice of findings, caller must free each finding's strings and the slice
///
/// every per-surface check shares a single directory walk and a single read per
/// file, so the pre-pass cost stays linear in the number of files rather than
/// the number of checks
pub fn runAll(io: std.Io, 
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    project_root: []const u8,
) ![]Finding {
    var findings: std.ArrayList(Finding) = .empty;

    if (cfg.layers.cosmetic) {
        try checkCentralizedDirs(io, allocator, project_root, &findings);
    }

    for (cfg.surfaces) |surface| {
        try checkSurface(io, allocator, cfg, project_root, surface, &findings);
    }

    return findings.toOwnedSlice(allocator);
}

/// file basename matches one of the surface's legal suffixes or innate members
fn matchesSurfaceName(surface: config.Surface, basename: []const u8) bool {
    for (surface.suffixes) |suffix| {
        if (std.mem.endsWith(u8, basename, suffix)) return true;
    }
    for (surface.innateMembers) |innate| {
        if (std.mem.endsWith(u8, basename, innate)) return true;
    }
    return false;
}

/// file basename is an innate member of the surface
fn isInnateMember(surface: config.Surface, basename: []const u8) bool {
    for (surface.innateMembers) |innate| {
        if (std.mem.endsWith(u8, basename, innate)) return true;
    }
    return false;
}

/// one file of a surface, with everything the checks can decide before the file
/// is opened. the walker's slices live in its own buffer, so both are copied
const SurfaceFile = struct {
    /// path relative to the surface directory
    relative_path: []u8,
    basename: []u8,
    /// the name matches none of the surface's legal suffixes
    suffix_violation: bool,
};

/// the per-file work, so it can run on a pool: the suffix violation the walk
/// already knew, then the structural checks that have to read the file
fn checkSurfaceFile(
    temp: std.mem.Allocator,
    finding_allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    project_root: []const u8,
    surface: config.Surface,
    file: SurfaceFile,
    structural: bool,
    findings: *std.ArrayList(Finding),
) !void {
    const file_path = try std.fmt.allocPrint(temp, "{s}/{s}/{s}", .{ project_root, surface.path, file.relative_path });
    defer temp.free(file_path);

    if (file.suffix_violation) {
        const suffixes_formatted = try formatStringSlice(temp, surface.suffixes);
        defer temp.free(suffixes_formatted);
        try reportFinding(
            finding_allocator,
            findings,
            file_path,
            1,
            try std.fmt.allocPrint(finding_allocator, "file '{s}' in surface '{s}' does not match any legal suffix (allowed: {s})", .{ file.basename, surface.name, suffixes_formatted }),
            "cosmetic",
        );
    }

    if (!structural) return;
    if (!std.mem.endsWith(u8, file.basename, ".ts")) return;

    const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, temp, .limited(1024 * 1024)) catch return;

    const imports = try extractImports(temp, content);
    const innate = isInnateMember(surface, file.basename);
    for (imports) |import_path| {
        const resolved_path = (try paths.resolveRelative(temp, file_path, import_path)) orelse continue;
        const target_surface = cfg.owningSurface(resolved_path) orelse continue;

        if (!cfg.canImport(surface.name, target_surface.name) and !std.mem.eql(u8, surface.name, target_surface.name)) {
            try reportFinding(
                finding_allocator,
                findings,
                file_path,
                0,
                try std.fmt.allocPrint(finding_allocator, "surface '{s}' (dagOrder {d}) importing from '{s}' (dagOrder {d}) -- '{s}' is not in '{s}'s allowedImports", .{ surface.name, surface.dagOrder, target_surface.name, target_surface.dagOrder, target_surface.name, surface.name }),
                "structural",
            );
        }

        if (innate and target_surface.dagOrder > surface.dagOrder) {
            try reportFinding(
                finding_allocator,
                findings,
                file_path,
                1,
                try std.fmt.allocPrint(finding_allocator, "innate member '{s}' in surface '{s}' (dagOrder {d}) imports from deeper surface '{s}' (dagOrder {d}) -- lift this type to the shallowest common ancestor", .{ file.basename, surface.name, surface.dagOrder, target_surface.name, target_surface.dagOrder }),
                "structural",
            );
        }
    }
}

/// append a finding, taking ownership of `message` and copying `file_path` into
/// the finding's allocator
fn reportFinding(
    allocator: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    file_path: []const u8,
    line: u32,
    message: []u8,
    layer: []const u8,
) !void {
    errdefer allocator.free(message);
    const file = try allocator.dupe(u8, file_path);

    findings.append(allocator, .{
        .file = file,
        .line = line,
        .message = message,
        .layer = layer,
    }) catch |err| {
        allocator.free(file);
        return err;
    };
}

/// the batch one surface's files are checked through. every index is claimed by
/// exactly one worker, so a result slot has a single writer and the merge needs
/// no lock. findings are built with the thread-safe allocator and copied into the
/// caller's at the merge, which is the ownership contract the sequential path had
const SurfaceBatch = struct {
    io: std.Io,
    cfg: *const config.Config,
    project_root: []const u8,
    surface: config.Surface,
    structural: bool,
    files: []const SurfaceFile,
    results: []std.ArrayList(Finding),
    failures: []?anyerror,
    next: std.atomic.Value(usize),
};

/// the most pre-pass threads a run will start
///
/// the pre-pass runs beside the lint scan, which already takes every core the
/// machine has, so its threads are contention rather than throughput: measured on
/// a 14-core box, 8 workers cost 1.15x against 2, and 1 worker is 7% worse than 2
/// because the reads then serialise behind each other. the work is mostly reading
/// a file and looking for imports, which one or two threads keep in flight while
/// the scan keeps the cores
const max_prepass_workers = 2;

/// below this a surface's whole pre-pass is shorter than the threads cost to
/// start, so nothing is spawned
const parallel_min_files = 64;

/// the allocator findings are built with on both sides of the merge
const shared_finding_allocator = std.heap.smp_allocator;

fn surfaceWorker(batch: *SurfaceBatch, arena: *std.heap.ArenaAllocator) void {
    while (true) {
        const index = batch.next.fetchAdd(1, .monotonic);
        if (index >= batch.files.len) return;

        _ = arena.reset(.retain_capacity);

        const temp = arena.allocator();
        var local: std.ArrayList(Finding) = .empty;
        if (checkSurfaceFile(temp, shared_finding_allocator, batch.io, batch.cfg, batch.project_root, batch.surface, batch.files[index], batch.structural, &local)) |_| {
            batch.results[index] = local;
        } else |err| {
            batch.failures[index] = err;
        }
    }
}

/// run every enabled check against one surface directory: one walk to collect its
/// files, then a flat queue over them. the walk and the merge are both in walk
/// order, so the output does not depend on how many threads ran
fn checkSurface(io: std.Io,
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    project_root: []const u8,
    surface: config.Surface,
    findings: *std.ArrayList(Finding),
) !void {
    const cosmetic = cfg.layers.cosmetic;
    const structural = cfg.layers.structural;
    if (!cosmetic and !structural) return;

    const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, surface.path });
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        // a surface that names a directory the project does not have is a config
        // typo that disables the whole surface in silence, which is the one
        // failure a lint gate must not have
        if (structural and err == error.FileNotFound) {
            const msg = try std.fmt.allocPrint(allocator, "surface '{s}' names the directory {s}/, which does not exist; create it or drop the surface from architecture.config.json", .{ surface.name, surface.path });
            try reportFinding(allocator, findings, dir_path, 0, msg, "structural");
        }
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var files: std.ArrayList(SurfaceFile) = .empty;
    defer {
        for (files.items) |file| {
            allocator.free(file.relative_path);
            allocator.free(file.basename);
        }
        files.deinit(allocator);
    }

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try files.append(allocator, .{
            .relative_path = try allocator.dupe(u8, entry.path),
            .basename = try allocator.dupe(u8, entry.basename),
            .suffix_violation = cosmetic and !matchesSurfaceName(surface, entry.basename),
        });
    }

    if (files.items.len == 0) {
        if (structural) try reportSingleton(allocator, findings, project_root, surface, 0);
        return;
    }

    const available_cores = std.Thread.getCpuCount() catch 1;
    const worker_count = @min(available_cores, max_prepass_workers);
    if (files.items.len < parallel_min_files or worker_count < 2) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        for (files.items) |file| {
            try checkSurfaceFile(arena.allocator(), allocator, io, cfg, project_root, surface, file, structural, findings);
            _ = arena.reset(.retain_capacity);
        }
        if (structural) try reportSingleton(allocator, findings, project_root, surface, files.items.len);
        return;
    }

    const results = try allocator.alloc(std.ArrayList(Finding), files.items.len);
    defer allocator.free(results);
    const failures = try allocator.alloc(?anyerror, files.items.len);
    defer allocator.free(failures);
    for (results) |*result| result.* = .empty;
    @memset(failures, null);

    var batch = SurfaceBatch{
        .io = io,
        .cfg = cfg,
        .project_root = project_root,
        .surface = surface,
        .structural = structural,
        .files = files.items,
        .results = results,
        .failures = failures,
        .next = .init(0),
    };

    var arenas: [max_prepass_workers]std.heap.ArenaAllocator = undefined;
    for (0..worker_count) |worker| arenas[worker] = std.heap.ArenaAllocator.init(shared_finding_allocator);
    defer for (0..worker_count) |worker| arenas[worker].deinit();

    var threads: [max_prepass_workers]std.Thread = undefined;
    var spawned: usize = 0;
    for (0..worker_count) |worker| {
        threads[worker] = std.Thread.spawn(.{}, surfaceWorker, .{ &batch, &arenas[worker] }) catch break;
        spawned += 1;
    }
    for (threads[0..spawned]) |thread| thread.join();
    // drains the queue when no thread could start, and any item a partial spawn
    // left behind. worker zero is finished either way, so its arena is free
    surfaceWorker(&batch, &arenas[0]);

    var failed: ?anyerror = null;
    for (results, failures) |result, failure| {
        if (failure) |err| {
            if (failed == null) failed = err;
        }
        for (result.items) |finding| {
            if (failed == null) {
                try findings.append(allocator, .{
                    .file = try allocator.dupe(u8, finding.file),
                    .line = finding.line,
                    .message = try allocator.dupe(u8, finding.message),
                    .layer = finding.layer,
                });
            }
            shared_finding_allocator.free(finding.file);
            shared_finding_allocator.free(finding.message);
        }
        var owned = result;
        owned.deinit(shared_finding_allocator);
    }
    if (failed) |err| return err;
    if (structural) try reportSingleton(allocator, findings, project_root, surface, files.items.len);
}

/// the leaf-node structural finding, emitted after a surface's files so the
/// output keeps the order the sequential walker produced
fn reportSingleton(
    allocator: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    project_root: []const u8,
    surface: config.Surface,
    file_count: usize,
) !void {
    if (file_count > 1) return;

    const dir_name_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, surface.path });
    const msg = try std.fmt.allocPrint(allocator, "surface '{s}' contains only {d} file(s), a set of 1 is a leaf node that shouldn't carry folder overhead; consider lifting or expanding", .{ surface.name, file_count });
    try findings.append(allocator, .{
        .file = dir_name_path,
        .line = 0,
        .message = msg,
        .layer = "structural",
    });
}

/// flag centralized config/, types/, or models/ directories
fn checkCentralizedDirs(io: std.Io, 
    allocator: std.mem.Allocator,
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
                const msg = try std.fmt.allocPrint(allocator, "centralized '{s}/' directory detected, config, types, and models must be co-located with consumers, not centralized", .{dir_name});
                try findings.append(allocator, .{
                    .file = dir_path,
                    .line = 1,
                    .message = msg,
                    .layer = "cosmetic",
                });
                break;
            }
        }
    }
}

/// extract relative import paths from a TypeScript source file
/// handles single/multi-line static imports, dynamic import(), and side-effect imports
/// every relative import path in `content`
///
/// the prefixes all start with `f` or `i`, so the scan hops between those two
/// bytes instead of asking six `mem.eql` calls about every byte of the file. on
/// a 3KB source the old form spent ~96k instructions per file here, which is
/// most of the pre-pass's cost now that the pre-pass runs beside the scan
fn extractImports(allocator: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var imports: std.ArrayList([]const u8) = .empty;

    var pos: usize = 0;
    while (std.mem.indexOfAnyPos(u8, content, pos, "fi")) |found| {
        // the byte the old scan examined next, whether or not this one matched
        pos = found + 1;

        const prefix = matchImportPrefix(content[found..]) orelse continue;
        const path_start = found + prefix.len;
        if (path_start >= content.len) continue;

        const quote_char = prefix[prefix.len - 1];
        const path_end = findClosingQuote(content, path_start, quote_char) orelse continue;
        const import_path = content[path_start..path_end];

        // only track relative imports
        if (std.mem.startsWith(u8, import_path, "./") or std.mem.startsWith(u8, import_path, "../")) {
            try imports.append(allocator, try allocator.dupe(u8, import_path));
        }

        pos = path_start + 1;
    }

    return imports.toOwnedSlice(allocator);
}

/// the import prefix `rest` starts with, or null when it starts with neither
fn matchImportPrefix(rest: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "from \"", "from '", "import(\"", "import('", "import \"", "import '" };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, rest, prefix)) return prefix;
    }
    return null;
}

/// find the end of a quoted string, handling backslash escapes
/// `start` is the first character after the opening quote, so the opening quote
/// itself is never matched as the closer
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

/// join `[]const []const u8` into a comma-separated string, e.g. `.util.ts, .service.ts`
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
    // `start` is the first character after the opening quote, which is how
    // extractImports calls it
    const content = "hello 'world'";
    const pos = findClosingQuote(content, 7, '\'').?;
    try testing.expectEqual(@as(usize, 12), pos);
}

test "findClosingQuote handles backslash escapes" {
    const content = "'hello\\'world'";
    const pos = findClosingQuote(content, 1, '\'').?;
    try testing.expectEqual(@as(usize, 13), pos);
}

/// surfaces covering both shapes the resolver has to handle: a single-root tree
/// (lib, src/db, src/services), a root-level program (tools), and paths carrying
/// their own prefix segment (apps/web, packages/core)
var test_surfaces = [_]config.Surface{
    .{ .name = "lib", .path = "lib", .depth = 0, .dagOrder = 0, .suffixes = &.{".ts"} },
    .{ .name = "tools", .path = "tools", .depth = 0, .dagOrder = 1, .suffixes = &.{".ts"} },
    .{ .name = "db", .path = "src/db", .depth = 1, .dagOrder = 2, .suffixes = &.{".repo.ts"} },
    .{ .name = "services", .path = "src/services", .depth = 1, .dagOrder = 3, .suffixes = &.{".service.ts"} },
    .{ .name = "web", .path = "apps/web", .depth = 1, .dagOrder = 4, .suffixes = &.{".ts"} },
    .{ .name = "core", .path = "packages/core", .depth = 1, .dagOrder = 5, .suffixes = &.{".ts"} },
};

fn testConfig() config.Config {
    return .{ .surfaces = &test_surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
}

test "owningSurface matches a surface path on segment boundaries only" {
    const cfg = testConfig();
    try testing.expect(cfg.owningSurface("src/db/x.repo.ts") != null);
    try testing.expectEqualStrings("db", cfg.owningSurface("src/db/x.repo.ts").?.name);
    // `src/db-extra` is a different directory that merely shares a text prefix
    try testing.expect(cfg.owningSurface("src/db-extra/x.repo.ts") == null);
}

test "owningSurface keeps the longest match for nested surface paths" {
    var surfaces = [_]config.Surface{
        .{ .name = "web", .path = "apps/web", .depth = 1, .dagOrder = 1, .suffixes = &.{".ts"} },
        .{ .name = "web-store", .path = "apps/web/store", .depth = 2, .dagOrder = 2, .suffixes = &.{".ts"} },
    };
    const cfg = config.Config{ .surfaces = &surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };

    try testing.expectEqualStrings("web-store", cfg.owningSurface("apps/web/store/cart.ts").?.name);
    try testing.expectEqualStrings("web", cfg.owningSurface("apps/web/page.ts").?.name);
}

test "owningSurface matches the surface path itself" {
    const cfg = testConfig();
    try testing.expectEqualStrings("lib", cfg.owningSurface("lib").?.name);
}

test "a root-level surface's cross-tree import reaches the firewall" {
    // the regression this pair guards: `../src/db/...` used to fall out of the
    // resolver at its first segment (`src` is not a surface name) and never
    // reached canImport at all, so a root-level program importing into src/ was
    // unpoliced
    const allocator = testing.allocator;
    const cfg = testConfig();
    const resolved = (try paths.resolveRelative(allocator, "./tools/probe.smoke.ts", "../src/db/x.repo.ts")).?;
    defer allocator.free(resolved);

    const target = cfg.owningSurface(resolved).?;
    try testing.expectEqualStrings("db", target.name);
    // tools sits at dagOrder 1 and db at 2, so this is a violation
    try testing.expect(!cfg.canImport("tools", target.name));
}

test "a same-surface import resolves and is allowed" {
    const allocator = testing.allocator;
    const cfg = testConfig();
    const resolved = (try paths.resolveRelative(allocator, "./src/services/nested/x.service.ts", "../y.service.ts")).?;
    defer allocator.free(resolved);

    try testing.expectEqualStrings("src/services/y.service.ts", resolved);
    try testing.expectEqualStrings("services", cfg.owningSurface(resolved).?.name);
}
