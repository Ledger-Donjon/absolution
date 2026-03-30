// Integration test: whole-field `.whole_values` on an inner byte array (field dims).

typedef struct {
    unsigned char b[8];
} packet_t;

packet_t pkt;

void AbsolutionTestRegression(void) {
    (void)pkt;
}
