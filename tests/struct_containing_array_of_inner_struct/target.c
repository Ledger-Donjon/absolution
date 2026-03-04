#include <string.h>

// Inner struct that will be used in an array
typedef struct {
    int x;
    short y;
} inner_t;

// Outer struct containing an array of inner structs
typedef struct {
    int id;
    inner_t items[4];  // Array of structs - tests the dim_positions fix
    char tag;
} outer_t;

outer_t g_data;

// Apply a memset on the overall struct to impact the padding
void mutation() {
    memset(&g_data, 0x42, sizeof(g_data));
}

void AbsolutionTestRegression() { mutation(); }
