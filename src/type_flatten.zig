//! Type flattening for C global variable extraction.
//!
//! Flattens C types (structs, unions, arrays) into a linear list of fields
//! with their bit widths, dimensions, and padding information.

const aro = @import("aro");
const std = @import("std");
const ir = @import("cgen/ir.zig");

pub const Domain = ir.Domain;

const ParseError = std.mem.Allocator.Error;
const Dimensions = std.ArrayListUnmanaged(ir.Dimension);
const DimPositions = std.ArrayListUnmanaged(usize);
const Fields = std.ArrayListUnmanaged(ir.Field);

const root_prefix = ".";

/// Tracks array dimensions along with their positions in the field path.
const DimStack = struct {
    dims: Dimensions = .{},

    fn deinit(self: *DimStack, allocator: std.mem.Allocator) void {
        self.dims.deinit(allocator);
    }

    fn append(self: *DimStack, allocator: std.mem.Allocator, len: usize, stride: u64) !void {
        try self.dims.append(allocator, .{ .len = len, .stride_bytes = stride });
    }

    fn pop(self: *DimStack) void {
        _ = self.dims.pop();
    }

    fn cloneDims(self: DimStack, allocator: std.mem.Allocator) ![]const ir.Dimension {
        return try allocator.dupe(ir.Dimension, self.dims.items);
    }
};

/// Extract top-level array dimensions, returning the innermost element type and the peeled dimensions.
pub fn peelTopLevelArrayDims(
    allocator: std.mem.Allocator,
    tree: aro.Tree,
    qt: aro.QualType,
) ParseError!struct { qt: aro.QualType, dims: []const ir.Dimension } {
    var dims_list = Dimensions{};
    errdefer dims_list.deinit(allocator);
    var current = qt;

    while (current.get(tree.comp, .array)) |arr| {
        switch (arr.len) {
            .fixed, .static => |len| {
                const elem_size = arr.elem.sizeofOrNull(tree.comp) orelse 1; // Should be complete
                try dims_list.append(allocator, .{ .len = @intCast(len), .stride_bytes = elem_size });
                current = arr.elem;
            },
            else => break,
        }
    }

    return .{ .qt = current, .dims = try dims_list.toOwnedSlice(allocator) };
}

/// Flatten a type starting from a global variable.
/// This is the main entry point for flattening a global's type.
pub fn flattenGlobal(
    allocator: std.mem.Allocator,
    tree: aro.Tree,
    qt: aro.QualType,
    fields: *Fields,
) ParseError!void {
    var dim_stack = DimStack{};
    defer dim_stack.deinit(allocator);

    var pad_index: usize = 0;
    try flattenType(allocator, tree, qt, root_prefix, &dim_stack, fields, &pad_index, 0);
}

/// Flatten any supported type (scalars, arrays, records, unions) into fields.
pub fn flattenType(
    allocator: std.mem.Allocator,
    tree: aro.Tree,
    qt: aro.QualType,
    prefix: []const u8,
    dim_stack: *DimStack,
    fields: *Fields,
    pad_index: *usize,
    offset_bits: usize,
) ParseError!void {
    _ = qt.sizeofOrNull(tree.comp) orelse return;

    if (qt.get(tree.comp, .array)) |arr| {
        switch (arr.len) {
            .fixed, .static => |len| {
                // Record the dimension along with the current prefix length.
                // This tells us where in the final path to insert the array index.
                const elem_size = arr.elem.sizeofOrNull(tree.comp) orelse 1;
                try dim_stack.append(allocator, @intCast(len), elem_size);
                defer dim_stack.pop();
                try flattenType(allocator, tree, arr.elem, prefix, dim_stack, fields, pad_index, offset_bits);
                return;
            },
            else => return,
        }
    }

    const base = qt.base(tree.comp).type;
    switch (base) {
        .@"struct" => |rec| {
            try flattenRecord(allocator, tree, rec, prefix, dim_stack, fields, pad_index, offset_bits);
            return;
        },
        .@"union" => |rec| {
            const layout = rec.layout orelse return;
            // Unsupported union: emit padding equal to its max size so we do not
            // consume fuzzer bytes for the unknown variant.
            try addPadding(
                allocator,
                fields,
                prefix,
                dim_stack.*,
                @as(usize, @intCast(layout.size_bits)),
                offset_bits,
                pad_index,
            );
            return;
        },
        else => {},
    }

    const size_bytes = qt.sizeofOrNull(tree.comp) orelse return;
    const bits = @as(usize, @intCast(size_bytes)) * 8;
    var domain: Domain = .top;
    const ty = qt.type(tree.comp);
    if (ty == .bool) {
        domain = .{ .values = &.{ &[_]u8{0}, &[_]u8{1} } };
    }

    const dims_info = try dim_stack.cloneDims(allocator);
    errdefer allocator.free(dims_info);

    const name_copy = try allocator.dupe(u8, prefix);
    errdefer allocator.free(name_copy);

    try fields.append(allocator, .{
        .name = name_copy,
        .offset_bits = offset_bits,
        .bit_width = bits,
        .dims = dims_info,
        .is_padding = false,
        .domain = domain,
    });
}

