//! Include path discovery for zig cc compatibility.
//!
//! Configures aro's compilation include search paths to match `zig cc` behavior.
//! The bundled sysroot lives under `resource_dir/lib/...`.

const aro = @import("aro");
const std = @import("std");

/// Append the bundled-sysroot include paths to `driver.includes`.
/// The caller commits the merged list (system + user) to the compilation
/// via a single `initSearchPath` call, mirroring aro's normal driver flow.
///
/// The bundled sysroot lives under `resource_dir/lib/...`. We add directories
/// in the same order that `zig cc -E -v` reports, except we intentionally omit
/// /usr/local/include and /usr/include to keep absolution self-contained:
///   1. <prefix>/lib/include (Zig's compiler-rt / intrinsic headers)
///   2. <prefix>/lib/libc/include/<target-triple> (target-specific libc headers)
///   3. <prefix>/lib/libc/include/generic-<abi-family> (generic libc headers)
///   4. <prefix>/lib/libc/include/<arch>-<os>-any (arch+os wildcards)
///   5. <prefix>/lib/libc/include/any-<os>-any (os-only wildcards)
pub fn addZigCcImplicitIncludes(driver: *aro.Driver, resource_dir: []const u8) !void {
    const comp = driver.comp;
    const target = comp.target;
    const arch = target.cpu.arch;
    const os = target.os.tag;
    const abi = target.abi;

    // 1. Zig's compiler-provided headers (stddef.h, stdarg.h, etc.)
    const zig_lib_include = try std.fs.path.join(comp.arena, &.{ resource_dir, "lib", "include" });
    try driver.includes.append(comp.gpa, .{ .kind = .system, .path = zig_lib_include });

    const libc_include_base = try std.fs.path.join(comp.arena, &.{ resource_dir, "lib", "libc", "include" });

    // 2. Target-specific libc headers (e.g., x86_64-linux-gnu or x86-linux-gnu)
    const target_subdir = try getTargetLibcSubdir(comp.arena, arch, os, abi);
    if (target_subdir) |subdir| {
        const target_include = try std.fs.path.join(comp.arena, &.{ libc_include_base, subdir });
        try driver.includes.append(comp.gpa, .{ .kind = .system, .path = target_include });
    }

    // 3. Generic libc headers based on ABI family (glibc, musl, etc.)
    const generic_subdir = getGenericLibcSubdir(abi);
    if (generic_subdir) |subdir| {
        const generic_include = try std.fs.path.join(comp.arena, &.{ libc_include_base, subdir });
        try driver.includes.append(comp.gpa, .{ .kind = .system, .path = generic_include });
    }

    // 4. Architecture + OS wildcard headers (e.g., x86-linux-any)
    const arch_os_any = try getArchOsAnySubdir(comp.arena, arch, os);
    if (arch_os_any) |subdir| {
        const arch_os_include = try std.fs.path.join(comp.arena, &.{ libc_include_base, subdir });
        try driver.includes.append(comp.gpa, .{ .kind = .system, .path = arch_os_include });
    }

    // 5. OS-only wildcard headers (e.g., any-linux-any)
    const any_os_any = try getAnyOsAnySubdir(comp.arena, os);
    if (any_os_any) |subdir| {
        const any_os_include = try std.fs.path.join(comp.arena, &.{ libc_include_base, subdir });
        try driver.includes.append(comp.gpa, .{ .kind = .system, .path = any_os_include });
    }

    // Note: We intentionally do NOT add /usr/local/include or /usr/include.
    // absolution is self-contained and uses only the bundled headers from the
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

test "getTargetLibcSubdir x86_64/linux/gnu" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getTargetLibcSubdir(arena.allocator(), .x86_64, .linux, .gnu);
    try std.testing.expectEqualStrings("x86-linux-gnu", result.?);
}

test "getTargetLibcSubdir aarch64/linux/musl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getTargetLibcSubdir(arena.allocator(), .aarch64, .linux, .musl);
    try std.testing.expectEqualStrings("aarch64-linux-musl", result.?);
}

test "getTargetLibcSubdir arm/linux/gnueabihf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getTargetLibcSubdir(arena.allocator(), .arm, .linux, .gnueabihf);
    try std.testing.expectEqualStrings("arm-linux-gnueabi", result.?);
}

