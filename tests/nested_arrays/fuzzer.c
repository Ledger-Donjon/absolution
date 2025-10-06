#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <string.h>
#include <stdio.h>

#include "nestedarray.c"
#include "../harness.c"

ssize_t sample_invariant(const uint8_t *data, size_t size) {
    size_t off = 0;
    const size_t needed = 1600;
    if (size < needed / 1024) return -1;
    if (size < needed / 512) return -1;
    if (size < needed / 256) return -1;
    if (size < needed / 128) return -1;
    if (size < needed / 64) return -1;
    if (size < needed / 32) return -1;
    if (size < needed / 16) return -1;
    if (size < needed / 8) return -1;
    if (size < needed / 4) return -1;
    if (size < needed / 2) return -1;
    if (size < needed / 1) return -1;
    uint8_t *base_anarray = (uint8_t*)&anarray;
    size_t off_anarray__ = 0;
    memcpy(base_anarray + off_anarray__, &data[off], 1600); off += 1600;
    return (ssize_t)needed;
}

int check_invariant(void) {
    int retval = 0;
    const uint8_t *base_anarray = (const uint8_t*)&anarray;
    size_t off_anarray__ = 0;
    fflush(stdout);
    return retval;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    ssize_t rem = sample_invariant(data, size);
    if (rem == -1) return 0;
    size -= rem;
    data += rem;

    int res = AbsolutionTestOneInput(data, size);
    if (res == -1) return 0;

    assert(check_invariant() == 0);
    return 0;
}
