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

pub const Domain = cgen_tree.Domain;
pub const Field = cgen_tree.Field;
pub const Global = cgen_tree.Global;

const ParseError = std.mem.Allocator.Error;
const FieldsBuilder = std.ArrayListUnmanaged(Field);

/// C parser built on aro, specialized for extracting global variables.
///
/// Wraps aro's Compilation, Driver, and Toolchain to provide a simpler API
/// for parsing translation units and collecting non-const globals with their
/// flattened field layouts.
const Parser = @This();
// Struct parameters
gpa: std.mem.Allocator,
arena: std.mem.Allocator,
diagnostics: *aro.Diagnostics,
toolchain: aro.Toolchain,
computed_sources: [4]aro.Source = undefined,

/// Initialize the parser, discover the toolchain, and prime diagnostics.
/// Args:
///   gpa: General-purpose allocator used for long-lived buffers.
///   arena: Short-lived arena used by aro internals.
///   cflags: C compiler flags forwarded to aro's driver (e.g. `-I`, `-D`, `-fshort-enums`).
pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator, cflags: []const []const u8) !Parser {
    // Initialize base fields in-place so self-references are valid from the start
    const diag = try gpa.create(aro.Diagnostics);
    diag.* = .{
        .output = .{ .to_list = .{ .arena = .init(gpa) } },
        .state = .{ .enable_all_warnings = false },
    };
    errdefer quickDestroy(gpa, diag);

    // Create compilation with diagnostics pointing at final storage
    var comp = try gpa.create(aro.Compilation);
    comp.* = try aro.Compilation.initDefault(gpa, arena, diag, std.fs.cwd());
    errdefer quickDestroy(gpa, comp);
    // Use clang frontend defaults (same as zig cc).
    comp.langopts.setEmulatedCompiler(.clang);

    // Compute resource_dir relative to executable and store a duped copy
    const exe_path = try std.fs.selfExePathAlloc(gpa);
    defer gpa.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse unreachable;
    const resource_dir = std.fs.path.dirname(exe_dir) orelse unreachable;
    const resource_dir_dupe = try comp.arena.dupe(u8, resource_dir);

    // Initialize driver and toolchain using stable self pointers
    var driver = try gpa.create(aro.Driver);
    driver.* = .{ .comp = comp, .aro_name = "absolution", .diagnostics = diag, .resource_dir = resource_dir_dupe };
    errdefer quickDestroy(gpa, driver);
    var toolchain: aro.Toolchain = .{ .driver = driver, .filesystem = .{ .fake = &.{} } };
    errdefer toolchain.deinit();
    try toolchain.discover();

    // Suppress aro's default include paths; we configure them ourselves to
    // match `zig cc` behavior using the bundled sysroot under `<prefix>/lib/...`.
    driver.nostdinc = true;
    driver.nostdlibinc = true;
    driver.nobuiltininc = true;

    // Configure include search order from the bundled sysroot.
    try include_paths.addZigCcImplicitIncludes(driver.comp, resource_dir_dupe);

    // Add compatibility macros for LLVM/Clang 18+ headers.
    // __building_module(x) is a Clang builtin that returns 0 unless building a specific
    // Clang module. Aro doesn't support Clang modules, so we define it to always return 0.
    // This is required for Zig 0.15.2+ which ships LLVM 18+ headers that use this macro.
    const compat_source = try driver.comp.addSourceFromBuffer("<compat>",
        \\// Compatibility macros for LLVM/Clang 18+ headers
        \\#define __building_module(x) 0
        \\
    );
    // We call buildUserMacros before generateBuiltinMacros as calling parseArgs will
    // update the driver state
    const user_macros = try buildUserMacros(toolchain, cflags, gpa);
    const builtin_source = try driver.comp.generateBuiltinMacros(driver.system_defines);
    const empty_main = try toolchain.driver.comp.addSourceFromBuffer("<absolution>", "\n");

    return .{
        .gpa = gpa,
        .arena = arena,
        .diagnostics = diag,
        .toolchain = toolchain,
        .computed_sources = .{ empty_main, builtin_source, compat_source, user_macros },
    };
}

/// Build a synthetic source containing user-defined macros from C compiler flags.
/// Forwards -I, -D, -f*, -std=, and other flags to aro's Driver.
fn buildUserMacros(toolchain: aro.Toolchain, cflags: []const []const u8, allocator: std.mem.Allocator) !aro.Source {
    if (cflags.len == 0) return toolchain.driver.comp.addSourceFromBuffer("<no cflags>", "\n");
    // Driver.parseArgs expects argv format where index 0 is the program name.
    // Prepend a dummy program name so the flags start at index 1.
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.append(allocator, "absolution");
    try args.appendSlice(allocator, cflags);

    var stdout_buf: [0]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buf);
    var user_macro: std.ArrayList(u8) = .empty;
    defer user_macro.deinit(toolchain.driver.comp.gpa);
    // Pass our macro_buf so -D/-U flags accumulate there for later use.
    _ = try toolchain.driver.parseArgs(&stdout, &user_macro, args.items);
    const user_macro_buf = try user_macro.toOwnedSlice(allocator);
    defer allocator.free(user_macro_buf);
    // Converted to a source via `addSourceFromBuffer`
    return try toolchain.driver.comp.addSourceFromBuffer("<command line>", user_macro_buf);
}

