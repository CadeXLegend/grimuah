const std = @import("std");
const config = @import("config.zig");
const ir = @import("ir.zig");
const ts = @import("lang/ts.zig");
const rules = @import("rules.zig");
const scope = @import("scope.zig");

/// the lint engine: discovery, the per-file front-end, rule dispatch, findings
///
/// a file is read once. the token stream is always built, because it is the cheap
/// half of the front-end and most rules read it; the tree is built only when an
/// enabled rule declares `syntax = .ir`, because the parse costs more than the
/// tokenise (measured: 1243ms against 734ms for 5000 files)
///
/// `src/lint.zig` is the token-level engine this one was moved out of. it is kept
/// as the differential oracle: `.auto/rule-parity.sh` runs both over the bench
/// repos and fails on any difference in (line, layer, severity, message)

pub const Finding = rules.Finding;
pub const Severity = rules.Severity;

/// the most lint threads a run will start. the work is per file and memory-bound,
/// so past the machine's physical core count the workers contend for the same
/// cores instead of adding throughput: 8 was half this box's 14 cores and left
/// 1.30x on the table, while 16 matches them. the ceiling also keeps a check on a
/// 64-core server from starting 64 threads for a few hundred milliseconds of work
const max_lint_workers = 16;

/// below this a repo's whole scan is shorter than the threads cost to start, so
/// the run stays on one core. the front-end costs ~0.4ms per file, so 64 files is
/// ~25ms of work against a few ms of spawning
const parallel_min_files = 64;

/// scan every lintable source file under `project_root` and return the findings
///
/// `hygiene` runs the native equivalent of biome's built-in ruleset. it is off
/// only under `--biome`, where biome's own ruleset is the one that runs
///
/// the front-end is per file and shares nothing, so a repo with work to spread
/// runs it on several cores. findings are merged in walk order, which is the
/// order the single-core path produces, so the output does not depend on the
/// machine
pub fn runAll(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    project_root: []const u8,
    hygiene: bool,
) ![]Finding {
    var findings: std.ArrayList(Finding) = .empty;
    errdefer freeFindings(allocator, findings.items);

    const paths = try collectPaths(io, allocator, cfg, project_root);
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    const available_cores = std.Thread.getCpuCount() catch 1;
    const worker_count = @min(available_cores, max_lint_workers);

    if (paths.len < parallel_min_files or worker_count < 2) {
        for (paths) |path| try scanFile(io, allocator, cfg, &findings, path, project_root, hygiene);
        return findings.toOwnedSlice(allocator);
    }

    try lintInParallel(io, allocator, cfg, &findings, paths, project_root, hygiene, worker_count);
    return findings.toOwnedSlice(allocator);
}

pub fn freeFindings(allocator: std.mem.Allocator, findings: []Finding) void {
    for (findings) |finding| {
        allocator.free(finding.path);
        allocator.free(finding.message);
    }
    allocator.free(findings);
}

/// the lint scope is the config's source roots, so the walk prunes every
/// directory that cannot lead to one and never visits build output, agent scratch
/// directories or vendored trees. symlinks are never followed: the bench repos
/// carry node_modules as a symlink and following it would walk the whole install
///
/// the paths come back in walk order, which is what the merge order is built on
fn collectPaths(io: std.Io, allocator: std.mem.Allocator, cfg: *const config.Config, project_root: []const u8) ![][]u8 {
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    var dir = std.Io.Dir.cwd().openDir(io, project_root, .{ .iterate = true }) catch return paths.toOwnedSlice(allocator);
    defer dir.close(io);

    try collectDir(io, allocator, cfg, &paths, dir, "", 0);
    return paths.toOwnedSlice(allocator);
}

fn collectDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    paths: *std.ArrayList([]u8),
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    depth: u32,
) !void {
    if (depth > 32) return;

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const rel = try std.fmt.bufPrint(&path_buf, "{s}{s}", .{ rel_prefix, entry.name });

        switch (entry.kind) {
            .directory => {
                if (std.mem.eql(u8, entry.name, "node_modules")) continue;
                if (std.mem.eql(u8, entry.name, ".git")) continue;
                if (!cfg.mayContainLintedFile(rel)) continue;

                var child = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer child.close(io);

                var child_prefix_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const child_prefix = try std.fmt.bufPrint(&child_prefix_buf, "{s}/", .{rel});
                try collectDir(io, allocator, cfg, paths, child, child_prefix, depth + 1);
            },
            .file => {
                if (!isLintableSource(entry.name)) continue;
                if (!cfg.lintsFile(rel)) continue;
                try paths.append(allocator, try allocator.dupe(u8, rel));
            },
            else => {},
        }
    }
}

/// the shared work queue. every index is claimed by exactly one worker, so a
/// result slot and its failure slot need no lock, and the result list itself is
/// built with the thread-safe allocator the merge frees from
const Batch = struct {
    io: std.Io,
    project_root: []const u8,
    cfg: *const config.Config,
    hygiene: bool,
    paths: []const []const u8,
    results: []std.ArrayList(Finding),
    failures: []?anyerror,
    next: std.atomic.Value(usize),
};

