# Contributing

This guide explains the code organization and development workflow for absolution.

## Code Organization

```
absolution/
├── src/
│   ├── main.zig              # CLI entrypoint and argument parsing
│   ├── root.zig              # Library exports (Parser, cgen, Invariant)
│   ├── Parser.zig            # C parsing via aro, global extraction
│   ├── Invariant.zig         # .zon invariant loading and application
│   ├── type_flatten.zig      # Type flattening (structs, arrays, unions → field list)
│   ├── include_paths.zig     # Include path discovery (zig cc compatibility)
│   ├── seed.zig              # initial seed generation
│   ├── cgen.zig              # Code generation orchestration
│   └── cgen/
│       ├── tree.zig          # Core data structures (Domain, Field, Global)
│       ├── builder.zig       # File writing utilities and type re-exports
│       └── emit.zig          # C code emission (sampler, checker, entrypoint)
├── tests/                    # Integration test cases
│   └── <test_name>/
│       ├── <file>.c          # Test input
│       ├── <file>.c.in       # Optional input invariant
│       └── <file>.c.zon      # Golden output
├── scripts/
│   ├── integration.py        # pytest-based integration test runner
│   └── gen-golden.sh         # Golden file generator
└── build.zig                 # Build configuration
```

## Module Responsibilities

### `main.zig`

CLI interface using the [clap](https://github.com/Hejsil/zig-clap) library:
- Parses command-line arguments
- Orchestrates the parse → generate → emit pipeline
- Writes seed file

### `Parser.zig`

Parses C translation units using [aro](https://github.com/Vexu/aro):
- Initializes the aro toolchain and configures include paths (via `include_paths.zig`)
- Extracts non-const global variables
- Delegates type flattening to `type_flatten.zig`
- Deduplicates non-static globals across translation units

### `type_flatten.zig`

Flattens C types into a linear field list:
- Peels top-level array dimensions from globals
- Recursively flattens structs into dot-path field names
- Generates synthetic padding fields from layout gaps
- Handles arrays, unions, and bit-fields

### `include_paths.zig`

Discovers and configures include search paths to match `zig cc` behavior:
- Adds target-specific, generic, and wildcard libc header directories
- Uses the bundled sysroot under `<prefix>/lib/...`
- Keeps absolution self-contained (no host system headers)

### `Invariant.zig`

Handles `.zon` invariant files:
- Loads and parses invariant specifications
- Validates pointer domain targets
- Applies domain constraints to parsed globals

### `cgen/tree.zig`

Core data structures:
- `Domain`: `.top`, `.values`, `.pointers`
- `Field`: Flattened field with name, width, dimensions, domain
- `Global`: Named global with dimensions and fields

### `cgen.zig`

Code generation orchestration:
- Computes the total fuzzer input bytes needed for sampling
- Delegates file emission to `cgen/emit.zig`

### `cgen/emit.zig`

C code emission:
- `writeFuzzerC`: Writes includes, extern declarations, redef file, sampler, checker, and entrypoint
- `emitSampler`: Generates `sample_invariant()` function
- `emitChecker`: Generates `check_invariant()` function
- `emitEntrypoint`: Generates `LLVMFuzzerTestOneInput()`

## Development Workflow

### Building

```bash
zig build                    # Build to zig-out/
zig build -fincremental      # Incremental build (faster)
zig build run -- --help      # Build and run with args
```

### Testing

```bash
zig build test               # Unit tests (in-source)
zig build test --summary all # Verbose unit test output
uv run scripts/integration.py  # Integration tests (pytest)
```

### Adding a new test case

1. Create a directory under `tests/`:
   ```
   tests/my_test/
   ```

2. Add a C file with the globals to parse:
   ```c
   // tests/my_test/myfile.c
   struct Foo { int x; };
   struct Foo foo;
   ```

3. Generate the golden `.zon` output:
   ```bash
   zig build
   zig-out/bin/absolution -t tests/my_test/myfile.c --zon tests/my_test/myfile.c.zon --redef /dev/null
   # Verify the output is correct
   ```

4. The test runner automatically discovers new tests.

5. Run to verify:
   ```bash
   uv run scripts/integration.py
   ```

## Architecture Notes

### Parsing pipeline

```
C file → aro Preprocessor → aro Parser → AST traversal → ParsedGlobal[]
```

- Uses aro's built-in preprocessor (self-contained, no external dependencies)
- Configures include paths from bundled libc headers via `include_paths.zig`
- System headers are automatically filtered via `Source.Kind` tracking

### Flattening

Nested structures are flattened to dot-path field names:

```c
struct { struct { int x; } inner; } outer;
// Becomes: .inner.x
```

Padding is detected from layout gaps and emitted as `._padN` fields.

### Code generation

The emitter produces C code with:
- Nested loops for array dimensions (global and field)
- Static arrays for `.values` and `.pointers` domains
- Index-based selection for constrained domains

## Code Style

- Follow Zig standard library conventions
- Use `errdefer` for cleanup on error paths
- Prefer `std.ArrayListUnmanaged` for fields to minimize allocations
- Document public functions with `///` doc comments

## Pre-commit

The project uses pre-commit hooks (see `.pre-commit-config.yaml`). Install with:

```bash
pip install pre-commit
pre-commit install
```

## Self-Contained Philosophy

Absolution is completely self-contained at runtime. It uses:
- The bundled aro library for C parsing and preprocessing
- Bundled sysroot headers copied at build time to `zig-out/lib/`

No external tools (zig, clang, gcc) are required at runtime.
