const std = @import("std");

/// surface definition, one entry in the surfaces array of architecture.config.json
pub const Surface = struct {
    name: []const u8,
    path: []const u8,
    depth: u32,
    dagOrder: u32,
    suffixes: []const []const u8,
    innateMembers: []const []const u8 = &.{},
    allowedImports: []const []const u8 = &.{},

    pub fn deinit(self: *const Surface, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        for (self.suffixes) |s| allocator.free(s);
        if (self.suffixes.len > 0) allocator.free(self.suffixes);
        for (self.innateMembers) |s| allocator.free(s);
        if (self.innateMembers.len > 0) allocator.free(self.innateMembers);
        for (self.allowedImports) |s| allocator.free(s);
        if (self.allowedImports.len > 0) allocator.free(self.allowedImports);
    }
};

/// rule layer toggles
pub const Layers = struct {
    cosmetic: bool,
    structural: bool,
    resilience: bool,
    behavioural: bool,
};

/// optional root-level lib/ surface at depth 0
pub const RootLib = struct {
    enabled: bool,
    path: []const u8,

    pub fn deinit(self: *const RootLib, allocator: std.mem.Allocator) void {
        if (self.enabled) allocator.free(self.path);
    }
};

/// parsed architecture configuration
pub const Config = struct {
    surfaces: []Surface,
    layers: Layers,
    rootLib: RootLib = .{ .enabled = false, .path = "lib" },

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        for (self.surfaces) |*surface| surface.deinit(allocator);
        allocator.free(self.surfaces);
        self.rootLib.deinit(allocator);
    }

    /// get a surface by name, or null if not found
    pub fn getSurface(self: *const Config, name: []const u8) ?*const Surface {
        for (self.surfaces) |*surface| {
            if (std.mem.eql(u8, surface.name, name)) return surface;
        }
        return null;
    }

    /// check if `from` surface is allowed to import from `to` surface
    pub fn canImport(self: *const Config, from_name: []const u8, to_name: []const u8) bool {
        const from = self.getSurface(from_name) orelse return false;
        const to = self.getSurface(to_name) orelse return false;
        // a surface can always import from itself
        if (std.mem.eql(u8, from_name, to_name)) return true;
        // from has same or lower dagOrder (shallower in DAG): allowed only if explicitly listed
        if (from.dagOrder <= to.dagOrder) {
            for (from.allowedImports) |allowed| {
                if (std.mem.eql(u8, allowed, to_name)) return true;
            }
        }
        // from has higher dagOrder (deeper in DAG): always allowed (top-down DAG)
        return from.dagOrder > to.dagOrder;
    }

    /// find which surface owns a given file path, or null if none
    pub fn owningSurface(self: *const Config, file_path: []const u8) ?*const Surface {
        for (self.surfaces) |*surface| {
            if (std.mem.startsWith(u8, file_path, surface.path)) return surface;
        }
        return null;
    }
};

/// validation error, returned when config fails structural checks
pub const ValidationError = error{
    DuplicateSurfaceNames,
    DuplicateDagOrders,
    EmptySurfaces,
    InvalidDagOrder,
    InvalidRootLibPath,
    MissingSurfaceInEdge,
};

/// validate structural invariants of a loaded config
pub fn validate(config: *const Config) ValidationError!void {
    if (config.surfaces.len == 0) return ValidationError.EmptySurfaces;

    // no duplicate surface names
    for (config.surfaces, 0..) |surface_a, i| {
        for (config.surfaces[i + 1 ..]) |surface_b| {
            if (std.mem.eql(u8, surface_a.name, surface_b.name))
                return ValidationError.DuplicateSurfaceNames;
        }
    }

    // no duplicate dagOrders: each surface must have a unique DAG order
    for (config.surfaces, 0..) |surface_a, i| {
        for (config.surfaces[i + 1 ..]) |surface_b| {
            if (surface_a.dagOrder == surface_b.dagOrder)
                return ValidationError.DuplicateDagOrders;
        }
    }

    // dagOrders must be sequential starting from 0
    for (0..config.surfaces.len) |expected| {
        var found = false;
        for (config.surfaces) |surface| {
            if (surface.dagOrder == expected) {
                found = true;
                break;
            }
        }
        if (!found) return ValidationError.InvalidDagOrder;
    }

    // all edge references must point to real surfaces
    for (config.surfaces) |surface| {
        for (surface.allowedImports) |import_name| {
            if (config.getSurface(import_name) == null)
                return ValidationError.MissingSurfaceInEdge;
        }
    }

    // rootLib path must be non-empty when enabled
    if (config.rootLib.enabled and config.rootLib.path.len == 0)
        return ValidationError.InvalidRootLibPath;
}

