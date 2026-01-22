const aro = @import("aro");
const std = @import("std");
const cgen_tree = @import("cgen/tree.zig");

const ParseError = std.mem.Allocator.Error;

pub const Domain = cgen_tree.Domain;
pub const ParsedField = cgen_tree.Field;
pub const ParsedGlobal = cgen_tree.Global;

const Dimensions = std.ArrayListUnmanaged(usize);
const Fields = std.ArrayListUnmanaged(ParsedField);
const root_prefix = ".";

// Usual pattern in zig to use a file as a struct
// I don't really like this pattern and might change this.
// This file can be seen as a lightweight version of a arocc Driver
// With simpler APIs that work better for our needs.
// The point of the Parser struct is to ease the allocation of all
// needed structs. They all reference each other and can be used
// directly later on
const Parser = @This();
// Struct parameters
allocator: std.mem.Allocator,
arena: std.mem.Allocator,
diagnostics: aro.Diagnostics,
comp: aro.Compilation,
driver: aro.Driver,
toolchain: aro.Toolchain,
initialized: bool = false,

/// Initialize the parser, discover the toolchain, and prime diagnostics.
/// Args:
///   allocator: General-purpose allocator used for long-lived buffers.
///   arena: Short-lived arena used by aro internals.
///   io: Threaded IO instance passed to aro for file access.
pub fn init(allocator: std.mem.Allocator, arena: std.mem.Allocator) !*Parser {
    const p = try allocator.create(Parser);
    errdefer allocator.destroy(p);

    // Initialize base fields in-place so self-references are valid from the start
    p.* = .{
        .allocator = allocator,
        .arena = arena,
        .diagnostics = .{
            .output = .{ .to_list = .{ .arena = std.heap.ArenaAllocator.init(allocator) } },
            .state = .{ .enable_all_warnings = false },
        },
        .comp = undefined,
        .driver = undefined,
        .toolchain = undefined,
        .initialized = false,
    };
    errdefer p.diagnostics.deinit();

    // Create compilation with diagnostics pointing at final storage
    p.comp = try aro.Compilation.initDefault(allocator, arena, &p.diagnostics, std.fs.cwd());
    errdefer p.comp.deinit();

    // Compute resource_dir relative to executable and store a duped copy
    const exe_path = try std.fs.selfExePathAlloc(p.allocator);
    defer p.allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse unreachable;
    const resource_dir = std.fs.path.dirname(exe_dir) orelse unreachable;
    const resource_dir_dupe = try p.comp.arena.dupe(u8, resource_dir);

    // Initialize driver and toolchain using stable self pointers
    p.driver = .{ .comp = &p.comp, .aro_name = "fuzzmate", .diagnostics = &p.diagnostics, .resource_dir = resource_dir_dupe };
    errdefer p.driver.deinit();
    p.toolchain = .{ .driver = &p.driver, .filesystem = .{ .fake = &.{} } };
    errdefer p.toolchain.deinit();
    try p.toolchain.discover();
    try p.toolchain.defineSystemIncludes();
    p.initialized = true;

    return p;
}

/// Tear down toolchain state and diagnostics if previously initialized.
/// Safe to call exactly once per `init`.
pub fn deinit(p: *Parser) void {
    if (p.initialized) {
        p.toolchain.deinit();
        p.driver.deinit();
    }
    p.comp.deinit();
    p.diagnostics.deinit();

    const allocator = p.allocator;
    allocator.destroy(p);
}

pub fn free_globals(allocator: std.mem.Allocator, globals: *std.ArrayList(ParsedGlobal)) void {
    for (globals.items) |*g| {
        g.deinit(allocator);
    }
    globals.deinit(allocator);
}

