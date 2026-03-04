/* Regression test: headers included via different "../" relative paths must
 * be deduplicated to the same source.
 *
 * This file includes shared.h from "common/shared.h" directly.
 * The sub-header "handler/handler_types.h" also includes "../common/shared.h",
 * producing the path "handler/../common/shared.h" which must normalise to
 * the same entry as "common/shared.h".
 *
 * Without normalisation the same header is loaded twice (different source IDs)
 * causing wasted preprocessing work and potential #pragma once failures.
 */
#include "common/shared.h"
#include "handler/handler_types.h"

shared_t global_state;
handler_info_t handler_info;
