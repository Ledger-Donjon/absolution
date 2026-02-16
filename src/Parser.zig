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

const FieldsBuilder = std.ArrayListUnmanaged(ParsedField);

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
/// Driver.parseArgs().  Converted to a source via `addSourceFromOwnedBuffer`
/// before the first call to `collect_globals`.
macro_buf: std.ArrayList(u8) = .empty,
/// Lazily-built source from `macro_buf`; null until the first parse.
user_macro_source: ?aro.Source = null,
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
        .builtin_source = null,
        .compat_source = undefined,
        .macro_buf = .empty,
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
    try include_paths.addZigCcImplicitIncludes(&p.comp, resource_dir_dupe);

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

    p.initialized = true;

    return p;
}

/// Process C compiler flags via arocc's Driver.
/// Handles -I, -D, -f*, -std=, and other standard C compiler flags.
/// Must be called after init() and before collect_all_globals().
pub fn addCFlags(p: *Parser, cflags: []const []const u8) !void {
    // Driver.parseArgs expects argv format where index 0 is the program name.
    // Prepend a dummy program name so the flags start at index 1.
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(p.allocator);
    try args.append(p.allocator, "fuzzmate");
    try args.appendSlice(p.allocator, cflags);

    var stdout_buf: [0]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buf);
    // Pass our macro_buf so -D/-U flags accumulate there for later use.
    _ = try p.driver.parseArgs(&stdout, &p.macro_buf, args.items);
}

/// Convert the accumulated `macro_buf` into an aro Source.
/// Returns the cached source on subsequent calls, or null when no defines
/// were registered.  Mirrors aro's Driver pattern (`addSourceFromOwnedBuffer`).
fn resolveUserMacros(p: *Parser) !?aro.Source {
    if (p.user_macro_source) |s| return s;
    if (p.macro_buf.items.len == 0) return null;

    const contents = try p.macro_buf.toOwnedSlice(p.allocator);
    errdefer p.allocator.free(contents);

    p.user_macro_source = try p.comp.addSourceFromOwnedBuffer(
        "<command line>",
        contents,
        .user,
    );
    return p.user_macro_source;
}

/// Tear down toolchain state and diagnostics if previously initialized.
/// Safe to call exactly once per `init`.
pub fn deinit(p: *Parser) void {
    if (p.initialized) {
        p.toolchain.deinit();
        p.driver.deinit();
    }
    p.macro_buf.deinit(p.allocator);
    p.comp.deinit();
    p.diagnostics.deinit();

    const allocator = p.allocator;
    allocator.destroy(p);
}

