const std = @import("std");
const config = @import("../config.zig");
const presets = @import("../presets.zig");
const templates = @import("../templates.zig");
const gritql = @import("../gritql.zig");

/// embedded schema, shipped in binary, written to every scaffolded project
const embedded_schema: []const u8 = @embedFile("../architecture.schema.json");

/// embedded outcome pattern file, written to lib/ when surface is selected
const embedded_outcome: []const u8 = @embedFile("../templates/outcome.ts");

/// embedded biome config template
const biome_config_template: []const u8 =
    \\{
    \\  "$schema": "https://biomejs.dev/schemas/2.5.3/schema.json",
    \\  "formatter": {
    \\    "enabled": true,
    \\    "indentStyle": "space",
    \\    "indentWidth": 2
    \\  },
    \\  "plugins": [
    \\    ".grimuah-rules/cosmetic.grit",
    \\    ".grimuah-rules/structural.grit",
    \\    ".grimuah-rules/resilience.grit",
    \\    ".grimuah-rules/behavioural.grit"
    \\  ],
    \\  "linter": {
    \\    "enabled": true
    \\  }
    \\}
    \\
;

const tsconfig_template: []const u8 =
    \\{
    \\  "compilerOptions": {
    \\    "target": "esnext",
    \\    "module": "ES2022",
    \\    "moduleResolution": "bundler",
    \\    "lib": ["ES2022"],
    \\    "noEmit": true,
    \\    "esModuleInterop": true,
    \\    "skipLibCheck": true,
    \\    "forceConsistentCasingInFileNames": true,
    \\    "resolveJsonModule": true,
    \\    "isolatedModules": true,
    \\    "allowImportingTsExtensions": true,
    \\    "noImplicitOverride": true,
    \\    "noPropertyAccessFromIndexSignature": true,
    \\    "noImplicitReturns": true,
    \\    "noFallthroughCasesInSwitch": true,
    \\    "outDir": "./dist",
    \\    "rootDir": "./src"
    \\  },
    \\  "include": ["src/**/*.ts"],
    \\  "exclude": ["node_modules", "dist"]
    \\}
    \\
;

/// interactive refinement answers: user choices beyond the preset
const InteractiveAnswers = struct {
    lib: bool = false,
    db: bool = false,
    pages: bool = false,
    commands: bool = false,
    middleware: bool = false,
    tasks: bool = false,
};

/// which optional surfaces are already in the preset
const SurfacePresence = struct {
    has_lib: bool,
    has_db: bool,
    has_pages: bool,
    has_commands: bool,
    has_middleware: bool,
    has_tasks: bool,
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

    // interactive refinement: only ask about surfaces not already in preset
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
        .has_tasks = false,
    };
    for (cfg.surfaces) |surface| {
        if (std.mem.eql(u8, surface.name, "lib")) presence.has_lib = true;
        if (std.mem.eql(u8, surface.name, "db")) presence.has_db = true;
        if (std.mem.eql(u8, surface.name, "pages")) presence.has_pages = true;
        if (std.mem.eql(u8, surface.name, "commands")) presence.has_commands = true;
        if (std.mem.eql(u8, surface.name, "middleware")) presence.has_middleware = true;
        if (std.mem.eql(u8, surface.name, "tasks")) presence.has_tasks = true;
    }
    return presence;
}

