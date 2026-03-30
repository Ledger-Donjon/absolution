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

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // 0. Parse optional filter from argv
    const process_args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, process_args);
    // process_args[0] is the binary itself; anything after is a filter
    const filter: ?[]const u8 = if (process_args.len > 1) process_args[1] else null;
    if (filter) |f| out(bold ++ "Filter: " ++ reset ++ "{s}\n", .{f});

    // 1. Build absolution
    out(bold ++ "Building absolution..." ++ reset ++ "\n", .{});
    try buildAbsolution(gpa);

    std.fs.cwd().access("zig-out/bin/absolution", .{}) catch {
        out(red ++ "absolution binary not found at zig-out/bin/absolution" ++ reset ++ "\n", .{});
        std.process.exit(1);
    };

    // 2. Discover tests
    var cases: std.ArrayList(TestCase) = .empty;
    try discoverTests(arena, &cases);
    std.mem.sort(TestCase, cases.items, {}, struct {
        fn lt(_: void, a: TestCase, b: TestCase) bool {
            return std.mem.order(u8, a.test_id, b.test_id) == .lt;
        }
    }.lt);

    out("Collected " ++ bold ++ "{d}" ++ reset ++ " test(s)\n\n", .{cases.items.len});

    // 3. Prepare temp directory (clean slate each run)
    std.fs.deleteTreeAbsolute(tmp_base) catch {};
    try std.fs.cwd().makePath(tmp_base);

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
            out("  " ++ yellow ++ "SKIP" ++ reset ++ "  {s}  " ++ dim ++ "({s})" ++ reset ++ "\n", .{ tc.test_id, reason });
            skipped += 1;
            continue;
        }

        if (runOneTest(gpa, arena, tc, idx)) {
            out("  " ++ green ++ "PASS" ++ reset ++ "  {s}\n", .{tc.test_id});
            passed += 1;
        } else |err| {
            out("  " ++ red ++ "FAIL" ++ reset ++ "  {s}  " ++ dim ++ "({s})" ++ reset ++ "\n", .{ tc.test_id, @errorName(err) });
            failed += 1;
        }
    }

    // 5. Summary
    if (filter != null and filtered_count == 0) {
        out(red ++ "No tests matched filter" ++ reset ++ "\n", .{});
        std.process.exit(1);
    }
    out("\n" ++ bold ++ "{d}" ++ reset ++ " passed", .{passed});
    if (failed > 0) out(", " ++ bold ++ red ++ "{d} failed" ++ reset, .{failed});
    if (skipped > 0) out(", " ++ bold ++ yellow ++ "{d} skipped" ++ reset, .{skipped});
    out("\n", .{});

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

fn buildAbsolution(allocator: std.mem.Allocator) !void {
    var child = std.process.Child.init(&.{ "zig", "build", "install" }, allocator);
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            out(red ++ "Build failed (exit code {d})" ++ reset ++ "\n", .{code});
            std.process.exit(1);
        },
        else => {
            out(red ++ "Build terminated abnormally" ++ reset ++ "\n", .{});
            std.process.exit(1);
        },
    }
}

// -----------------------------------------------------------------------
// Test discovery
// -----------------------------------------------------------------------

fn discoverTests(arena: std.mem.Allocator, cases: *std.ArrayList(TestCase)) !void {
    const cwd = std.fs.cwd();
    var tests_dir = cwd.openDir("tests", .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open tests/ directory: {s}\n", .{@errorName(err)});
        return err;
    };
    defer tests_dir.close();

    var walker = try tests_dir.walk(arena);
    defer walker.deinit();

    while (try walker.next()) |entry| {
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
        if (fileExists(cwd, skip_path)) {
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
        if (!fileExists(cwd, golden_path)) continue;

        // .flags sidecar (extra compiler flags after --)
        const flags_path = try std.fmt.allocPrint(arena, "{s}.flags", .{c_path});
        const flags: []const []const u8 = readNonCommentLines(arena, cwd, flags_path) catch &.{};

        // .targets sidecar (explicit target list, or fall back to the .c file itself)
        const targets_path = try std.fmt.allocPrint(arena, "{s}.targets", .{c_path});
        const targets: []const []const u8 = blk: {
            const lines = readNonCommentLines(arena, cwd, targets_path) catch {
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
        const invariant_path: ?[]const u8 = if (fileExists(cwd, inv_path)) inv_path else null;

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
    tc: TestCase,
    idx: usize,
) !void {
    const test_dir = try std.fmt.allocPrint(arena, tmp_base ++ "/{d}", .{idx});
    try std.fs.cwd().makePath(test_dir);

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
    try execCapture(gpa, argv.items);

    // 2. Compile generated fuzzer.c
    try execCapture(gpa, &.{ "zig", "cc", "-c", out_fuzzer, "-o", out_obj, "-I", tc.dir_path });

    // 3. Golden-file comparison
    const actual = try std.fs.cwd().readFileAlloc(gpa, out_zon, 10 * 1024 * 1024);
    defer gpa.free(actual);
    const expected = try std.fs.cwd().readFileAlloc(gpa, tc.golden_path, 10 * 1024 * 1024);
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

fn execCapture(gpa: std.mem.Allocator, argv: []const []const u8) !void {
    const result = std.process.Child.run(.{
        .allocator = gpa,
        .argv = argv,
        .max_output_bytes = 10 * 1024 * 1024,
    }) catch |err| {
        std.debug.print("    Failed to spawn:", .{});
        for (argv) |arg| std.debug.print(" {s}", .{arg});
        std.debug.print("\n    {s}\n", .{@errorName(err)});
        return err;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("    Command exited with code {d}:", .{code});
                for (argv) |arg| std.debug.print(" {s}", .{arg});
                std.debug.print("\n", .{});
                if (result.stderr.len > 0) {
                    std.debug.print("    {s}\n", .{std.mem.trimRight(u8, result.stderr, "\n")});
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
fn out(comptime fmt: []const u8, args: anytype) void {
    const stdout = std.fs.File.stdout();
    var buf: [8192]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
    stdout.writeAll(str) catch {};
}

// -----------------------------------------------------------------------
// File helpers
// -----------------------------------------------------------------------

fn fileExists(dir: std.fs.Dir, path: []const u8) bool {
    dir.access(path, .{}) catch return false;
    return true;
}

/// Read non-empty, non-comment lines from a file. Returns error on missing file.
fn readNonCommentLines(arena: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) ![]const []const u8 {
    const content = try dir.readFileAlloc(arena, path, 10 * 1024 * 1024);
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
