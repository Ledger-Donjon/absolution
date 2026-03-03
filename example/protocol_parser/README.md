# Example: Protocol Parser with CMake Integration

This example shows how to integrate absolution into an existing CMake project. It
is a small packet decoder/validator with global configuration state that
absolution samples automatically.

## Project layout

```
protocol_parser/
├── CMakeLists.txt              # Library + app + fuzzing targets
├── include/protocol.h          # Shared types and API
├── src/
│   ├── main.c                  # Demo application (not fuzzed)
│   ├── decoder.c               # Packet decoder — has static decoder_config
│   └── session.c               # Session tracker — has static session state
└── fuzz/
    └── fuzz_decode.c           # Fuzz harness: FuzzDecode()
```

### What gets fuzzed

`decoder.c` has a `static struct decoder_config` (max payload size, allowed
versions bitmask, strict sequencing flag) and `session.c` has a
`static struct session` (sequence counter, rx/error counts). Both are file-local
(`static`), so absolution mangles their symbols with `objcopy` to make them
globally visible for the generated `fuzzer.c`.

The harness in `fuzz/fuzz_decode.c` defines `FuzzDecode()` which runs the
decode → validate → process pipeline. The generated `LLVMFuzzerTestOneInput`
calls `sample_invariant()` to fill both structs from fuzzer input, then passes
the remaining bytes to `FuzzDecode()`.

### Compile definitions

`decoder.c` uses a compile-time `PROTO_MAX_VERSIONS` define (guarded by
`#error`) that controls a conditional field in the config struct. This
demonstrates that `-D` defines flow through all three stages of the build:

1. **absolution** (aro parsing) — so it sees the correct struct layout
2. **clang** (object compilation) — so the `.o` files match
3. **clang** (harness/fuzzer.c) — so the final link is consistent

## Building

### Prerequisites

- **absolution** built and installed (`zig build` in the repo root)
- **CMake** >= 3.20
- **Ninja** (recommended) or Make
- **clang** with libFuzzer support
- **objcopy** (GNU binutils or `llvm-objcopy`)

### Normal build (library + demo app)

```bash
cmake -B build -G Ninja -DCMAKE_C_COMPILER=clang
cmake --build build
./build/parser
# Output: Packet OK: type=1 seq=0 payload_len=5
```

### Fuzzer build

```bash
cmake -B build -G Ninja \
    -DENABLE_FUZZING=ON \
    -DCMAKE_C_COMPILER=clang \
    -DAbsolution_DIR=<path-to-absolution>/zig-out/lib/cmake/Absolution

cmake --build build --target fuzz_decode
```

### Running the fuzzer

```bash
# Quick smoke test
./build/fuzz_decode -runs=1000 -seed=1

# With a persistent corpus
mkdir -p corpus
./build/fuzz_decode corpus/
```

## How the CMake integration works

The key is `absolution_add_fuzzer()` from `find_package(Absolution)`:

```cmake
absolution_add_fuzzer(
    NAME fuzz_decode
    TARGETS src/decoder.c src/session.c
    HARNESS fuzz/fuzz_decode.c
    ENTRY FuzzDecode
    LINK_LIBRARIES protocol
)
```

Because `protocol` declares its include directories and compile definitions as
`PUBLIC`, they propagate automatically to every stage of the absolution pipeline —
no need to duplicate them. This single call creates a CMake target that:

1. **Runs absolution** on the target `.c` files to generate `fuzzer.c`,
   `fuzzer.redef`, and `fuzzer.seed`
2. **Compiles** each target to a `.o` file (separate from the normal library
   build, so objcopy can modify them)
3. **Applies `objcopy`** to rename and globalize static symbols per the
   `.redef` file
4. **Links** everything: generated `fuzzer.c` + user harness + modified `.o`
   files, with `-fsanitize=fuzzer,address`
