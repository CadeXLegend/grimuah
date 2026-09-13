const std = @import("std");
const config = @import("config.zig");
const ir = @import("ir.zig");
// `paths_mod` rather than `paths`, which four functions in this file use for a
// local name
const paths_mod = @import("paths.zig");
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
    /// the file this came from, borrowed from the run's own path list. it is empty
    /// only for a file the run skipped before reading, which contributes nothing
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

    try mergeRun(allocator, &findings, contributions, cfg, hygiene);
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

    try mergeRun(allocator, &findings, contributions, cfg, hygiene);
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
///
/// the project's own indexes are built first, because a project rule's verdict
/// needs every file read: the declared return types a call-site rule tests against,
/// and the import graph a graph rule reads. a graph rule's own row is reached in
/// this walk, from the graph the merge built, so it lands beside the file's other
/// rows
fn mergeRun(
    allocator: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    contributions: []Contribution,
    cfg: *const config.Config,
    hygiene: bool,
) !void {
    var index = try DeclaredReturns.init(allocator, contributions);
    defer index.deinit();

    var graph: ?rules.ImportGraph = null;
    if (rules.needsImportGraph(cfg, hygiene)) graph = try buildImportGraph(allocator, contributions);
    defer if (graph) |*built| built.deinit();

    for (contributions, 0..) |*contribution, file| {
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
        if (graph) |*built| {
            try rules.resolveGraph(allocator, built, file, contribution.path, cfg, hygiene, findings);
        }
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
            for (contribution.project.declared_returns.items) |declared_return| try index.add(declared_return);
        }
        return index;
    }

    fn deinit(self: *DeclaredReturns) void {
        self.arena.deinit();
    }

    fn add(self: *DeclaredReturns, declared_return: typemodel.DeclaredReturn) !void {
        const arena = self.arena.allocator();
        // a repeated name leaks the second key into the arena, which the run frees
        // as a whole. narrowing that would need a lookup before the insert, and the
        // arena makes it not worth one
        const entry = try self.by_name.getOrPut(arena, try arena.dupe(u8, declared_return.name));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(arena, try arena.dupe(u8, declared_return.type_text));
    }

    /// the declared return types of one name, or null when no file declares it
    fn declaredTypesOf(self: *const DeclaredReturns, name: []const u8) ?[]const []const u8 {
        const declared = self.by_name.get(name) orelse return null;
        return declared.items;
    }
};

/// every static import statement one file makes, in statement order
///
/// a specifier can name a package, a file outside every source root, or a path the
/// run never read, and only the merge can tell which: the file itself knows only
/// what it wrote, and the run's own path set is not assembled until every file has
/// been read
fn collectImports(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    imports: *std.ArrayList(rules.ImportEdge),
) !void {
    var child = module.firstChildOf(module.root);
    while (child) |current| : (child = module.nextSiblingOf(current)) {
        if (module.kindOf(current) != .import_decl) continue;
        // the specifier points into the file's own memory, which the worker reuses
        // for the next file, so the run keeps its own copy. a statement that wrote no
        // specifier is left out where the specifiers are read, not here
        try imports.append(allocator, .{
            .specifier = try allocator.dupe(u8, module.nodeOf(current).name),
            .line = module.spanOf(current).line,
        });
    }
}

