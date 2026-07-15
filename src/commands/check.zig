const std = @import("std");
const config = @import("../config.zig");
const prepass = @import("../prepass.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    // load config from the current directory
    const parsed = config.load(io, allocator, "architecture.config.json") catch |err| {
        std.debug.print("error: could not load architecture.config.json: {s}\n", .{@errorName(err)});
        std.debug.print("run 'arch init' first to scaffold a project.\n", .{});
        return;
    };
    defer parsed.deinit();
    const cfg = parsed.value;

    // validate config
    config.validate(&cfg) catch |err| {
        std.debug.print("error: invalid architecture.config.json: {s}\n", .{@errorName(err)});
        return;
    };

    var exit_code: u8 = 0;
    var finding_count: u32 = 0;

    // run CLI pre-passes
    if (cfg.layers.cosmetic or cfg.layers.structural) {
        const findings = prepass.runAll(io, allocator, &cfg, ".") catch |err| {
            std.debug.print("error: pre-pass checks failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer {
            for (findings) |f| {
                allocator.free(f.file);
                allocator.free(f.message);
            }
            allocator.free(findings);
        }

        for (findings) |finding| {
            std.debug.print("{}\n", .{finding});
            finding_count += 1;
        }
    }

    // run biome lint as subprocess
    const biome_result = runBiomeLint(allocator, io);
    if (biome_result) |output| {
        defer allocator.free(output);
        if (output.len > 0) {
            std.debug.print("{s}", .{output});
            exit_code = 1;
        }
    } else |err| {
        std.debug.print("warning: could not run biome lint: {s}\n", .{@errorName(err)});
        std.debug.print("make sure biome is installed (npm install --save-dev @biomejs/biome)\n", .{});
    }

    if (finding_count > 0) exit_code = 1;

    if (exit_code == 0) {
        std.debug.print("arch check: clean\n", .{});
    } else {
        std.debug.print("arch check: {d} violation(s) found\n", .{finding_count});
    }

    if (exit_code != 0) std.process.exit(exit_code);
}

/// run biome lint and capture its output
fn runBiomeLint(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const argv = [_][]const u8{ "npx", "biome", "lint", ".", "--reporter=compact" };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
    });

    switch (result.term) {
        .exited => |code| {
            if (code == 0) return ""; // clean
            return result.stdout; // violations
        },
        else => return error.BiomeFailed,
    }
}
