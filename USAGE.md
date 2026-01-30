# Usage Guide

This guide covers the full workflow for using fuzzmate to fuzz C programs with invariant-constrained global state.

## Overview

Fuzzmate generates a libFuzzer harness that:

1. **Samples** global state from fuzzer input (respecting domain constraints)
2. **Calls** your test harness function `AbsolutionTestOneInput`
3. **Checks** that padding bytes remain zeroed (invariant enforcement)

## CLI Reference

```
fuzzmate [OPTIONS]

OPTIONS:
  --targets <path>    (required) C translation unit with globals to sample.
                      This path is included verbatim via #include "...".

  --out <path>        Output C path (default: fuzzer.c)

  --seed <path>       Seed file path (default: fuzzer.seed)

  --zon <path>        Export parsed module to .zon format

  --invariant <path>  Apply .zon invariant before emission

  -h, --help          Show help and exit
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

The harness must define `AbsolutionTestOneInput`:

```c
// harness.c
#include "targets.c"

int AbsolutionTestOneInput(const uint8_t *data, size_t size) {
    process_config();
    return 0;  // Return -1 to skip post-call invariant check
}
```

### Step 3: Generate the fuzzer

```bash
zig-out/bin/fuzzmate \
  --targets targets.c \
  --out fuzzer.c \
  --seed fuzzer.seed \
  --zon module.zon  # Optional: export parsed structure
```

### Step 4: Build and run

```bash
# With clang
clang -std=c23 -fsanitize=fuzzer,address fuzzer.c -o fuzzer

# Or with zig
zig cc -std=c23 -fsanitize=fuzzer fuzzer.c -o fuzzer

# Seed the corpus and run
mkdir -p corpus
cp fuzzer.seed corpus/
./fuzzer corpus/
```

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
2. Calls your `AbsolutionTestOneInput` with remaining bytes
3. Calls `check_invariant` unless harness returned `-1`

## Tips

### Exporting and editing invariants

```bash
# Generate with auto-detected domains
fuzzmate --targets targets.c --zon module.zon --out fuzzer.c

# Edit module.zon to constrain domains...

# Regenerate with constraints applied
fuzzmate --targets targets.c --invariant module.zon --out fuzzer.c
```

### Pointer domain validation

When using `.pointers` domains, fuzzmate validates that all referenced symbols exist in the parsed globals. Invalid symbols cause an error.

### Skipping invariant checks

Return `-1` from `AbsolutionTestOneInput` to skip the post-call invariant check. Useful for:
- Functions that legitimately modify padding
- Early exit paths that don't complete normally

## Limitations

- **Unions**: Treated as opaque storage (padding-equivalent)
- **Bit-fields**: Ignored (left as zeros from memset)
- **Incomplete types**: Skipped during parsing
- **C standard**: Emits C23; adjust compiler flags accordingly
