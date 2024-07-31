const std = @import("std");

const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const unit_tests = b.addTest(.{
        .name = "Unit Tests",
        .root_source_file = .{ .src_path = .{ .sub_path = "src/fontana.zig", .owner = b } },
        .target = target,
        .optimize = optimize,
    });

    const run_test_cmd = b.addRunArtifact(unit_tests);
    run_test_cmd.step.dependOn(b.getInstallStep());

    _ = b.addModule("fontana", .{
        .root_source_file = .{ .src_path = .{ .sub_path = "src/fontana.zig", .owner = b } },
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_test_cmd.step);
}
