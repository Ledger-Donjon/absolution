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
pub const Field = cgen_tree.Field;
pub const Global = cgen_tree.Global;

const FieldsBuilder = std.ArrayListUnmanaged(Field);

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
/// Lazily-generated builtin macros; null until first parse. Generated after
/// addCFlags() so that -std= takes effect before builtin generation.
builtin_source: ?aro.Source = null,
compat_source: aro.Source,
/// User -D/-U define text accumulated as `#define`/`#undef` lines by arocc's
/// Driver.parseArgs().
user_macro_source: ?aro.Source = null,
initialized: bool = false,

/// Initialize the parser, discover the toolchain, and prime diagnostics.
/// Args:
///   allocator: General-purpose allocator used for long-lived buffers.
///   arena: Short-lived arena used by aro internals.
pub fn new(allocator: std.mem.Allocator, arena: std.mem.Allocator, cflags: []const []const u8) !*Parser {
    const p = try allocator.create(Parser);
    errdefer allocator.destroy(p);

    // Initialize base fields in-place so self-references are valid from the start
    p.* = .{
        .allocator = allocator,
        .arena = arena,
        .diagnostics = .{
            .output = .{ .to_list = .{ .arena = .init(allocator) } },
            .state = .{ .enable_all_warnings = false },
        },
        .comp = undefined,
        .driver = undefined,
        .toolchain = undefined,
        .builtin_source = null,
        .compat_source = undefined,
        .user_macro_source = null,
        .initialized = false,
    };
    errdefer p.diagnostics.deinit();

    // Create compilation with diagnostics pointing at final storage
    p.comp = try aro.Compilation.initDefault(allocator, arena, &p.diagnostics, std.fs.cwd());
    errdefer p.comp.deinit();
    // Use clang frontend defaults (same as zig cc).
    p.comp.langopts.setEmulatedCompiler(.clang);
    p.comp.langopts.standard = .c23;

    // Pre-allocate aro's generated_buf to prevent reallocation.
    //
    // The StringInterner stores []const u8 slices pointing into generated_buf.
    // If generated_buf's ArrayList grows and reallocates, the old backing
    // memory is freed, leaving the StringInterner with dangling pointers.
    // Pre-allocating avoids this class of bugs entirely.
    try p.comp.generated_buf.ensureTotalCapacity(allocator, 32 * 1024 * 1024);

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
    try include_paths.addZigCcImplicitIncludes(p.driver.comp, resource_dir_dupe);

    // Note: builtin_source is generated lazily in collect_all_globals(),
    // after addCFlags() has been called, so -std= takes effect first.

    // Add compatibility macros for LLVM/Clang 18+ headers.
    // __building_module(x) is a Clang builtin that returns 0 unless building a specific
    // Clang module. Aro doesn't support Clang modules, so we define it to always return 0.
    // This is required for Zig 0.15.2+ which ships LLVM 18+ headers that use this macro.
    p.compat_source = try p.driver.comp.addSourceFromBuffer("<compat>",
        \\// Compatibility macros for LLVM/Clang 18+ headers
        \\#define __building_module(x) 0
        \\
    );

    try p.addCFlags(cflags);
    p.builtin_source = try p.driver.comp.generateBuiltinMacros(p.driver.system_defines);

    return p;
}

/// Process C compiler flags via arocc's Driver.
/// Handles -I, -D, -f*, -std=, and other standard C compiler flags.
/// Must be called after init() and before collect_all_globals().
pub fn addCFlags(p: *Parser, cflags: []const []const u8) !void {
    if (cflags.len == 0) return;
    // Driver.parseArgs expects argv format where index 0 is the program name.
    // Prepend a dummy program name so the flags start at index 1.
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(p.allocator);
    try args.append(p.allocator, "fuzzmate");
    try args.appendSlice(p.allocator, cflags);

    var stdout_buf: [0]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buf);
    var user_macro: std.ArrayList(u8) = .empty;
    defer user_macro.deinit(p.comp.gpa);
    // Pass our macro_buf so -D/-U flags accumulate there for later use.
    _ = try p.driver.parseArgs(&stdout, &user_macro, args.items);
    const user_macro_buf = try user_macro.toOwnedSlice(p.allocator);
    defer p.allocator.free(user_macro_buf);
    // Converted to a source via `addSourceFromBuffer`
    p.user_macro_source = try p.comp.addSourceFromBuffer("<command line>", user_macro_buf);
}

/// Tear down toolchain state and diagnostics if previously initialized.
/// Safe to call exactly once per `init`.
pub fn deinit(p: *Parser) void {
    p.toolchain.deinit();
    p.driver.deinit();
    p.comp.deinit();
    p.diagnostics.deinit();

    const allocator = p.allocator;
    allocator.destroy(p);
}

