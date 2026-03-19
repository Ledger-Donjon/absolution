const std = @import("std");
const Parser = @import("../Parser.zig");
const ir = @import("ir.zig");

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
    fn openLoop(self: *LoopStack, dim: ir.Dimension, index: usize) !void {
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
    global_dims: []const ir.Dimension,
    field_dims: []const ir.Dimension,
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

/// Emit file-scope domain tables for .values and .pointers fields.
/// These are used by both the sampler (to pick values) and the checker (to validate post-run).
fn emitDomainTables(globals: []const Parser.Global, file: *std.fs.File) !void {
    var num_buf: [64]u8 = undefined;
    var bytes_buf: [64]u8 = undefined;
    var value_idx: usize = 0;
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

                    try file.writeAll("static const uint8_t ");
                    try file.writeAll(label);
                    try file.writeAll("[] = { ");
                    for (vals, 0..) |v, vi| {
                        if (vi > 0) try file.writeAll(", ");
                        for (0..bytes) |bi| {
                            if (bi > 0) try file.writeAll(", ");
                            const byte_val: u8 = if (bi < v.len) v[bi] else 0;
                            const byte_str = try std.fmt.bufPrint(&num_buf, "0x{X:0>2}", .{byte_val});
                            try file.writeAll(byte_str);
                        }
                    }
                    try file.writeAll(" };\n");
                    const count_str = try std.fmt.bufPrint(&num_buf, "#define {s}_COUNT {d}\n", .{ label, vals.len });
                    try file.writeAll(count_str);
                    const bytes_def = try std.fmt.bufPrint(&num_buf, "#define {s}_BYTES {s}\n", .{ label, bytes_str });
                    try file.writeAll(bytes_def);
                },
                .pointers => |ptrs| {
                    if (ptrs.len == 0) continue;
                    var ptr_label_buf: [64]u8 = undefined;
                    const ptr_label = try std.fmt.bufPrint(&ptr_label_buf, "FM_PTR_{d}", .{ptr_idx});
                    ptr_idx += 1;

                    try file.writeAll("static void *");
                    try file.writeAll(ptr_label);
                    try file.writeAll("[] = { ");
                    for (ptrs, 0..) |p, pi| {
                        if (pi > 0) try file.writeAll(", ");
                        try file.writeAll("&");
                        try file.writeAll(p);
                    }
                    try file.writeAll(" };\n");
                    const count_str = try std.fmt.bufPrint(&num_buf, "#define {s}_COUNT {d}\n", .{ ptr_label, ptrs.len });
                    try file.writeAll(count_str);
                },
            }
        }
    }

    if (value_idx > 0 or ptr_idx > 0) try file.writeAll("\n");
}

/// Generate the complete fuzzer C file and `objcopy` redefinition file.
/// Writes includes, extern/weak declarations, sampler, checker, and libFuzzer entrypoint.
pub fn writeFuzzerC(
    allocator: std.mem.Allocator,
    globals: []const Parser.Global,
    needed_bytes: usize,
    out_path: []const u8,
    redef_path: []const u8,
    entry_name: []const u8,
    func_symbols: []const []const u8,
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

    // Expose the total global-state byte count so custom mutators know
    // where the APDU payload begins in the flat fuzzer input.
    const globals_size_define = try std.fmt.allocPrint(allocator, "#define ABSOLUTION_GLOBALS_SIZE {d}\n\n", .{needed_bytes});
    defer allocator.free(globals_size_define);
    try file.writeAll(globals_size_define);

    for (func_symbols) |sym| {
        const func_decl = try std.fmt.allocPrint(allocator, "extern void {s}(void);\n", .{sym});
        defer allocator.free(func_decl);
        try file.writeAll(func_decl);
    }
    if (func_symbols.len > 0) try file.writeAll("\n");

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
        // Note: using weak attribute instead of extern to allow the use of optimization flags like
        // -O1/2/3/z that would remove some statement always passed by value and not reference
        const decl = try std.fmt.allocPrint(allocator, "uint8_t __attribute__((weak)) {s}[{d}];\n", .{ mangled, g.size_bytes });
        defer allocator.free(decl);
        try file.writeAll(decl);
    }

    try file.writeAll("\n");

    try emitDomainTables(globals, &file);
    try emitSampler(allocator, globals, &file);
    try emitChecker(allocator, globals, &file);
    try emitEntrypoint(allocator, &file, entry_name);
}

