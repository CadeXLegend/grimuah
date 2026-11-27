const std = @import("std");
const config = @import("../config.zig");
const corpus = @import("../corpus.zig");
const engine = @import("../engine.zig");
const lint = @import("../lint.zig");
const rules = @import("../rules.zig");
const sweep_roots = @import("build_options").sweep_roots;

// the differential test for the rule migration
//
// `src/lint.zig` is the token-level engine grimuah shipped, verified against
// biome 2.5.11's plugin engine while biome was the oracle. this test runs both
// it and the engine in `src/engine.zig` plus `src/rules/` over every lintable
// file of the committed corpus and fails on any difference in (line, layer,
// severity, message). moving a rule to a different reader has to be invisible
//
// the guard covers the rules the token engine has, which is the set the
// migration moved. a rule added since has no twin in `src/lint.zig`, so its
// findings are dropped from both sides before the comparison and
// `tests/oracle/` is what pins it
//
// a root named by `-Dsweep-roots=` is swept as well, which is how the same
// differential runs over a live tree. the corpus is what gates, so the sweep is
// the opt-in: only files the repository carries decide whether this test passes
//
// a pass prints nothing, which zig 0.17's `zig build test` requires: it reads any
// stderr from the run as a failed command
const Totals = struct {
    files: usize = 0,
    with_findings: usize = 0,
    differences: usize = 0,
};

test "the engine reports what the token engine reports" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cfg = config.Config{
        .surfaces = &.{},
        .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true },
    };

    var totals: Totals = .{};
    try sweepRoot(&totals, allocator, io, &cfg, corpus.root);
    var extra_roots = std.mem.tokenizeScalar(u8, sweep_roots, ':');
    while (extra_roots.next()) |root| try sweepRoot(&totals, allocator, io, &cfg, root);

    // a corpus this small, or a tree that vanished, would leave the loop with
    // nothing to compare and report the silence of a passing run
    if (totals.files == 0) {
        std.debug.print("parity: {s} holds no lintable file\n", .{corpus.root});
        return error.EmptyCorpus;
    }
    if (totals.differences == 0) return;
    std.debug.print(
        "parity: {d} files, {d} with findings, {d} differing\n",
        .{ totals.files, totals.with_findings, totals.differences },
    );
    try std.testing.expectEqual(@as(usize, 0), totals.differences);
}

/// compare both engines over every lintable file under `root`, which a missing
/// directory fails: a root the caller named is either there or a typo
fn sweepRoot(totals: *Totals, allocator: std.mem.Allocator, io: std.Io, cfg: *const config.Config, root: []const u8) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer directory.close(io);

    var walker = try directory.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.path, "node_modules") != null) continue;
        if (!isLintableSource(entry.basename)) continue;

        const source = directory.readFileAlloc(io, entry.path, allocator, .limited(1 << 20)) catch continue;
        defer allocator.free(source);
        totals.files += 1;

        var reference: std.ArrayList(lint.Finding) = .empty;
        defer {
            for (reference.items) |finding| allocator.free(finding.path);
            reference.deinit(allocator);
        }
        try lint.lintContent(allocator, cfg, &reference, entry.path, source);

        var candidate: engine.Contribution = .{};
        defer candidate.deinit(allocator);
        // the hygiene layer is the built-in subset, which this parity test
        // does not cover: `tests/oracle/hygiene-corpus.tsv` does
        try engine.lintContent(allocator, allocator, cfg, &candidate, entry.path, source, &.{entry.path}, false, .owned);

        dropUncovered(&reference);
        dropUncoveredEngine(&candidate.findings);

        if (reference.items.len != 0) totals.with_findings += 1;
        if (reference.items.len == candidate.findings.items.len and sameFindings(reference.items, candidate.findings.items)) continue;
        totals.differences += 1;
        if (totals.differences > 20) continue;
        std.debug.print("parity: {s}: token engine {d} finding(s), engine {d}\n", .{ entry.path, reference.items.len, candidate.findings.items.len });
        for (reference.items) |finding| {
            std.debug.print("  token  line {d} [{s}] {s} ({s})\n", .{ finding.line, finding.layer, finding.message, @tagName(finding.severity) });
        }
        for (candidate.findings.items) |finding| {
            std.debug.print("  engine line {d} [{s}] {s} ({s})\n", .{ finding.line, finding.layer, finding.message, @tagName(finding.severity) });
        }
    }
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
