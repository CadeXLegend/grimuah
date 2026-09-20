const std = @import("std");

/// the agent skills the binary carries, as files the root `skills/` tree owns
///
/// they are embedded rather than copied into `src/`, so the markdown an agent
/// receives is the same file a reader of the repository reads, and the shipped
/// binary hands over the version it was built from
const embedded_skills = [_]struct { import_name: []const u8, path: []const u8 }{
    .{ .import_name = "skill-grimuah-setup", .path = "skills/grimuah-setup/SKILL.md" },
    .{ .import_name = "skill-grimuah-architecture", .path = "skills/grimuah-architecture/SKILL.md" },
    .{ .import_name = "skill-grimuah-compliance", .path = "skills/grimuah-compliance/SKILL.md" },
    .{ .import_name = "skill-grimuah-fix-findings", .path = "skills/grimuah-fix-findings/SKILL.md" },
    .{ .import_name = "skill-grimuah-migrate-existing", .path = "skills/grimuah-migrate-existing/SKILL.md" },
};

/// make every skill reachable as `@embedFile("<import_name>")` from `module`
///
/// they sit outside the module's package path, so the build has to name them
/// one by one. every module that reads them needs this, the test build included
fn addEmbeddedSkills(b: *std.Build, module: *std.Build.Module) void {
    for (embedded_skills) |skill| {
        module.addAnonymousImport(skill.import_name, .{ .root_source_file = b.path(skill.path) });
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // the release artifact is stripped unless asked otherwise
    //
    // debug info is ~85% of an unstripped binary, and `strip_debug_info` also
    // gates the stack-tracing machinery (`std.zig`'s `allow_stack_tracing`
    // defaults to its negation), which is another ~28% of the binary and can
    // only print resolved frames while the symbols it reads are still there.
    // a stripped release carries neither, so a shipped binary is small and a
    // panic prints a plain "stack tracing is disabled" instead of a wall of
    // `???` addresses
    //
    // a local build keeps both: debug is the default optimize mode, and
    // `-Dstrip=false` keeps them on any release build
    const strip = b.option(bool, "strip", "omit debug symbols and stack tracing from the binary") orelse (optimize != .Debug);

    const exe = b.addExecutable(.{
        .name = "grimuah",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });

    addEmbeddedSkills(b, exe.root_module);

    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // a failing test is read through its stack trace, so a test build
            // keeps its symbols whatever the release default is
            .strip = false,
        }),
    });

    const run_tests = b.addRunArtifact(tests);

    addEmbeddedSkills(b, tests.root_module);

    const test_step = b.step("test", "run unit tests");
    test_step.dependOn(&run_tests.step);
}
