const std = @import("std");
const skills = @import("../skills.zig");

/// what an install run was asked to do
pub const InstallOptions = struct {
    /// the directory every skill folder is written under, relative to the
    /// directory the command runs in
    root: []const u8 = skills.default_install_root,
    /// rewrite a skill the target already holds. the default leaves a hand-edited
    /// or older copy alone, so re-running install after an upgrade cannot destroy
    /// work without being told to
    overwrite: bool = false,
    /// where the run reports. null writes to the process stderr, which is what a run
    /// wants. a test passes a discarding writer instead, because `zig build test`
    /// reports a test that wrote to stderr as a failed command even when every test
    /// passed, and a suite that prints turns every green run into a failure line
    report: ?*std.Io.Writer = null,
};

/// write a progress line to the run's destination, or to stderr when it has none
fn report(destination: ?*std.Io.Writer, comptime format: []const u8, args: anytype) void {
    if (destination) |writer| {
        writer.print(format, args) catch {};
        return;
    }
    std.debug.print(format, args);
}

/// print every skill the binary carries, with the description an agent matches on
///
/// it reads no directory: a listing that depended on what is installed would
/// answer a different question in every project
pub fn list() void {
    std.debug.print("the agent skills this binary carries\n\n", .{});
    for (skills.all) |skill| {
        const description = skills.description(skill) orelse "(no description in frontmatter)";
        std.debug.print("  {s}\n    {s}\n\n", .{ skill.name, description });
    }
    std.debug.print("install with `grimuah skills install [name...] [--path <dir>] [--force]`\n", .{});
    std.debug.print("install root defaults to {s}\n", .{skills.default_install_root});
}

/// write the named skills, or every skill when no name is given, under the root
///
/// `dir` is the directory the paths resolve against, which is the working
/// directory in a run and a temporary tree in a test
pub fn install(
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    names: []const []const u8,
    options: InstallOptions,
) !void {
    var selected: std.ArrayList(skills.Skill) = .empty;
    defer selected.deinit(allocator);

    if (names.len == 0) {
        for (skills.all) |skill| try selected.append(allocator, skill);
    } else {
        for (names) |name| {
            const skill = skills.find(name) orelse {
                std.debug.print("error: no skill named '{s}'\n", .{name});
                std.debug.print("run 'grimuah skills list' for the names this binary carries.\n", .{});
                std.process.exit(1);
            };
            try selected.append(allocator, skill);
        }
    }

    report(options.report, "installing {d} skill(s) into {s}\n", .{ selected.items.len, options.root });

    var written: u32 = 0;
    var skipped: u32 = 0;
    for (selected.items) |skill| {
        const path = try skills.installPath(allocator, options.root, skill);
        defer allocator.free(path);

        if (!options.overwrite and fileExists(dir, io, path)) {
            report(options.report, "  skipped {s} (already there, --force overwrites)\n", .{path});
            skipped += 1;
            continue;
        }

        if (std.fs.path.dirname(path)) |parent| {
            try dir.createDirPath(io, parent);
        }
        try dir.writeFile(io, .{ .sub_path = path, .data = skill.contents });
        report(options.report, "  wrote {s}\n", .{path});
        written += 1;
    }

    report(options.report, "installed {d}, skipped {d}\n", .{ written, skipped });
}

/// true when the path already names a file
///
/// a path that resolves to a directory counts as taken too, because writing over
/// it would replace a tree with a file
fn fileExists(dir: std.Io.Dir, io: std.Io, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

const testing = std.testing;

fn readInstalled(dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return dir.readFileAlloc(io, path, allocator, .limited(1 << 20));
}

test "install writes every skill when no name is given" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var sink_buffer: [256]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buffer);
    try install(tmp.dir, io, allocator, &.{}, .{ .report = &sink.writer });

    // the run says what it did, even though the destination here throws it away
    try testing.expect(sink.fullCount() > 0);

    for (skills.all) |skill| {
        const path = try skills.installPath(allocator, skills.default_install_root, skill);
        defer allocator.free(path);

        const installed = try readInstalled(tmp.dir, io, allocator, path);
        defer allocator.free(installed);
        try testing.expectEqualStrings(skill.contents, installed);
    }
}

test "install writes one named skill and leaves the others out" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var sink_buffer: [256]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buffer);
    try install(tmp.dir, io, allocator, &.{"grimuah-compliance"}, .{ .report = &sink.writer });

    const written = try skills.installPath(allocator, skills.default_install_root, skills.find("grimuah-compliance").?);
    defer allocator.free(written);
    const absent = try skills.installPath(allocator, skills.default_install_root, skills.find("grimuah-setup").?);
    defer allocator.free(absent);

    try testing.expect(fileExists(tmp.dir, io, written));
    try testing.expect(!fileExists(tmp.dir, io, absent));
}

test "install honours a custom root" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var sink_buffer: [256]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buffer);
    try install(tmp.dir, io, allocator, &.{"grimuah-setup"}, .{ .root = "somewhere/else", .report = &sink.writer });

    const path = try skills.installPath(allocator, "somewhere/else", skills.find("grimuah-setup").?);
    defer allocator.free(path);
    try testing.expect(fileExists(tmp.dir, io, path));
}

test "install keeps an existing file unless overwrite is asked for" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const skill = skills.find("grimuah-setup").?;
    const path = try skills.installPath(allocator, skills.default_install_root, skill);
    defer allocator.free(path);

    var sink_buffer: [256]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&sink_buffer);
    const options = InstallOptions{ .report = &sink.writer };

    try install(tmp.dir, io, allocator, &.{"grimuah-setup"}, options);
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "hand edited\n" });

    try install(tmp.dir, io, allocator, &.{"grimuah-setup"}, options);
    const kept = try readInstalled(tmp.dir, io, allocator, path);
    defer allocator.free(kept);
    try testing.expectEqualStrings("hand edited\n", kept);

    try install(tmp.dir, io, allocator, &.{"grimuah-setup"}, .{ .overwrite = true, .report = &sink.writer });
    const replaced = try readInstalled(tmp.dir, io, allocator, path);
    defer allocator.free(replaced);
    try testing.expectEqualStrings(skill.contents, replaced);
}
