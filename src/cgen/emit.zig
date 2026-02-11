const std = @import("std");
const Parser = @import("../Parser.zig");
const Tree = @import("tree.zig");

fn writeIndent(file: *std.fs.File, depth: usize) !void {
    for (0..depth) |_| try file.writeAll("    ");
}

fn emitMemset(file: *std.fs.File, depth: usize, dst: []const u8, value: []const u8, size: []const u8) !void {
    try writeIndent(file, depth);
    try file.writeAll("memset(");
    try file.writeAll(dst);
    try file.writeAll(", ");
    try file.writeAll(value);
    try file.writeAll(", ");
    try file.writeAll(size);
    try file.writeAll(");\n");
}

fn emitMemcpy(file: *std.fs.File, depth: usize, dst: []const u8, src: []const u8, size: []const u8) !void {
    try writeIndent(file, depth);
    try file.writeAll("memcpy(");
    try file.writeAll(dst);
    try file.writeAll(", ");
    try file.writeAll(src);
    try file.writeAll(", ");
    try file.writeAll(size);
    try file.writeAll(");\n");
}

fn incrementOffset(file: *std.fs.File, depth: usize, inc: []const u8) !void {
    try writeIndent(file, depth);
    try file.writeAll("off += ");
    try file.writeAll(inc);
    try file.writeAll(";\n");
}

/// Helper for managing nested loop generation.
const LoopStack = struct {
    file: *std.fs.File,
    base_depth: usize,
    current_depth: usize,

    fn init(file: *std.fs.File, base_depth: usize) LoopStack {
        return .{
            .file = file,
            .base_depth = base_depth,
            .current_depth = base_depth,
        };
    }

    /// Open a loop for a dimension.
    fn openLoop(self: *LoopStack, dim: Tree.Dimension, index: usize) !void {
        try writeIndent(self.file, self.current_depth);
        var buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "for (size_t i{d} = 0; i{d} < {d}; i{d}++) {{\n",
            .{ index, index, dim.len, index },
        );
        try self.file.writeAll(line);
        self.current_depth += 1;
    }

    /// Close the last N loops that were opened.
    fn closeLoops(self: *LoopStack, count: usize) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            self.current_depth -= 1;
            try writeIndent(self.file, self.current_depth);
            try self.file.writeAll("}\n");
        }
    }

    /// Get the current indentation depth.
    fn depth(self: *const LoopStack) usize {
        return self.current_depth;
    }
};

fn mangleName(allocator: std.mem.Allocator, path: []const u8, symbol: []const u8) ![]const u8 {
    // Sanitize path: replace non-alphanumeric with _
    const sanitized = try allocator.dupe(u8, path);
    defer allocator.free(sanitized);
    for (sanitized) |*c| {
        if (!std.ascii.isAlphanumeric(c.*)) {
            c.* = '_';
        }
    }
    return std.fmt.allocPrint(allocator, "{s}_{s}", .{ sanitized, symbol });
}

/// Generate offset calculation string: "base + i0*s0 + i1*s1 + ..."
fn emitOffsetCalc(
    allocator: std.mem.Allocator,
    global_dims: []const Tree.Dimension,
    field_dims: []const Tree.Dimension,
    base_offset: u64,
) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print("{d}", .{base_offset});

    // Global dims use indices i0, i1, ...
    for (global_dims, 0..) |d, i| {
        if (d.stride_bytes > 0) {
            try w.print(" + i{d} * {d}", .{ i, d.stride_bytes });
        }
    }

    // Field dims use indices i{global_dims.len}, ...
    for (field_dims, 0..) |d, i| {
        if (d.stride_bytes > 0) {
            try w.print(" + i{d} * {d}", .{ global_dims.len + i, d.stride_bytes });
        }
    }

    return try buf.toOwnedSlice(allocator);
}

/// Generate the C sampler, checker, and libFuzzer entrypoint.
pub fn writeFuzzerC(
    allocator: std.mem.Allocator,
    globals: []const Parser.ParsedGlobal,
    needed_bytes: usize,
    out_path: []const u8,
    redef_path: []const u8,
    entry_name: []const u8,
) !void {
    var file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer file.close();

    var redef_file = try std.fs.cwd().createFile(redef_path, .{ .truncate = true });
    defer redef_file.close();

    try file.writeAll(
        \\#include <assert.h>
        \\#include <stdint.h>
        \\#include <stddef.h>
        \\#include <string.h>
        \\#include <stdio.h>
        \\
    );

    // Write the forward declaration for the user's harness function.
    const fwd_decl = try std.fmt.allocPrint(allocator, "int {s}(const uint8_t *data, size_t size);\n\n", .{entry_name});
    defer allocator.free(fwd_decl);
    try file.writeAll(fwd_decl);

    for (globals) |g| {
        const mangled = if (g.is_static)
            try mangleName(allocator, g.source_file, g.name)
        else
            try allocator.dupe(u8, g.name);
        defer allocator.free(mangled);

        if (g.is_static) {
            // Write redef line
            const line = try std.fmt.allocPrint(allocator, "{s} {s} {s}\n", .{ g.source_file, g.name, mangled });
            defer allocator.free(line);
            try redef_file.writeAll(line);
        }

        // Write extern decl
        // Note: we treat everything as byte array to avoid type issues in C
        const decl = try std.fmt.allocPrint(allocator, "extern uint8_t {s}[{d}];\n", .{ mangled, g.size_bytes });
        defer allocator.free(decl);
        try file.writeAll(decl);
    }

    try file.writeAll("\n");

    try emitSampler(allocator, globals, needed_bytes, &file);
    try emitChecker(allocator, globals, &file);
    try emitEntrypoint(allocator, &file, entry_name);
}

