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
    /// repo-relative directories the lint walk starts from. this is the whole
    /// ignore list: a file outside every root is not part of the declared
    /// architecture, so nothing lints it, and build output, agent scratch
    /// directories and vendored trees need no glob patterns to be skipped
    ///
    /// absent means "derive it from the surfaces" (see `lintRootAt`), so a
    /// config that predates the field keeps the same scope
    sourceRoots: []const []const u8 = &.{},
    surfaces: []Surface,
    layers: Layers,
    rootLib: RootLib = .{ .enabled = false, .path = "lib" },

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        for (self.sourceRoots) |root| allocator.free(root);
        if (self.sourceRoots.len > 0) allocator.free(self.sourceRoots);
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

    /// true when `file_path` sits under a declared source root or rootLib
    pub fn lintsFile(self: *const Config, file_path: []const u8) bool {
        var index: usize = 0;
        while (index < self.lintRootCount()) : (index += 1) {
            if (pathIsWithin(file_path, self.lintRootAt(index))) return true;
        }
        return self.rootLib.enabled and pathIsWithin(file_path, self.rootLib.path);
    }

    /// the walk's prune test: true when descending into `dir_path` could still
    /// reach a linted file, i.e. some root sits inside it or above it
    pub fn mayContainLintedFile(self: *const Config, dir_path: []const u8) bool {
        var index: usize = 0;
        while (index < self.lintRootCount()) : (index += 1) {
            const root = self.lintRootAt(index);
            if (pathIsWithin(root, dir_path) or pathIsWithin(dir_path, root)) return true;
        }
        if (self.rootLib.enabled) {
            if (pathIsWithin(self.rootLib.path, dir_path) or pathIsWithin(dir_path, self.rootLib.path)) return true;
        }
        return false;
    }

    /// how many lint roots this config has. a config that declares none derives
    /// one per surface, so the count follows the surfaces instead
    fn lintRootCount(self: *const Config) usize {
        return if (self.sourceRoots.len > 0) self.sourceRoots.len else self.surfaces.len;
    }

    fn lintRootAt(self: *const Config, index: usize) []const u8 {
        if (self.sourceRoots.len > 0) return self.sourceRoots[index];
        return surfaceContainer(self.surfaces[index].path);
    }

    /// find which surface owns a given normalised repo-relative path, or null
    /// matches on segment boundaries, so "src/db-extra/x.ts" is not inside "src/db",
    /// and keeps the longest match, so a nested surface path beats its parent
    pub fn owningSurface(self: *const Config, file_path: []const u8) ?*const Surface {
        var owner: ?*const Surface = null;
        for (self.surfaces) |*surface| {
            if (!pathIsWithin(file_path, surface.path)) continue;
            if (owner == null or surface.path.len > owner.?.path.len) owner = surface;
        }
        return owner;
    }
};

/// the directory a lint walk starts from for a surface that declared no source
/// roots: its container. a surface sitting at the project root is its own
/// container, because the root above it is the whole repo and taking that would
/// lint every unrelated tree in it
fn surfaceContainer(surface_path: []const u8) []const u8 {
    const parent = std.fs.path.dirname(surface_path) orelse return surface_path;
    if (parent.len == 0) return surface_path;
    return parent;
}

/// true when `file_path` is `dir_path` itself or sits underneath it, the
/// boundary check keeps "src/db-extra" from matching the "src/db" surface
fn pathIsWithin(file_path: []const u8, dir_path: []const u8) bool {
    if (dir_path.len == 0) return false;
    if (!std.mem.startsWith(u8, file_path, dir_path)) return false;
    if (file_path.len == dir_path.len) return true;
    return file_path[dir_path.len] == '/';
}

