#include "protocol.h"
#include <string.h>

#ifndef PROTO_MAX_VERSIONS
#error "PROTO_MAX_VERSIONS must be defined (-D)"
#endif

/* ── Global decoder configuration ─────────────────────────────────
 * fuzzmate will sample this struct from fuzzer input so we exercise
 * the decoder under many different configuration states.             */
static struct decoder_config config = {
    .max_payload      = PROTO_MAX_PAYLOAD,
    .allowed_versions = 0x01,
    .strict_seq       = 1,
};

int decode_packet(const uint8_t *buf, size_t len, struct packet *out) {
    if (len < sizeof(struct packet_header))
        return -1;

    memcpy(&out->hdr, buf, sizeof(struct packet_header));

    /* Reject versions beyond the compile-time limit. */
    if (out->hdr.version >= PROTO_MAX_VERSIONS)
        return -1;

    /* Check version against config bitmask. */
    if (!(config.allowed_versions & (1u << out->hdr.version)))
        return -1;

    /* Enforce max payload. */
    if (out->hdr.payload_len > config.max_payload)
        return -1;

    if (len < sizeof(struct packet_header) + out->hdr.payload_len)
        return -1;

    memcpy(out->payload, buf + sizeof(struct packet_header),
           out->hdr.payload_len);

    return 0;
}
