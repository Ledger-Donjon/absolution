const std = @import("std");
const Parser = @import("../Parser.zig");
const ir = @import("ir.zig");

fn writeIndent(io: std.Io, file: *std.Io.File, depth: usize) !void {
    for (0..depth) |_| try file.writeStreamingAll(io, "    ");
}

fn emitMemset(io: std.Io, file: *std.Io.File, depth: usize, dst: []const u8, value: []const u8, size: []const u8) !void {
    try writeIndent(io, file, depth);
    try file.writeStreamingAll(io, "memset(");
    try file.writeStreamingAll(io, dst);
    try file.writeStreamingAll(io, ", ");
    try file.writeStreamingAll(io, value);
    try file.writeStreamingAll(io, ", ");
    try file.writeStreamingAll(io, size);
    try file.writeStreamingAll(io, ");\n");
}

fn emitMemcpy(io: std.Io, file: *std.Io.File, depth: usize, dst: []const u8, src: []const u8, size: []const u8) !void {
    try writeIndent(io, file, depth);
    try file.writeStreamingAll(io, "memcpy(");
    try file.writeStreamingAll(io, dst);
    try file.writeStreamingAll(io, ", ");
    try file.writeStreamingAll(io, src);
    try file.writeStreamingAll(io, ", ");
    try file.writeStreamingAll(io, size);
    try file.writeStreamingAll(io, ");\n");
}

fn incrementOffset(io: std.Io, file: *std.Io.File, depth: usize, inc: []const u8) !void {
    try writeIndent(io, file, depth);
    try file.writeStreamingAll(io, "off += ");
    try file.writeStreamingAll(io, inc);
    try file.writeStreamingAll(io, ";\n");
}

/// Helper for managing nested loop generation.
const LoopStack = struct {
    file: *std.Io.File,
    io: std.Io,
    base_depth: usize,
    current_depth: usize,

    fn init(io: std.Io, file: *std.Io.File, base_depth: usize) LoopStack {
        return .{
            .file = file,
            .io = io,
            .base_depth = base_depth,
            .current_depth = base_depth,
        };
    }

    /// Open a loop for a dimension.
    fn openLoop(self: *LoopStack, dim: ir.Dimension, index: usize) !void {
        try writeIndent(self.io, self.file, self.current_depth);
        var buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "for (size_t i{d} = 0; i{d} < {d}; i{d}++) {{\n",
            .{ index, index, dim.len, index },
        );
        try self.file.writeStreamingAll(self.io, line);
        self.current_depth += 1;
    }

    /// Close the last N loops that were opened.
    fn closeLoops(self: *LoopStack, count: usize) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            self.current_depth -= 1;
            try writeIndent(self.io, self.file, self.current_depth);
            try self.file.writeStreamingAll(self.io, "}\n");
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

/// Build a C expression that indexes into a dense whole_values blob using the
/// loop variables from the field dimensions.  The blob stores elements
/// sequentially (no stride gaps), so the offset for element (i_k, i_k+1, ...)
/// is: src_base + (i_k * inner_product_k+1 + i_k+1 * inner_product_k+2 + ...) * elem_bytes
fn emitBlobOffsetExpr(
    buf: []u8,
    src_base: []const u8,
    field_dims: []const ir.Dimension,
    global_dims_len: usize,
    elem_bytes: usize,
) ![]const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..src_base.len], src_base);
    pos += src_base.len;

    var inner_product: usize = elem_bytes;
    var i: usize = field_dims.len;
    while (i > 0) {
        i -= 1;
        const idx = global_dims_len + i;
        const written = try std.fmt.bufPrint(buf[pos..], " + i{d} * {d}", .{ idx, inner_product });
        pos += written.len;
        inner_product *= field_dims[i].len;
    }
    return buf[0..pos];
}

/// Generate offset calculation string: "base + i0*s0 + i1*s1 + ..."
fn emitOffsetCalc(
    allocator: std.mem.Allocator,
    global_dims: []const ir.Dimension,
    field_dims: []const ir.Dimension,
    base_offset: u64,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    try aw.writer.print("{d}", .{base_offset});

    for (global_dims, 0..) |d, i| {
        if (d.stride_bytes > 0) {
            try aw.writer.print(" + i{d} * {d}", .{ i, d.stride_bytes });
        }
    }

    for (field_dims, 0..) |d, i| {
        if (d.stride_bytes > 0) {
            try aw.writer.print(" + i{d} * {d}", .{ global_dims.len + i, d.stride_bytes });
        }
    }

    return try aw.toOwnedSlice();
}