/// Collect non-const, user-defined globals along with their bit widths.
pub fn collect_globals(p: *Parser, path: []const u8, allocator: std.mem.Allocator) !std.ArrayList(ParsedGlobal) {
    const source = try p.driver.comp.addSourceFromPath(path);
    const builtin = try p.driver.comp.generateBuiltinMacros(p.driver.system_defines);
    var pp = try aro.Preprocessor.initDefault(p.driver.comp);
    defer pp.deinit();
    pp.preprocessSources(&.{ source, builtin }) catch |err| {
        // Print compilation errors
        var stdout_buf: [1024]u8 = undefined;
        var stdout = std.fs.File.stdout().writer(&stdout_buf);
        defer _ = stdout.interface.flush() catch {};
        for (p.driver.comp.diagnostics.output.to_list.messages.items) |msg| {
            try msg.write(&stdout.interface, .escape_codes, true);
        }
        return err;
    };
    var tree = try pp.parse();
    defer tree.deinit();

    var globals = std.ArrayList(ParsedGlobal).empty;
    errdefer free_globals(allocator, &globals);

    for (tree.root_decls.items) |idx| {
        const node = idx.get(&tree);
        switch (node) {
            .variable => |variable| {
                const loc = tree.tokens.items(.loc)[variable.name_tok];
                const expanded = loc.expand(p.driver.comp);
                // Ignore system variables
                if (expanded.kind != .user) continue;
                // Ignore const-qualified objects
                if (variable.qt.@"const") continue;
                // Ignore incomplete types
                if (variable.qt.hasIncompleteSize(tree.comp)) continue;

                const name_slice = tree.tokSlice(variable.name_tok);
                const copied_name = try allocator.dupe(u8, name_slice);
                errdefer allocator.free(copied_name);

                var peeled = try peelTopLevelArrayDims(allocator, tree, variable.qt);
                errdefer peeled.dims.deinit(allocator);

                var fields = Fields{};
                // If flattening fails, we need to clean up fields that were added.
                // Since ParsedField (cgen_tree.Field) now has a deinit, we can loop and deinit.
                // Or define a helper. Since we're inside collect_globals, we can use errdefer with a lambda or helper.
                // However, fields is managed by ArrayListUnmanaged.
                // Let's create a small helper for cleaning up partial fields list if flattening fails.
                errdefer {
                    for (fields.items) |*f| f.deinit(allocator);
                    fields.deinit(allocator);
                }

                var dims = Dimensions{};
                defer dims.deinit(allocator);

                var pad_index: usize = 0;
                try flattenType(allocator, tree, peeled.qt, root_prefix, &dims, &fields, &pad_index);

                try globals.append(allocator, .{ .name = copied_name, .dims = peeled.dims, .fields = fields });
            },
            else => {},
        }
    }

    return globals;
}

/// Extract top-level array dimensions, returning the innermost element type and the peeled dimensions.
fn peelTopLevelArrayDims(
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

/// Append a synthetic padding field with the given bit width.
fn addPadding(
    allocator: std.mem.Allocator,
    fields: *std.ArrayListUnmanaged(ParsedField),
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

/// Flatten record fields into ParsedField entries, adding padding as needed.
fn flattenRecord(
    allocator: std.mem.Allocator,
    tree: aro.Tree,
    record: aro.Type.Record,
    prefix: []const u8,
    dims: *Dimensions,
    fields: *std.ArrayListUnmanaged(ParsedField),
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
        try flattenType(allocator, tree, field.qt, field_name, dims, fields, pad_index);
        current_bits = @max(current_bits, offset_bits + size_bits);
    }

    if (layout.size_bits > current_bits) {
        const tail_bits = @as(usize, @intCast(layout.size_bits - current_bits));
        try addPadding(allocator, fields, prefix, dims.*, tail_bits, current_bits, pad_index);
    }
}

/// Flatten any supported type (scalars, arrays, records, unions) into fields.
fn flattenType(
    allocator: std.mem.Allocator,
    tree: aro.Tree,
    qt: aro.QualType,
    prefix: []const u8,
    dims: *Dimensions,
    fields: *std.ArrayListUnmanaged(ParsedField),
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

/// Return the record descriptor when the QualType is a struct, else null.
fn getStructRecord(qt: aro.QualType, comp: *const aro.Compilation) ?aro.Type.Record {
    return switch (qt.base(comp).type) {
        .@"struct" => |record| record,
        else => null,
    };
}
