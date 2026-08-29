const std = @import("std");
const config = @import("../config.zig");
const presets = @import("../presets.zig");
const gritql = @import("../gritql.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var parsed = config.load(io, allocator, "architecture.config.json") catch |err| {
        std.debug.print("error: could not load architecture.config.json: {s}\n", .{@errorName(err)});
        return;
    };
    defer parsed.deinit();
    const cfg = parsed.value;

    // detect which preset this project most closely matches
    const matching = detectMatchingPreset(&cfg);
    const latest_parsed = presets.loadPreset(allocator, matching) catch |err| {
        std.debug.print("error: could not load preset {s}: {s}\n", .{ @tagName(matching), @errorName(err) });
        return;
    };
    defer latest_parsed.deinit();
    const latest = latest_parsed.value;

    // merge: add new surfaces from the preset, preserve user's layer toggles
    var changes: u32 = 0;

    // add preset surfaces not already in user config
    for (latest.surfaces) |preset_surface| {
        if (cfg.getSurface(preset_surface.name) == null) {
            std.debug.print("  + adding surface '{s}' from updated preset\n", .{preset_surface.name});
            changes += 1;
        }
    }

    if (changes == 0) {
        std.debug.print("upgrade: already up to date\n", .{});
        return;
    }

    // rewrite config with merged values
    try rewriteConfig(io, allocator, &cfg, &latest);

    // regenerate GritQL rules
    try gritql.generateRules(io, allocator, ".", &cfg);

    std.debug.print("upgrade: {d} change(s) applied\n", .{changes});
}

fn detectMatchingPreset(cfg: *const config.Config) presets.Preset {
    const names = [_][]const u8{ "lib", "db", "services", "middleware", "components", "commands", "tasks", "handlers", "pages", "utils" };
    var scores = [_]u32{0} ** 5; // default, webapp, cli, backend, bot

    for (names, 0..) |name, name_idx| {
        if (cfg.getSurface(name) != null) {
            switch (name_idx) {
                0 => { // lib
                    scores[0] += 0; // default has no lib
                    scores[1] += 1; // webapp
                    scores[2] += 1; // cli
                    scores[3] += 1; // backend
                    scores[4] += 1; // bot
                },
                1 => { // db
                    scores[0] += 0;
                    scores[1] += 0;
                    scores[2] += 0;
                    scores[3] += 1; // backend
                    scores[4] += 1; // bot
                },
                2 => { // services
                    scores[0] += 1;
                    scores[1] += 1;
                    scores[2] += 0;
                    scores[3] += 1;
                    scores[4] += 1;
                },
                3 => { // components
                    scores[0] += 1;
                    scores[1] += 1;
                    scores[2] += 0;
                    scores[3] += 0;
                    scores[4] += 1;
                },
                4 => { // middleware
                    scores[0] += 0;
                    scores[1] += 0;
                    scores[2] += 0;
                    scores[3] += 1; // backend
                    scores[4] += 1; // bot
                },
                5 => { // commands
                    scores[0] += 0;
                    scores[1] += 0;
                    scores[2] += 1; // cli
                    scores[3] += 0;
                    scores[4] += 1; // bot
                },
                6 => { // tasks
                    scores[0] += 0;
                    scores[1] += 0;
                    scores[2] += 0;
                    scores[3] += 1; // backend
                    scores[4] += 1; // bot
                },
                7 => { // handlers
                    scores[0] += 0;
                    scores[1] += 0;
                    scores[2] += 0;
                    scores[3] += 0;
                    scores[4] += 1; // bot
                },
                8 => { // pages
                    scores[0] += 0;
                    scores[1] += 1; // webapp
                    scores[2] += 0;
                    scores[3] += 0;
                    scores[4] += 0;
                },
                9 => { // utils
                    scores[0] += 1;
                    scores[1] += 1;
                    scores[2] += 1;
                    scores[3] += 0;
                    scores[4] += 0;
                },
                else => {},
            }
        }
    }

    // find preset with highest match score, prefer specific presets over generic ones on tie
    var best: presets.Preset = .default;
    var best_score: u32 = 0;
    const candidates = [_]presets.Preset{ .default, .webapp, .cli, .backend, .bot };
    for (candidates, scores) |candidate, score| {
        if (score > best_score) {
            best = candidate;
            best_score = score;
        }
    }
    return best;
}