/// Emit file-scope domain tables for .values and .pointers fields.
/// These are used by both the sampler (to pick values) and the checker (to validate post-run).
fn emitDomainTables(io: std.Io, globals: []const Parser.Global, file: *std.Io.File) !void {
    var num_buf: [64]u8 = undefined;
    var bytes_buf: [64]u8 = undefined;
    var value_idx: usize = 0;
    var wval_idx: usize = 0;
    var ptr_idx: usize = 0;

    for (globals) |g| {
        for (g.fields) |f| {
            if (f.is_padding) continue;
            const bytes = (f.bit_width + 7) / 8;
            const bytes_str = try std.fmt.bufPrint(&bytes_buf, "{d}", .{bytes});

            switch (f.domain) {
                .top => {},
                .values => |vals| {
                    if (vals.len == 0) continue;
                    var label_buf: [64]u8 = undefined;
                    const label = try std.fmt.bufPrint(&label_buf, "FM_VAL_{d}", .{value_idx});
                    value_idx += 1;

                    try file.writeStreamingAll(io, "static const uint8_t ");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, "[] = { ");
                    for (vals, 0..) |v, vi| {
                        if (vi > 0) try file.writeStreamingAll(io, ", ");
                        for (0..bytes) |bi| {
                            if (bi > 0) try file.writeStreamingAll(io, ", ");
                            const byte_val: u8 = if (bi < v.len) v[bi] else 0;
                            const byte_str = try std.fmt.bufPrint(&num_buf, "0x{X:0>2}", .{byte_val});
                            try file.writeStreamingAll(io, byte_str);
                        }
                    }
                    try file.writeStreamingAll(io, " };\n");
                    const count_str = try std.fmt.bufPrint(&num_buf, "#define {s}_COUNT {d}\n", .{ label, vals.len });
                    try file.writeStreamingAll(io, count_str);
                    const bytes_def = try std.fmt.bufPrint(&num_buf, "#define {s}_BYTES {s}\n", .{ label, bytes_str });
                    try file.writeStreamingAll(io, bytes_def);
                },
                .whole_values => |vals| {
                    if (vals.len == 0) continue;
                    const blob_bytes = ir.wholeFieldBytes(f);
                    const blob_str = try std.fmt.bufPrint(&bytes_buf, "{d}", .{blob_bytes});
                    var label_buf: [64]u8 = undefined;
                    const label = try std.fmt.bufPrint(&label_buf, "FM_WVAL_{d}", .{wval_idx});
                    wval_idx += 1;

                    try file.writeStreamingAll(io, "static const uint8_t ");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, "[] = { ");
                    for (vals, 0..) |v, vi| {
                        if (vi > 0) try file.writeStreamingAll(io, ", ");
                        for (0..blob_bytes) |bi| {
                            if (bi > 0) try file.writeStreamingAll(io, ", ");
                            const byte_val: u8 = if (bi < v.len) v[bi] else 0;
                            const byte_str = try std.fmt.bufPrint(&num_buf, "0x{X:0>2}", .{byte_val});
                            try file.writeStreamingAll(io, byte_str);
                        }
                    }
                    try file.writeStreamingAll(io, " };\n");
                    const count_str = try std.fmt.bufPrint(&num_buf, "#define {s}_COUNT {d}\n", .{ label, vals.len });
                    try file.writeStreamingAll(io, count_str);
                    const bytes_def = try std.fmt.bufPrint(&num_buf, "#define {s}_BLOB_BYTES {s}\n", .{ label, blob_str });
                    try file.writeStreamingAll(io, bytes_def);
                },
                .pointers => |ptrs| {
                    if (ptrs.len == 0) continue;
                    var ptr_label_buf: [64]u8 = undefined;
                    const ptr_label = try std.fmt.bufPrint(&ptr_label_buf, "FM_PTR_{d}", .{ptr_idx});
                    ptr_idx += 1;

                    try file.writeStreamingAll(io, "static void *");
                    try file.writeStreamingAll(io, ptr_label);
                    try file.writeStreamingAll(io, "[] = { ");
                    for (ptrs, 0..) |p, pi| {
                        if (pi > 0) try file.writeStreamingAll(io, ", ");
                        try file.writeStreamingAll(io, "&");
                        try file.writeStreamingAll(io, p);
                    }
                    try file.writeStreamingAll(io, " };\n");
                    const count_str = try std.fmt.bufPrint(&num_buf, "#define {s}_COUNT {d}\n", .{ ptr_label, ptrs.len });
                    try file.writeStreamingAll(io, count_str);
                },
            }
        }
    }

    if (value_idx > 0 or wval_idx > 0 or ptr_idx > 0) try file.writeStreamingAll(io, "\n");
}

/// Generate the complete fuzzer C file and `objcopy` redefinition file.
/// Writes includes, extern/weak declarations, sampler, checker, and libFuzzer entrypoint.
pub fn writeFuzzerC(
    allocator: std.mem.Allocator,
    io: std.Io,
    globals: []const Parser.Global,
    needed_bytes: usize,
    out_path: []const u8,
    redef_path: []const u8,
    entry_name: []const u8,
    func_symbols: []const []const u8,
) !void {
    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer file.close(io);

    var redef_file = try std.Io.Dir.cwd().createFile(io, redef_path, .{ .truncate = true });
    defer redef_file.close(io);

    try file.writeStreamingAll(io,
        \\#include <assert.h>
        \\#include <stdint.h>
        \\#include <stddef.h>
        \\#include <string.h>
        \\#include <stdio.h>
        \\
    );

    const fwd_decl = try std.fmt.allocPrint(allocator, "int {s}(const uint8_t *data, size_t size);\n\n", .{entry_name});
    defer allocator.free(fwd_decl);
    try file.writeStreamingAll(io, fwd_decl);

    const globals_size_define = try std.fmt.allocPrint(allocator, "#define ABSOLUTION_GLOBALS_SIZE {d}\n\n", .{needed_bytes});
    defer allocator.free(globals_size_define);
    try file.writeStreamingAll(io, globals_size_define);

    for (func_symbols) |sym| {
        const func_decl = try std.fmt.allocPrint(allocator, "extern void {s}(void);\n", .{sym});
        defer allocator.free(func_decl);
        try file.writeStreamingAll(io, func_decl);
    }
    if (func_symbols.len > 0) try file.writeStreamingAll(io, "\n");

    for (globals) |g| {
        const mangled = if (g.is_static)
            try mangleName(allocator, g.source_file, g.name)
        else
            try allocator.dupe(u8, g.name);
        defer allocator.free(mangled);

        if (g.is_static) {
            const line = try std.fmt.allocPrint(allocator, "{s} {s} {s}\n", .{ g.source_file, g.name, mangled });
            defer allocator.free(line);
            try redef_file.writeStreamingAll(io, line);
        }

        const decl = try std.fmt.allocPrint(allocator, "uint8_t __attribute__((weak)) {s}[{d}];\n", .{ mangled, g.size_bytes });
        defer allocator.free(decl);
        try file.writeStreamingAll(io, decl);
    }

    try file.writeStreamingAll(io, "\n");

    try emitDomainTables(io, globals, &file);
    try emitSampler(allocator, io, globals, &file);
    try emitChecker(allocator, io, globals, &file);
    try emitEntrypoint(allocator, io, &file, entry_name);
}

