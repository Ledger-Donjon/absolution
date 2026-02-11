#include "protocol.h"
#include <stdio.h>

/* Tiny demo driver — not involved in fuzzing. */
int main(void) {
    /* A hand-crafted PING packet. */
    uint8_t raw[] = {
        0x00,              /* version 0 */
        PKT_PING,          /* type     */
        0x05, 0x00,        /* payload_len = 5  (little-endian) */
        0x00, 0x00, 0x00, 0x00,  /* seq = 0 */
        'h', 'e', 'l', 'l', 'o' /* payload */
    };

    struct packet pkt;
    if (decode_packet(raw, sizeof(raw), &pkt) != 0) {
        fprintf(stderr, "decode failed\n");
        return 1;
    }
    if (validate_packet(&pkt) != 0) {
        fprintf(stderr, "validation failed\n");
        return 1;
    }
    process_packet(&pkt);
    printf("Packet OK: type=%u seq=%u payload_len=%u\n",
           pkt.hdr.type, pkt.hdr.seq, pkt.hdr.payload_len);
    return 0;
}
