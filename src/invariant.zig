//! Invariant loading and application for domain constraints.
//!
//! Invariants specify allowed values for global fields, constraining the
//! fuzzer's sampling to meaningful states.

const std = @import("std");
const tree = @import("cgen/tree.zig");
const Parser = @import("Parser.zig");

/// Parsed invariant specification containing domain constraints for globals.
/// Owns all memory in `globals`.
pub const Invariant = struct {
    globals: []tree.Global,

    /// Caller must pass the same allocator used in `loadZon`.
    pub fn deinit(self: Invariant, allocator: std.mem.Allocator) void {
        for (self.globals) |*g| g.deinit(allocator);
        allocator.free(self.globals);
    }
};

/// Load an invariant from a `.zon` file.
/// All returned memory is owned by the caller through `Invariant`.
pub fn loadZon(allocator: std.mem.Allocator, path: []const u8) !Invariant {
    const bytes = try std.fs.cwd().readFileAllocOptions(
        allocator,
        path,
        std.math.maxInt(usize),
        null,
        std.mem.Alignment.@"8",
        0,
    );
    defer allocator.free(bytes);

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(allocator);

    const parsed = try std.zon.parse.fromSlice(
        []tree.Global,
        allocator,
        bytes,
        &diag,
        .{ .ignore_unknown_fields = false },
    );

    return .{ .globals = parsed };
}

/// Clone a domain into `allocator`.
/// Returns newly allocated domain and marks ownership.
fn cloneDomain(
    allocator: std.mem.Allocator,
    domain: tree.Domain,
) !struct {
    domain: Parser.Domain,
    owned: bool,
} {
    return switch (domain) {
        .top => .{
            .domain = .top,
            .owned = false,
        },

        .values => |vals| blk: {
            const dup_vals = try allocator.alloc([]const u8, vals.len);
            errdefer allocator.free(dup_vals);

            for (vals, 0..) |v, i| {
                dup_vals[i] = try allocator.dupe(u8, v);
                errdefer allocator.free(dup_vals[i]);
            }

            break :blk .{
                .domain = .{ .values = dup_vals },
                .owned = true,
            };
        },

        .pointers => |ptrs| blk: {
            const dup_ptrs = try allocator.alloc([]const u8, ptrs.len);
            errdefer allocator.free(dup_ptrs);

            for (ptrs, 0..) |p, i| {
                dup_ptrs[i] = try allocator.dupe(u8, p);
                errdefer allocator.free(dup_ptrs[i]);
            }

            break :blk .{
                .domain = .{ .pointers = dup_ptrs },
                .owned = true,
            };
        },
    };
}

/// Apply invariant domains to parsed globals.
/// Mutates `globals` in-place.
///
/// Ownership rules:
/// - Newly cloned domains become owned by `Parser.Field`.
/// - Previous owned domains are freed before replacement.
pub fn applyToGlobals(
    allocator: std.mem.Allocator,
    globals: *std.ArrayList(Parser.Global),
    inv: Invariant,
) !void {
    // Build symbol table and global lookup.
    var global_map = std.StringHashMap(*Parser.Global).init(allocator);
    defer global_map.deinit();

    var symbols = std.StringHashMap(void).init(allocator);
    defer symbols.deinit();

    try global_map.ensureTotalCapacity(@intCast(globals.items.len));
    try symbols.ensureTotalCapacity(@intCast(globals.items.len));

    for (globals.items) |*g| {
        try global_map.putNoClobber(g.name, g);
        try symbols.putNoClobber(g.name, {});
    }

    // Apply invariant globals
    for (inv.globals) |g| {
        const target = global_map.get(g.name) orelse continue;

        var field_map = std.StringHashMap(*Parser.Field).init(allocator);
        defer field_map.deinit();

        try field_map.ensureTotalCapacity(@intCast(target.fields.len));

        for (target.fields) |*mf| {
            try field_map.put(mf.name, mf);
        }

        for (g.fields) |f| {
            const mf = field_map.get(f.name) orelse continue;

            // --- Validate pointer targets first ---
            if (f.domain == .pointers) {
                for (f.domain.pointers) |p| {
                    if (!symbols.contains(p))
                        return error.InvalidPointerTarget;
                }
            }

            // --- Clone domain transactionally ---
            const cloned = try cloneDomain(allocator, f.domain);

            // --- Free previous domain if owned ---
            if (mf.domain_owned) {
                mf.deinit(allocator);
            }

            mf.domain = cloned.domain;
            mf.domain_owned = cloned.owned;
        }
    }
}

test "applyToGlobals updates domains" {
    const allocator = std.testing.allocator;

    var globals = std.ArrayList(Parser.Global).empty;
    defer Parser.free_globals(allocator, &globals);

    const global_fields = try allocator.alloc(Parser.Field, 1);
    global_fields[0] = .{
        .name = try allocator.dupe(u8, "."),
        .bit_width = 8,
        .is_padding = false,
        .domain = .top,
        .domain_owned = false,
    };

    try globals.append(allocator, .{
        .name = try allocator.dupe(u8, "g"),
        .fields = global_fields,
    });

    const inv_fields = try allocator.alloc(tree.Field, 1);
    inv_fields[0] = .{
        .name = try allocator.dupe(u8, "."),
        .bit_width = 8,
        .domain = .{ .values = &.{"0xAA"} },
        .is_padding = false,
    };

    var inv = Invariant{
        .globals = try allocator.alloc(tree.Global, 1),
    };
    defer inv.deinit(allocator);
    inv.globals[0] = .{
        .name = try allocator.dupe(u8, "g"),
        .fields = inv_fields,
    };

    try applyToGlobals(allocator, &globals, inv);
    try std.testing.expect(globals.items[0].fields[0].domain == .values);
}
