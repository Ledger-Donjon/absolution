const std = @import("std");
const Parser = @import("../Parser.zig");

/// Re-export ParsedGlobal for type compatibility in the cgen pipeline.
pub const ParsedGlobal = Parser.Global;

/// Write bytes to a file, creating or truncating as needed.
pub fn writeFile(path: []const u8, contents: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}