/// load and parse architecture.config.json from a file path
/// caller owns the returned Parsed (call .deinit())
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Config) {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(raw);

    return try std.json.parseFromSlice(Config, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// create a single Surface with heap-allocated fields for testing
fn testSurface(allocator: std.mem.Allocator, name: []const u8, path: []const u8, depth: u32, dagOrder: u32, suffixes: []const []const u8) !Surface {
    const owned_name = try allocator.dupe(u8, name);
    const owned_path = try allocator.dupe(u8, path);
    const owned_suffixes = try allocator.alloc([]const u8, suffixes.len);
    for (suffixes, 0..) |suf, idx| {
        owned_suffixes[idx] = try allocator.dupe(u8, suf);
    }
    return .{ .name = owned_name, .path = owned_path, .depth = depth, .dagOrder = dagOrder, .suffixes = owned_suffixes };
}

test "canImport top-down DAG rules" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 3);
    surfaces[0] = try testSurface(allocator, "utils", "src/utils", 1, 0, &.{".util.ts"});
    surfaces[1] = try testSurface(allocator, "services", "src/services", 1, 1, &.{".service.ts"});
    surfaces[2] = try testSurface(allocator, "components", "src/components", 1, 2, &.{".component.ts"});

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    // deeper (higher dagOrder) → shallower (lower dagOrder): always allowed
    try testing.expect(cfg.canImport("components", "utils"));
    try testing.expect(cfg.canImport("services", "utils"));

    // shallower (lower dagOrder) → deeper (higher dagOrder): denied without explicit allowed_imports
    try testing.expect(!cfg.canImport("utils", "components"));
    try testing.expect(!cfg.canImport("utils", "services"));

    // same surface: always allowed
    try testing.expect(cfg.canImport("utils", "utils"));

    // unknown surface
    try testing.expect(!cfg.canImport("ghost", "utils"));
    try testing.expect(!cfg.canImport("utils", "ghost"));

    // same dagOrder (shouldn't happen with valid config, but defensive check)
    try testing.expect(!cfg.canImport("services", "components"));
}

test "canImport with explicit allowed_imports allows shallow-to-deep" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 2);
    surfaces[0] = try testSurface(allocator, "utils", "src/utils", 1, 0, &.{".util.ts"});
    var utils_allowed = try allocator.alloc([]const u8, 1);
    utils_allowed[0] = try allocator.dupe(u8, "services");
    surfaces[0].allowedImports = utils_allowed;
    surfaces[1] = try testSurface(allocator, "services", "src/services", 1, 1, &.{".service.ts"});

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    try testing.expect(cfg.canImport("utils", "services"));
}

test "canImport same dagOrder with explicit allowed_imports" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 2);
    surfaces[0] = try testSurface(allocator, "commands", "src/commands", 1, 5, &.{".command.ts"});
    var commands_allowed = try allocator.alloc([]const u8, 1);
    commands_allowed[0] = try allocator.dupe(u8, "tasks");
    surfaces[0].allowedImports = commands_allowed;
    surfaces[1] = try testSurface(allocator, "tasks", "src/tasks", 1, 5, &.{".task.ts"});

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    try testing.expect(cfg.canImport("commands", "tasks"));
    // reverse: tasks → commands not explicitly allowed
    try testing.expect(!cfg.canImport("tasks", "commands"));
}

test "validate catches EmptySurfaces" {
    const allocator = testing.allocator;
    const cfg = Config{ .surfaces = &.{}, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    try testing.expectError(ValidationError.EmptySurfaces, validate(&cfg));
    _ = allocator;
}

test "validate catches DuplicateSurfaceNames" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 2);
    surfaces[0] = try testSurface(allocator, "utils", "src/utils", 1, 0, &.{".util.ts"});
    surfaces[1] = try testSurface(allocator, "utils", "src/other", 1, 1, &.{".other.ts"});

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    try testing.expectError(ValidationError.DuplicateSurfaceNames, validate(&cfg));
}

