const std = @import("std");

const Builder = std.build.Builder;
const Pkg = std.build.Pkg;

pub const pkg = Pkg{
    .name = "fontana",
    .source = .{ .path = "src/fontana.zig" },
    .dependencies = &{},
};

pub fn build(b: *Builder) void {
    const buildMode = b.standardReleaseOptions();

    const fontana_build_test = b.addTestExe("fontana-tests", "fontana.zig");
    fontana_build_test.linkLibC();
    fontana_build_test.setBuildMode(buildMode);
    fontana_build_test.install();

    const run_test_cmd = fontana_build_test.run();
    run_test_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_test_cmd.step);

    const build_only_test_step = b.step("test_build_only", "Build the tests but does not run it");
    build_only_test_step.dependOn(&fontana_build_test.step);
    build_only_test_step.dependOn(b.getInstallStep());
}
