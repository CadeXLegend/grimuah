const std = @import("std");
const config = @import("config.zig");

/// rule layer that groups GritQL rules and maps to a config toggle
pub const RuleLayer = enum {
    cosmetic,
    structural,
    resilience,
    behavioural,

    /// whether this layer contributes GritQL plugin files under `cfg`
    /// structural has no GritQL rules: folder suffixes, the import firewall,
    /// centralized dirs, innate member depth and singletons are enforced by the
    /// CLI pre-passes. it stays a config toggle but emits no plugin
    pub fn hasPlugin(self: RuleLayer, cfg: *const config.Config) bool {
        return switch (self) {
            .cosmetic => cfg.layers.cosmetic,
            .structural => false,
            .resilience => cfg.layers.resilience,
            .behavioural => cfg.layers.behavioural,
        };
    }
};

/// which engine enforces a rule
pub const Engine = enum {
    /// the pattern compiles under biome 2.5.11's GritQL subset
    biome,
    /// biome silently discards the pattern and reports nothing for it, so only
    /// src/lint.zig enforces the rule. the plugin file is still generated: it is
    /// the canonical record of the rule's intent and it keeps biome.json's
    /// plugin list stable, but `nativeOnlyMessages()` is what the guards hold
    /// biome to
    native_only,
};

/// a single GritQL rule, emitted as its own plugin file
///
/// biome prunes plugin matching by the root node kind of each plugin file.
/// several distinct patterns wrapped in one top-level `or {}` defeat that
/// pruning and cost ~2-3x more than the same patterns in separate files, so
/// every rule gets its own file
pub const Rule = struct {
    layer: RuleLayer,
    file: []const u8,
    pattern: []const u8,
    engine: Engine = .biome,
};

