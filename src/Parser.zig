//! C translation unit parser for global variable extraction.
//!
//! Uses the aro compiler frontend to parse C files and extract non-const
//! global variables along with their field layouts, padding, and array
//! dimensions.

const aro = @import("aro");
const std = @import("std");
const cgen_tree = @import("cgen/tree.zig");
const include_paths = @import("include_paths.zig");
const type_flatten = @import("type_flatten.zig");

const ParseError = std.mem.Allocator.Error;

pub const Domain = cgen_tree.Domain;
pub const ParsedField = cgen_tree.Field;
pub const ParsedGlobal = cgen_tree.Global;

const Fields = std.ArrayListUnmanaged(ParsedField);

/// C parser built on aro, specialized for extracting global variables.
///
/// Wraps aro's Compilation, Driver, and Toolchain to provide a simpler API
/// for parsing translation units and collecting non-const globals with their
/// flattened field layouts.
const Parser = @This();
// Struct parameters
allocator: std.mem.Allocator,
arena: std.mem.Allocator,
diagnostics: aro.Diagnostics,
comp: aro.Compilation,
driver: aro.Driver,
toolchain: aro.Toolchain,
initialized: bool = false,

/// Initialize the parser, discover the toolchain, and prime diagnostics.
/// Args:
///   allocator: General-purpose allocator used for long-lived buffers.
///   arena: Short-lived arena used by aro internals.
pub fn init(allocator: std.mem.Allocator, arena: std.mem.Allocator) !*Parser {
    const p = try allocator.create(Parser);
    errdefer allocator.destroy(p);

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
    p.comp = try aro.Compilation.initDefault(allocator, arena, &p.diagnostics, std.fs.cwd());
    errdefer p.comp.deinit();
    // Match `zig cc` more closely (clang frontend defaults).
    p.comp.langopts.setEmulatedCompiler(.clang);
    p.comp.langopts.standard = .gnu17;

    // Compute resource_dir relative to executable and store a duped copy
    const exe_path = try std.fs.selfExePathAlloc(p.allocator);
    defer p.allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse unreachable;
    const resource_dir = std.fs.path.dirname(exe_dir) orelse unreachable;
    const resource_dir_dupe = try p.comp.arena.dupe(u8, resource_dir);

    // Initialize driver and toolchain using stable self pointers
    p.driver = .{ .comp = &p.comp, .aro_name = "fuzzmate", .diagnostics = &p.diagnostics, .resource_dir = resource_dir_dupe };
    errdefer p.driver.deinit();
    p.toolchain = .{ .driver = &p.driver, .filesystem = .{ .fake = &.{} } };
    errdefer p.toolchain.deinit();
    try p.toolchain.discover();

    // Suppress aro's default include paths; we configure them ourselves to
    // match `zig cc` behavior using the bundled sysroot under `<prefix>/lib/...`.
    p.driver.nostdinc = true;
    p.driver.nostdlibinc = true;
    p.driver.nobuiltininc = true;

    // Configure include search order from the bundled sysroot.
    try include_paths.addZigCcImplicitIncludes(&p.comp, resource_dir_dupe);

    p.initialized = true;

    return p;
}

/// Tear down toolchain state and diagnostics if previously initialized.
/// Safe to call exactly once per `init`.
pub fn deinit(p: *Parser) void {
    if (p.initialized) {
        p.toolchain.deinit();
        p.driver.deinit();
    }
    p.comp.deinit();
    p.diagnostics.deinit();

    const allocator = p.allocator;
    allocator.destroy(p);
}

pub fn free_globals(allocator: std.mem.Allocator, globals: *std.ArrayList(ParsedGlobal)) void {
    for (globals.items) |*g| {
        g.deinit(allocator);
    }
    globals.deinit(allocator);
}

/// Check if a type is effectively const, including arrays of const elements.
/// This handles cases like `const T arr[N]` where the top-level array type
/// may not be const but the element type is.
fn isEffectivelyConst(comp: *aro.Compilation, qt: aro.QualType) bool {
    // Check top-level const
    if (qt.@"const") return true;

    // Peel through arrays to check element type constness
    var current = qt;
    while (current.get(comp, .array)) |arr| {
        current = arr.elem;
        if (current.@"const") return true;
    }

    return false;
}

