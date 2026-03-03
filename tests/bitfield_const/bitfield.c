/* Test case for bit-field and const global handling.
 *
 * This file tests that absolution:
 * 1. Does NOT emit memcpy(&bitfield, ...) for bit-field members
 * 2. Does NOT sample const globals (including arrays of const elements)
 * 3. DOES sample non-const globals with regular (non-bitfield) members
 */

#include <stdint.h>
#include <stdbool.h>

/* Struct with bit-fields - these should NOT be sampled */
typedef struct {
    uint32_t regular_field;      /* Regular field - should be sampled */
    uint32_t bf_a : 1;           /* Bit-field - should NOT be sampled */
    uint32_t bf_b : 6;           /* Bit-field - should NOT be sampled */
    uint32_t bf_c : 4;           /* Bit-field - should NOT be sampled */
    uint16_t another_regular;    /* Regular field - should be sampled */
} bitfield_struct_t;

/* Simple struct without bit-fields for comparison */
typedef struct {
    uint32_t x;
    uint32_t y;
} simple_struct_t;

/* Non-const global with bit-fields - regular fields should be sampled */
bitfield_struct_t mutable_bitfield_global;

/* Const global with bit-fields - should NOT be sampled at all */
const bitfield_struct_t const_bitfield_global = {0, 0, 0, 0, 0};

/* Array of const elements - should NOT be sampled */
const simple_struct_t const_array[3] = {{1, 2}, {3, 4}, {5, 6}};

/* Non-const array - should be sampled */
simple_struct_t mutable_array[2];

/* Const scalar - should NOT be sampled */
const uint32_t const_scalar = 42;

/* Non-const scalar - should be sampled */
uint32_t mutable_scalar;
