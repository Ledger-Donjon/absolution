/* KLEE-only memcpy/memmove for symbolic execution.
 *
 * A copy whose size is symbolic (a length the input decides) makes the
 * klee-uclibc byte loop ask the solver at every byte, and KLEE runs its seeds
 * side by side, so one such copy stalls every seed of the run. On app-ethereum,
 * copies of symbolic length in the transaction parser took over half of the
 * solver time of the jobs whose seeds never got through their session.
 *
 * Here a symbolic size forks once. One path takes the value its seed (or the
 * current model) gives and copies concretely; the other keeps the size
 * symbolic and copies byte by byte as before, so KLEE still checks every length
 * that path allows (an overflow by length) once it searches it.
 *
 * App-agnostic: compiled into the app tier of every KLEE target. KLEE refuses a
 * second memcpy next to klee-uclibc's, so these carry their own names and the
 * _klee target passes --function-alias=memcpy:absolution_klee_memcpy (and the
 * same for memmove), which also covers the copies KLEE lowers from llvm.memcpy
 * and the ones inside klee-uclibc. "used" keeps them through --optimize, which
 * runs before the aliasing and drops functions nothing calls yet. Built with
 * -fno-builtin, or the loops would be turned back into calls to memcpy.
 *
 * bcmp: clang turns memcmp(...) == 0 into bcmp at -O1, and klee-uclibc has none,
 * so KLEE called the host's on each object's last concrete bytes: an equality on
 * symbolic memory always took the side those stale bytes gave (on app-ethereum,
 * 65 call sites, among them every address, selector and hash check). */

#include <stddef.h>
#include <stdint.h>

unsigned klee_is_symbolic(uintptr_t n);
uint64_t klee_get_value_i64(uint64_t expr);
void    *memcpy(void *dst, const void *src, size_t n);
void    *memmove(void *dst, const void *src, size_t n);

/* --function-alias stops KLEE when no function has the name, as on an app that
 * never calls memmove: this keeps both linked in from klee-uclibc. */
__attribute__((used)) static void *(*const keep_linked[])(void *, const void *, size_t)
    = {memcpy, memmove};

static size_t copy_size(size_t n)
{
    if (klee_is_symbolic(n)) {
        /* volatile: without it --optimize reads "n == value ? value : n" as n and
         * the copy stays symbolic. */
        volatile size_t value = (size_t) klee_get_value_i64(n);
        if (n == value) {
            return value;
        }
    }
    return n;
}

__attribute__((used)) void *absolution_klee_memcpy(void *dst, const void *src, size_t n)
{
    unsigned char       *d = dst;
    const unsigned char *s = src;

    n = copy_size(n);
    for (size_t i = 0; i < n; i++) {
        d[i] = s[i];
    }
    return dst;
}

__attribute__((used)) void *absolution_klee_memmove(void *dst, const void *src, size_t n)
{
    unsigned char       *d = dst;
    const unsigned char *s = src;

    n = copy_size(n);
    /* Backward only when dst starts inside src: from a symbolic n, the backward
     * loop reads and writes every byte at a symbolic offset. */
    if ((uintptr_t) d - (uintptr_t) s >= n) {
        for (size_t i = 0; i < n; i++) {
            d[i] = s[i];
        }
    }
    else {
        for (size_t i = n; i-- > 0;) {
            d[i] = s[i];
        }
    }
    return dst;
}

/* One expression for the whole compare: the caller's == 0 forks once, where a loop
 * stopping at the first difference forks at every symbolic byte. Reads all n
 * bytes, as ASan's strict_memcmp (its default) checks them in the native lane. */
int bcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *x    = a;
    const unsigned char *y    = b;
    unsigned char        diff = 0;

    n = copy_size(n);
    for (size_t i = 0; i < n; i++) {
        diff |= x[i] ^ y[i];
    }
    return diff;
}
