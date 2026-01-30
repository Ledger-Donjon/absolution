//! Type flattening for C global variable extraction.
//!
//! Flattens C types (structs, unions, arrays) into a linear list of fields
//! with their bit widths, dimensions, and padding information.

const aro = @import("aro");
const std = @import("std");
const cgen_tree = @import("cgen/tree.zig");

pub const Domain = cgen_tree.Domain;
pub const ParsedField = cgen_tree.Field;

const ParseError = std.mem.Allocator.Error;
const Dimensions = std.ArrayListUnmanaged(usize);
const Fields = std.ArrayListUnmanaged(ParsedField);

const root_prefix = ".";

/// Extract top-level array dimensions, returning the innermost element type and the peeled dimensions.
pub fn peelTopLevelArrayDims(
    allocator: std.mem.Allocator,
    tree: aro.Tree,
    qt: aro.QualType,
) ParseError!struct { qt: aro.QualType, dims: Dimensions } {
    var dims_list = Dimensions{};
    errdefer dims_list.deinit(allocator);
    var current = qt;

    while (current.get(tree.comp, .array)) |arr| {
        switch (arr.len) {
            .fixed, .static => |len| {
                try dims_list.append(allocator, @intCast(len));
                current = arr.elem;
            },
            else => break,
        }
    }

    return .{ .qt = current, .dims = dims_list };
}

/// Flatten a type starting from a global variable.
/// This is the main entry point for flattening a global's type.
pub fn flattenGlobal(
    allocator: std.mem.Allocator,
    tree: aro.Tree,
    qt: aro.QualType,
    fields: *Fields,
) ParseError!void {
    var dims = Dimensions{};
    defer dims.deinit(allocator);

    var pad_index: usize = 0;
    try flattenType(allocator, tree, qt, root_prefix, &dims, fields, &pad_index);
}

/// Flatten any supported type (scalars, arrays, records, unions) into fields.
pub fn flattenType(
    allocator: std.mem.Allocator,
    tree: aro.Tree,
    qt: aro.QualType,
    prefix: []const u8,
    dims: *Dimensions,
    fields: *Fields,
    pad_index: *usize,
) ParseError!void {
    _ = qt.sizeofOrNull(tree.comp) orelse return;

    if (qt.get(tree.comp, .array)) |arr| {
        switch (arr.len) {
            .fixed, .static => |len| {
                try dims.append(allocator, @intCast(len));
                defer _ = dims.pop();
                try flattenType(allocator, tree, arr.elem, prefix, dims, fields, pad_index);
                return;
            },
            else => return,
        }
    }

    const base = qt.base(tree.comp).type;
    switch (base) {
        .@"struct" => |rec| {
            try flattenRecord(allocator, tree, rec, prefix, dims, fields, pad_index);
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
                dims.*,
                @as(usize, @intCast(layout.size_bits)),
                0,
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
        domain = .{ .values = &.{ "0", "1" } };
    }

    var dims_info = try dims.*.clone(allocator);
    errdefer dims_info.deinit(allocator);

    const name_copy = try allocator.dupe(u8, prefix);
    errdefer allocator.free(name_copy);

    try fields.append(allocator, .{
        .name = name_copy,
        .bit_width = bits,
        .dims = dims_info,
        .is_padding = false,
        .domain = domain,
    });
}

/// Flatten record fields into ParsedField entries, adding padding as needed.
fn flattenRecord(
    allocator: std.mem.Allocator,
    tree: aro.Tree,
    record: aro.Type.Record,
    prefix: []const u8,
    dims: *Dimensions,
    fields: *Fields,
    pad_index: *usize,
) ParseError!void {
    const layout = record.layout orelse return;
    var current_bits: usize = 0;

    for (record.fields) |field| {
        if (field.layout.offset_bits == std.math.maxInt(u64)) continue;
        const offset_bits = @as(usize, @intCast(field.layout.offset_bits));
        const size_bits = @as(usize, @intCast(field.layout.size_bits));
        if (offset_bits > current_bits) {
            try addPadding(allocator, fields, prefix, dims.*, offset_bits - current_bits, current_bits, pad_index);
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
            try flattenType(allocator, tree, field.qt, field_name, dims, fields, pad_index);
        }
        // Bit-fields are left as unsampled storage (zeros from memset).

        current_bits = @max(current_bits, offset_bits + size_bits);
    }

    if (layout.size_bits > current_bits) {
        const tail_bits = @as(usize, @intCast(layout.size_bits - current_bits));
        try addPadding(allocator, fields, prefix, dims.*, tail_bits, current_bits, pad_index);
    }
}

/// Append a synthetic padding field with the given bit width.
fn addPadding(
    allocator: std.mem.Allocator,
    fields: *Fields,
    prefix: []const u8,
    dims: Dimensions,
    bits: usize,
    pad_offset_bits: usize,
    pad_index: *usize,
) ParseError!void {
    if (bits == 0) return;
    const name = try std.fmt.allocPrint(allocator, "{s}_pad{d}", .{ prefix, pad_index.* });
    pad_index.* += 1;
    var dims_copy = try dims.clone(allocator);
    errdefer dims_copy.deinit(allocator);
    const container_copy = try allocator.dupe(u8, prefix);
    errdefer allocator.free(container_copy);
    try fields.append(allocator, .{
        .name = name,
        .pad_container = container_copy,
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
