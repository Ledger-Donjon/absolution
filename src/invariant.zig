const std = @import("std");
const tree = @import("cgen/tree.zig");
const Parser = @import("Parser.zig");

pub const Invariant = struct {
    globals: []tree.Global,

    pub fn deinit(self: Invariant, allocator: std.mem.Allocator) void {
        for (self.globals) |*g| g.deinit(allocator);
        allocator.free(self.globals);
    }
};

/// Load an invariant from a `.zon` file, duplicating all strings for ownership.
/// Args:
///   allocator: Allocator used for all cloned data.
///   path: Path to the `.zon` file on disk.
pub fn loadZon(allocator: std.mem.Allocator, path: []const u8) !Invariant {
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    defer allocator.free(raw);
    const bytes = try allocator.allocSentinel(u8, raw.len, 0);
    defer allocator.free(bytes);
    @memcpy(bytes, raw);

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(allocator);

    // Parse root as an array of globals; reject stray keys for a tighter format.
    const parsed = try std.zon.parse.fromSlice([]tree.Global, allocator, bytes, &diag, .{
        .ignore_unknown_fields = false,
    });

    return .{ .globals = parsed };
}

/// Apply invariant domains directly to parsed globals, validating pointer targets.
/// Args:
///   allocator: Allocator used for any temporary storage during application.
///   globals: Parsed globals to update in-place.
///   inv: Invariant describing expected domains for globals and fields.
pub fn applyToGlobals(
    allocator: std.mem.Allocator,
    globals: *std.ArrayList(Parser.ParsedGlobal),
    inv: Invariant,
) !void {
    // Build map of existing globals for fast lookup
    var global_map = std.StringHashMap(*Parser.ParsedGlobal).init(allocator);
    defer global_map.deinit();
    try global_map.ensureTotalCapacity(@intCast(globals.items.len));

    // Also build symbols set for pointer validation
    var symbols = std.StringHashMap(void).init(allocator);
    defer symbols.deinit();
    try symbols.ensureTotalCapacity(@intCast(globals.items.len));

    for (globals.items) |*g| {
        try global_map.putNoClobber(g.name, g);
        try symbols.putNoClobber(g.name, {});
    }

    for (inv.globals) |g| {
        const target = global_map.get(g.name) orelse continue;

        // Build field map for this global
        var field_map = std.StringHashMap(*Parser.ParsedField).init(allocator);
        defer field_map.deinit();
        try field_map.ensureTotalCapacity(@intCast(target.fields.items.len));

        for (target.fields.items) |*mf| {
            try field_map.put(mf.name, mf);
        }

        for (g.fields.items) |f| {
            const mf = field_map.get(f.name) orelse continue;

            switch (f.domain) {
                .pointers => |ptrs| {
                    for (ptrs) |p| {
                        if (!symbols.contains(p)) return error.InvalidPointerTarget;
                    }
                },
                else => {},
            }

            // Clone into globals ownership.
            switch (f.domain) {
                .top => {
                    mf.domain = .top;
                    mf.domain_owned = false;
                },
                .values => |vals| {
                    const dup_vals = try allocator.alloc([]const u8, vals.len);
                    for (vals, 0..) |v, vi| {
                        dup_vals[vi] = try allocator.dupe(u8, v);
                    }
                    mf.domain = .{ .values = dup_vals };
                    mf.domain_owned = true;
                },
                .pointers => |ptrs| {
                    const dup_ptrs = try allocator.alloc([]const u8, ptrs.len);
                    for (ptrs, 0..) |p, pi| {
                        dup_ptrs[pi] = try allocator.dupe(u8, p);
                    }
                    mf.domain = .{ .pointers = dup_ptrs };
                    mf.domain_owned = true;
                },
            }
        }
    }
}

test "applyToGlobals updates domains" {
    const allocator = std.testing.allocator;

    var globals = std.ArrayList(Parser.ParsedGlobal).empty;
    defer Parser.free_globals(allocator, &globals);

    const field_name = try allocator.dupe(u8, ".");
    try globals.append(allocator, .{
        .name = try allocator.dupe(u8, "g"),
        .fields = std.ArrayListUnmanaged(Parser.ParsedField){
            .items = try allocator.alloc(Parser.ParsedField, 1),
        },
    });
    globals.items[0].fields.items[0] = .{
        .name = field_name,
        .bit_width = 8,
        .dims = .{},
        .is_padding = false,
        .domain = .top,
        .domain_owned = false,
    };

    var inv = Invariant{
        .globals = try allocator.alloc(tree.Global, 1),
    };
    defer inv.deinit(allocator);
    inv.globals[0] = .{
        .name = try allocator.dupe(u8, "g"),
        .fields = .{
            .items = try allocator.alloc(tree.Field, 1),
        },
    };
    inv.globals[0].fields.items[0] = .{
        .name = try allocator.dupe(u8, "."),
        .bit_width = 8,
        .dims = .{},
        .domain = .{ .values = &.{"0xAA"} },
        .is_padding = false,
    };

    try applyToGlobals(allocator, &globals, inv);
    try std.testing.expect(globals.items[0].fields.items[0].domain == .values);
}
