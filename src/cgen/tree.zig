const std = @import("std");

const SerializeContext = struct { list: *std.ArrayList(u8), allocator: std.mem.Allocator };
fn serializeWriteFn(ctx: SerializeContext, bytes: []const u8) error{OutOfMemory}!usize {
    try ctx.list.appendSlice(ctx.allocator, bytes);
    return bytes.len;
}

/// Domain of a field value. This mirrors the legacy invariant notions:
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
    /// For synthetic padding fields, the container lvalue expression path (dot-path),
    /// e.g. "." or ".d.sub". Null for non-padding fields.
    pad_container: ?[]const u8 = null,
    /// For synthetic padding fields, bit offset within `pad_container`.
    /// Meaningful only when `is_padding` is true.
    offset_bits: usize = 0,
    /// Width in bits.
    bit_width: usize,
    /// Optional array dimensions (empty when scalar).
    dims: std.ArrayListUnmanaged(usize) = .{},
    /// Whether this field is padding that must remain zeroed.
    is_padding: bool = false,
    /// Value domain.
    domain: Domain = .top,
    /// Whether the domain data is owned by this field (and should be freed).
    domain_owned: bool = false,

    pub fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.pad_container) |c| allocator.free(c);
        self.dims.deinit(allocator);
        if (self.domain_owned) {
            switch (self.domain) {
                .values => |vals| {
                    for (vals) |v| allocator.free(v);
                    allocator.free(vals);
                },
                .pointers => |ptrs| {
                    for (ptrs) |p| allocator.free(p);
                    allocator.free(ptrs);
                },
                else => {},
            }
        }
    }
};

/// A translation-unit global with its flattened fields.
pub const Global = struct {
    name: []const u8,
    dims: std.ArrayListUnmanaged(usize) = .{},
    fields: std.ArrayListUnmanaged(Field) = .{},

    pub fn deinit(self: *Global, allocator: std.mem.Allocator) void {
        self.dims.deinit(allocator);
        for (self.fields.items) |*f| {
            f.deinit(allocator);
        }
        self.fields.deinit(allocator);
        allocator.free(self.name);
    }
};
