const std = @import("std");

/// one agent skill the binary carries
///
/// the markdown is embedded rather than read from a sibling directory, so an
/// installed binary has every skill at the version that binary shipped with, and
/// nothing needs a network or a checkout to hand them over
pub const Skill = struct {
    /// the folder the skill installs into, which the frontmatter also names
    name: []const u8,
    contents: []const u8,
};

/// where `grimuah skills install` writes when `--path` is absent
///
/// a project-level directory, because a skill is only useful to an agent working
/// in that project, and `.agents/` is the tree every agent tool reads
pub const default_install_root = ".agents/skills";

/// every skill, in the order a new project meets them
pub const all = [_]Skill{
    .{
        .name = "grimuah-setup",
        .contents = @embedFile("skill-grimuah-setup"),
    },
    .{
        .name = "grimuah-architecture",
        .contents = @embedFile("skill-grimuah-architecture"),
    },
    .{
        .name = "grimuah-compliance",
        .contents = @embedFile("skill-grimuah-compliance"),
    },
    .{
        .name = "grimuah-fix-findings",
        .contents = @embedFile("skill-grimuah-fix-findings"),
    },
    .{
        .name = "grimuah-migrate-existing",
        .contents = @embedFile("skill-grimuah-migrate-existing"),
    },
};

/// the skill whose folder name is `name`, or null when the binary carries none
pub fn find(name: []const u8) ?Skill {
    for (all) |skill| {
        if (std.mem.eql(u8, skill.name, name)) return skill;
    }
    return null;
}

/// the value the frontmatter block declares for `key`, without its quotes
///
/// the frontmatter is the skill's own declaration about itself, so reading it
/// rather than repeating it in this table is what keeps the listing and the file
/// from disagreeing. it reads one line per key, which is the shape every shipped
/// skill uses
fn frontmatterValue(contents: []const u8, key: []const u8) ?[]const u8 {
    const document = std.mem.trimStart(u8, contents, " \t\r\n");
    if (!std.mem.startsWith(u8, document, "---")) return null;
    const body = document[3..];
    const close = std.mem.indexOf(u8, body, "\n---") orelse return null;

    var lines = std.mem.splitScalar(u8, body[1..close], '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t"), key)) continue;
        return std.mem.trim(u8, std.mem.trim(u8, line[colon + 1 ..], " \t\r"), "\"");
    }
    return null;
}

/// the skill's description, which is the sentence an agent matches on
pub fn description(skill: Skill) ?[]const u8 {
    const value = frontmatterValue(skill.contents, "description") orelse return null;
    if (value.len == 0) return null;
    return value;
}

/// where one skill installs, relative to the directory the command runs in
pub fn installPath(allocator: std.mem.Allocator, root: []const u8, skill: Skill) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/SKILL.md", .{ root, skill.name });
}

const testing = std.testing;

test "frontmatterValue reads a quoted value" {
    const document = "---\nname: \"demo\"\ndescription: \"a skill\"\n---\n\nbody\n";
    try testing.expectEqualStrings("demo", frontmatterValue(document, "name").?);
    try testing.expectEqualStrings("a skill", frontmatterValue(document, "description").?);
}

test "frontmatterValue stops at the block, so a body line cannot be read as frontmatter" {
    const document = "---\nname: \"demo\"\n---\n\nname: \"body line\"\n";
    try testing.expectEqualStrings("demo", frontmatterValue(document, "name").?);
}

test "frontmatterValue returns null without a frontmatter block" {
    try testing.expectEqual(@as(?[]const u8, null), frontmatterValue("# no frontmatter\n", "name"));
    try testing.expectEqual(@as(?[]const u8, null), frontmatterValue("---\nname: \"demo\"\n", "name"));
}

test "frontmatterValue returns null for a key the frontmatter omits" {
    const document = "---\nname: \"demo\"\n---\n";
    try testing.expectEqual(@as(?[]const u8, null), frontmatterValue(document, "description"));
}

test "every embedded skill declares the name it installs under" {
    // the folder name is what an agent reads, and the frontmatter is what the
    // listing prints. a skill whose two names drift installs somewhere the
    // description does not mention
    for (all) |skill| {
        const declared = frontmatterValue(skill.contents, "name") orelse {
            std.debug.print("{s}: no name in frontmatter\n", .{skill.name});
            return error.MissingName;
        };
        testing.expectEqualStrings(skill.name, declared) catch |err| {
            std.debug.print("{s}: frontmatter names {s}\n", .{ skill.name, declared });
            return err;
        };
    }
}

test "every embedded skill carries a description and a body" {
    // a skill shorter than this is a stub rather than a procedure, so the count
    // catches a file that was emptied or replaced by a placeholder
    const min_plausible_body_bytes = 512;
    for (all) |skill| {
        try testing.expect(description(skill) != null);
        try testing.expect(skill.contents.len > min_plausible_body_bytes);
        try testing.expect(std.mem.indexOf(u8, skill.contents, "## When to Use") != null);
        try testing.expect(std.mem.indexOf(u8, skill.contents, "## Verification") != null);
    }
}

test "skill names are unique and findable" {
    for (all, 0..) |skill, i| {
        for (all[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, skill.name, other.name));
        }
        try testing.expect(find(skill.name) != null);
    }
    try testing.expect(find("grimuah-nonexistent") == null);
}

test "installPath puts each skill in its own folder under the root" {
    const path = try installPath(testing.allocator, default_install_root, all[0]);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings(".agents/skills/grimuah-setup/SKILL.md", path);
}
