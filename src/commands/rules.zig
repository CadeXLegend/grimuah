const std = @import("std");
const rules = @import("../rules.zig");

/// the layers in the order the listing groups them, which is the order the
/// README introduces them, with the hygiene pass last because it has no toggle
/// of its own
const listed_layers = [_]rules.Layer{ .cosmetic, .structural, .resilience, .behavioural, .hygiene };

/// the widest rule name of the table, so the columns line up for whatever the
/// table holds rather than for the names it holds today
const name_column_width = blk: {
    var widest: usize = 0;
    for (rules.all) |rule| {
        if (rule.name.len > widest) widest = rule.name.len;
    }
    break :blk widest;
};

/// one rule of the listing: the name a config keys on, the layer it belongs to
/// above it, and the sentence the run prints
const row_format = std.fmt.comptimePrint("  {{s: <{d}}}  {{s: <5}}  {{s}}\n", .{name_column_width});

/// print every rule the engine can report, grouped by layer
///
/// the names are what a config turns a rule off with, and the run itself reports
/// the layer and the message rather than the name, so this is the mapping from a
/// finding a reader just saw to the key that silences it
///
/// it reads no config: what a project turned off is the project's own file, and a
/// listing that depended on the directory it ran in would answer a different
/// question in every directory
pub fn run() void {
    std.debug.print("every rule, by the layer that gates it\n\n", .{});

    for (listed_layers) |layer| {
        std.debug.print("{s}\n", .{layer.name()});
        for (rules.all) |rule| {
            if (rule.layer != layer) continue;
            std.debug.print(row_format, .{ rule.name, @tagName(rule.severity), rule.message });
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("a rule the config omits runs, so a config usually lists only the rules it silences\n", .{});
    std.debug.print("  \"rules\": {{ \"<name>\": false }}\n", .{});
    std.debug.print("a rule that is right everywhere but one boundary is carved out there instead\n", .{});
    std.debug.print("  \"exemptions\": [{{ \"rule\": \"<name>\", \"paths\": [\"<dir or file>\"], \"reason\": \"<why>\" }}]\n", .{});
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// the listing is the discovery path for the config keys, so a rule it omits is a
// rule nobody can turn off without reading the source

test "the listing covers every layer and every rule" {
    // every layer the table uses is one the listing groups under, or the rules of
    // that layer would print under no heading at all
    for (rules.all) |rule| {
        var listed = false;
        for (listed_layers) |layer| {
            if (rule.layer == layer) listed = true;
        }
        try testing.expect(listed);
    }

    // and every layer with rules prints at least one row, so a heading the table
    // has outgrown is caught here rather than by a reader who sees an empty list
    for (listed_layers) |layer| {
        var rows: usize = 0;
        for (rules.all) |rule| {
            if (rule.layer == layer) rows += 1;
        }
        try testing.expect(rows > 0);
    }
}