pub fn free_globals(allocator: std.mem.Allocator, globals: *std.ArrayList(Global)) void {
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
///
/// Each file is parsed in its own Preprocessor so that no aro state
/// leaks between translation units.  The `aro.Compilation` caches
/// source file contents, keeping I/O minimal.
pub fn collectGlobals(p: *Parser, paths: []const []const u8, allocator: std.mem.Allocator) !std.ArrayList(Global) {
    const user_macros = p.user_macro_source;

    var source_list: std.ArrayList(aro.Source) = .empty;
    defer source_list.deinit(allocator);

    const empty_main = try p.comp.addSourceFromBuffer("<fuzzmate>", "\n");
    try source_list.append(allocator, empty_main);
    try source_list.append(allocator, p.builtin_source.?);
    try source_list.append(allocator, p.compat_source);
    if (user_macros) |um| {
        try source_list.append(allocator, um);
    }

    for (paths) |path| {
        const src = try p.driver.comp.addSourceFromPath(path);
        try source_list.append(allocator, src);
    }

    var pp = try aro.Preprocessor.initDefault(p.driver.comp);
    defer pp.deinit();
    pp.preprocessSources(source_list.items) catch |err| {
        printDiagnostics(p.driver.comp);
        return err;
    };

    var tree = try pp.parse();
    defer tree.deinit();

    return try collectGlobalsFromTree(p.driver.comp, tree, allocator);
}

/// Go through an entire Tree and extracts its globals.
/// Non-static globals that have already been seen (tracked via `seen_globals`)
/// are skipped to avoid duplicate extern declarations in the generated fuzzer.
fn collectGlobalsFromTree(comp: *aro.Compilation, tree: aro.Tree, allocator: std.mem.Allocator) !std.ArrayList(Global) {
    var globals: std.ArrayList(Global) = .empty;
    errdefer free_globals(allocator, &globals);

    // Track non-static globals already collected so that the same linker
    // symbol appearing in multiple translation units is emitted only once.
    var seen_globals: std.StringHashMap([]const u8) = .init(allocator);
    defer seen_globals.deinit();
    for (tree.root_decls.items) |idx| {
        const node = idx.get(&tree);
        switch (node) {
            .variable => |variable| {
                const loc = tree.tokens.items(.loc)[variable.name_tok];
                const expanded = loc.expand(comp);
                if (expanded.kind != .user) continue;
                if (isEffectivelyConst(tree.comp, variable.qt)) continue;
                if (variable.qt.hasIncompleteSize(tree.comp)) continue;

                //const name_slice = tree.tokSlice(variable.name_tok);
                // if (typedef_names.contains(name_slice)) continue;

                // Heuristic: skip variables that look like parsing artifacts.
                if (variable.initializer == null and variable.definition == null and
                    variable.storage_class == .auto and !variable.qt.isInvalid())
                {
                    const ty = variable.qt.type(tree.comp);
                    if (ty == .int) {
                        continue;
                    }
                }

                const source_path = try allocator.dupe(u8, expanded.path);
                errdefer allocator.free(source_path);

                const name_slice = try allocator.dupe(u8, tree.tokSlice(variable.name_tok));
                errdefer allocator.free(name_slice);

                // Non-static globals share a single linker symbol across all
                // translation units.  If we already collected one with this
                // name, skip the duplicate and warn.
                if (variable.storage_class != .static) {
                    if (seen_globals.get(name_slice)) |first_file| {
                        std.debug.print(
                            "[fuzzmate] warning: duplicate non-static global '{s}' in {s} " ++
                                "(first seen in {s}) — skipped\n",
                            .{ name_slice, source_path, first_file },
                        );
                        allocator.free(source_path);
                        allocator.free(name_slice);
                        continue;
                    }
                    try seen_globals.put(name_slice, source_path);
                }

                const size_val = variable.qt.sizeofOrNull(tree.comp);
                if (size_val == null) continue;
                const size_bytes: u64 = @intCast(size_val.?);

                const peeled = try type_flatten.peelTopLevelArrayDims(allocator, tree, variable.qt);
                errdefer allocator.free(peeled.dims);

                var fields_builder: std.ArrayList(Field) = .empty;
                errdefer fields_builder.deinit(allocator);
                errdefer for (fields_builder.items) |*f| f.deinit(allocator);

                try type_flatten.flattenGlobal(allocator, tree, peeled.qt, &fields_builder);

                const fields = try fields_builder.toOwnedSlice(allocator);
                errdefer allocator.free(fields);

                try globals.append(allocator, .{
                    .name = name_slice,
                    .source_file = source_path,
                    .size_bytes = size_bytes,
                    .is_static = variable.storage_class == .static,
                    .dims = peeled.dims,
                    .fields = fields,
                });
            },
            else => {},
        }
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