fn quickDestroy(allocator: std.mem.Allocator, ptr: anytype) void {
    ptr.deinit();
    allocator.destroy(ptr);
}

/// Tear down toolchain state and diagnostics if previously initialized.
/// Safe to call exactly once per `init`.
pub fn deinit(p: *Parser) void {
    var driver: *aro.Driver = p.toolchain.driver;
    var comp: *aro.Compilation = driver.comp;
    var diag: *aro.Diagnostics = p.diagnostics;

    p.toolchain.deinit();
    comp.deinit();
    driver.deinit();
    diag.deinit();

    p.gpa.destroy(comp);
    p.gpa.destroy(driver);
    p.gpa.destroy(diag);

    p.* = undefined;
}

/// Free all globals and their owned fields, then deinit the list itself.
pub fn freeGlobals(allocator: std.mem.Allocator, globals: *std.ArrayList(Global)) void {
    for (globals.items) |*g| g.deinit(allocator);
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

/// Collect globals from every target file.
pub fn collectGlobals(p: *Parser, paths: []const []const u8) !std.ArrayList(Global) {
    var source_list: std.ArrayList(aro.Source) = .empty;
    defer source_list.deinit(p.gpa);

    try source_list.appendSlice(p.gpa, &p.computed_sources);

    for (paths) |path| {
        const src = try p.toolchain.driver.comp.addSourceFromPath(path);
        try source_list.append(p.gpa, src);
    }

    var pp = try aro.Preprocessor.initDefault(p.toolchain.driver.comp);
    defer pp.deinit();
    pp.preprocessSources(source_list.items) catch |err| {
        printDiagnostics(p.toolchain.driver.comp);
        return err;
    };

    var tree = try pp.parse();
    defer tree.deinit();

    return try collectGlobalsFromTree(p.toolchain.driver.comp, tree, p.gpa);
}

/// Go through an entire Tree and extracts its globals.
/// Non-static globals that have already been seen (tracked via `seen_globals`)
/// are skipped to avoid duplicate extern declarations in the generated fuzzer.
fn collectGlobalsFromTree(comp: *aro.Compilation, tree: aro.Tree, gpa: std.mem.Allocator) !std.ArrayList(Global) {
    var globals: std.ArrayList(Global) = .empty;
    errdefer freeGlobals(gpa, &globals);
    // prevent number of reallocations on big compilation units
    try globals.ensureTotalCapacity(gpa, tree.root_decls.items.len);

    // Track non-static globals already collected so that the same linker
    // symbol appearing in multiple translation units is emitted only once.
    var seen: std.StringHashMap(void) = .init(gpa);
    defer seen.deinit();

    var fields_builder: FieldsBuilder = .empty;
    defer fields_builder.deinit(gpa);

    for (tree.root_decls.items) |idx| {
        const node = idx.get(&tree);
        if (node != .variable) continue;
        const variable = node.variable;
        const loc = tree.tokens.items(.loc)[variable.name_tok];
        const expanded = loc.expand(comp);
        if (expanded.kind != .user) continue;
        if (isEffectivelyConst(tree.comp, variable.qt)) continue;
        if (variable.qt.hasIncompleteSize(tree.comp)) continue;

        // Non-static globals share a single linker symbol across all
        // translation units.  If we already collected one with this
        // name, skip the duplicate and warn.
        const variable_name = tree.tokSlice(variable.name_tok);
        if (variable.storage_class != .static) {
            const res = try seen.getOrPut(variable_name);
            if (res.found_existing) continue;
        }

        const size_val = variable.qt.sizeofOrNull(tree.comp) orelse continue;
        const size_bytes: u64 = @intCast(size_val);

        const peeled = try type_flatten.peelTopLevelArrayDims(gpa, tree, variable.qt);
        errdefer gpa.free(peeled.dims);

        fields_builder.clearRetainingCapacity();
        try type_flatten.flattenGlobal(gpa, tree, peeled.qt, &fields_builder);

        const fields = try gpa.dupe(Field, fields_builder.items);
        errdefer gpa.free(fields);

        try globals.append(gpa, .{
            .name = try gpa.dupe(u8, variable_name),
            .source_file = try gpa.dupe(u8, expanded.path),
            .size_bytes = size_bytes,
            .is_static = variable.storage_class == .static,
            .dims = peeled.dims,
            .fields = fields,
        });
    }

    return globals;
}

/// Print accumulated aro diagnostics to stdout.
fn printDiagnostics(comp: *aro.Compilation) void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    defer _ = stdout.interface.flush() catch {};
    for (comp.diagnostics.output.to_list.messages.items) |msg| {
        msg.write(&stdout.interface, .escape_codes, true) catch {};
    }
}
