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
builtin_source: aro.Source,
compat_source: aro.Source,
/// User -D define text accumulated as `#define` lines, matching aro's Driver
/// pattern.  Converted to a source via `addSourceFromOwnedBuffer` before the
/// first call to `collect_globals`.
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
        .builtin_source = undefined,
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

    p.builtin_source = try p.driver.comp.generateBuiltinMacros(p.driver.system_defines);

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

/// Add a user include directory (-I) for C header resolution.
/// These are searched before system include directories.
pub fn addIncludeDir(p: *Parser, path: []const u8) !void {
    try p.comp.include_dirs.append(p.allocator, try p.comp.arena.dupe(u8, path));
}

/// Add a preprocessor define (-D).
/// Accepts "NAME" (defined as 1) or "NAME=VALUE", matching aro's Driver
/// convention.  Must be called before the first `collect_globals`.
pub fn addDefine(p: *Parser, def: []const u8) !void {
    const w = p.macro_buf.writer(p.allocator);
    if (std.mem.indexOfScalar(u8, def, '=')) |eq| {
        try w.print("#define {s} {s}\n", .{ def[0..eq], def[eq + 1 ..] });
    } else {
        try w.print("#define {s} 1\n", .{def});
    }
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

/// Collect non-const, user-defined globals along with their bit widths.
///
/// Uses arocc's native preprocessing with the bundled sysroot headers.
/// System headers are automatically filtered via Source.Kind tracking.
pub fn collect_globals(p: *Parser, path: []const u8, allocator: std.mem.Allocator) !std.ArrayList(ParsedGlobal) {
    // Load source file directly - arocc handles all preprocessing natively
    // using the bundled sysroot headers configured in init().
    const source = try p.driver.comp.addSourceFromPath(path);

    // Materialise user -D defines into an aro source (once, on first parse).
    const user_macros = try p.resolveUserMacros();

    var pp = try aro.Preprocessor.initDefault(p.driver.comp);
    defer pp.deinit();
    // Include compat_source and user defines before builtin_source and the
    // user source so that all macros are visible during preprocessing.
    const sources = if (user_macros) |um|
        &[_]aro.Source{ source, p.builtin_source, p.compat_source, um }
    else
        &[_]aro.Source{ source, p.builtin_source, p.compat_source };
    pp.preprocessSources(sources) catch |err| {
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

    // First pass: collect typedef names to filter out variables that shadow them.
    // This prevents generating code like `memset(&my_type_t, ...)` where my_type_t
    // is both a typedef and a variable name, which causes C compilation errors.
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

                // Skip variables whose name conflicts with a typedef name.
                // This avoids generating invalid C like `memset(&type_name, ...)`
                // where `type_name` is interpreted as a type, not a variable.
                if (typedef_names.contains(name_slice)) continue;

                // Heuristic: skip variables that look like parsing artifacts.
                // These occur in two scenarios:
                //
                // 1. Typedef parsing artifacts: aro parses constructs like:
                //      typedef int (*foo_t)(void) __attribute__((warn_unused_result));
                //    and incorrectly creates both a typedef and a variable named `foo_t`.
                //
                // 2. Function parameter artifacts: aro sometimes emits .variable nodes
                //    for function parameters (e.g., `size_t size` from a function signature),
                //    which should not appear in root_decls at all.
                //
                // We detect these by checking for:
                // - No initializer (tentative definition)
                // - No actual definition
                // - 'auto' storage class (invalid at file scope in C)
                // - Type is a primitive integer type (not a user-defined type like struct/typedef)
                if (variable.initializer == null and variable.definition == null and
                    variable.storage_class == .auto and !variable.qt.isInvalid())
                {
                    const ty = variable.qt.type(tree.comp);
                    // Filter if type is a primitive integer (covers all int sizes via .int tag)
                    // This catches spurious variables from function parameters like `size_t size`
                    if (ty == .int) {
                        continue;
                    }
                }

                const copied_name = try allocator.dupe(u8, name_slice);
                errdefer allocator.free(copied_name);

                // Capture source file path from the translation unit
                const source_file_path = path;
                const copied_source_file = try allocator.dupe(u8, source_file_path);
                errdefer allocator.free(copied_source_file);

                // Check if the variable has static storage class (internal linkage)
                const is_static = variable.storage_class == .static;

                // Calculate size in bytes (we already know it's complete from the check above)
                const size_val = variable.qt.sizeofOrNull(tree.comp);
                if (size_val == null) continue;
                const size_bytes: u64 = @intCast(size_val.?);

                var peeled = try type_flatten.peelTopLevelArrayDims(allocator, tree, variable.qt);
                errdefer peeled.dims.deinit(allocator);

                var fields = Fields{};
                errdefer {
                    for (fields.items) |*f| f.deinit(allocator);
                    fields.deinit(allocator);
                }

                try type_flatten.flattenGlobal(allocator, tree, peeled.qt, &fields);

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

    return globals;
}
