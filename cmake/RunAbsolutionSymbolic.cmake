# RunAbsolutionSymbolic.cmake — script-mode helper (build time).
#
# Runs the absolution CLI in --symbolic mode to emit the symbolic-execution
# driver (AbsolutionSymbolicTestOneInput + main) and the .redef file. Unlike the
# fuzzer path there is no seed; the input model lives in sample_invariant().
#
# -D variables:
#   ABSOLUTION   — path to absolution binary
#   TARGETS_FILE — one relative source path per line
#   OUT_C        — output driver .c path
#   REDEF        — output .redef path
#   ENTRY        — harness entry function name
#   ENGINE       — symbolic backend: klee
#   APDU_SIZE    — symbolic APDU byte size
#   INVARIANT    — (optional) .zon constraint file
#   ZERO_SYMBOLS / LENIENT_ZERO_SYMBOLS / DOMAIN_OVERRIDES
#                — (optional) comma-joined file lists
#   SKIP_POINTERS— (optional) TRUE to pass --no-symbolic-pointers (leave
#                  unconstrained pointer-typed globals NULL, not symbolic)
#   NO_POST_CHECK— (optional) TRUE to pass --no-post-check
#   FLAGS_FILE   — one compiler flag per line
#   WORK_DIR     — CMAKE_SOURCE_DIR (targets resolved relative to this)

file(STRINGS "${TARGETS_FILE}" _targets)
file(STRINGS "${FLAGS_FILE}"   _flags)

set(_cmd "${ABSOLUTION}")
foreach(_t ${_targets})
    list(APPEND _cmd -t "${_t}")
endforeach()
list(APPEND _cmd
    -o "${OUT_C}"
    -r "${REDEF}"
    -e "${ENTRY}"
    --symbolic "${ENGINE}"
    --apdu-size "${APDU_SIZE}"
)
if(INVARIANT)
    list(APPEND _cmd -i "${INVARIANT}")
endif()
foreach(_pair "ZERO_SYMBOLS;-Z" "LENIENT_ZERO_SYMBOLS;--lenient-zero-symbols" "DOMAIN_OVERRIDES;-O")
    list(GET _pair 0 _var)
    list(GET _pair 1 _opt)
    string(REPLACE "," ";" _files "${${_var}}")
    foreach(_f ${_files})
        list(APPEND _cmd "${_opt}" "${_f}")
    endforeach()
endforeach()
if(SKIP_POINTERS)
    list(APPEND _cmd --no-symbolic-pointers)
endif()
if(NO_POST_CHECK)
    list(APPEND _cmd --no-post-check)
endif()
list(APPEND _cmd --)
foreach(_f ${_flags})
    list(APPEND _cmd "${_f}")
endforeach()

execute_process(
    COMMAND ${_cmd}
    WORKING_DIRECTORY "${WORK_DIR}"
    RESULT_VARIABLE _rc
)
if(NOT _rc EQUAL 0)
    message(FATAL_ERROR "absolution --symbolic failed (exit ${_rc})")
endif()