/// Emit `sample_invariant()` — reads fuzzer input bytes and hydrates globals
/// according to their field domains (top, values, or pointers).
fn emitSampler(allocator: std.mem.Allocator, io: std.Io, globals: []const Parser.Global, file: *std.Io.File) !void {
    var num_buf: [64]u8 = undefined;
    var bytes_buf: [64]u8 = undefined;

    var value_idx: usize = 0;
    var wval_idx: usize = 0;
    var ptr_idx: usize = 0;
    try file.writeStreamingAll(io, "ptrdiff_t sample_invariant(const uint8_t *data, size_t size) {\n");
    try file.writeStreamingAll(io, "    size_t off = 0;\n");
    try file.writeStreamingAll(io, "    const size_t needed = ABSOLUTION_GLOBALS_SIZE ;\n");
    try file.writeStreamingAll(io, "    if (size < needed) return -1;\n");

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
        try emitMemset(io, file, 1, memset_dst, "0", memset_size);

        // Open global loops once per global.
        var loop_stack: LoopStack = .init(io, file, 1);
        for (g.dims, 0..) |d, i| {
            try loop_stack.openLoop(d, i);
        }

        for (g.fields) |f| {
            if (f.is_padding) continue;
            const bytes = (f.bit_width + 7) / 8;
            const bytes_str = try std.fmt.bufPrint(&bytes_buf, "{d}", .{bytes});

            const field_dims_len = f.dims.len;

            if (f.domain == .whole_values) {
                const vals = f.domain.whole_values;
                if (vals.len == 0) continue;

                const current_depth = loop_stack.depth();
                var label_buf: [64]u8 = undefined;
                const label = try std.fmt.bufPrint(&label_buf, "FM_WVAL_{d}", .{wval_idx});
                wval_idx += 1;

                if (vals.len > 1) {
                    try writeIndent(io, file, current_depth);
                    try file.writeStreamingAll(io, "size_t idx_");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, " = data[off] % ");
                    const count_str = try std.fmt.bufPrint(&num_buf, "{d}", .{vals.len});
                    try file.writeStreamingAll(io, count_str);
                    try file.writeStreamingAll(io, ";\n");
                }

                if (ir.isWholeFieldDense(f)) {
                    const offset_expr = try emitOffsetCalc(allocator, g.dims, &.{}, @intCast(f.offset_bits / 8));
                    defer allocator.free(offset_expr);
                    const dst_expr = try std.fmt.allocPrint(allocator, "&{s}[{s}]", .{ mangled, offset_expr });
                    defer allocator.free(dst_expr);
                    const blob_str = try std.fmt.bufPrint(&bytes_buf, "{d}", .{ir.wholeFieldBytes(f)});

                    if (vals.len > 1) {
                        var src_buf: [256]u8 = undefined;
                        const src = try std.fmt.bufPrint(&src_buf, "&{s}[idx_{s} * {s}_BLOB_BYTES]", .{ label, label, label });
                        try emitMemcpy(io, file, current_depth, dst_expr, src, blob_str);
                    } else {
                        var src_buf: [256]u8 = undefined;
                        const src = try std.fmt.bufPrint(&src_buf, "&{s}[0]", .{label});
                        try emitMemcpy(io, file, current_depth, dst_expr, src, blob_str);
                    }
                } else {
                    const src_base = if (vals.len > 1)
                        try std.fmt.allocPrint(allocator, "idx_{s} * {s}_BLOB_BYTES", .{ label, label })
                    else
                        try std.fmt.allocPrint(allocator, "0", .{});
                    defer allocator.free(src_base);

                    for (f.dims, 0..) |d, fi| {
                        const i = global_dims_len + fi;
                        try loop_stack.openLoop(d, i);
                    }
                    const inner_depth = loop_stack.depth();

                    const offset_expr = try emitOffsetCalc(allocator, g.dims, f.dims, @intCast(f.offset_bits / 8));
                    defer allocator.free(offset_expr);
                    const dst_expr = try std.fmt.allocPrint(allocator, "&{s}[{s}]", .{ mangled, offset_expr });
                    defer allocator.free(dst_expr);

                    var blob_off_buf: [256]u8 = undefined;
                    const elem_bytes = ir.elementBytes(f);
                    const blob_off_expr = try emitBlobOffsetExpr(&blob_off_buf, src_base, f.dims, global_dims_len, elem_bytes);
                    var src_buf: [256]u8 = undefined;
                    const src = try std.fmt.bufPrint(&src_buf, "&{s}[{s}]", .{ label, blob_off_expr });

                    const eb_str = try std.fmt.bufPrint(&bytes_buf, "{d}", .{elem_bytes});
                    try emitMemcpy(io, file, inner_depth, dst_expr, src, eb_str);

                    try loop_stack.closeLoops(field_dims_len);
                }

                if (vals.len > 1) {
                    try incrementOffset(io, file, current_depth, "1");
                }
                continue;
            }

            // Open field loops (if any) inside the global loops.
            for (f.dims, 0..) |d, fi| {
                const i = global_dims_len + fi;
                try loop_stack.openLoop(d, i);
            }

            // Construct offset expression
            const offset_expr = try emitOffsetCalc(allocator, g.dims, f.dims, @intCast(f.offset_bits / 8) // Byte offset
            );
            defer allocator.free(offset_expr);

            const dst_expr = try std.fmt.allocPrint(allocator, "&{s}[{s}]", .{ mangled, offset_expr });
            defer allocator.free(dst_expr);

            const current_depth = loop_stack.depth();
            switch (f.domain) {
                .top => {
                    try emitMemcpy(io, file, current_depth, dst_expr, "&data[off]", bytes_str);
                    try incrementOffset(io, file, current_depth, bytes_str);
                },
                .values => |vals| {
                    if (vals.len == 0) {
                        try loop_stack.closeLoops(field_dims_len);
                        continue;
                    }
                    var label_buf: [64]u8 = undefined;
                    const label = try std.fmt.bufPrint(&label_buf, "FM_VAL_{d}", .{value_idx});
                    value_idx += 1;

                    if (vals.len > 1) {
                        try writeIndent(io, file, current_depth);
                        try file.writeStreamingAll(io, "size_t idx_");
                        try file.writeStreamingAll(io, label);
                        try file.writeStreamingAll(io, " = data[off] % ");
                        const count_str = try std.fmt.bufPrint(&num_buf, "{d}", .{vals.len});
                        try file.writeStreamingAll(io, count_str);
                        try file.writeStreamingAll(io, ";\n");

                        var src_buf: [256]u8 = undefined;
                        const src = try std.fmt.bufPrint(&src_buf, "&{s}[idx_{s} * {s}]", .{ label, label, bytes_str });
                        try emitMemcpy(io, file, current_depth, dst_expr, src, bytes_str);
                        try incrementOffset(io, file, current_depth, "1");
                    } else {
                        var src_buf: [256]u8 = undefined;
                        const src = try std.fmt.bufPrint(&src_buf, "&{s}[0]", .{label});
                        try emitMemcpy(io, file, current_depth, dst_expr, src, bytes_str);
                    }
                },
                .whole_values => unreachable,
                .pointers => |ptrs| {
                    if (ptrs.len == 0) {
                        try loop_stack.closeLoops(field_dims_len);
                        continue;
                    }
                    var ptr_label_buf: [64]u8 = undefined;
                    const ptr_label = try std.fmt.bufPrint(&ptr_label_buf, "FM_PTR_{d}", .{ptr_idx});
                    ptr_idx += 1;

                    if (ptrs.len > 1) {
                        try writeIndent(io, file, current_depth);
                        try file.writeStreamingAll(io, "size_t idx_");
                        try file.writeStreamingAll(io, ptr_label);
                        try file.writeStreamingAll(io, " = data[off] % ");
                        const count_str = try std.fmt.bufPrint(&num_buf, "{d}", .{ptrs.len});
                        try file.writeStreamingAll(io, count_str);
                        try file.writeStreamingAll(io, ";\n");

                        var src_buf: [128]u8 = undefined;
                        const src = try std.fmt.bufPrint(&src_buf, "&{s}[idx_{s}]", .{ ptr_label, ptr_label });
                        try emitMemcpy(io, file, current_depth, dst_expr, src, bytes_str);
                        try incrementOffset(io, file, current_depth, "1");
                    } else {
                        var src_buf: [128]u8 = undefined;
                        const src = try std.fmt.bufPrint(&src_buf, "&{s}[0]", .{ptr_label});
                        try emitMemcpy(io, file, current_depth, dst_expr, src, bytes_str);
                    }
                },
            }

            // Close only field loops.
            try loop_stack.closeLoops(field_dims_len);
        }

        // Close global loops.
        try loop_stack.closeLoops(global_dims_len);
    }

    try file.writeStreamingAll(io, "    return off;\n}\n\n");
}