/// the run's import graph: every file's imports resolved against the files of the
/// run, and the strongly connected components of two or more, which are the cycles
///
/// a file can only be reached by a file of its own dagOrder, so the surface
/// firewall cannot see a cycle and the graph has to
///
/// resolution is the run's path set and nothing else, which is what makes an import
/// to a package or to a file outside every source root no edge at all. the three
/// candidates are the specifier itself, the specifier with `.ts`, and its `index.ts`
fn buildImportGraph(allocator: std.mem.Allocator, contributions: []const Contribution) !rules.ImportGraph {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const graph_allocator = arena.allocator();

    var by_path: std.StringHashMapUnmanaged(u32) = .empty;
    for (contributions, 0..) |contribution, file| {
        const key = try graph_allocator.dupe(u8, contribution.path);
        try by_path.put(graph_allocator, key, @intCast(file));
    }
    defer by_path.deinit(graph_allocator);

    const edges = try graph_allocator.alloc([]const rules.ResolvedEdge, contributions.len);
    for (contributions, 0..) |contribution, file| {
        edges[file] = try resolveEdges(graph_allocator, &by_path, contribution.path, contribution.project.imports.items);
    }

    // every allocation through the arena has to happen before the struct literal
    // copies it: the arena's state is a value, and a copy taken mid-literal misses
    // the buffers a later field allocated, so `deinit` would free only the first
    const cycle_of = try findCycles(graph_allocator, edges, contributions.len);
    return .{ .arena = arena, .edges = edges, .cycle_of = cycle_of };
}

/// every edge of one file that points at a file of the run
///
/// a specifier that names no file of the run, or that names the importing file
/// itself, is not an edge: a module cannot depend on itself, and a package or a
/// path outside the lint scope has nothing to point at
fn resolveEdges(
    allocator: std.mem.Allocator,
    by_path: *const std.StringHashMapUnmanaged(u32),
    from_path: []const u8,
    imports: []const rules.ImportEdge,
) ![]const rules.ResolvedEdge {
    var edges: std.ArrayList(rules.ResolvedEdge) = .empty;
    errdefer edges.deinit(allocator);

    for (imports) |import| {
        // only a relative specifier is read: a bare one names a package
        if (!std.mem.startsWith(u8, import.specifier, ".")) continue;
        const base = (try paths_mod.resolveRelative(allocator, from_path, import.specifier)) orelse continue;
        const target = targetOf(by_path, base, from_path) orelse continue;
        try edges.append(allocator, .{ .target = target, .line = import.line });
    }
    return edges.toOwnedSlice(allocator);
}

/// the file of the run a resolved specifier names, or null when it names none
///
/// `base`, `base.ts` and `base/index.ts` are tried in that order, and the import
/// is dropped when the path it names is the importing file: a specifier can walk a
/// module back to itself, which is not a dependency
fn targetOf(by_path: *const std.StringHashMapUnmanaged(u32), base: []const u8, from_path: []const u8) ?u32 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (target_candidates) |candidate| {
        const name = std.fmt.bufPrint(&buffer, "{s}{s}{s}", .{ base, candidate.suffix, candidate.extension }) catch return null;
        const file = by_path.get(name) orelse continue;
        if (std.mem.eql(u8, name, from_path)) return null;
        return file;
    }
    return null;
}

/// the names a relative specifier is tried against, in order: the path itself, the
/// path with the source extension, and the path's `index.ts`
const target_candidates = [_]struct { suffix: []const u8, extension: []const u8 }{
    .{ .suffix = "", .extension = "" },
    .{ .suffix = "", .extension = ".ts" },
    .{ .suffix = "/index", .extension = ".ts" },
};