/// ask interactive questions for surfaces not already in the preset
fn askInteractive(presence: SurfacePresence) !InteractiveAnswers {
    var answers = InteractiveAnswers{};
    var question_count: u32 = 0;
    const max_questions: u32 = 6;

    const questions = [_]struct { key: []const u8, present: bool, target: *bool }{
        .{ .key = "lib", .present = presence.has_lib, .target = &answers.lib },
        .{ .key = "db", .present = presence.has_db, .target = &answers.db },
        .{ .key = "pages", .present = presence.has_pages, .target = &answers.pages },
        .{ .key = "commands", .present = presence.has_commands, .target = &answers.commands },
        .{ .key = "middleware", .present = presence.has_middleware, .target = &answers.middleware },
        .{ .key = "tasks", .present = presence.has_tasks, .target = &answers.tasks },
    };

    for (questions) |q| {
        if (q.present) continue;
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
        .{ .label = "lib", .description = "root-level framework utilities (OperationOutcome, registry), importable by all" },
        .{ .label = "db", .description = "database layer with db/repositories/ and db/migrations/" },
        .{ .label = "pages", .description = "web UI surface, deepest dagOrder, imports from components/services" },
        .{ .label = "commands", .description = "CLI/bot interaction surface, deepest dagOrder, imports from all shallower" },
        .{ .label = "middleware", .description = "request pipeline surface, sits between services and components" },
        .{ .label = "tasks", .description = "background job processing surface, imports from lib/db/middleware/services" },
    };

    const desc = for (prompts) |p| {
        if (std.mem.eql(u8, p.label, label)) break p.description;
    } else "add this surface to the project";

    std.debug.print("add {s}/? {s} [y/N]: ", .{ label, desc });

    // read one byte at a time until newline
    // handles both terminal (line-buffered) and piped input (heredoc delivers one byte per read on a pipe)
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
/// surfaces under src/ get depth=1, lib gets depth=0
/// dagOrder is set sequentially based on insertion position
fn applyPatches(allocator: std.mem.Allocator, cfg: *config.Config, answers: InteractiveAnswers, presence: SurfacePresence) !void {
    // count how many new surfaces to add
    var new_count: usize = 0;
    if (answers.lib and !presence.has_lib) new_count += 1;
    if (answers.db and !presence.has_db) new_count += 1;
    if (answers.pages and !presence.has_pages) new_count += 1;
    if (answers.commands and !presence.has_commands) new_count += 1;
    if (answers.middleware and !presence.has_middleware) new_count += 1;
    if (answers.tasks and !presence.has_tasks) new_count += 1;

    if (new_count == 0) return;

    const total = cfg.surfaces.len + new_count;
    const new_surfaces = try allocator.alloc(config.Surface, total);

    // copy existing surfaces
    for (cfg.surfaces, 0..) |surface, i| {
        new_surfaces[i] = surface;
    }

    var insert_idx: usize = cfg.surfaces.len;

    // compute the base dagOrder: highest existing dagOrder + 1
    var next_dag_order: u32 = 0;
    for (cfg.surfaces) |surface| {
        if (surface.dagOrder >= next_dag_order) next_dag_order = surface.dagOrder + 1;
    }

    // add lib at depth 0 (root-level), dagOrder = next
    if (answers.lib and !presence.has_lib) {
        new_surfaces[insert_idx] = createSurface(allocator, "lib", "lib", 0, next_dag_order, &.{".ts"}, &.{ ".types.ts", ".config.ts", ".spec.ts" }, &.{});
        insert_idx += 1;
        next_dag_order += 1;
    }

    // add db under src/, depth 1
    if (answers.db and !presence.has_db) {
        new_surfaces[insert_idx] = createSurface(allocator, "db", "src/db", 1, next_dag_order, &.{ ".repo.ts", ".config.ts" }, &.{ ".types.ts", ".config.ts", ".spec.ts", "schema.ts" }, &.{"lib"});
        insert_idx += 1;
        next_dag_order += 1;
    }

    // add middleware under src/, depth 1
    if (answers.middleware and !presence.has_middleware) {
        const mid_allowed: []const []const u8 = if (answers.lib and !presence.has_lib) (if (answers.db and !presence.has_db) &.{ "lib", "db", "services" } else &.{"lib"}) else &.{"services"};
        new_surfaces[insert_idx] = createSurface(allocator, "middleware", "src/middleware", 1, next_dag_order, &.{ ".middleware.ts", ".config.ts" }, &.{ ".types.ts", ".config.ts", ".spec.ts", ".regex-patterns.ts" }, mid_allowed);
        insert_idx += 1;
        next_dag_order += 1;
    }

    // add pages under src/, depth 1
    if (answers.pages and !presence.has_pages) {
        new_surfaces[insert_idx] = createSurface(allocator, "pages", "src/pages", 1, next_dag_order, &.{ ".page.ts", ".config.ts" }, &.{ ".types.ts", ".config.ts", ".spec.ts" }, &.{ "lib", "utils", "services", "components" });
        insert_idx += 1;
        next_dag_order += 1;
    }

    // add commands under src/, depth 1
    if (answers.commands and !presence.has_commands) {
        const cmd_allowed: []const []const u8 = if (answers.db and !presence.has_db) &.{ "lib", "utils", "db", "services" } else &.{ "lib", "utils", "services" };
        new_surfaces[insert_idx] = createSurface(allocator, "commands", "src/commands", 1, next_dag_order, &.{ ".command.ts", ".config.ts" }, &.{ ".types.ts", ".config.ts", ".spec.ts", ".regex-patterns.ts" }, cmd_allowed);
        insert_idx += 1;
        next_dag_order += 1;
    }

    // add tasks under src/, depth 1
    if (answers.tasks and !presence.has_tasks) {
        const tasks_allowed: []const []const u8 = if (answers.middleware and !presence.has_middleware) &.{ "lib", "db", "middleware", "services" } else &.{ "lib", "db", "services" };
        new_surfaces[insert_idx] = createSurface(allocator, "tasks", "src/tasks", 1, next_dag_order, &.{ ".task.ts", ".config.ts" }, &.{ ".types.ts", ".config.ts", ".spec.ts" }, tasks_allowed);
        insert_idx += 1;
        next_dag_order += 1;
    }

    // swap the surfaces array
    cfg.surfaces = new_surfaces;

    // enable root lib if lib was added
    if (answers.lib and !presence.has_lib) {
        cfg.rootLib.enabled = true;
    }
}

/// create a heap-allocated Surface with all fields
fn createSurface(allocator: std.mem.Allocator, name: []const u8, path: []const u8, depth: u32, dagOrder: u32, suffixes: []const []const u8, innateMembers: []const []const u8, allowedImports: []const []const u8) config.Surface {
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
        .dagOrder = dagOrder,
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
    const config_json_str = try std.fmt.bufPrint(&json_buf, "{f}", .{config.Formatter{ .value = cfg }});
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

    // write .gitignore
    try writeGitignore(io, name);

    // scaffold .husky/
    try scaffoldHusky(io, name);

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

        // write outcome.ts pattern
        var outcome_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const outcome_path = try std.fmt.bufPrint(&outcome_path_buf, "{s}/outcome.ts", .{lib_dir});
        try templates.writeFile(io, outcome_path, embedded_outcome);
    }

    // create .grimuah-rules/ directory
    var rules_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rules_dir = try std.fmt.bufPrint(&rules_dir_buf, "{s}/.grimuah-rules", .{name});
    try std.Io.Dir.cwd().createDirPath(io, rules_dir);
}