/// the allocator findings are built with, on both sides of the merge: the worker
/// that reports one and the run that hands it to the caller
const shared_finding_allocator = std.heap.smp_allocator;

fn lintWorker(batch: *Batch, arena: *std.heap.ArenaAllocator) void {
    while (true) {
        const index = batch.next.fetchAdd(1, .monotonic);
        if (index >= batch.paths.len) return;

        // the front-end's memory is the worker's own and is reused for the next
        // file; `retain_capacity` keeps the pages so a worker does not re-map a
        // tree-sized allocation per file
        _ = arena.reset(.retain_capacity);

        const content = readSource(batch.io, arena.allocator(), batch.project_root, batch.paths[index]);
        var local: std.ArrayList(Finding) = .empty;
        if (lintContent(arena.allocator(), shared_finding_allocator, batch.cfg, &local, batch.paths[index], content, batch.hygiene, .reclaimed)) |_| {
            batch.results[index] = local;
        } else |err| {
            batch.failures[index] = err;
        }
    }
}

/// lint the paths across `worker_count` threads. the reads happen on the worker
/// that needs the bytes: `std.Io` is thread-safe, and leaving them on the calling
/// thread made the reads the serial part of the run
fn lintInParallel(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    findings: *std.ArrayList(Finding),
    paths: []const []const u8,
    project_root: []const u8,
    hygiene: bool,
    worker_count: usize,
) !void {
    const results = try allocator.alloc(std.ArrayList(Finding), paths.len);
    defer allocator.free(results);
    const failures = try allocator.alloc(?anyerror, paths.len);
    defer allocator.free(failures);
    for (results) |*result| result.* = .empty;
    @memset(failures, null);

    var batch = Batch{
        .io = io,
        .project_root = project_root,
        .cfg = cfg,
        .hygiene = hygiene,
        .paths = paths,
        .results = results,
        .failures = failures,
        .next = .init(0),
    };

    var arenas: [max_lint_workers]std.heap.ArenaAllocator = undefined;
    for (0..worker_count) |worker| arenas[worker] = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer for (0..worker_count) |worker| arenas[worker].deinit();

    var threads: [max_lint_workers]std.Thread = undefined;
    var spawned: usize = 0;
    for (0..worker_count) |worker| {
        threads[worker] = std.Thread.spawn(.{}, lintWorker, .{ &batch, &arenas[worker] }) catch break;
        spawned += 1;
    }
    for (threads[0..spawned]) |thread| thread.join();
    // drains the queue when no thread could start, and any item a partial spawn
    // left behind. worker zero is finished either way, so its arena is free
    lintWorker(&batch, &arenas[0]);

    var failed: ?anyerror = null;
    for (results, failures) |result, failure| {
        if (failure) |err| {
            if (failed == null) failed = err;
        }
        for (result.items) |finding| {
            if (failed == null) {
                try findings.append(allocator, .{
                    .path = try allocator.dupe(u8, finding.path),
                    .line = finding.line,
                    .message = try allocator.dupe(u8, finding.message),
                    .layer = finding.layer,
                    .severity = finding.severity,
                });
            }
            shared_finding_allocator.free(finding.path);
            shared_finding_allocator.free(finding.message);
        }
        var owned = result;
        owned.deinit(shared_finding_allocator);
    }
    if (failed) |err| return err;
}

/// the file's bytes, or an empty slice when it cannot be read. an unreadable
/// file produces no finding, which is what a truncated read would also do
fn readSource(io: std.Io, scratch: std.mem.Allocator, project_root: []const u8, path: []const u8) []const u8 {
    const full_path = std.fmt.allocPrint(scratch, "{s}/{s}", .{ project_root, path }) catch return "";
    return std.Io.Dir.cwd().readFileAlloc(io, full_path, scratch, .limited(1 << 21)) catch "";
}

fn isLintableSource(name: []const u8) bool {
    const extensions = [_][]const u8{ ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs" };
    for (extensions) |extension| {
        if (std.mem.endsWith(u8, name, extension)) return true;
    }
    return false;
}

/// every live pattern needs one of these in the source, so a file without any of
/// them cannot produce a diagnostic and never needs the front-end. this may only
/// *over*-include: `.auto/native-diff.sh` proves over the bench repos, sleepy and
/// the committed corpus that no file it skips was carrying a finding. every
/// needle is the literal a pattern matches, so keep it in step with the rules
fn maybeTrigger(content: []const u8) bool {
    if (containsWord(content, "null")) return true;
    if (containsWord(content, "let")) return true;
    if (containsWord(content, "switch")) return true;
    if (std.mem.indexOf(u8, content, "\u{2014}") != null) return true;
    if (containsWord(content, "for")) return true;
    if (containsWord(content, "as")) return true;
    if (containsWord(content, "throw")) return true;
    if (containsWord(content, "catch")) return true;
    if (std.mem.indexOf(u8, content, "==") != null) return true;
    return containsExportClause(content);
}

/// `word` bounded by non-identifier bytes, so `class` does not answer for `as`
fn containsWord(content: []const u8, word: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, word)) |found| {
        pos = found + 1;
        if (found > 0 and isIdentifierContinue(content[found - 1])) continue;
        const after = found + word.len;
        if (after < content.len and isIdentifierContinue(content[after])) continue;
        return true;
    }
    return false;
}