/// validation error, returned when config fails structural checks
pub const ValidationError = error{
    DuplicateSurfaceNames,
    DuplicateDagOrders,
    EmptySourceRoot,
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

    // a source root must name a directory, an empty string would silently match
    // no path at all and lint nothing
    for (config.sourceRoots) |root| {
        if (root.len == 0) return ValidationError.EmptySourceRoot;
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

    const cfg = Config{ .surfaces = surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    defer cfg.deinit(allocator);

    try validate(&cfg);
}

/// compact json emitter, mirrors std.json.Formatter so it works in {f} format
/// strings
/// hand-rolled because std.json's indent options expand arrays onto separate
/// lines while a generated config reads better with them inlined
/// an array is inlined when the whole line fits the width and expanded
/// otherwise, so a generated config stays stable across regeneration
pub const Formatter = struct {
    value: *const Config,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.writeConfig(writer);
        try writer.writeByte('\n');
    }

    fn writeConfig(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const config = self.value;
        try writer.writeAll("{");
        // omitted when absent, so a derived config round-trips unchanged and the
        // field only appears once the project declares roots
        if (config.sourceRoots.len > 0) {
            try writer.writeAll("\n  ");
            try writeArrayField(writer, "sourceRoots", config.sourceRoots, true, TOP_LEVEL_INDENT);
        }
        try writer.writeAll("\n  \"surfaces\": [\n");
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
            try writeArrayField(writer, "suffixes", surface.suffixes, true, SURFACE_FIELD_INDENT);
            try writer.writeAll("\n      ");
            try writeArrayField(writer, "innateMembers", surface.innateMembers, true, SURFACE_FIELD_INDENT);
            try writer.writeAll("\n      ");
            try writeArrayField(writer, "allowedImports", surface.allowedImports, false, SURFACE_FIELD_INDENT);
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

    fn writeArrayField(writer: *std.Io.Writer, key: []const u8, values: []const []const u8, has_trailing_comma: bool, indent: usize) std.Io.Writer.Error!void {
        const line_len = indent + key.len + KEY_PREFIX_OVERHEAD + inlineArrayLen(values) + @intFromBool(has_trailing_comma);
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
                try writer.splatByteAll(' ', indent + 2);
                try std.json.Stringify.value(value, .{}, writer);
                try writer.writeAll(if (is_last_element) "\n" else ",\n");
            }
            try writer.splatByteAll(' ', indent);
            try writer.writeAll("]");
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

/// the width a generated config wraps at, so the layout stays stable across
/// regeneration
const LINE_WIDTH = 80;

/// indent of a field directly inside the root object
const TOP_LEVEL_INDENT = 2;

/// indent of a field inside a surface object
const SURFACE_FIELD_INDENT = 6;

/// chars around the key in `"key": `, two quotes, a colon, and a space
const KEY_PREFIX_OVERHEAD = 4;

test "formatter emits compact json" {
    const allocator = testing.allocator;

    var surfaces = try allocator.alloc(Surface, 2);
    surfaces[0] = try testSurface(allocator, "lib", "lib", 0, 0, &.{".ts"});
    surfaces[1] = try testSurface(allocator, "services", "src/services", 1, 1, &.{".service.ts"});
    // both fields are owned by the surface once set, so they have to be
    // allocated: Surface.deinit frees every element
    const innate_members = try allocator.alloc([]const u8, 4);
    for ([_][]const u8{ ".types.ts", ".config.ts", ".spec.ts", ".regex-patterns.ts" }, 0..) |literal, index| {
        innate_members[index] = try allocator.dupe(u8, literal);
    }
    surfaces[1].innateMembers = innate_members;

    const allowed_imports = try allocator.alloc([]const u8, 2);
    for ([_][]const u8{ "lib", "db" }, 0..) |literal, index| {
        allowed_imports[index] = try allocator.dupe(u8, literal);
    }
    surfaces[1].allowedImports = allowed_imports;
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
        \\      "suffixes": [".service.ts"],
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

/// surfaces shaped like a real project: most live under `src/`, while `lib` and
/// `gateway` sit at the project root. returned by value so each caller owns its
/// own copy and can hand out a pointer to it
fn testProjectSurfaces() [3]Surface {
    return .{
        .{ .name = "lib", .path = "lib", .depth = 0, .dagOrder = 0, .suffixes = &.{".ts"} },
        .{ .name = "db", .path = "src/db", .depth = 1, .dagOrder = 1, .suffixes = &.{".repo.ts"} },
        .{ .name = "gateway", .path = "gateway", .depth = 1, .dagOrder = 2, .suffixes = &.{".ts"} },
    };
}

test "lintsFile uses the declared source roots as the whole ignore list" {
    var roots = [_][]const u8{ "src", "scripts" };
    var surfaces = testProjectSurfaces();
    const cfg = Config{
        .sourceRoots = &roots,
        .surfaces = &surfaces,
        .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true },
        .rootLib = .{ .enabled = true, .path = "lib" },
    };

    try testing.expect(cfg.lintsFile("src/bot.ts"));
    try testing.expect(cfg.lintsFile("src/db/x.repo.ts"));
    try testing.expect(cfg.lintsFile("scripts/seed.ts"));
    try testing.expect(cfg.lintsFile("lib/x.ts"));
    // a declared root is the whole ignore list: build output and agent scratch
    // directories are outside every root and need no glob patterns
    try testing.expect(!cfg.lintsFile("dist/foo.ts"));
    try testing.expect(!cfg.lintsFile(".rpiv/artifacts/x.mjs"));
    // declared roots replace the derivation, so a surface outside them is out
    try testing.expect(!cfg.lintsFile("gateway/bot.ts"));
}

test "a config without source roots derives them from the surface containers" {
    var surfaces = testProjectSurfaces();
    const cfg = Config{
        .surfaces = &surfaces,
        .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true },
    };

    // the container of src/db is src, so a file sitting directly in src belongs
    // to the declared architecture even though no surface path covers it
    try testing.expect(cfg.lintsFile("src/bot.ts"));
    try testing.expect(cfg.lintsFile("src/db/x.repo.ts"));
    // a root-level surface is its own container, the repo root above it would
    // pull in every unrelated tree
    try testing.expect(cfg.lintsFile("gateway/bot.ts"));
    try testing.expect(cfg.lintsFile("lib/x.ts"));
    try testing.expect(!cfg.lintsFile("dist/foo.ts"));
    try testing.expect(!cfg.lintsFile(".rpiv/artifacts/x.mjs"));
}

test "mayContainLintedFile keeps the walk open only above a lint root" {
    var surfaces = testProjectSurfaces();
    const cfg = Config{
        .surfaces = &surfaces,
        .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true },
    };

    try testing.expect(cfg.mayContainLintedFile("src"));
    try testing.expect(cfg.mayContainLintedFile("src/db"));
    try testing.expect(cfg.mayContainLintedFile("gateway"));
    try testing.expect(cfg.mayContainLintedFile("lib"));
    try testing.expect(!cfg.mayContainLintedFile("dist"));
    try testing.expect(!cfg.mayContainLintedFile(".rpiv"));
    try testing.expect(!cfg.mayContainLintedFile("node_modules"));
}

test "mayContainLintedFile stays open on the path down to a nested root" {
    var surfaces = [_]Surface{
        .{ .name = "web-store", .path = "apps/web/store", .depth = 1, .dagOrder = 0, .suffixes = &.{".ts"} },
    };
    const cfg = Config{
        .surfaces = &surfaces,
        .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true },
    };

    // the walk starts at the project root, so every ancestor of the container
    // has to answer true or the root is never reached
    try testing.expect(cfg.mayContainLintedFile("apps"));
    try testing.expect(cfg.mayContainLintedFile("apps/web"));
    try testing.expect(!cfg.mayContainLintedFile("apps/server"));
    try testing.expect(!cfg.mayContainLintedFile("dist"));
}

