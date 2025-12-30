# Fuzzmate

## What is this

Fuzzmate lets you specify an invariant for a program’s global state and fuzz
its entrypoints from states uniformly sampled from that invariant. This helps
surface bugs in any interleaving of calls, assuming the fuzzer can explore the
space sufficiently.

## How it works

- Parse globals from your `--targets` translation unit using `aro`.
- Build flattened globals containing fields, padding, and domains.
- Optionally apply a `.zon` invariant.
- Emit `fuzzer.c` with:
  - `sample_invariant`: hydrates globals from the fuzzer input (or fixed
    domains) and returns the number of remaining bytes.
  - `check_invariant`: asserts padding bytes stay zeroed.
  - `LLVMFuzzerTestOneInput`: feeds the remaining bytes to
    `AbsolutionTestOneInput`, skips the post-call invariant check if the harness
    returns `-1`, and otherwise asserts `check_invariant` succeeds.
- Write a zero-filled seed file sized to the required random bytes (optional).
- Optionally emit the discovered module/invariant back to `.zon`.

## Invariant language (reference)

Invariants are written in Zig’s `.zon` format. The top-level shape is an array
of globals:

```zig
.{
  .{ .name = "<global name>", .dims = .{...}, .fields = .{
    .{ .name = "<.path>", .bit_width = <bits>, .dims = .{...}, .domain = .top | .{ .values = .{"0xAA", ...} } | .{ .pointers = .{"&symbol", ...} } },
    // ...
  }, },
  // ...
}
```

- `.domain` kinds:
  - `.top`: bytes are taken directly from the fuzz input.
  - `.values`: fixed literal bytes (hex strings) copied into the field.
  - `.pointers`: addresses forced to listed symbols (validated against parsed
    globals).
- Globals and fields are flattened: nested structs become dot paths
  (e.g., `.d.e`), padding fields are named with `_pad*`, and arrays list their
  dimensions in `.dims`.
- The number of fuzz-input bytes needed is computed from the globals before
  emission and passed to the emitter; it is not stored in the invariant file.

Example module emitted by the current implementation:

```1:11:tests/basic/basic.c.zon
.{
  .includes = .{"tests/basic/basic.c", "playground/harness.c"},
  .globals = .{
    .{ .name = "astruct", .dims = .{10}, .fields = .{
      .{ .name = ".a", .bit_width = 32, .dims = .{}, .domain = .top },
      // ...
```

## Requirements

- Zig `0.15.2` (per `build.zig.zon`).
- C toolchain that can build libFuzzer binaries (e.g., `clang -fsanitize=fuzzer`
  or `zig cc -fsanitize=fuzzer`).
- When installing, the build copies the bundled libc headers from the Zig
  toolchain into `zig-out/include` so `#include` paths resolve for the generated
  code.

## Build and install

```bash
zig build -fincremental           # builds and installs to zig-out/
zig build run -- -h             # show CLI help
```

The installed binary lives at `zig-out/bin/fuzzmate`; `zig-out/include`
contains the libc headers copied from the active Zig toolchain.

## Quickstart

1. Provide a targets translation unit (`--targets`) containing the globals and
   helper functions your harness depends on.
2. Provide a harness translation unit (`--harness`) that defines
   `int AbsolutionTestOneInput(const uint8_t*, size_t);`. Returning `-1` skips
   the post-call invariant check for that input.
3. Generate sources (optionally capturing the parsed module as `.zon`):

   ```bash
   zig-out/bin/fuzzmate \
     --targets path/to/targets.c \
     --harness path/to/harness.c \
     --out path/to/fuzzer.c \
     --seed path/to/fuzzer.seed \
     --zon path/to/module.zon \
     [--invariant path/to/invariant.zon]
    ```

   Without `--invariant`, all fields default to `.top`. Use `--zon` to capture the
   auto-detected module, edit it to set domains, and feed it back with
   `--invariant`.

4. Build the fuzzer binary (pick your compiler):

   ```bash
   clang -std=c23 -fsanitize=fuzzer,address path/to/fuzzer.c -o path/to/fuzzer
   # or
   zig cc -std=c23 -fsanitize=fuzzer path/to/fuzzer.c -o path/to/fuzzer
   ```

5. Seed and run libFuzzer:

   ```bash
   mkdir -p path/to/corpus
   cp path/to/fuzzer.seed path/to/corpus/
   ./path/to/fuzzer path/to/corpus/
   ```

## CLI usage

- `--targets <str>` (required): C translation unit with the globals to sample.
  The path is included verbatim in the generated C via `#include "..."`.
- `--harness <str>` (required): C translation unit that defines
  `int AbsolutionTestOneInput(const uint8_t*, size_t);`.
- `--invariant <str>`: `.zon` file to apply before emission.
- `--out <str>`: Output C path (default `fuzzer.c`).
- `--zon <str>`: Optional `.zon` dump of the final module (after invariants).
- `--seed <str>`: Optional seed path (default `fzzer.seed`, matching current
  code).
- `--infer-const-intent`: Parsed flag; currently a no-op placeholder.

## Notes and limitations

- Padding is zeroed before the harness call and asserted afterwards.
- Pointer domains are validated against parsed globals when applying an
  invariant; invalid symbols cause an error.
- Unions are treated as opaque storage; bit-fields are ignored.
- Arrays without explicit sizes but with initializers are sized from the
  initializer list.
- Everything is emitted as C23; adjust your compiler flags accordingly.