pub const rules = [_]Rule{
    .{
        .layer = .cosmetic,
        .file = "cosmetic-em-dash.grit",
        .pattern =
        \\// cosmetic: surface-level readability
        \\// ban em-dashes everywhere (strings, templates, comments)
        \\`—` as $emdash where {
        \\  register_diagnostic(span=$emdash, message="do not use em-dashes; use commas, colons, or sentence breaks instead", severity="error")
        \\}
        ,
        .engine = .native_only,
    },
    .{
        .layer = .resilience,
        .file = "resilience-switch.grit",
        .pattern =
        \\// resilience: change-proofing -- patterns that prevent codebase fractures
        \\// ban switch -- use dispatch tables (Record/Map)
        \\`switch ($expr) { $cases }` as $switch_stmt where {
        \\  register_diagnostic(span=$switch_stmt, message="do not use switch; use a dispatch table (Record/Map) instead", severity="error")
        \\}
        ,
        .engine = .native_only,
    },
    .{
        .layer = .resilience,
        .file = "resilience-for.grit",
        .pattern =
        \\// ban C-style for loops -- use map, filter, reduce, or for..of
        \\`for ($init; $cond; $update) { $body }` as $for_stmt where {
        \\  register_diagnostic(span=$for_stmt, message="do not use imperative for loops; use map, filter, reduce, or for..of instead", severity="error")
        \\}
        ,
    },
    .{
        .layer = .resilience,
        .file = "resilience-double-equals.grit",
        .pattern =
        \\// ban == -- use ===
        \\`$left == $right` as $double_eq where {
        \\  register_diagnostic(span=$double_eq, message="use === instead of == to avoid type coercion bugs", severity="error")
        \\}
        ,
    },
    .{
        .layer = .resilience,
        .file = "resilience-let.grit",
        .pattern =
        \\// ban let -- use const
        \\`let $name = $value` as $let_decl where {
        \\  register_diagnostic(span=$let_decl, message="do not use let; use const. only let at module-level mutable caches", severity="error")
        \\}
        ,
        .engine = .native_only,
    },
    .{
        .layer = .resilience,
        .file = "resilience-null.grit",
        .pattern =
        \\// ban null -- use undefined
        \\`null` as $null_lit where {
        \\  register_diagnostic(span=$null_lit, message="do not use null; use undefined. null only at third-party boundaries (DB, RegExp)", severity="error")
        \\}
        ,
    },
    .{
        .layer = .resilience,
        .file = "resilience-as-any.grit",
        .pattern =
        \\// ban as any -- use proper types
        \\`$expr as any` as $any_cast where {
        \\  register_diagnostic(span=$any_cast, message="'as any' bypasses type safety entirely; use a proper type instead", severity="error")
        \\}
        ,
    },
    .{
        .layer = .resilience,
        .file = "resilience-chained-cast.grit",
        .pattern =
        \\// ban chained as casts -- use a single cast
        \\`$expr as $t1 as $t2` as $chained_cast where {
        \\  register_diagnostic(span=$chained_cast, message="chained 'as' casts bypass type safety; use a single cast only", severity="error")
        \\}
        ,
    },
    .{
        .layer = .resilience,
        .file = "resilience-reexport.grit",
        .pattern =
        \\// ban proxy re-exports -- every export must add value
        \\`export { $names } from $module` as $reexport where {
        \\  register_diagnostic(span=$reexport, message="do not proxy re-export; every export must originate from the file that defines it", severity="error")
        \\}
        ,
    },
    .{
        .layer = .resilience,
        .file = "resilience-as-const.grit",
        .pattern =
        \\// ban const-as-enum -- use enum
        \\`const $name = { $members } as const` as $asconst where {
        \\  register_diagnostic(span=$asconst, message="use enum instead of const + as const; enum gives you both value and type in one declaration", severity="error")
        \\}
        ,
    },
    .{
        .layer = .behavioural,
        .file = "behavioural-throw.grit",
        .pattern =
        \\// behavioural: runtime safety -- errors flow through discriminated unions, never throw
        \\// ban throw -- all errors must flow through OperationOutcome
        \\`throw $expr` as $throw_stmt where {
        \\  register_diagnostic(span=$throw_stmt, message="do not use throw; all errors must flow through OperationOutcome. see lib/outcome.ts", severity="error")
        \\}
        ,
    },
    .{
        .layer = .behavioural,
        .file = "behavioural-bare-catch.grit",
        .pattern =
        \\// ban bare catch -- must log or handle the error
        \\`try { $body } catch {}` as $bare_catch where {
        \\  register_diagnostic(span=$bare_catch, message="do not use bare catch with silent failure; log the error or return an Outcome", severity="error")
        \\}
        ,
    },
    .{
        .layer = .behavioural,
        .file = "behavioural-silent-catch.grit",
        .pattern =
        \\// ban catch that neither handles, logs, nor rethrows the error
        \\`try { $body } catch { $catch_body }` as $silent_catch where {
        \\  not $catch_body <: contains `return $_`,
        \\  not $catch_body <: contains `throw $_`,
        \\  not $catch_body <: contains `console`,
        \\  register_diagnostic(span=$silent_catch, message="catch block must handle or log the error, not silently discard it", severity="warn")
        \\}
        ,
    },
    .{
        .layer = .behavioural,
        .file = "behavioural-bound-catch.grit",
        .pattern =
        \\// ban catch with bound error that neither handles, logs, nor rethrows
        \\`try { $body } catch ($err) { $catch_body }` as $bound_catch where {
        \\  not $catch_body <: contains `return $_`,
        \\  not $catch_body <: contains `throw $_`,
        \\  not $catch_body <: contains `console`,
        \\  register_diagnostic(span=$bound_catch, message="catch block must handle or log the error, not silently discard it", severity="warn")
        \\}
        ,
    },
};

/// the full contents of a rule's plugin file
pub fn ruleContent(allocator: std.mem.Allocator, rule: Rule) ![]u8 {
    return std.fmt.allocPrint(allocator, "engine biome(1.0)\n\n{s}\n", .{rule.pattern});
}

