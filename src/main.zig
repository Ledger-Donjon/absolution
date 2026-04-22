//! CLI entrypoint for absolution.
//!
//! Parses command-line arguments, orchestrates the parse → invariant → codegen
//! pipeline, and optionally writes the `.zon` invariant and seed files.

const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap");
const build_options = @import("build_options");
const absolution = @import("absolution");
const Invariant = absolution.Invariant;
const Global = absolution.Parser.Global;
const ir = absolution.ir;
const seed = absolution.seed;
const emit = absolution.emit;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    // CLI
    const opts = parseArgs(gpa, io, init.minimal.args) catch return;
    defer gpa.free(opts.targets);
    defer gpa.free(opts.cflags);

    // Parser setup
    var parser = try absolution.Parser.init(gpa, arena, io, opts.cflags);
    defer if (builtin.mode != .ReleaseFast) parser.deinit();

    // Retrieve Globals from targets
    var globals = try parser.collectGlobals(opts.targets);
    defer if (builtin.mode != .ReleaseFast) absolution.Parser.freeGlobals(gpa, &globals);

    // Optional: retrieve invariant and apply constraints
    var func_symbols: []const []const u8 = &.{};
    defer gpa.free(func_symbols);
    if (opts.invariant_path) |inv_path| {
        var inv = Invariant.init(gpa, io, inv_path) catch |err| {
            switch (err) {
                error.ParseZon => std.debug.print("Invalid format of input invariant\n", .{}),
                else => {},
            }
            return err;
        };
        // tied to enclosing scope
        defer if (builtin.mode != .ReleaseFast) inv.deinit();
        const res = try inv.applyToGlobals(gpa, arena, globals);
        globals = res.globals;
        func_symbols = res.func_symbols;
    }

    try ir.validateGlobalsDomains(globals.items);

    // Compute needed bytes
    const needed_bytes = seed.neededBytesFromGlobals(globals.items);

    // Code generation
    try emit.writeFuzzerC(gpa, io, globals.items, needed_bytes, opts.out_c, opts.redef, opts.entry, func_symbols);

    // Optional: Save invariant to file
    if (opts.zon) |zon_path| try writeInvariant(gpa, io, globals.items, zon_path);

    // Optional: Generate an arbitrary seed
    if (opts.seed) |seed_path| try seed.writeSeed(io, seed_path, needed_bytes);
}

fn writeInvariant(allocator: std.mem.Allocator, io: std.Io, globals: []const Global, zon_path: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    try std.zon.stringify.serialize(globals, .{ .whitespace = true }, &aw.writer);
    try aw.writer.writeByte('\n');
    const zon_bytes = try aw.toOwnedSlice();
    defer allocator.free(zon_bytes);
    var file = try std.Io.Dir.cwd().createFile(io, zon_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, zon_bytes);
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

fn printHelpAndFail(io: std.Io, stream: std.Io.File) !Options {
    try printHelp(io, stream);
    return error.InvalidArgs;
}

fn printHelp(io: std.Io, stream: std.Io.File) !void {
    var banner_buf: [256]u8 = undefined;
    var w = stream.writer(io, &banner_buf);
    try w.interface.print("absolution @{s}\n\n", .{build_options.version});
    try w.interface.flush();
    try clap.helpToFile(io, stream, clap.Help, &cli, help_opts);
}

fn parseArgs(allocator: std.mem.Allocator, io: std.Io, args: std.process.Args) !Options {
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &cli, clap.parsers.default, args, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        try diag.reportToFile(io, std.Io.File.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) return printHelpAndFail(io, std.Io.File.stdout());

    const targets = try allocator.dupe([]const u8, res.args.targets);
    errdefer allocator.free(targets);

    if (targets.len == 0) return printHelpAndFail(io, std.Io.File.stderr());

    const redef_path = res.args.redef orelse return printHelpAndFail(io, std.Io.File.stderr());

    const cflags = try allocator.dupe([]const u8, res.positionals[0]);
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