/// Emit `sample_invariant()` — reads fuzzer input bytes and hydrates globals
/// according to their field domains (top, values, or pointers).
fn emitSampler(allocator: std.mem.Allocator, globals: []const Parser.Global, file: *std.fs.File) !void {
    var num_buf: [64]u8 = undefined;
    var bytes_buf: [64]u8 = undefined;

    var value_idx: usize = 0;
    var ptr_idx: usize = 0;
    try file.writeAll("ptrdiff_t sample_invariant(const uint8_t *data, size_t size) {\n");
    try file.writeAll("    size_t off = 0;\n");
    try file.writeAll("    const size_t needed = ABSOLUTION_GLOBALS_SIZE ;\n");
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
        var loop_stack: LoopStack = .init(file, 1);
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
                    if (vals.len == 0) continue;
                    var label_buf: [64]u8 = undefined;
                    const label = try std.fmt.bufPrint(&label_buf, "FM_VAL_{d}", .{value_idx});
                    value_idx += 1;

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
                    if (ptrs.len == 0) continue;
                    var ptr_label_buf: [64]u8 = undefined;
                    const ptr_label = try std.fmt.bufPrint(&ptr_label_buf, "FM_PTR_{d}", .{ptr_idx});
                    ptr_idx += 1;

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

/// Emit the checker that enforces invariants: padding zeroed, and constrained
/// domains (.values, .pointers) still valid after the harness run.
fn emitChecker(allocator: std.mem.Allocator, globals: []const Parser.Global, file: *std.fs.File) !void {
    var bytes_buf: [64]u8 = undefined;
    var value_idx: usize = 0;
    var ptr_idx: usize = 0;

    try file.writeAll("int check_invariant(void) {\n");

    for (globals) |g| {
        const global_dims_len = g.dims.len;

        const mangled = if (g.is_static)
            try mangleName(allocator, g.source_file, g.name)
        else
            try allocator.dupe(u8, g.name);
        defer allocator.free(mangled);

        // Open global loops once per global.
        var loop_stack: LoopStack = .init(file, 1);
        for (g.dims, 0..) |d, i| {
            try loop_stack.openLoop(d, i);
        }

        for (g.fields) |f| {
            const bytes = (f.bit_width + 7) / 8;
            const bytes_str = try std.fmt.bufPrint(&bytes_buf, "{d}", .{bytes});
            const field_dims_len = f.dims.len;

            // Open field loops (if any) inside the global loops.
            for (f.dims, 0..) |d, fi| {
                const i = global_dims_len + fi;
                try loop_stack.openLoop(d, i);
            }

            const current_depth = loop_stack.depth();

            // Skip byte-unaligned regions (bitfields can produce these).
            if (f.offset_bits % 8 != 0) {
                try loop_stack.closeLoops(field_dims_len);
                continue;
            }

            const offset_expr = try emitOffsetCalc(allocator, g.dims, f.dims, @intCast(f.offset_bits / 8));
            defer allocator.free(offset_expr);

            if (f.is_padding) {
                // Padding must stay zeroed.
                try writeIndent(file, current_depth);
                try file.writeAll("for (size_t i = 0; i < ");
                try file.writeAll(bytes_str);
                try file.writeAll("; i++) {\n");
                try writeIndent(file, current_depth + 1);
                try file.writeAll("if (");
                try file.writeAll(mangled);
                try file.writeAll("[");
                try file.writeAll(offset_expr);
                try file.writeAll(" + i] != 0) return -1;\n");
                try writeIndent(file, current_depth);
                try file.writeAll("}\n");
            } else switch (f.domain) {
                .top => {},
                .values => |vals| {
                    if (vals.len == 0) {
                        try loop_stack.closeLoops(field_dims_len);
                        continue;
                    }
                    var label_buf: [64]u8 = undefined;
                    const label = try std.fmt.bufPrint(&label_buf, "FM_VAL_{d}", .{value_idx});
                    value_idx += 1;

                    try writeIndent(file, current_depth);
                    try file.writeAll("{\n");
                    try writeIndent(file, current_depth + 1);
                    try file.writeAll("int found = 0;\n");
                    try writeIndent(file, current_depth + 1);
                    try file.writeAll("for (size_t vi = 0; vi < ");
                    try file.writeAll(label);
                    try file.writeAll("_COUNT; vi++) {\n");
                    try writeIndent(file, current_depth + 2);
                    try file.writeAll("if (memcmp(&");
                    try file.writeAll(mangled);
                    try file.writeAll("[");
                    try file.writeAll(offset_expr);
                    try file.writeAll("], &");
                    try file.writeAll(label);
                    try file.writeAll("[vi * ");
                    try file.writeAll(label);
                    try file.writeAll("_BYTES], ");
                    try file.writeAll(label);
                    try file.writeAll("_BYTES) == 0) { found = 1; break; }\n");
                    try writeIndent(file, current_depth + 1);
                    try file.writeAll("}\n");
                    try writeIndent(file, current_depth + 1);
                    try file.writeAll("if (!found) return -1;\n");
                    try writeIndent(file, current_depth);
                    try file.writeAll("}\n");
                },
                .pointers => |ptrs| {
                    if (ptrs.len == 0) {
                        try loop_stack.closeLoops(field_dims_len);
                        continue;
                    }
                    var ptr_label_buf: [64]u8 = undefined;
                    const ptr_label = try std.fmt.bufPrint(&ptr_label_buf, "FM_PTR_{d}", .{ptr_idx});
                    ptr_idx += 1;

                    try writeIndent(file, current_depth);
                    try file.writeAll("{\n");
                    try writeIndent(file, current_depth + 1);
                    try file.writeAll("void *current;\n");
                    try writeIndent(file, current_depth + 1);
                    try file.writeAll("memcpy(&current, &");
                    try file.writeAll(mangled);
                    try file.writeAll("[");
                    try file.writeAll(offset_expr);
                    try file.writeAll("], sizeof(void *));\n");
                    try writeIndent(file, current_depth + 1);
                    try file.writeAll("int found = 0;\n");
                    try writeIndent(file, current_depth + 1);
                    try file.writeAll("for (size_t pi = 0; pi < ");
                    try file.writeAll(ptr_label);
                    try file.writeAll("_COUNT; pi++) {\n");
                    try writeIndent(file, current_depth + 2);
                    try file.writeAll("if (current == ");
                    try file.writeAll(ptr_label);
                    try file.writeAll("[pi]) { found = 1; break; }\n");
                    try writeIndent(file, current_depth + 1);
                    try file.writeAll("}\n");
                    try writeIndent(file, current_depth + 1);
                    try file.writeAll("if (!found) return -1;\n");
                    try writeIndent(file, current_depth);
                    try file.writeAll("}\n");
                },
            }

            // Close field loops.
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

fn readTmpFile(tmp: *std.testing.TmpDir, name: []const u8, buf: []u8) ![]const u8 {
    var f = try tmp.dir.openFile(name, .{});
    defer f.close();
    const n = try f.readAll(buf);
    return buf[0..n];
}

fn createTmpFile(tmp: *std.testing.TmpDir, name: []const u8) !std.fs.File {
    return try tmp.dir.createFile(name, .{ .read = true });
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
    try writeIndent(&file, 2);
    try file.writeAll("x");
    var buf: [64]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expectEqualStrings("        x", out);
}

test "emitMemset generates correct output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
    try emitMemset(&file, 1, "dst", "0", "sizeof(x)");
    var buf: [256]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expectEqualStrings("    memset(dst, 0, sizeof(x));\n", out);
}

test "emitMemcpy generates correct output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
    try emitMemcpy(&file, 0, "a", "b", "4");
    var buf: [256]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expectEqualStrings("memcpy(a, b, 4);\n", out);
}

test "incrementOffset generates correct output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
    try incrementOffset(&file, 1, "8");
    var buf: [256]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expectEqualStrings("    off += 8;\n", out);
}

test "LoopStack open and close loops" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
    var ls = LoopStack.init(&file, 1);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
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
    try emitDomainTables(globals, &file);
    var buf: [2048]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_VAL_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0xAA") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_VAL_0_COUNT 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_VAL_0_BYTES 1") != null);
}

