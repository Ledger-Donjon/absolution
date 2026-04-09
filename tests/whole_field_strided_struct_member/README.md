# Test: whole_field_strided_struct_member

## Purpose

Demonstrate the limitation of whole field on a strided struct member.

## Category

edge-case

## Issue

When applying a multi-value whole field domain on an array of struct where the member field is strided, the generated sampler/checker considers the field as contiguous in memory, effectively corrupting the intended layout of the domain.

## Symptom

The parser understands the field correctly as strided:

```zig
.name = ".items.b",
.dims = .{.{ .len = 4, .stride_bytes = 4 }},
```

The prefix accounting also looks correct:

```c
#define ABSOLUTION_GLOBALS_SIZE 1
```

The suspicious part is the generated `whole_values` code:

```c
memcpy(&pkt[0], &FM_WVAL_0[idx_FM_WVAL_0 * FM_WVAL_0_BLOB_BYTES], 4);
if (memcmp(&pkt[0], &FM_WVAL_0[vi * FM_WVAL_0_BLOB_BYTES], FM_WVAL_0_BLOB_BYTES) == 0) { found = 1; break; }
```

## Root Cause

`src/cgen/emit.zig` handles `.values` per element through the field-dimension loop, but `.whole_values` skips that path and copies/checks a single dense blob starting from the base field offset.

For `.items.b` with `.len = 4` and `.stride_bytes = 4`, the logical bytes live at offsets `0, 4, 8, 12`. The generated `whole_values` code instead copies/checks bytes `0..3` contiguously from `&pkt[0]`.

So the issue is not parsing or selector-byte count, it is the final application/check treating a strided field like a dense blob.

## Notes

- Dense array fields such as `uint8_t b[8]` are not affected by this issue.
- This issue appears when the field stride is larger than the element size, for example a field inside an array of structs with other members or padding between consecutive elements.
- Until this is fixed, prefer `.values` over `.whole_values` for strided fields.

