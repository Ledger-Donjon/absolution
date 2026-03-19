const std = @import("std");

pub const Dimension = struct {
    len: usize,
    stride_bytes: u64,
};

/// Domain of a field value:
/// - `top`      : unconstrained bytes pulled from the input stream.
/// - `values`   : fixed set of literal values to choose from.
/// - `pointers` : allowed pointer targets (by symbol name).
pub const Domain = union(enum) {
    top,
    values: []const []const u8,
    pointers: []const []const u8,
};

/// A flattened field inside a global.
pub const Field = struct {
    /// Field name with dot-path semantics, e.g. ".a" or ".a_pad".
    name: []const u8,
    /// Offset in bits from the start of the global variable.
    offset_bits: usize = 0,
    /// Width in bits.
    bit_width: usize,
    /// Optional array dimensions (empty when scalar).
    dims: []const Dimension = &.{},
    /// Whether this field is padding that must remain zeroed.
    is_padding: bool = false,
    /// Value domain.
    domain: Domain = .top,

    pub fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.dims);
    }

    pub fn updateDomain(self: *Field, arena: std.mem.Allocator, domain: Domain) !void {
        self.domain =
            switch (domain) {
                .top => .top,
                .values => |vals| blk: {
                    const dup_vals = try arena.alloc([]const u8, vals.len);
                    for (vals, 0..) |v, i| {
                        dup_vals[i] = try arena.dupe(u8, v);
                    }
                    break :blk .{ .values = dup_vals };
                },
                .pointers => |ptrs| blk: {
                    const dup_ptrs = try arena.alloc([]const u8, ptrs.len);
                    for (ptrs, 0..) |p, i| {
                        dup_ptrs[i] = try arena.dupe(u8, p);
                    }
                    break :blk .{ .pointers = dup_ptrs };
                },
            };
    }
};

/// A translation-unit global with its flattened fields.
pub const Global = struct {
    /// Variable name in the original source.
    name: []const u8,
    /// Source file path where this global is defined (owned).
    source_file: []const u8,
    /// Total size of the global in bytes.
    size_bytes: u64,
    /// Whether the global has internal linkage (static storage class).
    is_static: bool,
    /// Top-level array dimensions (empty for scalars).
    dims: []const Dimension,
    /// Flattened fields within this global.
    fields: []Field = &.{},

    pub fn deinit(self: *Global, allocator: std.mem.Allocator) void {
        for (self.fields) |*f| {
            f.deinit(allocator);
        }
        allocator.free(self.fields);
        allocator.free(self.name);
        allocator.free(self.source_file);
        allocator.free(self.dims);
    }
};

test "Field.updateDomain with .top" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = Field{
        .name = "",
        .bit_width = 8,
        .domain = .{ .values = &.{"0xAA"} },
    };
    try f.updateDomain(arena.allocator(), .top);
    try std.testing.expect(f.domain == .top);
}

test "Field.updateDomain with .values deep-copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = Field{ .name = "", .bit_width = 8 };

    var src_buf = "AB".*;
    const src_slice: []const u8 = &src_buf;
    try f.updateDomain(arena.allocator(), .{ .values = &.{src_slice} });

    try std.testing.expect(f.domain == .values);
    try std.testing.expectEqual(@as(usize, 1), f.domain.values.len);
    try std.testing.expectEqualStrings("AB", f.domain.values[0]);

    // Mutate original — copy must be unaffected
    src_buf[0] = 'Z';
    try std.testing.expectEqualStrings("AB", f.domain.values[0]);
}

test "Field.updateDomain with .pointers deep-copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = Field{ .name = "", .bit_width = 64 };

    var src_buf = "handler_a".*;
    const src_slice: []const u8 = &src_buf;
    try f.updateDomain(arena.allocator(), .{ .pointers = &.{src_slice} });

    try std.testing.expect(f.domain == .pointers);
    try std.testing.expectEqual(@as(usize, 1), f.domain.pointers.len);
    try std.testing.expectEqualStrings("handler_a", f.domain.pointers[0]);

    src_buf[0] = 'Z';
    try std.testing.expectEqualStrings("handler_a", f.domain.pointers[0]);
}

test "Field.deinit frees owned memory" {
    const alloc = std.testing.allocator;
    const dims = try alloc.alloc(Dimension, 1);
    dims[0] = .{ .len = 5, .stride_bytes = 4 };
    var f = Field{
        .name = try alloc.dupe(u8, ".field"),
        .bit_width = 32,
        .dims = dims,
    };
    f.deinit(alloc);
}

test "Global.deinit frees fields, name, source_file, and dims" {
    const alloc = std.testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = .{
        .name = try alloc.dupe(u8, ".x"),
        .bit_width = 32,
        .dims = try alloc.alloc(Dimension, 0),
    };
    const dims = try alloc.alloc(Dimension, 1);
    dims[0] = .{ .len = 3, .stride_bytes = 4 };
    var g = Global{
        .name = try alloc.dupe(u8, "my_global"),
        .source_file = try alloc.dupe(u8, "test.c"),
        .size_bytes = 12,
        .is_static = false,
        .dims = dims,
        .fields = fields,
    };
    g.deinit(alloc);
}