test "emitDomainTables with .pointers field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
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
    try emitDomainTables(globals, &file);
    var buf: [2048]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_PTR_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "&handler_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_PTR_0_COUNT 1") != null);
}

test "emitDomainTables skips padding fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
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
    try emitDomainTables(globals, &file);
    var buf: [256]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "emitSampler generates sample_invariant for .top field" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
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
    try emitSampler(alloc, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "sample_invariant") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "memset(g, 0, sizeof(g))") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcpy(&g[0], &data[off], 4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "off += 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return off;") != null);
}

test "emitSampler with .values domain" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
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
    try emitSampler(alloc, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "idx_FM_VAL_0 = data[off] % 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "off += 1") != null);
}

test "emitSampler with .pointers domain" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
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
    try emitSampler(alloc, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "idx_FM_PTR_0 = data[off] % 1") != null);
}

test "emitSampler skips padding fields" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
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
    try emitSampler(alloc, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcpy") == null);
}

test "emitSampler with static global uses mangled name" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
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
    try emitSampler(alloc, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "src_a_c_var") != null);
}

test "emitChecker generates padding zero-check" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
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
    try emitChecker(alloc, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "check_invariant") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "!= 0) return -1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return 0;") != null);
}

test "emitChecker generates .values validation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
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
    try emitChecker(alloc, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_VAL_0_COUNT") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "if (!found) return -1") != null);
}

