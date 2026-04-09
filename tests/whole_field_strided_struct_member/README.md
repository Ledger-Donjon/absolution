# Test: whole_field_strided_struct_member

## Purpose

Verify that `.whole_values` correctly scatters/gathers elements for strided struct members (stride > element size).

## Category

edge-case (fixed)

## Background

For `.items.b` with `.len = 4` and `.stride_bytes = 4`, the logical bytes live at memory offsets `0, 4, 8, 12`. The emitter must scatter each blob byte to its strided position in the sampler and gather them back before comparison in the checker — not treat the blob as a single contiguous run at the base offset.

Dense array fields (`stride == element size`) are unaffected; those use a single `memcpy`/`memcmp`.
