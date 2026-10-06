const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core library: canonical format, segments, journal, verify, LLM view.
    const core = b.addModule("zephyr_core", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zephyr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zephyr_core", .module = core },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // Tests: core unit tests (one artifact per file, since the test runner
    // only discovers test blocks in the root file), plus the Phase 0 vector suite.

    const options = b.addOptions();
    options.addOptionPath("vectors", b.path("spec/vectors/journals.json"));
    const vector_module = b.createModule(.{
        .root_source_file = b.path("test/vectors.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
            .{ .name = "std_options", .module = options.createModule() },
        },
    });
    const vector_tests = b.addTest(.{ .root_module = vector_module });
    const run_vector_tests = b.addRunArtifact(vector_tests);

    const test_step = b.step("test", "Run tests");
    const core_test_files = [_][]const u8{
        "src/core/records.zig",
        "src/core/segment.zig",
        "src/core/journal.zig",
        "src/core/view.zig",
        "src/core/nfc.zig",
        "src/core/timezone.zig",
        "src/core/mark_ranges.zig",
    };
    for (core_test_files) |path| {
        const module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
        });
        const core_tests = b.addTest(.{ .root_module = module });
        const run_core_tests = b.addRunArtifact(core_tests);
        test_step.dependOn(&run_core_tests.step);
    }
    test_step.dependOn(&run_vector_tests.step);

    const fmt_step = b.step("fmt", "Run format checks");
    fmt_step.dependOn(&b.addFmt(.{ .paths = b.pathList(&.{ "src", "test", "build.zig" }) }).step);
}
