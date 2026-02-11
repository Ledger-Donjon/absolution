#ifndef PROTOCOL_H
#define PROTOCOL_H

#include <stdint.h>
#include <stddef.h>

/* ── Packet wire format ───────────────────────────────────────────── */

#define PROTO_MAX_PAYLOAD 256

enum packet_type {
    PKT_PING  = 0x01,
    PKT_DATA  = 0x02,
    PKT_ACK   = 0x03,
    PKT_RESET = 0xFF,
};

struct packet_header {
    uint8_t  version;
    uint8_t  type;
    uint16_t payload_len;
    uint32_t seq;
};

struct packet {
    struct packet_header hdr;
    uint8_t payload[PROTO_MAX_PAYLOAD];
};

/* ── Decoder configuration ────────────────────────────────────────── */

struct decoder_config {
    uint16_t max_payload;       /* reject packets larger than this    */
    uint8_t  allowed_versions;  /* bitmask of accepted version fields */
    uint8_t  strict_seq;        /* if non-zero, enforce ordering      */
#ifdef PROTO_MAX_VERSIONS
    uint8_t  version_table[PROTO_MAX_VERSIONS]; /* per-version flags  */
#endif
};

/* ── Session state ────────────────────────────────────────────────── */

struct session {
    uint32_t next_seq;
    uint32_t rx_count;
    uint32_t err_count;
};

/* ── Public API ───────────────────────────────────────────────────── */

/**
 * Decode a raw buffer into a packet structure.
 * Returns 0 on success, -1 on error.
 */
int decode_packet(const uint8_t *buf, size_t len, struct packet *out);

/**
 * Validate a decoded packet against session state.
 * Returns 0 on success, -1 on error.
 */
int validate_packet(const struct packet *pkt);

/**
 * Process a fully validated packet (updates session counters).
 */
void process_packet(const struct packet *pkt);

#endif /* PROTOCOL_H */
