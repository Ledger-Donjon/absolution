// Integration test: verifies that -D defines are passed through to the parser.
//
// Requires two compile flags to be defined (via .flags sidecar):
//   - HAS_EXTRA: adds an extra field to config_t
//   - BUFFER_SIZE: size of the data array (must be defined)
//
// Without -DHAS_EXTRA: config_t has base_a, base_b (8 bytes).
// With -DHAS_EXTRA: config_t has base_a, base_b, extra (12 bytes).
//
// data[] size is BUFFER_SIZE bytes.

#ifndef BUFFER_SIZE
#error We can not parse this file with fuzzmate
#endif

typedef struct {
    int base_a;
    int base_b;
#ifdef HAS_EXTRA
    int extra;  // Only present when -DHAS_EXTRA is passed
#endif
} config_t;

config_t g_config;
unsigned char data[BUFFER_SIZE];
