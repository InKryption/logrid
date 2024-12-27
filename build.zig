const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const run_step_enabled = !(b.option(bool, "install", "Only install artifacts usually executed by the specified steps.") orelse false);

    const install_step = b.getInstallStep();
    const unit_test_step = b.step("unit-test", "Run unit tests.");

    {
        const test_step = b.step("test", "Run all tests.");
        test_step.dependOn(unit_test_step);
    }

    const logrid_mod = b.addModule("logrid", .{
        .root_source_file = b.path("src/logrid.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_test_exe = b.addTest(.{
        .name = "unit-test",
        .root_module = logrid_mod,
    });

    const unit_test_install = b.addInstallArtifact(unit_test_exe, .{});
    install_step.dependOn(&unit_test_install.step);
    unit_test_step.dependOn(&unit_test_install.step);

    const unit_test_run = b.addRunArtifact(unit_test_exe);
    if (run_step_enabled) unit_test_step.dependOn(&unit_test_run.step);
}
