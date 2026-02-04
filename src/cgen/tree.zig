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
    /// For synthetic padding fields, the container lvalue expression path (dot-path),
    /// e.g. "." or ".d.sub". Null for non-padding fields.
    pad_container: ?[]const u8 = null,
    /// Offset in bits from the start of the global variable.
    offset_bits: usize = 0,
    /// Width in bits.
    bit_width: usize,
    /// Optional array dimensions (empty when scalar).
    dims: std.ArrayListUnmanaged(Dimension) = .{},
    /// Byte offsets in `name` where each dimension's index should be inserted.
    /// Each entry corresponds to the same index in `dims`. For example, if
    /// name=".ep_in.status" and dims=[4], dim_positions=[7] means the [4]
    /// index goes after ".ep_in" (byte offset 7), producing ".ep_in[i].status".
    dim_positions: std.ArrayListUnmanaged(usize) = .{},
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
        self.dim_positions.deinit(allocator);
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
    /// Variable name in the original source.
    name: []const u8,
    /// Source file path where this global is defined (owned).
    source_file: []const u8,
    /// Total size of the global in bytes.
    size_bytes: u64,
    /// Whether the global has internal linkage (static storage class).
    is_static: bool,
    /// Top-level array dimensions (empty for scalars).
    dims: std.ArrayListUnmanaged(Dimension) = .{},
    /// Flattened fields within this global.
    fields: std.ArrayListUnmanaged(Field) = .{},

    pub fn deinit(self: *Global, allocator: std.mem.Allocator) void {
        self.dims.deinit(allocator);
        for (self.fields.items) |*f| {
            f.deinit(allocator);
        }
        self.fields.deinit(allocator);
        allocator.free(self.name);
        allocator.free(self.source_file);
    }
};