test "validate catches DuplicateDagOrders" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 2);
    surfaces[0] = try testSurface(allocator, "utils", "src/utils", 1, 0, &.{".util.ts"});
    surfaces[1] = try testSurface(allocator, "services", "src/services", 1, 0, &.{".service.ts"});

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    try testing.expectError(ValidationError.DuplicateDagOrders, validate(&cfg));
}

test "validate catches InvalidDagOrder" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 2);
    surfaces[0] = try testSurface(allocator, "utils", "src/utils", 1, 0, &.{".util.ts"});
    surfaces[1] = try testSurface(allocator, "services", "src/services", 1, 2, &.{".service.ts"});

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    try testing.expectError(ValidationError.InvalidDagOrder, validate(&cfg));
}

test "validate catches MissingSurfaceInEdge" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 2);
    surfaces[0] = try testSurface(allocator, "utils", "src/utils", 1, 0, &.{".util.ts"});
    var utils_edge = try allocator.alloc([]const u8, 1);
    utils_edge[0] = try allocator.dupe(u8, "ghost");
    surfaces[0].allowedImports = utils_edge;
    surfaces[1] = try testSurface(allocator, "services", "src/services", 1, 1, &.{".service.ts"});

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    try testing.expectError(ValidationError.MissingSurfaceInEdge, validate(&cfg));
}

test "validate passes for valid config" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 3);
    surfaces[0] = try testSurface(allocator, "utils", "src/utils", 1, 0, &.{".util.ts"});
    var utils_allowed_imports = try allocator.alloc([]const u8, 1);
    utils_allowed_imports[0] = try allocator.dupe(u8, "services");
    surfaces[0].allowedImports = utils_allowed_imports;
    surfaces[1] = try testSurface(allocator, "services", "src/services", 1, 1, &.{".service.ts"});
    surfaces[2] = try testSurface(allocator, "components", "src/components", 1, 2, &.{".component.ts"});
    var components_allowed = try allocator.alloc([]const u8, 2);
    components_allowed[0] = try allocator.dupe(u8, "utils");
    components_allowed[1] = try allocator.dupe(u8, "services");
    surfaces[2].allowedImports = components_allowed;

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    try validate(&cfg);
}

