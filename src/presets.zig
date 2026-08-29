const std = @import("std");
const config = @import("config.zig");

/// preset names for the --preset flag
pub const Preset = enum {
    default,
    webapp,
    cli,
    backend,
    bot,

    pub fn fromName(name: []const u8) ?Preset {
        const map = std.StaticStringMap(Preset).initComptime(.{
            .{ "default", .default },
            .{ "webapp", .webapp },
            .{ "cli", .cli },
            .{ "backend", .backend },
            .{ "bot", .bot },
        });
        return map.get(name);
    }
};

/// embedded preset JSON, compiled into the binary at build time
const embedded_default: []const u8 = @embedFile("preset_data/default.json");
const embedded_webapp: []const u8 = @embedFile("preset_data/webapp.json");
const embedded_cli: []const u8 = @embedFile("preset_data/cli.json");
const embedded_backend: []const u8 = @embedFile("preset_data/backend.json");
const embedded_bot: []const u8 = @embedFile("preset_data/bot.json");

/// return the raw JSON string for a preset
pub fn getRaw(preset: Preset) []const u8 {
    return switch (preset) {
        .default => embedded_default,
        .webapp => embedded_webapp,
        .cli => embedded_cli,
        .backend => embedded_backend,
        .bot => embedded_bot,
    };
}

/// parse a preset into a Config, caller owns the returned Parsed (call .deinit())
pub fn loadPreset(allocator: std.mem.Allocator, preset: Preset) !std.json.Parsed(config.Config) {
    const raw = getRaw(preset);
    return try std.json.parseFromSlice(config.Config, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });
}

/// get the display description for a preset
pub fn description(preset: Preset) []const u8 {
    return switch (preset) {
        .default => "bare-bones: services/, utils/, components/ with minimal scaffolding",
        .webapp => "web application: lib/, utils/, services/, components/, pages/",
        .cli => "command-line tool: lib/, utils/, services/, commands/",
        .backend => "backend service: lib/, db/, middleware/, services/ (plus optional tasks/)",
        .bot => "telegram/chat bot: lib/, db/, services/, middleware/, components/, commands/, tasks/, handlers/",
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseFromSlice succeeds on default preset" {
    const allocator = testing.allocator;
    const parsed = try loadPreset(allocator, .default);
    defer parsed.deinit();

    try testing.expect(parsed.value.surfaces.len == 3);
    try testing.expect(parsed.value.rootLib.enabled == false);
}

test "parseFromSlice succeeds on webapp preset" {
    const allocator = testing.allocator;
    const parsed = try loadPreset(allocator, .webapp);
    defer parsed.deinit();

    try testing.expect(parsed.value.surfaces.len == 5);
    try testing.expect(parsed.value.rootLib.enabled == true);
}

test "parseFromSlice succeeds on cli preset" {
    const allocator = testing.allocator;
    const parsed = try loadPreset(allocator, .cli);
    defer parsed.deinit();

    try testing.expect(parsed.value.surfaces.len == 4);
}

test "parseFromSlice succeeds on backend preset" {
    const allocator = testing.allocator;
    const parsed = try loadPreset(allocator, .backend);
    defer parsed.deinit();

    try testing.expect(parsed.value.surfaces.len == 4);
}

test "parseFromSlice succeeds on bot preset" {
    const allocator = testing.allocator;
    const parsed = try loadPreset(allocator, .bot);
    defer parsed.deinit();

    try testing.expect(parsed.value.surfaces.len == 8);
    try testing.expect(parsed.value.rootLib.enabled == true);
}

test "parseFromSlice ignores unknown fields when disabled" {
    const allocator = testing.allocator;
    const raw =
        \\{
        \\  "surfaces": [
        \\    {
        \\      "name": "utils",
        \\      "path": "src/utils",
        \\      "depth": 0,
        \\      "suffixes": [".util.ts"]
        \\    }
        \\  ],
        \\  "layers": {
        \\    "cosmetic": true,
        \\    "structural": true,
        \\    "resilience": true,
        \\    "behavioural": true
        \\  },
        \\  "extraField": "should be ignored"
        \\}
    ;

    const parsed = try std.json.parseFromSlice(config.Config, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try testing.expect(parsed.value.surfaces.len == 1);
}

test "parseFromSlice fails on unknown fields with strict mode" {
    const allocator = testing.allocator;
    const raw =
        \\{
        \\  "surfaces": [
        \\    {
        \\      "name": "utils",
        \\      "path": "src/utils",
        \\      "depth": 0,
        \\      "suffixes": [".util.ts"]
        \\    }
        \\  ],
        \\  "layers": {
        \\    "cosmetic": true,
        \\    "structural": true,
        \\    "resilience": true,
        \\    "behavioural": true
        \\  },
        \\  "extraField": "should cause error"
        \\}
    ;

    const result = std.json.parseFromSlice(config.Config, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });

    try testing.expectError(error.UnknownField, result);
}
