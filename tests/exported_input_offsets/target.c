// Covers the input-layout export (--offsets): a global whose bytes are consumed
// contiguously, one with interior padding that is zeroed rather than sampled, an
// array global, and a `static` reached through its mangled linker name.

#include <stdint.h>

// 16 sampled bytes, first in the layout.
uint8_t ctrl[16];

// Interior padding is zeroed, not sampled, so this spends 1 + 4 bytes.
struct padded {
    uint8_t  flag;
    uint32_t counter;
};
struct padded state;

// Array global: dimensions multiply the per-element cost.
uint16_t table[4];

// Only reachable after objcopy renames it, so the offset constant is emitted
// against the mangled name.
static uint8_t secret[8];

void AbsolutionTestRegression(void)
{
    ctrl[0]      = 1;
    state.flag   = 2;
    table[0]     = 3;
    secret[0]    = 4;
}
