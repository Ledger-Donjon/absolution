const std = @import("std");
const Parser = @import("../Parser.zig");

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

fn emitMemcpy(file: *std.fs.File, depth: usize, dst_prefix: []const u8, dst: []const u8, src: []const u8, size: []const u8) !void {
    try writeIndent(file, depth);
    try file.writeAll("memcpy(");
    try file.writeAll(dst_prefix);
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
    fn openLoop(self: *LoopStack, dim: usize, index: usize) !void {
        try writeIndent(self.file, self.current_depth);
        var buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "for (size_t i{d} = 0; i{d} < {d}; i{d}++) {{\n",
            .{ index, index, dim, index },
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

/// Build a C field expression with all necessary indices.
/// Returns an owned slice that must be freed by the caller.
fn buildFieldExpression(
    allocator: std.mem.Allocator,
    global_name: []const u8,
    global_dims_len: usize,
    field_path: []const u8,
    field_dims_len: usize,
    start_index: usize,
) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print("{s}", .{global_name});
    for (0..global_dims_len) |i| {
        try w.print("[i{d}]", .{i});
    }
    if (!(field_path.len == 1 and field_path[0] == '.')) {
        try w.print("{s}", .{field_path});
    }
    for (0..field_dims_len) |fi| {
        try w.print("[i{d}]", .{start_index + fi});
    }

    return try buf.toOwnedSlice(allocator);
}

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
        \\#include <string.h>
        \\#include <stdio.h>
        \\#include "
    );
    try file.writeAll(target_path);
    try file.writeAll(
        \\"
        \\
        \\int AbsolutionTestOneInput(const uint8_t *data, size_t size);
        \\
    );

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
        const global_dims_len = g.dims.items.len;

        // Zero the entire global storage up-front so padding bytes start as 0.
        // This lets sampling ignore synthetic padding fields.
        var memset_dst_buf: [256]u8 = undefined;
        var memset_size_buf: [256]u8 = undefined;
        const memset_dst = try std.fmt.bufPrint(&memset_dst_buf, "&{s}", .{g.name});
        const memset_size = try std.fmt.bufPrint(&memset_size_buf, "sizeof({s})", .{g.name});
        try emitMemset(file, 1, memset_dst, "0", memset_size);

        // Open global loops once per global.
        var loop_stack = LoopStack.init(file, 1);
        for (g.dims.items, 0..) |d, i| {
            try loop_stack.openLoop(d, i);
        }

        for (g.fields.items) |f| {
            if (f.is_padding) continue;
            const bytes = (f.bit_width + 7) / 8;
            const bytes_str = try std.fmt.bufPrint(&bytes_buf, "{d}", .{bytes});

            const field_dims_len = f.dims.items.len;

            // Open field loops (if any) inside the global loops.
            for (f.dims.items, 0..) |d, fi| {
                const i = global_dims_len + fi;
                try loop_stack.openLoop(d, i);
            }

            // Construct expression with indices: g[i0][i1]... .field[iN]...
            const expr = try buildFieldExpression(
                allocator,
                g.name,
                global_dims_len,
                f.name,
                field_dims_len,
                global_dims_len,
            );
            defer allocator.free(expr);

            const current_depth = loop_stack.depth();
            switch (f.domain) {
                .top => {
                    try emitMemcpy(file, current_depth, "&", expr, "&data[off]", bytes_str);
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
                    try emitMemcpy(file, current_depth, "&", expr, src, bytes_str);
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
                    try emitMemcpy(file, current_depth, "&", expr, src, bytes_str);
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
    var num_buf: [64]u8 = undefined;
    var bytes_buf: [64]u8 = undefined;

    try file.writeAll("int check_invariant(void) {\n");

    for (globals) |g| {
        const global_dims_len = g.dims.items.len;

        // Open global loops once per global.
        var loop_stack = LoopStack.init(file, 1);
        for (g.dims.items, 0..) |d, i| {
            try loop_stack.openLoop(d, i);
        }

        for (g.fields.items) |f| {
            if (!f.is_padding) continue;
            const bytes = (f.bit_width + 7) / 8;
            const bytes_str = try std.fmt.bufPrint(&bytes_buf, "{d}", .{bytes});

            const field_dims_len = f.dims.items.len;

            // Open field loops (if any) inside the global loops.
            for (f.dims.items, 0..) |d, fi| {
                const i = global_dims_len + fi;
                try loop_stack.openLoop(d, i);
            }

            const current_depth = loop_stack.depth();
            try writeIndent(file, current_depth);
            try file.writeAll("for (size_t i = 0; i < ");
            try file.writeAll(bytes_str);
            try file.writeAll("; i++) {\n");
            try writeIndent(file, current_depth + 1);
            if (f.offset_bits % 8 != 0) return error.UnalignedPaddingOffset;
            const off_bytes_str = try std.fmt.bufPrint(&num_buf, "{d}", .{f.offset_bits / 8});
            const container_path = f.pad_container orelse f.name;

            const container_expr = try buildFieldExpression(
                allocator,
                g.name,
                global_dims_len,
                container_path,
                field_dims_len,
                global_dims_len,
            );
            defer allocator.free(container_expr);

            try file.writeAll("if ((((const uint8_t *)&");
            try file.writeAll(container_expr);
            try file.writeAll(") + ");
            try file.writeAll(off_bytes_str);
            try file.writeAll(")[i] != 0) return -1;\n");
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
fn emitEntrypoint(file: *std.fs.File) !void {
    try file.writeAll(
        \\int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
        \\    ptrdiff_t consumed = sample_invariant(data, size);
        \\    if (consumed < 0) return 0;
        \\    data += (size_t)consumed;
        \\    size -= (size_t)consumed;
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
