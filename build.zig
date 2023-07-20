const std = @import("std");

const Builder = std.build.Builder;
const Pkg = std.build.Pkg;

pub const pkg = Pkg{
    .name = "fontana",
    .source = .{ .path = "src/fontana.zig" },
    .dependencies = &{},
};

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const unit_tests = b.addTest(.{
        .name = "Unit Tests",
        .root_source_file = .{ .path = "src/fontana.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_test_cmd = b.addRunArtifact(unit_tests);
    run_test_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_test_cmd.step);
}
