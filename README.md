# Fuzzmate

Fuzzmate lets you specify an invariant for a program's global state and fuzz its entrypoints from states uniformly sampled from that invariant. This helps surface bugs in any interleaving of calls, assuming the fuzzer can explore the space sufficiently.

## How it works

1. Parse globals from your C translation unit(s) using [aro](https://github.com/Vexu/aro).
2. Build flattened globals containing fields, padding, and domains.
3. Optionally apply a `.zon` invariant to constrain field values.
4. Emit `fuzzer.c` with sampling, invariant checking, and libFuzzer entrypoint.
5. Emit a symbol redefinition file for `objcopy` (handles `static` globals across translation units).
6. Write an optional seed file sized to the required random bytes.

## Requirements

- **Zig 0.15.2** (per `build.zig.zon`)
- **C toolchain** with libFuzzer support (e.g., `clang -fsanitize=fuzzer`)
- **objcopy** (GNU binutils or `llvm-objcopy`) — for static symbol redefinition

## Quick start

```bash
# Build fuzzmate
zig build

# Show CLI help
./zig-out/bin/fuzzmate -h

# Generate fuzzer sources from one or more translation units
./zig-out/bin/fuzzmate \
  -t path/to/module_a.c \
  -t path/to/module_b.c \
  -I path/to/include \
  -D MY_DEFINE=42 \
  --entry MyTestOneInput \
  --out fuzzer.c \
  --redef fuzzer.redef \
  --seed fuzzer.seed

# Compile targets, apply objcopy, link, and run
clang -g -c module_a.c -o module_a.o
clang -g -c module_b.c -o module_b.o
# (apply objcopy --redefine-sym / --globalize-symbol per fuzzer.redef)
clang -g -fsanitize=fuzzer,address fuzzer.c harness.c module_a.o module_b.o -o fuzzer
mkdir -p corpus && cp fuzzer.seed corpus/
./fuzzer corpus/
```

## Testing

```bash
zig build test    # Run unit tests
zig build it      # Run integration tests (golden .zon comparison)
```

## Documentation

- **[USAGE.md](USAGE.md)** — Detailed usage guide with examples and behavior reference
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — Code organization and development workflow
