const std = @import("std");
const config = @import("config.zig");

/// rule layer that maps to a generated .grit file
pub const RuleLayer = enum {
    cosmetic,
    structural,
    resilience,
    behavioural,

    pub fn fileName(self: RuleLayer) []const u8 {
        return switch (self) {
            .cosmetic => "cosmetic.grit",
            .structural => "structural.grit",
            .resilience => "resilience.grit",
            .behavioural => "behavioural.grit",
        };
    }
};

/// generate all enabled .grit rule files into arch-rules/
pub fn generateRules(io: std.Io, 
    allocator: std.mem.Allocator,
    project_root: []const u8,
    cfg: *const config.Config,
) !void {
    const layers = [_]RuleLayer{ .cosmetic, .structural, .resilience, .behavioural };
    const enabled = [_]bool{ cfg.layers.cosmetic, cfg.layers.structural, cfg.layers.resilience, cfg.layers.behavioural };

    for (0..layers.len) |i| {
        const layer = layers[i];
        if (!enabled[i]) continue;

        const content = try generateLayer(allocator, layer);
        defer allocator.free(content);

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/arch-rules/{s}", .{ project_root, layer.fileName() });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
    }
}

/// generate the GritQL content for a single rule layer
fn generateLayer(allocator: std.mem.Allocator, layer: RuleLayer) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;

    try buf.appendSlice(allocator, "engine biome(1.0)\n\n");

    switch (layer) {
        .cosmetic => try appendCosmetic(allocator, &buf),
        .structural => try appendStructural(allocator, &buf),
        .resilience => try appendResilience(allocator, &buf),
        .behavioural => try appendBehavioural(allocator, &buf),
    }

    return buf.toOwnedSlice(allocator);
}

/// cosmetic layer: em-dash detection in string literals
fn appendCosmetic(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(allocator, 
        \\// cosmetic: surface-level readability
        \\
        \\// ban em-dashes in string literals
        \\`"$content"` as $str where {
        \\  $content <: contains "—",
        \\  register_diagnostic(
        \\    span = $str,
        \\    message = "do not use em-dashes; use commas, colons, or sentence breaks instead",
        \\    severity = "error"
        \\  )
        \\}
        \\
        \\// ban em-dashes in template literals
        \\` `$content` ` as $tmpl where {
        \\  $content <: contains "—",
        \\  register_diagnostic(
        \\    span = $tmpl,
        \\    message = "do not use em-dashes; use commas, colons, or sentence breaks instead",
        \\    severity = "error"
        \\  )
        \\}
        \\
    );
}

/// structural layer: nothing for GritQL — handled by CLI pre-passes
fn appendStructural(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(allocator, 
        \\// structural: graph integrity — enforced by CLI pre-passes, not GritQL
        \\// folder-as-suffix naming, import firewall, centralized directory detection,
        \\// singleton warnings, innate member depth scoping
        \\// see: arch check
        \\
    );
}

/// resilience layer: change-proofing patterns
fn appendResilience(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(allocator, 
        \\// resilience: change-proofing — patterns that prevent codebase fractures
        \\
        \\// ban switch statements — use dispatch tables (Record/Map) instead
        \\`switch ($expr) { $cases }` as $stmt where {
        \\  register_diagnostic(
        \\    span = $stmt,
        \\    message = "do not use switch; use a dispatch table (Record/Map) instead",
        \\    severity = "error"
        \\  )
        \\}
        \\
        \\// ban C-style for loops — use map, filter, reduce, or for..of
        \\`for ($init; $cond; $update) { $body }` as $stmt where {
        \\  register_diagnostic(
        \\    span = $stmt,
        \\    message = "do not use imperative for loops; use map, filter, reduce, or for..of instead",
        \\    severity = "error"
        \\  )
        \\}
        \\
        \\// ban let — use const, only let at truly mutable sites
        \\`let $name = $value` as $decl where {
        \\  register_diagnostic(
        \\    span = $decl,
        \\    message = "do not use let; use const. only let at module-level mutable caches",
        \\    severity = "error"
        \\  )
        \\}
        \\
        \\// ban null — use undefined instead
        \\`null` as $null where {
        \\  register_diagnostic(
        \\    span = $null,
        \\    message = "do not use null; use undefined. null only at third-party boundaries (DB, RegExp)",
        \\    severity = "error"
        \\  )
        \\}
        \\
        \\// ban as any — use proper types
        \\`$expr as any` as $cast where {
        \\  register_diagnostic(
        \\    span = $cast,
        \\    message = "'as any' bypasses type safety entirely; use a proper type instead",
        \\    severity = "error"
        \\  )
        \\}
        \\
        \\// ban chained as casts — use a single cast
        \\`$expr as $t1 as $t2` as $cast where {
        \\  register_diagnostic(
        \\    span = $cast,
        \\    message = "chained 'as' casts bypass type safety; use a single cast only",
        \\    severity = "error"
        \\  )
        \\}
        \\
        \\// ban proxy re-exports — every export must add value
        \\`export { $names } from $module` as $stmt where {
        \\  $module <: `'$path'`,
        \\  register_diagnostic(
        \\    span = $stmt,
        \\    message = "do not proxy re-export; every export must originate from the file that defines it",
        \\    severity = "error"
        \\  )
        \\}
        \\
        \\// ban const-as-enum pattern — use enum instead of const + as const + keyof typeof
        \\`const $name = { $members } as const` as $decl where {
        \\  register_diagnostic(
        \\    span = $decl,
        \\    message = "use enum instead of const + as const; enum gives you both value and type in one declaration",
        \\    severity = "error"
        \\  )
        \\}
        \\
    );
}

/// behavioural layer: runtime safety — no throw, input validation
fn appendBehavioural(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(allocator, 
        \\// behavioural: runtime safety — errors flow through discriminated unions, never throw
        \\
        \\// ban throw — all errors must flow through OperationOutcome
        \\`throw $expr` as $stmt where {
        \\  register_diagnostic(
        \\    span = $stmt,
        \\    message = "do not use throw; all errors must flow through OperationOutcome. see lib/operation-outcome.ts",
        \\    severity = "error"
        \\  )
        \\}
        \\
        \\// ban bare catch — catch blocks must log or handle the error
        \\`try { $body } catch {}` as $stmt where {
        \\  register_diagnostic(
        \\    span = $stmt,
        \\    message = "do not use bare catch with silent failure; log the error or return an OperationOutcome",
        \\    severity = "error"
        \\  )
        \\}
        \\
        \\// ban catch without logging — catches that don't use the error (no binding)
        \\`try { $body } catch { $_ }` as $stmt where {
        \\  register_diagnostic(
        \\    span = $stmt,
        \\    message = "catch block must handle or log the error, not silently discard it",
        \\    severity = "warn"
        \\  )
        \\}
        \\
        \\// ban catch with bound error but no logging
        \\`try { $body } catch ($err) { $_ }` as $stmt where {
        \\  register_diagnostic(
        \\    span = $stmt,
        \\    message = "catch block must handle or log the error, not silently discard it",
        \\    severity = "warn"
        \\  )
        \\}
        \\
    );
}
