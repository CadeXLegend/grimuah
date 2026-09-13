const std = @import("std");
const config = @import("../config.zig");
const engine = @import("../engine.zig");
const lint = @import("../lint.zig");
const rules = @import("../rules.zig");

// the differential test for the rule migration
//
// `src/lint.zig` is the token-level engine grimuah shipped, verified against
// biome 2.5.11's plugin engine while biome was the oracle. this test runs both
// it and the engine in `src/engine.zig` plus `src/rules/` over every file the
// parser sweep covers and fails on any difference in (line, layer, severity,
// message). moving a rule to a different reader has to be invisible
//
// the guard covers the rules the token engine has, which is the set the
// migration moved. a rule added since has no twin in `src/lint.zig`, so its
// findings are dropped from both sides before the comparison and
// `tests/oracle/` is what pins it
//
// it is silent when it passes, because `zig build test` multiplexes the test
// runner's progress over stderr
test "the engine reports what the token engine reports" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const roots_list = std.Io.Dir.cwd().readFileAlloc(io, ".auto/parse-sweep.txt", a, .limited(1 << 16)) catch return;
    defer a.free(roots_list);

    const cfg = config.Config{
        .surfaces = &.{},
        .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true },
    };

    var files: usize = 0;
    var with_findings: usize = 0;
    var differences: usize = 0;
    var roots_found: usize = 0;

    var line_iterator = std.mem.splitScalar(u8, roots_list, '\n');
    while (line_iterator.next()) |raw_line| {
        const root = std.mem.trim(u8, raw_line, " \t\r");
        if (root.len == 0 or root[0] == '#') continue;
        var directory = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer directory.close(io);
        roots_found += 1;

        var walker = try directory.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.indexOf(u8, entry.path, "node_modules") != null) continue;
            if (!isLintableSource(entry.basename)) continue;

            const source = directory.readFileAlloc(io, entry.path, a, .limited(1 << 20)) catch continue;
            defer a.free(source);
            files += 1;

            var reference: std.ArrayList(lint.Finding) = .empty;
            defer {
                for (reference.items) |finding| a.free(finding.path);
                reference.deinit(a);
            }
            try lint.lintContent(a, &cfg, &reference, entry.path, source);

            var candidate: engine.Contribution = .{};
            defer candidate.deinit(a);
            // the hygiene layer is the built-in subset, which this parity test
            // does not cover: `tests/oracle/hygiene-corpus.tsv` does
            try engine.lintContent(a, a, &cfg, &candidate, entry.path, source, false, .owned);

            dropUncovered(&reference);
            dropUncoveredEngine(&candidate.findings);

            if (reference.items.len != 0) with_findings += 1;
            if (reference.items.len == candidate.findings.items.len and sameFindings(reference.items, candidate.findings.items)) continue;
            differences += 1;
            if (differences > 20) continue;
            std.debug.print("parity: {s}: token engine {d} finding(s), engine {d}\n", .{ entry.path, reference.items.len, candidate.findings.items.len });
            for (reference.items) |finding| {
                std.debug.print("  token  line {d} [{s}] {s} ({s})\n", .{ finding.line, finding.layer, finding.message, @tagName(finding.severity) });
            }
            for (candidate.findings.items) |finding| {
                std.debug.print("  engine line {d} [{s}] {s} ({s})\n", .{ finding.line, finding.layer, finding.message, @tagName(finding.severity) });
            }
        }
    }

    if (differences == 0) return;
    std.debug.print(
        "parity: {d} roots, {d} files, {d} with findings, {d} differing\n",
        .{ roots_found, files, with_findings, differences },
    );
    try std.testing.expectEqual(@as(usize, 0), differences);
}

/// whether `message` belongs to a rule `src/lint.zig` implements, i.e. one the
/// token engine can have an opinion about
fn tokenOracleCovers(message: []const u8) bool {
    for (rules.all) |rule| {
        if (!rule.oracle) continue;
        if (std.mem.eql(u8, rule.message, message)) return true;
    }
    return false;
}

fn dropUncovered(findings: *std.ArrayList(lint.Finding)) void {
    var kept: usize = 0;
    for (findings.items) |finding| {
        if (!tokenOracleCovers(finding.message)) {
            std.testing.allocator.free(finding.path);
            continue;
        }
        findings.items[kept] = finding;
        kept += 1;
    }
    findings.shrinkRetainingCapacity(kept);
}

fn dropUncoveredEngine(findings: *std.ArrayList(engine.Finding)) void {
    var kept: usize = 0;
    for (findings.items) |finding| {
        if (!tokenOracleCovers(finding.message)) {
            std.testing.allocator.free(finding.path);
            std.testing.allocator.free(finding.message);
            continue;
        }
        findings.items[kept] = finding;
        kept += 1;
    }
    findings.shrinkRetainingCapacity(kept);
}

/// findings as a multiset: the two engines may report them in a different order,
/// so both sides are sorted and compared in step
fn sameFindings(reference: []lint.Finding, candidate: []engine.Finding) bool {
    if (reference.len != candidate.len) return false;
    std.mem.sort(lint.Finding, reference, {}, referenceLessThan);
    std.mem.sort(engine.Finding, candidate, {}, candidateLessThan);

    for (reference, candidate) |wanted, actual| {
        if (actual.line != wanted.line) return false;
        if (!sameSeverity(actual.severity, wanted.severity)) return false;
        if (!std.mem.eql(u8, actual.layer, wanted.layer)) return false;
        if (!std.mem.eql(u8, actual.message, wanted.message)) return false;
    }
    return true;
}

fn referenceLessThan(_: void, left: lint.Finding, right: lint.Finding) bool {
    return orderLessThan(left.line, left.layer, left.message, left.severity == .err, right.line, right.layer, right.message, right.severity == .err);
}

fn candidateLessThan(_: void, left: engine.Finding, right: engine.Finding) bool {
    return orderLessThan(left.line, left.layer, left.message, left.severity == .err, right.line, right.layer, right.message, right.severity == .err);
}

fn orderLessThan(
    left_line: u32,
    left_layer: []const u8,
    left_message: []const u8,
    left_is_error: bool,
    right_line: u32,
    right_layer: []const u8,
    right_message: []const u8,
    right_is_error: bool,
) bool {
    if (left_line != right_line) return left_line < right_line;
    if (left_is_error != right_is_error) return left_is_error;
    const layer_order = std.mem.order(u8, left_layer, right_layer);
    if (layer_order != .eq) return layer_order == .lt;
    return std.mem.order(u8, left_message, right_message) == .lt;
}

fn sameSeverity(candidate: engine.Severity, reference: lint.Severity) bool {
    return switch (reference) {
        .err => candidate == .err,
        .warn => candidate == .warn,
    };
}

fn isLintableSource(name: []const u8) bool {
    const extensions = [_][]const u8{ ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs" };
    for (extensions) |extension| {
        if (std.mem.endsWith(u8, name, extension)) return true;
    }
    return false;
}