/// label every file that sits in a cycle of two or more
///
/// tarjan's pass, with the recursion made explicit: a repository can hold more
/// files than a thread's stack can hold frames, and the graph is one index per
/// file, so the walk keeps its own stack. a component of one file is not a cycle
/// and keeps `rules.no_cycle`, so the label is the verdict a rule reports on
fn findCycles(allocator: std.mem.Allocator, edges: []const []const rules.ResolvedEdge, file_count: usize) ![]const u32 {
    const unvisited = std.math.maxInt(u32);

    const discovery = try allocator.alloc(u32, file_count);
    defer allocator.free(discovery);
    const low_link = try allocator.alloc(u32, file_count);
    defer allocator.free(low_link);
    const on_stack = try allocator.alloc(bool, file_count);
    defer allocator.free(on_stack);
    @memset(discovery, unvisited);
    @memset(on_stack, false);

    const cycle_of: []u32 = try allocator.alloc(u32, file_count);
    @memset(cycle_of, rules.no_cycle);

    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(allocator);
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(allocator);

    var next_discovery: u32 = 0;
    var next_cycle: u32 = 0;

    for (0..file_count) |start| {
        if (discovery[start] != unvisited) continue;

        try pushNode(allocator, &frames, &pending, discovery, low_link, on_stack, &next_discovery, @intCast(start));

        while (frames.items.len > 0) {
            const frame = &frames.items[frames.items.len - 1];
            const node = frame.node;
            const own_edges = edges[node];

            if (frame.cursor < own_edges.len) {
                const target = own_edges[frame.cursor].target;
                frame.cursor += 1;
                if (discovery[target] == unvisited) {
                    try pushNode(allocator, &frames, &pending, discovery, low_link, on_stack, &next_discovery, target);
                } else if (on_stack[target]) {
                    low_link[node] = @min(low_link[node], discovery[target]);
                }
                continue;
            }

            // every edge read, so this node's own component is decided
            if (low_link[node] == discovery[node]) {
                if (popComponent(&pending, on_stack, cycle_of, next_cycle, node)) next_cycle += 1;
            }
            _ = frames.pop();
            if (frames.items.len > 0) {
                const parent = frames.items[frames.items.len - 1].node;
                low_link[parent] = @min(low_link[parent], low_link[node]);
            }
        }
    }

    return cycle_of;
}

/// one node of the component walk, and how many of its edges are read
const Frame = struct {
    node: u32,
    cursor: usize,
};

fn pushNode(
    allocator: std.mem.Allocator,
    frames: *std.ArrayList(Frame),
    pending: *std.ArrayList(u32),
    discovery: []u32,
    low_link: []u32,
    on_stack: []bool,
    next_discovery: *u32,
    node: u32,
) !void {
    discovery[node] = next_discovery.*;
    low_link[node] = next_discovery.*;
    next_discovery.* += 1;
    try pending.append(allocator, node);
    on_stack[node] = true;
    try frames.append(allocator, .{ .node = node, .cursor = 0 });
}

