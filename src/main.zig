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
    defer gpa.free(opts.zero_symbols);
    defer gpa.free(opts.lenient_zero_symbols);
    defer gpa.free(opts.domain_overrides);

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

    if (opts.zero_symbols.len + opts.lenient_zero_symbols.len + opts.domain_overrides.len > 0) {
        try applyTuning(gpa, io, arena, globals.items, &parser.enums, opts);
    }

    try ir.validateGlobalsDomains(globals.items);

    // Compute needed bytes
    const needed_bytes = seed.neededBytesFromGlobals(globals.items);

    // Code generation
    try emit.writeFuzzerC(gpa, io, globals.items, needed_bytes, opts.out_c, opts.redef, opts.entry, func_symbols, opts.post_check);

    // Optional: Save invariant to file
    if (opts.zon) |zon_path| try writeInvariant(gpa, io, globals.items, zon_path);

    // Optional: Generate an arbitrary seed
    if (opts.seed) |seed_path| try seed.writeSeed(io, seed_path, needed_bytes);
}

fn readAll(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .@"1", null) catch |err| {
        std.debug.print("error: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer gpa.free(bytes);
    return arena.dupe(u8, bytes);
}

/// Zero lists and domain overrides, applied in this run so the emitted sampler
/// and the exported `.zon` are already tuned.
fn applyTuning(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, globals: []Global, enums: *const absolution.Parser.EnumTable, opts: Options) !void {
    const Tuning = absolution.Tuning;
    var zeros: std.ArrayList(Tuning.ZeroSymbol) = .empty;
    for (opts.zero_symbols) |path| {
        try zeros.appendSlice(arena, try Tuning.parseZeroSymbols(arena, try readAll(gpa, io, arena, path), false));
    }
    for (opts.lenient_zero_symbols) |path| {
        try zeros.appendSlice(arena, try Tuning.parseZeroSymbols(arena, try readAll(gpa, io, arena, path), true));
    }
    var overrides: std.ArrayList(Tuning.Override) = .empty;
    for (opts.domain_overrides) |path| {
        try overrides.appendSlice(arena, try Tuning.parseOverrides(arena, try readAll(gpa, io, arena, path), path));
    }

    const rep = try Tuning.apply(arena, globals, zeros.items, overrides.items, enums);
    std.debug.print("tuning: {d} globals ({d} zeroed, {d} fuzzable), {d} override(s) applied\n", .{
        rep.total, rep.zeroed, rep.total - rep.zeroed, rep.overridden,
    });
    for (rep.stale_zeros) |z| {
        if (z.source) |src| {
            std.debug.print("warning: zero symbol '{s}@{s}' matched no global\n", .{ z.name, src });
        } else {
            std.debug.print("warning: zero symbol '{s}' matched no global\n", .{z.name});
        }
    }
    if (rep.unmatched.len > 0) {
        for (rep.unmatched) |o| {
            std.debug.print("{s}:{d}: error: override '{s}{s}' matched no field\n", .{ o.file, o.line, o.global, o.field });
        }
        return error.UnmatchedOverride;
    }
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
    post_check: bool,
    zero_symbols: []const []const u8,
    lenient_zero_symbols: []const []const u8,
    domain_overrides: []const []const u8,
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
    \\--no-post-check          Do not assert check_invariant() after the harness returns (for harnesses that drive the globals out of the sampled domain, e.g. multi-step sessions).
    \\-Z, --zero-symbols <str>...  Zero-symbol list(s): matched globals get a single all-zero value. Unmatched selectors are reported.
    \\--lenient-zero-symbols <str>...  Zero-symbol list(s) shared across projects: unmatched selectors are not reported.
    \\-O, --domain-overrides <str>...  Domain override file(s) ('<global>.<field> = values ...|top|enum <T>'), applied after the zero lists. Unmatched overrides are fatal.
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

    const zero_symbols = try allocator.dupe([]const u8, res.args.@"zero-symbols");
    errdefer allocator.free(zero_symbols);
    const lenient_zero_symbols = try allocator.dupe([]const u8, res.args.@"lenient-zero-symbols");
    errdefer allocator.free(lenient_zero_symbols);
    const domain_overrides = try allocator.dupe([]const u8, res.args.@"domain-overrides");
    errdefer allocator.free(domain_overrides);

    return .{
        .targets = targets,
        .redef = redef_path,
        .invariant_path = res.args.invariant,
        .out_c = res.args.out orelse "fuzzer.c",
        .zon = res.args.zon,
        .seed = res.args.seed orelse "fuzzer.seed",
        .entry = res.args.entry orelse "AbsolutionTestOneInput",
        .post_check = res.args.@"no-post-check" == 0,
        .zero_symbols = zero_symbols,
        .lenient_zero_symbols = lenient_zero_symbols,
        .domain_overrides = domain_overrides,
        .cflags = cflags,
    };
}