test "getTargetLibcSubdir wasm32 returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getTargetLibcSubdir(arena.allocator(), .wasm32, .linux, .gnu);
    try std.testing.expect(result == null);
}

test "getTargetLibcSubdir freestanding returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getTargetLibcSubdir(arena.allocator(), .x86_64, .freestanding, .gnu);
    try std.testing.expect(result == null);
}

test "getTargetLibcSubdir none abi on linux defaults to gnu" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getTargetLibcSubdir(arena.allocator(), .x86_64, .linux, .none);
    try std.testing.expectEqualStrings("x86-linux-gnu", result.?);
}

test "getTargetLibcSubdir none abi on non-linux returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getTargetLibcSubdir(arena.allocator(), .x86_64, .windows, .none);
    try std.testing.expect(result == null);
}

test "getTargetLibcSubdir riscv64/linux/musl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getTargetLibcSubdir(arena.allocator(), .riscv64, .linux, .musl);
    try std.testing.expectEqualStrings("riscv64-linux-musl", result.?);
}

test "getTargetLibcSubdir powerpc64/linux/gnu" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getTargetLibcSubdir(arena.allocator(), .powerpc64, .linux, .gnu);
    try std.testing.expectEqualStrings("powerpc64-linux-gnu", result.?);
}

test "getTargetLibcSubdir x86_64/macos mapped to darwin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getTargetLibcSubdir(arena.allocator(), .x86_64, .macos, .gnu);
    try std.testing.expectEqualStrings("x86-darwin-gnu", result.?);
}

test "getTargetLibcSubdir android abi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getTargetLibcSubdir(arena.allocator(), .aarch64, .linux, .android);
    try std.testing.expectEqualStrings("aarch64-linux-android", result.?);
}

test "getGenericLibcSubdir gnu returns generic-glibc" {
    try std.testing.expectEqualStrings("generic-glibc", getGenericLibcSubdir(.gnu).?);
}

test "getGenericLibcSubdir musl returns generic-musl" {
    try std.testing.expectEqualStrings("generic-musl", getGenericLibcSubdir(.musl).?);
}

test "getGenericLibcSubdir none returns generic-glibc" {
    try std.testing.expectEqualStrings("generic-glibc", getGenericLibcSubdir(.none).?);
}

test "getGenericLibcSubdir eabi returns null" {
    try std.testing.expect(getGenericLibcSubdir(.eabi) == null);
}

test "getGenericLibcSubdir gnueabihf returns generic-glibc" {
    try std.testing.expectEqualStrings("generic-glibc", getGenericLibcSubdir(.gnueabihf).?);
}

test "getGenericLibcSubdir musleabi returns generic-musl" {
    try std.testing.expectEqualStrings("generic-musl", getGenericLibcSubdir(.musleabi).?);
}

test "getArchOsAnySubdir x86_64/linux" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getArchOsAnySubdir(arena.allocator(), .x86_64, .linux);
    try std.testing.expectEqualStrings("x86-linux-any", result.?);
}

test "getArchOsAnySubdir wasm32 returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getArchOsAnySubdir(arena.allocator(), .wasm32, .linux);
    try std.testing.expect(result == null);
}

test "getArchOsAnySubdir freestanding returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getArchOsAnySubdir(arena.allocator(), .x86_64, .freestanding);
    try std.testing.expect(result == null);
}

test "getArchOsAnySubdir riscv64/freebsd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getArchOsAnySubdir(arena.allocator(), .riscv64, .freebsd);
    try std.testing.expectEqualStrings("riscv64-freebsd-any", result.?);
}

test "getAnyOsAnySubdir linux" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getAnyOsAnySubdir(arena.allocator(), .linux);
    try std.testing.expectEqualStrings("any-linux-any", result.?);
}

test "getAnyOsAnySubdir freestanding returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getAnyOsAnySubdir(arena.allocator(), .freestanding);
    try std.testing.expect(result == null);
}

test "getAnyOsAnySubdir windows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getAnyOsAnySubdir(arena.allocator(), .windows);
    try std.testing.expectEqualStrings("any-windows-any", result.?);
}

test "getAnyOsAnySubdir macos mapped to darwin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getAnyOsAnySubdir(arena.allocator(), .macos);
    try std.testing.expectEqualStrings("any-darwin-any", result.?);
}
