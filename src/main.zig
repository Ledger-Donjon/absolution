//! CLI entrypoint for absolution.
//!
//! Parses command-line arguments, orchestrates the parse → invariant → codegen
//! pipeline, and optionally writes the `.zon` invariant and seed files.

const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap");
const absolution = @import("absolution");
const Invariant = absolution.Invariant;
const Global = absolution.Parser.Global;

fn writeSeed(path: []const u8, size: usize) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    const chunk_size = 4096;
    // we use undefine memory as the seed content does not matter
    const chunk: [chunk_size]u8 = undefined;

    var remaining = size;
    while (remaining > 0) {
        const n = @min(remaining, chunk_size);
        try file.writeAll(chunk[0..n]);
        remaining -= n;
    }
}

fn writeInvariant(allocator: std.mem.Allocator, globals: std.ArrayList(Global), zon_path: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    try std.zon.stringify.serialize(globals.items, .{ .whitespace = true }, &aw.writer);
    try aw.writer.writeByte('\n'); // Ensure trailing newline
    const zon_bytes = try aw.toOwnedSlice();
    defer allocator.free(zon_bytes);
    var file = try std.fs.cwd().createFile(zon_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(zon_bytes);
}

const Options = struct {
    targets: []const []const u8,
    redef: []const u8,
    invariant_path: ?[]const u8,
    out_c: []const u8,
    zon: ?[]const u8,
    seed: ?[]const u8,
    entry: []const u8,
    cflags: []const []const u8,
};

const cli = clap.parseParamsComptime(
    \\-h, --help               Show this help and exit.
    \\-t, --targets <str>...   Path to targets C translation unit(s).
    \\-o, --out <str>          Optional Output fuzzer C path (default: fuzzer.c).
    \\-r, --redef <str>        Required redefinition file output path.
    \\-i, --invariant <str>    Optional invariant (.in or .zon).
    \\-z, --zon <str>          Optional zon output path.
    \\-s, --seed <str>         Optional seed output path (default: fuzzer.seed).
    \\-e, --entry <str>        Optional harness function name (default: AbsolutionTestOneInput).
    \\<str>...                 C compiler flags after '--' (e.g. -I path -DFOO -fshort-enums).
    \\
);

const help_opts: clap.HelpOptions = .{
    .description_indent = 2,
};

fn printHelpAndFail(stream: std.fs.File) !Options {
    try clap.helpToFile(stream, clap.Help, &cli, help_opts);
    return error.InvalidArgs;
}

fn parseArgs(allocator: std.mem.Allocator) !Options {
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &cli, clap.parsers.default, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) return printHelpAndFail(.stdout());

    const targets = try allocator.dupe([]const u8, res.args.targets);
    errdefer allocator.free(targets);

    if (targets.len == 0) return printHelpAndFail(.stderr());

    const redef_path = res.args.redef orelse return printHelpAndFail(.stderr());

    const cflags = try allocator.dupe([]const u8, res.positionals[0]);
    // const cflags = try collectSlice(allocator, res.positionals[0]);
    errdefer allocator.free(cflags);

    return .{
        .targets = targets,
        .redef = redef_path,
        .invariant_path = res.args.invariant,
        .out_c = res.args.out orelse "fuzzer.c",
        .zon = res.args.zon,
        .seed = res.args.seed orelse "fuzzer.seed",
        .entry = res.args.entry orelse "AbsolutionTestOneInput",
        .cflags = cflags,
    };
}

pub fn main() !void {
    // Allocators
    var runtime_allocator = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 8 }){};
    defer _ = runtime_allocator.deinit();
    const gpa = runtime_allocator.allocator();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    // CLI
    const opts = parseArgs(gpa) catch return;
    defer gpa.free(opts.targets);
    defer gpa.free(opts.cflags);

    // Parser setup
    var parser = try absolution.Parser.init(gpa, arena.allocator(), opts.cflags);
    defer if (builtin.mode != .ReleaseFast) parser.deinit();

    // Retrieve Globals from targets
    var globals = try parser.collectGlobals(opts.targets);
    defer if (builtin.mode != .ReleaseFast) absolution.Parser.freeGlobals(gpa, &globals);

    // Optional: retrieve invariant and apply constraints
    var func_symbols: []const []const u8 = &.{};
    defer gpa.free(func_symbols);
    if (opts.invariant_path) |inv_path| {
        var inv = Invariant.init(gpa, inv_path) catch |err| {
            switch (err) {
                error.ParseZon => std.debug.print("Invalid format of input invariant\n", .{}),
                else => {},
            }
            return err;
        };
        // tied to enclosing scope
        defer if (builtin.mode != .ReleaseFast) inv.deinit();
        const res = try inv.applyToGlobals(gpa, arena.allocator(), globals);
        globals = res.globals;
        func_symbols = res.func_symbols;
    }

    // Code generation
    const needed_bytes = try absolution.cgen.generateFuzzer(gpa, globals, opts.redef, opts.out_c, opts.entry, func_symbols);

    // Optional: Save invariant to file
    if (opts.zon) |zon_path| try writeInvariant(gpa, globals, zon_path);

    // Optional: Generate an arbtrary seed
    if (opts.seed) |seed_path| try writeSeed(seed_path, needed_bytes);
}
