const std = @import("std");
const tree = @import("tree.zig");
const Parser = @import("../Parser.zig");

/// Re-export ParsedGlobal so callers can pass parser results directly.
pub const ParsedGlobal = Parser.ParsedGlobal;

/// Small helper to persist bytes to disk.
pub fn writeFile(path: []const u8, contents: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}

fn dimsProduct(dims: []const usize) usize {
    var prod: usize = 1;
    for (dims) |d| prod *= d;
    return prod;
}
