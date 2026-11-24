//! Build-time tuning of the discovered model: zero lists and domain overrides.
//!
//! Both are applied to the parsed globals in the same run that generates the
//! harness, after the optional `.zon` invariant, so the sampler and the exported
//! `.zon` already carry the tuned domains. No second generate-and-rebuild pass.
//!
//! Zero list (one selector per line, `#` comments):
//!
//!     g_ctx                 every global named g_ctx
//!     g_ctx@src/feature.c   only the one whose source path contains src/feature.c
//!
//! A matched global gets a single all-zero `whole_values` candidate on every
//! field, so it leaves the fuzzable prefix without consuming input bytes.
//!
//! Domain overrides (one per line, `#` comments):
//!
//!     appState. = values \x00 \x01 \x02
//!     txContext.txType = values \x00 \x01 \x02 \x04 \xc0
//!     challenge. = top
//!     G_context.state = enum app_state_t
//!
//! The selector splits on the first dot: `g.a.b` is field `.a.b` of global `g`,
//! `g.` is the whole scalar. Each value is a byte string (`\xNN` escapes); the
//! emitter zero-pads values shorter than the field element. `enum T` takes the
//! enumerators of the C enum `T` (tag or typedef name) found in the parsed
//! sources, encoded little-endian at the field's width.

const std = @import("std");
const ir = @import("cgen/ir.zig");
const Parser = @import("Parser.zig");

pub const ZeroSymbol = struct {
    name: []const u8,
    source: ?[]const u8,
    /// Selectors from a lenient list are not reported when they match nothing.
    lenient: bool,
};

pub const Override = struct {
    global: []const u8,
    field: []const u8,
    domain: ir.Domain,
    /// Set for `= enum T`; `apply` resolves it into a `values` domain.
    enum_type: ?[]const u8 = null,
    file: []const u8,
    line: usize,
};

pub const ParseError = error{InvalidOverride} || std.mem.Allocator.Error;

