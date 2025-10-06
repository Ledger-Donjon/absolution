const aro = @import("aro");
const std = @import("std");

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

pub fn init(p: *Parser, allocator: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io) !void {
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
    p.comp = try aro.Compilation.initDefault(allocator, arena, io, &p.diagnostics, std.fs.cwd());
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

    p.toolchain = .{ .driver = &p.driver };
    errdefer p.toolchain.deinit();

    try p.toolchain.discover();
    try p.toolchain.defineSystemIncludes();
    // Finalize include search paths for the preprocessor (normally done in Driver.main).
    try p.driver.comp.initSearchPath(p.driver.includes.items, false);
    p.initialized = true;
}

pub fn deinit(p: *Parser) void {
    if (p.initialized) {
        p.toolchain.deinit();
        p.driver.deinit();
    }
    p.comp.deinit();
    p.diagnostics.deinit();
}

pub fn dump_variable(p: *Parser, tree: aro.Tree, variable: aro.Tree.Node.Variable, stdout: *std.fs.File.Writer) !void {
    // Check origin: ignore system/external includes
    // Print: name:type:sizeof(type)

    const name = tree.tokSlice(variable.name_tok);
    try dumpType(p, tree, name, variable.qt, stdout);
}

pub fn dump_globals(p: *Parser, path: []const u8) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    defer stdout.interface.flush() catch {};

    const source = try p.driver.comp.addSourceFromPath(path);
    const builtin = try p.driver.comp.generateBuiltinMacros(p.driver.system_defines);

    var pp = try aro.Preprocessor.initDefault(p.driver.comp);
    defer pp.deinit();
    pp.preprocessSources(.{ .main = source, .builtin = builtin }) catch |err| {
        for (p.driver.comp.diagnostics.output.to_list.messages.items) |msg| {
            try msg.write(&stdout.interface, .escape_codes, true);
        }
        return err;
    };
    var tree = try pp.parse();
    defer tree.deinit();

    // Iterate top-level declarations and print non-system, non-const globals
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

                try dump_variable(p, tree, variable, &stdout);
            },
            else => {},
        }
    }
}

fn getStructRecord(qt: aro.QualType, comp: *const aro.Compilation) ?aro.Type.Record {
    return switch (qt.base(comp).type) {
        .@"struct" => |record| record,
        else => null,
    };
}

fn dumpType(
    p: *Parser,
    tree: aro.Tree,
    prefix: []const u8,
    qt: aro.QualType,
    stdout: *std.fs.File.Writer,
) !void {
    // Records: expand fields recursively
    if (getStructRecord(qt, tree.comp)) |rec| {
        return dumpRecordFields(p, tree, rec, prefix, stdout);
    }
    // Fallback: scalar or non-record/array types -> print total sizeof
    if (qt.sizeofOrNull(tree.comp)) |sz| {
        stdout.interface.print("{s}:{d}\n", .{ prefix, sz }) catch {};
    } else {
        stdout.interface.print("{s}:?\n", .{prefix}) catch {};
    }
    // Arrays of records: expand element record fields once with [] suffix
    if (qt.get(tree.comp, .array)) |arr| {
        if (arr.elem.getRecord(tree.comp)) |rec| {
            try dumpRecordFields(p, tree, rec, prefix, stdout);
        }
    }
}

fn dumpRecordFields(
    p: *Parser,
    tree: aro.Tree,
    record: aro.Type.Record,
    prefix: []const u8,
    stdout: *std.fs.File.Writer,
) std.mem.Allocator.Error!void {
    for (record.fields) |field| {
        var field_name: []const u8 = undefined;
        if (field.name_tok != 0) {
            const fname = tree.tokSlice(field.name_tok);
            field_name = try std.fmt.allocPrint(p.arena, "{s}.{s}", .{ prefix, fname });
        } else {
            field_name = prefix;
        }
        try dumpType(p, tree, field_name, field.qt, stdout);
    }
}
