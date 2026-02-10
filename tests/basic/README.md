# Test: basic

## Purpose
Validates basic struct parsing with typedef arrays and padding detection.

## Category
feature

## Issue
N/A - This is a baseline feature test, not a regression test.

## Test Validation
- `basic.c` defines a typedef'd struct array: `mytype astruct[10]`
- The struct has fields `int a`, `short b`, `char c` with implicit padding
- Fuzzmate should:
  - Detect `astruct` as a non-static global variable
  - Correctly calculate size (80 bytes = 10 elements × 8 bytes each)
  - Identify struct fields with correct offsets and bit widths
  - Detect the 1-byte padding after `char c`

## Expected Output
```
name = "astruct"
size_bytes = 80
is_static = false
dims = [{ len = 10, stride_bytes = 8 }]
fields:
  .a: offset=0, width=32 bits
  .b: offset=32, width=16 bits
  .c: offset=48, width=8 bits
  ._pad0: offset=56, width=8 bits (padding)
```

## Related Files
- `src/type_flatten.zig` - Field flattening and padding detection
- `src/Parser.zig` - Global variable extraction
- `tests/padding_check/` - More extensive padding tests