/// Flatten record fields into ir.Field entries, adding padding as needed.
fn flattenRecord(
    allocator: std.mem.Allocator,
    tree: aro.Tree,
    record: aro.Type.Record,
    prefix: []const u8,
    dim_stack: *DimStack,
    fields: *Fields,
    pad_index: *usize,
    base_offset_bits: usize,
) ParseError!void {
    const layout = record.layout orelse return;
    var current_bits: usize = 0;

    for (record.fields) |field| {
        if (field.layout.offset_bits == std.math.maxInt(u64)) continue;
        const offset_bits = @as(usize, @intCast(field.layout.offset_bits));
        const size_bits = @as(usize, @intCast(field.layout.size_bits));
        if (offset_bits > current_bits) {
            try addPadding(allocator, fields, prefix, dim_stack.*, offset_bits - current_bits, base_offset_bits + current_bits, pad_index);
        }

        var field_name = prefix;
        var field_name_owned = false;
        if (field.name_tok != 0) {
            const fname = tree.tokSlice(field.name_tok);
            field_name = try joinFieldName(allocator, prefix, fname);
            field_name_owned = true;
        }

        defer {
            if (field_name_owned) allocator.free(field_name);
        }

        // Detect bit-fields: if the layout size is smaller than the declared type size,
        // this is a bit-field. We cannot take the address of a bit-field in C, so we
        // skip flattening it and leave the storage as zeros (from the global memset).
        const declared_size_bytes = field.qt.sizeofOrNull(tree.comp);
        const is_bitfield = if (declared_size_bytes) |dsb|
            size_bits < @as(usize, @intCast(dsb)) * 8
        else
            false;

        if (!is_bitfield) {
            try flattenType(allocator, tree, field.qt, field_name, dim_stack, fields, pad_index, base_offset_bits + offset_bits);
        }
        // Bit-fields are left as unsampled storage (zeros from memset).

        current_bits = @max(current_bits, offset_bits + size_bits);
    }

    if (layout.size_bits > current_bits) {
        const tail_bits = @as(usize, @intCast(layout.size_bits - current_bits));
        try addPadding(allocator, fields, prefix, dim_stack.*, tail_bits, base_offset_bits + current_bits, pad_index);
    }
}

/// Append a synthetic padding field with the given bit width.
fn addPadding(
    allocator: std.mem.Allocator,
    fields: *Fields,
    prefix: []const u8,
    dim_stack: DimStack,
    bits: usize,
    pad_offset_bits: usize,
    pad_index: *usize,
) ParseError!void {
    if (bits == 0) return;
    const name = try std.fmt.allocPrint(allocator, "{s}_pad{d}", .{ prefix, pad_index.* });
    errdefer allocator.free(name);
    pad_index.* += 1;
    const dims_copy = try dim_stack.cloneDims(allocator);
    errdefer allocator.free(dims_copy);
    try fields.append(allocator, .{
        .name = name,
        .offset_bits = pad_offset_bits,
        .bit_width = bits,
        .dims = dims_copy,
        .is_padding = true,
        .domain = .top,
    });
}

/// Join a prefix and field name, avoiding duplicate dots for root prefixes.
fn joinFieldName(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ParseError![]const u8 {
    if (prefix.len == 0) return std.fmt.allocPrint(allocator, ".{s}", .{name});
    const needs_dot = prefix[prefix.len - 1] != '.';
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, if (needs_dot) "." else "", name });
}

