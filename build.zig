const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libxev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    const libxev_mod = libxev_dep.module("xev");

    const zython_mod = b.addModule("zython", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xev", .module = libxev_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zython",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zython", .module = zython_mod },
                .{ .name = "xev", .module = libxev_mod },
            },
        }),
    });
    exe.root_module.link_libc = true;
    // Platform-specific linking
    if (target.result.os.tag == .linux) {
        exe.root_module.linkSystemLibrary("m", .{});
        exe.root_module.linkSystemLibrary("pthread", .{});
    }
    b.installArtifact(exe);

    const run_step = b.step("run", "Run Zython interpreter");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // zpip — pip on Zig with libxev
    const zpip_exe = b.addExecutable(.{
        .name = "zpip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpip.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "xev", .module = libxev_mod },
            },
        }),
    });
    zpip_exe.root_module.link_libc = true;
    if (target.result.os.tag == .linux) {
        zpip_exe.root_module.linkSystemLibrary("m", .{});
    }
    b.installArtifact(zpip_exe);

    const zpip_run_step = b.step("zpip", "Run zpip (pip on Zig with libxev)");
    const zpip_run_cmd = b.addRunArtifact(zpip_exe);
    zpip_run_step.dependOn(&zpip_run_cmd.step);
    if (b.args) |args| {
        zpip_run_cmd.addArgs(args);
    }

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = zython_mod,
    });
    mod_tests.root_module.link_libc = true;
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.root_module.link_libc = true;
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);
}
