const std = @import("std");
const config = @import("../config.zig");
const presets = @import("../presets.zig");
const templates = @import("../templates.zig");
const gritql = @import("../gritql.zig");

/// embedded schema — shipped in binary, written to every scaffolded project
const embedded_schema: []const u8 = @embedFile("../architecture.schema.json");

/// embedded biome config template
const biome_config_template: []const u8 =
    \\{
    \\  "$schema": "https://biomejs.dev/schemas/2.5.3/schema.json",
    \\  "formatter": {
    \\    "enabled": true,
    \\    "indentStyle": "space",
    \\    "indentWidth": 2
    \\  },
    \\  "plugins": ["arch-rules/cosmetic.grit", "arch-rules/structural.grit", "arch-rules/resilience.grit", "arch-rules/behavioural.grit"],
    \\  "linter": {
    \\    "enabled": true
    \\  }
    \\}
;

const tsconfig_template: []const u8 =
    \\{
    \\  "compilerOptions": {
    \\    "target": "ES2022",
    \\    "module": "ES2022",
    \\    "moduleResolution": "bundler",
    \\    "strict": true,
    \\    "noEmit": true,
    \\    "allowImportingTsExtensions": true,
    \\    "isolatedModules": true,
    \\    "skipLibCheck": true
    \\  }
    \\}
;

/// interactive refinement answers — user choices beyond the preset
const InteractiveAnswers = struct {
    lib: bool = false,
    db: bool = false,
    pages: bool = false,
    commands: bool = false,
    middleware: bool = false,
};

/// which optional surfaces are already in the preset
const SurfacePresence = struct {
    has_lib: bool,
    has_db: bool,
    has_pages: bool,
    has_commands: bool,
    has_middleware: bool,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, project_name: ?[]const u8, preset_name: ?[]const u8) !void {
    const name = project_name orelse "my-project";
    const preset = if (preset_name) |pn|
        presets.Preset.fromName(pn) orelse {
            std.debug.print("unknown preset: {s}\n", .{pn});
            std.debug.print("available: default, webapp, cli, backend, bot\n", .{});
            return;
        }
    else
        presets.Preset.default;

    std.debug.print("scaffolding {s} with preset {s}...\n", .{ name, @tagName(preset) });

    var parsed = try presets.loadPreset(allocator, preset);
    defer parsed.deinit();
    const cfg = &parsed.value;

    // detect which optional surfaces the preset already has
    const presence = detectPresence(cfg);

    // interactive refinement — only ask about surfaces not already in preset
    const answers = try askInteractive(presence);

    // apply interactive patches to config
    try applyPatches(allocator, cfg, answers, presence);

    // scaffold the project
    try scaffoldProject(io, allocator, name, cfg);

    // generate GritQL rule files
    try gritql.generateRules(io, allocator, name, cfg);

    std.debug.print("done. {s}/ is ready.\n", .{name});
}

/// check which optional surfaces are already in the preset
fn detectPresence(cfg: *const config.Config) SurfacePresence {
    var presence = SurfacePresence{
        .has_lib = false,
        .has_db = false,
        .has_pages = false,
        .has_commands = false,
        .has_middleware = false,
    };
    for (cfg.surfaces) |surface| {
        if (std.mem.eql(u8, surface.name, "lib")) presence.has_lib = true;
        if (std.mem.eql(u8, surface.name, "db")) presence.has_db = true;
        if (std.mem.eql(u8, surface.name, "pages")) presence.has_pages = true;
        if (std.mem.eql(u8, surface.name, "commands")) presence.has_commands = true;
        if (std.mem.eql(u8, surface.name, "middleware")) presence.has_middleware = true;
    }
    return presence;
}

/// ask interactive questions for surfaces not already in the preset
/// default preset (no surfaces present) asks all 5; named presets skip what they include
fn askInteractive(presence: SurfacePresence) !InteractiveAnswers {
    var answers = InteractiveAnswers{};
    var question_count: u32 = 0;
    const max_questions: u32 = 5;

    const questions = [_]struct { key: []const u8, present: bool, target: *bool }{
        .{ .key = "lib", .present = presence.has_lib, .target = &answers.lib },
        .{ .key = "db", .present = presence.has_db, .target = &answers.db },
        .{ .key = "pages", .present = presence.has_pages, .target = &answers.pages },
        .{ .key = "commands", .present = presence.has_commands, .target = &answers.commands },
        .{ .key = "middleware", .present = presence.has_middleware, .target = &answers.middleware },
    };

    for (questions) |q| {
        if (q.present) continue; // already in preset, skip
        if (question_count >= max_questions) break;

        const answer = try askYesNo(q.key);
        if (answer) {
            q.target.* = true;
        }
        question_count += 1;
    }

    return answers;
}

