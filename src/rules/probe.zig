const std = @import("std");
const engine = @import("../engine.zig");
const config = @import("../config.zig");
const root = @import("../rules.zig");

/// the probe the rule unit tests share
///
/// a rule test is almost always the same shape: lint one source string under one
/// layer, and compare the findings to a list of `line: message` rows. the probe
/// is that shape in one place, so a new rule's test is its fixture and its
/// expectation and nothing else
///
/// a rule that judges a call by how its callee is declared elsewhere needs more
/// than one file, and `expectProject` is that shape: several sources, one run, and
/// `path:line: message` rows
///
/// it is compiled into the test binary only: the engine's own run is what
/// production uses

/// every configuration layer off but `layer`. `.hygiene` is not a
/// configuration layer, and the hygiene rules need every layer off, so it
/// returns the all-off configuration the engine then pairs with its own
/// hygiene switch
pub fn only(layer: root.Layer) config.Layers {
    return .{
        .cosmetic = layer == .cosmetic,
        .structural = layer == .structural,
        .resilience = layer == .resilience,
        .behavioural = layer == .behavioural,
    };
}

/// the findings a project of sources produces under `layer`, in one run
///
/// the run is the engine's own, so a rule that declared `needs_project` reads a
/// real index here and a test cannot pin a verdict the engine would not reach
fn lintSources(
    allocator: std.mem.Allocator,
    layer: root.Layer,
    sources: []const engine.Source,
) ![]engine.Finding {
    const cfg = config.Config{ .surfaces = &.{}, .layers = only(layer) };
    return engine.runSources(allocator, &cfg, sources, layer == .hygiene);
}

/// the findings `layer` produces for `source` alone, as `line: message` rows
pub fn findingsFor(
    allocator: std.mem.Allocator,
    layer: root.Layer,
    path: []const u8,
    source: []const u8,
) ![]const []const u8 {
    const findings = try lintSources(allocator, layer, &.{.{ .path = path, .content = source }});
    defer engine.freeFindings(allocator, findings);

    var rows: std.ArrayList([]const u8) = .empty;
    errdefer rows.deinit(allocator);
    for (findings) |finding| {
        try rows.append(allocator, try std.fmt.allocPrint(allocator, "{d}: {s}", .{ finding.line, finding.message }));
    }
    return rows.toOwnedSlice(allocator);
}

/// the findings a whole project produces under `layer`, as `path:line: message`
/// rows, which is what tells two files of one run apart
pub fn projectRows(
    allocator: std.mem.Allocator,
    layer: root.Layer,
    sources: []const engine.Source,
) ![]const []const u8 {
    const findings = try lintSources(allocator, layer, sources);
    defer engine.freeFindings(allocator, findings);

    var rows: std.ArrayList([]const u8) = .empty;
    errdefer rows.deinit(allocator);
    for (findings) |finding| {
        try rows.append(allocator, try std.fmt.allocPrint(allocator, "{s}:{d}: {s}", .{ finding.path, finding.line, finding.message }));
    }
    return rows.toOwnedSlice(allocator);
}

/// lint `source` as `path` under `layer` and require exactly `expected`, in the
/// order the rules report it
pub fn expect(layer: root.Layer, path: []const u8, source: []const u8, expected: []const []const u8) !void {
    const allocator = std.testing.allocator;
    const actual = try findingsFor(allocator, layer, path, source);
    defer {
        for (actual) |row| allocator.free(row);
        allocator.free(actual);
    }
    try expectRows(actual, expected);
}

/// lint `sources` as one project under `layer` and require exactly `expected`
/// rows, each `path:line: message`
pub fn expectProject(layer: root.Layer, sources: []const engine.Source, expected: []const []const u8) !void {
    const allocator = std.testing.allocator;
    const actual = try projectRows(allocator, layer, sources);
    defer {
        for (actual) |row| allocator.free(row);
        allocator.free(actual);
    }
    try expectRows(actual, expected);
}

fn expectRows(actual: []const []const u8, expected: []const []const u8) !void {
    for (expected, 0..) |want, index| {
        if (index >= actual.len) {
            std.debug.print("missing finding: {s}\n", .{want});
            return error.TestUnexpectedResult;
        }
        if (!std.mem.eql(u8, want, actual[index])) {
            std.debug.print("finding {d}: want '{s}', got '{s}'\n", .{ index, want, actual[index] });
            return error.TestUnexpectedResult;
        }
    }
    if (actual.len != expected.len) {
        for (actual[expected.len..]) |extra| std.debug.print("unexpected finding: {s}\n", .{extra});
        return error.TestUnexpectedResult;
    }
}
