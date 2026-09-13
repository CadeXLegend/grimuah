const std = @import("std");
const config = @import("config.zig");
const ir = @import("ir.zig");
const ts = @import("lang/ts.zig");
const typemodel = @import("lang/typemodel.zig");
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

/// one source of a run, for a caller that already holds it
pub const Source = struct {
    path: []const u8,
    content: []const u8,
};

/// what one file contributes to a run: the findings it produced, the return types
/// it declares, and the call sites its rules could not settle on their own
///
/// the engine keeps one per file, in path order, so a worker writes only its own
/// and the merge needs no lock. `project` stays empty unless an enabled rule
/// declared `needs_project`
pub const Contribution = struct {
    /// the file this came from, borrowed from the run's own path list
    path: []const u8 = "",
    findings: std.ArrayList(Finding) = .empty,
    project: rules.Project = .{},

    /// free everything, with the allocator the findings and the project were built
    /// on. every field is left empty, because a merge that empties a contribution
    /// as it reports it and a cleanup that frees whatever is left both run
    pub fn deinit(self: *Contribution, allocator: std.mem.Allocator) void {
        for (self.findings.items) |finding| {
            allocator.free(finding.path);
            allocator.free(finding.message);
        }
        self.findings.deinit(allocator);
        self.project.deinit(allocator);
        self.* = .{};
    }
};

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
/// `hygiene` runs the native equivalent of the built-in ruleset biome used to
/// provide. it is always on now, and it is a parameter only so the corpus tests
/// can isolate the architecture rules
///
/// the front-end is per file and shares nothing, so a repo with work to spread
/// runs it on several cores. every file's findings are collected into its own slot
/// first and merged in walk order afterwards, which is the order a single core
/// produces, so the output does not depend on the machine. the merge is also where
/// a rule that needs the whole project reaches its verdict, because that verdict
/// cannot be reached until the last file has been read
///
/// reads happen on the worker that needs the bytes: `std.Io` is thread-safe, and
/// leaving them on the calling thread made the reads the serial part of the run
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

    const contributions = try allocator.alloc(Contribution, paths.len);
    defer allocator.free(contributions);
    for (contributions) |*contribution| contribution.* = .{};
    errdefer for (contributions) |*contribution| contribution.deinit(shared_finding_allocator);

    const available_cores = std.Thread.getCpuCount() catch 1;
    const worker_count = @min(available_cores, max_lint_workers);

    var failure: ?anyerror = null;
    if (paths.len < parallel_min_files or worker_count < 2) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        for (paths, 0..) |path, index| {
            // the front-end's memory is this file's and is reused for the next,
            // the way a worker reuses its own
            _ = arena.reset(.retain_capacity);
            const content = readSource(io, arena.allocator(), project_root, path);
            // the word-boundary pre-test can only rule out a file that no live rule's
            // literal occurs in. a hygiene rule matches a declaration, and a declaration
            // can be named anything, so with the hygiene layer on there is no file to
            // skip and the test is not worth the scan
            if (!rules.lintsEveryFile(cfg, hygiene) and !maybeTrigger(content)) continue;

            lintContent(arena.allocator(), shared_finding_allocator, cfg, &contributions[index], path, content, hygiene, .reclaimed) catch |err| {
                failure = err;
                break;
            };
        }
    } else {
        failure = try lintInParallel(io, cfg, contributions, paths, project_root, hygiene, worker_count);
    }

    try mergeRun(allocator, &findings, contributions);
    if (failure) |err| return err;
    return findings.toOwnedSlice(allocator);
}

/// lint a project that is already in memory, as one run
///
/// production reads from disk, and this is the same run over sources a caller
/// holds: a rule that judges a call by how its callee is declared in another file
/// cannot be tested any other way, because its verdict needs two files at once
pub fn runSources(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    sources: []const Source,
    hygiene: bool,
) ![]Finding {
    var findings: std.ArrayList(Finding) = .empty;
    errdefer freeFindings(allocator, findings.items);

    const contributions = try allocator.alloc(Contribution, sources.len);
    defer allocator.free(contributions);
    for (contributions) |*contribution| contribution.* = .{};
    errdefer for (contributions) |*contribution| contribution.deinit(shared_finding_allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (sources, 0..) |source, index| {
        _ = arena.reset(.retain_capacity);
        try lintContent(arena.allocator(), shared_finding_allocator, cfg, &contributions[index], source.path, source.content, hygiene, .reclaimed);
    }

    try mergeRun(allocator, &findings, contributions);
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
    contributions: []Contribution,
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
        if (lintContent(arena.allocator(), shared_finding_allocator, batch.cfg, &batch.contributions[index], batch.paths[index], content, batch.hygiene, .reclaimed)) |_| {
        } else |err| {
            batch.failures[index] = err;
        }
    }
}