/// ask a single yes/no question on stdin
fn askYesNo(label: []const u8) !bool {
    const prompts = [_]struct { label: []const u8, description: []const u8 }{
        .{ .label = "lib", .description = "root-level framework utilities (OperationOutcome, registry) — depth 0, importable by all" },
        .{ .label = "db", .description = "database layer with db/repositories/ and db/migrations/ — depth 1" },
        .{ .label = "pages", .description = "web UI surface — deepest depth, imports from components/services" },
        .{ .label = "commands", .description = "CLI/bot interaction surface — deepest depth, imports from all shallower" },
        .{ .label = "middleware", .description = "request pipeline surface — sits between services and components" },
    };

    const desc = for (prompts) |p| {
        if (std.mem.eql(u8, p.label, label)) break p.description;
    } else "add this surface to the project";

    std.debug.print("add {s}/? {s} [y/N]: ", .{ label, desc });

    // read one byte at a time until newline — handles both terminal (line-buffered)
    // and piped input (heredoc delivers one byte per read on a pipe)
    var buf: [32]u8 = undefined;
    var pos: usize = 0;
    while (pos < buf.len) {
        const n = std.posix.read(0, buf[pos..][0..1]) catch return false;
        if (n == 0) return false;
        if (buf[pos] == '\n') break;
        pos += 1;
    }
    return pos > 0 and (buf[0] == 'y' or buf[0] == 'Y');
}

/// apply interactive answers to the config by adding selected surfaces
/// this regenerates the surfaces array with new entries inserted at correct depths
fn applyPatches(allocator: std.mem.Allocator, cfg: *config.Config, answers: InteractiveAnswers, presence: SurfacePresence) !void {
    // count how many new surfaces to add
    var new_count: usize = 0;
    if (answers.lib and !presence.has_lib) new_count += 1;
    if (answers.db and !presence.has_db) new_count += 1;
    if (answers.pages and !presence.has_pages) new_count += 1;
    if (answers.commands and !presence.has_commands) new_count += 1;
    if (answers.middleware and !presence.has_middleware) new_count += 1;

    if (new_count == 0) return;

    const total = cfg.surfaces.len + new_count;
    const new_surfaces = try allocator.alloc(config.Surface, total);

    // copy existing surfaces
    for (cfg.surfaces, 0..) |surface, i| {
        new_surfaces[i] = surface;
    }

    var insert_idx: usize = cfg.surfaces.len;

    // add lib at depth 0 if requested (shift existing surfaces down, not lib itself)
    if (answers.lib and !presence.has_lib) {
        // shift all existing surfaces +1 to make room for lib at depth 0
        for (new_surfaces[0..cfg.surfaces.len]) |*existing| {
            existing.depth += 1;
        }
        new_surfaces[insert_idx] = createSurface(allocator, "lib", "lib", 0, &.{".ts"}, &.{ ".types.ts", ".config.ts", ".spec.ts" }, &.{});
        insert_idx += 1;
    }

    // add db between lib and services — shift services/components +1 to make room
    if (answers.db and !presence.has_db) {
        const db_depth: u32 = if (answers.lib and !presence.has_lib) @as(u32, 1) else 1;
        // shift services and components +1 to make room for db
        for (new_surfaces[0..cfg.surfaces.len]) |*existing| {
            if (existing.depth >= db_depth) existing.depth += 1;
        }
        new_surfaces[insert_idx] = createSurface(allocator, "db", "src/db", db_depth, &.{ ".repo.ts", ".config.ts" }, &.{ ".types.ts", ".config.ts", ".spec.ts", "schema.ts" }, &.{"lib"});
        insert_idx += 1;
    }

    // add middleware between services and components
    if (answers.middleware and !presence.has_middleware) {
        const md_depth: u32 = 4;
        for (new_surfaces[0..insert_idx]) |*existing| {
            if (existing.depth >= md_depth) existing.depth += 1;
        }
        new_surfaces[insert_idx] = createSurface(allocator, "middleware", "src/middleware", md_depth, &.{ ".middleware.ts", ".config.ts" }, &.{ ".types.ts", ".config.ts", ".spec.ts", ".regex-patterns.ts" }, &.{ "lib", "db", "services" });
        insert_idx += 1;
    }

    // add pages at deep depth
    if (answers.pages and !presence.has_pages) {
        const pages_depth: u32 = @intCast(total - 2);
        new_surfaces[insert_idx] = createSurface(allocator, "pages", "src/pages", pages_depth, &.{ ".page.ts", ".config.ts" }, &.{ ".types.ts", ".config.ts", ".spec.ts" }, &.{ "lib", "utils", "services", "components" });
        insert_idx += 1;
    }

    // add commands at deepest depth
    if (answers.commands and !presence.has_commands) {
        const cmd_depth: u32 = @intCast(total - 1);
        new_surfaces[insert_idx] = createSurface(allocator, "commands", "src/commands", cmd_depth, &.{ ".command.ts", ".config.ts" }, &.{ ".types.ts", ".config.ts", ".spec.ts", ".regex-patterns.ts" }, &.{ "lib", "utils", "db", "services" });
        insert_idx += 1;
    }

    // swap the surfaces array (old one was allocated by parseFromSlice, freed by deinit)
    cfg.surfaces = new_surfaces;

    // enable root lib if lib was added
    if (answers.lib and !presence.has_lib) {
        cfg.rootLib.enabled = true;
    }
}

