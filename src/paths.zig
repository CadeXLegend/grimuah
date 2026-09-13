const std = @import("std");

/// the project-relative path arithmetic the passes share
///
/// an import specifier is written relative to the file that makes it, and every
/// consumer needs the same answer: the firewall in `src/prepass.zig` asks which
/// surface the target belongs to, and the import graph in `src/engine.zig` asks
/// which file of the run it names. the walk is written once here so the two
/// cannot disagree about what `../services/x.service.ts` means

/// resolve a relative import against the importing file's directory into a
/// normalised project-relative path, e.g. `("./src/db/xp.repo.ts",
/// "../services/xp.service.ts")` gives `"src/services/xp.service.ts"`
///
/// resolving by path rather than by the import's first segment is what makes
/// cross-tree imports (`"../src/services/..."`) and surfaces whose path has a
/// prefix segment (`"apps/web"`, `"packages/core"`) visible to the firewall, the
/// first-segment form silently matched nothing for both
///
/// returns null when the path climbs above the project root, which is a specifier
/// naming something outside the repository rather than inside it
pub fn resolveRelative(allocator: std.mem.Allocator, importer_path: []const u8, specifier: []const u8) !?[]u8 {
    const importer_dir = std.fs.path.dirname(importer_path) orelse return null;

    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    for ([_][]const u8{ importer_dir, specifier }) |component| {
        var iter = std.mem.tokenizeScalar(u8, component, '/');
        while (iter.next()) |segment| {
            if (std.mem.eql(u8, segment, ".")) continue;
            if (std.mem.eql(u8, segment, "..")) {
                if (segments.items.len == 0) return null;
                _ = segments.pop();
                continue;
            }
            try segments.append(allocator, segment);
        }
    }

    return try std.mem.join(allocator, "/", segments.items);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectResolved(importer_path: []const u8, specifier: []const u8, expected: []const u8) !void {
    const allocator = testing.allocator;
    const resolved = (try resolveRelative(allocator, importer_path, specifier)).?;
    defer allocator.free(resolved);
    try testing.expectEqualStrings(expected, resolved);
}

test "a sibling import resolves within its own surface" {
    try expectResolved("./src/db/xp.repo.ts", "./xp-types.ts", "src/db/xp-types.ts");
}

test "a cross-surface import resolves" {
    try expectResolved("./src/db/xp.repo.ts", "../services/xp.service.ts", "src/services/xp.service.ts");
}

test "a cross-tree import resolves through a prefix segment" {
    // the form that used to resolve to null: the importer sits at the root, so
    // the target's first segment is `src`, which is not a surface name
    try expectResolved("./tools/probe.smoke.ts", "../src/db/x.repo.ts", "src/db/x.repo.ts");
}

test "a deep relative climb resolves" {
    try expectResolved("./src/services/nested/deep/x.service.ts", "../../../db/x.repo.ts", "src/db/x.repo.ts");
}

test "a climb out of a prefixed surface path resolves" {
    try expectResolved("./apps/web/page.ts", "../../packages/core/store.ts", "packages/core/store.ts");
}

test "an import that climbs above the project root resolves to null" {
    const allocator = testing.allocator;
    try testing.expect((try resolveRelative(allocator, "./lib/x.ts", "../../y.ts")) == null);
}

test "a specifier naming the importing file's own directory resolves to that directory" {
    try expectResolved("src/db/x.repo.ts", ".", "src/db");
}
