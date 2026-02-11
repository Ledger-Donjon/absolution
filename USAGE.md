# Usage Guide

This guide covers the full workflow for using fuzzmate to fuzz C programs with invariant-constrained global state.

## Overview

Fuzzmate generates a libFuzzer harness that:

1. **Samples** global state from fuzzer input (respecting domain constraints)
2. **Calls** your test harness function (configurable with `--entry`)
3. **Checks** that padding bytes remain zeroed (invariant enforcement)

## CLI Reference

```
fuzzmate [OPTIONS]

OPTIONS:
  -t, --targets <str>...   (required) C translation unit(s) with globals to sample.
  -r, --redef <str>        (required) Output path for symbol redefinition file.
  -o, --out <str>          Output C path (default: fuzzer.c).
  -s, --seed <str>         Seed file path (default: fuzzer.seed).
  -e, --entry <str>        Harness function name (default: AbsolutionTestOneInput).
  -z, --zon <str>          Export parsed module to .zon format.
  -i, --invariant <str>    Apply .zon invariant before emission.
  -I, --include <str>...   Additional include directories for C parsing.
  -D, --define <str>...    Preprocessor defines (NAME or NAME=VALUE).
  -h, --help               Show help and exit.
```

## Workflow

### Step 1: Create your targets file

Your targets file contains the globals you want to fuzz:

```c
// targets.c
typedef struct {
    int value;
    char flags;
} Config;

Config config;

void process_config(void) {
    if (config.value < 0 && config.flags & 0x01) {
        // Potential bug: negative value with flag set
    }
}
```

### Step 2: Create your harness

The harness defines a function that exercises your code. By default fuzzmate
expects `AbsolutionTestOneInput`, but you can choose any name with `--entry`:

```c
// harness.c
#include "targets.c"

int MyTestOneInput(const uint8_t *data, size_t size) {
    process_config();
    return 0;  // Return -1 to skip post-call invariant check
}
```

### Step 3: Generate the fuzzer

```bash
./zig-out/bin/fuzzmate \
  -t targets.c \
  --out fuzzer.c \
  --redef fuzzer.redef \
  --seed fuzzer.seed \
  --entry MyTestOneInput \
  --zon module.zon  # Optional: export parsed structure
```

If your targets need include paths or preprocessor defines:

```bash
./zig-out/bin/fuzzmate \
  -t src/module_a.c -t src/module_b.c \
  -I include/ \
  -D MAX_ITEMS=64 \
  --out fuzzer.c \
  --redef fuzzer.redef \
  --entry MyTestOneInput
```

### Step 4: Apply symbol redefinitions and build

When targets contain `static` globals, fuzzmate generates a `.redef` file
with symbol renames. Apply them with `objcopy` before linking:

```bash
# Compile targets
clang -g -c targets.c -o targets.o

# Apply redefinitions (if any static globals)
while read -r file old new; do
  objcopy --redefine-sym ${old}=${new} ${file}.o
  objcopy --globalize-symbol ${new} ${file}.o
done < fuzzer.redef

# Link and run
clang -g -fsanitize=fuzzer,address fuzzer.c harness.c targets.o -o fuzzer
mkdir -p corpus && cp fuzzer.seed corpus/
./fuzzer corpus/
```

For CMake projects, `fuzzmate_add_fuzzer()` handles all of this automatically.
See the [example/protocol_parser/](example/protocol_parser/) directory.

## Invariant Language

Invariants constrain the domains of global fields. They're written in Zig's `.zon` format.

### Structure

```zig
.{
  .{ .name = "global_name", .dims = .{...}, .fields = .{
    .{ .name = ".field_path", .bit_width = <bits>, .dims = .{...}, .domain = ... },
    // ...
  }},
}
```

### Domain types

| Domain | Description | Fuzzer bytes used |
|--------|-------------|-------------------|
| `.top` | Unconstrained bytes from fuzzer input | `bit_width / 8` |
| `.values` | Fixed literal values (hex strings) | 1 (index selection) |
| `.pointers` | Addresses of listed symbols | 1 (index selection) |

### Example

```zig
.{.{
    .name = "config",
    .dims = .{ .items = .{}, .capacity = 0 },
    .fields = .{ .items = .{
        .{
            .name = ".value",
            .bit_width = 32,
            .dims = .{ .items = .{}, .capacity = 0 },
            .domain = .top,  // Full 4 bytes from fuzzer
        },
        .{
            .name = ".flags",
            .bit_width = 8,
            .dims = .{ .items = .{}, .capacity = 0 },
            .domain = .{ .values = .{ "0x00", "0x01", "0x03" } },  // Only these values
        },
    }},
}}
```

### Field naming conventions

