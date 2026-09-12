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
/// it is compiled into the test binary only: the engine's own scan is what
/// production runs

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

/// the findings `layer` produces for `source`, as `line: message` rows
pub fn findingsFor(
    allocator: std.mem.Allocator,
    layer: root.Layer,
    path: []const u8,
    source: []const u8,
) ![]const []const u8 {
    const cfg = config.Config{ .surfaces = &.{}, .layers = only(layer) };

    var findings: std.ArrayList(engine.Finding) = .empty;
    defer {
        for (findings.items) |finding| {
            allocator.free(finding.path);
            allocator.free(finding.message);
        }
        findings.deinit(allocator);
    }
    try engine.lintContent(allocator, allocator, &cfg, &findings, path, source, layer == .hygiene, .owned);

    var rows: std.ArrayList([]const u8) = .empty;
    errdefer rows.deinit(allocator);
    for (findings.items) |finding| {
        try rows.append(allocator, try std.fmt.allocPrint(allocator, "{d}: {s}", .{ finding.line, finding.message }));
    }
    return rows.toOwnedSlice(allocator);
}

/// lint `source` as `path` under `layer` and require exactly `expected`, in the
/// order the rules report it
pub fn expect(layer: root.Layer, path: []const u8, source: []const u8, expected: []const []const u8) !void {
    const a = std.testing.allocator;
    const actual = try findingsFor(a, layer, path, source);
    defer {
        for (actual) |row| a.free(row);
        a.free(actual);
    }

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
