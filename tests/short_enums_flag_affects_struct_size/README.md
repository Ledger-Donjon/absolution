# Short Enums Test

This test verifies that absolution correctly handles the `-fshort-enums` compiler flag via arocc.

## Background

When C code is compiled with `-fshort-enums`, enum types use the smallest integer type that can hold all values (e.g., `char` instead of `int`). This significantly affects struct sizes:

```c
typedef enum { STATE_IDLE = 0, STATE_ACTIVE = 1 } apdu_state_e;  // fits in 1 byte
typedef enum { MEDIA_NONE = 0, MEDIA_USB = 1 } apdu_media_t;      // fits in 1 byte

typedef struct {
    apdu_state_e   apdu_state;   // 4 bytes normal, 1 byte with -fshort-enums
    unsigned short apdu_length;  // 2 bytes
    unsigned short io_flags;     // 2 bytes
    apdu_media_t   apdu_media;   // 4 bytes normal, 1 byte with -fshort-enums
} io_app_t;
```

| Scenario | Enum Size | Struct Size |
|----------|-----------|-------------|
| Default | 4 bytes | 12 bytes |
| `-fshort-enums` | 1 byte | 8 bytes |

## Solution

Absolution now supports passing C compiler flags to arocc via the `--` separator:

```bash
absolution --targets file.c --out fuzzer.c --redef redef.txt -- -fshort-enums -I /path -DFOO=1
```

The CMake integration automatically passes `INCLUDE_DIRECTORIES`, `COMPILE_DEFINITIONS`, and `COMPILE_OPTIONS` from the target to absolution.

## Test Files

- `short_enums.c` - C test file with structs containing enums
- `short_enums.c.zon` - Golden file (8 bytes with -fshort-enums)
- `short_enums.c.flags` - Specifies `-fshort-enums` flag for this test

## Running the Test

```bash
# Run via integration test suite
./scripts/integration.sh

# Run manually
./zig-out/bin/absolution --targets tests/short_enums/short_enums.c \
    --zon /tmp/out.zon --out /tmp/fuzzer.c --redef /tmp/redef.txt -- -fshort-enums

# Verify size
grep size_bytes /tmp/out.zon  # Should show 8 bytes
```
