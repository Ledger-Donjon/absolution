//! Invariant loading and application for domain constraints.
//!
//! Invariants specify allowed values for global fields, constraining the
//! fuzzer's sampling to meaningful states.

const std = @import("std");
const ir = @import("cgen/ir.zig");
const Parser = @import("Parser.zig");

/// Parsed invariant specification containing domain constraints for globals.
/// Owns all memory in `globals`.
const Invariant = @This();
globals: []ir.Global,
arena: std.heap.ArenaAllocator,

/// Load an invariant from a `.zon` file.
/// All returned memory is owned by the caller through `Invariant`.
pub fn init(gpa: std.mem.Allocator, path: []const u8) !Invariant {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    // zon will allocate an array and elements in depths
    // it is easier to destroy arena
    const zon_allocator = arena.allocator();

    const bytes = try std.fs.cwd().readFileAllocOptions(
        gpa,
        path,
        std.math.maxInt(usize),
        null,
        std.mem.Alignment.@"8",
        0,
    );
    defer gpa.free(bytes);

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(zon_allocator);

    const globals = try std.zon.parse.fromSlice(
        []ir.Global,
        zon_allocator,
        bytes,
        &diag,
        .{ .ignore_unknown_fields = false },
    );

    return .{ .globals = globals, .arena = arena };
}

