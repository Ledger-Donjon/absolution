# BuildSymbolicBitcode.cmake — script-mode helper (build time).
#
# Compiles the target sources, the absolution symbolic driver, and the harness
# to LLVM bitcode with a KLEE-compatible clang, applies the absolution symbol
# redefinitions at the IR level (llvm-objcopy cannot operate on bitcode), and
# links everything into a single module for KLEE.
#
# Two app-grade capabilities on top of the plain path:
#
#   * UBSan-abort oracle (UBSAN=ON): app/mock-tier TUs are compiled with
#     -fsanitize=undefined -fno-sanitize-recover=all and linked against
#     abort()-on-UB stubs, so KLEE reports undefined behaviour as an error path.
#     CONV_FILES additionally enables implicit-integer-truncation/sign-change on
#     the named files (the silent-narrowing class -fsanitize=undefined omits).
#
#   * Tiered/override link: TUs are classified mock / app / sdk by path; the
#     fuzz mocks override the real SDK symbols they shadow (llvm-link has no
#     --allow-multiple-definition), matching the native fuzz build's link order.
#     With a single tier (e.g. a standalone library) this degenerates to a flat
#     link, so the simple case is unchanged.
#
# Why an IR-level rename instead of objcopy: absolution emits weak mangled
# storage for each sampled global in the driver and a .redef mapping
# "<src> <old> <new>". objcopy rejects bitcode, so here we rename @<old> ->
# @<new> in the textual IR and drop the `internal` linkage so the app's (now
# strong, external) definition overrides the driver's weak placeholder.
#
# -D variables:
#   BC_CC        — KLEE-compatible clang (emits compatible bitcode)
#   LLVM_DIS / LLVM_AS / LLVM_LINK
#   TARGETS_FILE — one relative source path per line (the sampled TUs)
#   FLAGS_FILE   — one compiler flag per line (-I/-D/-std ...)
#   REDEF        — absolution .redef file ("<src> <old> <new>" per line)
#   DRIVER_C     — the absolution symbolic driver (symbolic.c)
#   HARNESS      — (optional) the user's harness .c
#   EXTRA_SOURCES— (optional) comma-joined harness-side .c files (app tier)
#   ENGINE_DEF   — engine selection define (e.g. ABSOLUTION_KLEE)
#   OUT_BC       — linked output bitcode
#   WORK_DIR     — source root (relative target paths resolved against this)
#   BC_DIR       — scratch dir for per-TU bitcode
#   BC_OPT       — optimisation flag for bitcode (default -O0)
#   UBSAN        — ON to enable the UBSan-abort oracle (default OFF)
#   UBSAN_STUBS  — abort-on-UB stub .c (required when UBSAN=ON)
#   CONV_FILES   — comma-joined basenames to also instrument with implicit-
#                  integer-truncation/sign-change
#   TIER_MOCK_MATCH / TIER_SDK_MATCH — comma-joined path substrings for tiers
#   ALLOC_SHIM   — (optional) malloc-backed lib_alloc drop-in linked into the
#                  mock tier to concretise the SDK allocator (avoids the
#                  symbolic chunk-walk / STP address-resolve wall)
#   WRAP         — (optional) comma-joined symbols the native build wraps with
#                  -Wl,--wrap=X; mock-tier __wrap_X definitions become X
#
# Also writes ${OUT_BC}.d, a depfile listing every header the TUs included, so
# the caller's custom command reruns when one of them changes.

cmake_minimum_required(VERSION 3.20)
cmake_policy(SET CMP0057 NEW)   # IN_LIST operator (script mode)

if(NOT BC_OPT)
    set(BC_OPT "-O0")
endif()

file(MAKE_DIRECTORY "${BC_DIR}")
# Per-TU depfiles of a previous run may name TUs that are gone.
file(GLOB_RECURSE _stale_deps "${BC_DIR}/*.d")
if(_stale_deps)
    file(REMOVE ${_stale_deps})
endif()
file(STRINGS "${TARGETS_FILE}" _targets)
file(STRINGS "${FLAGS_FILE}"   _flags_raw)

