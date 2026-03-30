# Absolution

Absolution lets you specify an invariant for a program’s global state and fuzz its entrypoints from states uniformly sampled from that invariant. This helps surface bugs in any interleaving of calls, assuming the fuzzer can explore the space sufficiently.

## How it works

1. Parse globals from your C translation unit(s) using [aro](https://github.com/Vexu/aro).
2. Build flattened globals containing fields, padding, and domains.
3. Optionally apply a `.zon` invariant to constrain field values (per-element `.values` / `.pointers`, or whole-field blobs with `.whole_values` on array-shaped fields; see [USAGE.md](USAGE.md)).
4. Emit `fuzzer.c` with sampling, invariant checking, and libFuzzer entrypoint.
5. Emit a symbol redefinition file for `objcopy` (handles `static` globals across translation units).
6. Write an optional seed file sized to the required random bytes.

## Requirements

- **Zig 0.15.2** (per `build.zig.zon`)
- **C toolchain** with libFuzzer support (e.g., `clang -fsanitize=fuzzer`)
- **objcopy** (GNU binutils or `llvm-objcopy`) — for static symbol redefinition

## Quick start

```bash
# Build absolution
zig build -Doptimize=ReleaseFast

# Show CLI help
./zig-out/bin/absolution -h

# Generate fuzzer sources from one or more translation units
./zig-out/bin/absolution \
  -t path/to/module_a.c \
  -t path/to/module_b.c \
  --entry MyTestOneInput \
  --out fuzzer.c \
  --redef fuzzer.redef \
  --seed fuzzer.seed \
  -- -I path/to/include -DMY_DEFINE=42

# Compile targets, apply objcopy, link, and run
clang -g -c module_a.c -o module_a.o
clang -g -c module_b.c -o module_b.o
# (apply objcopy --redefine-sym / --globalize-symbol per fuzzer.redef)
clang -g -fsanitize=fuzzer,address fuzzer.c harness.c module_a.o module_b.o -o fuzzer
mkdir -p corpus && cp fuzzer.seed corpus/
./fuzzer corpus/
```

## CMake integration

Absolution ships CMake modules for `find_package(Absolution)`. After installing,
add fuzzing to an existing CMake project with a single function call:

```cmake
find_package(Absolution REQUIRED)

absolution_add_fuzzer(
    NAME fuzz_my_target
    TARGETS src/module_a.c src/module_b.c
    HARNESS fuzz/my_harness.c
    ENTRY MyTestOneInput
    INCLUDE_DIRECTORIES "${CMAKE_SOURCE_DIR}/include"
    COMPILE_DEFINITIONS "MY_DEFINE=42"
)
```

This creates a CMake target that handles the full pipeline: run absolution,
compile objects, apply `objcopy` symbol redefinitions, and link the final fuzzer
binary with sanitizers.

See **[example/protocol_parser/](example/protocol_parser/)** for a complete
working example with multiple translation units.

## Testing

```bash
zig build test                # Run unit tests
uv run scripts/integration.py # Integration tests (pytest)
```

## Documentation

- **[USAGE.md](USAGE.md)** — Detailed usage guide with examples and behavior reference
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — Code organization and development workflow
- **[example/protocol_parser/](example/protocol_parser/)** — Complete CMake integration example

