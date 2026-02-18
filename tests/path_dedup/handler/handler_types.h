#pragma once
/* Include shared.h via "../" — produces path "handler/../common/shared.h" */
#include "../common/shared.h"

typedef struct {
    shared_t state;
    int flags;
} handler_info_t;
