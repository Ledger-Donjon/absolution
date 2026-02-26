# Usage Guide

This guide covers the full workflow for using fuzzmate to fuzz C programs with invariant-constrained global state.

## Overview

Fuzzmate generates a libFuzzer harness that:

1. **Samples** global state from fuzzer input (respecting domain constraints)
2. **Calls** your test harness function (configurable with `--entry`)
3. **Checks** that padding bytes remain zeroed (invariant enforcement)

## CLI Reference

```
fuzzmate [OPTIONS] [-- <cflags>...]

OPTIONS:
  -t, --targets <str>...   (required) C translation unit(s) with globals to sample.
  -r, --redef <str>        (required) Output path for symbol redefinition file.
  -o, --out <str>          Output C path (default: fuzzer.c).
  -s, --seed <str>         Seed file path (default: fuzzer.seed).
  -e, --entry <str>        Harness function name (default: AbsolutionTestOneInput).
  -z, --zon <str>          Export parsed module to .zon format.
  -i, --invariant <str>    Apply .zon invariant before emission.
  -h, --help               Show help and exit.

POSITIONAL (after '--'):
  C compiler flags passed directly to the parser (e.g. -I path -DFOO -fshort-enums).
```

## Workflow

### Step 1: Create your targets file

Your targets file contains the globals you want to fuzz:
```c
// targets.h
typedef struct {
    int value;
    char flags;
} Config;

void process_config(void);
```


```c
#include targets.h
// targets.c


// Because it is not `const` it will be collected by fuzzmate
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
#include "targets.h"

int MyTestOneInput(const uint8_t *data, size_t size) {
    // For this test we only rely on fuzzmate behavior
    // but you can use data and size to fuzz parameters
    process_config();
    return 0;
}
```

### Step 3: Generate the fuzzer

```bash
fuzzmate \
  -t targets.c \
  --out fuzzer.c \
  --redef fuzzer.redef \
  --seed fuzzer.seed \
  --entry MyTestOneInput \
  --zon module.zon  # Optional: export parsed structure
```

If your targets need include paths or preprocessor defines, pass them after `--`:

```bash
fuzzmate \
  -t targets.c \
  --out fuzzer.c \
  --redef fuzzer.redef \
  --seed fuzzer.seed \
  --entry MyTestOneInput \
  --zon module.zon  # Optional: export parsed structure
  -- -I include/ -DMAX_ITEMS=64
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

Each global is serialized with its metadata, dimensions, and a flat list of
fields:

```zig
.{.{
    .name = "global_name",
    .source_file = "path/to/source.c",
    .size_bytes = 8,
    .is_static = false,
    .dims = .{},                    // slice of .{ .len, .stride_bytes }
    .fields = .{
        .{
            .name = ".field_path",
            .pad_container = null,  // non-null for padding fields
            .offset_bits = 0,
            .bit_width = 32,
            .dims = .{},
            .dim_positions = .{},
            .is_padding = false,
            .domain = .top,
            .domain_owned = false,
        },
        // ...
    },
}}
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
    .source_file = "config.c",
    .size_bytes = 8,
    .is_static = false,
    .dims = .{},
    .fields = .{
        .{
            .name = ".value",
            .pad_container = null,
            .offset_bits = 0,
            .bit_width = 32,
            .dims = .{},
            .dim_positions = .{},
            .is_padding = false,
            .domain = .top,         // Full 4 bytes from fuzzer
            .domain_owned = false,
        },
        .{
            .name = ".flags",
            .pad_container = null,
            .offset_bits = 32,
            .bit_width = 8,
            .dims = .{},
            .dim_positions = .{},
            .is_padding = false,
            .domain = .{ .values = .{ "0x00", "0x01", "0x03" } },  // Only these values
            .domain_owned = false,
        },
    },
}}
```

### Field naming conventions

- **Scalar fields**: `.field_name`
- **Nested structs**: `.outer.inner`
- **Padding fields**: `._pad0`, `._pad1`, etc. (auto-generated, with `.is_padding = true`)

### Array dimensions

Global-level and field-level arrays are both expressed as a `.dims` slice of
`{ .len, .stride_bytes }` entries:

- **Global arrays**: Dimensions in the global's `.dims`
- **Field arrays**: Dimensions in the field's `.dims`

Example for `Config configs[10]` with `int values[5]` (struct size 8 bytes):

```zig
.{.{
    .name = "configs",
    .source_file = "configs.c",
    .size_bytes = 80,
    .is_static = false,
    .dims = .{.{ .len = 10, .stride_bytes = 8 }},
    .fields = .{
        .{
            .name = ".values",
            .pad_container = null,
            .offset_bits = 0,
            .bit_width = 32,
            .dims = .{.{ .len = 5, .stride_bytes = 4 }},
            .dim_positions = .{},
            .is_padding = false,
            .domain = .top,
            .domain_owned = false,
        },
    },
}}
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
fuzzmate -t targets.c --zon targets.zon --out fuzzer.c --redef fuzzer.redef

# Edit targets.zon to constrain domains...

# Regenerate with constraints applied
fuzzmate -t targets.c --invariant targets.zon --out fuzzer.c --redef fuzzer.redef
```

### Pointer domain validation

When using `.pointers` domains, fuzzmate validates that all referenced symbols exist in the parsed globals. Invalid symbols cause an error.

### Skipping invariant checks

Return `-1` from your harness function to skip the post-call invariant check. Useful for:
- Functions that legitimately modify padding
- Early exit paths that don't complete normally

## CMake Integration

Fuzzmate includes CMake modules installed to `lib/cmake/Fuzzmate/`.
Point CMake at the install prefix:

```bash
cmake -B build -G Ninja \
    -DENABLE_FUZZING=ON \
    -DCMAKE_C_COMPILER=clang \
    -DFuzzmate_DIR=/path/to/fuzzmate/release/lib/cmake/Fuzzmate

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
