#include <stdint.h>
#include <stddef.h>
#include "protocol.h"

/*
 * Fuzz harness for the decode + validate + process pipeline.
 *
 * When linked with absolution's generated fuzzer.c, the call order is:
 *   1. LLVMFuzzerTestOneInput receives raw bytes from libFuzzer.
 *   2. sample_invariant() fills the global decoder_config and session
 *      structs from the first N bytes.
 *   3. The remaining bytes are passed here as (data, size).
 *   4. After we return, check_invariant() verifies struct padding.
 *
 * This lets libFuzzer explore the full config × session × input space
 * without requiring a handwritten state setup.
 */
int FuzzDecode(const uint8_t *data, size_t size) {
    struct packet pkt;

    if (decode_packet(data, size, &pkt) != 0)
        return 0;   /* invalid input — not interesting, but not a bug */

    if (validate_packet(&pkt) != 0)
        return 0;

    process_packet(&pkt);
    return 0;
}
