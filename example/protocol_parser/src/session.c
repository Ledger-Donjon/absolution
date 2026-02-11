#include "protocol.h"

/* ── Global session state ─────────────────────────────────────────
 * fuzzmate will sample this struct so the fuzzer explores many
 * different session histories without needing a long packet stream. */
static struct session sess = {
    .next_seq  = 0,
    .rx_count  = 0,
    .err_count = 0,
};

int validate_packet(const struct packet *pkt) {
    /* Sequence ordering check (if enabled by decoder_config). */
    if (pkt->hdr.seq < sess.next_seq)
        return -1;

    /* Simple type sanity. */
    switch (pkt->hdr.type) {
    case PKT_PING:
    case PKT_DATA:
    case PKT_ACK:
    case PKT_RESET:
        break;
    default:
        return -1;
    }

    return 0;
}

void process_packet(const struct packet *pkt) {
    sess.next_seq = pkt->hdr.seq + 1;
    sess.rx_count++;
}