/// lint the paths across `worker_count` threads, filling each file's contribution,
/// and return the first failure. the merge is the caller's, because it happens
/// after every file has been read either way
fn lintInParallel(
    io: std.Io,
    cfg: *const config.Config,
    contributions: []Contribution,
    paths: []const []const u8,
    project_root: []const u8,
    hygiene: bool,
    worker_count: usize,
) !?anyerror {
    const failures = try shared_finding_allocator.alloc(?anyerror, paths.len);
    defer shared_finding_allocator.free(failures);
    @memset(failures, null);

    var batch = Batch{
        .io = io,
        .project_root = project_root,
        .cfg = cfg,
        .hygiene = hygiene,
        .paths = paths,
        .contributions = contributions,
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

    for (failures) |failure| {
        if (failure) |err| return err;
    }
    return null;
}

/// turn every file's contribution into the run's findings, in walk order
///
/// a file's deferred call sites follow that file's own findings, so the run still
/// reports a file's rows in one place. the rule table puts the project rules last,
/// which is the order those rows would have had if the rule could have decided on
/// its own
fn mergeRun(
    allocator: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    contributions: []Contribution,
) !void {
    var index = try DeclaredReturns.init(allocator, contributions);
    defer index.deinit();

    for (contributions) |*contribution| {
        for (contribution.findings.items) |finding| {
            try findings.append(allocator, .{
                .path = try allocator.dupe(u8, finding.path),
                .line = finding.line,
                .message = try allocator.dupe(u8, finding.message),
                .layer = finding.layer,
                .severity = finding.severity,
            });
        }

        try resolveDeferred(allocator, &index, contribution, findings);
        contribution.deinit(shared_finding_allocator);
    }
}

/// report the call sites one file deferred, now that every declaration is known
fn resolveDeferred(
    allocator: std.mem.Allocator,
    index: *const DeclaredReturns,
    contribution: *const Contribution,
    findings: *std.ArrayList(Finding),
) !void {
    for (contribution.project.deferred.items) |candidate| {
        // a name the project declares nowhere is not judged: the call may be a
        // builtin, a call to this file's own local, or a call through a shape the
        // reader does not model
        const declared = index.declaredTypesOf(candidate.name) orelse continue;

        var every_declaration_passes = true;
        for (declared) |declared_return| {
            if (!candidate.passes(declared_return)) {
                every_declaration_passes = false;
                break;
            }
        }
        if (!every_declaration_passes) continue;

        try findings.append(allocator, .{
            .path = try allocator.dupe(u8, contribution.path),
            .line = candidate.line,
            .message = try allocator.dupe(u8, candidate.message),
            .layer = candidate.layer.name(),
            .severity = candidate.severity,
        });
    }
}

/// every declared return type a run found, keyed by the name it is declared under
///
/// the project rules judge a call by how its callee is declared, and the
/// declaration can sit in any file, so the whole project is read before a verdict
/// is reached. a name declared more than once keeps every declaration, because a
/// call is reported only when all of them agree
///
/// the names and the texts are the index's own copies: a file's declarations are
/// freed as soon as that file's rows are reported, and the index outlives them
const DeclaredReturns = struct {
    arena: std.heap.ArenaAllocator,
    by_name: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,

    fn init(allocator: std.mem.Allocator, contributions: []const Contribution) !DeclaredReturns {
        var index = DeclaredReturns{ .arena = std.heap.ArenaAllocator.init(allocator) };
        errdefer index.deinit();

        for (contributions) |contribution| {
            for (contribution.project.declared_returns.items) |declared| try index.add(declared);
        }
        return index;
    }

    fn deinit(self: *DeclaredReturns) void {
        self.arena.deinit();
    }

    fn add(self: *DeclaredReturns, declared: typemodel.DeclaredReturn) !void {
        const arena = self.arena.allocator();
        // a repeated name leaks the second key into the arena, which the run frees
        // as a whole. narrowing that would need a lookup before the insert, and the
        // arena makes it not worth one
        const entry = try self.by_name.getOrPut(arena, try arena.dupe(u8, declared.name));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(arena, try arena.dupe(u8, declared.type_text));
    }

    /// the declared return types of one name, or null when no file declares it
    fn declaredTypesOf(self: *const DeclaredReturns, name: []const u8) ?[]const []const u8 {
        const declared = self.by_name.get(name) orelse return null;
        return declared.items;
    }
};

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
    contribution: *Contribution,
    rel_path: []const u8,
    content: []const u8,
    hygiene: bool,
    teardown: Teardown,
) !void {
    contribution.path = rel_path;

    var number_line: u32 = 1;
    const lexed = try ts.tokenizeAll(frontend_allocator, content, &number_line);
    const tokens = lexed.tokens;
    defer if (teardown == .owned) {
        frontend_allocator.free(tokens);
        frontend_allocator.free(lexed.jsx_names);
    };

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
        if (parsed) |*module| scopes = scope.analyze(frontend_allocator, module, tokens, lexed.jsx_names, walk) catch null;
    }

    // the return types this file contributes to the run's index. a rule that judges
    // a call by how its callee is declared needs them, and only a file the run
    // parses can contribute any
    const project_wanted = rules.needsProject(cfg, hygiene);
    if (project_wanted) {
        if (parsed) |*module| {
            try typemodel.declaredReturns(finding_allocator, tokens, module, content, &contribution.project.declared_returns);
        }
    }

    var context = rules.Context{
        .allocator = finding_allocator,
        .cfg = cfg,
        .findings = &contribution.findings,
        .path = rel_path,
        .source = content,
        .tokens = tokens,
        .module = if (parsed) |*module| module else null,
        .scopes = if (scopes) |*table| table else null,
        .walk = walk,
        .hygiene = hygiene,
        .project = if (project_wanted) &contribution.project else null,
    };
    try rules.run(&context);
}
