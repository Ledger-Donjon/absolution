//! Integration tests for fuzzmate.
//!
//! Each test case corresponds to a directory under `tests/`. The test parses
//! the `.c` file using the library directly (no subprocess), generates the
//! `.zon` output in memory, and compares it byte-for-byte against the golden
//! file.
//!
//! Run with: zig build it

const std = @import("std");
const fuzzmate = @import("root.zig");

/// Helper that runs the full parse→serialize pipeline and compares against golden.
/// Paths are relative to the project root (where `zig build` is invoked).
fn runGoldenTest(comptime subdir: []const u8, comptime c_file: []const u8) !void {
    const c_path = "tests/" ++ subdir ++ "/" ++ c_file;
    const golden_path = "tests/" ++ subdir ++ "/" ++ c_file ++ ".zon";

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Read golden file at runtime
    const golden = std.fs.cwd().readFileAlloc(allocator, golden_path, 1024 * 1024) catch |err| {
        std.debug.print("Failed to read golden file '{s}': {}\n", .{ golden_path, err });
        return err;
    };
    defer allocator.free(golden);

    const parser = try fuzzmate.Parser.init(allocator, arena.allocator());
    defer parser.deinit();

    var globals = try parser.collect_globals(c_path, allocator);
    defer fuzzmate.Parser.free_globals(allocator, &globals);

    // Serialize globals to .zon in memory
    var aw = std.Io.Writer.Allocating.init(allocator);
    try std.zon.stringify.serialize(globals.items, .{ .whitespace = true }, &aw.writer);
    try aw.writer.writeByte('\n');
    const actual = try aw.toOwnedSlice();
    defer allocator.free(actual);

    // Compare
    try std.testing.expectEqualStrings(golden, actual);
}

// ============================================================================
// Test cases — one per directory under tests/
// ============================================================================

test "anonymous_types" {
    try runGoldenTest("anonymous_types", "anon.c");
}

test "arrays" {
    try runGoldenTest("arrays", "array.c");
}

test "basic" {
    try runGoldenTest("basic", "basic.c");
}

test "bitfield_const" {
    try runGoldenTest("bitfield_const", "bitfield.c");
}

test "complex_struct" {
    try runGoldenTest("complex_struct", "complex.c");
}

test "function_pointers" {
    try runGoldenTest("function_pointers", "funcptr.c");
}

test "nested" {
    try runGoldenTest("nested", "nested.c");
}

test "nested_arrays" {
    try runGoldenTest("nested_arrays", "nestedarray.c");
}

test "padding_check" {
    try runGoldenTest("padding_check", "padding.c");
}
