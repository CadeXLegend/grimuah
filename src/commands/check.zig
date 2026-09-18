const std = @import("std");
const config = @import("../config.zig");
const prepass = @import("../prepass.zig");
const engine = @import("../engine.zig");
const rules = @import("../rules.zig");

/// the pre-pass on its own thread while the engine takes the cores. the two
/// stages are independent, both walk the whole tree, and neither reads the
/// other's output, so overlapping them takes the smaller one off the critical
/// path. the arena is the thread's alone: the caller's allocator is not
/// thread-safe, and the findings are printed before the arena dies
const PrepassJob = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    root: []const u8,
    findings: []prepass.Finding = &.{},
    failure: ?anyerror = null,

    fn run(job: *PrepassJob) void {
        job.findings = prepass.runAll(job.io, job.allocator, job.cfg, job.root) catch |err| {
            job.failure = err;
            return;
        };
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    // load config from the current directory
    const parsed = config.load(io, allocator, "architecture.config.json") catch |err| {
        std.debug.print("error: could not load architecture.config.json: {s}\n", .{@errorName(err)});
        std.debug.print("run 'grimuah init' first to scaffold a project.\n", .{});
        return;
    };
    defer parsed.deinit();
    var cfg = parsed.value;

    // validate config
    config.validate(&cfg) catch |err| {
        std.debug.print("error: invalid architecture.config.json: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // match the rule names the config carries against the table once, so a name
    // the table does not have stops the run instead of leaving the rule it meant
    // to silence in place
    if (rules.resolveToggles(&cfg)) |unknown_name| {
        std.debug.print("Error: architecture.config.json names the rule '{s}', which grimuah has no rule for.\n", .{unknown_name});
        std.debug.print("Run 'grimuah rules' to list every name.\n", .{});
        std.process.exit(1);
    }

    var exit_code: u8 = 0;
    var finding_count: u32 = 0;

    // start the pre-pass before the engine, so the two stages share the wall clock
    const run_prepass = cfg.layers.cosmetic or cfg.layers.structural;
    var prepass_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer prepass_arena.deinit();
    var prepass_job = PrepassJob{ .io = io, .allocator = prepass_arena.allocator(), .cfg = &cfg, .root = "." };
    var prepass_thread: ?std.Thread = null;
    if (run_prepass) {
        prepass_thread = std.Thread.spawn(.{}, PrepassJob.run, .{&prepass_job}) catch null;
    }

    // enforce grimuah's own rules and the hygiene layer, all in-process
    var native_findings: []engine.Finding = &.{};
    native_findings = engine.runAll(io, allocator, &cfg, ".", true) catch |err| blk: {
        std.debug.print("error: native rule checks failed: {s}\n", .{@errorName(err)});
        break :blk &.{};
    };
    defer if (native_findings.len > 0) engine.freeFindings(allocator, native_findings);

    // the pre-pass is printed first, as it was when it ran first
    if (run_prepass) {
        if (prepass_thread) |thread| thread.join() else PrepassJob.run(&prepass_job);
        if (prepass_job.failure) |err| {
            std.debug.print("error: pre-pass checks failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        }

        for (prepass_job.findings) |finding| {
            const finding_formatted = try std.fmt.allocPrint(allocator, "{s}:{d}: [{s}] {s}", .{ finding.file, finding.line, finding.layer, finding.message });
            defer allocator.free(finding_formatted);
            std.debug.print("{s}\n", .{finding_formatted});
            finding_count += 1;
        }
    }

    // print every finding, warnings included. holding a warning back until
    // something else failed hides a real defect behind a project that is
    // otherwise clean, and a lint gate that reports less than it knows is the
    // one failure this engine is built to avoid. the exit code still turns on
    // errors alone
    for (native_findings) |finding| {
        const finding_formatted = try std.fmt.allocPrint(allocator, "{s}:{d}: [{s}] {s}", .{ finding.path, finding.line, finding.layer, finding.message });
        defer allocator.free(finding_formatted);
        std.debug.print("{s}\n", .{finding_formatted});
        if (finding.severity == .err) finding_count += 1;
    }
    if (finding_count > 0) exit_code = 1;

    if (exit_code == 0) {
        std.debug.print("grimuah check: clean\n", .{});
    } else {
        std.debug.print("grimuah check: {d} violation(s) found\n", .{finding_count});
    }

    if (exit_code != 0) std.process.exit(exit_code);
}
