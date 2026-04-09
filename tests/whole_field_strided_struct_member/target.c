// Strided whole-field case: logical field `.items.b` lives at offsets 0, 4, 8, 12.
// The extra bytes are compiler padding created by the explicit alignment.

typedef struct __attribute__((aligned(4))) {
    unsigned char b;
} slot_t;

typedef struct {
    slot_t items[4];
} packet_t;

typedef char slot_t_must_be_4_bytes[(sizeof(slot_t) == 4) ? 1 : -1];

packet_t pkt;
