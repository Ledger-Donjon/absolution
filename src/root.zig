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

// Declares here what will be unit tested
test {
    _ = @import("Invariant.zig");
    // add other files with tests here as needed
}
