/* Regression test: non-static globals appearing in multiple translation units
 * must be deduplicated in the generated fuzzer output.
 *
 * Both this file and other.c declare "point_t shared_point". When both are
 * passed as targets, fuzzmate should emit the extern declaration and sampler
 * code for shared_point only once.
 *
 * See: global_dedup.c.targets for the multi-file target list.
 */
#include "shared.h"

point_t shared_point;
