const std = @import("std");

/// surface definition — one entry in the surfaces array of architecture.config.json
pub const Surface = struct {
    name: []const u8,
    path: []const u8,
    depth: u32,
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
        // only free path when rootLib was present in JSON (indicated by enabled=true)
        // when enabled=false with the default, path is a comptime literal
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
        // deeper surface can import from shallower if listed in allowed_imports
        if (from.depth <= to.depth) {
            for (from.allowedImports) |allowed| {
                if (std.mem.eql(u8, allowed, to_name)) return true;
            }
        }
        // shallower → deeper: always allowed (top-down DAG)
        return from.depth > to.depth;
    }

    /// find which surface owns a given file path, or null if none
    pub fn owningSurface(self: *const Config, file_path: []const u8) ?*const Surface {
        for (self.surfaces) |*surface| {
            if (std.mem.startsWith(u8, file_path, surface.path)) return surface;
        }
        return null;
    }
};

/// validation error — returned when config fails structural checks
pub const ValidationError = error{
    DuplicateSurfaceNames,
    DuplicateDepths,
    EmptySurfaces,
    InvalidDepthOrder,
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

    // no duplicate depths — each surface must have a unique depth
    for (config.surfaces, 0..) |surface_a, i| {
        for (config.surfaces[i + 1 ..]) |surface_b| {
            if (surface_a.depth == surface_b.depth)
                return ValidationError.DuplicateDepths;
        }
    }

    // depths must be sequential starting from 0
    for (0..config.surfaces.len) |expected_depth| {
        var found = false;
        for (config.surfaces) |surface| {
            if (surface.depth == expected_depth) {
                found = true;
                break;
            }
        }
        if (!found) return ValidationError.InvalidDepthOrder;
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
fn testSurface(allocator: std.mem.Allocator, name: []const u8, path: []const u8, depth: u32, suffixes: []const []const u8) !Surface {
    const owned_name = try allocator.dupe(u8, name);
    const owned_path = try allocator.dupe(u8, path);
    const owned_suffixes = try allocator.alloc([]const u8, suffixes.len);
    for (suffixes, 0..) |suf, idx| {
        owned_suffixes[idx] = try allocator.dupe(u8, suf);
    }
    return .{ .name = owned_name, .path = owned_path, .depth = depth, .suffixes = owned_suffixes };
}

test "canImport top-down DAG rules" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 3);
    surfaces[0] = try testSurface(allocator, "utils", "src/utils", 0, &.{".util.ts"});
    surfaces[1] = try testSurface(allocator, "services", "src/services", 1, &.{".service.ts"});
    surfaces[2] = try testSurface(allocator, "components", "src/components", 2, &.{".component.ts"});

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    // deeper → shallower: always allowed
    try testing.expect(cfg.canImport("components", "utils"));
    try testing.expect(cfg.canImport("services", "utils"));

    // shallower → deeper: denied without explicit allowed_imports
    try testing.expect(!cfg.canImport("utils", "components"));
    try testing.expect(!cfg.canImport("utils", "services"));

    // same surface: always allowed
    try testing.expect(cfg.canImport("utils", "utils"));

    // unknown surface
    try testing.expect(!cfg.canImport("ghost", "utils"));
    try testing.expect(!cfg.canImport("utils", "ghost"));

    // same depth: denied without explicit allowed_imports
    try testing.expect(!cfg.canImport("services", "components"));
}

test "canImport with explicit allowed_imports allows shallower→deeper" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 2);
    surfaces[0] = try testSurface(allocator, "utils", "src/utils", 0, &.{".util.ts"});
    var utils_allowed = try allocator.alloc([]const u8, 1);
    utils_allowed[0] = try allocator.dupe(u8, "services");
    surfaces[0].allowedImports = utils_allowed;
    surfaces[1] = try testSurface(allocator, "services", "src/services", 1, &.{".service.ts"});

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    try testing.expect(cfg.canImport("utils", "services"));
}

test "canImport same depth with explicit allowed_imports" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 2);
    surfaces[0] = try testSurface(allocator, "commands", "src/commands", 5, &.{".command.ts"});
    var commands_allowed = try allocator.alloc([]const u8, 1);
    commands_allowed[0] = try allocator.dupe(u8, "tasks");
    surfaces[0].allowedImports = commands_allowed;
    surfaces[1] = try testSurface(allocator, "tasks", "src/tasks", 5, &.{".task.ts"});

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
    surfaces[0] = try testSurface(allocator, "utils", "src/utils", 0, &.{".util.ts"});
    surfaces[1] = try testSurface(allocator, "utils", "src/other", 1, &.{".other.ts"});

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    try testing.expectError(ValidationError.DuplicateSurfaceNames, validate(&cfg));
}

test "validate catches DuplicateDepths" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 2);
    surfaces[0] = try testSurface(allocator, "utils", "src/utils", 0, &.{".util.ts"});
    surfaces[1] = try testSurface(allocator, "services", "src/services", 0, &.{".service.ts"});

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    try testing.expectError(ValidationError.DuplicateDepths, validate(&cfg));
}

test "validate catches InvalidDepthOrder" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 2);
    surfaces[0] = try testSurface(allocator, "utils", "src/utils", 0, &.{".util.ts"});
    surfaces[1] = try testSurface(allocator, "services", "src/services", 2, &.{".service.ts"});

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    try testing.expectError(ValidationError.InvalidDepthOrder, validate(&cfg));
}

test "validate catches MissingSurfaceInEdge" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 2);
    surfaces[0] = try testSurface(allocator, "utils", "src/utils", 0, &.{".util.ts"});
    var utils_edge = try allocator.alloc([]const u8, 1);
    utils_edge[0] = try allocator.dupe(u8, "ghost");
    surfaces[0].allowedImports = utils_edge;
    surfaces[1] = try testSurface(allocator, "services", "src/services", 1, &.{".service.ts"});

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    try testing.expectError(ValidationError.MissingSurfaceInEdge, validate(&cfg));
}

test "validate passes for valid config" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 3);
    surfaces[0] = try testSurface(allocator, "utils", "src/utils", 0, &.{".util.ts"});
    var utils_allowed_imports = try allocator.alloc([]const u8, 1);
    utils_allowed_imports[0] = try allocator.dupe(u8, "services");
    surfaces[0].allowedImports = utils_allowed_imports;
    surfaces[1] = try testSurface(allocator, "services", "src/services", 1, &.{".service.ts"});
    surfaces[2] = try testSurface(allocator, "components", "src/components", 2, &.{".component.ts"});
    var components_allowed = try allocator.alloc([]const u8, 2);
    components_allowed[0] = try allocator.dupe(u8, "utils");
    components_allowed[1] = try allocator.dupe(u8, "services");
    surfaces[2].allowedImports = components_allowed;

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    try validate(&cfg);
}
