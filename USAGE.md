# Usage Guide

This guide covers the full workflow for using absolution to fuzz C programs with invariant-constrained global state.
It assumes absolution is already built (`zig build`) or installed; see [README.md](README.md) for requirements (Zig 0.16.0, C toolchain with libFuzzer, objcopy).

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
  -S, --symbolic <str>     Emit a symbolic-execution driver for the given engine: 'klee'.
  -a, --apdu-size <str>    Optional symbolic APDU byte size (symbolic mode; default: 260).
  -P, --no-symbolic-pointers  Symbolic mode: leave unconstrained pointer globals NULL.
      --no-post-check      Do not assert check_invariant() after the harness returns.
  -Z, --zero-symbols <str>...  Zero-symbol list(s); unmatched selectors are reported.
      --lenient-zero-symbols <str>...  Shared zero-symbol list(s); unmatched selectors are silent.
  -O, --domain-overrides <str>...  Override file(s); unmatched lines are fatal.

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

The symbolic driver (`AbsolutionSymbolicTestOneInput`) applies the same
post-condition. Both files `#undef NDEBUG` before `<assert.h>`, so release
flags cannot compile the check out.

The post-condition assumes the harness keeps the globals inside the sampled
domain. A harness that drives the program forward on purpose (for example a
multi-step session started from a reset state) leaves them outside it on every
run. Pass `--no-post-check` (CMake: `NO_POST_CHECK`) to drop the assertion.

## Tips

### Zero lists and domain overrides

Most projects only need a few tweaks on top of the discovered model. Instead
of exporting, editing and re-importing a `.zon`, pass them in the same run:

```bash
absolution -t app.c -o fuzzer.c -r fuzzer.redef \
    -Z zero-symbols.txt --lenient-zero-symbols sdk-zero-symbols.txt \
    -O domain-overrides.txt -- -Iinclude
```

A zero list has one selector per line (`#` comments). `g_ctx` matches every
global named `g_ctx`; `g_ctx@src/feature.c` only the one whose source path
contains `src/feature.c`. Matched globals get one all-zero value, so they no
longer consume input bytes.

An override file has one line per field, applied after the zero lists. A
comment takes a whole line:

```
# whole scalar global
appState. = values \x00 \x01 \x02
txContext.txType = values \x00 \x02
# re-open a zeroed field
g_ctx.metadata.op_type = top
# every enumerator of a C enum
G_context.state = enum app_state_t
```

The selector splits on the first dot (`g.a.b` is field `.a.b` of `g`). Values
are byte strings with `\xNN` escapes, zero-padded to the field element size.
`enum T` takes the enumerators of the C enum `T` (tag or typedef name) found in
the parsed sources.
The order is: `--invariant`, then zero lists, then overrides. `--zon` exports
the tuned model. In CMake, pass `ZERO_SYMBOLS`, `LENIENT_ZERO_SYMBOLS` and
`DOMAIN_OVERRIDES`; editing any of these files regenerates the driver.

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

## Symbolic execution (KLEE)

With `--symbolic klee`, absolution emits a symbolic-execution driver instead of
a libFuzzer harness. The driver reuses the same `sample_invariant()` sampler,
so every domain constraint (`.top`, `.values`, `.whole_values`, `.pointers`)
applies symbolically. Two things become symbolic:

1. **The constrained globals**, hydrated by `sample_invariant()` from the
   prefix of a symbolic input buffer, so enum/state fields stay within their
   `.values` sets while `top` fields are fully symbolic.
2. **The APDU**, the trailing bytes of that buffer, passed to your existing
   harness as `entry(data, size)`.

The driver mirrors the fuzzer's split of a runtime `main` and a test callback:
`AbsolutionSymbolicTestOneInput()` is the analysis body and a thin `main()`
calls it. The body marks the global buffer `absolution_sym_input` symbolic
(`klee_make_symbolic` under `-DABSOLUTION_KLEE`), runs the sampler, and forwards
the trailing APDU bytes to your harness. Built without `-DABSOLUTION_KLEE`, the
driver reads the buffer from stdin instead, so a test case replays natively
(`./driver < input`).

The buffer has the fuzzer driver's input layout: a KLEE test case replays on
the libFuzzer build unchanged, so it can be triaged with the fuzzer binary.

