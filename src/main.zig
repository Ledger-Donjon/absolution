const std = @import("std");
const clap = @import("clap");
const fuzzmate = @import("fuzzmate");
const invariant = @import("fuzzmate").invariant;

const Options = struct {
    targets: []const u8,
    invariant: ?[]const u8,
    out_c: []const u8,
    zon: ?[]const u8,
    seed: ?[]const u8,
};

const cli = clap.parseParamsComptime(
    \\-h, --help               Show this help and exit.
    \\-t, --targets <str>      Path to targets C translation unit.
    \\-o, --out <str>          Optional Output fuzzer C path (default: fuzzer.c).
    \\    --invariant <str>    Optional invariant (.in or .zon).
    \\    --zon <str>          Optional zon output path.
    \\    --seed <str>         Optional seed output path (default: <out>.seed).
    \\
);

const helpOpts: clap.HelpOptions = .{
    .description_indent = 2,
};

/// Create or truncate a seed file and fill it with zero bytes.
/// Args:
///   allocator: Allocator used to stage the zero buffer.
///   path: Destination file path.
///   size: Number of bytes to write.
fn writeSeed(allocator: std.mem.Allocator, path: []const u8, size: usize) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    const buf_size = 4096;
    const zeros = try allocator.alloc(u8, buf_size);
    defer allocator.free(zeros);
    @memset(zeros, 0);

    var remaining = size;
    while (remaining > 0) {
        const to_write = @min(remaining, buf_size);
        try file.writeAll(zeros[0..to_write]);
        remaining -= to_write;
    }
}

/// Parse command-line arguments and return resolved options.
/// Args:
///   allocator: Allocator used for clap parsing and derived defaults.
/// Returns:
///   Options struct with CLI-resolved paths and flags.
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

    if (res.args.help != 0) {
        try clap.helpToFile(.stdout(), clap.Help, &cli, helpOpts);
        return error.InvalidArgs;
    }

    const targets_path = res.args.targets orelse {
        try clap.helpToFile(.stderr(), clap.Help, &cli, helpOpts);
        return error.InvalidArgs;
    };
    const out_c_path = res.args.out orelse "fuzzer.c";
    const zon_path = res.args.zon;
    const seed_path = res.args.seed orelse "fuzzer.seed";

    return .{
        .targets = targets_path,
        .invariant = res.args.invariant,
        .out_c = out_c_path,
        .zon = zon_path,
        .seed = seed_path,
    };
}

/// Entry point: parse CLI, collect globals, emit fuzzer sources, and seed file.
pub fn main() !void {
    // Set up exeution allocators
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 8 }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Get user options
    const opts = parseArgs(allocator) catch return;

    const parser = try fuzzmate.Parser.init(allocator, arena.allocator());
    defer parser.deinit();

    var globals = try parser.collect_globals(opts.targets, allocator);
    defer fuzzmate.Parser.free_globals(allocator, &globals);

    var inv: ?invariant.Invariant = null;
    if (opts.invariant) |inv_path| {
        inv = try invariant.loadZon(allocator, inv_path);
        defer if (inv) |spec| spec.deinit(allocator);
    }

    const needed_bytes = try fuzzmate.cgen.generateFuzzer(
        allocator,
        &globals,
        opts.targets,
        opts.out_c,
        opts.zon,
        inv,
    );

    if (opts.seed) |seed_output| {
        try writeSeed(allocator, seed_output, needed_bytes);
    }
}
