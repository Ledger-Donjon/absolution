const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const aro_dep = b.dependency("aro", .{
        .target = target,
        .optimize = optimize,
    });
    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("fuzzmate", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "aro", .module = aro_dep.module("aro") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "fuzzmate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fuzzmate", .module = mod },
                .{ .name = "clap", .module = clap_dep.module("clap") },
            },
        }),
    });

    b.installArtifact(exe);
    install_zig_cc_sysroot_headers(b);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

pub fn install_zig_cc_sysroot_headers(b: *std.Build) void {
    // Bundle the same header sysroot that `zig cc` uses so fuzzmate's parsing
    // follows Zig's include resolution order and remains self-hosted.
    //
    // `zig cc -E -v` (Linux/glibc example) shows:
    //   <zig-lib>/include
    //   <zig-lib>/libc/include/x86-linux-gnu
    //   <zig-lib>/libc/include/generic-glibc
    //   <zig-lib>/libc/include/x86-linux-any
    //   <zig-lib>/libc/include/any-linux-any
    //   /usr/local/include
    //   /usr/include
    //
    // We preserve this layout under `zig-out/lib/...` so the runtime can add
    // these directories in the same order without depending on the host.

    const zig_include_dir = b.graph.zig_lib_directory.join(b.allocator, &.{"include"}) catch unreachable;
    b.installDirectory(.{
        .source_dir = .{ .cwd_relative = zig_include_dir },
        .install_dir = .prefix,
        .install_subdir = "lib/include",
    });

    const zig_libc_include_dir = b.graph.zig_lib_directory.join(b.allocator, &.{"libc/include"}) catch unreachable;
    b.installDirectory(.{
        .source_dir = .{ .cwd_relative = zig_libc_include_dir },
        .install_dir = .prefix,
        .install_subdir = "lib/libc/include",
    });
}
