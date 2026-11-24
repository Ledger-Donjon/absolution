/*
 * klee_mem_alloc.c — KLEE-only concretising shim for the Ledger SDK allocator
 * (ledger-secure-sdk/lib_alloc/mem_alloc.c).
 *
 * WHY: the real allocator stores chunk metadata (size + free/phys indices)
 * INSIDE the heap buffer and walks it with pointer arithmetic
 * (GET_PTR / ensure_chunk_valid). Under symbolic execution, a symbolic value
 * that reaches an allocation size or a chunk index turns those walks into
 * symbolic-ADDRESS reads over a 16-34 KB pool, so KLEE/STP must "resolve" a
 * symbolic pointer against a huge memory object — a query that does not
 * terminate (the `mem_alloc.c:232 Query timed out (resolve)` wall).
 *
 * FIX: override the allocator (the mock tier wins at link time) with a trivial
 * one backed by the modeled libc malloc. KLEE hands back a fresh CONCRETE
 * address for each allocation and concretises a symbolic size, so no symbolic
 * chunk-walk / address-resolve is ever generated. The bug oracle is unaffected:
 * a UB such as the row-13 int16 narrowing still aborts at its conversion site,
 * which happens BEFORE any allocator interaction with the wild value.
 *
 * FIDELITY: the real mem_free() silently ignores a pointer that is not a live
 * heap chunk (e.g. a still-zero/garbage pointer field, or one seeded from the
 * symbolic input by sample_invariant). libc free() does NOT — KLEE flags such a
 * call as "free of global" / "invalid pointer: free", which floods the run with
 * false positives that have nothing to do with the code under test. So mem_free
 * is a NO-OP here (leaking is fine: each symbolic path is short and KLEE's heap
 * is effectively unbounded) and mem_realloc copies into a fresh block instead of
 * freeing the old one. Allocations carry an 8-byte size prefix so realloc can
 * copy the right amount.
 *
 * App-agnostic: every Ledger app that links lib_alloc exposes exactly these
 * symbols, so this single shim serves all of them. Opt in per target with the
 * ALLOC_SHIM flag of absolution_add_symbolic_target().
 */
#include <stdlib.h>
#include <string.h>
#include "mem_alloc.h"

/* Opaque, non-NULL context so callers' `ctx != NULL` checks pass. The real API
 * threads a heap handle through every call; we ignore it and use the process
 * heap, so the address of any static object is a fine sentinel. */
static int _klee_mem_ctx;

/* 8-byte size prefix keeps the returned payload 8-aligned (malloc is >=8-aligned
 * and 8 is the SDK's PAYLOAD_DATA_ALIGNEMENT) while letting realloc copy exactly
 * the old payload without knowing it out of band. */
#define HDR 8

mem_ctx_t mem_init(void *heap_start, size_t heap_size)
{
    (void) heap_start;
    (void) heap_size;
    return (mem_ctx_t) &_klee_mem_ctx;
}

void *mem_alloc(mem_ctx_t ctx, size_t nb_bytes)
{
    (void) ctx;
    unsigned char *base = (unsigned char *) malloc(HDR + nb_bytes);
    if (base == NULL) {
        return NULL;
    }
    *(size_t *) base = nb_bytes;
    return base + HDR;
}

void *mem_realloc(mem_ctx_t ctx, void *ptr, size_t size)
{
    (void) ctx;
    if (ptr == NULL) {
        return mem_alloc(ctx, size);
    }
    size_t old = *(size_t *) ((unsigned char *) ptr - HDR);
    void  *np  = mem_alloc(ctx, size);
    if (np != NULL) {
        memcpy(np, ptr, old < size ? old : size);
    }
    /* deliberately do NOT free(ptr): see FIDELITY note. */
    return np;
}

/* NO-OP: mirrors the real allocator's tolerance of non-heap pointers and avoids
 * libc free() rejecting symbolic/global pointers under KLEE. */
void mem_free(mem_ctx_t ctx, void *ptr)
{
    (void) ctx;
    (void) ptr;
}

/* Chunk enumeration is meaningless for a malloc-backed heap; the parsers under
 * test do not depend on it for correctness, so a no-op keeps callers happy. */
void mem_parse(mem_ctx_t ctx, mem_parse_callback_t callback, void *dat)
{
    (void) ctx;
    (void) callback;
    (void) dat;
}

void mem_stat(mem_ctx_t *ctx, mem_stat_t *stat)
{
    (void) ctx;
    if (stat) {
        stat->total_size     = 0;
        stat->free_size      = 0;
        stat->allocated_size = 0;
        stat->nb_chunks      = 0;
        stat->nb_allocated   = 0;
    }
}
