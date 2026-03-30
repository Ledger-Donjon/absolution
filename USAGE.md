# Usage Guide

This guide covers the full workflow for using absolution to fuzz C programs with invariant-constrained global state.
It assumes absolution is already built (`zig build`) or installed; see [README.md](README.md) for requirements (Zig 0.15.2, C toolchain with libFuzzer, objcopy).

## Overview

Absolution generates a libFuzzer harness that:

1. **Samples** global state from fuzzer input (respecting domain constraints)
2. **Calls** your test harness function (configurable with `--entry`)
3. **Checks** that padding bytes remain zeroed (invariant enforcement)

## CLI Reference

```
absolution [OPTIONS] [-- <cflags>...]

OPTIONS:
  -h, --help               Show this help and exit.
  -t, --targets <str>...   (required) Path to target C translation unit(s).
  -o, --out <str>          Output fuzzer C path (default: fuzzer.c).
  -r, --redef <str>        (required) Output path for symbol redefinition file.
  -i, --invariant <str>    Optional invariant file (.zon).
  -z, --zon <str>          Optional: export parsed module to .zon format.
  -s, --seed <str>         Optional seed file path (default: fuzzer.seed).
  -e, --entry <str>        Optional harness function name (default: AbsolutionTestOneInput).

  <str>...                 C compiler flags after '--' (e.g. -I path -DFOO -fshort-enums).
```

## Workflow

### Step 1: Create your targets file

Your targets file contains the globals you want to fuzz:
```c
// targets.h
typedef int (*handler_fn)(int);

// Function pointer table (handlers receive input_value)
extern handler_fn handlers[4];

int handle_a(int n);
int handle_b(int n);
int handle_c(int n);
int handle_d(int n);
```


```c
// targets.c
#include "targets.h"


// Global state: value passed to all handlers
int input_value;

// Function pointer table (handlers receive input_value)
handler_fn handlers[4];

int handle_a(int n) { return n + 1; }
int handle_b(int n) { return n * 2; }
int handle_c(int n) { return n - 1; }
int handle_d(int n) { return -1; }
```

### Step 2: Create your harness

The harness defines a function that exercises your code. By default absolution
expects `AbsolutionTestOneInput`, but you can choose any name with `--entry`:

```c
// harness.c
#include "targets.h"

int MyTestOneInput(const uint8_t *data, size_t size) {
    // For this test we only rely on absolution behavior
    // but you can use data and size to fuzz parameters
    for (int i = 0; i < 4; i++) {
        if (handlers[i] != 0)
            handlers[i](input_value);
    }
    return 0;
}
```

### Step 3: Generate the fuzzer

```bash
absolution \
  -t targets.c \
  --out fuzzer.c \
  --redef fuzzer.redef \
  --seed fuzzer.seed \
  --entry MyTestOneInput \
  --zon module.zon  # Optional: export parsed structure
```

If your targets need include paths or preprocessor defines, pass them after `--`:

```bash
absolution \
  -t targets.c \
  --out fuzzer.c \
  --redef fuzzer.redef \
  --seed fuzzer.seed \
  --entry MyTestOneInput \
  --zon module.zon  # Optional: export parsed structure
  -- -I include/ -DMAX_ITEMS=64
```

### Step 4: Apply symbol redefinitions and build

When targets contain `static` globals, absolution generates a `.redef` file.
Each line has three space-separated fields: **source_path**, **old_symbol**, **new_symbol**.
You must map each source path to the corresponding object file (e.g. `targets.c` → `targets.o`).
Apply redefinitions with `objcopy` before linking:

```bash
# Compile targets
clang -g -c targets.c -o targets.o

# Apply redefinitions (if any static globals)
# Each redef line: source_path old_symbol new_symbol
while read -r src_path old_sym new_sym; do
  obj="${src_path%.c}.o"   # map source path to your object file
  objcopy --redefine-sym "${old_sym}=${new_sym}" "${obj}"
  objcopy --globalize-symbol "${new_sym}" "${obj}"
done < fuzzer.redef

# Link and run
clang -g -fsanitize=fuzzer,address fuzzer.c harness.c targets.o -o fuzzer
mkdir -p corpus && cp fuzzer.seed corpus/
./fuzzer corpus/
```

For CMake projects, `absolution_add_fuzzer()` handles all of this automatically.
See the [example/protocol_parser/](example/protocol_parser/) directory.

## Invariant Language

