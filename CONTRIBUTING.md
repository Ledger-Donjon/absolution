# Contributing

This guide explains the code organization and development workflow for fuzzmate.

## Code Organization

```
fuzzmate/
├── src/
│   ├── main.zig           # CLI entrypoint and argument parsing
│   ├── root.zig           # Library exports (Parser, cgen, invariant)
│   ├── Parser.zig         # C parsing via aro, global/field extraction
│   ├── invariant.zig      # .zon invariant loading and application
│   ├── integration_test.zig   # Integration test runner
│   └── cgen/
│       ├── tree.zig       # Core data structures (Domain, Field, Global)
│       ├── builder.zig    # File writing utilities
│       └── emit.zig       # C code generation (sampler, checker, entrypoint)
├── tests/                 # Integration test cases
│   └── <test_name>/
│       ├── <file>.c       # Test input
│       └── <file>.c.zon   # Golden output
├── scripts/
│   └── integration.sh     # Shell-based integration test runner
└── build.zig              # Build configuration
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
zig build it                 # Integration tests (golden comparison)
zig build test --summary all # Verbose unit test output
zig build it --summary all   # Verbose integration test output
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
   zig-out/bin/fuzzmate --targets tests/my_test/myfile.c --zon tests/my_test/myfile.c.zon
   # Verify the output is correct
   ```

4. Add the test case to `src/integration_test.zig`:
   ```zig
   test "my_test" {
       try runGoldenTest("my_test", "myfile.c");
   }
   ```

5. Run to verify:
   ```bash
   zig build it
   ```

## Architecture Notes

### Parsing pipeline

```
C file → aro Preprocessor → aro Parser → AST traversal → ParsedGlobal[]
```

- Uses `zig cc -E` for preprocessing when available (matches Zig's include resolution)
- Falls back to aro's built-in preprocessor if `zig` is unavailable
- Configures include paths from bundled libc headers in `zig-out/lib/`

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

## Environment Variables

| Variable | Description |
|----------|-------------|
| `FUZZMATE_ZIG` | Override the Zig executable used for preprocessing |