/// `export` followed by whitespace or comments then `{`, the shape the re-export
/// rule needs. `export type {` and `export * from` do not answer here, which can
/// only cost a file that has no re-export to find
fn containsExportClause(content: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, "export")) |found| {
        pos = found + 1;
        if (found > 0 and isIdentifierContinue(content[found - 1])) continue;

        var i = found + "export".len;
        if (i < content.len and isIdentifierContinue(content[i])) continue;

        while (i < content.len) {
            const char = content[i];
            if (char == ' ' or char == '\t' or char == '\r' or char == '\n') {
                i += 1;
                continue;
            }
            if (char == '/' and i + 1 < content.len and content[i + 1] == '/') {
                i += 2;
                while (i < content.len and content[i] != '\n') i += 1;
                continue;
            }
            if (char == '/' and i + 1 < content.len and content[i + 1] == '*') {
                i += 2;
                while (i + 1 < content.len and !(content[i] == '*' and content[i + 1] == '/')) i += 1;
                i = @min(i + 2, content.len);
                continue;
            }
            break;
        }
        if (i < content.len and content[i] == '{') return true;
    }
    return false;
}

fn isIdentifierContinue(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_' or char == '$';
}

fn scanFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    findings: *std.ArrayList(Finding),
    rel_path: []const u8,
    project_root: []const u8,
    hygiene: bool,
) !void {
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, rel_path });
    defer allocator.free(full_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .limited(1 << 21)) catch return;
    defer allocator.free(content);

    // the word-boundary pre-test can only rule out a file that no live rule's
    // literal occurs in. a hygiene rule matches a declaration, and a declaration
    // can be named anything, so with the hygiene layer on there is no file to
    // skip and the test is not worth the scan
    if (!rules.lintsEveryFile(cfg, hygiene) and !maybeTrigger(content)) return;

    try lintContent(allocator, allocator, cfg, findings, rel_path, content, hygiene, .owned);
}

/// whether the front-end gives back the memory it takes
///
/// the parallel scan hands the front-end a region it resets after every file, so
/// freeing a token stream, a tree or a scope table there reclaims nothing while
/// still walking every block the file produced and poisoning each one on the way
/// out. a caller that owns its allocator says `owned`, so a caller that forgets
/// is a leak the unit tests report rather than a silent one
pub const Teardown = enum { owned, reclaimed };

/// tokenise `content`, parse it when a rule needs the tree, and run the rules
///
/// two allocators because the halves have different lifetimes: the front-end's
/// token stream, tree and scope table are dropped when the file is done, while a
/// finding belongs to the run that reports it. the parallel path reuses one arena
/// for the first and builds the second on the shared allocator
pub fn lintContent(
    frontend_allocator: std.mem.Allocator,
    finding_allocator: std.mem.Allocator,
    cfg: *const config.Config,
    findings: *std.ArrayList(Finding),
    rel_path: []const u8,
    content: []const u8,
    hygiene: bool,
    teardown: Teardown,
) !void {
    var number_line: u32 = 1;
    const tokens = try ts.tokenize(frontend_allocator, content, &number_line);
    defer if (teardown == .owned) frontend_allocator.free(tokens);

    var parsed: ?ir.Module = null;
    defer if (teardown == .owned) {
        if (parsed) |*module| module.deinit();
    };
    if (rules.needsTree(cfg, hygiene)) {
        parsed = ts.parseTokens(frontend_allocator, content, tokens) catch null;
    }

    // every node in walk order, built once: seven consumers used to chase links
    // through the tree separately
    var walk: []ir.WalkEntry = &.{};
    defer if (teardown == .owned) frontend_allocator.free(walk);
    if (parsed) |*module| walk = try module.walkOrder(frontend_allocator);

    var scopes: ?scope.Table = null;
    defer if (teardown == .owned) {
        if (scopes) |*table| table.deinit();
    };
    if (hygiene) {
        if (parsed) |*module| scopes = scope.analyze(frontend_allocator, module, tokens, walk) catch null;
    }

    var context = rules.Context{
        .allocator = finding_allocator,
        .cfg = cfg,
        .findings = findings,
        .path = rel_path,
        .source = content,
        .tokens = tokens,
        .module = if (parsed) |*module| module else null,
        .scopes = if (scopes) |*table| table else null,
        .walk = walk,
        .hygiene = hygiene,
    };
    try rules.run(&context);
}