Invariants constrain the domains of global fields. They are written in Zig's `.zon` format.
The `--invariant` option accepts a path to a `.zon` file produced by `--zon` and optionally edited.

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
            .offset_bits = 0,
            .bit_width = 32,
            .dims = .{},
            .is_padding = false,
            .domain = .top,
        },
        // ...
    },
}}
```

### Domain types

| Domain | Description | Fuzzer bytes used |
|--------|-------------|-------------------|
| `.top` | Unconstrained bytes from fuzzer input | `element_bytes ×` global instances `×` field instances (see dimensions below) |
| `.values` | Fixed literal values (hex strings), **per scalar element** | `0` if there is at most one candidate, else `1` selector byte **per element** (each index in the field’s `.dims`, times global array instances) |
| `.whole_values` | Fixed set of **full field-instance** byte blobs (covers the entire field span, including all of the field’s `.dims`) | `0` if there is at most one candidate, else `1` selector byte **per field instance** (global array instances only; not once per inner array element) |
| `.pointers` | Addresses of listed symbols (per element, same indexing as `.values`) | Same selector rule as `.values` |

Constrained domains (`.values`, `.whole_values`, `.pointers`) allow at most **256** candidates; each multi-candidate domain uses a single selector byte to pick an index.

**When to use `.values` vs `.whole_values` for array-shaped fields**

- Use **`.values`** when each array element should be chosen independently from the same small set (or when the field is scalar). The sampler loops over dimensions and spends up to one selector byte per element.
- Use **`.whole_values`** when the entire array (or blob) must be one of a few fixed byte patterns end-to-end. Each candidate blob’s length must equal the field’s total byte span: `(bit_width / 8) × ∏` field dimension lengths. Do not rely on candidate string length alone to imply whole-field semantics; encode intent explicitly with `.whole_values`.

### Example

```zig
.{ .{
    .name = "input_value",
    .source_file = "tests/function_pointers_with_invariant_constraint/target.c",
    .size_bytes = 4,
    .is_static = false,
    .dims = .{},
    .fields = .{
        .{
            .name = ".",
            .offset_bits = 0,
            .bit_width = 32,
            .dims = .{},
            .is_padding = false,
            .domain = .{ .values = .{
                "\x00",
                "\x01",
                "\x64",
            } },
        },
    },
}, .{
    .name = "handlers",
    .source_file = "tests/function_pointers_with_invariant_constraint/target.c",
    .size_bytes = 32,
    .is_static = false,
    .dims = .{.{ .len = 4, .stride_bytes = 8 }},
    .fields = .{
        .{
            .name = ".",
            .offset_bits = 0,
            .bit_width = 64,
            .dims = .{.{ .len = 4, .stride_bytes = 8 }},
            .is_padding = false,
            .domain = .{ .pointers = .{
                "handle_a",
                "handle_b",
                "handle_c",
                "handle_d",
            } },
        },
    },
} }
```

Whole-field value example (`uint8_t b[8]` must be exactly one of two 8-byte patterns; one selector byte for the field, not eight):

```zig
.{.{
    .name = "pkt",
    .source_file = "my_module.c",
    .size_bytes = 8,
    .is_static = false,
    .dims = .{},
    .fields = .{.{
        .name = ".b",
        .offset_bits = 0,
        .bit_width = 8,
        .dims = .{.{ .len = 8, .stride_bytes = 1 }},
        .is_padding = false,
        .domain = .{ .whole_values = .{
            "\x00\x01\x02\x03\x04\x05\x06\x07",
            "\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xff",
        } },
    }},
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
            .offset_bits = 0,
            .bit_width = 32,
            .dims = .{.{ .len = 5, .stride_bytes = 4 }},
            .is_padding = false,
            .domain = .top,
        },
    },
}}
```

## Generated Code

The generated `fuzzer.c` contains:

### `sample_invariant(data, size)`

Instantiate globals from fuzzer input (signature: `ptrdiff_t sample_invariant(const uint8_t *data, size_t size)`):
- Returns the number of bytes consumed (for the remaining harness data)
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
absolution -t targets.c --zon targets.zon --out fuzzer.c --redef fuzzer.redef

# Edit targets.zon to constrain domains...

# Regenerate with constraints applied
absolution -t targets.c --invariant targets.zon --out fuzzer.c --redef fuzzer.redef
```

### Pointer domain validation

When using `.pointers` domains, absolution validates that all referenced symbols exist in the parsed globals. Invalid symbols cause an error.

### Skipping invariant checks

Return `-1` from your harness function to skip the post-call invariant check. Useful for:
- Functions that legitimately modify padding
- Early exit paths that don't complete normally

## CMake Integration

Absolution includes CMake modules installed to `lib/cmake/Absolution/`.
Point CMake at the install prefix:

```bash
cmake -B build -G Ninja \
    -DENABLE_FUZZING=ON \
    -DCMAKE_C_COMPILER=clang \
    -DAbsolution_DIR=/path/to/absolution/release/lib/cmake/Absolution

cmake --build build --target my_fuzzer
```

The `absolution_add_fuzzer()` function accepts these keywords:

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
options to **all stages** of the absolution pipeline:

- The **absolution CLI** (so aro sees the correct headers and defines)
- The **target `.o` compilation** (so objects match the parsed layout)
- The **harness and `fuzzer.c` compilation** (so the final link is consistent)

This means you typically don't need to duplicate include paths or defines
that are already declared on your library targets:

```cmake
# my_sdk already declares PUBLIC include dirs and defines —
# absolution picks them up automatically via LINK_LIBRARIES.
absolution_add_fuzzer(
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