test "DimStack append, cloneDims, and pop" {
    const alloc = std.testing.allocator;
    var ds = DimStack{};
    defer ds.deinit(alloc);

    try ds.append(alloc, 3, 8);
    try ds.append(alloc, 5, 4);

    const cloned = try ds.cloneDims(alloc);
    defer alloc.free(cloned);
    try std.testing.expectEqual(@as(usize, 2), cloned.len);
    try std.testing.expectEqual(@as(usize, 3), cloned[0].len);
    try std.testing.expectEqual(@as(u64, 8), cloned[0].stride_bytes);
    try std.testing.expectEqual(@as(usize, 5), cloned[1].len);
    try std.testing.expectEqual(@as(u64, 4), cloned[1].stride_bytes);

    ds.pop();
    const cloned2 = try ds.cloneDims(alloc);
    defer alloc.free(cloned2);
    try std.testing.expectEqual(@as(usize, 1), cloned2.len);
}

test "DimStack cloneDims empty" {
    const alloc = std.testing.allocator;
    var ds = DimStack{};
    defer ds.deinit(alloc);
    const cloned = try ds.cloneDims(alloc);
    defer alloc.free(cloned);
    try std.testing.expectEqual(@as(usize, 0), cloned.len);
}

test "joinFieldName with root prefix" {
    const alloc = std.testing.allocator;
    const result = try joinFieldName(alloc, ".", "x");
    defer alloc.free(result);
    try std.testing.expectEqualStrings(".x", result);
}

test "joinFieldName with nested prefix" {
    const alloc = std.testing.allocator;
    const result = try joinFieldName(alloc, ".a", "b");
    defer alloc.free(result);
    try std.testing.expectEqualStrings(".a.b", result);
}

test "joinFieldName with empty prefix" {
    const alloc = std.testing.allocator;
    const result = try joinFieldName(alloc, "", "x");
    defer alloc.free(result);
    try std.testing.expectEqualStrings(".x", result);
}

test "joinFieldName with trailing dot prefix" {
    const alloc = std.testing.allocator;
    const result = try joinFieldName(alloc, ".a.", "b");
    defer alloc.free(result);
    try std.testing.expectEqualStrings(".a.b", result);
}

fn freeField(alloc: std.mem.Allocator, f: *ir.Field) void {
    alloc.free(f.name);
    alloc.free(f.dims);
}

test "addPadding creates correct padding field" {
    const alloc = std.testing.allocator;
    var fields = Fields{};
    defer {
        for (fields.items) |*f| freeField(alloc, f);
        fields.deinit(alloc);
    }
    var ds = DimStack{};
    defer ds.deinit(alloc);
    try ds.append(alloc, 2, 8);

    var idx: usize = 0;
    try addPadding(alloc, &fields, ".", ds, 24, 32, &idx);

    try std.testing.expectEqual(@as(usize, 1), fields.items.len);
    try std.testing.expectEqualStrings("._pad0", fields.items[0].name);
    try std.testing.expectEqual(@as(usize, 24), fields.items[0].bit_width);
    try std.testing.expectEqual(@as(usize, 32), fields.items[0].offset_bits);
    try std.testing.expect(fields.items[0].is_padding);
    try std.testing.expectEqual(@as(usize, 1), fields.items[0].dims.len);
    try std.testing.expectEqual(@as(usize, 1), idx);
}

test "addPadding with zero bits is no-op" {
    const alloc = std.testing.allocator;
    var fields = Fields{};
    defer fields.deinit(alloc);
    var ds = DimStack{};
    defer ds.deinit(alloc);

    var idx: usize = 0;
    try addPadding(alloc, &fields, ".", ds, 0, 0, &idx);

    try std.testing.expectEqual(@as(usize, 0), fields.items.len);
    try std.testing.expectEqual(@as(usize, 0), idx);
}

test "addPadding increments pad_index" {
    const alloc = std.testing.allocator;
    var fields = Fields{};
    defer {
        for (fields.items) |*f| freeField(alloc, f);
        fields.deinit(alloc);
    }
    var ds = DimStack{};
    defer ds.deinit(alloc);

    var idx: usize = 0;
    try addPadding(alloc, &fields, ".", ds, 8, 0, &idx);
    try addPadding(alloc, &fields, ".", ds, 16, 8, &idx);

    try std.testing.expectEqual(@as(usize, 2), fields.items.len);
    try std.testing.expectEqualStrings("._pad0", fields.items[0].name);
    try std.testing.expectEqualStrings("._pad1", fields.items[1].name);
    try std.testing.expectEqual(@as(usize, 2), idx);
}