/// Emit the checker that enforces invariants: padding zeroed, and constrained
/// domains (.values, .pointers) still valid after the harness run.
fn emitChecker(allocator: std.mem.Allocator, io: std.Io, globals: []const Parser.Global, file: *std.Io.File) !void {
    var bytes_buf: [64]u8 = undefined;
    var value_idx: usize = 0;
    var wval_idx: usize = 0;
    var ptr_idx: usize = 0;

    try file.writeStreamingAll(io, "int check_invariant(void) {\n");

    for (globals) |g| {
        const global_dims_len = g.dims.len;

        const mangled = if (g.is_static)
            try mangleName(allocator, g.source_file, g.name)
        else
            try allocator.dupe(u8, g.name);
        defer allocator.free(mangled);

        // Open global loops once per global.
        var loop_stack: LoopStack = .init(io, file, 1);
        for (g.dims, 0..) |d, i| {
            try loop_stack.openLoop(d, i);
        }

        for (g.fields) |f| {
            const bytes = (f.bit_width + 7) / 8;
            const bytes_str = try std.fmt.bufPrint(&bytes_buf, "{d}", .{bytes});
            const field_dims_len = f.dims.len;

            // Skip byte-unaligned regions (bitfields can produce these).
            if (f.offset_bits % 8 != 0) continue;

            if (f.is_padding) {
                for (f.dims, 0..) |d, fi| {
                    const i = global_dims_len + fi;
                    try loop_stack.openLoop(d, i);
                }
                const current_depth = loop_stack.depth();
                const offset_expr = try emitOffsetCalc(allocator, g.dims, f.dims, @intCast(f.offset_bits / 8));
                defer allocator.free(offset_expr);

                try writeIndent(io, file, current_depth);
                try file.writeStreamingAll(io, "for (size_t i = 0; i < ");
                try file.writeStreamingAll(io, bytes_str);
                try file.writeStreamingAll(io, "; i++) {\n");
                try writeIndent(io, file, current_depth + 1);
                try file.writeStreamingAll(io, "if (");
                try file.writeStreamingAll(io, mangled);
                try file.writeStreamingAll(io, "[");
                try file.writeStreamingAll(io, offset_expr);
                try file.writeStreamingAll(io, " + i] != 0) return -1;\n");
                try writeIndent(io, file, current_depth);
                try file.writeStreamingAll(io, "}\n");

                try loop_stack.closeLoops(field_dims_len);
                continue;
            }

            if (f.domain == .whole_values) {
                const vals = f.domain.whole_values;
                if (vals.len == 0) continue;

                const current_depth = loop_stack.depth();

                var label_buf: [64]u8 = undefined;
                const label = try std.fmt.bufPrint(&label_buf, "FM_WVAL_{d}", .{wval_idx});
                wval_idx += 1;

                if (ir.isWholeFieldDense(f)) {
                    const offset_expr = try emitOffsetCalc(allocator, g.dims, &.{}, @intCast(f.offset_bits / 8));
                    defer allocator.free(offset_expr);

                    try writeIndent(io, file, current_depth);
                    try file.writeStreamingAll(io, "{\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "int found = 0;\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "for (size_t vi = 0; vi < ");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, "_COUNT; vi++) {\n");
                    try writeIndent(io, file, current_depth + 2);
                    try file.writeStreamingAll(io, "if (memcmp(&");
                    try file.writeStreamingAll(io, mangled);
                    try file.writeStreamingAll(io, "[");
                    try file.writeStreamingAll(io, offset_expr);
                    try file.writeStreamingAll(io, "], &");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, "[vi * ");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, "_BLOB_BYTES], ");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, "_BLOB_BYTES) == 0) { found = 1; break; }\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "}\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "if (!found) return -1;\n");
                    try writeIndent(io, file, current_depth);
                    try file.writeStreamingAll(io, "}\n");
                } else {
                    const blob_bytes = ir.wholeFieldBytes(f);
                    const blob_str = try std.fmt.bufPrint(&bytes_buf, "{d}", .{blob_bytes});
                    const elem_bytes = ir.elementBytes(f);

                    try writeIndent(io, file, current_depth);
                    try file.writeStreamingAll(io, "{\n");

                    // Declare a local buffer and gather strided elements into it.
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "uint8_t wvbuf[");
                    try file.writeStreamingAll(io, blob_str);
                    try file.writeStreamingAll(io, "];\n");

                    for (f.dims, 0..) |d, fi| {
                        const i = global_dims_len + fi;
                        try loop_stack.openLoop(d, i);
                    }
                    const gather_depth = loop_stack.depth();

                    const offset_expr = try emitOffsetCalc(allocator, g.dims, f.dims, @intCast(f.offset_bits / 8));
                    defer allocator.free(offset_expr);
                    const src_expr = try std.fmt.allocPrint(allocator, "&{s}[{s}]", .{ mangled, offset_expr });
                    defer allocator.free(src_expr);

                    var blob_off_buf: [256]u8 = undefined;
                    const blob_off_expr = try emitBlobOffsetExpr(&blob_off_buf, "0", f.dims, global_dims_len, elem_bytes);
                    var dst_buf: [256]u8 = undefined;
                    const dst_expr = try std.fmt.bufPrint(&dst_buf, "&wvbuf[{s}]", .{blob_off_expr});

                    var eb_buf: [64]u8 = undefined;
                    const eb_str_2 = try std.fmt.bufPrint(&eb_buf, "{d}", .{elem_bytes});
                    try emitMemcpy(io, file, gather_depth, dst_expr, src_expr, eb_str_2);

                    try loop_stack.closeLoops(field_dims_len);

                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "int found = 0;\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "for (size_t vi = 0; vi < ");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, "_COUNT; vi++) {\n");
                    try writeIndent(io, file, current_depth + 2);
                    try file.writeStreamingAll(io, "if (memcmp(wvbuf, &");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, "[vi * ");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, "_BLOB_BYTES], ");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, "_BLOB_BYTES) == 0) { found = 1; break; }\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "}\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "if (!found) return -1;\n");
                    try writeIndent(io, file, current_depth);
                    try file.writeStreamingAll(io, "}\n");
                }
                continue;
            }

            // Open field loops (if any) inside the global loops.
            for (f.dims, 0..) |d, fi| {
                const i = global_dims_len + fi;
                try loop_stack.openLoop(d, i);
            }

            const current_depth = loop_stack.depth();
            const offset_expr = try emitOffsetCalc(allocator, g.dims, f.dims, @intCast(f.offset_bits / 8));
            defer allocator.free(offset_expr);

            switch (f.domain) {
                .top => {},
                .whole_values => unreachable,
                .values => |vals| {
                    if (vals.len == 0) {
                        try loop_stack.closeLoops(field_dims_len);
                        continue;
                    }
                    var label_buf: [64]u8 = undefined;
                    const label = try std.fmt.bufPrint(&label_buf, "FM_VAL_{d}", .{value_idx});
                    value_idx += 1;

                    try writeIndent(io, file, current_depth);
                    try file.writeStreamingAll(io, "{\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "int found = 0;\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "for (size_t vi = 0; vi < ");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, "_COUNT; vi++) {\n");
                    try writeIndent(io, file, current_depth + 2);
                    try file.writeStreamingAll(io, "if (memcmp(&");
                    try file.writeStreamingAll(io, mangled);
                    try file.writeStreamingAll(io, "[");
                    try file.writeStreamingAll(io, offset_expr);
                    try file.writeStreamingAll(io, "], &");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, "[vi * ");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, "_BYTES], ");
                    try file.writeStreamingAll(io, label);
                    try file.writeStreamingAll(io, "_BYTES) == 0) { found = 1; break; }\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "}\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "if (!found) return -1;\n");
                    try writeIndent(io, file, current_depth);
                    try file.writeStreamingAll(io, "}\n");
                },
                .pointers => |ptrs| {
                    if (ptrs.len == 0) {
                        try loop_stack.closeLoops(field_dims_len);
                        continue;
                    }
                    var ptr_label_buf: [64]u8 = undefined;
                    const ptr_label = try std.fmt.bufPrint(&ptr_label_buf, "FM_PTR_{d}", .{ptr_idx});
                    ptr_idx += 1;

                    try writeIndent(io, file, current_depth);
                    try file.writeStreamingAll(io, "{\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "void *current;\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "memcpy(&current, &");
                    try file.writeStreamingAll(io, mangled);
                    try file.writeStreamingAll(io, "[");
                    try file.writeStreamingAll(io, offset_expr);
                    try file.writeStreamingAll(io, "], sizeof(void *));\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "int found = 0;\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "for (size_t pi = 0; pi < ");
                    try file.writeStreamingAll(io, ptr_label);
                    try file.writeStreamingAll(io, "_COUNT; pi++) {\n");
                    try writeIndent(io, file, current_depth + 2);
                    try file.writeStreamingAll(io, "if (current == ");
                    try file.writeStreamingAll(io, ptr_label);
                    try file.writeStreamingAll(io, "[pi]) { found = 1; break; }\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "}\n");
                    try writeIndent(io, file, current_depth + 1);
                    try file.writeStreamingAll(io, "if (!found) return -1;\n");
                    try writeIndent(io, file, current_depth);
                    try file.writeStreamingAll(io, "}\n");
                },
            }

            // Close field loops.
            try loop_stack.closeLoops(field_dims_len);
        }

        // Close global loops.
        try loop_stack.closeLoops(global_dims_len);
    }

    try file.writeStreamingAll(io, "    return 0;\n");
    try file.writeStreamingAll(io, "}\n\n");
}