test "emitChecker generates .pointers validation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
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
    try emitChecker(alloc, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "FM_PTR_0_COUNT") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "void *current") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "if (!found) return -1") != null);
}

test "emitChecker skips unaligned bitfield offsets" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
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
    try emitChecker(alloc, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcpy") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "memcmp") == null);
}

test "emitEntrypoint generates LLVMFuzzerTestOneInput" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
    try emitEntrypoint(alloc, &file, "MyHarness");
    var buf: [2048]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "LLVMFuzzerTestOneInput") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sample_invariant") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "MyHarness(data, size)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "check_invariant()") != null);
}

test "writeFuzzerC end-to-end produces valid output" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
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

    try writeFuzzerC(alloc, globals, 4, out_path, redef_path, "TestHarness", &.{});

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
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
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

    try writeFuzzerC(alloc, globals, 1, out_path, redef_path, "TestEntry", &.{});

    var buf: [4096]u8 = undefined;
    const redef_out = try readTmpFile(&tmp, "fuzzer2.redef", &buf);
    try std.testing.expect(std.mem.indexOf(u8, redef_out, "src/mod.c cfg src_mod_c_cfg") != null);

    var buf2: [16384]u8 = undefined;
    const c_out = try readTmpFile(&tmp, "fuzzer2.c", &buf2);
    try std.testing.expect(std.mem.indexOf(u8, c_out, "src_mod_c_cfg") != null);
}

test "writeFuzzerC with func_symbols emits extern declarations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const out_path = try std.fs.path.join(alloc, &.{ dir_path, "fuzzer3.c" });
    defer alloc.free(out_path);
    const redef_path = try std.fs.path.join(alloc, &.{ dir_path, "fuzzer3.redef" });
    defer alloc.free(redef_path);

    const globals: []const Parser.Global = &.{};
    try writeFuzzerC(alloc, globals, 0, out_path, redef_path, "Entry", &.{"my_handler"});

    var buf: [8192]u8 = undefined;
    const c_out = try readTmpFile(&tmp, "fuzzer3.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, c_out, "extern void my_handler(void)") != null);
}

test "emitSampler with global array dims opens loops" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
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
    try emitSampler(alloc, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "for (size_t i0 = 0; i0 < 10; i0++)") != null);
}

test "emitChecker with global array dims opens loops" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try createTmpFile(&tmp, "t.c");
    defer file.close();
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
    try emitChecker(alloc, globals, &file);
    var buf: [4096]u8 = undefined;
    const out = try readTmpFile(&tmp, "t.c", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "for (size_t i0 = 0; i0 < 10; i0++)") != null);
}
