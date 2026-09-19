const std = @import("std");

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

    const test_step = b.step("test", "run unit tests");
    test_step.dependOn(&run_tests.step);
}
