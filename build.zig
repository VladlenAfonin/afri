const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Tests.
    const test_compile = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_run = b.addRunArtifact(test_compile);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_run.step);

    // Benchmarks.
    const zbench = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    }).module("zbench");

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench.root_module.addImport("zbench", zbench);

    const run = b.addRunArtifact(bench);
    if (b.args) |args| {
        run.addArgs(args);
    }

    const run_step = b.step("bench", "Run the benchmarks");
    run_step.dependOn(&run.step);

    const fri_bench = b.addExecutable(.{
        .name = "fri_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fri/bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fri_bench.root_module.addImport("zbench", zbench);

    const fri_run = b.addRunArtifact(fri_bench);
    if (b.args) |args| {
        fri_run.addArgs(args);
    }

    const fri_run_step = b.step("bench-fri", "Run the FRI benchmarks");
    fri_run_step.dependOn(&fri_run.step);
}
