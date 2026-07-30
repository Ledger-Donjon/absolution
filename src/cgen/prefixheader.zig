const std = @import("std");
const Parser = @import("../Parser.zig");
const ir = @import("ir.zig");

pub fn path(allocator: std.mem.Allocator, out_path: []const u8) ![]const u8 {
    const extension = std.fs.path.extension(out_path);
    const stem = out_path[0 .. out_path.len - extension.len];
    return std.fmt.allocPrint(allocator, "{s}.h", .{stem});
}

fn sanitizedIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, name);
    for (result) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '_') c.* = '_';
    }
    return result;
}

fn fieldStatePrefixBytes(field: Parser.Field) usize {
    if (field.is_padding) return 0;
    return switch (field.domain) {
        .top => ir.elementBytes(field) * ir.dimsProduct(field.dims),
        .values, .pointers => ir.constrainedSelectorBytes(field.domain) * ir.dimsProduct(field.dims),
        .whole_values => ir.constrainedSelectorBytes(field.domain),
    };
}

fn emitArrayDimensions(io: std.Io, file: *std.Io.File, dims: []const ir.Dimension) !void {
    var buf: [64]u8 = undefined;
    for (dims) |dim| {
        const suffix = try std.fmt.bufPrint(&buf, "[{d}]", .{dim.len});
        try file.writeStreamingAll(io, suffix);
    }
}

/// Emit the public description of the bytes consumed by `sample_invariant`.
///
/// Each global is represented by a packed nested structure. This preserves the
/// sampler's ordering: global dimensions, then fields, then field dimensions.
pub fn write(
    allocator: std.mem.Allocator,
    io: std.Io,
    globals: []const Parser.Global,
    needed_bytes: usize,
    header_path: []const u8,
) !void {
    var file = try std.Io.Dir.cwd().createFile(io, header_path, .{ .truncate = true });
    defer file.close(io);

    try file.writeStreamingAll(io,
        \\#ifndef ABSOLUTION_STATE_PREFIX_H
        \\#define ABSOLUTION_STATE_PREFIX_H
        \\
        \\#include <stdint.h>
        \\
        \\#if defined(__GNUC__) || defined(__clang__)
        \\#define ABSOLUTION_PACKED __attribute__((__packed__))
        \\#else
        \\#define ABSOLUTION_PACKED
        \\#endif
        \\
    );

    var size_buf: [96]u8 = undefined;
    const size_define = try std.fmt.bufPrint(
        &size_buf,
        "#define ABSOLUTION_STATE_PREFIX_SIZE {d}u\n\n",
        .{needed_bytes},
    );
    try file.writeStreamingAll(io, size_define);
    try file.writeStreamingAll(io, "typedef struct ABSOLUTION_PACKED {\n");

    var emitted_global = false;
    for (globals, 0..) |global, global_idx| {
        var has_encoded_fields = false;
        for (global.fields) |field| {
            if (fieldStatePrefixBytes(field) > 0) {
                has_encoded_fields = true;
                break;
            }
        }
        if (!has_encoded_fields) continue;
        emitted_global = true;

        const global_name = try sanitizedIdentifier(allocator, global.name);
        defer allocator.free(global_name);

        try file.writeStreamingAll(io, "    struct ABSOLUTION_PACKED {\n");
        for (global.fields, 0..) |field, field_idx| {
            if (fieldStatePrefixBytes(field) == 0) continue;

            const field_name = try sanitizedIdentifier(allocator, field.name);
            defer allocator.free(field_name);
            var first_name_char: usize = 0;
            while (first_name_char < field_name.len and field_name[first_name_char] == '_') {
                first_name_char += 1;
            }
            const trimmed_field_name = field_name[first_name_char..];
            const member_name = if (trimmed_field_name.len > 0) trimmed_field_name else "unnamed";

            var member_buf: [512]u8 = undefined;
            const member = try std.fmt.bufPrint(
                &member_buf,
                "        uint8_t field_{d}_{s}",
                .{ field_idx, member_name },
            );
            try file.writeStreamingAll(io, member);

            switch (field.domain) {
                .top => {
                    try file.writeStreamingAll(io, "_bytes");
                    try emitArrayDimensions(io, &file, field.dims);
                    var bytes_buf: [64]u8 = undefined;
                    const bytes = try std.fmt.bufPrint(&bytes_buf, "[{d}]", .{ir.elementBytes(field)});
                    try file.writeStreamingAll(io, bytes);
                },
                .values, .pointers => {
                    try file.writeStreamingAll(io, "_selector");
                    try emitArrayDimensions(io, &file, field.dims);
                },
                .whole_values => try file.writeStreamingAll(io, "_selector"),
            }
            try file.writeStreamingAll(io, ";\n");
        }

        var global_member_buf: [512]u8 = undefined;
        const global_member = try std.fmt.bufPrint(
            &global_member_buf,
            "    }} global_{d}_{s}",
            .{ global_idx, global_name },
        );
        try file.writeStreamingAll(io, global_member);
        try emitArrayDimensions(io, &file, global.dims);
        try file.writeStreamingAll(io, ";\n");
    }

    // GCC and Clang support zero-length arrays. This keeps the public type's
    // size equal to zero when every state field is fixed by its invariant.
    if (!emitted_global) try file.writeStreamingAll(io, "    uint8_t _empty[0];\n");

    try file.writeStreamingAll(io,
        \\} AbsolutionStatePrefix;
        \\
        \\#if defined(__cplusplus)
        \\static_assert(sizeof(AbsolutionStatePrefix) == ABSOLUTION_STATE_PREFIX_SIZE,
        \\              "AbsolutionStatePrefix layout mismatch");
        \\#else
        \\_Static_assert(sizeof(AbsolutionStatePrefix) == ABSOLUTION_STATE_PREFIX_SIZE,
        \\               "AbsolutionStatePrefix layout mismatch");
        \\#endif
        \\
        \\#undef ABSOLUTION_PACKED
        \\
        \\#endif
        \\
    );
}

