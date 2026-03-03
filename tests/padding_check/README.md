# Test: padding_check

## Purpose
Validates correct detection and handling of struct padding bytes.

## Category
feature

## Issue
N/A - This is a feature test ensuring padding is properly identified.

## Test Validation
- `padding.c` defines a struct with deliberate padding scenarios
- Absolution should correctly identify padding bytes inserted by the compiler
- Padding fields should be marked with `is_padding = true`
- Padding should have appropriate `pad_container` references

## Why Padding Matters
Struct padding bytes can contain uninitialized memory or stale data. When fuzzing:
- Padding bytes should be included in the fuzzed data range
- This ensures the fuzzer can detect bugs related to uninitialized memory reads
- The `pad_container` field helps identify which struct member the padding follows

## Related Files
- `src/type_flatten.zig` - Padding detection logic
- `tests/basic/` - Basic padding example
- `tests/complex_struct/` - More complex padding scenarios
