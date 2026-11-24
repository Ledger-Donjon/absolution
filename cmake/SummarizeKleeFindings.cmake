# SummarizeKleeFindings.cmake — script-mode helper.
#
# Reports the outcome of a KLEE campaign WITHOUT treating a time-boxed run as a
# build failure. Invoked as:
#   cmake -DKLEE_OUT=<dir> -DNAME=<target> [-DJOBS=<n>] -P SummarizeKleeFindings.cmake
#
# Rationale: a symbolic campaign that hits its --max-time budget (and is then
# force-halted by the watchdog, which makes KLEE exit non-zero) is a NORMAL
# outcome, not an error. The only genuine failure is KLEE never starting, which
# we detect by the absence of the `info` file KLEE writes when it starts. With
# JOBS > 1, each job k has its own output directory, KLEE_OUT/<k>.

if(NOT JOBS)
    set(JOBS 1)
endif()
if(JOBS GREATER 1)
    file(GLOB _infos "${KLEE_OUT}/*/info")
else()
    file(GLOB _infos "${KLEE_OUT}/info")
endif()
list(LENGTH _infos _started)
if(_started EQUAL 0)
    message(FATAL_ERROR
        "[absolution] KLEE produced no output in '${KLEE_OUT}' -- the run "
        "never started (toolchain / bitcode / setup error).")
endif()
if(_started LESS JOBS)
    message(WARNING "[absolution] ${NAME}: only ${_started} of ${JOBS} KLEE jobs started; "
        "see ${KLEE_OUT}/<job>.log")
endif()

file(GLOB_RECURSE _errs "${KLEE_OUT}/*.err")
list(LENGTH _errs _n)
file(GLOB_RECURSE _ktests "${KLEE_OUT}/*.ktest")
list(LENGTH _ktests _nk)

if(_n GREATER 0)
    message(STATUS "[absolution] ${NAME}: KLEE reported ${_n} error path(s):")
    foreach(_e ${_errs})
        file(RELATIVE_PATH _b "${KLEE_OUT}" "${_e}")
        message(STATUS "    - ${_b}")
    endforeach()
    message(STATUS "[absolution] ${NAME}: inspect ${KLEE_OUT} "
        "(each *.err has a matching *.ktest holding the concrete PoC input).")
else()
    message(STATUS "[absolution] ${NAME}: KLEE campaign completed with 0 error "
        "paths (${_nk} test(s) recorded) -- no bug within the time/solver budget.")
endif()