/// the `message="..."` text a pattern registers
pub fn ruleMessage(rule: Rule) []const u8 {
    const marker = "message=\"";
    const at = std.mem.indexOf(u8, rule.pattern, marker) orelse return "";
    const start = at + marker.len;
    const end = start + (std.mem.indexOfScalar(u8, rule.pattern[start..], '"') orelse return "");
    return rule.pattern[start..end];
}

const native_only_count = blk: {
    var total: usize = 0;
    for (rules) |rule| {
        if (rule.engine == .native_only) total += 1;
    }
    break :blk total;
};

/// every rule message biome's plugin engine cannot enforce, and therefore the
/// full set of findings `src/lint.zig` may report that biome's oracle will not:
/// `.auto/native-diff.sh` requires biome to stay silent on each of these
pub fn nativeOnlyMessages() [native_only_count][]const u8 {
    var messages: [native_only_count][]const u8 = undefined;
    var index: usize = 0;
    for (rules) |rule| {
        if (rule.engine != .native_only) continue;
        messages[index] = ruleMessage(rule);
        index += 1;
    }
    return messages;
}

/// generate one .grit plugin file per enabled rule into .grimuah-rules/ and
/// keep biome.json's plugin list in sync
/// generate one .grit plugin file per enabled rule into .grimuah-rules/ and
/// keep biome.json's plugin list in sync
pub fn generateRules(
    io: std.Io,
    allocator: std.mem.Allocator,
    project_root: []const u8,
    cfg: *const config.Config,
) !void {
    for (rules) |rule| {
        if (!rule.layer.hasPlugin(cfg)) continue;

        const content = try ruleContent(allocator, rule);
        defer allocator.free(content);

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/.grimuah-rules/{s}", .{ project_root, rule.file });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
    }

    try syncBiomePlugins(io, allocator, project_root, cfg);
}

/// plugin paths grimuah wrote before rules were split one-per-file
const legacy_plugin_files = [_][]const u8{
    ".grimuah-rules/cosmetic.grit",
    ".grimuah-rules/structural.grit",
    ".grimuah-rules/resilience.grit",
    ".grimuah-rules/behavioural.grit",
};

/// migrate biome.json's `plugins` array from the legacy per-layer layout to the
/// per-rule layout. returns null when the array is not exactly the legacy list,
/// so user-added plugins and every other setting are never touched
pub fn migrateBiomeJson(allocator: std.mem.Allocator, raw: []const u8, cfg: *const config.Config) !?[]u8 {
    const key_at = std.mem.indexOf(u8, raw, "\"plugins\"") orelse return null;
    const open_at = key_at + (std.mem.indexOfScalar(u8, raw[key_at..], '[') orelse return null);
    const close_at = open_at + (std.mem.indexOfScalar(u8, raw[open_at..], ']') orelse return null);

    if (!isLegacyPluginArray(raw[open_at + 1 .. close_at])) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, raw[0 .. open_at + 1]);
    var remaining = countPlugins(cfg);
    for (rules) |rule| {
        if (!rule.layer.hasPlugin(cfg)) continue;
        remaining -= 1;
        try out.appendSlice(allocator, "\n    \".grimuah-rules/");
        try out.appendSlice(allocator, rule.file);
        try out.appendSlice(allocator, if (remaining == 0) "\"\n  " else "\",");
    }
    try out.appendSlice(allocator, raw[close_at..]);
    return try out.toOwnedSlice(allocator);
}

/// the array body must be exactly the legacy per-layer plugin list
fn isLegacyPluginArray(body: []const u8) bool {
    var seen: usize = 0;
    var parts = std.mem.splitScalar(u8, body, ',');
    while (parts.next()) |part| {
        const entry = std.mem.trim(u8, part, " \t\r\n\"");
        if (entry.len == 0) continue;
        if (!isLegacyPlugin(entry)) return false;
        seen += 1;
    }
    return seen == legacy_plugin_files.len;
}