/// pop one component off the walk's stack, labelling its files and returning
/// whether the component is a cycle
///
/// the root is the last file popped, so a component of one is exactly a first pop
/// that is the root, and its label is taken back: a single file is not a cycle and
/// must not read as one
fn popComponent(pending: *std.ArrayList(u32), on_stack: []bool, cycle_of: []u32, label: u32, root: u32) bool {
    var members: usize = 0;
    while (true) {
        const member = pending.pop() orelse break;
        on_stack[member] = false;
        cycle_of[member] = label;
        members += 1;
        if (member == root) break;
    }
    if (members == 1) cycle_of[root] = rules.no_cycle;
    return members > 1;
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

    // the imports this file contributes to the run's graph. a rule that judges a
    // file by what it links to needs every file's, and the run resolves them once
    // the scan is done
    if (rules.needsImportGraph(cfg, hygiene)) {
        if (parsed) |*module| try collectImports(finding_allocator, module, &contribution.project.imports);
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

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a component of one file is not a cycle, and a mutual pair is one component" {
    const allocator = std.testing.allocator;

    // 0 and 1 reach each other. 2 only points into that pair, 3 reaches 4 one way,
    // and 5 stands alone. 6 points into the pair too and then into its own cycle
    // with 7, which is the cross edge into an already finished component: reaching
    // the pair back would make 6 look like part of it and lose the cycle with 7
    const edges = [_][]const rules.ResolvedEdge{
        &.{.{ .target = 1, .line = 1 }},
        &.{.{ .target = 0, .line = 2 }},
        &.{.{ .target = 0, .line = 3 }},
        &.{.{ .target = 4, .line = 4 }},
        &.{},
        &.{},
        &.{ .{ .target = 0, .line = 6 }, .{ .target = 7, .line = 7 } },
        &.{.{ .target = 6, .line = 8 }},
    };
    const cycle_of = try findCycles(allocator, &edges, edges.len);
    defer allocator.free(cycle_of);

    try testing.expect(cycle_of[0] != rules.no_cycle);
    try testing.expectEqual(cycle_of[0], cycle_of[1]);
    try testing.expectEqual(rules.no_cycle, cycle_of[2]);
    try testing.expectEqual(rules.no_cycle, cycle_of[3]);
    try testing.expectEqual(rules.no_cycle, cycle_of[4]);
    try testing.expectEqual(rules.no_cycle, cycle_of[5]);
    try testing.expect(cycle_of[6] != rules.no_cycle);
    try testing.expectEqual(cycle_of[6], cycle_of[7]);
    // the two cycles are separate components, which is what makes a file's row its
    // own closing import rather than any import that lands on a cycle
    try testing.expect(cycle_of[6] != cycle_of[0]);
}

test "a specifier resolves by its path, and only a relative one is an edge" {
    const allocator = std.testing.allocator;

    var contributions = [_]Contribution{
        .{ .path = "src/db/a.repo.ts" },
        .{ .path = "src/db/b.repo.ts" },
        .{ .path = "src/db/nested/index.ts" },
        .{ .path = "src/db/c.repo.ts" },
    };
    defer for (&contributions) |*contribution| contribution.deinit(allocator);

    const sources = [_]struct { file: usize, specifier: []const u8, line: u32 }{
        // the path itself, with the extension
        .{ .file = 0, .specifier = "./b.repo.ts", .line = 1 },
        // a directory's `index.ts`
        .{ .file = 0, .specifier = "./nested", .line = 2 },
        // the path with the extension added
        .{ .file = 1, .specifier = "./a.repo.ts", .line = 3 },
        // a climb out of a nested directory, back to the file the first import
        // already reached
        .{ .file = 2, .specifier = "../a.repo.ts", .line = 4 },
        // a bare specifier names a package, and this one is the same directory's
        // file spelled without the `./` that would make it relative
        .{ .file = 3, .specifier = "@lib/helper", .line = 5 },
        .{ .file = 3, .specifier = "a.repo.ts", .line = 6 },
        // a path the run never read names nothing, and a module cannot depend on
        // itself
        .{ .file = 3, .specifier = "./missing.repo", .line = 7 },
        .{ .file = 3, .specifier = "./c.repo.ts", .line = 8 },
        .{ .file = 3, .specifier = "../../../outside/x.repo", .line = 9 },
    };
    for (sources) |source| {
        try contributions[source.file].project.imports.append(allocator, .{
            .specifier = try allocator.dupe(u8, source.specifier),
            .line = source.line,
        });
    }

    var graph = try buildImportGraph(allocator, &contributions);
    defer graph.deinit();

    try testing.expectEqual(@as(usize, 2), graph.edges[0].len);
    try testing.expectEqual(@as(u32, 1), graph.edges[0][0].target);
    try testing.expectEqual(@as(u32, 2), graph.edges[0][1].target);
    try testing.expectEqual(@as(u32, 0), graph.edges[1][0].target);
    try testing.expectEqual(@as(u32, 0), graph.edges[2][0].target);
    try testing.expectEqual(@as(usize, 0), graph.edges[3].len);

    // 0 and 1 import each other and 0 also imports 2, which imports 0 back, so all
    // three are one component. 3's specifiers resolved to nothing, so it stands
    // alone and keeps no label
    try testing.expectEqual(graph.cycle_of[0], graph.cycle_of[1]);
    try testing.expect(graph.cycle_of[0] != rules.no_cycle);
    try testing.expectEqual(graph.cycle_of[0], graph.cycle_of[2]);
    try testing.expectEqual(rules.no_cycle, graph.cycle_of[3]);
}