/// Preprocess source file using `zig cc -E`, falling back to direct parsing.
/// Returns the source and optionally the path to a temp file to delete afterward.
fn preprocessSource(
    p: *Parser,
    path: []const u8,
) !struct { source: aro.Source, pp_to_delete: ?[]const u8 } {
    const gpa = p.driver.comp.gpa;
    const explicit_zig = std.process.getEnvVarOwned(gpa, "FUZZMATE_ZIG") catch null;
    defer if (explicit_zig) |v| gpa.free(v);

    const zig_exe = if (explicit_zig) |v| v else "zig";

    // Write preprocessed output to disk to avoid buffering huge stdout in memory.
    const pp_dir = ".zig-cache/fuzzmate";
    std.fs.cwd().makePath(pp_dir) catch return .{
        .source = try p.driver.comp.addSourceFromPath(path),
        .pp_to_delete = null,
    };

    const pp_rel_path = try std.fmt.allocPrint(p.comp.arena, "{s}/pp-{d}.i", .{ pp_dir, std.time.nanoTimestamp() });
    var pp_file = std.fs.cwd().createFile(pp_rel_path, .{ .truncate = true }) catch return .{
        .source = try p.driver.comp.addSourceFromPath(path),
        .pp_to_delete = null,
    };
    defer pp_file.close();

    var argv = [_][]const u8{ zig_exe, "cc", "-E", path };
    var child = std.process.Child.init(&argv, gpa);
    child.expand_arg0 = if (explicit_zig != null) .no_expand else .expand;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return .{
        .source = try p.driver.comp.addSourceFromPath(path),
        .pp_to_delete = null,
    };

    var buf: [64 * 1024]u8 = undefined;
    const child_stdout = child.stdout.?;
    while (true) {
        const n = try child_stdout.read(&buf);
        if (n == 0) break;
        try pp_file.writeAll(buf[0..n]);
    }

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return .{
            .source = try p.driver.comp.addSourceFromPath(path),
            .pp_to_delete = null,
        },
        else => return .{
            .source = try p.driver.comp.addSourceFromPath(path),
            .pp_to_delete = null,
        },
    }

    return .{
        .source = try p.driver.comp.addSourceFromPath(pp_rel_path),
        .pp_to_delete = pp_rel_path,
    };
}

/// Collect non-const, user-defined globals along with their bit widths.
pub fn collect_globals(p: *Parser, path: []const u8, allocator: std.mem.Allocator) !std.ArrayList(ParsedGlobal) {
    // To match `zig cc` include semantics and avoid frontend differences in
    // complex header stacks, prefer preprocessing the translation unit with
    // `zig cc -E` when possible.
    const pp_result = try preprocessSource(p, path);
    defer if (pp_result.pp_to_delete) |pp_path| std.fs.cwd().deleteFile(pp_path) catch {};

    const builtin = try p.driver.comp.generateBuiltinMacros(p.driver.system_defines);
    var pp = try aro.Preprocessor.initDefault(p.driver.comp);
    defer pp.deinit();
    pp.preprocessSources(&.{ pp_result.source, builtin }) catch |err| {
        // Print compilation errors
        var stdout_buf: [1024]u8 = undefined;
        var stdout = std.fs.File.stdout().writer(&stdout_buf);
        defer _ = stdout.interface.flush() catch {};
        for (p.driver.comp.diagnostics.output.to_list.messages.items) |msg| {
            try msg.write(&stdout.interface, .escape_codes, true);
        }
        return err;
    };
    var tree = try pp.parse();
    defer tree.deinit();

    var globals = std.ArrayList(ParsedGlobal).empty;
    errdefer free_globals(allocator, &globals);

    for (tree.root_decls.items) |idx| {
        const node = idx.get(&tree);
        switch (node) {
            .variable => |variable| {
                const loc = tree.tokens.items(.loc)[variable.name_tok];
                const expanded = loc.expand(p.driver.comp);
                // Ignore system variables
                if (expanded.kind != .user) continue;
                // Ignore const-qualified objects (including arrays of const elements)
                if (isEffectivelyConst(tree.comp, variable.qt)) continue;
                // Ignore incomplete types
                if (variable.qt.hasIncompleteSize(tree.comp)) continue;

                const name_slice = tree.tokSlice(variable.name_tok);
                const copied_name = try allocator.dupe(u8, name_slice);
                errdefer allocator.free(copied_name);

                var peeled = try type_flatten.peelTopLevelArrayDims(allocator, tree, variable.qt);
                errdefer peeled.dims.deinit(allocator);

                var fields = Fields{};
                errdefer {
                    for (fields.items) |*f| f.deinit(allocator);
                    fields.deinit(allocator);
                }

                try type_flatten.flattenGlobal(allocator, tree, peeled.qt, &fields);

                try globals.append(allocator, .{ .name = copied_name, .dims = peeled.dims, .fields = fields });
            },
            else => {},
        }
    }

    return globals;
}
