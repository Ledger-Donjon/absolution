//! Seed generation for libFuzzer harness execution.
//!
//! This module implements the behavior when specifying the seed parameter.
const std = @import("std");
const ir = @import("cgen/ir.zig");

pub fn neededBytesFromGlobals(globals: []const ir.Global) usize {
    var total: usize = 0;
    for (globals) |g| {
        const global_mult = ir.dimsProduct(g.dims);
        for (g.fields) |f| {
            if (f.is_padding) continue;
            const field_mult = ir.dimsProduct(f.dims);
            const bytes: usize = switch (f.domain) {
                .top => ir.elementBytes(f) * global_mult * field_mult,
                .values, .pointers => ir.constrainedSelectorBytes(f.domain) * global_mult * field_mult,
                .whole_values => global_mult * (ir.constrainedSelectorBytes(f.domain) + ir.wholeFieldBytes(f)),
            };
            total += bytes;
        }
    }
    return total;
}

// Write a file the size given, no garantee on the content is given
pub fn writeSeed(path: []const u8, size: usize) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    const chunk_size = 4096;
    // we use undefine memory as the seed content does not matter
    const chunk: [chunk_size]u8 = undefined;

    var remaining = size;
    while (remaining > 0) {
        const n = @min(remaining, chunk_size);
        try file.writeAll(chunk[0..n]);
        remaining -= n;
    }
}

test "neededBytesFromGlobals returns 0 for empty globals" {
    const globals: []const ir.Global = &.{};
    try std.testing.expectEqual(@as(usize, 0), neededBytesFromGlobals(globals));
}

test "neededBytesFromGlobals skips padding fields" {
    const fields: []const ir.Field = &.{.{
        .name = ".pad0",
        .bit_width = 32,
        .is_padding = true,
    }};
    const globals: []const ir.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 4,
        .is_static = false,
        .dims = &.{},
        .fields = @constCast(fields),
    }};
    try std.testing.expectEqual(@as(usize, 0), neededBytesFromGlobals(globals));
}

test "neededBytesFromGlobals counts .top bytes by width" {
    const fields: []const ir.Field = &.{.{
        .name = ".x",
        .bit_width = 32,
        .is_padding = false,
        .domain = .top,
    }};
    const globals: []const ir.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 4,
        .is_static = false,
        .dims = &.{},
        .fields = @constCast(fields),
    }};
    try std.testing.expectEqual(@as(usize, 4), neededBytesFromGlobals(globals));
}

test "neededBytesFromGlobals counts multi-candidate .values/.pointers as 1 byte each" {
    const fields: []const ir.Field = &.{
        .{
            .name = ".a",
            .bit_width = 32,
            .is_padding = false,
            .domain = .{ .values = &.{ "0xAA", "0xBB" } },
        },
        .{
            .name = ".b",
            .bit_width = 64,
            .is_padding = false,
            .domain = .{ .pointers = &.{ "func", "other" } },
        },
    };
    const globals: []const ir.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 12,
        .is_static = false,
        .dims = &.{},
        .fields = @constCast(fields),
    }};
    try std.testing.expectEqual(@as(usize, 2), neededBytesFromGlobals(globals));
}

test "neededBytesFromGlobals singleton constrained domains use 0 selector bytes" {
    const fields: []const ir.Field = &.{
        .{
            .name = ".a",
            .bit_width = 32,
            .is_padding = false,
            .domain = .{ .values = &.{"0xAA"} },
        },
        .{
            .name = ".b",
            .bit_width = 64,
            .is_padding = false,
            .domain = .{ .pointers = &.{"func"} },
        },
    };
    const globals: []const ir.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 12,
        .is_static = false,
        .dims = &.{},
        .fields = @constCast(fields),
    }};
    try std.testing.expectEqual(@as(usize, 0), neededBytesFromGlobals(globals));
}

test "neededBytesFromGlobals whole_values counts selector and blob per global instance" {
    const fields: []const ir.Field = &.{
        .{
            .name = ".buf",
            .bit_width = 8,
            .is_padding = false,
            .dims = &.{.{ .len = 2, .stride_bytes = 1 }},
            .domain = .{ .whole_values = &.{ &[_]u8{ 1, 2 }, &[_]u8{ 3, 4 } } },
        },
    };
    const globals: []const ir.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 6,
        .is_static = false,
        .dims = &.{.{ .len = 3, .stride_bytes = 2 }},
        .fields = @constCast(fields),
    }};
    // global_mult=3, per instance: 1 selector + 2 blob bytes => 3 * 3 = 9
    try std.testing.expectEqual(@as(usize, 9), neededBytesFromGlobals(globals));
}

test "neededBytesFromGlobals multiplies by global and field dims" {
    const fields: []const ir.Field = &.{.{
        .name = ".x",
        .bit_width = 8,
        .is_padding = false,
        .domain = .top,
        .dims = &.{.{ .len = 4, .stride_bytes = 1 }},
    }};
    const globals: []const ir.Global = &.{.{
        .name = "arr",
        .source_file = "",
        .size_bytes = 12,
        .is_static = false,
        .dims = &.{.{ .len = 3, .stride_bytes = 4 }},
        .fields = @constCast(fields),
    }};
    // 1 byte * global_dim(3) * field_dim(4) = 12
    try std.testing.expectEqual(@as(usize, 12), neededBytesFromGlobals(globals));
}

test "writeSeed creates file with exact size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const full = try std.fs.path.join(std.testing.allocator, &.{ path, "seed.bin" });
    defer std.testing.allocator.free(full);

    try writeSeed(full, 100);
    const stat = try tmp.dir.statFile("seed.bin");
    try std.testing.expectEqual(@as(u64, 100), stat.size);
}

test "writeSeed creates empty file for size 0" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const full = try std.fs.path.join(std.testing.allocator, &.{ path, "empty.bin" });
    defer std.testing.allocator.free(full);

    try writeSeed(full, 0);
    const stat = try tmp.dir.statFile("empty.bin");
    try std.testing.expectEqual(@as(u64, 0), stat.size);
}

test "writeSeed handles size larger than chunk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const full = try std.fs.path.join(std.testing.allocator, &.{ path, "big.bin" });
    defer std.testing.allocator.free(full);

    try writeSeed(full, 5000);
    const stat = try tmp.dir.statFile("big.bin");
    try std.testing.expectEqual(@as(u64, 5000), stat.size);
}
