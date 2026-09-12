const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const prepass = @import("../prepass.zig");
const gritql = @import("../gritql.zig");
const engine = @import("../engine.zig");

/// a spawned biome process plus the machinery to drain its pipes
/// initialized in place: the multi-reader holds pointers into reader_buffer
const BiomeProcess = struct {
    active: bool = false,
    child: std.process.Child = undefined,
    reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined,
    reader: std.Io.File.MultiReader = undefined,
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
};

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

pub fn run(allocator: std.mem.Allocator, io: std.Io, use_biome: bool) !void {
    // load config from the current directory
    const parsed = config.load(io, allocator, "architecture.config.json") catch |err| {
        std.debug.print("error: could not load architecture.config.json: {s}\n", .{@errorName(err)});
        std.debug.print("run 'grimuah init' first to scaffold a project.\n", .{});
        return;
    };
    defer parsed.deinit();
    const cfg = parsed.value;

    // validate config
    config.validate(&cfg) catch |err| {
        std.debug.print("error: invalid architecture.config.json: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // grimuah's own rules run natively, so biome only has to run its built-in
    // linter when it is asked for. that only holds when biome.json advertises
    // exactly the canonical rule set: `--skip=plugin` cannot skip a subset, and a
    // project that has plugins of its own must keep biome's plugin engine
    const canonical_rules = biomeConfigIsCanonical(io, allocator, &cfg);

    // `--biome` is the opt-in: the default path spawns nothing, and biome is
    // started first so its work overlaps the pre-passes when it does run
    var biome_process: BiomeProcess = .{};
    if (use_biome) {
        spawnBiome(&biome_process, allocator, io, canonical_rules) catch |err| {
            std.debug.print("warning: could not run biome lint: {s}\n", .{@errorName(err)});
            std.debug.print("make sure biome is installed (npm install --save-dev @biomejs/biome)\n", .{});
        };
    }

    var exit_code: u8 = 0;
    var finding_count: u32 = 0;
    var biome_reported = false;

    // start the pre-pass before the engine, so the two stages share the wall clock
    const run_prepass = cfg.layers.cosmetic or cfg.layers.structural;
    var prepass_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer prepass_arena.deinit();
    var prepass_job = PrepassJob{ .io = io, .allocator = prepass_arena.allocator(), .cfg = &cfg, .root = "." };
    var prepass_thread: ?std.Thread = null;
    if (run_prepass) {
        prepass_thread = std.Thread.spawn(.{}, PrepassJob.run, .{&prepass_job}) catch null;
    }

    // enforce grimuah's own rules in-process, plus the hygiene layer unless
    // biome is the one running its built-in ruleset
    var native_findings: []engine.Finding = &.{};
    native_findings = engine.runAll(io, allocator, &cfg, ".", !use_biome) catch |err| blk: {
        if (biome_process.active) biome_process.child.kill(io);
        std.debug.print("error: native rule checks failed: {s}\n", .{@errorName(err)});
        break :blk &.{};
    };
    defer if (native_findings.len > 0) engine.freeFindings(allocator, native_findings);

    // the pre-pass is printed first, as it was when it ran first
    if (run_prepass) {
        if (prepass_thread) |thread| thread.join() else PrepassJob.run(&prepass_job);
        if (prepass_job.failure) |err| {
            if (biome_process.active) biome_process.child.kill(io);
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

    // collect the biome output now that the pre-passes have finished
    if (biome_process.active) {
        if (collectBiome(&biome_process)) |output| {
            defer allocator.free(output);
            if (output.len > 0) {
                std.debug.print("{s}", .{output});
                exit_code = 1;
                biome_reported = true;
            }
        } else |err| {
            std.debug.print("warning: could not run biome lint: {s}\n", .{@errorName(err)});
        }
    }

    if (exit_code == 0) {
        std.debug.print("grimuah check: clean\n", .{});
    } else if (finding_count > 0) {
        std.debug.print("grimuah check: {d} violation(s) found\n", .{finding_count});
    } else if (biome_reported) {
        // biome's diagnostics are printed above but deliberately not counted: it
        // renders at most 20 by default, so any total grimuah derived from that
        // output would understate the real number
        std.debug.print("grimuah check: violations reported by biome (see diagnostics above)\n", .{});
    }

    if (exit_code != 0) std.process.exit(exit_code);
}

/// biome.json lists exactly grimuah's enabled rule files, so grimuah can skip
/// the plugin engine and enforce them natively. a project with its own plugins,
/// or one still on the legacy four-file layout, keeps biome's plugin engine
fn biomeConfigIsCanonical(io: std.Io, allocator: std.mem.Allocator, cfg: *const config.Config) bool {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, "biome.json", allocator, .limited(1 << 20)) catch return false;
    defer allocator.free(raw);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return false;
    defer parsed.deinit();

    const plugins = switch (parsed.value) {
        .object => |object| object.get("plugins") orelse return false,
        else => return false,
    };
    const entries = switch (plugins) {
        .array => |array| array.items,
        else => return false,
    };
    if (entries.len != gritql.countPlugins(cfg)) return false;

    // every entry must name a distinct enabled rule
    const seen = allocator.alloc(bool, gritql.rules.len) catch return false;
    defer allocator.free(seen);
    @memset(seen, false);

    for (entries) |entry| {
        const path = switch (entry) {
            .string => |string| string,
            else => return false,
        };
        var matched = false;
        for (gritql.rules, 0..) |rule, i| {
            if (seen[i] or !rule.layer.hasPlugin(cfg)) continue;
            var expected_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const expected = std.fmt.bufPrint(&expected_buf, ".grimuah-rules/{s}", .{rule.file}) catch return false;
            if (!std.mem.eql(u8, path, expected)) continue;
            seen[i] = true;
            matched = true;
            break;
        }
        if (!matched) return false;
    }
    return true;
}

/// path to a project-local biome shim, relative to the project root
const local_biome_relative = "node_modules/.bin/biome";

/// spawn biome, preferring its native binary (no node startup), then the
/// project shim, then a biome on PATH, then npx. `skip_plugins` drops biome's
/// plugin engine, which grimuah has already enforced natively
fn spawnBiome(process: *BiomeProcess, allocator: std.mem.Allocator, io: std.Io, skip_plugins: bool) !void {
    const native_path = try findNativeBiome(allocator, io);
    defer if (native_path) |path| allocator.free(path);
    const local_path = try findLocalBiome(allocator, io);
    defer if (local_path) |path| allocator.free(path);

    const candidates = [_]?[]const u8{ native_path, local_path, "biome", "npx" };
    for (candidates) |candidate| {
        const binary = candidate orelse continue;
        const spawned = if (skip_plugins)
            try trySpawn(process, allocator, io, &.{ binary, "lint", ".", "--skip=plugin" })
        else
            try trySpawn(process, allocator, io, &.{ binary, "lint", "." });
        if (spawned) return;
    }

    return error.BiomeNotFound;
}

/// spawn one candidate, returning false when the binary itself is unavailable
fn trySpawn(process: *BiomeProcess, allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !bool {
    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };

    process.* = .{
        .active = true,
        .child = child,
        .allocator = allocator,
        .io = io,
    };
    process.reader.init(allocator, io, process.reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    return true;
}

/// wait for biome and return its diagnostics, empty when clean
/// biome writes diagnostics to stderr and only the run summary to stdout
fn collectBiome(process: *BiomeProcess) ![]u8 {
    const allocator = process.allocator;
    const io = process.io;
    defer process.reader.deinit();
    defer process.child.kill(io);

    while (process.reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try process.reader.checkAnyError();

    const term = try process.child.wait(io);

    const stdout_slice = try process.reader.toOwnedSlice(0);
    const stderr_slice = try process.reader.toOwnedSlice(1);
    defer allocator.free(stdout_slice);
    defer allocator.free(stderr_slice);

    switch (term) {
        .exited => |code| {
            if (code == 0) return allocator.alloc(u8, 0);
            if (stderr_slice.len > 0) return allocator.dupe(u8, stderr_slice);
            return allocator.dupe(u8, stdout_slice);
        },
        else => return error.BiomeFailed,
    }
}

/// biome's platform-specific npm package name, null on unsupported targets
fn nativeBiomePackage() ?[]const u8 {
    const abi = builtin.target.abi;
    const arch = builtin.cpu.arch;
    return switch (builtin.os.tag) {
        .linux => if (abi.isMusl()) switch (arch) {
            .x86_64 => "cli-linux-x64-musl",
            .aarch64 => "cli-linux-arm64-musl",
            else => null,
        } else switch (arch) {
            .x86_64 => "cli-linux-x64",
            .aarch64 => "cli-linux-arm64",
            else => null,
        },
        .macos => switch (arch) {
            .x86_64 => "cli-darwin-x64",
            .aarch64 => "cli-darwin-arm64",
            else => null,
        },
        .windows => switch (arch) {
            .x86_64 => "cli-win32-x64",
            .aarch64 => "cli-win32-arm64",
            else => null,
        },
        else => null,
    };
}

/// the biome executable's filename inside its package
const native_biome_exe = if (builtin.os.tag == .windows) "biome.exe" else "biome";

/// find biome's native binary, skipping the node shim. handles hoisted installs
/// (npm/yarn/bun) and pnpm's virtual store. null when it can't be located
fn findNativeBiome(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const package = nativeBiomePackage() orelse return null;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    var dir_path: []const u8 = cwd;
    while (true) {
        const hoisted = try std.fs.path.join(allocator, &.{ dir_path, "node_modules", "@biomejs", package, native_biome_exe });
        if (isExecutable(io, hoisted)) return hoisted;
        allocator.free(hoisted);

        if (try findInPnpmStore(allocator, io, dir_path, package)) |found| return found;

        const parent = std.fs.path.dirname(dir_path) orelse return null;
        if (parent.len == 0 or std.mem.eql(u8, parent, dir_path)) return null;
        dir_path = parent;
    }
}

/// look for biome's native binary inside pnpm's .pnpm virtual store
fn findInPnpmStore(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, package: []const u8) !?[]u8 {
    const store_path = try std.fs.path.join(allocator, &.{ dir_path, "node_modules", ".pnpm" });
    defer allocator.free(store_path);

    var store = std.Io.Dir.openDirAbsolute(io, store_path, .{ .iterate = true }) catch return null;
    defer store.close(io);

    var prefix_buffer: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buffer, "@biomejs+{s}@", .{package});

    var iterator = store.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;

        const candidate = try std.fs.path.join(allocator, &.{ store_path, entry.name, "node_modules", "@biomejs", package, native_biome_exe });
        if (isExecutable(io, candidate)) return candidate;
        allocator.free(candidate);
    }

    return null;
}

fn isExecutable(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch return false;
    return true;
}

/// find the project's locally installed biome shim, walking up from the current
/// directory so check still works when run from a subdirectory
fn findLocalBiome(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    var dir_path: []const u8 = cwd;
    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ dir_path, local_biome_relative });
        if (isExecutable(io, candidate)) return candidate;
        allocator.free(candidate);

        const parent = std.fs.path.dirname(dir_path) orelse return null;
        if (parent.len == 0 or std.mem.eql(u8, parent, dir_path)) return null;
        dir_path = parent;
    }
}
