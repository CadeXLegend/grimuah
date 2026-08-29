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

/// generate all enabled .grit rule files into .arch-rules/
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
        const path = try std.fmt.bufPrint(&path_buf, "{s}/.arch-rules/{s}", .{ project_root, layer.fileName() });
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

/// cosmetic layer: em-dash detection
fn appendCosmetic(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(allocator,
        \\// cosmetic: surface-level readability
        \\
        \\// ban em-dashes everywhere (strings, templates, comments)
        \\`—` as $emdash where {
        \\  register_diagnostic(span=$emdash, message="do not use em-dashes; use commas, colons, or sentence breaks instead", severity="error")
        \\}
        \\
    );
}

/// structural layer: handled by CLI pre-passes
/// biome 2.x requires at least one pattern per plugin file
fn appendStructural(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(allocator,
        \\// structural: graph integrity
        \\// enforced by CLI pre-passes, not GritQL
        \\// folder-as-suffix naming, import firewall, centralized directory detection,
        \\// singleton warnings, innate member depth scoping
        \\// see: arch check
        \\
        \\`undefined` where {}
        \\
    );
}

/// resilience layer: change-proofing patterns
fn appendResilience(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(allocator,
        \\// resilience: change-proofing -- patterns that prevent codebase fractures
        \\
        \\or {
        \\  // ban switch -- use dispatch tables (Record/Map)
        \\  `switch ($expr) { $cases }` as $switch_stmt where {
        \\    register_diagnostic(span=$switch_stmt, message="do not use switch; use a dispatch table (Record/Map) instead", severity="error")
        \\  },
        \\
        \\  // ban C-style for loops -- use map, filter, reduce, or for..of
        \\  `for ($init; $cond; $update) { $body }` as $for_stmt where {
        \\    register_diagnostic(span=$for_stmt, message="do not use imperative for loops; use map, filter, reduce, or for..of instead", severity="error")
        \\  },
        \\
        \\  // ban let -- use const
        \\  // ban == -- use ===
        \\  `$left == $right` as $double_eq where {
        \\    register_diagnostic(span=$double_eq, message="use === instead of == to avoid type coercion bugs", severity="error")
        \\  },
        
        \\  `let $name = $value` as $let_decl where {
        \\    register_diagnostic(span=$let_decl, message="do not use let; use const. only let at module-level mutable caches", severity="error")
        \\  },
        \\
        \\  // ban null -- use undefined
        \\  `null` as $null_lit where {
        \\    register_diagnostic(span=$null_lit, message="do not use null; use undefined. null only at third-party boundaries (DB, RegExp)", severity="error")
        \\  },
        \\
        \\  // ban as any -- use proper types
        \\  `$expr as any` as $any_cast where {
        \\    register_diagnostic(span=$any_cast, message="'as any' bypasses type safety entirely; use a proper type instead", severity="error")
        \\  },
        \\
        \\  // ban chained as casts -- use a single cast
        \\  `$expr as $t1 as $t2` as $chained_cast where {
        \\    register_diagnostic(span=$chained_cast, message="chained 'as' casts bypass type safety; use a single cast only", severity="error")
        \\  },
        \\
        \\  // ban proxy re-exports -- every export must add value
        \\  `export { $names } from $module` as $reexport where {
        \\    register_diagnostic(span=$reexport, message="do not proxy re-export; every export must originate from the file that defines it", severity="error")
        \\  },
        \\
        \\  // ban const-as-enum -- use enum
        \\  `const $name = { $members } as const` as $asconst where {
        \\    register_diagnostic(span=$asconst, message="use enum instead of const + as const; enum gives you both value and type in one declaration", severity="error")
        \\  },
        \\}
        \\
    );
}

/// behavioural layer: runtime safety -- no throw, input validation
fn appendBehavioural(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(allocator,
        \\// behavioural: runtime safety -- errors flow through discriminated unions, never throw
        \\
        \\or {
        \\  // ban throw -- all errors must flow through OperationOutcome
        \\  `throw $expr` as $throw_stmt where {
        \\    register_diagnostic(span=$throw_stmt, message="do not use throw; all errors must flow through OperationOutcome. see lib/outcome.ts", severity="error")
        \\  },
        \\
        \\  // ban bare catch -- must log or handle the error
        \\  `try { $body } catch {}` as $bare_catch where {
        \\    register_diagnostic(span=$bare_catch, message="do not use bare catch with silent failure; log the error or return an Outcome", severity="error")
        \\  },
        \\
        \\  // ban catch without logging (no binding)
        \\  `try { $body } catch { $_ }` as $silent_catch where {
        \\    register_diagnostic(span=$silent_catch, message="catch block must handle or log the error, not silently discard it", severity="warn")
        \\  },
        \\
        \\  // ban catch with bound error but no logging
        \\  `try { $body } catch ($err) { $_ }` as $bound_catch where {
        \\    register_diagnostic(span=$bound_catch, message="catch block must handle or log the error, not silently discard it", severity="warn")
        \\  },
        \\}
        \\
    );
}

const testing = std.testing;

test "generateLayer cosmetic starts with engine biome" {
    const allocator = testing.allocator;
    const content = try generateLayer(allocator, .cosmetic);
    defer allocator.free(content);
    try testing.expect(std.mem.startsWith(u8, content, "engine biome(1.0)\n"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "em-dash"));
}

test "generateLayer structural is comment-only" {
    const allocator = testing.allocator;
    const content = try generateLayer(allocator, .structural);
    defer allocator.free(content);
    try testing.expect(std.mem.startsWith(u8, content, "engine biome(1.0)\n"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "CLI pre-passes"));
}

test "generateLayer resilience contains all patterns" {
    const allocator = testing.allocator;
    const content = try generateLayer(allocator, .resilience);
    defer allocator.free(content);
    try testing.expect(std.mem.startsWith(u8, content, "engine biome(1.0)\n"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "switch"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "for"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "=="));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "null"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "as any"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "as const"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "proxy re-export"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "dispatch table"));
}

test "generateLayer behavioural contains all patterns" {
    const allocator = testing.allocator;
    const content = try generateLayer(allocator, .behavioural);
    defer allocator.free(content);
    try testing.expect(std.mem.startsWith(u8, content, "engine biome(1.0)\n"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "throw"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "catch {}"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "catch ($err)"));
}

test "RuleLayer.fileName returns correct name" {
    try testing.expectEqualStrings("cosmetic.grit", RuleLayer.cosmetic.fileName());
    try testing.expectEqualStrings("structural.grit", RuleLayer.structural.fileName());
    try testing.expectEqualStrings("resilience.grit", RuleLayer.resilience.fileName());
    try testing.expectEqualStrings("behavioural.grit", RuleLayer.behavioural.fileName());
}