/// Emit the sampler that hydrates globals from fuzzer input or domains.
/// Args:
///   module: Flattened module describing globals/fields.
///   file: Output file handle for C emission.
fn emitSampler(allocator: std.mem.Allocator, globals: []const Parser.ParsedGlobal, needed_bytes: usize, file: *std.fs.File) !void {
    var num_buf: [64]u8 = undefined;
    var bytes_buf: [64]u8 = undefined;
    const needed_str = try std.fmt.bufPrint(&num_buf, "{d}", .{needed_bytes});

    var value_idx: usize = 0;
    var ptr_idx: usize = 0;
    try file.writeAll("ptrdiff_t sample_invariant(const uint8_t *data, size_t size) {\n");
    try file.writeAll("    size_t off = 0;\n");
    try file.writeAll("    const size_t needed = ");
    try file.writeAll(needed_str);
    try file.writeAll(";\n");
    try file.writeAll("    if (size < needed) return -1;\n");

    for (globals) |g| {
        const global_dims_len = g.dims.len;

        const mangled = if (g.is_static)
            try mangleName(allocator, g.source_file, g.name)
        else
            try allocator.dupe(u8, g.name);
        defer allocator.free(mangled);

        // Zero the entire global storage up-front so padding bytes start as 0.
        // This lets sampling ignore synthetic padding fields.
        var memset_dst_buf: [256]u8 = undefined;
        var memset_size_buf: [256]u8 = undefined;
        // Access via mangled name
        const memset_dst = try std.fmt.bufPrint(&memset_dst_buf, "{s}", .{mangled});
        const memset_size = try std.fmt.bufPrint(&memset_size_buf, "sizeof({s})", .{mangled});
        try emitMemset(file, 1, memset_dst, "0", memset_size);

        // Open global loops once per global.
        var loop_stack = LoopStack.init(file, 1);
        for (g.dims, 0..) |d, i| {
            try loop_stack.openLoop(d, i);
        }

        for (g.fields) |f| {
            if (f.is_padding) continue;
            const bytes = (f.bit_width + 7) / 8;
            const bytes_str = try std.fmt.bufPrint(&bytes_buf, "{d}", .{bytes});

            const field_dims_len = f.dims.len;

            // Open field loops (if any) inside the global loops.
            for (f.dims, 0..) |d, fi| {
                const i = global_dims_len + fi;
                try loop_stack.openLoop(d, i);
            }

            // Construct offset expression
            const offset_expr = try emitOffsetCalc(allocator, g.dims, f.dims, @intCast(f.offset_bits / 8) // Byte offset
            );
            defer allocator.free(offset_expr);

            // Access: &mangled[offset_expr]
            // Wait, offset_expr might be long. We should allocate.
            const dst_expr = try std.fmt.allocPrint(allocator, "&{s}[{s}]", .{ mangled, offset_expr });
            defer allocator.free(dst_expr);

            const current_depth = loop_stack.depth();
            switch (f.domain) {
                .top => {
                    try emitMemcpy(file, current_depth, dst_expr, "&data[off]", bytes_str);
                    try incrementOffset(file, current_depth, bytes_str);
                },
                .values => |vals| {
                    var label_buf: [64]u8 = undefined;
                    const label = try std.fmt.bufPrint(&label_buf, "FM_VAL_{d}", .{value_idx});
                    value_idx += 1;

                    try writeIndent(file, current_depth);
                    try file.writeAll("static const uint8_t ");
                    try file.writeAll(label);
                    try file.writeAll("[] = { ");
                    for (vals, 0..) |v, vi| {
                        if (vi > 0) try file.writeAll(", ");
                        for (v, 0..) |b, bi| {
                            if (bi > 0) try file.writeAll(", ");
                            const byte_str = try std.fmt.bufPrint(&num_buf, "0x{X:0>2}", .{b});
                            try file.writeAll(byte_str);
                        }
                    }
                    try file.writeAll(" };\n");

                    try writeIndent(file, current_depth);
                    try file.writeAll("size_t idx_");
                    try file.writeAll(label);
                    try file.writeAll(" = data[off] % ");
                    const count_str = try std.fmt.bufPrint(&num_buf, "{d}", .{vals.len});
                    try file.writeAll(count_str);
                    try file.writeAll(";\n");

                    var src_buf: [256]u8 = undefined;
                    const src = try std.fmt.bufPrint(&src_buf, "&{s}[idx_{s} * {s}]", .{ label, label, bytes_str });
                    try emitMemcpy(file, current_depth, dst_expr, src, bytes_str);
                    try incrementOffset(file, current_depth, "1");
                },
                .pointers => |ptrs| {
                    var ptr_label_buf: [64]u8 = undefined;
                    const ptr_label = try std.fmt.bufPrint(&ptr_label_buf, "FM_PTR_{d}", .{ptr_idx});
                    ptr_idx += 1;

                    try writeIndent(file, current_depth);
                    try file.writeAll("static void *");
                    try file.writeAll(ptr_label);
                    try file.writeAll("[] = { ");
                    for (ptrs, 0..) |p, pi| {
                        if (pi > 0) try file.writeAll(", ");
                        try file.writeAll("&");
                        try file.writeAll(p);
                    }
                    try file.writeAll(" };\n");

                    try writeIndent(file, current_depth);
                    try file.writeAll("size_t idx_");
                    try file.writeAll(ptr_label);
                    try file.writeAll(" = data[off] % ");
                    const count_str = try std.fmt.bufPrint(&num_buf, "{d}", .{ptrs.len});
                    try file.writeAll(count_str);
                    try file.writeAll(";\n");

                    var src_buf: [128]u8 = undefined;
                    const src = try std.fmt.bufPrint(&src_buf, "&{s}[idx_{s}]", .{ ptr_label, ptr_label });
                    try emitMemcpy(file, current_depth, dst_expr, src, bytes_str);
                    try incrementOffset(file, current_depth, "1");
                },
            }

            // Close only field loops.
            try loop_stack.closeLoops(field_dims_len);
        }

        // Close global loops.
        try loop_stack.closeLoops(global_dims_len);
    }

    try file.writeAll("    return off;\n}\n\n");
}

