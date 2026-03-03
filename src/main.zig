const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap");
const absolution = @import("absolution");
const invariant = absolution.invariant;

fn writeSeed(
    path: []const u8,
    size: usize,
) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    const chunk_size = 4096;
    const chunk: [chunk_size]u8 = undefined;

    var remaining = size;
    while (remaining > 0) {
        const n = @min(remaining, chunk_size);
        try file.writeAll(chunk[0..n]);
        remaining -= n;
    }
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
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 8 }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    // CLI
    const opts = parseArgs(allocator) catch return;
    defer allocator.free(opts.targets);
    defer allocator.free(opts.cflags);

    // Parser setup
    var parser = try absolution.Parser.init(allocator, arena.allocator(), opts.cflags);
    defer if (builtin.mode != .ReleaseFast) parser.deinit();

    // Retrieve Globals from targets
    var globals = try parser.collectGlobals(opts.targets);
    defer if (builtin.mode != .ReleaseFast) absolution.Parser.freeGlobals(allocator, &globals);

    // Optional invariant
    var inv: ?invariant.Invariant = null;
    if (opts.invariant_path) |inv_path| {
        inv = try invariant.loadZon(allocator, inv_path);
        defer if (builtin.mode != .ReleaseFast) inv.?.deinit(allocator);
    }

    // Code generation
    const needed_bytes = try absolution.cgen.generateFuzzer(
        allocator,
        &globals,
        opts.redef,
        opts.out_c,
        opts.zon,
        inv,
        opts.entry,
    );

    // Optional seed
    if (opts.seed) |seed_path| {
        try writeSeed(seed_path, needed_bytes);
    }
}
