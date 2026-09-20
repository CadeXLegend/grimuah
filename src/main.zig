const std = @import("std");
const initCmd = @import("commands/init.zig");
const checkCmd = @import("commands/check.zig");
const addCmd = @import("commands/add.zig");
const removeCmd = @import("commands/remove.zig");
const upgradeCmd = @import("commands/upgrade.zig");
const rulesCmd = @import("commands/rules.zig");
const skillsCmd = @import("commands/skills.zig");
const skills = @import("skills.zig");

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
    _ = @import("ir.zig");
    _ = @import("lang/ts.zig");
    _ = @import("lang/typemodel.zig");
    _ = @import("lint.zig");
    _ = @import("prepass.zig");
    _ = @import("presets.zig");
    _ = @import("templates.zig");
    _ = @import("commands/add.zig");
    _ = @import("commands/check.zig");
    _ = @import("commands/init.zig");
    _ = @import("commands/remove.zig");
    _ = @import("commands/rules.zig");
    _ = @import("commands/skills.zig");
    _ = @import("skills.zig");
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
        try checkCmd.run(allocator, io);
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
    } else if (std.mem.eql(u8, command, "rules")) {
        rulesCmd.run();
    } else if (std.mem.eql(u8, command, "skills")) {
        try runSkills(allocator, io, args);
    } else {
        std.debug.print("unknown command: {s}\n", .{command});
        printUsage();
    }
}

/// dispatch `grimuah skills list` and `grimuah skills install`
fn runSkills(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    const subcommand = if (args.len > 2 and !std.mem.startsWith(u8, args[2], "--")) args[2] else null;
    const chosen = subcommand orelse {
        printSkillsUsage();
        return;
    };

    if (std.mem.eql(u8, chosen, "list")) {
        skillsCmd.list();
        return;
    }
    if (!std.mem.eql(u8, chosen, "install")) {
        std.debug.print("unknown skills subcommand: {s}\n", .{chosen});
        printSkillsUsage();
        return;
    }

    var names: std.ArrayList([]const u8) = .empty;
    try collectSkillNames(allocator, args, &names);
    try skillsCmd.install(std.Io.Dir.cwd(), io, allocator, names.items, .{
        .root = parseFlag(args, "--path") orelse skills.default_install_root,
        .overwrite = hasFlag(args, "--force"),
    });
}

/// every argument that names a skill, skipping the subcommand and each flag
///
/// `--path` takes a value, so the argument after it is the path and not a name.
/// `--path=<dir>` carries its own value and is skipped like any other flag
fn collectSkillNames(allocator: std.mem.Allocator, args: []const [:0]const u8, names: *std.ArrayList([]const u8)) !void {
    // the program name, `skills` and the subcommand are never skill names
    const first_candidate: usize = 3;
    var index: usize = first_candidate;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--path")) {
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, argument, "-")) continue;
        try names.append(allocator, argument);
    }
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |argument| {
        if (std.mem.eql(u8, argument, flag)) return true;
    }
    return false;
}

fn printSkillsUsage() void {
    std.debug.print(
        \\usage:
        \\  grimuah skills list                      every skill this binary carries
        \\  grimuah skills install [name...] [--path <dir>] [--force]
        \\
        \\install writes each skill to <dir>/<name>/SKILL.md
        \\<dir> defaults to .agents/skills, and an existing file is kept unless --force
    , .{});
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
        \\grimuah :  scaffold enforceably-structured TypeScript projects
        \\
        \\usage:
        \\  grimuah init [name] [--preset <name>]   (summon is an alias)
        \\  grimuah check
        \\  grimuah add <surface> [--path <dir>]
        \\  grimuah remove <surface>
        \\  grimuah upgrade
        \\  grimuah rules
        \\  grimuah skills list|install [name...] [--path <dir>] [--force]
        \\
        \\check runs grimuah's architecture rules and its built-in hygiene rules
        \\in-process, with no subprocess and no other linter involved
        \\
        \\rules lists every rule name architecture.config.json can turn off
        \\
        \\skills hands the agent skills this binary carries to a project
        \\
        \\presets: default, webapp, cli, backend, bot
        \\
    , .{});
}