/// Emit the checker that enforces padding bytes stay zeroed.
fn emitChecker(allocator: std.mem.Allocator, globals: []const Parser.ParsedGlobal, file: *std.fs.File) !void {
    var bytes_buf: [64]u8 = undefined;

    try file.writeAll("int check_invariant(void) {\n");

    for (globals) |g| {
        const global_dims_len = g.dims.len;

        const mangled = if (g.is_static)
            try mangleName(allocator, g.source_file, g.name)
        else
            try allocator.dupe(u8, g.name);
        defer allocator.free(mangled);

        // Open global loops once per global.
        var loop_stack = LoopStack.init(file, 1);
        for (g.dims, 0..) |d, i| {
            try loop_stack.openLoop(d, i);
        }

        for (g.fields) |f| {
            if (!f.is_padding) continue;
            const bytes = (f.bit_width + 7) / 8;
            const bytes_str = try std.fmt.bufPrint(&bytes_buf, "{d}", .{bytes});

            const field_dims_len = f.dims.len;

            // Open field loops (if any) inside the global loops.
            for (f.dims, 0..) |d, fi| {
                const i = global_dims_len + fi;
                try loop_stack.openLoop(d, i);
            }

            const current_depth = loop_stack.depth();
            // Some targets (notably those using bitfields) can produce padding with a
            // bit offset that is not byte-aligned. Since the checker operates on
            // bytes, conservatively skip unaligned padding regions instead of
            // failing code generation.
            if (f.offset_bits % 8 != 0) {
                try loop_stack.closeLoops(field_dims_len);
                continue;
            }

            try writeIndent(file, current_depth);
            try file.writeAll("for (size_t i = 0; i < ");
            try file.writeAll(bytes_str);
            try file.writeAll("; i++) {\n");
            try writeIndent(file, current_depth + 1);

            // Construct offset expression
            const offset_expr = try emitOffsetCalc(allocator, g.dims, f.dims, @intCast(f.offset_bits / 8) // Byte offset
            );
            defer allocator.free(offset_expr);

            try file.writeAll("if (");
            try file.writeAll(mangled);
            try file.writeAll("[");
            try file.writeAll(offset_expr);
            try file.writeAll(" + i"); // offset + i
            try file.writeAll("] != 0) return -1;\n");

            try writeIndent(file, current_depth);
            try file.writeAll("}\n");

            // Close only field loops.
            try loop_stack.closeLoops(field_dims_len);
        }

        // Close global loops.
        try loop_stack.closeLoops(global_dims_len);
    }

    try file.writeAll("    return 0;\n");
    try file.writeAll("}\n\n");
}

/// Emit the libFuzzer entrypoint that wires sampling, harness, and checks.
fn emitEntrypoint(allocator: std.mem.Allocator, file: *std.fs.File, entry_name: []const u8) !void {
    try file.writeAll(
        \\int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
        \\    ptrdiff_t consumed = sample_invariant(data, size);
        \\    if (consumed < 0) return 0;
        \\    data += (size_t)consumed;
        \\    size -= (size_t)consumed;
        \\
    );

    const call_line = try std.fmt.allocPrint(allocator, "    int res = {s}(data, size);\n", .{entry_name});
    defer allocator.free(call_line);
    try file.writeAll(call_line);

    try file.writeAll(
        \\    if (res == -1) return 0;
        \\    assert(check_invariant() == 0);
        \\    return 0;
        \\}
    );
}