# ── Sanitise the harvested flags ─────────────────────────────────────────────
# The genex harvest can pick up sanitizer/coverage/-Werror flags from the fuzz
# build; KLEE bitcode must not carry ASan/coverage instrumentation, and -Werror
# would fail the bitcode compile on benign warnings. Strip them; we add our own
# (UBSan) instrumentation explicitly below.
set(_flags "")
foreach(_f ${_flags_raw})
    string(STRIP "${_f}" _fs)
    if(_fs STREQUAL "" OR _fs STREQUAL "-I" OR _fs STREQUAL "-D")
        continue()
    endif()
    if(_fs MATCHES "^-fsanitize" OR _fs MATCHES "^-fno-sanitize"
       OR _fs MATCHES "^-fprofile" OR _fs MATCHES "^-fcoverage"
       OR _fs MATCHES "^-Werror")
        continue()
    endif()
    list(APPEND _flags "${_fs}")
endforeach()

# -MD: clang writes <bc minus .bc>.d next to each output (merged below).
set(_common_flags -emit-llvm -c -g -MD ${BC_OPT}
    -Wno-implicit-function-declaration -Wno-int-conversion
    -D${ENGINE_DEF} ${_flags})

# UBSan-abort instrumentation for the app/mock tiers (the code under test); the
# SDK/libc carry intentional wrapping we do not want to flag.
set(_ubsan_flags -fsanitize=undefined -fno-sanitize-recover=all
    -fno-sanitize=function,alignment)
# Recoverable: ubsan_stubs.c reports a conversion on a copy of the path and
# lets the path go on. Must come after _ubsan_flags.
set(_conv_flags -fsanitize=implicit-integer-truncation,implicit-integer-sign-change
    -fsanitize-recover=implicit-integer-truncation,implicit-integer-sign-change)

# ── Split the comma-joined list vars back into CMake lists ───────────────────
function(_csv_to_list csv out)
    string(REPLACE "," ";" _l "${csv}")
    set(${out} "${_l}" PARENT_SCOPE)
endfunction()
_csv_to_list("${CONV_FILES}"      _conv_files)
_csv_to_list("${TIER_MOCK_MATCH}" _tier_mock)
_csv_to_list("${TIER_SDK_MATCH}"  _tier_sdk)
_csv_to_list("${WRAP}"            _wrap_syms)

# ── Classify a source path into a tier ───────────────────────────────────────
function(_tier_of abs out)
    foreach(_m ${_tier_mock})
        if(_m AND "${abs}" MATCHES "${_m}")
            set(${out} "mock" PARENT_SCOPE)
            return()
        endif()
    endforeach()
    foreach(_s ${_tier_sdk})
        if(_s AND "${abs}" MATCHES "${_s}")
            set(${out} "sdk" PARENT_SCOPE)
            return()
        endif()
    endforeach()
    set(${out} "app" PARENT_SCOPE)
endfunction()

# ── Parse the redef file: map each source path to its (old new) rename pairs ──
set(_redef_srcs "")
if(EXISTS "${REDEF}")
    file(STRINGS "${REDEF}" _redef_lines)
    foreach(_line ${_redef_lines})
        string(REPLACE " " ";" _parts "${_line}")
        list(LENGTH _parts _len)
        if(NOT _len EQUAL 3)
            continue()
        endif()
        list(GET _parts 0 _rsrc)
        list(GET _parts 1 _rold)
        list(GET _parts 2 _rnew)
        list(FIND _redef_srcs "${_rsrc}" _si)
        if(_si EQUAL -1)
            list(APPEND _redef_srcs "${_rsrc}")
        endif()
        list(APPEND _redef_old_${_rsrc} "${_rold}")
        list(APPEND _redef_new_${_rsrc} "${_rnew}")
    endforeach()
endif()

