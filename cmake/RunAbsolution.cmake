# RunAbsolution.cmake — script-mode helper (build time)
#
# -D variables:
#   ABSOLUTION     — path to absolution binary
#   TARGETS_FILE — one relative source path per line
#   OUT_C        — output fuzzer.c path
#   REDEF        — output .redef path
#   SEED         — output .seed path
#   ENTRY        — entry function name
#   INVARIANT    — (optional) invariant file path
#   ZERO_SYMBOLS / LENIENT_ZERO_SYMBOLS / DOMAIN_OVERRIDES
#                — (optional) comma-joined file lists
#   NO_POST_CHECK— (optional) TRUE to pass --no-post-check
#   FLAGS_FILE   — one compiler flag per line (-Ipath, -DFOO, -std=c99 …)
#   WORK_DIR     — CMAKE_SOURCE_DIR (absolution resolves targets relative to this)

file(STRINGS "${TARGETS_FILE}" _targets)
file(STRINGS "${FLAGS_FILE}"   _flags)

set(_cmd "${ABSOLUTION}")
foreach(_t ${_targets})
    list(APPEND _cmd -t "${_t}")
endforeach()
list(APPEND _cmd
    -o "${OUT_C}"
    -z "${OUT_C}.zon"
    -r "${REDEF}"
    -s "${SEED}"
    -e "${ENTRY}"
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
    message(FATAL_ERROR "absolution failed (exit ${_rc})")
endif()