/// biome-format-clean json emitter, mirrors std.json.Formatter so it works in
/// {f} format strings
/// hand-rolled because std.json's indent options expand arrays onto separate
/// lines while biome's formatter inlines them
/// biome's formatter inlines an array when the whole line fits its line width
/// and expands it otherwise, so this emitter applies the same rule
pub const Formatter = struct {
    value: *const Config,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.writeConfig(writer);
        try writer.writeByte('\n');
    }

    fn writeConfig(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const config = self.value;
        try writer.writeAll("{\n  \"surfaces\": [\n");
        for (config.surfaces, 0..) |surface, surface_index| {
            const is_last_surface = surface_index + 1 == config.surfaces.len;
            try writer.writeAll("    {\n");
            try writer.writeAll("      \"name\": ");
            try std.json.Stringify.value(surface.name, .{}, writer);
            try writer.writeAll(",\n      \"path\": ");
            try std.json.Stringify.value(surface.path, .{}, writer);
            try writer.print(",\n      \"depth\": {},", .{surface.depth});
            try writer.print("\n      \"dagOrder\": {}", .{surface.dagOrder});
            try writer.writeAll(",\n      ");
            try writeArrayField(writer, "suffixes", surface.suffixes, true);
            try writer.writeAll("\n      ");
            try writeArrayField(writer, "innateMembers", surface.innateMembers, true);
            try writer.writeAll("\n      ");
            try writeArrayField(writer, "allowedImports", surface.allowedImports, false);
            try writer.writeAll(if (is_last_surface) "\n    }\n" else "\n    },\n");
        }
        try writer.writeAll("  ],\n  \"layers\": {\n");
        try writer.print("    \"cosmetic\": {},\n", .{config.layers.cosmetic});
        try writer.print("    \"structural\": {},\n", .{config.layers.structural});
        try writer.print("    \"resilience\": {},\n", .{config.layers.resilience});
        try writer.print("    \"behavioural\": {}\n", .{config.layers.behavioural});
        try writer.writeAll("  },\n  \"rootLib\": {\n");
        try writer.print("    \"enabled\": {},\n", .{config.rootLib.enabled});
        try writer.writeAll("    \"path\": ");
        try std.json.Stringify.value(config.rootLib.path, .{}, writer);
        try writer.writeAll("\n  }\n}");
    }

    fn writeArrayField(writer: *std.Io.Writer, key: []const u8, values: []const []const u8, has_trailing_comma: bool) std.Io.Writer.Error!void {
        const FIELD_INDENT = 6;
        const line_len = FIELD_INDENT + key.len + KEY_PREFIX_OVERHEAD + inlineArrayLen(values) + @intFromBool(has_trailing_comma);
        if (line_len <= LINE_WIDTH) {
            try writer.writeAll("\"");
            try writer.writeAll(key);
            try writer.writeAll("\": ");
            try writeInlineArray(writer, values);
        } else {
            try writer.writeAll("\"");
            try writer.writeAll(key);
            try writer.writeAll("\": [\n");
            for (values, 0..) |value, value_index| {
                const is_last_element = value_index + 1 == values.len;
                try writer.writeAll("        ");
                try std.json.Stringify.value(value, .{}, writer);
                try writer.writeAll(if (is_last_element) "\n" else ",\n");
            }
            try writer.writeAll("      ]");
        }
        if (has_trailing_comma) try writer.writeByte(',');
    }

    /// length of the inline form of an array, e.g. ["a", "b"]
    /// assumes values need no json escaping, true for surface names, paths,
    /// and suffixes
    fn inlineArrayLen(values: []const []const u8) usize {
        var len: usize = 2; // brackets
        for (values, 0..) |value, value_index| {
            if (value_index > 0) len += 2; // ", " separator
            len += value.len + 2; // quoted value
        }
        return len;
    }

    fn writeInlineArray(writer: *std.Io.Writer, values: []const []const u8) std.Io.Writer.Error!void {
        try writer.writeByte('[');
        for (values, 0..) |value, value_index| {
            if (value_index > 0) try writer.writeAll(", ");
            try std.json.Stringify.value(value, .{}, writer);
        }
        try writer.writeByte(']');
    }
};

/// biome's default formatter line width, kept in sync with the generated
/// biome.json which does not override lineWidth
const LINE_WIDTH = 80;

/// chars around the key in `"key": `, two quotes, a colon, and a space
const KEY_PREFIX_OVERHEAD = 4;

test "formatter emits biome-clean json" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 2);
    surfaces[0] = try testSurface(allocator, "lib", "lib", 0, 0, &.{".ts"});
    surfaces[1] = try testSurface(allocator, "services", "src/services", 1, 1, &.{ ".service.ts", ".config.ts" });
    surfaces[1].innateMembers = &.{ ".types.ts", ".config.ts", ".spec.ts", ".regex-patterns.ts" };
    surfaces[1].allowedImports = &.{ "lib", "db" };
    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    var buf: [1024]u8 = undefined;
    const json = try std.fmt.bufPrint(&buf, "{f}", .{Formatter{ .value = &cfg }});
    const expected =
        \\{
        \\  "surfaces": [
        \\    {
        \\      "name": "lib",
        \\      "path": "lib",
        \\      "depth": 0,
        \\      "dagOrder": 0,
        \\      "suffixes": [".ts"],
        \\      "innateMembers": [],
        \\      "allowedImports": []
        \\    },
        \\    {
        \\      "name": "services",
        \\      "path": "src/services",
        \\      "depth": 1,
        \\      "dagOrder": 1,
        \\      "suffixes": [".service.ts", ".config.ts"],
        \\      "innateMembers": [
        \\        ".types.ts",
        \\        ".config.ts",
        \\        ".spec.ts",
        \\        ".regex-patterns.ts"
        \\      ],
        \\      "allowedImports": ["lib", "db"]
        \\    }
        \\  ],
        \\  "layers": {
        \\    "cosmetic": true,
        \\    "structural": true,
        \\    "resilience": true,
        \\    "behavioural": true
        \\  },
        \\  "rootLib": {
        \\    "enabled": false,
        \\    "path": "lib"
        \\  }
        \\}
    ;
    try testing.expectEqualStrings(expected ++ "\n", json);
}