/// Emit the libFuzzer entrypoint that wires sampling, harness, and checks.
fn emitEntrypoint(allocator: std.mem.Allocator, io: std.Io, file: *std.Io.File, entry_name: []const u8) !void {
    try file.writeStreamingAll(io,
        \\int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
        \\    ptrdiff_t consumed = sample_invariant(data, size);
        \\    if (consumed < 0) return 0;
        \\    data += (size_t)consumed;
        \\    size -= (size_t)consumed;
        \\
    );

    const call_line = try std.fmt.allocPrint(allocator, "    int res = {s}(data, size);\n", .{entry_name});
    defer allocator.free(call_line);
    try file.writeStreamingAll(io, call_line);

    try file.writeStreamingAll(io,
        \\    if (res == -1) return 0;
        \\    assert(check_invariant() == 0);
        \\    return 0;
        \\}
    );
}

fn readTmpFile(tmp: *std.testing.TmpDir, name: []const u8, buf: []u8) ![]const u8 {
    const tio = std.testing.io;
    var f = try tmp.dir.openFile(tio, name, .{});
    defer f.close(tio);
    const n = try f.readPositionalAll(tio, buf, 0);
    return buf[0..n];
}

fn createTmpFile(tmp: *std.testing.TmpDir, name: []const u8) !std.Io.File {
    const tio = std.testing.io;
    return try tmp.dir.createFile(tio, name, .{ .read = true });
}