/// Parse a zero-symbol list.
pub fn parseZeroSymbols(arena: std.mem.Allocator, text: []const u8, lenient: bool) ![]ZeroSymbol {
    var out: std.ArrayList(ZeroSymbol) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, line, '@')) |at| {
            try out.append(arena, .{
                .name = std.mem.trim(u8, line[0..at], " \t"),
                .source = std.mem.trim(u8, line[at + 1 ..], " \t"),
                .lenient = lenient,
            });
        } else {
            try out.append(arena, .{ .name = line, .source = null, .lenient = lenient });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Decode one value token: `\xNN` and `\\` escapes, every other byte literal.
pub fn decodeValue(arena: std.mem.Allocator, token: []const u8) ParseError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < token.len) {
        if (token[i] == '\\' and i + 1 < token.len) {
            if (token[i + 1] == 'x') {
                if (i + 4 > token.len) return error.InvalidOverride;
                const byte = std.fmt.parseInt(u8, token[i + 2 .. i + 4], 16) catch return error.InvalidOverride;
                try out.append(arena, byte);
                i += 4;
                continue;
            }
            if (token[i + 1] == '\\') {
                try out.append(arena, '\\');
                i += 2;
                continue;
            }
        }
        try out.append(arena, token[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// Parse a domain-overrides file. `file` is kept for diagnostics.
pub fn parseOverrides(arena: std.mem.Allocator, text: []const u8, file: []const u8) ParseError![]Override {
    var out: std.ArrayList(Override) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            std.debug.print("{s}:{d}: error: expected '<global>.<field> = values ...|top|enum <T>'\n", .{ file, line_no });
            return error.InvalidOverride;
        };
        const selector = std.mem.trim(u8, line[0..eq], " \t");
        const dot = std.mem.indexOfScalar(u8, selector, '.') orelse {
            std.debug.print("{s}:{d}: error: selector '{s}' has no '.' (use '{s}.' for the whole global)\n", .{ file, line_no, selector, selector });
            return error.InvalidOverride;
        };
        const global = selector[0..dot];
        const field = try std.fmt.allocPrint(arena, ".{s}", .{selector[dot + 1 ..]});

        var rhs = std.mem.tokenizeAny(u8, line[eq + 1 ..], " \t");
        const kind = rhs.next() orelse {
            std.debug.print("{s}:{d}: error: missing domain after '='\n", .{ file, line_no });
            return error.InvalidOverride;
        };

        var domain: ir.Domain = undefined;
        var enum_type: ?[]const u8 = null;
        if (std.mem.eql(u8, kind, "top")) {
            if (rhs.next() != null) {
                std.debug.print("{s}:{d}: error: 'top' takes no values\n", .{ file, line_no });
                return error.InvalidOverride;
            }
            domain = .top;
        } else if (std.mem.eql(u8, kind, "values")) {
            var vals: std.ArrayList([]const u8) = .empty;
            while (rhs.next()) |tok| {
                const v = decodeValue(arena, tok) catch {
                    std.debug.print("{s}:{d}: error: bad value '{s}'\n", .{ file, line_no, tok });
                    return error.InvalidOverride;
                };
                try vals.append(arena, v);
            }
            if (vals.items.len == 0) {
                std.debug.print("{s}:{d}: error: 'values' needs at least one value\n", .{ file, line_no });
                return error.InvalidOverride;
            }
            domain = .{ .values = try vals.toOwnedSlice(arena) };
        } else if (std.mem.eql(u8, kind, "enum")) {
            enum_type = rhs.next();
            if (enum_type == null or rhs.next() != null) {
                std.debug.print("{s}:{d}: error: 'enum' takes exactly one type name\n", .{ file, line_no });
                return error.InvalidOverride;
            }
            domain = .top;
        } else {
            std.debug.print("{s}:{d}: error: unknown domain '{s}' (expected 'values', 'top' or 'enum')\n", .{ file, line_no, kind });
            return error.InvalidOverride;
        }

        try out.append(arena, .{
            .global = global,
            .field = field,
            .domain = domain,
            .enum_type = enum_type,
            .file = file,
            .line = line_no,
        });
    }
    return out.toOwnedSlice(arena);
}

pub const Report = struct {
    total: usize,
    zeroed: usize,
    overridden: usize,
    /// Strict zero selectors that matched no global (misspelled or renamed).
    stale_zeros: []const ZeroSymbol,
    /// Overrides that matched no field. The caller treats these as fatal.
    unmatched: []const Override,
};

fn zeroMatches(z: ZeroSymbol, g: Parser.Global) bool {
    if (!std.mem.eql(u8, z.name, g.name)) return false;
    const src = z.source orelse return true;
    return std.mem.indexOf(u8, g.source_file, src) != null;
}

/// One little-endian `width`-byte value per distinct enumerator.
fn enumDomain(arena: std.mem.Allocator, values: []const i128, width: usize) !ir.Domain {
    var out: std.ArrayList([]const u8) = .empty;
    next: for (values) |v| {
        const b = try arena.alloc(u8, width);
        var x: u128 = @bitCast(v);
        for (b) |*byte| {
            byte.* = @truncate(x);
            x >>= 8;
        }
        for (out.items) |seen| if (std.mem.eql(u8, seen, b)) continue :next;
        try out.append(arena, b);
    }
    return .{ .values = try out.toOwnedSlice(arena) };
}

/// Apply zero lists, then overrides (overrides win), to `globals` in place.
/// `enums` resolves `= enum T` overrides.
pub fn apply(
    arena: std.mem.Allocator,
    globals: []Parser.Global,
    zeros: []const ZeroSymbol,
    overrides: []const Override,
    enums: *const Parser.EnumTable,
) !Report {
    const zero_hit = try arena.alloc(bool, zeros.len);
    @memset(zero_hit, false);
    const override_hit = try arena.alloc(bool, overrides.len);
    @memset(override_hit, false);

    var zeroed: usize = 0;
    for (globals) |*g| {
        var matched = false;
        for (zeros, 0..) |z, zi| {
            if (zeroMatches(z, g.*)) {
                zero_hit[zi] = true;
                matched = true;
            }
        }
        if (!matched) continue;
        zeroed += 1;
        for (g.fields) |*f| {
            if (f.is_padding) continue;
            const blob = try arena.alloc(u8, ir.wholeFieldBytes(f.*));
            @memset(blob, 0);
            const blobs = try arena.alloc([]const u8, 1);
            blobs[0] = blob;
            f.domain = .{ .whole_values = blobs };
        }
    }

    var overridden: usize = 0;
    for (overrides, 0..) |o, oi| {
        const enum_vals = if (o.enum_type) |t| enums.get(t) orelse {
            std.debug.print("{s}:{d}: error: enum '{s}' not found in the parsed sources\n", .{ o.file, o.line, t });
            return error.UnknownEnum;
        } else null;
        for (globals) |*g| {
            if (!std.mem.eql(u8, g.name, o.global)) continue;
            for (g.fields) |*f| {
                if (f.is_padding or !std.mem.eql(u8, f.name, o.field)) continue;
                const domain = if (enum_vals) |vals| try enumDomain(arena, vals, ir.elementBytes(f.*)) else o.domain;
                try f.updateDomain(arena, domain);
                override_hit[oi] = true;
                overridden += 1;
            }
        }
    }

    var stale: std.ArrayList(ZeroSymbol) = .empty;
    for (zeros, zero_hit) |z, hit| {
        if (!hit and !z.lenient) try stale.append(arena, z);
    }
    var unmatched: std.ArrayList(Override) = .empty;
    for (overrides, override_hit) |o, hit| {
        if (!hit) try unmatched.append(arena, o);
    }

    return .{
        .total = globals.len,
        .zeroed = zeroed,
        .overridden = overridden,
        .stale_zeros = try stale.toOwnedSlice(arena),
        .unmatched = try unmatched.toOwnedSlice(arena),
    };
}

fn testGlobal(alloc: std.mem.Allocator, name: []const u8, src: []const u8, field_names: []const []const u8) !Parser.Global {
    const fields = try alloc.alloc(Parser.Field, field_names.len);
    for (field_names, 0..) |fname, i| {
        fields[i] = .{ .name = try alloc.dupe(u8, fname), .bit_width = 8, .domain = .top };
    }
    return .{
        .name = try alloc.dupe(u8, name),
        .source_file = try alloc.dupe(u8, src),
        .size_bytes = field_names.len,
        .is_static = false,
        .dims = &.{},
        .fields = fields,
    };
}

test "decodeValue handles hex escapes and literals" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xc0 }, try decodeValue(a, "\\x00\\xc0"));
    try std.testing.expectEqualSlices(u8, "ab", try decodeValue(a, "ab"));
    try std.testing.expectEqualSlices(u8, "\\", try decodeValue(a, "\\\\"));
    try std.testing.expectError(error.InvalidOverride, decodeValue(a, "\\xZZ"));
    try std.testing.expectError(error.InvalidOverride, decodeValue(a, "\\x0"));
}