/// create a heap-allocated Surface with all fields
fn createSurface(allocator: std.mem.Allocator, name: []const u8, path: []const u8, depth: u32, suffixes: []const []const u8, innateMembers: []const []const u8, allowedImports: []const []const u8) config.Surface {
    const name_copy = allocator.dupe(u8, name) catch @panic("OOM");
    const path_copy = allocator.dupe(u8, path) catch @panic("OOM");

    const suffixes_copy = allocator.alloc([]const u8, suffixes.len) catch @panic("OOM");
    for (suffixes, 0..) |s, i| suffixes_copy[i] = allocator.dupe(u8, s) catch @panic("OOM");

    const innate_copy = allocator.alloc([]const u8, innateMembers.len) catch @panic("OOM");
    for (innateMembers, 0..) |s, i| innate_copy[i] = allocator.dupe(u8, s) catch @panic("OOM");

    const imports_copy = allocator.alloc([]const u8, allowedImports.len) catch @panic("OOM");
    for (allowedImports, 0..) |s, i| imports_copy[i] = allocator.dupe(u8, s) catch @panic("OOM");

    return .{
        .name = name_copy,
        .path = path_copy,
        .depth = depth,
        .suffixes = suffixes_copy,
        .innateMembers = innate_copy,
        .allowedImports = imports_copy,
    };
}

fn scaffoldProject(io: std.Io, allocator: std.mem.Allocator, name: []const u8, cfg: *const config.Config) !void {
    try std.Io.Dir.cwd().createDirPath(io, name);

    // write architecture.schema.json
    var schema_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const schema_path = try std.fmt.bufPrint(&schema_path_buf, "{s}/architecture.schema.json", .{name});
    try templates.writeFile(io, schema_path, embedded_schema);

    // write architecture.config.json
    var config_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&config_path_buf, "{s}/architecture.config.json", .{name});

    var json_buf: [16384]u8 = undefined;
    const config_json_str = try std.fmt.bufPrint(&json_buf, "{f}", .{std.json.fmt(cfg.*, .{ .whitespace = .indent_2 })});
    try templates.writeFile(io, config_path, config_json_str);

    // write biome.json
    var biome_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const biome_path = try std.fmt.bufPrint(&biome_path_buf, "{s}/biome.json", .{name});
    try templates.writeFile(io, biome_path, biome_config_template);

    // write tsconfig.json
    var tsconfig_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tsconfig_path = try std.fmt.bufPrint(&tsconfig_path_buf, "{s}/tsconfig.json", .{name});
    try templates.writeFile(io, tsconfig_path, tsconfig_template);

    // write package.json
    try writePackageJson(io, allocator, name);

    // create surface directories with example files
    for (cfg.surfaces) |surface| {
        var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ name, surface.path });
        try std.Io.Dir.cwd().createDirPath(io, dir_path);

        if (surface.suffixes.len > 0) {
            const example_name = try std.fmt.allocPrint(allocator, "example{s}", .{surface.suffixes[0]});
            defer allocator.free(example_name);

            var example_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const example_path = try std.fmt.bufPrint(&example_path_buf, "{s}/{s}", .{ dir_path, example_name });
            try templates.writeFile(io, example_path, "// TODO: implement\n");
        }
    }

    // create root-level lib/ if enabled
    if (cfg.rootLib.enabled) {
        var lib_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const lib_dir = try std.fmt.bufPrint(&lib_dir_buf, "{s}/{s}", .{ name, cfg.rootLib.path });
        try std.Io.Dir.cwd().createDirPath(io, lib_dir);
        const lib_example_path = try std.fmt.allocPrint(allocator, "{s}/example.ts", .{lib_dir});
        defer allocator.free(lib_example_path);
        try templates.writeFile(io, lib_example_path, "// TODO: implement\n");
    }

    // create arch-rules/ directory
    var rules_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rules_dir = try std.fmt.bufPrint(&rules_dir_buf, "{s}/arch-rules", .{name});
    try std.Io.Dir.cwd().createDirPath(io, rules_dir);
}

fn writePackageJson(io: std.Io, allocator: std.mem.Allocator, name: []const u8) !void {
    const pkg = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "name": "{s}",
        \\  "version": "0.0.0",
        \\  "private": true,
        \\  "scripts": {{
        \\    "check": "biome check",
        \\    "format": "biome format --write",
        \\    "typecheck": "tsc --noEmit"
        \\  }}
        \\}}
    , .{name});
    defer allocator.free(pkg);

    var pkg_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_path = try std.fmt.bufPrint(&pkg_path_buf, "{s}/package.json", .{name});
    try templates.writeFile(io, pkg_path, pkg);
}
