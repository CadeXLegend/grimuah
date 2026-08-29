const std = @import("std");

/// template variables available for substitution during scaffolding
pub const TemplateVars = struct {
    project_name: []const u8,
};

/// replace {{key}} placeholders in content with values from vars
pub fn render(content: []const u8, vars: TemplateVars, allocator: std.mem.Allocator) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;

    while (i < content.len) {
        if (i + 1 < content.len and content[i] == '{' and content[i + 1] == '{') {
            const end = std.mem.indexOfPos(u8, content, i + 2, "}}") orelse {
                try result.appendSlice(content[i..]);
                break;
            };
            const key = std.mem.trim(u8, content[i + 2 .. end], " ");
            const value = getVar(key, vars);
            try result.appendSlice(value);
            i = end + 2;
        } else {
            try result.append(allocator, content[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

fn getVar(key: []const u8, vars: TemplateVars) []const u8 {
    if (std.mem.eql(u8, key, "projectName")) return vars.project_name;
    return ""; // unknown vars → empty string
}

/// copy a directory tree from src_dir to dst_dir, applying template variable substitution
/// on all text files (determined by extension)
pub fn scaffoldDir(io: std.Io, 
    allocator: std.mem.Allocator,
    src_dir: []const u8,
    dst_dir: []const u8,
    vars: TemplateVars,
) !void {
    var src = try std.Io.Dir.cwd().openDir(io, src_dir, .{ .iterate = true });
    defer src.close(io);

    var walker = try src.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const rel_path = entry.path;
        const src_path = try std.fs.path.join(allocator, &.{ src_dir, rel_path });
        defer allocator.free(src_path);

        // rename _gitignore → .gitignore
        const dst_name = if (std.mem.eql(u8, entry.basename, "_gitignore"))
            ".gitignore"
        else
            entry.basename;

        var dst_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dst_dirname = std.fs.path.dirname(rel_path) orelse ".";
        const dst_rel = try std.fmt.bufPrint(&dst_path_buf, "{s}/{s}", .{ dst_dirname, dst_name });
        const dst_path = try std.fs.path.join(allocator, &.{ dst_dir, dst_rel });
        defer allocator.free(dst_path);

        // ensure parent directories exist
        if (dst_dirname.len > 0 and !std.mem.eql(u8, dst_dirname, ".")) {
            const parent = std.fs.path.dirname(dst_path) orelse dst_dir;
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }

        if (isTextFile(entry.basename)) {
            const content = try std.Io.Dir.cwd().readFileAlloc(io, src_path, allocator, .limited(1024 * 1024));
            defer allocator.free(content);
            const rendered = try render(content, vars, allocator);
            defer allocator.free(rendered);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst_path, .data = rendered });
        } else {
            try std.Io.Dir.cwd().copyFile(io, src_path, std.Io.Dir.cwd(), dst_path, .{});
        }
    }
}

/// write a string to a file, creating parent directories
pub fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

/// write a string to a file, creating parent directories, with executable permission
pub fn writeExecutableFile(io: std.Io, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content, .flags = .{ .permissions = .executable_file } });
}

fn isTextFile(name: []const u8) bool {
    const text_extensions = [_][]const u8{
        ".ts",   ".tsx",  ".js",   ".jsx",  ".json",
        ".md",   ".html", ".css",  ".yml",  ".yaml",
        ".toml", ".grit", ".gitignore", ".env",
    };
    for (text_extensions) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

const testing = std.testing;

test "render substitutes {{projectName}}" {
    const allocator = testing.allocator;
    const rendered = try render("hello {{projectName}}!", .{ .project_name = "world" }, allocator);
    defer allocator.free(rendered);
    try testing.expectEqualStrings("hello world!", rendered);
}

test "render passes through without placeholders" {
    const allocator = testing.allocator;
    const rendered = try render("hello world", .{ .project_name = "x" }, allocator);
    defer allocator.free(rendered);
    try testing.expectEqualStrings("hello world", rendered);
}

test "render substitutes unknown var with empty string" {
    const allocator = testing.allocator;
    const rendered = try render("{{unknown}}", .{ .project_name = "x" }, allocator);
    defer allocator.free(rendered);
    try testing.expectEqualStrings("", rendered);
}

test "render handles multiple substitutions" {
    const allocator = testing.allocator;
    const rendered = try render("{{projectName}}/src/{{projectName}}.ts", .{ .project_name = "pkg" }, allocator);
    defer allocator.free(rendered);
    try testing.expectEqualStrings("pkg/src/pkg.ts", rendered);
}

test "isTextFile true for known extensions" {
    try testing.expect(isTextFile("foo.ts"));
    try testing.expect(isTextFile("bar.config.ts"));
    try testing.expect(isTextFile("biome.json"));
    try testing.expect(isTextFile("index.html"));
    try testing.expect(isTextFile(".env"));
    try testing.expect(isTextFile("cosmetic.grit"));
    try testing.expect(isTextFile("_gitignore"));
}

test "isTextFile false for binary extensions" {
    try testing.expect(!isTextFile("photo.png"));
    try testing.expect(!isTextFile("icon.jpg"));
    try testing.expect(!isTextFile("binary.exe"));
    try testing.expect(!isTextFile("doc.pdf"));
}