fn writeGitignore(io: std.Io, name: []const u8) !void {
    const content =
        \\node_modules/
        \\dist/
        \\*.log
        \\.env
        \\.env.*
        \\.dev.vars
        \\!.env.example
        \\.pi
        \\.rpiv
    ;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/.gitignore", .{name});
    try templates.writeFile(io, path, content);
}

fn scaffoldHusky(io: std.Io, name: []const u8) !void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    // create .husky/ directory
    const husky_dir = try std.fmt.bufPrint(&buf, "{s}/.husky", .{name});
    try std.Io.Dir.cwd().createDirPath(io, husky_dir);

    // write pre-commit
    const precommit_path = try std.fmt.bufPrint(&buf, "{s}/.husky/pre-commit", .{name});
    try templates.writeFile(io, precommit_path,
        \\pnpm typecheck
        \\pnpm lint
        \\bash .husky/check-em-dash.sh
        \\bash .husky/format-on-commit.sh
    );

    // write check-em-dash.sh
    const check_emdash_path = try std.fmt.bufPrint(&buf, "{s}/.husky/check-em-dash.sh", .{name});
    try templates.writeExecutableFile(io, check_emdash_path,
        \\#!/usr/bin/env bash
        \\# ban em-dash in source files
        \\STATUS=0
        \\if grep -rn $'\xe2\x80\x94' src/ --include="*.ts"; then
        \\  echo ""
        \\  echo "em-dash found in source files, banned in this project"
        \\  echo "replace with a comma, colon, or sentence break instead"
        \\  STATUS=1
        \\fi
        \\exit $STATUS
    );

    // write format-on-commit.sh
    const format_commit_path = try std.fmt.bufPrint(&buf, "{s}/.husky/format-on-commit.sh", .{name});
    try templates.writeExecutableFile(io, format_commit_path,
        \\#!/usr/bin/env bash
        \\STAGED_FILES=$(git diff --cached --name-only)
        \\pnpm format
        \\UNSTAGED_FILES=$(git diff --name-only)
        \\FILES_TO_RESTAGE=$(comm -12 <(echo "$STAGED_FILES" | sort) <(echo "$UNSTAGED_FILES" | sort))
        \\if [ -n "$FILES_TO_RESTAGE" ]; then
        \\  echo "$FILES_TO_RESTAGE" | xargs git add
        \\  echo "Re-staged formatted files:"
        \\  echo "$FILES_TO_RESTAGE"
        \\else
        \\  echo "All staged files were already properly formatted."
        \\fi
    );
}

fn writePackageJson(io: std.Io, allocator: std.mem.Allocator, name: []const u8) !void {
    const pkg = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "name": "{s}",
        \\  "version": "0.0.0",
        \\  "private": true,
        \\  "scripts": {{
        \\    "check": "biome check",
        \\    "lint": "biome lint",
        \\    "format": "biome format --write",
        \\    "typecheck": "tsc --noEmit",
        \\    "release": "commit-and-tag-version",
        \\    "release:minor": "commit-and-tag-version --release-as minor",
        \\    "release:patch": "commit-and-tag-version --release-as patch",
        \\    "release:dry": "commit-and-tag-version --dry-run",
        \\    "prepare": "husky"
        \\  }},
        \\  "devDependencies": {{
        \\    "husky": "^9.1.7",
        \\    "typescript": "^6.0.3",
        \\    "commit-and-tag-version": "^12.7.3"
        \\  }}
        \\}}
        \\
    , .{name});
    defer allocator.free(pkg);

    var pkg_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_path = try std.fmt.bufPrint(&pkg_path_buf, "{s}/package.json", .{name});
    try templates.writeFile(io, pkg_path, pkg);
}
