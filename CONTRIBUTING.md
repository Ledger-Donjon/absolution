# Contributing

This guide explains the code organization and development workflow for absolution.

## Code Organization

```
absolution/
├── src/
│   ├── main.zig              # CLI entrypoint and argument parsing
│   ├── root.zig              # Library exports (Parser, cgen, invariant)
│   ├── Parser.zig            # C parsing via aro, global/field extraction
│   ├── invariant.zig         # .zon invariant loading and application
│   └── cgen/
│       ├── tree.zig          # Core data structures (Domain, Field, Global)
│       ├── builder.zig       # File writing utilities
│       └── emit.zig          # C code generation (sampler, checker, entrypoint)
├── tests/                    # Integration test cases
│   └── <test_name>/
│       ├── <file>.c          # Test input
│       └── <file>.c.zon      # Golden output
├── scripts/
│   └── integration.sh        # Shell-based integration test runner
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
- Configures include paths to match `zig cc` behavior
- Extracts non-const global variables
- Flattens nested structs into dot-path field names
- Generates synthetic padding fields
- Handles arrays, unions, bit-fields

### `invariant.zig`

Handles `.zon` invariant files:
- Loads and parses invariant specifications
- Validates pointer domain targets
- Applies domain constraints to parsed globals

### `cgen/tree.zig`

Core data structures:
- `Domain`: `.top`, `.values`, `.pointers`
- `Field`: Flattened field with name, width, dimensions, domain
- `Global`: Named global with dimensions and fields

### `cgen/emit.zig`

C code generation:
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
bash scripts/integration.sh  # Integration tests
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

4. Script should be automaticaly discovering the new tests

5. Run to verify:
   ```bash
   bash scripts/integration.sh
   ```

## Architecture Notes

### Parsing pipeline

```
C file → aro Preprocessor → aro Parser → AST traversal → ParsedGlobal[]
```

- Uses aro's built-in preprocessor (self-contained, no external dependencies)
- Configures include paths from bundled libc headers in `zig-out/lib/`
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