# Apply the absolution IR renames for one source's bitcode module, in place.
function(_apply_redef src bc)
    if(NOT "${src}" IN_LIST _redef_srcs)
        return()
    endif()
    set(_ll "${bc}.ll")
    execute_process(COMMAND "${LLVM_DIS}" "${bc}" -o "${_ll}" RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "llvm-dis failed: ${bc}")
    endif()
    file(READ "${_ll}" _ir)
    list(LENGTH _redef_old_${src} _n)
    set(_j 0)
    while(_j LESS _n)
        list(GET _redef_old_${src} ${_j} _old)
        list(GET _redef_new_${src} ${_j} _new)
        string(REGEX REPLACE "@${_old}([^A-Za-z0-9_$.])" "@${_new}\\1" _ir "${_ir}")
        string(REPLACE "@${_new} = internal " "@${_new} = " _ir "${_ir}")
        string(REPLACE "@${_new} = internal dso_local " "@${_new} = dso_local " _ir "${_ir}")
        math(EXPR _j "${_j} + 1")
    endwhile()
    file(WRITE "${_ll}" "${_ir}")
    execute_process(COMMAND "${LLVM_AS}" "${_ll}" -o "${bc}" RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "llvm-as failed: ${_ll}")
    endif()
endfunction()

# llvm-link has no --wrap: rename a mock module's __wrap_X to X so it overrides
# the real X through the mock tier, as -Wl,--wrap=X does in the native link.
function(_apply_wrap bc)
    if(NOT _wrap_syms)
        return()
    endif()
    set(_ll "${bc}.wrap.ll")
    execute_process(COMMAND "${LLVM_DIS}" "${bc}" -o "${_ll}" RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "llvm-dis failed: ${bc}")
    endif()
    file(READ "${_ll}" _ir)
    string(FIND "${_ir}" "@__wrap_" _has_wrap)
    if(_has_wrap EQUAL -1)
        return()
    endif()
    foreach(_sym ${_wrap_syms})
        string(REGEX REPLACE "@__wrap_${_sym}([^A-Za-z0-9_$.])" "@${_sym}\\1" _ir "${_ir}")
    endforeach()
    file(WRITE "${_ll}" "${_ir}")
    execute_process(COMMAND "${LLVM_AS}" "${_ll}" -o "${bc}" RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "llvm-as failed: ${_ll}")
    endif()
endfunction()

# Per-tier bitcode accumulators.
set(_mock_bcs "")
set(_app_bcs "")
set(_sdk_bcs "")
set(_bc_i 0)

# ── Compile + classify + rename each sampled target TU ───────────────────────
foreach(_src ${_targets})
    # ABSOLUTE also folds "..", so anchored tier patterns see the real path.
    get_filename_component(_abs "${_src}" ABSOLUTE BASE_DIR "${WORK_DIR}")

    _tier_of("${_abs}" _tier)
    set(_tier_dir "${BC_DIR}/${_tier}")
    file(MAKE_DIRECTORY "${_tier_dir}")
    set(_bc "${_tier_dir}/tu_${_bc_i}.bc")
    math(EXPR _bc_i "${_bc_i} + 1")

    set(_tu_flags ${_common_flags})
    if(UBSAN AND (_tier STREQUAL "app" OR _tier STREQUAL "mock"))
        list(APPEND _tu_flags ${_ubsan_flags})
        get_filename_component(_base "${_abs}" NAME)
        if("${_base}" IN_LIST _conv_files)
            list(APPEND _tu_flags ${_conv_flags})
        endif()
    endif()

    execute_process(
        COMMAND "${BC_CC}" ${_tu_flags} "${_abs}" -o "${_bc}"
        RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "bitcode compile failed: ${_abs}")
    endif()

    _apply_redef("${_src}" "${_bc}")
    if(_tier STREQUAL "mock")
        _apply_wrap("${_bc}")
    endif()
    list(APPEND _${_tier}_bcs "${_bc}")
endforeach()

# ── Compile the absolution driver (app tier, no UBSan: generic glue) ──────────
set(_driver_bc "${BC_DIR}/app/driver.bc")
file(MAKE_DIRECTORY "${BC_DIR}/app")
execute_process(
    COMMAND "${BC_CC}" ${_common_flags} "${DRIVER_C}" -o "${_driver_bc}"
    RESULT_VARIABLE _rc)
if(NOT _rc EQUAL 0)
    message(FATAL_ERROR "bitcode compile failed: ${DRIVER_C}")
