const std = @import("std");
const Parser = @import("../Parser.zig");

/// Generate the C sampler, checker, and libFuzzer entrypoint.
pub fn writeFuzzerC(
    allocator: std.mem.Allocator,
    globals: []const Parser.ParsedGlobal,
    needed_bytes: usize,
    out_path: []const u8,
    target_path: []const u8,
) !void {
    var file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(
        \\#include <assert.h>
        \\#include <stdint.h>
        \\#include <stddef.h>
        \\#include <sys/types.h>
        \\#include <string.h>
        \\#include <stdio.h>
        \\
    );

    try file.writeAll("#include \"");
    try file.writeAll(target_path);
    try file.writeAll("\"\n");

    try emitSampler(allocator, globals, needed_bytes, &file);
    try emitChecker(allocator, globals, &file);
    try emitEntrypoint(&file);
}

/// Emit the sampler that hydrates globals from fuzzer input or domains.
/// Args:
///   module: Flattened module describing globals/fields.
///   file: Output file handle for C emission.
fn emitSampler(allocator: std.mem.Allocator, globals: []const Parser.ParsedGlobal, needed_bytes: usize, file: *std.fs.File) !void {
    var num_buf: [64]u8 = undefined;
    const needed_str = try std.fmt.bufPrint(&num_buf, "{d}", .{needed_bytes});

    var expr_buf: std.ArrayList(u8) = .empty;
    defer expr_buf.deinit(allocator);

    var value_idx: usize = 0;
    var ptr_idx: usize = 0;
    try file.writeAll("ssize_t sample_invariant(const uint8_t *data, size_t size) {\n");
    try file.writeAll("    size_t off = 0;\n");
    try file.writeAll("    const size_t needed = ");
    try file.writeAll(needed_str);
    try file.writeAll(";\n");
    try file.writeAll("    if (size < needed) return -1;\n");

    for (globals) |g| {
        for (g.fields.items) |f| {
            const bytes = (f.bit_width + 7) / 8;
            const bytes_str = try std.fmt.bufPrint(&num_buf, "{d}", .{bytes});

            // Construct expression
            const expr: []const u8 = if (f.name.len == 1 and f.name[0] == '.') blk: {
                break :blk g.name;
            } else blk: {
                expr_buf.clearRetainingCapacity();
                try expr_buf.writer(allocator).print("{s}{s}", .{ g.name, f.name });
                break :blk expr_buf.items;
            };

            if (f.is_padding) {
                try file.writeAll("    memset(&");
                try file.writeAll(expr);
                try file.writeAll(", 0, ");
                try file.writeAll(bytes_str);
                try file.writeAll(");\n");
                continue;
            }

            switch (f.domain) {
                .top => {
                    try file.writeAll("    memcpy(&");
                    try file.writeAll(expr);
                    try file.writeAll(", &data[off], ");
                    try file.writeAll(bytes_str);
                    try file.writeAll(");\n");
                    try file.writeAll("    off += ");
                    try file.writeAll(bytes_str);
                    try file.writeAll(";\n");
                },
                .values => |vals| {
                    // Reuse expr_buf for label if needed, but we need expr for memcpy.
                    // So we should allocate a separate buffer or string for label.
                    // Or since label is short, we can use a small stack buffer for it?
                    // "FM_VAL_{d}" is short.
                    var label_buf: [64]u8 = undefined;
                    const label = try std.fmt.bufPrint(&label_buf, "FM_VAL_{d}", .{value_idx});
                    value_idx += 1;

                    try file.writeAll("    static const uint8_t ");
                    try file.writeAll(label);
                    try file.writeAll("[] = { ");
                    for (vals[0], 0..) |b, bi| {
                        if (bi > 0) try file.writeAll(", ");
                        const byte_str = try std.fmt.bufPrint(&num_buf, "0x{X:0>2}", .{b});
                        try file.writeAll(byte_str);
                    }
                    try file.writeAll(" };\n");
                    try file.writeAll("    memcpy(&");
                    try file.writeAll(expr);
                    try file.writeAll(", ");
                    try file.writeAll(label);
                    try file.writeAll(", ");
                    try file.writeAll(bytes_str);
                    try file.writeAll(");\n");
                    try file.writeAll("    off += ");
                    try file.writeAll(bytes_str);
                    try file.writeAll(";\n");
                },
                .pointers => |ptrs| {
                    var ptr_label_buf: [64]u8 = undefined;
                    const ptr_label = try std.fmt.bufPrint(&ptr_label_buf, "FM_PTR_{d}", .{ptr_idx});
                    ptr_idx += 1;
                    const target = ptrs[0];
                    try file.writeAll("    void *");
                    try file.writeAll(ptr_label);
                    try file.writeAll(" = (void *)&");
                    try file.writeAll(target);
                    try file.writeAll(";\n");
                    try file.writeAll("    memcpy(&");
                    try file.writeAll(expr);
                    try file.writeAll(", &");
                    try file.writeAll(ptr_label);
                    try file.writeAll(", ");
                    try file.writeAll(bytes_str);
                    try file.writeAll(");\n");
                    try file.writeAll("    off += ");
                    try file.writeAll(bytes_str);
                    try file.writeAll(";\n");
                },
            }
        }
    }

    try file.writeAll("    return size - off;\n}\n\n");
}

/// Emit the checker that enforces padding bytes stay zeroed.
fn emitChecker(allocator: std.mem.Allocator, globals: []const Parser.ParsedGlobal, file: *std.fs.File) !void {
    var num_buf: [64]u8 = undefined;

    var expr_buf: std.ArrayList(u8) = .empty;
    defer expr_buf.deinit(allocator);

    try file.writeAll("int check_invariant(void) {\n");

    for (globals) |g| {
        for (g.fields.items) |f| {
            if (!f.is_padding) continue;
            const bytes = (f.bit_width + 7) / 8;
            const bytes_str = try std.fmt.bufPrint(&num_buf, "{d}", .{bytes});

            const expr: []const u8 = if (f.name.len == 1 and f.name[0] == '.') blk: {
                break :blk g.name;
            } else blk: {
                expr_buf.clearRetainingCapacity();
                try expr_buf.writer(allocator).print("{s}{s}", .{ g.name, f.name });
                break :blk expr_buf.items;
            };

            try file.writeAll("    for (size_t i = 0; i < ");
            try file.writeAll(bytes_str);
            try file.writeAll("; i++) {\n");
            try file.writeAll("        if (((const uint8_t *)&");
            try file.writeAll(expr);
            try file.writeAll(")[i] != 0) return -1;\n");
            try file.writeAll("    }\n");
        }
    }

    try file.writeAll("    return 0;\n");
    try file.writeAll("}\n\n");
}

/// Emit the libFuzzer entrypoint that wires sampling, harness, and checks.
fn emitEntrypoint(file: *std.fs.File) !void {
    try file.writeAll(
        \\int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
        \\    ssize_t rem = sample_invariant(data, size);
        \\    if (rem == -1) return 0;
        \\    size -= rem;
        \\    data += rem;
        \\    int res = AbsolutionTestOneInput(data, size);
        \\    if (res == -1) return 0;
        \\    assert(check_invariant() == 0);
        \\    return 0;
        \\}
    );
}

/// Write a buffer to disk, truncating or creating the target file.
fn writeFile(path: []const u8, contents: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}