- **Scalar fields**: `.field_name`
- **Nested structs**: `.outer.inner`
- **Padding fields**: `._pad0`, `._pad1`, etc. (auto-generated)

### Array dimensions

- **Global arrays**: Dimensions in the global's `.dims`
- **Field arrays**: Dimensions in the field's `.dims`

Example for `Config configs[10]` with `int values[5]`:

```zig
.{
    .name = "configs",
    .dims = .{ .items = .{10}, .capacity = 16 },
    .fields = .{ .items = .{
        .{ .name = ".values", .bit_width = 32, .dims = .{ .items = .{5}, .capacity = 8 }, .domain = .top },
    }},
}
```

## Generated Code

The generated `fuzzer.c` contains:

### `sample_invariant(data, size)`

Hydrates globals from fuzzer input:
- Returns number of bytes consumed (for remaining harness data)
- Returns `-1` if input is too short
- Zeros all storage before sampling (for padding)

### `check_invariant(void)`

Asserts padding bytes remain zeroed:
- Returns `0` on success
- Returns `-1` on invariant violation

### `LLVMFuzzerTestOneInput(data, size)`

LibFuzzer entrypoint that:
1. Calls `sample_invariant` to set up state
2. Calls your harness function (default `AbsolutionTestOneInput`, or the name
   given to `--entry`) with remaining bytes
3. Calls `check_invariant` unless harness returned `-1`

## Tips

### Exporting and editing invariants

```bash
# Generate with auto-detected domains
./zig-out/bin/fuzzmate -t targets.c --zon module.zon --out fuzzer.c --redef fuzzer.redef

# Edit module.zon to constrain domains...

# Regenerate with constraints applied
./zig-out/bin/fuzzmate -t targets.c --invariant module.zon --out fuzzer.c --redef fuzzer.redef
```

### Pointer domain validation

When using `.pointers` domains, fuzzmate validates that all referenced symbols exist in the parsed globals. Invalid symbols cause an error.

### Skipping invariant checks

Return `-1` from your harness function to skip the post-call invariant check. Useful for:
- Functions that legitimately modify padding
- Early exit paths that don't complete normally

## CMake Integration

Fuzzmate includes CMake modules installed to `lib/cmake/Fuzzmate/`. After
building fuzzmate with `zig build`, point CMake at the install prefix:

```bash
cmake -B build -G Ninja \
    -DENABLE_FUZZING=ON \
    -DCMAKE_C_COMPILER=clang \
    -DFuzzmate_DIR=/path/to/fuzzmate/zig-out/lib/cmake/Fuzzmate

cmake --build build --target my_fuzzer
```

The `fuzzmate_add_fuzzer()` function accepts these keywords:

| Keyword | Required | Description |
|---------|----------|-------------|
| `NAME` | yes | Name of the fuzzer executable target |
| `TARGETS` | yes | C source files whose globals will be fuzzed |
| `HARNESS` | no | C file containing the test function |
| `ENTRY` | no | Harness function name (default: `AbsolutionTestOneInput`) |
| `INVARIANT` | no | `.zon` constraint file |
| `INCLUDE_DIRECTORIES` | no | Extra `-I` paths |
| `COMPILE_DEFINITIONS` | no | Preprocessor defines (`NAME` or `NAME=VALUE`) |
| `COMPILE_OPTIONS` | no | Extra compiler flags for target compilation |
| `LINK_LIBRARIES` | no | Extra libraries to link into the fuzzer |
| `SANITIZERS` | no | Sanitizer list (default: `fuzzer,address`) |

### Transitive property propagation

`LINK_LIBRARIES` entries that are CMake targets automatically propagate their
`PUBLIC` / `INTERFACE` include directories, compile definitions, and compile
options to **all stages** of the fuzzmate pipeline:

- The **fuzzmate CLI** (so aro sees the correct headers and defines)
- The **target `.o` compilation** (so objects match the parsed layout)
- The **harness and `fuzzer.c` compilation** (so the final link is consistent)

This means you typically don't need to duplicate include paths or defines
that are already declared on your library targets:

```cmake
# my_sdk already declares PUBLIC include dirs and defines —
# fuzzmate picks them up automatically via LINK_LIBRARIES.
fuzzmate_add_fuzzer(
    NAME fuzz_my_target
    TARGETS src/module.c
    HARNESS fuzz/harness.c
    ENTRY MyTestOneInput
    LINK_LIBRARIES my_sdk
)
```

See [example/protocol_parser/](example/protocol_parser/) for a complete working example.

## Limitations

- **Unions**: Treated as opaque storage (padding-equivalent)
- **Bit-fields**: Ignored (left as zeros from memset)
- **Incomplete types**: Skipped during parsing
- **C standard**: Emits C23; adjust compiler flags accordingly