endif()
list(APPEND _app_bcs "${_driver_bc}")

# ── Compile the harness (app tier, no UBSan: the oracle lives in the TUs) ─────
if(HARNESS)
    set(_harness_bc "${BC_DIR}/app/harness.bc")
    execute_process(
        COMMAND "${BC_CC}" ${_common_flags} "${HARNESS}" -o "${_harness_bc}"
        RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "bitcode compile failed: ${HARNESS}")
    endif()
    list(APPEND _app_bcs "${_harness_bc}")
endif()

_csv_to_list("${EXTRA_SOURCES}" _extra_srcs)
set(_extra_i 0)
foreach(_extra ${_extra_srcs})
    set(_extra_bc "${BC_DIR}/app/extra_${_extra_i}.bc")
    math(EXPR _extra_i "${_extra_i} + 1")
    execute_process(
        COMMAND "${BC_CC}" ${_common_flags} "${_extra}" -o "${_extra_bc}"
        RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "bitcode compile failed: ${_extra}")
    endif()
    list(APPEND _app_bcs "${_extra_bc}")
endforeach()

# ── Compile the abort-on-UB stubs (app tier) so __ubsan_handle_* resolve ──────
if(UBSAN)
    if(NOT UBSAN_STUBS OR NOT EXISTS "${UBSAN_STUBS}")
        message(FATAL_ERROR "UBSAN=ON but UBSAN_STUBS='${UBSAN_STUBS}' not found")
    endif()
    set(_stub_bc "${BC_DIR}/app/ubsan_stubs.bc")
    execute_process(
        COMMAND "${BC_CC}" -emit-llvm -c -g ${BC_OPT} -w "${UBSAN_STUBS}" -o "${_stub_bc}"
        RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "bitcode compile failed: ${UBSAN_STUBS}")
    endif()
    list(APPEND _app_bcs "${_stub_bc}")
endif()

# ── KLEE copies (app tier): a symbolic size forks once instead of per byte ────
if(ENGINE_DEF STREQUAL "ABSOLUTION_KLEE")
    set(_copy_src "${CMAKE_CURRENT_LIST_DIR}/symbolic/klee_mem_copy.c")
    set(_copy_bc "${BC_DIR}/app/klee_mem_copy.bc")
    execute_process(
        COMMAND "${BC_CC}" -emit-llvm -c -g ${BC_OPT} -fno-builtin -w "${_copy_src}" -o "${_copy_bc}"
        RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "bitcode compile failed: ${_copy_src}")
    endif()
    list(APPEND _app_bcs "${_copy_bc}")
endif()

# ── Optional allocator-concretisation shim (mock tier, overrides the SDK) ─────
# The real SDK allocator walks chunk metadata with symbolic pointer arithmetic,
# which turns into non-terminating STP address-resolve queries once a symbolic
# value reaches it. ALLOC_SHIM is a malloc-backed drop-in for the lib_alloc
# symbols; placing it in the mock tier makes it win over ledger-secure-sdk's
# mem_alloc.c at link, so no symbolic chunk-walk is ever generated. Compiled
# without UBSan (infrastructure, not code under test).
if(ALLOC_SHIM)
    if(NOT EXISTS "${ALLOC_SHIM}")
        message(FATAL_ERROR "ALLOC_SHIM='${ALLOC_SHIM}' not found")
    endif()
    file(MAKE_DIRECTORY "${BC_DIR}/mock")
    set(_alloc_bc "${BC_DIR}/mock/alloc_shim.bc")
    execute_process(
        COMMAND "${BC_CC}" ${_common_flags} -w "${ALLOC_SHIM}" -o "${_alloc_bc}"
        RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "bitcode compile failed: ${ALLOC_SHIM}")
    endif()
    _apply_wrap("${_alloc_bc}")
    list(APPEND _mock_bcs "${_alloc_bc}")
endif()

# ── Tiered link: mock overrides app; app pulls only-needed SDK ───────────────
function(_llvm_link out)
    execute_process(
        COMMAND "${LLVM_LINK}" ${ARGN} -o "${out}"
        RESULT_VARIABLE _rc ERROR_VARIABLE _err)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "llvm-link -> ${out} failed:\n${_err}")
    endif()