```text
  absolution_sym_input[]        symbolic, GLOBALS_SIZE + APDU_SIZE bytes
     |
     v
  AbsolutionSymbolicTestOneInput()
     |  absolution_sym_prepare(input, GLOBALS_SIZE, APDU_SIZE)   weak, no-op
     |  sample_invariant(input, size)     prefix -> globals, within domains
     v
  entry(input + consumed, APDU_SIZE)      your harness, real app code;
     |                                    KLEE forks on every symbolic branch
     v
  check_invariant()                       post-condition (unless --no-post-check)
```

### Preparing the input before sampling

Between `SYM_MAKE_SYMBOLIC` and `sample_invariant()`, the driver calls
`void absolution_sym_prepare(uint8_t *input, size_t globals_size, size_t apdu_size)`.
The driver's own definition is weak and does nothing. A harness that defines it
can constrain or concretize bytes of `absolution_sym_input` there (for example
with `klee_assume()`), and the globals sampled next see the result: a byte fixed
later, in the harness entry, would leave the globals holding expressions over the
symbolic byte. The Ledger SDK harness uses it under KLEE to replay a seed
concretely except the bytes a second seed object, a byte mask, names
(`LEDGER_SYM_SEED_MASKS`).

### Generate

```bash
absolution \
  -t src/decoder.c -t src/session.c \
  --symbolic klee \
  --out symbolic.c \
  --redef symbolic.redef \
  --apdu-size 260 \
  --entry FuzzDecode \
  -- -I include/
```

This writes `symbolic.c` (the driver) and `symbolic.redef` (static-symbol
redefinitions, applied as in the fuzzer flow). No seed file is produced in
symbolic mode. `-P` (`--no-symbolic-pointers`) leaves unconstrained
pointer-typed globals NULL: a symbolic address makes KLEE resolve a wild
pointer over the whole address space.

### CMake: `absolution_add_symbolic_target()`

The symbolic sibling of `absolution_add_fuzzer()` takes the same `TARGETS`,
`HARNESS`, `ENTRY`, `INVARIANT`, zero lists and overrides, and builds one LLVM
bitcode module for KLEE:

```cmake
absolution_add_symbolic_target(
    NAME sym_decode
    TARGETS src/decoder.c src/session.c
    HARNESS fuzz/fuzz_decode.c
    ENTRY   FuzzDecode
    APDU_SIZE 300
    LINK_LIBRARIES protocol
    BITCODE_TOOLCHAIN_BIN /path/to/clang+llvm-13/bin   # KLEE 3.x reads LLVM 13
)
```

```bash
cmake --build build --target sym_decode        # driver + sym_decode.bc
cmake --build build --target sym_decode_klee   # run KLEE, list its error paths
```

The build compiles every TU to bitcode with `-DABSOLUTION_KLEE`, applies the
`.redef` renames at the IR level (`llvm-objcopy` cannot edit bitcode), and links
with `llvm-link`. The main options (full list in
[cmake/AbsolutionSymbolic.cmake](cmake/AbsolutionSymbolic.cmake)):

- `UBSAN`: instrument the app with `-fsanitize=undefined` and link abort-on-UB
  stubs, so undefined behavior becomes a KLEE error path. `CONV_FILES` adds the
  implicit-conversion checks, on the named files only.
- `ALLOC_SHIM`: replace the Ledger SDK allocator with a malloc-backed shim, so a
  symbolic value reaching the heap does not stall the solver.
- `SKIP_POINTERS` and `NO_POST_CHECK`: same as `-P` and `--no-post-check`.
- `KLEE_MAX_TIME`, `KLEE_JOBS`, `KLEE_SEED_SLICE`, `KLEE_ARGS` and
  `KLEE_COMMAND`: the time budget, the number of KLEE processes run side by side
  (`@JOB@` in `KLEE_ARGS` becomes the job number, e.g. for one seed directory
  per job), a per-seed time slice, extra flags and the launcher.

A run that ends at its time budget is a normal end. The `_klee` target then
lists every `*.err` file under `klee_out/` (one subdirectory per job); each has
a matching `*.ktest` with the concrete input. It fails only when no KLEE job
started.

See [example/protocol_parser/](example/protocol_parser/) for a working example.

## Limitations

- **Unions**: Treated as opaque storage (padding-equivalent)
- **Bit-fields**: Ignored (left as zeros from memset)
- **Incomplete types**: Skipped during parsing
- **C standard**: Emits C23; adjust compiler flags accordingly
