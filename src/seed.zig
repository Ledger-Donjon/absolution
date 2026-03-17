//! Seed generation for libFuzzer harness execution.
//!
//! This module implements the behavior when specifying the seed parameter.
const std = @import("std");
const ir = @import("cgen/ir.zig");

pub fn neededBytesFromGlobals(globals: []const ir.Global) usize {
    var total: usize = 0;
    for (globals) |g| {
        const global_mult = dimsProduct(g.dims);
        for (g.fields) |f| {
            if (f.is_padding) continue;
            const field_mult = dimsProduct(f.dims);
            const bytes: usize = switch (f.domain) {
                .top => (f.bit_width + 7) / 8,
                .values, .pointers => 1,
            };
            total += bytes * global_mult * field_mult;
        }
    }
    return total;
}

fn dimsProduct(dims: []const ir.Dimension) usize {
    var prod: usize = 1;
    for (dims) |d| prod *= d.len;
    return prod;
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
