//! Absolution library for invariant-constrained fuzzing of C programs.
//!
//! Main components:
//! - `Parser`: Parses C translation units and extracts global variables
//! - `cgen`: Generates libFuzzer harness C code
//! - `Invariant`: Loads and applies `.zon` invariant specifications

pub const Parser = @import("Parser.zig");
pub const cgen = @import("cgen.zig");
pub const Invariant = @import("Invariant.zig");