endfunction()

list(LENGTH _mock_bcs _n_mock)
list(LENGTH _sdk_bcs  _n_sdk)

# -override lets every mock definition win, weak ones included. A weak mock is
# only a default (e.g. fuzz_runtime.c's no-op fuzz_app_reset), and in the native
# link the harness's strong definition beats it; keep that by deleting the weak
# mocks the app tier defines strongly before the override link.
function(_drop_shadowed_weak mock_bc)
    string(REPLACE "llvm-link" "llvm-nm" _nm "${LLVM_LINK}")
    string(REPLACE "llvm-link" "llvm-extract" _extract "${LLVM_LINK}")
    execute_process(COMMAND "${_nm}" --defined-only "${mock_bc}"
        OUTPUT_VARIABLE _mock_syms RESULT_VARIABLE _rc ERROR_VARIABLE _err)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "llvm-nm failed on ${mock_bc}:\n${_err}")
    endif()
    execute_process(COMMAND "${_nm}" --defined-only ${ARGN}
        OUTPUT_VARIABLE _app_syms RESULT_VARIABLE _rc ERROR_VARIABLE _err)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "llvm-nm failed on the app tier:\n${_err}")
    endif()
    string(REGEX MATCHALL " W [^ \n]+" _weak "${_mock_syms}")
    set(_drop "")
    foreach(_w ${_weak})
        string(SUBSTRING "${_w}" 3 -1 _sym)
        string(FIND "${_app_syms}" " T ${_sym}\n" _pos)
        if(NOT _pos EQUAL -1)
            list(APPEND _drop "--func=${_sym}")
        endif()
    endforeach()
    if(_drop)
        execute_process(COMMAND "${_extract}" --delete ${_drop} "${mock_bc}" -o "${mock_bc}"
            RESULT_VARIABLE _rc ERROR_VARIABLE _err)
        if(NOT _rc EQUAL 0)
            message(FATAL_ERROR "llvm-extract failed on ${mock_bc}:\n${_err}")
        endif()
    endif()
endfunction()

set(_override_args "")
if(_n_mock GREATER 0)
    set(_mock_bc "${BC_DIR}/.mock.bc")
    _llvm_link("${_mock_bc}" ${_mock_bcs})
    _drop_shadowed_weak("${_mock_bc}" ${_app_bcs})
    set(_override_args -override "${_mock_bc}")
endif()

if(_n_sdk GREATER 0)
    set(_base_bc "${BC_DIR}/.base.bc")
    _llvm_link("${_base_bc}" ${_override_args} ${_app_bcs})
    set(_sdk_bc "${BC_DIR}/.sdk.bc")
    _llvm_link("${_sdk_bc}" ${_sdk_bcs})
    _llvm_link("${OUT_BC}" --only-needed "${_base_bc}" "${_sdk_bc}")
else()
    # Single/two-tier (no SDK): link app (optionally mock-overridden) straight out.
    _llvm_link("${OUT_BC}" ${_override_args} ${_app_bcs})
endif()

# ── Merge the per-TU depfiles into one rule for OUT_BC ───────────────────────
# Each holds "<tu>.bc: deps..." with make escaping; keep the deps verbatim.
file(GLOB_RECURSE _tu_deps "${BC_DIR}/*.d")
set(_all_deps "")
foreach(_d ${_tu_deps})
    file(READ "${_d}" _txt)
    string(REPLACE "\\\n" " " _txt "${_txt}")
    string(REGEX REPLACE "^[^:]*:" "" _txt "${_txt}")
    string(REPLACE "\n" " " _txt "${_txt}")
    string(APPEND _all_deps " ${_txt}")
endforeach()
string(REGEX REPLACE "[ \t]+" " " _all_deps "${_all_deps}")
file(WRITE "${OUT_BC}.d" "${OUT_BC}:${_all_deps}\n")

list(LENGTH _app_bcs _n_app)
message(STATUS "[absolution] symbolic bitcode: ${OUT_BC} "
    "(tiers: mock=${_n_mock} app=${_n_app} sdk=${_n_sdk})")
