const tree = @import("cgen/tree.zig");
const builder = @import("cgen/builder.zig");
const emit = @import("cgen/emit.zig");
const invariant = @import("invariant.zig");
const std = @import("std");

/// Public re-exports for the C generation pipeline.
pub const Tree = tree;
pub const Builder = builder;
pub const Emit = emit;

/// Convenience helper to build a module from parsed globals and emit a fuzzer.
pub fn generateFuzzer(
    allocator: std.mem.Allocator,
    globals: *std.ArrayList(Builder.ParsedGlobal),
    target_path: []const u8,
    out_c_path: []const u8,
    zon_path: ?[]const u8,
    inv: ?invariant.Invariant,
) !usize {
    if (inv) |spec| {
        try invariant.applyToGlobals(allocator, globals, spec);
    }

    const needed_bytes = neededBytesFromGlobals(globals.items);

    try Emit.writeFuzzerC(allocator, globals.items, needed_bytes, out_c_path, target_path);

    if (zon_path) |zp| {
        var aw = std.Io.Writer.Allocating.init(allocator);
        try std.zon.stringify.serialize(globals.items, .{ .whitespace = true }, &aw.writer);
        const zon_bytes = try aw.toOwnedSlice();
        defer allocator.free(zon_bytes);
        try Builder.writeFile(zp, zon_bytes);
    }

    return needed_bytes;
}

fn neededBytesFromGlobals(globals: []const Builder.ParsedGlobal) usize {
    var total: usize = 0;
    for (globals) |g| {
        const global_mult = dimsProduct(g.dims.items);
        for (g.fields.items) |f| {
            const field_mult = dimsProduct(f.dims.items);
            const bytes = (f.bit_width + 7) / 8;
            total += bytes * global_mult * field_mult;
        }
    }
    return total;
}

fn dimsProduct(dims: []const usize) usize {
    var prod: usize = 1;
    for (dims) |d| prod *= d;
    return prod;
}