// ---------------------------------------------------------------------------
// Pure-helper tests
// ---------------------------------------------------------------------------

test "mangleName sanitizes path and joins with symbol" {
    const alloc = std.testing.allocator;
    const result = try mangleName(alloc, "foo/bar.c", "var");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("foo_bar_c_var", result);
}

test "mangleName handles empty path" {
    const alloc = std.testing.allocator;
    const result = try mangleName(alloc, "", "sym");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("_sym", result);
}

test "emitOffsetCalc base offset only" {
    const alloc = std.testing.allocator;
    const result = try emitOffsetCalc(alloc, &.{}, &.{}, 42);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("42", result);
}

test "emitOffsetCalc with global and field dims" {
    const alloc = std.testing.allocator;
    const gdims: []const ir.Dimension = &.{.{ .len = 3, .stride_bytes = 8 }};
    const fdims: []const ir.Dimension = &.{.{ .len = 4, .stride_bytes = 2 }};
    const result = try emitOffsetCalc(alloc, gdims, fdims, 10);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("10 + i0 * 8 + i1 * 2", result);
}

test "emitOffsetCalc skips zero-stride dims" {
    const alloc = std.testing.allocator;
    const gdims: []const ir.Dimension = &.{.{ .len = 3, .stride_bytes = 0 }};
    const result = try emitOffsetCalc(alloc, gdims, &.{}, 5);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("5", result);
}

test "writeIndent outputs correct spaces" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    try writeIndent(io, &file, 2);
    try file.writeStreamingAll(io, "x");
    var buf: [64]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expectEqualStrings("        x", out);
}

test "emitMemset generates correct output" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    try emitMemset(io, &file, 1, "dst", "0", "sizeof(x)");
    var buf: [256]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expectEqualStrings("    memset(dst, 0, sizeof(x));\n", out);
}

test "emitMemcpy generates correct output" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    try emitMemcpy(io, &file, 0, "a", "b", "4");
    var buf: [256]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expectEqualStrings("memcpy(a, b, 4);\n", out);
}

test "incrementOffset generates correct output" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    try incrementOffset(io, &file, 1, "8");
    var buf: [256]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expectEqualStrings("    off += 8;\n", out);
}

test "LoopStack open and close loops" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    var ls = LoopStack.init(io, &file, 1);
    try std.testing.expectEqual(@as(usize, 1), ls.depth());
    try ls.openLoop(.{ .len = 3, .stride_bytes = 4 }, 0);
    try std.testing.expectEqual(@as(usize, 2), ls.depth());
    try ls.closeLoops(1);
    try std.testing.expectEqual(@as(usize, 1), ls.depth());
    var buf: [512]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "for (size_t i0 = 0; i0 < 3; i0++)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "}") != null);
}

// ---------------------------------------------------------------------------
// Generator tests
// ---------------------------------------------------------------------------

test "emitDomainTables with .values field" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".x",
        .bit_width = 8,
        .is_padding = false,
        .domain = .{ .values = &.{ &[_]u8{0xAA}, &[_]u8{0xBB} } },
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 1,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitDomainTables(io, globals, &file);
    var buf: [2048]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_VAL_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0xAA") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_VAL_0_COUNT 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_VAL_0_BYTES 1") != null);
}

test "emitDomainTables with .whole_values field" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".b",
        .bit_width = 8,
        .is_padding = false,
        .dims = &.{.{ .len = 4, .stride_bytes = 1 }},
        .domain = .{ .whole_values = &.{ &[_]u8{ 1, 2, 3, 4 }, &[_]u8{ 5, 6, 7, 8 } } },
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "pkt",
        .source_file = "",
        .size_bytes = 4,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitDomainTables(io, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_WVAL_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_WVAL_0_COUNT 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_WVAL_0_BLOB_BYTES 4") != null);
}

test "emitDomainTables with .pointers field" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".fp",
        .bit_width = 64,
        .is_padding = false,
        .domain = .{ .pointers = &.{"handler_a"} },
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 8,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitDomainTables(io, globals, &file);
    var buf: [2048]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_PTR_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "&handler_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_PTR_0_COUNT 1") != null);
}

