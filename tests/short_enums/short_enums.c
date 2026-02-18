// Test case to reproduce struct size mismatch caused by -fshort-enums.
//
// BUG: fuzzmate's arocc parser doesn't handle -fshort-enums flag, causing
// struct size mismatches between parsed size and actual compiled size.
//
// Without -fshort-enums: enums are 4 bytes (int), io_app_t = 12 bytes
// With -fshort-enums: enums are 1 byte, io_app_t = 8 bytes
//
// This directly causes runtime crashes when the generated fuzzer.c tries
// to write data beyond the actual struct bounds.

typedef enum {
    STATE_IDLE = 0,
    STATE_ACTIVE = 1,
    STATE_BUSY = 2,
    STATE_WAITING = 3,
    STATE_DONE = 4
} apdu_state_e;  // Values 0-4, fits in 1 byte with -fshort-enums

typedef enum {
    MEDIA_NONE = 0,
    MEDIA_USB = 1,
    MEDIA_BLE = 2,
    MEDIA_NFC = 3
} apdu_media_t;  // Values 0-3, fits in 1 byte with -fshort-enums

typedef struct {
    apdu_state_e   apdu_state;   // 4 bytes normal, 1 byte with -fshort-enums
    unsigned short apdu_length;  // 2 bytes
    unsigned short io_flags;     // 2 bytes  
    apdu_media_t   apdu_media;   // 4 bytes normal, 1 byte with -fshort-enums
} io_app_t;

// Global variable to be fuzzed
io_app_t G_io_app;

// Standard compilation: 12 bytes (4 + 2 + 2 + 4)
// With -fshort-enums: 8 bytes (1 + 1pad + 2 + 2 + 1 + 1pad)
