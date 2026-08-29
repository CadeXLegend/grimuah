const std = @import("std");
const config = @import("../config.zig");
const gritql = @import("../gritql.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, surface_name: []const u8) !void {
    var parsed = config.load(io, allocator, "architecture.config.json") catch |err| {
        std.debug.print("error: could not load architecture.config.json: {s}\n", .{@errorName(err)});
        return;
    };
    defer parsed.deinit();
    var cfg = parsed.value;

    // check surface exists
    const target = cfg.getSurface(surface_name) orelse {
        std.debug.print("error: surface '{s}' not found\n", .{surface_name});
        return;
    };

    std.debug.print("removing surface '{s}'...\n", .{surface_name});

    // remove the directory
    const dir_path = try std.fmt.allocPrint(allocator, "{s}", .{target.path});
    defer allocator.free(dir_path);

    std.Io.Dir.cwd().deleteTree(io, dir_path) catch |err| {
        std.debug.print("warning: could not remove directory '{s}': {s}\n", .{ dir_path, @errorName(err) });
    };

    // regenerate architecture.config.json without the removed surface
    try rewriteConfigWithout(io, allocator, &cfg, surface_name);

    // regenerate GritQL rules
    try gritql.generateRules(io, allocator, ".", &cfg);

    std.debug.print("removed surface '{s}'\n", .{surface_name});
}

fn rewriteConfigWithout(io: std.Io, allocator: std.mem.Allocator, cfg: *config.Config, remove_name: []const u8) !void {
    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(allocator);

    const removed_surface = cfg.getSurface(remove_name).?;
    const removed_dag_order = removed_surface.dagOrder;

    try json_buf.appendSlice(allocator, "{\n  \"surfaces\": [\n");

    var written: usize = 0;
    for (cfg.surfaces) |surface| {
        if (std.mem.eql(u8, surface.name, remove_name)) continue;

        // shift dagOrder down if the removed surface is ordered before this one
        const new_dag_order = if (surface.dagOrder > removed_dag_order) surface.dagOrder - 1 else surface.dagOrder;

        if (written > 0) try json_buf.appendSlice(allocator, ",\n");

        try json_buf.appendSlice(allocator, try std.fmt.allocPrint(
            allocator,
            "    {{\n      \"name\": \"{s}\",\n      \"path\": \"{s}\",\n      \"depth\": {d},\n      \"dagOrder\": {d},\n      \"suffixes\": [",
            .{ surface.name, surface.path, surface.depth, new_dag_order },
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
        // also strip the removed surface from allowedImports
        var imp_written: usize = 0;
        for (surface.allowedImports) |imp| {
            if (std.mem.eql(u8, imp, remove_name)) continue;
            if (imp_written > 0) try json_buf.appendSlice(allocator, ", ");
            try json_buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"{s}\"", .{imp}));
            imp_written += 1;
        }

        try json_buf.appendSlice(allocator, "]\n    }");
        written += 1;
    }

    try json_buf.appendSlice(allocator, "\n  ],\n");

    // write layers
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