test "emitDomainTables skips padding fields" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".pad0",
        .bit_width = 8,
        .is_padding = true,
        .domain = .top,
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 1,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitDomainTables(io, globals, &file);
    var buf: [256]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "emitSampler generates sample_invariant for .top field" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".x",
        .bit_width = 32,
        .is_padding = false,
        .domain = .top,
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 4,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitSampler(alloc, io, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "sample_invariant") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "memset(g, 0, sizeof(g))") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcpy(&g[0], &data[off], 4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "off += 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return off;") != null);
}

test "emitSampler with .values domain" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".x",
        .bit_width = 8,
        .is_padding = false,
        .domain = .{ .values = &.{ &[_]u8{0}, &[_]u8{1} } },
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 1,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitSampler(alloc, io, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "idx_FM_VAL_0 = data[off] % 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "off += 1") != null);
}

test "emitSampler with .whole_values multi-candidate" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".b",
        .bit_width = 8,
        .is_padding = false,
        .dims = &.{.{ .len = 4, .stride_bytes = 1 }},
        .domain = .{ .whole_values = &.{ &[_]u8{ 1, 2, 3, 4 }, &[_]u8{ 5, 6, 7, 8 } } },
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "pkt",
        .source_file = "",
        .size_bytes = 4,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitSampler(alloc, io, globals, &file);
    var buf: [8192]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "idx_FM_WVAL_0 = data[off] % 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_WVAL_0_BLOB_BYTES") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcpy(&pkt[0], &FM_WVAL_0[idx_FM_WVAL_0 * FM_WVAL_0_BLOB_BYTES], 4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "off += 1") != null);
    // Whole-field path: no per-element field loops for this domain
    try std.testing.expect(std.mem.indexOf(u8, out, "for (size_t i1 = 0;") == null);
}

test "emitSampler with .whole_values singleton uses no selector byte" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".b",
        .bit_width = 8,
        .is_padding = false,
        .dims = &.{.{ .len = 2, .stride_bytes = 1 }},
        .domain = .{ .whole_values = &.{&[_]u8{ 0xAA, 0xBB }} },
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "pkt",
        .source_file = "",
        .size_bytes = 2,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitSampler(alloc, io, globals, &file);
    var buf: [8192]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "&FM_WVAL_0[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "idx_FM_WVAL_0") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "off += 1") == null);
}

test "emitSampler with strided .whole_values scatters elements" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".items.b",
        .bit_width = 8,
        .is_padding = false,
        .dims = &.{.{ .len = 4, .stride_bytes = 4 }},
        .domain = .{ .whole_values = &.{ &[_]u8{ 0x10, 0x20, 0x30, 0x40 }, &[_]u8{ 0xa0, 0xb0, 0xc0, 0xd0 } } },
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "pkt",
        .source_file = "",
        .size_bytes = 16,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitSampler(alloc, io, globals, &file);
    var buf: [8192]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "idx_FM_WVAL_0 = data[off] % 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "for (size_t i0 = 0; i0 < 4; i0++)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcpy(&pkt[0 + i0 * 4], &FM_WVAL_0[idx_FM_WVAL_0 * FM_WVAL_0_BLOB_BYTES + i0 * 1], 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "off += 1") != null);
}

test "emitSampler with strided .whole_values singleton scatters without selector" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".items.b",
        .bit_width = 8,
        .is_padding = false,
        .dims = &.{.{ .len = 4, .stride_bytes = 4 }},
        .domain = .{ .whole_values = &.{&[_]u8{ 0x10, 0x20, 0x30, 0x40 }} },
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "pkt",
        .source_file = "",
        .size_bytes = 16,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitSampler(alloc, io, globals, &file);
    var buf: [8192]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "for (size_t i0 = 0; i0 < 4; i0++)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcpy(&pkt[0 + i0 * 4], &FM_WVAL_0[0 + i0 * 1], 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "idx_FM_WVAL_0") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "off += 1") == null);
}

test "emitSampler with .pointers domain" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".fp",
        .bit_width = 64,
        .is_padding = false,
        .domain = .{ .pointers = &.{"handler_a"} },
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 8,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitSampler(alloc, io, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "&FM_PTR_0[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "idx_FM_PTR_0") == null);
}

test "emitSampler skips padding fields" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".pad0",
        .bit_width = 24,
        .is_padding = true,
        .domain = .top,
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 4,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitSampler(alloc, io, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcpy") == null);
}

test "emitSampler with static global uses mangled name" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".x",
        .bit_width = 8,
        .is_padding = false,
        .domain = .top,
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "var",
        .source_file = "src/a.c",
        .size_bytes = 1,
        .is_static = true,
        .dims = &.{},
        .fields = fields,
    }};
    try emitSampler(alloc, io, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "src_a_c_var") != null);
}

test "emitChecker generates padding zero-check" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".pad0",
        .offset_bits = 8,
        .bit_width = 24,
        .is_padding = true,
        .domain = .top,
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 4,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitChecker(alloc, io, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "check_invariant") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "!= 0) return -1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return 0;") != null);
}

test "emitChecker generates .whole_values validation" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".b",
        .bit_width = 8,
        .is_padding = false,
        .dims = &.{.{ .len = 4, .stride_bytes = 1 }},
        .domain = .{ .whole_values = &.{ &[_]u8{ 1, 2, 3, 4 }, &[_]u8{ 5, 6, 7, 8 } } },
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "pkt",
        .source_file = "",
        .size_bytes = 4,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitChecker(alloc, io, globals, &file);
    var buf: [8192]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_WVAL_0_COUNT") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_WVAL_0_BLOB_BYTES") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcmp(&pkt[0], &FM_WVAL_0[vi * FM_WVAL_0_BLOB_BYTES], FM_WVAL_0_BLOB_BYTES)") != null);
}