fn rewriteConfig(io: std.Io, allocator: std.mem.Allocator, cfg: *const config.Config, latest: *const config.Config) !void {
    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(allocator);

    // write user's surfaces (preserving any custom surfaces not in preset)
    try json_buf.appendSlice(allocator, "{\n  \"surfaces\": [\n");
    for (cfg.surfaces, 0..) |surface, i| {
        if (i > 0) try json_buf.appendSlice(allocator, ",\n");
        try json_buf.appendSlice(allocator, try std.fmt.allocPrint(
            allocator,
            "    {{\n      \"name\": \"{s}\",\n      \"path\": \"{s}\",\n      \"depth\": {d},\n      \"dagOrder\": {d},\n      \"suffixes\": [",
            .{ surface.name, surface.path, surface.depth, surface.dagOrder },
        ));
        for (surface.suffixes, 0..) |suffix, j| {
            try json_buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"{s}\"", .{suffix}));
            if (j < surface.suffixes.len - 1) try json_buf.appendSlice(allocator, ", ");
        }
        try json_buf.appendSlice(allocator, "],\n      \"innateMembers\": [");
        for (surface.innateMembers, 0..) |innate, j| {
            try json_buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"{s}\"", .{innate}));
            if (j < surface.innateMembers.len - 1) try json_buf.appendSlice(allocator, ", ");
        }
        try json_buf.appendSlice(allocator, "],\n      \"allowedImports\": [");
        for (surface.allowedImports, 0..) |imp, j| {
            try json_buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"{s}\"", .{imp}));
            if (j < surface.allowedImports.len - 1) try json_buf.appendSlice(allocator, ", ");
        }
        try json_buf.appendSlice(allocator, "]\n    }");
    }

    // add preset surfaces not in user config
    for (latest.surfaces) |preset_surface| {
        if (cfg.getSurface(preset_surface.name) != null) continue;
        try json_buf.appendSlice(allocator, ",\n");
        try json_buf.appendSlice(allocator, try std.fmt.allocPrint(
            allocator,
            "    {{\n      \"name\": \"{s}\",\n      \"path\": \"{s}\",\n      \"depth\": {d},\n      \"dagOrder\": {d},\n      \"suffixes\": [",
            .{ preset_surface.name, preset_surface.path, preset_surface.depth, preset_surface.dagOrder },
        ));
        for (preset_surface.suffixes, 0..) |suffix, j| {
            try json_buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"{s}\"", .{suffix}));
            if (j < preset_surface.suffixes.len - 1) try json_buf.appendSlice(allocator, ", ");
        }
        try json_buf.appendSlice(allocator, "],\n      \"innateMembers\": [");
        for (preset_surface.innateMembers, 0..) |innate, j| {
            try json_buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"{s}\"", .{innate}));
            if (j < preset_surface.innateMembers.len - 1) try json_buf.appendSlice(allocator, ", ");
        }
        try json_buf.appendSlice(allocator, "],\n      \"allowedImports\": [");
        for (preset_surface.allowedImports, 0..) |imp, j| {
            try json_buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"{s}\"", .{imp}));
            if (j < preset_surface.allowedImports.len - 1) try json_buf.appendSlice(allocator, ", ");
        }
        try json_buf.appendSlice(allocator, "]\n    }");
    }

    try json_buf.appendSlice(allocator, "\n  ],\n");

    // write layers from user config (preserve user choices)
    try json_buf.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\  "layers": {{
        \\    "cosmetic": {},
        \\    "structural": {},
        \\    "resilience": {},
        \\    "behavioural": {}
        \\  }}
    , .{ cfg.layers.cosmetic, cfg.layers.structural, cfg.layers.resilience, cfg.layers.behavioural }));

    if (cfg.rootLib.enabled) {
        try json_buf.appendSlice(allocator, try std.fmt.allocPrint(allocator,
            \\,
            \\  "rootLib": {{
            \\    "enabled": true,
            \\    "path": "{s}"
            \\  }}
        , .{cfg.rootLib.path}));
    }

    try json_buf.appendSlice(allocator, "\n}\n");

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "architecture.config.json", .data = json_buf.items });
}
