const std = @import("std");

const aro = @import("aro");
const fuzzmate = @import("fuzzmate");

pub fn main() !void {
    // Setting up our execution allocators
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    // AroCC will purposely not dealocate memory for better performances.
    // It's API takes an arena that can be used to free in once all allocations
    // Absolution depends heavily on arocc thus we follow the same init interface
    defer arena.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    const filepath = args.next() orelse {
        // no argument provided
        return;
    };

    var io = std.Io.Threaded.init(allocator);
    defer io.deinit();
    var parser: fuzzmate.Parser = undefined;
    try parser.init(allocator, arena.allocator(), io.io());
    defer parser.deinit();
    parser.dump_globals(filepath) catch |err| {
        // To lazy to handle errors for now
        switch (err) {
            error.IsDir => std.debug.print("{s} is a directory\n", .{filepath}),
            error.FatalError => {},
            else => return err,
        }
    };
}
