//! Include path discovery for zig cc compatibility.
//!
//! Configures aro's compilation include search paths to match `zig cc` behavior.
//! The bundled sysroot lives under `resource_dir/lib/...`.

const aro = @import("aro");
const std = @import("std");

/// Configure the compilation's include search paths using the bundled sysroot.
/// The bundled sysroot lives under `resource_dir/lib/...`. We add directories
/// in the same order that `zig cc -E -v` reports, except we intentionally omit
/// /usr/local/include and /usr/include to keep fuzzmate self-contained:
///   1. <prefix>/lib/include (Zig's compiler-rt / intrinsic headers)
///   2. <prefix>/lib/libc/include/<target-triple> (target-specific libc headers)
///   3. <prefix>/lib/libc/include/generic-<abi-family> (generic libc headers)
///   4. <prefix>/lib/libc/include/<arch>-<os>-any (arch+os wildcards)
///   5. <prefix>/lib/libc/include/any-<os>-any (os-only wildcards)
pub fn addZigCcImplicitIncludes(comp: *aro.Compilation, resource_dir: []const u8) !void {
    const target = comp.target;
    const arch = target.cpu.arch;
    const os = target.os.tag;
    const abi = target.abi;

    // 1. Zig's compiler-provided headers (stddef.h, stdarg.h, etc.)
    const zig_lib_include = try std.fs.path.join(comp.arena, &.{ resource_dir, "lib", "include" });
    try comp.addSystemIncludeDir(zig_lib_include);

    const libc_include_base = try std.fs.path.join(comp.arena, &.{ resource_dir, "lib", "libc", "include" });

    // 2. Target-specific libc headers (e.g., x86_64-linux-gnu or x86-linux-gnu)
    //    Zig uses some naming quirks: x86_64 glibc targets use "x86-linux-gnu".
    const target_subdir = try getTargetLibcSubdir(comp.arena, arch, os, abi);
    if (target_subdir) |subdir| {
        const target_include = try std.fs.path.join(comp.arena, &.{ libc_include_base, subdir });
        try comp.addSystemIncludeDir(target_include);
    }

    // 3. Generic libc headers based on ABI family (glibc, musl, etc.)
    const generic_subdir = getGenericLibcSubdir(abi);
    if (generic_subdir) |subdir| {
        const generic_include = try std.fs.path.join(comp.arena, &.{ libc_include_base, subdir });
        try comp.addSystemIncludeDir(generic_include);
    }

    // 4. Architecture + OS wildcard headers (e.g., x86-linux-any)
    const arch_os_any = try getArchOsAnySubdir(comp.arena, arch, os);
    if (arch_os_any) |subdir| {
        const arch_os_include = try std.fs.path.join(comp.arena, &.{ libc_include_base, subdir });
        try comp.addSystemIncludeDir(arch_os_include);
    }

    // 5. OS-only wildcard headers (e.g., any-linux-any)
    const any_os_any = try getAnyOsAnySubdir(comp.arena, os);
    if (any_os_any) |subdir| {
        const any_os_include = try std.fs.path.join(comp.arena, &.{ libc_include_base, subdir });
        try comp.addSystemIncludeDir(any_os_include);
    }

    // Note: We intentionally do NOT add /usr/local/include or /usr/include.
    // fuzzmate is self-contained and uses only the bundled headers from the
    // build-time copied sysroot. This ensures:
    //   1. Reproducible builds regardless of host system headers
    //   2. Proper system header tracking for filtering system symbols
}

