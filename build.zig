// subproject/gbm/build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const drm_dep = b.dependency("drm", .{ .target = target, .optimize = optimize });
    const nvidia_dep = b.dependency("nvidia", .{ .target = target, .optimize = optimize });

    const root_module = b.addModule("gbm", .{
        .root_source_file = b.path("src/gbm.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("drm", drm_dep.module("drm"));
    root_module.addImport("nvidia", nvidia_dep.module("nvidia"));

    const tests = b.addTest(.{
        .root_module = root_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
