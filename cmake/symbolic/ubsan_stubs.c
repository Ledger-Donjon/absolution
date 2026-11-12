/* Generic UBSan handler stubs for symbolic execution (KLEE).
 *
 * When a target is compiled with -fsanitize=undefined -fno-sanitize-recover=all
 * (see absolution_add_symbolic_target(UBSAN)), clang emits calls to
 * __ubsan_handle_*_abort on undefined behaviour. These stubs route every
 * handler to abort(), which KLEE reports as an error path -- turning the UBSan
 * instrumentation into a symbolic bug oracle.
 *
 * App-agnostic: nothing here depends on any particular Ledger app, so it lives
 * in the generic cmake/symbolic/ tooling and is compiled into the app tier of
 * every symbolic target that enables UBSAN.
 *
 * Both the _abort and non-abort variants are defined so the stubs resolve
 * whether or not -fno-sanitize-recover is in effect. */

#include <stddef.h>
#include <stdlib.h>

void __ubsan_handle_shift_out_of_bounds(void *d, void *l, void *r) { abort(); }
void __ubsan_handle_shift_out_of_bounds_abort(void *d, void *l, void *r) { abort(); }

void __ubsan_handle_type_mismatch_v1(void *d, void *p) { abort(); }
void __ubsan_handle_type_mismatch_v1_abort(void *d, void *p) { abort(); }

void __ubsan_handle_add_overflow(void *d, void *l, void *r) { abort(); }
void __ubsan_handle_add_overflow_abort(void *d, void *l, void *r) { abort(); }

void __ubsan_handle_sub_overflow(void *d, void *l, void *r) { abort(); }
void __ubsan_handle_sub_overflow_abort(void *d, void *l, void *r) { abort(); }

void __ubsan_handle_mul_overflow(void *d, void *l, void *r) { abort(); }
void __ubsan_handle_mul_overflow_abort(void *d, void *l, void *r) { abort(); }

void __ubsan_handle_divrem_overflow(void *d, void *l, void *r) { abort(); }
void __ubsan_handle_divrem_overflow_abort(void *d, void *l, void *r) { abort(); }

void __ubsan_handle_negate_overflow(void *d, void *v) { abort(); }
void __ubsan_handle_negate_overflow_abort(void *d, void *v) { abort(); }

void __ubsan_handle_pointer_overflow(void *d, void *b, void *r) { abort(); }
void __ubsan_handle_pointer_overflow_abort(void *d, void *b, void *r) { abort(); }

void __ubsan_handle_out_of_bounds(void *d, void *i) { abort(); }
void __ubsan_handle_out_of_bounds_abort(void *d, void *i) { abort(); }

void __ubsan_handle_load_invalid_value(void *d, void *v) { abort(); }
void __ubsan_handle_load_invalid_value_abort(void *d, void *v) { abort(); }

void __ubsan_handle_builtin_unreachable(void *d) { abort(); }

void __ubsan_handle_missing_return(void *d) { abort(); }

/* Implicit conversions (CONV_FILES) are built with recovery, as a native
 * -fsanitize=integer sweep reports them: a conversion the code means (a u16
 * read into an int16_t) must not end the path before a later one that is a bug.
 * A copy of the path reports the site, the path itself goes on; each path
 * reports a site once. */
struct ubsan_source_location {
    const char *file;
    unsigned    line;
    unsigned    column;
};

void klee_make_symbolic(void *addr, size_t nbytes, const char *name);
void klee_report_error(const char *file, int line, const char *message, const char *suffix)
    __attribute__((noreturn));

#define CONV_SITES_MAX 64
static const void *conv_sites[CONV_SITES_MAX];
static size_t      conv_sites_used;

void __ubsan_handle_implicit_conversion(void *d, void *s, void *t)
{
    const struct ubsan_source_location *loc = d;
    unsigned char                       report;

    for (size_t i = 0; i < conv_sites_used; i++) {
        if (conv_sites[i] == d) {
            return;
        }
    }
    if (conv_sites_used < CONV_SITES_MAX) {
        conv_sites[conv_sites_used++] = d;
    }
    klee_make_symbolic(&report, sizeof(report), "ubsan_conv_report");
    if (report) {
        klee_report_error(loc->file, (int) loc->line,
                          "implicit conversion changed the value", "conv.err");
    }
}
void __ubsan_handle_implicit_conversion_abort(void *d, void *s, void *t) { abort(); }

void __ubsan_handle_nonnull_arg(void *d) { abort(); }
void __ubsan_handle_nonnull_arg_abort(void *d) { abort(); }

void __ubsan_handle_nonnull_return_v1(void *d, void *l) { abort(); }
void __ubsan_handle_nonnull_return_v1_abort(void *d, void *l) { abort(); }

void __ubsan_handle_float_cast_overflow(void *d, void *v) { abort(); }
void __ubsan_handle_float_cast_overflow_abort(void *d, void *v) { abort(); }

void __ubsan_handle_vla_bound_not_positive(void *d, void *v) { abort(); }
void __ubsan_handle_vla_bound_not_positive_abort(void *d, void *v) { abort(); }