fn isLegacyPlugin(entry: []const u8) bool {
    for (legacy_plugin_files) |legacy| {
        if (std.mem.eql(u8, entry, legacy)) return true;
    }
    return false;
}

/// rewrite biome.json in place when it still carries the legacy plugin layout
fn syncBiomePlugins(io: std.Io, allocator: std.mem.Allocator, project_root: []const u8, cfg: *const config.Config) !void {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/biome.json", .{project_root});

    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch return;
    defer allocator.free(raw);

    const migrated = (try migrateBiomeJson(allocator, raw, cfg)) orelse return;
    defer allocator.free(migrated);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = migrated });
}

/// append the biome.json `plugins` array entries for every enabled rule
pub fn appendBiomePlugins(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), cfg: *const config.Config) !void {
    var remaining = countPlugins(cfg);
    for (rules) |rule| {
        if (!rule.layer.hasPlugin(cfg)) continue;
        remaining -= 1;
        try buf.appendSlice(allocator, "    \".grimuah-rules/");
        try buf.appendSlice(allocator, rule.file);
        try buf.appendSlice(allocator, if (remaining == 0) "\"\n" else "\",\n");
    }
}

pub fn countPlugins(cfg: *const config.Config) usize {
    var total: usize = 0;
    for (rules) |rule| {
        if (rule.layer.hasPlugin(cfg)) total += 1;
    }
    return total;
}

/// the plugin path grimuah writes for `rule`
pub fn pluginPath(allocator: std.mem.Allocator, rule: Rule) ![]u8 {
    return std.fmt.allocPrint(allocator, ".grimuah-rules/{s}", .{rule.file});
}

const testing = std.testing;

const all_layers_on = config.Config{
    .surfaces = &.{},
    .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true },
};

test "rule files are unique" {
    for (rules, 0..) |rule, i| {
        try testing.expect(std.mem.endsWith(u8, rule.file, ".grit"));
        for (rules[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, rule.file, other.file));
        }
    }
}

test "native-only rules are exactly the em-dash, let and switch rules" {
    const messages = nativeOnlyMessages();
    try testing.expectEqual(@as(usize, 3), messages.len);
    for (messages) |message| try testing.expect(message.len > 0);

    const expected = [_][]const u8{
        "do not use em-dashes; use commas, colons, or sentence breaks instead",
        "do not use let; use const. only let at module-level mutable caches",
        "do not use switch; use a dispatch table (Record/Map) instead",
    };
    for (expected) |want| {
        var found = false;
        for (messages) |message| {
            if (std.mem.eql(u8, message, want)) found = true;
        }
        try testing.expect(found);
    }

    // every native-only rule still ships its plugin file, so the scaffold and
    // biome.json keep documenting the rule and the plugin list stays stable
    for (rules) |rule| {
        if (rule.engine != .native_only) continue;
        try testing.expect(countPlugins(&all_layers_on) > 0);
        try testing.expect(std.mem.startsWith(u8, rule.file, "cosmetic-") or std.mem.startsWith(u8, rule.file, "resilience-"));
    }
}

test "no rule wraps its patterns in a top-level or block" {
    for (rules) |rule| {
        try testing.expect(!std.mem.containsAtLeast(u8, rule.pattern, 1, "or {"));
    }
}

test "every layer with gritql rules emits at least one file" {
    for ([_]RuleLayer{ .cosmetic, .resilience, .behavioural }) |layer| {
        try testing.expect(layer.hasPlugin(&all_layers_on));

        var found = false;
        for (rules) |rule| {
            if (rule.layer == layer) found = true;
        }
        try testing.expect(found);
    }

    try testing.expect(!RuleLayer.structural.hasPlugin(&all_layers_on));
    for (rules) |rule| {
        try testing.expect(rule.layer != .structural);
    }
}

test "ruleContent wraps the pattern in an engine header" {
    const content = try ruleContent(testing.allocator, rules[0]);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.startsWith(u8, content, "engine biome(1.0)\n\n"));
    try testing.expect(std.mem.endsWith(u8, content, "\n"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "register_diagnostic"));
}