/// Release all memory owned by this invariant (the arena allocated in `init`).
pub fn deinit(self: *Invariant) void {
    self.arena.deinit();
    self.* = undefined;
}

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
    self: Invariant,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    globals: std.ArrayList(Parser.Global),
) !struct { globals: std.ArrayList(Parser.Global), func_symbols: []const []const u8 } {
    // Build symbol table and global lookup.
    var global_map: std.StringHashMap(*Parser.Global) = .init(gpa);
    defer global_map.deinit();

    var symbols: std.StringHashMap(void) = .init(gpa);
    defer symbols.deinit();

    try global_map.ensureTotalCapacity(@intCast(globals.items.len));
    try symbols.ensureTotalCapacity(@intCast(globals.items.len));

    for (globals.items) |*g| {
        const key = try uniqueKey(arena, g.name, g.source_file, g.is_static);
        try global_map.putNoClobber(key, g);
        try symbols.put(g.name, {});
    }

    var func_syms: std.StringHashMap(void) = .init(gpa);
    defer func_syms.deinit();

    var field_map: std.StringHashMap(*Parser.Field) = .init(gpa);
    defer field_map.deinit();
    // Apply invariant globals
    for (self.globals) |g| {
        const key = try uniqueKey(arena, g.name, g.source_file, g.is_static);
        const target = global_map.get(key) orelse continue;

        field_map.clearRetainingCapacity();
        try field_map.ensureTotalCapacity(@intCast(target.fields.len));

        for (target.fields) |*mf| {
            try field_map.put(mf.name, mf);
        }

        for (g.fields) |f| {
            var mf = field_map.get(f.name) orelse continue;
            try mf.updateDomain(arena, f.domain);

            if (mf.domain == .pointers) {
                for (mf.domain.pointers) |ptr_name| {
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
    return .{ .globals = globals, .func_symbols = result };
}

/// Produce a map key that disambiguates static globals (same name, different
/// translation units) from non-static ones. Static globals include the
/// source path so that e.g. `file1.c:var` and `file2.c:var` get distinct keys.
fn uniqueKey(alloc: std.mem.Allocator, name: []const u8, source_file: []const u8, is_static: bool) ![]const u8 {
    if (is_static)
        return std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ source_file, name });
    return name;
}

test "applyToGlobals updates domains" {
    const allocator = std.testing.allocator;

    var globals = std.ArrayList(Parser.Global).empty;
    defer Parser.freeGlobals(allocator, &globals);

    const global_fields = try allocator.alloc(Parser.Field, 1);
    global_fields[0] = .{
        .name = try allocator.dupe(u8, "."),
        .bit_width = 8,
        .is_padding = false,
        .domain = .top,
    };

    try globals.append(allocator, .{
        .name = try allocator.dupe(u8, "g"),
        .source_file = try allocator.dupe(u8, ""),
        .size_bytes = 1,
        .is_static = false,
        .dims = &.{},
        .fields = global_fields,
    });

    var inv_arena = std.heap.ArenaAllocator.init(allocator);
    const inv_alloc = inv_arena.allocator();
    const inv_fields = try inv_alloc.alloc(ir.Field, 1);
    inv_fields[0] = .{
        .name = try inv_alloc.dupe(u8, "."),
        .bit_width = 8,
        .domain = .{ .values = &.{"0xAA"} },
        .is_padding = false,
    };
    const inv_globals = try inv_alloc.alloc(ir.Global, 1);
    inv_globals[0] = .{
        .name = try inv_alloc.dupe(u8, "g"),
        .source_file = try inv_alloc.dupe(u8, ""),
        .size_bytes = 1,
        .is_static = false,
        .dims = &.{},
        .fields = inv_fields,
    };
    var inv = Invariant{ .globals = inv_globals, .arena = inv_arena };
    defer inv.deinit();

    var apply_arena = std.heap.ArenaAllocator.init(allocator);
    defer apply_arena.deinit();
    const result = try inv.applyToGlobals(allocator, apply_arena.allocator(), globals);
    defer allocator.free(result.func_symbols);
    try std.testing.expect(globals.items[0].fields[0].domain == .values);
    try std.testing.expectEqual(@as(usize, 0), result.func_symbols.len);
}

test "applyToGlobals handles static globals with same name from different files" {
    const allocator = std.testing.allocator;
    var globals = std.ArrayList(Parser.Global).empty;
    defer Parser.freeGlobals(allocator, &globals);
    // Two static globals both named "var" from different source files.
    for ([_][]const u8{ "file1.c", "file2.c" }) |src| {
        const fields = try allocator.alloc(Parser.Field, 1);
        fields[0] = .{
            .name = try allocator.dupe(u8, "."),
            .bit_width = 32,
            .is_padding = false,
            .domain = .top,
        };
        try globals.append(allocator, .{
            .name = try allocator.dupe(u8, "var"),
            .source_file = try allocator.dupe(u8, src),
            .size_bytes = 4,
            .is_static = true,
            .dims = &.{},
            .fields = fields,
        });
    }
    // Invariant targets only the first file's "var".
    var inv_arena: std.heap.ArenaAllocator = .init(allocator);
    defer inv_arena.deinit();
    const inv_alloc = inv_arena.allocator();
    const inv_fields = try inv_alloc.alloc(ir.Field, 1);
    inv_fields[0] = .{
        .name = try inv_alloc.dupe(u8, "."),
        .bit_width = 32,
        .domain = .{ .values = &.{"0xAA"} },
        .is_padding = false,
    };
    const inv_globals = try inv_alloc.alloc(ir.Global, 1);
    inv_globals[0] = .{
        .name = try inv_alloc.dupe(u8, "var"),
        .source_file = try inv_alloc.dupe(u8, "file1.c"),
        .size_bytes = 4,
        .is_static = true,
        .dims = &.{},
        .fields = inv_fields,
    };
    const inv = Invariant{ .globals = inv_globals, .arena = inv_arena };
    var apply_arena: std.heap.ArenaAllocator = .init(allocator);
    defer apply_arena.deinit();
    const result = try inv.applyToGlobals(allocator, apply_arena.allocator(), globals);
    defer allocator.free(result.func_symbols);
    // file1.c's "var" should have its domain updated.
    try std.testing.expect(globals.items[0].fields[0].domain == .values);
    // file2.c's "var" should remain unconstrained.
    try std.testing.expect(globals.items[1].fields[0].domain == .top);
}

test "applyToGlobals with .pointers returns func_symbols for unknown targets" {
    const allocator = std.testing.allocator;
    var globals = std.ArrayList(Parser.Global).empty;
    defer Parser.freeGlobals(allocator, &globals);

    const global_fields = try allocator.alloc(Parser.Field, 1);
    global_fields[0] = .{
        .name = try allocator.dupe(u8, ".fp"),
        .bit_width = 64,
        .is_padding = false,
        .domain = .top,
    };
    try globals.append(allocator, .{
        .name = try allocator.dupe(u8, "g"),
        .source_file = try allocator.dupe(u8, ""),
        .size_bytes = 8,
        .is_static = false,
        .dims = &.{},
        .fields = global_fields,
    });

    var inv_arena: std.heap.ArenaAllocator = .init(allocator);
    defer inv_arena.deinit();
    const inv_alloc = inv_arena.allocator();
    const inv_fields = try inv_alloc.alloc(ir.Field, 1);
    inv_fields[0] = .{
        .name = try inv_alloc.dupe(u8, ".fp"),
        .bit_width = 64,
        .domain = .{ .pointers = &.{"unknown_func"} },
        .is_padding = false,
    };
    const inv_globals = try inv_alloc.alloc(ir.Global, 1);
    inv_globals[0] = .{
        .name = try inv_alloc.dupe(u8, "g"),
        .source_file = try inv_alloc.dupe(u8, ""),
        .size_bytes = 8,
        .is_static = false,
        .dims = &.{},
        .fields = inv_fields,
    };
    const inv = Invariant{ .globals = inv_globals, .arena = inv_arena };

    var apply_arena: std.heap.ArenaAllocator = .init(allocator);
    defer apply_arena.deinit();
    const result = try inv.applyToGlobals(allocator, apply_arena.allocator(), globals);
    defer allocator.free(result.func_symbols);

    try std.testing.expect(globals.items[0].fields[0].domain == .pointers);
    try std.testing.expectEqual(@as(usize, 1), result.func_symbols.len);
    try std.testing.expectEqualStrings("unknown_func", result.func_symbols[0]);
}

test "applyToGlobals skips missing global gracefully" {
    const allocator = std.testing.allocator;
    var globals = std.ArrayList(Parser.Global).empty;
    defer Parser.freeGlobals(allocator, &globals);

    const global_fields = try allocator.alloc(Parser.Field, 1);
    global_fields[0] = .{
        .name = try allocator.dupe(u8, ".x"),
        .bit_width = 8,
        .is_padding = false,
        .domain = .top,
    };
    try globals.append(allocator, .{
        .name = try allocator.dupe(u8, "existing"),
        .source_file = try allocator.dupe(u8, ""),
        .size_bytes = 1,
        .is_static = false,
        .dims = &.{},
        .fields = global_fields,
    });

    var inv_arena: std.heap.ArenaAllocator = .init(allocator);
    defer inv_arena.deinit();
    const inv_alloc = inv_arena.allocator();
    const inv_fields = try inv_alloc.alloc(ir.Field, 1);
    inv_fields[0] = .{
        .name = try inv_alloc.dupe(u8, ".x"),
        .bit_width = 8,
        .domain = .{ .values = &.{"0xFF"} },
        .is_padding = false,
    };
    const inv_globals = try inv_alloc.alloc(ir.Global, 1);
    inv_globals[0] = .{
        .name = try inv_alloc.dupe(u8, "nonexistent"),
        .source_file = try inv_alloc.dupe(u8, ""),
        .size_bytes = 1,
        .is_static = false,
        .dims = &.{},
        .fields = inv_fields,
    };
    const inv = Invariant{ .globals = inv_globals, .arena = inv_arena };

    var apply_arena: std.heap.ArenaAllocator = .init(allocator);
    defer apply_arena.deinit();
    const result = try inv.applyToGlobals(allocator, apply_arena.allocator(), globals);
    defer allocator.free(result.func_symbols);

    // "existing" should remain unchanged since invariant targets "nonexistent"
    try std.testing.expect(globals.items[0].fields[0].domain == .top);
}

test "applyToGlobals skips missing field gracefully" {
    const allocator = std.testing.allocator;
    var globals = std.ArrayList(Parser.Global).empty;
    defer Parser.freeGlobals(allocator, &globals);

    const global_fields = try allocator.alloc(Parser.Field, 1);
    global_fields[0] = .{
        .name = try allocator.dupe(u8, ".x"),
        .bit_width = 8,
        .is_padding = false,
        .domain = .top,
    };
    try globals.append(allocator, .{
        .name = try allocator.dupe(u8, "g"),
        .source_file = try allocator.dupe(u8, ""),
        .size_bytes = 1,
        .is_static = false,
        .dims = &.{},
        .fields = global_fields,
    });

    var inv_arena: std.heap.ArenaAllocator = .init(allocator);
    defer inv_arena.deinit();
    const inv_alloc = inv_arena.allocator();
    const inv_fields = try inv_alloc.alloc(ir.Field, 1);
    inv_fields[0] = .{
        .name = try inv_alloc.dupe(u8, ".nonexistent_field"),
        .bit_width = 8,
        .domain = .{ .values = &.{"0xFF"} },
        .is_padding = false,
    };
    const inv_globals = try inv_alloc.alloc(ir.Global, 1);
    inv_globals[0] = .{
        .name = try inv_alloc.dupe(u8, "g"),
        .source_file = try inv_alloc.dupe(u8, ""),
        .size_bytes = 1,
        .is_static = false,
        .dims = &.{},
        .fields = inv_fields,
    };
    const inv = Invariant{ .globals = inv_globals, .arena = inv_arena };

    var apply_arena: std.heap.ArenaAllocator = .init(allocator);
    defer apply_arena.deinit();
    const result = try inv.applyToGlobals(allocator, apply_arena.allocator(), globals);
    defer allocator.free(result.func_symbols);

    // ".x" should remain unchanged since invariant targets ".nonexistent_field"
    try std.testing.expect(globals.items[0].fields[0].domain == .top);
}

test "uniqueKey returns name for non-static" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const key = try uniqueKey(arena.allocator(), "var", "file.c", false);
    try std.testing.expectEqualStrings("var", key);
}

test "uniqueKey returns source-prefixed key for static" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const key = try uniqueKey(arena.allocator(), "var", "file.c", true);
    try std.testing.expectEqualStrings("file.c\x00var", key);
}

test "init loads .zon invariant file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const zon_content =
        \\.{.{
        \\    .name = "g",
        \\    .source_file = "",
        \\    .size_bytes = 1,
        \\    .is_static = false,
        \\    .dims = .{},
        \\    .fields = .{.{
        \\        .name = ".x",
        \\        .offset_bits = 0,
        \\        .bit_width = 8,
        \\        .dims = .{},
        \\        .is_padding = false,
        \\        .domain = .top,
        \\    }},
        \\}}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "test.zon", .data = zon_content });
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const full_path = try std.fs.path.join(allocator, &.{ dir_path, "test.zon" });
    defer allocator.free(full_path);

    var inv = try Invariant.init(allocator, full_path);
    defer inv.deinit();

    try std.testing.expectEqual(@as(usize, 1), inv.globals.len);
    try std.testing.expectEqualStrings("g", inv.globals[0].name);
    try std.testing.expectEqual(@as(usize, 1), inv.globals[0].fields.len);
    try std.testing.expectEqualStrings(".x", inv.globals[0].fields[0].name);
}
