const std = @import("std");

const HashFunction = enum {
    sha2,
    sha3,
    streebog,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const hash = b.option(
        HashFunction,
        "hash",
        "Select the 256-bit hash function (sha2, sha3, or streebog)",
    ) orelse .sha2;

    const build_options = b.addOptions();
    build_options.addOption(HashFunction, "hash", hash);

    const common = b.createModule(.{
        .root_source_file = b.path("src/common.zig"),
        .target = target,
        .optimize = optimize,
    });
    common.addOptions("build_options", build_options);

    // Tests.
    const test_compile = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_compile.root_module.addImport("common", common);

    const test_run = b.addRunArtifact(test_compile);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_run.step);

    // Benchmarks.
    const zbench = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    }).module("zbench");

    const afri_bench = b.addExecutable(.{
        .name = "afri_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/afri/bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    afri_bench.root_module.addImport("zbench", zbench);
    afri_bench.root_module.addImport("common", common);

    const afri_run = b.addRunArtifact(afri_bench);
    if (b.args) |args| {
        afri_run.addArgs(args);
    }

    const afri_run_step = b.step("bench-afri", "Run the benchmarks");
    afri_run_step.dependOn(&afri_run.step);

    const fri_bench = b.addExecutable(.{
        .name = "fri_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fri/bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fri_bench.root_module.addImport("zbench", zbench);
    fri_bench.root_module.addImport("common", common);

    const fri_run = b.addRunArtifact(fri_bench);
    if (b.args) |args| {
        fri_run.addArgs(args);
    }

    const fri_run_step = b.step("bench-fri", "Run the FRI benchmarks");
    fri_run_step.dependOn(&fri_run.step);

    const stark_bench = b.addExecutable(.{
        .name = "stark_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fri/stark_bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    stark_bench.root_module.addImport("zbench", zbench);
    stark_bench.root_module.addImport("common", common);

    const stark_run = b.addRunArtifact(stark_bench);
    if (b.args) |args| {
        stark_run.addArgs(args);
    }

    const stark_run_step = b.step("bench-stark", "Run the STARK benchmarks");
    stark_run_step.dependOn(&stark_run.step);

    const astark_bench = b.addExecutable(.{
        .name = "astark_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/afri/astark_bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    astark_bench.root_module.addImport("zbench", zbench);
    astark_bench.root_module.addImport("common", common);

    const astark_run = b.addRunArtifact(astark_bench);
    if (b.args) |args| {
        astark_run.addArgs(args);
    }

    const astark_run_step = b.step("bench-astark", "Run the ASTARK benchmarks");
    astark_run_step.dependOn(&astark_run.step);
}
