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
                // Blob bytes come from emitted domain tables, not from the fuzzer stream.
                .whole_values => global_mult * ir.constrainedSelectorBytes(f.domain),
            };
            total += bytes;
        }
    }
    return total;
}

// Write a file the size given, no guarantee on the content is given
pub fn writeSeed(io: std.Io, path: []const u8, size: usize) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    const chunk_size = 4096;
    // we use undefined memory since the seed content does not matter.
    const chunk: [chunk_size]u8 = undefined;

    var remaining = size;
    while (remaining > 0) {
        const n = @min(remaining, chunk_size);
        try file.writeStreamingAll(io, chunk[0..n]);
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

test "neededBytesFromGlobals whole_values counts selector bytes per global instance only" {
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
    // global_mult=3, multi-candidate => 1 selector byte per instance (blobs are static in C)
    try std.testing.expectEqual(@as(usize, 3), neededBytesFromGlobals(globals));
}

test "neededBytesFromGlobals whole_values singleton uses zero fuzzer bytes per instance" {
    const fields: []const ir.Field = &.{
        .{
            .name = ".b",
            .bit_width = 8,
            .is_padding = false,
            .dims = &.{.{ .len = 4, .stride_bytes = 1 }},
            .domain = .{ .whole_values = &.{&[_]u8{ 1, 2, 3, 4 }} },
        },
    };
    const globals: []const ir.Global = &.{.{
        .name = "pkt",
        .source_file = "",
        .size_bytes = 4,
        .is_static = false,
        .dims = &.{.{ .len = 2, .stride_bytes = 4 }},
        .fields = @constCast(fields),
    }};
    try std.testing.expectEqual(@as(usize, 0), neededBytesFromGlobals(globals));
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
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(path);
    const full = try std.fs.path.join(std.testing.allocator, &.{ path, "seed.bin" });
    defer std.testing.allocator.free(full);

    try writeSeed(std.testing.io, full, 100);
    const stat = try tmp.dir.statFile(std.testing.io, "seed.bin", .{});
    try std.testing.expectEqual(@as(u64, 100), stat.size);
}

test "writeSeed creates empty file for size 0" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(path);
    const full = try std.fs.path.join(std.testing.allocator, &.{ path, "empty.bin" });
    defer std.testing.allocator.free(full);

    try writeSeed(std.testing.io, full, 0);
    const stat = try tmp.dir.statFile(std.testing.io, "empty.bin", .{});
    try std.testing.expectEqual(@as(u64, 0), stat.size);
}

test "writeSeed handles size larger than chunk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(path);
    const full = try std.fs.path.join(std.testing.allocator, &.{ path, "big.bin" });
    defer std.testing.allocator.free(full);

    try writeSeed(std.testing.io, full, 5000);
    const stat = try tmp.dir.statFile(std.testing.io, "big.bin", .{});
    try std.testing.expectEqual(@as(u64, 5000), stat.size);
}
