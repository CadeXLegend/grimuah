const std = @import("std");
const initCmd = @import("commands/init.zig");
const checkCmd = @import("commands/check.zig");
const addCmd = @import("commands/add.zig");
const removeCmd = @import("commands/remove.zig");
const upgradeCmd = @import("commands/upgrade.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "init")) {
        const project_name = if (args.len > 2 and !std.mem.startsWith(u8, args[2], "--")) args[2] else null;
        const preset_name = parseFlag(args, "--preset") orelse parseFlag(args, "-p");

        try initCmd.run(allocator, io, project_name, preset_name);
    } else if (std.mem.eql(u8, command, "check")) {
        try checkCmd.run(allocator, io);
    } else if (std.mem.eql(u8, command, "add")) {
        const surface_name = if (args.len > 2) args[2] else null orelse {
            std.debug.print("usage: arch add <surface>\n", .{});
            return;
        };
        try addCmd.run(allocator, io, surface_name);
    } else if (std.mem.eql(u8, command, "remove")) {
        const surface_name = if (args.len > 2) args[2] else null orelse {
            std.debug.print("usage: arch remove <surface>\n", .{});
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

fn printUsage() void {
    std.debug.print(
        \\archicade :  scaffold enforceably-structured TypeScript projects
        \\
        \\usage:
        \\  archicade init [name] [--preset <name>]
        \\  archicade check
        \\  archicade add <surface>
        \\  archicade remove <surface>
        \\  archicade upgrade
        \\
        \\presets: default, webapp, cli, backend, bot
        \\
    , .{});
}
