# Fuzzmate

Fuzzmate lets you specify an invariant for a program's global state and fuzz its entrypoints from states uniformly sampled from that invariant. This helps surface bugs in any interleaving of calls, assuming the fuzzer can explore the space sufficiently.

## How it works

1. Parse globals from your C translation unit using [aro](https://github.com/Vexu/aro).
2. Build flattened globals containing fields, padding, and domains.
3. Optionally apply a `.zon` invariant to constrain field values.
4. Emit `fuzzer.c` with sampling, invariant checking, and libFuzzer entrypoint.
5. Write an optional seed file sized to the required random bytes.

## Requirements

- **Zig 0.15.2** (per `build.zig.zon`)
- **C toolchain** with libFuzzer support (e.g., `clang -fsanitize=fuzzer` or `zig cc -fsanitize=fuzzer`)

## Quick start

```bash
# Build
zig build

# Show CLI help
zig build run -- -h

# Generate fuzzer sources
zig-out/bin/fuzzmate \
  --targets path/to/targets.c \
  --out fuzzer.c \
  --seed fuzzer.seed

# Build and run the fuzzer
clang -std=c23 -fsanitize=fuzzer,address fuzzer.c -o fuzzer
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