test "parseOverrides splits the selector on the first dot" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ovs = try parseOverrides(a,
        \\# comment
        \\appState. = values \x00 \x01
        \\g_ctx.metadata.op_type = top
    , "test");
    try std.testing.expectEqual(@as(usize, 2), ovs.len);
    try std.testing.expectEqualStrings("appState", ovs[0].global);
    try std.testing.expectEqualStrings(".", ovs[0].field);
    try std.testing.expectEqual(@as(usize, 2), ovs[0].domain.values.len);
    try std.testing.expectEqualStrings("g_ctx", ovs[1].global);
    try std.testing.expectEqualStrings(".metadata.op_type", ovs[1].field);
    try std.testing.expect(ovs[1].domain == .top);
}

test "parseOverrides rejects unknown domains" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidOverride, parseOverrides(arena.allocator(), "g. = maybe", "test"));
    try std.testing.expectError(error.InvalidOverride, parseOverrides(arena.allocator(), "g. = enum", "test"));
    try std.testing.expectError(error.InvalidOverride, parseOverrides(arena.allocator(), "g. = enum a b", "test"));
}

test "apply resolves enum overrides at the field width" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var globals = [_]Parser.Global{try testGlobal(a, "g_ctx", "src/app.c", &.{ ".state", ".mode" })};
    globals[0].fields[0].bit_width = 16;

    var enums: Parser.EnumTable = .empty;
    try enums.put(a, "state_t", &.{ 0, 0x102, 0x102, -1 });

    const ovs = try parseOverrides(a,
        \\g_ctx.state = enum state_t
        \\g_ctx.mode = enum state_t
    , "test");
    try std.testing.expectEqualStrings("state_t", ovs[0].enum_type.?);
    _ = try apply(a, &globals, &.{}, ovs, &enums);

    // Duplicates collapse; values are little-endian at each field's width.
    const st = globals[0].fields[0].domain.values;
    try std.testing.expectEqual(@as(usize, 3), st.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00 }, st[0]);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x01 }, st[1]);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff }, st[2]);
    try std.testing.expectEqual(@as(usize, 3), globals[0].fields[1].domain.values.len);

    const bad = try parseOverrides(a, "g_ctx.state = enum nope_t", "test");
    try std.testing.expectError(error.UnknownEnum, apply(a, &globals, &.{}, bad, &enums));
}

test "apply zeroes, then overrides, and reports leftovers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var globals = [_]Parser.Global{
        try testGlobal(a, "g_state", "src/app.c", &.{"."}),
        try testGlobal(a, "g_ctx", "src/feature.c", &.{ ".a", ".b" }),
        try testGlobal(a, "g_ctx", "src/other.c", &.{ ".a", ".b" }),
    };

    const zeros = try parseZeroSymbols(a,
        \\g_ctx@src/feature.c
        \\g_missing
    , false);
    const lenient = try parseZeroSymbols(a, "g_not_in_this_app", true);
    const all_zeros = try std.mem.concat(a, ZeroSymbol, &.{ zeros, lenient });

    const ovs = try parseOverrides(a,
        \\g_state. = values \x00 \x01
        \\g_ctx.b = top
        \\g_ctx.nope = top
    , "test");

    const rep = try apply(a, &globals, all_zeros, ovs, &.empty);

    try std.testing.expectEqual(@as(usize, 1), rep.zeroed);
    try std.testing.expect(globals[0].fields[0].domain == .values);
    // feature.c's g_ctx: .a zeroed, .b re-opened by the override.
    try std.testing.expect(globals[1].fields[0].domain == .whole_values);
    try std.testing.expect(globals[1].fields[1].domain == .top);
    // other.c's g_ctx is not zeroed.
    try std.testing.expect(globals[2].fields[0].domain == .top);

    try std.testing.expectEqual(@as(usize, 1), rep.stale_zeros.len);
    try std.testing.expectEqualStrings("g_missing", rep.stale_zeros[0].name);
    try std.testing.expectEqual(@as(usize, 1), rep.unmatched.len);
    try std.testing.expectEqualStrings(".nope", rep.unmatched[0].field);
}
