const std = @import("std");
const config = @import("../config.zig");
const templates = @import("../templates.zig");
const gritql = @import("../gritql.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, surface_name: []const u8) !void {
    var parsed = config.load(io, allocator, "architecture.config.json") catch |err| {
        std.debug.print("error: could not load architecture.config.json: {s}\n", .{@errorName(err)});
        return;
    };
    defer parsed.deinit();
    var cfg = parsed.value;

    // check surface doesn't already exist
    if (cfg.getSurface(surface_name) != null) {
        std.debug.print("error: surface '{s}' already exists\n", .{surface_name});
        return;
    }

    std.debug.print("adding surface '{s}'...\n", .{surface_name});

    // determine depth (deepest + 1 unless it should slot in at a specific position)
    const new_depth: u32 = findDeepestDepth(&cfg) + 1;

    // collect allowedImports: all shallower surfaces
    var allowed: std.ArrayList([]const u8) = .empty;
    defer allowed.deinit(allocator);
    for (cfg.surfaces) |surface| {
        if (surface.depth < new_depth) {
            try allowed.append(allocator, surface.name);
        }
    }

    // determine legal suffixes based on surface name convention
    const suffixes = try suffixesForSurface(allocator, surface_name);
    defer allocator.free(suffixes);

    const innateMembers = [_][]const u8{ ".types.ts", ".config.ts", ".spec.ts" };

    // create the surface directory
    const surface_path = try std.fmt.allocPrint(allocator, "src/{s}", .{surface_name});
    defer allocator.free(surface_path);
    try std.Io.Dir.cwd().createDirPath(io, surface_path);

    // create example file
    const example_name = try std.fmt.allocPrint(allocator, "example{s}", .{suffixes[0]});
    defer allocator.free(example_name);
    var example_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const example_path = try std.fmt.bufPrint(&example_path_buf, "src/{s}/{s}", .{ surface_name, example_name });
    try templates.writeFile(io, example_path, "// TODO: implement\n");

    // regenerate architecture.config.json with new surface
    try rewriteConfig(io, allocator, &cfg, surface_name, surface_path, new_depth, suffixes, &innateMembers, allowed.items);

    // regenerate GritQL rules
    try gritql.generateRules(io, allocator, ".", &cfg);

    std.debug.print("added surface '{s}' at depth {d}\n", .{ surface_name, new_depth });
}

fn findDeepestDepth(cfg: *const config.Config) u32 {
    var max: u32 = 0;
    for (cfg.surfaces) |surface| {
        if (surface.depth > max) max = surface.depth;
    }
    return max;
}

fn suffixesForSurface(allocator: std.mem.Allocator, name: []const u8) ![]const []const u8 {
    // heuristic: surface name → standard suffix pattern
    if (std.mem.eql(u8, name, "validators")) return allocator.dupe([]const u8, &.{ ".validator.ts", ".config.ts" });
    if (std.mem.eql(u8, name, "guards")) return allocator.dupe([]const u8, &.{ ".guard.ts", ".config.ts" });
    if (std.mem.eql(u8, name, "states")) return allocator.dupe([]const u8, &.{ ".state.ts", ".config.ts" });
    if (std.mem.eql(u8, name, "repositories")) return allocator.dupe([]const u8, &.{ ".repo.ts", ".config.ts" });

    // default: <name>/<name>.ts (strip trailing 's' for singular)
    var singular = name;
    if (singular.len > 0 and singular[singular.len - 1] == 's') {
        singular = singular[0 .. singular.len - 1];
    }
    return try allocator.dupe([]const u8, &.{
        try std.fmt.allocPrint(allocator, ".{s}.ts", .{singular}),
        ".config.ts",
    });
}

/// rewrite architecture.config.json with a new surface appended
fn rewriteConfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    name: []const u8,
    path: []const u8,
    depth: u32,
    suffixes: []const []const u8,
    innateMembers: []const []const u8,
    allowedImports: [][]const u8,
) !void {
    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(allocator);

    // write opening
    try json_buf.appendSlice(allocator, "{\n  \"surfaces\": [\n");

    // write existing surfaces
    for (cfg.surfaces, 0..) |surface, i| {
        try writeSurfaceJson(&json_buf, surface, allocator);
        if (i < cfg.surfaces.len - 1) try json_buf.appendSlice(allocator, ",\n");
    }

    // write new surface
    try json_buf.appendSlice(allocator, ",\n");
    try json_buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "    {{\n      \"name\": \"{s}\",\n      \"path\": \"{s}\",\n      \"depth\": {d},\n      \"suffixes\": [", .{ name, path, depth }));
    for (suffixes, 0..) |suffix, j| {
        try json_buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"{s}\"", .{suffix}));
        if (j < suffixes.len - 1) try json_buf.appendSlice(allocator, ", ");
    }

    try json_buf.appendSlice(allocator, "],\n      \"innateMembers\": [");
    for (innateMembers, 0..) |innate, j| {
        try json_buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"{s}\"", .{innate}));
        if (j < innateMembers.len - 1) try json_buf.appendSlice(allocator, ", ");
    }

    try json_buf.appendSlice(allocator, "],\n      \"allowedImports\": [");
    for (allowedImports, 0..) |imp, j| {
        try json_buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"{s}\"", .{imp}));
        if (j < allowedImports.len - 1) try json_buf.appendSlice(allocator, ", ");
    }

    try json_buf.appendSlice(allocator, "]\n    }\n  ],\n");

    // write layers
    try json_buf.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\  "layers": {{
        \\    "cosmetic": {},
        \\    "structural": {},
        \\    "resilience": {},
        \\    "behavioural": {}
        \\  }}
    , .{ cfg.layers.cosmetic, cfg.layers.structural, cfg.layers.resilience, cfg.layers.behavioural }));

    // write rootLib if enabled
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

fn writeSurfaceJson(buf: *std.ArrayList(u8), surface: config.Surface, allocator: std.mem.Allocator) !void {
    try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "    {{\n      \"name\": \"{s}\",\n      \"path\": \"{s}\",\n      \"depth\": {d},\n      \"suffixes\": [", .{ surface.name, surface.path, surface.depth }));
    for (surface.suffixes, 0..) |suffix, j| {
        try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"{s}\"", .{suffix}));
        if (j < surface.suffixes.len - 1) try buf.appendSlice(allocator, ", ");
    }
    try buf.appendSlice(allocator, "],\n      \"innateMembers\": [");
    for (surface.innateMembers, 0..) |innate, j| {
        try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"{s}\"", .{innate}));
        if (j < surface.innateMembers.len - 1) try buf.appendSlice(allocator, ", ");
    }
    try buf.appendSlice(allocator, "],\n      \"allowedImports\": [");
    for (surface.allowedImports, 0..) |imp, j| {
        try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"{s}\"", .{imp}));
        if (j < surface.allowedImports.len - 1) try buf.appendSlice(allocator, ", ");
    }
    try buf.appendSlice(allocator, "]\n    }");
}