test "validate rejects an empty source root" {
    var roots = [_][]const u8{""};
    var surfaces = testProjectSurfaces();
    const cfg = Config{ .sourceRoots = &roots, .surfaces = &surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };

    try testing.expectError(ValidationError.EmptySourceRoot, validate(&cfg));
}

test "validate accepts a declared source root" {
    var roots = [_][]const u8{"src"};
    var surfaces = testProjectSurfaces();
    const cfg = Config{ .sourceRoots = &roots, .surfaces = &surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };

    try validate(&cfg);
}

test "formatter writes a declared source root and omits a derived one" {
    var roots = [_][]const u8{ "src", "scripts" };
    var surfaces = testProjectSurfaces();
    const declared = Config{ .sourceRoots = &roots, .surfaces = &surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };

    var buf: [1024]u8 = undefined;
    const json = try std.fmt.bufPrint(&buf, "{f}", .{Formatter{ .value = &declared }});
    try testing.expect(std.mem.startsWith(u8, json, "{\n  \"sourceRoots\": [\"src\", \"scripts\"],\n  \"surfaces\": ["));

    // derived configs round-trip without the field, so add/upgrade on an older
    // project does not invent a declaration it never had
    var derived_surfaces = testProjectSurfaces();
    const derived = Config{ .surfaces = &derived_surfaces, .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true } };
    const derived_json = try std.fmt.bufPrint(&buf, "{f}", .{Formatter{ .value = &derived }});
    try testing.expect(std.mem.startsWith(u8, derived_json, "{\n  \"surfaces\": ["));
}
