const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const aro_dep = b.dependency("aro", .{
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
            },
        }),
    });

    b.installArtifact(exe);
    // Make aro's includes available on install.
    b.installDirectory(.{
        .source_dir = aro_dep.path("include"),
        .install_dir = .prefix,
        .install_subdir = "include",
    });

    include_builtin_libc(b, target);

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

pub fn include_builtin_libc(b: *std.Build, target: std.Build.ResolvedTarget) void {
    // Install only the libc headers matching the target ABI (musl vs glibc).
    const is_musl = switch (target.result.abi) {
        .musl, .musleabi, .musleabihf, .muslx32 => true,
        else => false,
    };

    const fmt_target = b.fmt("{s}-{s}-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
        @tagName(target.result.abi),
    });

    const use_x86_glibc_fallback = !is_musl and target.result.cpu.arch == .x86_64 and target.result.os.tag == .linux and switch (target.result.abi) {
        .gnu, .gnux32 => true,
        else => false,
    };
    const target_subdir = if (use_x86_glibc_fallback) "x86-linux-gnu" else fmt_target;

    const libc_include_dir = if (is_musl)
        b.graph.zig_lib_directory.join(b.allocator, &.{"libc/musl/include"}) catch unreachable
    else
        b.graph.zig_lib_directory.join(b.allocator, &.{"libc/glibc/include"}) catch unreachable;
    const generic_glibc_dir = if (is_musl) null else b.graph.zig_lib_directory.join(b.allocator, &.{"libc/include/generic-glibc"}) catch unreachable;
    const target_include_dir = b.graph.zig_lib_directory.join(b.allocator, &.{ "libc/include", target_subdir }) catch unreachable;

    // Install the libc-specific includes plus the target-specific overlay.
    b.installDirectory(.{
        .source_dir = .{ .cwd_relative = libc_include_dir },
        .install_dir = .prefix,
        .install_subdir = "include",
    });
    if (generic_glibc_dir) |dir| {
        b.installDirectory(.{
            .source_dir = .{ .cwd_relative = dir },
            .install_dir = .prefix,
            .install_subdir = "include",
        });
    }
    b.installDirectory(.{
        .source_dir = .{ .cwd_relative = target_include_dir },
        .install_dir = .prefix,
        .install_subdir = "include",
    });
}
