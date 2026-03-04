# Packed struct regression test

This directory contains a regression test for a bug where struct layout–affecting attributes (`__attribute__((packed))`, `__attribute__((aligned(...)))`, etc.) were not handled correctly when C compiler flags (`-D` macros) were applied in the wrong order during parser initialization.

## The bug

The aro-based C parser in `src/Parser.zig` builds a series of preprocessor sources (compat macros, user macros from `-D`, builtin macros, empty main). The order of these sources matters because `buildUserMacros` calls `driver.parseArgs`, which updates the driver state. If builtin macros are generated before user macros are processed, the driver state used by `generateBuiltinMacros` is stale, and subsequent parsing can mis-handle types that depend on layout attributes.

**Symptoms (before fix):**

- Structs or unions tagged with `__attribute__((packed))` or `__attribute__((aligned(...)))` may be parsed with incorrect layout
- Wrong `sizeof` / stride / field offsets for globals
- Parsing failures or layout computation returning `null` for affected types

## The fix

In `Parser.init`, `buildUserMacros` must be called before `generateBuiltinMacros` so that `parseArgs` updates the driver state first. The comment in `Parser.zig` documents this ordering requirement:

```zig
// We call buildUserMacros before generateBuiltinMacros as calling parseArgs will
// update the driver state
```

## How to verify

**With the fix** — Run absolution on the packed test; it should succeed and produce the expected zon output (e.g. `obj_pool` with size 33792, stride 66 for `nbgl_any_obj_t`):
```bash
zig build
./zig-out/bin/absolution init tests/packed/packed.c -- tests/packed/packed.c.flags \
  -o /dev/null -r /dev/null -z packed.zon
```

## Test contents

- `packed.c` — Declares `obj_pool`, a static array of `nbgl_any_obj_t` (a union of various PACKED__ structs from the NBGL API).
- `nbgl_types.h` / `nbgl_obj.h` — Headers defining `PACKED__` as `__attribute__((packed))` and structs that use it.
- `packed.c.flags` — Compiler flags (defines like `TARGET_FLEX`, `SCREEN_SIZE_WALLET`, etc.) that influence which struct variants and sizes are used.
- `packed.c.zon` — Expected zon output when the packed attribute is correctly applied.
```