pub fn free_globals(allocator: std.mem.Allocator, globals: *std.ArrayList(ParsedGlobal)) void {
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

/// Collect non-const, user-defined globals along with their bit widths
/// from a single translation unit.
///
/// Uses arocc's native preprocessing with the bundled sysroot headers.
/// System headers are automatically filtered via Source.Kind tracking.
pub fn collect_globals(p: *Parser, path: []const u8, allocator: std.mem.Allocator) !std.ArrayList(ParsedGlobal) {
    return p.collect_all_globals(&.{path}, allocator);
}

/// Collect globals from every target file.
///
/// Each file is parsed in its own Preprocessor so that no aro state
/// leaks between translation units.  The `aro.Compilation` caches
/// source file contents, keeping I/O minimal.
pub fn collect_all_globals(p: *Parser, paths: []const []const u8, allocator: std.mem.Allocator) !std.ArrayList(ParsedGlobal) {
    // Generate builtin macros on first parse. This is done lazily so that
    // addCFlags() (which may change -std=) is called first.
    if (p.builtin_source == null) {
        p.builtin_source = try p.driver.comp.generateBuiltinMacros(p.driver.system_defines);
    }

    const user_macros = try p.resolveUserMacros();

    var globals = std.ArrayList(ParsedGlobal).empty;
    errdefer free_globals(allocator, &globals);

    for (paths, 0..) |path, i| {
        var timer = std.time.Timer.start() catch unreachable;
        std.debug.print("[fuzzmate] [{d}/{d}] {s} START\n", .{
            i + 1,
            paths.len,
            path,
        });
        try p.collectGlobalsFromFile(path, user_macros, allocator, &globals);
        const elapsed = timer.read();
        std.debug.print("[fuzzmate] [{d}/{d}] {s} in {d}ms\n", .{
            i + 1,
            paths.len,
            path,
            elapsed / std.time.ns_per_ms,
        });
    }
    return globals;
}

/// Parse a single translation unit and append its globals.
fn collectGlobalsFromFile(
    p: *Parser,
    path: []const u8,
    user_macros: ?aro.Source,
    allocator: std.mem.Allocator,
    globals: *std.ArrayList(ParsedGlobal),
) !void {
    // Build source list: [empty_main, builtins, compat, user_macros, target]
    var source_list = std.ArrayList(aro.Source).empty;
    defer source_list.deinit(allocator);

    const empty_main = try p.comp.addSourceFromBuffer("<fuzzmate>", "\n");
    try source_list.append(allocator, empty_main);
    try source_list.append(allocator, p.builtin_source.?);
    try source_list.append(allocator, p.compat_source);
    if (user_macros) |um| {
        try source_list.append(allocator, um);
    }

    const src = try p.driver.comp.addSourceFromPath(path);
    try source_list.append(allocator, src);

    var pp = try aro.Preprocessor.initDefault(p.driver.comp);
    defer pp.deinit();
    pp.preprocessSources(source_list.items) catch |err| {
        p.printDiagnostics();
        return err;
    };

    var tree = try pp.parse();
    defer tree.deinit();

    // Collect typedef names to filter out variables that shadow them.
    var typedef_names = std.StringHashMap(void).init(allocator);
    defer typedef_names.deinit();
    for (tree.root_decls.items) |idx| {
        const node = idx.get(&tree);
        switch (node) {
            .typedef => |td| {
                const name = tree.tokSlice(td.name_tok);
                try typedef_names.put(name, {});
            },
            else => {},
        }
    }

    for (tree.root_decls.items) |idx| {
        const node = idx.get(&tree);
        switch (node) {
            .variable => |variable| {
                const loc = tree.tokens.items(.loc)[variable.name_tok];
                const expanded = loc.expand(p.driver.comp);
                if (expanded.kind != .user) continue;
                if (isEffectivelyConst(tree.comp, variable.qt)) continue;
                if (variable.qt.hasIncompleteSize(tree.comp)) continue;

                const name_slice = tree.tokSlice(variable.name_tok);
                if (typedef_names.contains(name_slice)) continue;

                // Heuristic: skip variables that look like parsing artifacts.
                if (variable.initializer == null and variable.definition == null and
                    variable.storage_class == .auto and !variable.qt.isInvalid())
                {
                    const ty = variable.qt.type(tree.comp);
                    if (ty == .int) {
                        continue;
                    }
                }

                const source_file_path = expanded.path;
                const copied_source_file = try allocator.dupe(u8, source_file_path);
                errdefer allocator.free(copied_source_file);

                const copied_name = try allocator.dupe(u8, name_slice);
                errdefer allocator.free(copied_name);

                const is_static = variable.storage_class == .static;

                const size_val = variable.qt.sizeofOrNull(tree.comp);
                if (size_val == null) continue;
                const size_bytes: u64 = @intCast(size_val.?);

                const peeled = try type_flatten.peelTopLevelArrayDims(allocator, tree, variable.qt);
                errdefer allocator.free(peeled.dims);

                var fields_builder = FieldsBuilder{};
                errdefer {
                    for (fields_builder.items) |*f| f.deinit(allocator);
                    fields_builder.deinit(allocator);
                }

                try type_flatten.flattenGlobal(allocator, tree, peeled.qt, &fields_builder);

                const fields = try fields_builder.toOwnedSlice(allocator);
                errdefer {
                    for (fields) |*f| f.deinit(allocator);
                    allocator.free(fields);
                }

                try globals.append(allocator, .{
                    .name = copied_name,
                    .source_file = copied_source_file,
                    .size_bytes = size_bytes,
                    .is_static = is_static,
                    .dims = peeled.dims,
                    .fields = fields,
                });
            },
            else => {},
        }
    }
}

/// Print accumulated aro diagnostics to stdout.
fn printDiagnostics(p: *Parser) void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    defer _ = stdout.interface.flush() catch {};
    for (p.driver.comp.diagnostics.output.to_list.messages.items) |msg| {
        msg.write(&stdout.interface, .escape_codes, true) catch {};
    }
}
