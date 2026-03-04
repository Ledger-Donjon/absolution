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
    arena: std.heap.ArenaAllocator,

    /// Caller must pass the same allocator used in `loadZon`.
    pub fn deinit(self: Invariant) void {
        self.arena.deinit();
    }
};

/// Load an invariant from a `.zon` file.
/// All returned memory is owned by the caller through `Invariant`.
pub fn loadZon(gpa: std.mem.Allocator, path: []const u8) !Invariant {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var allocator = arena.allocator();

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

    return .{ .globals = parsed, .arena = arena };
}

/// Clone a domain into `allocator`.
/// Returns newly allocated domain.
fn cloneDomain(arena: std.mem.Allocator, domain: tree.Domain) !Parser.Domain {
    return switch (domain) {
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

/// Result of applying invariant domains to parsed globals.
pub const ApplyResult = struct {
    /// Pointer-target symbols not found among known globals.
    /// Presumed to be function symbols that need forward declarations.
    /// Caller owns the slice; individual strings reference the invariant arena.
    func_symbols: []const []const u8,
};

/// Apply invariant domains to parsed globals.
/// Mutates `globals` in-place and returns symbols that need forward
/// declarations (pointer targets not found among the known globals).
///
/// Ownership rules:
/// - Newly cloned domains become owned by `Parser.Field`.
/// - Previous owned domains are freed before replacement.
/// - Returned `func_symbols` slice is owned by caller (allocated via `gpa`);
///   the individual strings point into the invariant arena.
pub fn applyToGlobals(
    gpa: std.mem.Allocator,
    globals: *std.ArrayList(Parser.Global),
    inv: *Invariant,
) error{ OutOfMemory, InvalidPointerTarget }!ApplyResult {
    // Build symbol table and global lookup.
    var global_map: std.StringHashMap(*Parser.Global) = .init(gpa);
    defer global_map.deinit();

    var symbols: std.StringHashMap(void) = .init(gpa);
    defer symbols.deinit();

    try global_map.ensureTotalCapacity(@intCast(globals.items.len));
    try symbols.ensureTotalCapacity(@intCast(globals.items.len));

    for (globals.items) |*g| {
        try global_map.putNoClobber(g.name, g);
        try symbols.putNoClobber(g.name, {});
    }

    var func_syms: std.StringHashMap(void) = .init(gpa);
    defer func_syms.deinit();

    const arena = inv.arena.allocator();
    // Apply invariant globals
    for (inv.globals) |g| {
        const target = global_map.get(g.name) orelse continue;

        var field_map: std.StringHashMap(*Parser.Field) = .init(gpa);
        defer field_map.deinit();

        try field_map.ensureTotalCapacity(@intCast(target.fields.len));

        for (target.fields) |*mf| {
            try field_map.put(mf.name, mf);
        }

        for (g.fields) |f| {
            const mf = field_map.get(f.name) orelse continue;
            const cloned = try cloneDomain(arena, f.domain);
            mf.domain = cloned;

            if (cloned == .pointers) {
                for (cloned.pointers) |ptr_name| {
                    if (!symbols.contains(ptr_name)) {
                        std.debug.print("warning: pointer target '{s}' not found among globals, assuming function\n", .{ptr_name});
                        try func_syms.put(ptr_name, {});
                    }
                }
            }
        }
    }

    const result = try gpa.alloc([]const u8, func_syms.count());
    var i: usize = 0;
    var it = func_syms.keyIterator();
    while (it.next()) |key| : (i += 1) {
        result[i] = key.*;
    }
    return .{ .func_symbols = result };
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

    const result = try applyToGlobals(allocator, &globals, &inv);
    defer allocator.free(result.func_symbols);
    try std.testing.expect(globals.items[0].fields[0].domain == .values);
    try std.testing.expectEqual(@as(usize, 0), result.func_symbols.len);
}
