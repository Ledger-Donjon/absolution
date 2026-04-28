/* Regression test: user-supplied -I flags must reach the preprocessor's
 * include search path.
 *
 * The header `inner.h` lives in a sibling subdirectory `inc/`, so the
 * preprocessor cannot find it via the includer's directory alone — it
 * MUST honour the `-I .../inc` flag passed via target.c.flags.
 *
 * This guards against a regression where Driver.parseArgs collected
 * `-I/-isystem/-iquote/-idirafter` into `driver.includes` but the result
 * was never committed to `comp.search_path`, leaving every user-supplied
 * include path invisible to the preprocessor.
 */
#include "inner.h"

inner_t global_state;
