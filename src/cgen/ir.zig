const std = @import("std");

pub const Dimension = struct {
    len: usize,
    stride_bytes: u64,
};

/// Domain of a field value:
/// - `top`          : unconstrained bytes pulled from the input stream.
/// - `values`       : fixed set of literal values to choose from (per element).
/// - `whole_values` : fixed set of full-field byte blobs (one blob covers the
///                    entire field instance, including all `Field.dims`).
/// - `pointers`     : allowed pointer targets (by symbol name).
pub const Domain = union(enum) {
    top,
    values: []const []const u8,
    whole_values: []const []const u8,
    pointers: []const []const u8,
};

pub const DomainError = error{
    TooManyCandidates,
    EmptyWholeValuesDomain,
    WholeValuesBlobMismatch,
};

/// Product of dimension lengths (1 when `dims` is empty).
pub fn dimsProduct(dims: []const Dimension) usize {
    var prod: usize = 1;
    for (dims) |d| prod *= d.len;
    return prod;
}

/// Byte width of one scalar element of a field.
pub fn elementBytes(f: Field) usize {
    return (f.bit_width + 7) / 8;
}

/// Total byte span of one field instance (all field array dims), used by `whole_values`.
pub fn wholeFieldBytes(f: Field) usize {
    return elementBytes(f) * dimsProduct(f.dims);
}

/// For constrained domains: 0 bytes when there is at most one candidate, else 1 selector byte.
pub fn constrainedSelectorBytes(domain: Domain) usize {
    return switch (domain) {
        .top => 0,
        .values => |vals| if (vals.len <= 1) 0 else 1,
        .whole_values => |vals| if (vals.len <= 1) 0 else 1,
        .pointers => |ptrs| if (ptrs.len <= 1) 0 else 1,
    };
}

/// Rejects candidate lists that cannot be indexed with one byte (>256 choices).
pub fn validateConstrainedDomain(domain: Domain) DomainError!void {
    switch (domain) {
        .top => {},
        .values => |vals| if (vals.len > 256) return error.TooManyCandidates,
        .whole_values => |vals| {
            if (vals.len == 0) return error.EmptyWholeValuesDomain;
            if (vals.len > 256) return error.TooManyCandidates;
        },
        .pointers => |ptrs| if (ptrs.len > 256) return error.TooManyCandidates,
    }
}

/// Validates domain-specific constraints; for `whole_values`, checks candidate blob lengths.
pub fn validateFieldDomain(f: Field) DomainError!void {
    try validateConstrainedDomain(f.domain);
    switch (f.domain) {
        .top, .values, .pointers => {},
        .whole_values => |vals| {
            const expected = wholeFieldBytes(f);
            for (vals) |blob| {
                if (blob.len != expected) return error.WholeValuesBlobMismatch;
            }
        },
    }
}

pub fn validateGlobalsDomains(globals: []const Global) DomainError!void {
    for (globals) |g| {
        for (g.fields) |f| {
            if (f.is_padding) continue;
            try validateFieldDomain(f);
        }
    }
}

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
                .whole_values => |vals| blk: {
                    const dup_vals = try arena.alloc([]const u8, vals.len);
                    for (vals, 0..) |v, i| {
                        dup_vals[i] = try arena.dupe(u8, v);
                    }
                    break :blk .{ .whole_values = dup_vals };
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

test "Field.updateDomain with .whole_values deep-copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = Field{ .name = "", .bit_width = 16 };

    var src_buf = "AB".*;
    const src_slice: []const u8 = &src_buf;
    try f.updateDomain(arena.allocator(), .{ .whole_values = &.{src_slice} });

    try std.testing.expect(f.domain == .whole_values);
    try std.testing.expectEqual(@as(usize, 1), f.domain.whole_values.len);
    try std.testing.expectEqualStrings("AB", f.domain.whole_values[0]);

    src_buf[0] = 'Z';
    try std.testing.expectEqualStrings("AB", f.domain.whole_values[0]);
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

test "validateConstrainedDomain rejects more than 256 candidates" {
    var vals: [257][]const u8 = undefined;
    for (&vals) |*v| v.* = "x";
    try std.testing.expectError(error.TooManyCandidates, validateConstrainedDomain(.{ .values = &vals }));
}

test "validateFieldDomain whole_values checks blob length" {
    const f_ok: Field = .{
        .name = ".b",
        .bit_width = 16,
        .dims = &.{.{ .len = 1, .stride_bytes = 2 }},
        .domain = .{ .whole_values = &.{&[_]u8{ 1, 2 }} },
    };
    try validateFieldDomain(f_ok);

    const f_bad: Field = .{
        .name = ".b",
        .bit_width = 16,
        .dims = &.{.{ .len = 1, .stride_bytes = 2 }},
        .domain = .{ .whole_values = &.{&[_]u8{1}} },
    };
    try std.testing.expectError(error.WholeValuesBlobMismatch, validateFieldDomain(f_bad));
}

test "constrainedSelectorBytes" {
    try std.testing.expectEqual(@as(usize, 0), constrainedSelectorBytes(.top));
    try std.testing.expectEqual(@as(usize, 0), constrainedSelectorBytes(.{ .values = &.{"a"} }));
    try std.testing.expectEqual(@as(usize, 1), constrainedSelectorBytes(.{ .values = &.{ "a", "b" } }));
    try std.testing.expectEqual(@as(usize, 0), constrainedSelectorBytes(.{ .whole_values = &.{&[_]u8{1}} }));
    try std.testing.expectEqual(@as(usize, 1), constrainedSelectorBytes(.{ .whole_values = &.{ &[_]u8{1}, &[_]u8{2} } }));
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
