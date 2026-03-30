//! Absolution library for invariant-constrained fuzzing of C programs.
//!
//! Main components:
//! - `Parser`: Parses C translation units and extracts global variables
//! - `cgen`: Generates libFuzzer harness C code
//! - `Invariant`: Loads and applies `.zon` invariant specifications

pub const Parser = @import("Parser.zig");
pub const seed = @import("seed.zig");
pub const Invariant = @import("Invariant.zig");
pub const emit = @import("cgen/emit.zig");
pub const ir = @import("cgen/ir.zig");

test {
    _ = @import("Invariant.zig");
    _ = @import("cgen/ir.zig");
    _ = @import("cgen/emit.zig");
    _ = @import("seed.zig");
    _ = @import("type_flatten.zig");
    _ = @import("include_paths.zig");
    _ = @import("Parser.zig");
}
