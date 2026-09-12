const std = @import("std");
const initCmd = @import("commands/init.zig");
const checkCmd = @import("commands/check.zig");
const addCmd = @import("commands/add.zig");
const removeCmd = @import("commands/remove.zig");
const upgradeCmd = @import("commands/upgrade.zig");

/// no per-thread alternate signal stack
///
/// `std.Thread` gives every thread a 256KB thread-local signal stack by default
/// so a stack-overflow fault can be reported from outside the overflowing stack.
/// a check spawns 16 scan workers and a pre-pass thread, and the thread's TLS
/// setup zeroes that whole block before the thread runs any code: 17 threads x
/// 256KB was 3.4% of a run's instructions (measured with callgrind on a 250-file
/// repo). a lint worker does not recurse, so the stack it would be reported from
/// is not the stack it overflows
pub const std_options: std.Options = .{ .signal_stack_size = null };

test {
    // the unit tests live beside their modules. the build root is what decides
    // whether they run at all, so every module that has tests is listed here:
    // without this block `zig build test` compiles the binary and runs nothing
    _ = @import("config.zig");
    _ = @import("engine.zig");
    _ = @import("rules.zig");
    _ = @import("rules/hygiene.zig");
    _ = @import("rules/parity.zig");
    _ = @import("scope.zig");
    _ = @import("gritql.zig");
    _ = @import("ir.zig");
    _ = @import("lang/ts.zig");
    _ = @import("lint.zig");
    _ = @import("prepass.zig");
    _ = @import("presets.zig");
    _ = @import("templates.zig");
    _ = @import("commands/add.zig");
    _ = @import("commands/check.zig");
    _ = @import("commands/init.zig");
    _ = @import("commands/remove.zig");
    _ = @import("commands/upgrade.zig");
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "init") or std.mem.eql(u8, command, "summon")) {
        const project_name = if (args.len > 2 and !std.mem.startsWith(u8, args[2], "--")) args[2] else null;
        const preset_name = parseFlag(args, "--preset") orelse parseFlag(args, "-p");

        try initCmd.run(allocator, io, project_name, preset_name);
    } else if (std.mem.eql(u8, command, "check")) {
        try checkCmd.run(allocator, io, hasFlag(args, "--biome"));
    } else if (std.mem.eql(u8, command, "add")) {
        const surface_name = if (args.len > 2 and !std.mem.startsWith(u8, args[2], "--")) args[2] else null orelse {
            std.debug.print("usage: grimuah add <surface> [--path <dir>]\n", .{});
            return;
        };
        try addCmd.run(allocator, io, surface_name, parseFlag(args, "--path"));
    } else if (std.mem.eql(u8, command, "remove")) {
        const surface_name = if (args.len > 2) args[2] else null orelse {
            std.debug.print("usage: grimuah remove <surface>\n", .{});
            return;
        };
        try removeCmd.run(allocator, io, surface_name);
    } else if (std.mem.eql(u8, command, "upgrade")) {
        try upgradeCmd.run(allocator, io);
    } else {
        std.debug.print("unknown command: {s}\n", .{command});
        printUsage();
    }
}

fn parseFlag(args: []const [:0]const u8, flag: []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, flag) and i + 1 < args.len) {
            const next = args[i + 1];
            if (!std.mem.startsWith(u8, next, "--")) return next;
        }
        // support --preset=webapp form
        if (std.mem.startsWith(u8, arg, flag) and arg.len > flag.len + 1 and arg[flag.len] == '=') {
            return arg[flag.len + 1 ..];
        }
    }
    return null;
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn printUsage() void {
    std.debug.print(
        \\grimuah :  scaffold enforceably-structured TypeScript projects
        \\
        \\usage:
        \\  grimuah init [name] [--preset <name>]   (summon is an alias)
        \\  grimuah check [--biome]
        \\  grimuah add <surface> [--path <dir>]
        \\  grimuah remove <surface>
        \\  grimuah upgrade
        \\
        \\check runs grimuah's rules and its built-in hygiene rules in-process.
        \\--biome adds biome's own recommended ruleset, which needs biome installed.
        \\
        \\presets: default, webapp, cli, backend, bot
        \\
    , .{});
}