test "appendBiomePlugins emits a parsable json array" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try buf.appendSlice(testing.allocator, "{\"plugins\":[\n");
    try appendBiomePlugins(testing.allocator, &buf, &all_layers_on);
    try buf.appendSlice(testing.allocator, "]}");

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();

    const plugins = parsed.value.object.get("plugins").?.array;
    try testing.expectEqual(countPlugins(&all_layers_on), plugins.items.len);
    try testing.expectEqualStrings(".grimuah-rules/" ++ rules[0].file, plugins.items[0].string);

    for (rules) |rule| {
        const expected = try std.fmt.allocPrint(testing.allocator, ".grimuah-rules/{s}", .{rule.file});
        defer testing.allocator.free(expected);
        try testing.expect(std.mem.containsAtLeast(u8, buf.items, 1, expected));
    }
}

test "appendBiomePlugins honours disabled layers" {
    const cosmetic_only = config.Config{
        .surfaces = &.{},
        .layers = .{ .cosmetic = false, .structural = false, .resilience = false, .behavioural = false },
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try appendBiomePlugins(testing.allocator, &buf, &cosmetic_only);
    try testing.expectEqualStrings("", buf.items);

    const enabled = config.Config{
        .surfaces = &.{},
        .layers = .{ .cosmetic = true, .structural = false, .resilience = false, .behavioural = false },
    };
    buf.clearRetainingCapacity();
    try appendBiomePlugins(testing.allocator, &buf, &enabled);
    try testing.expectEqualStrings("    \".grimuah-rules/cosmetic-em-dash.grit\"\n", buf.items);
}

const legacy_biome_json =
    \\{
    \\  "$schema": "https://biomejs.dev/schemas/2.5.3/schema.json",
    \\  "files": { "includes": ["**", "!dist"] },
    \\  "plugins": [
    \\    ".grimuah-rules/cosmetic.grit",
    \\    ".grimuah-rules/structural.grit",
    \\    ".grimuah-rules/resilience.grit",
    \\    ".grimuah-rules/behavioural.grit"
    \\  ],
    \\  "linter": { "enabled": true }
    \\}
;

test "migrateBiomeJson rewrites the legacy plugin list" {
    const migrated = (try migrateBiomeJson(testing.allocator, legacy_biome_json, &all_layers_on)).?;
    defer testing.allocator.free(migrated);

    for (legacy_plugin_files) |legacy| {
        try testing.expect(!std.mem.containsAtLeast(u8, migrated, 1, legacy));
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, migrated, .{});
    defer parsed.deinit();
    const plugins = parsed.value.object.get("plugins").?.array;
    try testing.expectEqual(countPlugins(&all_layers_on), plugins.items.len);
    for (plugins.items) |entry| {
        try testing.expect(std.mem.startsWith(u8, entry.string, ".grimuah-rules/"));
    }

    try testing.expect(std.mem.containsAtLeast(u8, migrated, 1, "\"includes\": [\"**\", \"!dist\"]"));
}

test "migrateBiomeJson leaves user plugins and other settings alone" {
    const with_user_plugin =
        \\{
        \\  "plugins": [
        \\    ".grimuah-rules/cosmetic.grit",
        \\    ".grimuah-rules/structural.grit",
        \\    ".grimuah-rules/resilience.grit",
        \\    ".grimuah-rules/behavioural.grit",
        \\    "my-own.grit"
        \\  ]
        \\}
    ;
    try testing.expect((try migrateBiomeJson(testing.allocator, with_user_plugin, &all_layers_on)) == null);
}

test "migrateBiomeJson ignores configs without the legacy list" {
    try testing.expect((try migrateBiomeJson(testing.allocator, "{\n  \"linter\": {}\n}\n", &all_layers_on)) == null);
    try testing.expect((try migrateBiomeJson(testing.allocator, "{\n  \"plugins\": [\"other.grit\"]\n}\n", &all_layers_on)) == null);
}
