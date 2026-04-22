//! Integration tests for absolution.
//!
//! Finds .c test files under tests/, builds absolution once, then for each test:
//!   1. Runs absolution to produce .zon and fuzzer.c
//!   2. Compiles the generated fuzzer.c with `zig cc`
//!   3. Compares the .zon output against a golden file
//!
//! Run with:  zig run scripts/integration.zig
//!
//! Run a single test (substring match on test id):
//!            zig run scripts/integration.zig -- simple_struct

const std = @import("std");

const green = "\x1b[32m";
const red = "\x1b[31m";
const yellow = "\x1b[33m";
const bold = "\x1b[1m";
const dim = "\x1b[2m";
const reset = "\x1b[0m";

const tmp_base = "/tmp/absolution-integration-tests";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    // 0. Parse optional filter from argv
    const process_args = try init.minimal.args.toSlice(arena);
    const filter: ?[]const u8 = if (process_args.len > 1) process_args[1] else null;
    if (filter) |f| out(io, bold ++ "Filter: " ++ reset ++ "{s}\n", .{f});

    // 1. Build absolution
    out(io, bold ++ "Building absolution..." ++ reset ++ "\n", .{});
    try buildAbsolution(gpa, io);

    std.Io.Dir.cwd().access(io, "zig-out/bin/absolution", .{}) catch {
        out(io, red ++ "absolution binary not found at zig-out/bin/absolution" ++ reset ++ "\n", .{});
        std.process.exit(1);
    };

    // 2. Discover tests
    var cases: std.ArrayList(TestCase) = .empty;
    try discoverTests(arena, io, &cases);
    std.mem.sort(TestCase, cases.items, {}, struct {
        fn lt(_: void, a: TestCase, b: TestCase) bool {
            return std.mem.order(u8, a.test_id, b.test_id) == .lt;
        }
    }.lt);

    out(io, "Collected " ++ bold ++ "{d}" ++ reset ++ " test(s)\n\n", .{cases.items.len});

    // 3. Prepare temp directory (clean slate each run)
    std.Io.Dir.deleteDirAbsolute(io, tmp_base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_base);

    // 4. Run tests
    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    var filtered_count: usize = 0;
    for (cases.items, 0..) |tc, idx| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, tc.test_id, f) == null) continue;
        }
        filtered_count += 1;
        if (tc.skip_reason) |reason| {
            out(io, "  " ++ yellow ++ "SKIP" ++ reset ++ "  {s}  " ++ dim ++ "({s})" ++ reset ++ "\n", .{ tc.test_id, reason });
            skipped += 1;
            continue;
        }

        if (runOneTest(gpa, arena, io, tc, idx)) {
            out(io, "  " ++ green ++ "PASS" ++ reset ++ "  {s}\n", .{tc.test_id});
            passed += 1;
        } else |err| {
            out(io, "  " ++ red ++ "FAIL" ++ reset ++ "  {s}  " ++ dim ++ "({s})" ++ reset ++ "\n", .{ tc.test_id, @errorName(err) });
            failed += 1;
        }
    }

    // 5. Summary
    if (filter != null and filtered_count == 0) {
        out(io, red ++ "No tests matched filter" ++ reset ++ "\n", .{});
        std.process.exit(1);
    }
    out(io, "\n" ++ bold ++ "{d}" ++ reset ++ " passed", .{passed});
    if (failed > 0) out(io, ", " ++ bold ++ red ++ "{d} failed" ++ reset, .{failed});
    if (skipped > 0) out(io, ", " ++ bold ++ yellow ++ "{d} skipped" ++ reset, .{skipped});
    out(io, "\n", .{});

    if (failed > 0) std.process.exit(1);
}

// -----------------------------------------------------------------------
// Types
// -----------------------------------------------------------------------

const TestCase = struct {
    c_path: []const u8,
    golden_path: []const u8,
    dir_path: []const u8,
    test_id: []const u8,
    skip_reason: ?[]const u8 = null,
    flags: []const []const u8 = &.{},
    targets: []const []const u8 = &.{},
    invariant_path: ?[]const u8 = null,
};

// -----------------------------------------------------------------------
// Build
// -----------------------------------------------------------------------

fn buildAbsolution(allocator: std.mem.Allocator, io: std.Io) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "zig", "build", "install" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            out(io, red ++ "Build failed (exit code {d})" ++ reset ++ "\n", .{code});
            std.process.exit(1);
        },
        else => {
            out(io, red ++ "Build terminated abnormally" ++ reset ++ "\n", .{});
            std.process.exit(1);
        },
    }
}

// -----------------------------------------------------------------------
// Test discovery
// -----------------------------------------------------------------------

