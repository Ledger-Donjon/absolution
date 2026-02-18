#pragma once
/* Self-include via "./" — aro must normalise the path so #pragma once
   prevents infinite recursion. */
#include "./types.h"

typedef struct {
    int x;
    int y;
} point_t;