/// Determine the target-specific libc include subdirectory.
/// Zig uses specific naming conventions, e.g. x86_64-linux-gnu -> x86-linux-gnu.
fn getTargetLibcSubdir(
    arena: std.mem.Allocator,
    arch: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,
    abi: std.Target.Abi,
) !?[]const u8 {
    // Zig's libc headers use a normalized arch name in some cases
    const arch_name = switch (arch) {
        .x86_64, .x86 => "x86",
        .aarch64, .aarch64_be => "aarch64",
        .arm, .armeb => "arm",
        .riscv64 => "riscv64",
        .riscv32 => "riscv32",
        .powerpc64, .powerpc64le => "powerpc64",
        .powerpc, .powerpcle => "powerpc",
        .mips, .mipsel => "mips",
        .mips64, .mips64el => "mips64",
        .sparc, .sparc64 => "sparc",
        .s390x => "s390x",
        .wasm32, .wasm64 => return null, // No libc headers for wasm
        else => @tagName(arch),
    };

    const os_name = switch (os) {
        .linux => "linux",
        .macos, .ios, .tvos, .watchos, .visionos => "darwin",
        .freebsd => "freebsd",
        .netbsd => "netbsd",
        .openbsd => "openbsd",
        .dragonfly => "dragonfly",
        .windows => "windows",
        .freestanding => return null,
        else => @tagName(os),
    };

    const abi_name = switch (abi) {
        .gnu, .gnux32 => "gnu",
        .gnueabi, .gnueabihf => "gnueabi",
        .gnuabin32, .gnuabi64 => "gnuabi64",
        .gnuf32, .gnusf => "gnu",
        .musl, .musleabi, .musleabihf => "musl",
        .muslabin32, .muslabi64, .muslf32, .muslsf, .muslx32 => "musl",
        .android, .androideabi => "android",
        .none => if (os == .linux) "gnu" else return null,
        else => @tagName(abi),
    };

    return try std.fmt.allocPrint(arena, "{s}-{s}-{s}", .{ arch_name, os_name, abi_name });
}

/// Get the generic libc subdirectory based on ABI family.
fn getGenericLibcSubdir(abi: std.Target.Abi) ?[]const u8 {
    return switch (abi) {
        .gnu, .gnux32, .gnueabi, .gnueabihf, .gnuabin32, .gnuabi64, .gnuf32, .gnusf => "generic-glibc",
        .musl, .musleabi, .musleabihf, .muslabin32, .muslabi64, .muslf32, .muslsf, .muslx32 => "generic-musl",
        .none => "generic-glibc", // Default to glibc for unspecified ABI on Linux
        else => null,
    };
}

/// Get the arch-os-any wildcard subdirectory.
fn getArchOsAnySubdir(arena: std.mem.Allocator, arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag) !?[]const u8 {
    const arch_name = switch (arch) {
        .x86_64, .x86 => "x86",
        .aarch64, .aarch64_be => "aarch64",
        .arm, .armeb => "arm",
        .riscv64 => "riscv64",
        .riscv32 => "riscv32",
        .powerpc64, .powerpc64le => "powerpc64",
        .powerpc, .powerpcle => "powerpc",
        .mips, .mipsel => "mips",
        .mips64, .mips64el => "mips64",
        .wasm32, .wasm64 => return null,
        else => @tagName(arch),
    };

    const os_name = switch (os) {
        .linux => "linux",
        .macos, .ios, .tvos, .watchos, .visionos => "darwin",
        .freebsd, .netbsd, .openbsd, .dragonfly => @tagName(os),
        .windows => "windows",
        .freestanding => return null,
        else => @tagName(os),
    };

    return try std.fmt.allocPrint(arena, "{s}-{s}-any", .{ arch_name, os_name });
}

/// Get the any-os-any wildcard subdirectory.
fn getAnyOsAnySubdir(arena: std.mem.Allocator, os: std.Target.Os.Tag) !?[]const u8 {
    const os_name = switch (os) {
        .linux => "linux",
        .macos, .ios, .tvos, .watchos, .visionos => "darwin",
        .freebsd, .netbsd, .openbsd, .dragonfly => @tagName(os),
        .windows => "windows",
        .freestanding => return null,
        else => @tagName(os),
    };

    return try std.fmt.allocPrint(arena, "any-{s}-any", .{os_name});
}
