/* Regression test: #include "./self.h" inside a header that uses #pragma once.
 *
 * Without path normalisation in the include resolver, "dir/./types.h" and
 * "dir/types.h" are treated as different sources.  #pragma once only records
 * the source-id of the first path, so the self-include is not suppressed,
 * leading to infinite include recursion and unbounded memory growth.
 */
#include "sub/types.h"

point_t origin;