fn discoverTests(arena: std.mem.Allocator, io: std.Io, cases: *std.ArrayList(TestCase)) !void {
    const cwd = std.Io.Dir.cwd();
    var tests_dir = cwd.openDir(io, "tests", .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open tests/ directory: {s}\n", .{@errorName(err)});
        return err;
    };
    defer tests_dir.close(io);

    var walker = try tests_dir.walk(arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".c")) continue;

        const c_path = try std.fmt.allocPrint(arena, "tests/{s}", .{entry.path});
        const golden_path = try std.fmt.allocPrint(arena, "{s}.zon", .{c_path});
        const skip_path = try std.fmt.allocPrint(arena, "{s}.zon.skip-arocc-bug", .{c_path});

        const dir_path = if (std.mem.lastIndexOfScalar(u8, c_path, '/')) |i|
            c_path[0..i]
        else
            ".";

        const parent_name = if (std.mem.lastIndexOfScalar(u8, dir_path, '/')) |i|
            dir_path[i + 1 ..]
        else
            dir_path;

        const test_id = try std.fmt.allocPrint(arena, "{s}/{s}", .{ parent_name, entry.basename });

        // Skip marker
        if (fileExists(cwd, io, skip_path)) {
            try cases.append(arena, .{
                .c_path = c_path,
                .golden_path = golden_path,
                .dir_path = dir_path,
                .test_id = test_id,
                .skip_reason = "arocc parser bug",
            });
            continue;
        }

        // No golden file → not a test
        if (!fileExists(cwd, io, golden_path)) continue;

        // .flags sidecar (extra compiler flags after --)
        const flags_path = try std.fmt.allocPrint(arena, "{s}.flags", .{c_path});
        const flags: []const []const u8 = readNonCommentLines(arena, cwd, io, flags_path) catch &.{};

        // .targets sidecar (explicit target list, or fall back to the .c file itself)
        const targets_path = try std.fmt.allocPrint(arena, "{s}.targets", .{c_path});
        const targets: []const []const u8 = blk: {
            const lines = readNonCommentLines(arena, cwd, io, targets_path) catch {
                const one = try arena.alloc([]const u8, 1);
                one[0] = c_path;
                break :blk one;
            };
            const resolved = try arena.alloc([]const u8, lines.len);
            for (lines, 0..) |line, i| {
                resolved[i] = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, line });
            }
            break :blk resolved;
        };

        // .in sidecar (invariant constraint file)
        const inv_path = try std.fmt.allocPrint(arena, "{s}.in", .{c_path});
        const invariant_path: ?[]const u8 = if (fileExists(cwd, io, inv_path)) inv_path else null;

        try cases.append(arena, .{
            .c_path = c_path,
            .golden_path = golden_path,
            .dir_path = dir_path,
            .test_id = test_id,
            .flags = flags,
            .targets = targets,
            .invariant_path = invariant_path,
        });
    }
}

// -----------------------------------------------------------------------
// Run a single test
// -----------------------------------------------------------------------

fn runOneTest(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    tc: TestCase,
    idx: usize,
) !void {
    const test_dir = try std.fmt.allocPrint(arena, tmp_base ++ "/{d}", .{idx});
    try std.Io.Dir.cwd().createDirPath(io, test_dir);

    const out_zon = try std.fmt.allocPrint(arena, "{s}/out.zon", .{test_dir});
    const out_fuzzer = try std.fmt.allocPrint(arena, "{s}/fuzzer.c", .{test_dir});
    const out_redef = try std.fmt.allocPrint(arena, "{s}/redef.txt", .{test_dir});
    const out_obj = try std.fmt.allocPrint(arena, "{s}/fuzzer.o", .{test_dir});

    // -- Build absolution argv --
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "zig-out/bin/absolution");
    for (tc.targets) |t| {
        try argv.appendSlice(arena, &.{ "--targets", t });
    }
    if (tc.invariant_path) |inv| {
        try argv.appendSlice(arena, &.{ "-i", inv });
    }
    try argv.appendSlice(arena, &.{ "--zon", out_zon, "--out", out_fuzzer, "--redef", out_redef });
    if (tc.flags.len > 0) {
        try argv.append(arena, "--");
        try argv.appendSlice(arena, tc.flags);
    }

    // 1. Run absolution
    try execCapture(gpa, io, argv.items);

    // 2. Compile generated fuzzer.c
    try execCapture(gpa, io, &.{ "zig", "cc", "-c", out_fuzzer, "-o", out_obj, "-I", tc.dir_path });

    // 3. Golden-file comparison
    const actual = try std.Io.Dir.cwd().readFileAlloc(io, out_zon, gpa, .limited(10 * 1024 * 1024));
    defer gpa.free(actual);
    const expected = try std.Io.Dir.cwd().readFileAlloc(io, tc.golden_path, gpa, .limited(10 * 1024 * 1024));
    defer gpa.free(expected);

    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("    Golden mismatch: expected {s}\n", .{tc.golden_path});
        std.debug.print("    Actual output:   {s}\n", .{out_zon});
        return error.GoldenMismatch;
    }
}

// -----------------------------------------------------------------------
// Subprocess helpers
// -----------------------------------------------------------------------

fn execCapture(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    }) catch |err| {
        std.debug.print("    Failed to spawn:", .{});
        for (argv) |arg| std.debug.print(" {s}", .{arg});
        std.debug.print("\n    {s}\n", .{@errorName(err)});
        return err;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("    Command exited with code {d}:", .{code});
                for (argv) |arg| std.debug.print(" {s}", .{arg});
                std.debug.print("\n", .{});
                if (result.stderr.len > 0) {
                    std.debug.print("    {s}\n", .{std.mem.trimEnd(u8, result.stderr, "\n")});
                }
                return error.CommandFailed;
            }
        },
        else => {
            std.debug.print("    Command terminated abnormally:", .{});
            for (argv) |arg| std.debug.print(" {s}", .{arg});
            std.debug.print("\n", .{});
            return error.CommandFailed;
        },
    }
}

// -----------------------------------------------------------------------
// Output helpers
// -----------------------------------------------------------------------

/// Write formatted text to stdout. Errors are silently discarded.
fn out(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    const stdout = std.Io.File.stdout();
    var buf: [8192]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
    stdout.writeStreamingAll(io, str) catch {};
}

// -----------------------------------------------------------------------
// File helpers
// -----------------------------------------------------------------------

fn fileExists(dir: std.Io.Dir, io: std.Io, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

/// Read non-empty, non-comment lines from a file. Returns error on missing file.
fn readNonCommentLines(arena: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, path: []const u8) ![]const []const u8 {
    const content = try dir.readFileAlloc(io, path, arena, .limited(10 * 1024 * 1024));
    var lines: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        try lines.append(arena, trimmed);
    }
    return lines.items;
}