test "emitChecker generates strided .whole_values gather-then-compare" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".items.b",
        .bit_width = 8,
        .is_padding = false,
        .dims = &.{.{ .len = 4, .stride_bytes = 4 }},
        .domain = .{ .whole_values = &.{ &[_]u8{ 0x10, 0x20, 0x30, 0x40 }, &[_]u8{ 0xa0, 0xb0, 0xc0, 0xd0 } } },
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "pkt",
        .source_file = "",
        .size_bytes = 16,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitChecker(alloc, io, globals, &file);
    var buf: [8192]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "uint8_t wvbuf[4]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "for (size_t i0 = 0; i0 < 4; i0++)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcpy(&wvbuf[0 + i0 * 1], &pkt[0 + i0 * 4], 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcmp(wvbuf, &FM_WVAL_0[vi * FM_WVAL_0_BLOB_BYTES], FM_WVAL_0_BLOB_BYTES)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "if (!found) return -1") != null);
}

test "emitChecker generates .values validation" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".x",
        .bit_width = 8,
        .is_padding = false,
        .domain = .{ .values = &.{ &[_]u8{0}, &[_]u8{1} } },
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 1,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitChecker(alloc, io, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_VAL_0_COUNT") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "if (!found) return -1") != null);
}

test "emitChecker generates .pointers validation" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".fp",
        .bit_width = 64,
        .is_padding = false,
        .domain = .{ .pointers = &.{"handler_a"} },
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 8,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitChecker(alloc, io, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_PTR_0_COUNT") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "void *current") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "if (!found) return -1") != null);
}

test "emitChecker skips unaligned bitfield offsets" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".bf",
        .offset_bits = 3,
        .bit_width = 5,
        .is_padding = false,
        .domain = .top,
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 1,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};
    try emitChecker(alloc, io, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcpy") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcmp") == null);
}

test "emitEntrypoint generates LLVMFuzzerTestOneInput" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    try emitEntrypoint(alloc, io, &file, "MyHarness");
    var buf: [2048]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "LLVMFuzzerTestOneInput") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sample_invariant") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "MyHarness(data, size)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "check_invariant()") != null);
}

test "writeFuzzerC end-to-end produces valid output" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);
    const out_path = try std.fs.path.join(alloc, &.{ dir_path, "fuzzer.c" });
    defer alloc.free(out_path);
    const redef_path = try std.fs.path.join(alloc, &.{ dir_path, "fuzzer.redef" });
    defer alloc.free(redef_path);

    const fields: []Parser.Field = @constCast(&[_]Parser.Field{
        .{
            .name = ".x",
            .bit_width = 32,
            .is_padding = false,
            .domain = .top,
        },
        .{
            .name = ".pad0",
            .offset_bits = 32,
            .bit_width = 32,
            .is_padding = true,
            .domain = .top,
        },
    });
    const globals: []const Parser.Global = &.{.{
        .name = "g",
        .source_file = "",
        .size_bytes = 8,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    }};

    try writeFuzzerC(alloc, io, globals, 4, out_path, redef_path, "TestHarness", &.{});

    var buf: [16384]u8 = undefined;
    const out = try readTmpFile(&tmp, "fuzzer.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "#include <assert.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "int TestHarness(const uint8_t *data, size_t size)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "#define ABSOLUTION_GLOBALS_SIZE 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "uint8_t __attribute__((weak)) g[8]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sample_invariant") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "check_invariant") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "LLVMFuzzerTestOneInput") != null);
}

test "writeFuzzerC with static global writes redef file" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);
    const out_path = try std.fs.path.join(alloc, &.{ dir_path, "fuzzer2.c" });
    defer alloc.free(out_path);
    const redef_path = try std.fs.path.join(alloc, &.{ dir_path, "fuzzer2.redef" });
    defer alloc.free(redef_path);

    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".x",
        .bit_width = 8,
        .is_padding = false,
        .domain = .top,
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "cfg",
        .source_file = "src/mod.c",
        .size_bytes = 1,
        .is_static = true,
        .dims = &.{},
        .fields = fields,
    }};

    try writeFuzzerC(alloc, io, globals, 1, out_path, redef_path, "TestEntry", &.{});

    var buf: [4096]u8 = undefined;
    const redef_out = try readTmpFile(&tmp, "fuzzer2.redef", &buf);
    try std.testing.expect(std.mem.indexOf(u8, redef_out, "src/mod.c cfg src_mod_c_cfg") != null);

    var buf2: [16384]u8 = undefined;
    const c_out = try readTmpFile(&tmp, "fuzzer2.c", &buf2);
    try std.testing.expect(std.mem.indexOf(u8, c_out, "src_mod_c_cfg") != null);
}

test "writeFuzzerC with func_symbols emits extern declarations" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);
    const out_path = try std.fs.path.join(alloc, &.{ dir_path, "fuzzer3.c" });
    defer alloc.free(out_path);
    const redef_path = try std.fs.path.join(alloc, &.{ dir_path, "fuzzer3.redef" });
    defer alloc.free(redef_path);

    const globals: []const Parser.Global = &.{};
    try writeFuzzerC(alloc, io, globals, 0, out_path, redef_path, "Entry", &.{"my_handler"});

    var buf: [8192]u8 = undefined;
    const c_out = try readTmpFile(&tmp, "fuzzer3.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, c_out, "extern void my_handler(void)") != null);
}

test "emitSampler with global array dims opens loops" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".x",
        .bit_width = 8,
        .is_padding = false,
        .domain = .top,
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "arr",
        .source_file = "",
        .size_bytes = 30,
        .is_static = false,
        .dims = &.{.{ .len = 10, .stride_bytes = 3 }},
        .fields = fields,
    }};
    try emitSampler(alloc, io, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "for (size_t i0 = 0; i0 < 10; i0++)") != null);
}

test "emitChecker with global array dims opens loops" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close(io);
    const fields: []Parser.Field = @constCast(&[_]Parser.Field{.{
        .name = ".x",
        .bit_width = 8,
        .is_padding = true,
        .domain = .top,
    }});
    const globals: []const Parser.Global = &.{.{
        .name = "arr",
        .source_file = "",
        .size_bytes = 30,
        .is_static = false,
        .dims = &.{.{ .len = 10, .stride_bytes = 3 }},
        .fields = fields,
    }};
    try emitChecker(alloc, io, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "for (size_t i0 = 0; i0 < 10; i0++)") != null);
}
