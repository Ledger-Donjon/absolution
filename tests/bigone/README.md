# bigone test - SKIPPED (arocc bug)

This test is currently skipped due to an upstream arocc parser bug.

## Issue

The arocc parser crashes with `panic: reached unreachable code` in `TypeStore.zig:167`
when processing this file. The crash occurs at line 7678 on the function:

```c
static void reedSolomonComputeRemainder(const uint8_t data[], int dataLen,
    const uint8_t generator[], int degree, uint8_t result[])
```

The bug requires the accumulated parser state from the preceding 7677 lines to trigger.
See `tests/aroccbug/README.md` for detailed analysis.

## Why zig cc works but fuzzmate doesn't

- `zig cc` uses LLVM's Clang frontend - compiles this file fine
- fuzzmate uses arocc (Zig-native C frontend) for AST access - crashes on this file

## Golden file

The golden file is named `bigone.c.zon.skip-arocc-bug` to skip this test.
The integration script recognizes this suffix and skips with a warning.

## When arocc fixes the bug

1. Update arocc version in `build.zig.zon`
2. Test if this file parses: `./zig-out/bin/fuzzmate --targets tests/bigone/bigone.c ...`
3. If it works, rename the golden file:
   ```bash
   mv bigone.c.zon.skip-arocc-bug bigone.c.zon
   ```

## Upstream

- arocc: https://github.com/Vexu/arocc
- Version: `da0aedc2625fc16beceb641823a22ccfe58a73ff`