fn readTmpFile(tmp: *std.testing.TmpDir, name: []const u8, buf: []u8) ![]const u8 {
    const io = std.testing.io;
    var file = try tmp.dir.openFile(io, name, .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

test "path replaces the C output extension" {
    const alloc = std.testing.allocator;
    const result = try path(alloc, "generated/fuzzer.c");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("generated/fuzzer.h", result);
}

test "write mirrors sampler ordering and constrained selectors" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fields: []Parser.Field = @constCast(&[_]Parser.Field{
        .{
            .name = ".raw",
            .bit_width = 16,
            .dims = &.{.{ .len = 3, .stride_bytes = 2 }},
            .is_padding = false,
            .domain = .top,
        },
        .{
            .name = ".mode",
            .bit_width = 32,
            .is_padding = false,
            .domain = .{ .values = &.{ &[_]u8{0}, &[_]u8{1} } },
        },
        .{
            .name = ".fixed",
            .bit_width = 8,
            .is_padding = false,
            .domain = .{ .values = &.{&[_]u8{7}} },
        },
    });
    const globals: []const Parser.Global = &.{.{
        .name = "machine-state",
        .source_file = "",
        .size_bytes = 10,
        .is_static = false,
        .dims = &.{.{ .len = 2, .stride_bytes = 10 }},
        .fields = fields,
    }};

    const header_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path, "state.h" });
    defer alloc.free(header_path);
    try write(alloc, io, globals, 14, header_path);

    var buf: [8192]u8 = undefined;
    const header = try readTmpFile(&tmp, "state.h", &buf);
    try std.testing.expect(std.mem.indexOf(u8, header, "#define ABSOLUTION_STATE_PREFIX_SIZE 14u") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "field_0_raw_bytes[3][2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "field_1_mode_selector;") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "field_2_fixed") == null);
    try std.testing.expect(std.mem.indexOf(u8, header, "global_0_machine_state[2]") != null);
}

test "write supports an empty prefix" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const header_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path, "empty.h" });
    defer alloc.free(header_path);
    try write(alloc, io, &.{}, 0, header_path);

    var buf: [4096]u8 = undefined;
    const header = try readTmpFile(&tmp, "empty.h", &buf);
    try std.testing.expect(std.mem.indexOf(u8, header, "#define ABSOLUTION_STATE_PREFIX_SIZE 0u") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "uint8_t _empty[0]") != null);
}
