//! C code generation for libFuzzer harnesses.
//!
//! This module orchestrates the generation of fuzzer sources from parsed globals,
//! handling domain constraints, invariant application, and file output.

const tree = @import("cgen/tree.zig");
const builder = @import("cgen/builder.zig");
const emit = @import("cgen/emit.zig");
const std = @import("std");

/// Public re-exports for direct access to submodules.
pub const Tree = tree;
pub const Builder = builder;
pub const Emit = emit;

/// Generate a complete fuzzer from parsed globals.
///
/// Applies any invariant constraints, emits `fuzzer.c` with sampling/checking
/// functions, and optionally exports the module to `.zon` format.
///
/// Returns the number of fuzzer input bytes needed for sampling.
pub fn generateFuzzer(
    allocator: std.mem.Allocator,
    globals: std.ArrayList(Builder.ParsedGlobal),
    redef_path: []const u8,
    out_c_path: []const u8,
    entry_name: []const u8,
    func_symbols: []const []const u8,
) !usize {
    const needed_bytes = neededBytesFromGlobals(globals.items);

    try Emit.writeFuzzerC(allocator, globals.items, needed_bytes, out_c_path, redef_path, entry_name, func_symbols);

    return needed_bytes;
}

fn neededBytesFromGlobals(globals: []const Builder.ParsedGlobal) usize {
    var total: usize = 0;
    for (globals) |g| {
        // Skip static variables from header files - they can't be processed
        // by objcopy and are excluded from the generated fuzzer.
        if (g.is_static and Emit.isHeaderFile(g.source_file)) {
            continue;
        }
        const global_mult = dimsProduct(g.dims);
        for (g.fields) |f| {
            if (f.is_padding) continue;
            const field_mult = dimsProduct(f.dims);
            const bytes: usize = switch (f.domain) {
                .top => (f.bit_width + 7) / 8,
                .values, .pointers => 1,
            };
            total += bytes * global_mult * field_mult;
        }
    }
    return total;
}

fn dimsProduct(dims: []const Tree.Dimension) usize {
    var prod: usize = 1;
    for (dims) |d| prod *= d.len;
    return prod;
}
