# AbsolutionSymbolic.cmake — provides absolution_add_symbolic_target().
#
# Sibling of absolution_add_fuzzer(): it reuses the SAME target-collection and
# flag-harvesting machinery, but drives absolution in --symbolic mode and
# compiles the result to a single LLVM bitcode module for a symbolic-execution
# engine (KLEE by default) instead of a libFuzzer executable.
#
# The generated driver (AbsolutionSymbolicTestOneInput + main) reuses the exact
# same sample_invariant() input model as the fuzzer, so the symbolic run starts
# at the same entry with the same constrained globals. Before sampling it calls
# absolution_sym_prepare(input, globals_size, apdu_size), weak and empty in the
# driver: a harness source may define it to constrain the input first.
#
# Usage:
#   find_package(Absolution REQUIRED)
#   absolution_add_symbolic_target(
#       NAME sym_decode
#       TARGETS src/decoder.c src/session.c
#       HARNESS fuzz/fuzz_decode.c
#       ENTRY   FuzzDecode
#       APDU_SIZE 300
#       LINK_LIBRARIES protocol
#       BITCODE_TOOLCHAIN_BIN /path/to/clang+llvm-13/bin   # KLEE-compatible
#   )
#   # then:  cmake --build build --target sym_decode        # builds the .bc
#   #        cmake --build build --target sym_decode_klee   # runs KLEE
#
# Keywords:
#   NAME       (required)  logical target name (creates ${NAME}, ${NAME}_klee).
#   TARGETS    (required)  sampled .c files (their globals become symbolic).
#   HARNESS    (optional)  harness .c containing ENTRY.
#   EXTRA_SOURCES (optional) more harness-side .c files (glue, generated
#                          tables): compiled into the module, never sampled.
#   ENTRY      (optional)  harness entry (default AbsolutionSymbolicTestOneInput).
#   INVARIANT  (optional)  .zon constraint file.
#   ZERO_SYMBOLS / LENIENT_ZERO_SYMBOLS / DOMAIN_OVERRIDES
#                          same semantics as absolution_add_fuzzer().
#   WRAP       (optional)  symbols the native build redirects with -Wl,--wrap=X.
#                          llvm-link has no --wrap, so mock-tier definitions of
#                          __wrap_X are renamed to X at the IR level and then
#                          override the real X like any other mock. Mocks must
#                          not call __real_X.
#   SKIP_POINTERS (optional) flag: pass --no-symbolic-pointers so sample_invariant
#                          leaves unconstrained pointer-typed globals NULL instead
#                          of feeding them raw symbolic bytes. A symbolic address
#                          is never a meaningful input: it forces the solver to
#                          resolve a wild pointer over the whole address space
#                          (path/fork blowup) and makes app cleanup (e.g. a Ledger
#                          list-head walk in reset_app_context) chase garbage.
#                          Named .pointers targets are unaffected. Recommended for
#                          dispatcher-start runs; leaves the fuzzer lane untouched.
#   NO_POST_CHECK (optional) flag: do not assert check_invariant() after the
#                          harness (it may leave globals outside the domain).
#   ENGINE     (optional)  klee (the default and, for now, the only engine).
#   APDU_SIZE  (optional)  symbolic APDU byte size (default 260).
#   BITCODE_TOOLCHAIN_BIN  dir with clang/llvm-dis/llvm-as/llvm-link that emit
#                          bitcode your KLEE understands (KLEE 3.x -> LLVM 13).
#                          Defaults to searching PATH.
#   BITCODE_OPT            optimisation for bitcode (default -O0).
#   UBSAN      (optional)  flag: instrument the app/mock tiers with
#                          -fsanitize=undefined -fno-sanitize-recover=all and
#                          link abort()-on-UB stubs, so KLEE reports UB as an
#                          error path (a symbolic bug oracle).
#   UBSAN_STUBS(optional)  the abort-on-UB stub .c (default: the generic
#                          cmake/symbolic/ubsan_stubs.c shipped with Absolution).
#   ALLOC_SHIM (optional)  flag: link a malloc-backed drop-in for the Ledger SDK
#                          allocator (lib_alloc) into the mock tier, overriding
#                          the real mem_alloc.c. The real allocator walks chunk
#                          metadata with pointer arithmetic, so a symbolic value
#                          reaching the heap forces a non-terminating STP
#                          address-resolve over the pool; the shim returns
#                          concrete malloc addresses instead. Bug oracle intact
#                          (UB still aborts at its site, before the allocator).
#   ALLOC_SHIM_SRC(optional) override the shim .c (default: the generic
#                          cmake/symbolic/klee_mem_alloc.c shipped with Absolution).
#   CONV_FILES (optional)  basenames to ALSO instrument with implicit-integer-
#                          truncation/sign-change (silent narrowing UBSan omits);
#                          requires UBSAN. Scope it to the file(s) under test so
#                          a benign narrowing elsewhere does not abort.
#   TIER_MOCK_MATCH        path substrings marking the mock tier (default
#                          "tests/fuzzing/mock/"); mock symbols override the real
#                          SDK ones they shadow at link (llvm-link has no
#                          --allow-multiple-definition).
#   TIER_SDK_MATCH         path substrings marking the low-priority SDK tier
#                          (default "ledger-secure-sdk/"); linked --only-needed.
#   LD_LIBRARY_PATH        prepended when invoking the bitcode toolchain + KLEE.
#   KLEE_COMMAND           list forming the klee launcher (default "klee";
#                          e.g. "snap;run;klee" on snap installs).
#   KLEE_MAX_TIME          seconds for the _klee run (default 60).
#   KLEE_ARGS              extra klee flags (default: --libc=uclibc
#                          --emit-all-errors --optimize --watchdog
#                          --max-solver-time=30 --max-memory=8000
#                          --max-static-fork-pct=0.1
#                          --inline-threshold=-5000). The _klee target
#                          always adds the --function-alias pair that wires in
#                          symbolic/klee_mem_copy.c.
#   KLEE_JOBS              KLEE processes the _klee run starts side by side, each
#                          for KLEE_MAX_TIME (default 1). Job k writes to
#                          klee_out/<k> (one job: klee_out itself) and gets every
#                          "@JOB@" in KLEE_ARGS replaced by k, which is what
#                          makes the jobs differ: a seed directory each, say.
#                          KLEE is single-threaded, so jobs use more cores; a
#                          slow solver query also stalls only its own job.
#   KLEE_SEED_SLICE        seconds (default 0: off). Each job runs the seeds of
#                          its --seed-dir one at a time, each alone in its own
#                          KLEE process for at most that long, until
#                          KLEE_MAX_TIME is spent; tests and info still land in
#                          the job's output directory (symbolic/run_klee_jobs.sh).
#   INCLUDE_DIRECTORIES / COMPILE_DEFINITIONS / COMPILE_OPTIONS / LINK_LIBRARIES
#                          same semantics as absolution_add_fuzzer().
#
# Target properties on ${NAME} (read at generate time, so a hardening step can
# append to them after this call):
#   ABSOLUTION_WRAP        initialised from WRAP
#   ABSOLUTION_TIER_MOCK   initialised from TIER_MOCK_MATCH
#   ABSOLUTION_ALLOC_SHIM  initialised from ALLOC_SHIM / ALLOC_SHIM_SRC
#
# Exported (PARENT_SCOPE):
#   ${NAME}_BITCODE   path to the linked .bc
#   ${NAME}_DRIVER_C  path to the generated symbolic driver
#   ${NAME}_REDEF     path to the .redef file

function(absolution_add_symbolic_target)
    cmake_parse_arguments(
        SYM
        "UBSAN;ALLOC_SHIM;SKIP_POINTERS;NO_POST_CHECK"
        "NAME;HARNESS;INVARIANT;ENTRY;ENGINE;APDU_SIZE;BITCODE_TOOLCHAIN_BIN;BITCODE_OPT;LD_LIBRARY_PATH;KLEE_MAX_TIME;KLEE_JOBS;KLEE_SEED_SLICE;UBSAN_STUBS;ALLOC_SHIM_SRC"
        "TARGETS;EXTRA_SOURCES;COMPILE_OPTIONS;INCLUDE_DIRECTORIES;COMPILE_DEFINITIONS;LINK_LIBRARIES;KLEE_COMMAND;KLEE_ARGS;CONV_FILES;TIER_MOCK_MATCH;TIER_SDK_MATCH;ZERO_SYMBOLS;LENIENT_ZERO_SYMBOLS;DOMAIN_OVERRIDES;WRAP"
        ${ARGN}
    )

    if(NOT SYM_NAME)
        message(FATAL_ERROR "absolution_add_symbolic_target: NAME is required")
    endif()
    if(NOT SYM_TARGETS)
        message(FATAL_ERROR "absolution_add_symbolic_target: TARGETS is required")
    endif()
    if(NOT SYM_ENTRY)
        set(SYM_ENTRY "AbsolutionSymbolicTestOneInput")
    endif()
    if(NOT SYM_ENGINE)
        set(SYM_ENGINE "klee")
    endif()
    if(NOT SYM_APDU_SIZE)
        set(SYM_APDU_SIZE 260)
    endif()
    if(NOT SYM_BITCODE_OPT)
        set(SYM_BITCODE_OPT "-O0")
    endif()
    if(NOT SYM_KLEE_MAX_TIME)
        set(SYM_KLEE_MAX_TIME 60)
    endif()
    if(NOT SYM_KLEE_COMMAND)
        set(SYM_KLEE_COMMAND "klee")
    endif()
    if(NOT SYM_KLEE_JOBS)
        set(SYM_KLEE_JOBS 1)
    endif()
    if(NOT SYM_KLEE_JOBS MATCHES "^[1-9][0-9]*$")
        message(FATAL_ERROR "absolution_add_symbolic_target: KLEE_JOBS must be a positive integer, got '${SYM_KLEE_JOBS}'")
    endif()
    if(NOT SYM_KLEE_SEED_SLICE)
        set(SYM_KLEE_SEED_SLICE 0)
    endif()
    if(NOT SYM_KLEE_SEED_SLICE MATCHES "^[0-9]+$")
        message(FATAL_ERROR "absolution_add_symbolic_target: KLEE_SEED_SLICE must be a whole number of seconds, got '${SYM_KLEE_SEED_SLICE}'")
    endif()
    if(NOT SYM_KLEE_ARGS)
        # --watchdog runs the timers in a separate process so --max-time and
        # --max-solver-time actually preempt a blocked STP query (without it a
        # hard query hangs past the budget). --max-solver-time bounds each query;
        # the _klee target also sets `ulimit -s unlimited` because STP recurses
        # deeply on the TLV walk and otherwise crashes/stalls those queries.
        # --max-static-fork-pct: past the seeds, an instruction that has made over
        # 10% of the forks follows one side, so a loop over symbolic bytes cannot
        # fill --max-memory, past which KLEE kills states at random.
        # --inline-threshold=-5000: --optimize then inlines only single-caller
        # functions of up to about 2,000 instructions, not every handler into
        # the APDU dispatcher, whose registers each forked state copies.
        set(SYM_KLEE_ARGS --libc=uclibc --emit-all-errors --optimize
            --watchdog --max-solver-time=30 --max-memory=8000
            --max-static-fork-pct=0.1 --inline-threshold=-5000)
    endif()

    # ── UBSan-abort oracle + tier classification (app-grade options) ──────────
    # UBSAN turns clang's -fsanitize=undefined into a KLEE bug oracle by linking
    # abort()-on-UB stubs; CONV_FILES additionally enables the silent-narrowing
    # checks (implicit-integer-truncation/sign-change) on just the named files.
    # TIER_*_MATCH classify each TU so fuzz mocks override the real SDK symbols
    # they shadow at link time (llvm-link has no --allow-multiple-definition).
    if(SYM_UBSAN AND NOT SYM_UBSAN_STUBS)
        set(SYM_UBSAN_STUBS "${_ABSOLUTION_MODULE_DIR}/symbolic/ubsan_stubs.c")
    endif()
    # ALLOC_SHIM concretises the SDK allocator (mock tier overrides lib_alloc's
    # mem_alloc.c) so a symbolic value reaching the heap does not trigger a
    # non-terminating STP address-resolve over the chunk pool. Defaults to the
    # generic malloc-backed shim shipped with Absolution.
    if(SYM_ALLOC_SHIM AND NOT SYM_ALLOC_SHIM_SRC)
        set(SYM_ALLOC_SHIM_SRC "${_ABSOLUTION_MODULE_DIR}/symbolic/klee_mem_alloc.c")
    endif()
    if(NOT SYM_TIER_MOCK_MATCH)
        set(SYM_TIER_MOCK_MATCH "tests/fuzzing/mock/")
    endif()
    if(NOT SYM_TIER_SDK_MATCH)
        set(SYM_TIER_SDK_MATCH "ledger-secure-sdk/")
    endif()
    if(SYM_UBSAN)
        set(_ubsan_flag "ON")
    else()
        set(_ubsan_flag "OFF")
    endif()
    # Lists cross the -P boundary as comma-joined scalars (semicolons are CMake
    # list separators and would be resplit by the command line); the script
    # re-splits on comma.
    string(REPLACE ";" "," _conv_csv "${SYM_CONV_FILES}")
    string(REPLACE ";" "," _tier_sdk_csv "${SYM_TIER_SDK_MATCH}")
    set(_tier_mock_csv "$<JOIN:$<TARGET_PROPERTY:${SYM_NAME},ABSOLUTION_TIER_MOCK>,$<COMMA>>")
    set(_wrap_csv "$<JOIN:$<TARGET_PROPERTY:${SYM_NAME},ABSOLUTION_WRAP>,$<COMMA>>")
    set(_alloc_shim "$<TARGET_PROPERTY:${SYM_NAME},ABSOLUTION_ALLOC_SHIM>")

    # Engine -> driver define.
    if(SYM_ENGINE STREQUAL "klee")
        set(_engine_def "ABSOLUTION_KLEE")
    else()
        message(FATAL_ERROR "absolution_add_symbolic_target: unknown ENGINE '${SYM_ENGINE}'")
    endif()

    # ── Locate the bitcode toolchain ──────────────────────────────────────────
    if(SYM_BITCODE_TOOLCHAIN_BIN)
        set(_BC_CC     "${SYM_BITCODE_TOOLCHAIN_BIN}/clang")
        set(_LLVM_DIS  "${SYM_BITCODE_TOOLCHAIN_BIN}/llvm-dis")
        set(_LLVM_AS   "${SYM_BITCODE_TOOLCHAIN_BIN}/llvm-as")
        set(_LLVM_LINK "${SYM_BITCODE_TOOLCHAIN_BIN}/llvm-link")
    else()
        find_program(_BC_CC     clang)
        find_program(_LLVM_DIS  llvm-dis)
        find_program(_LLVM_AS   llvm-as)
        find_program(_LLVM_LINK llvm-link)
    endif()
    foreach(_tool _BC_CC _LLVM_DIS _LLVM_AS _LLVM_LINK)
        if(NOT ${_tool} OR NOT EXISTS "${${_tool}}")
            message(FATAL_ERROR "absolution_add_symbolic_target: bitcode tool ${_tool}='${${_tool}}' not found "
                "(set BITCODE_TOOLCHAIN_BIN to a KLEE-compatible clang+llvm bin dir)")
        endif()
    endforeach()

    # ── Working directory ─────────────────────────────────────────────────────
    set(_SYM_DIR "${CMAKE_CURRENT_BINARY_DIR}/_absolution_sym/${SYM_NAME}")
    file(MAKE_DIRECTORY "${_SYM_DIR}")
    set(_DRIVER_C     "${_SYM_DIR}/symbolic.c")
    set(_REDEF_FILE   "${_SYM_DIR}/symbolic.redef")
    set(_TARGETS_FILE "${_SYM_DIR}/absolution_targets.txt")
    set(_FLAGS_FILE   "${_SYM_DIR}/absolution_flags.rsp")
    set(_BC_DIR       "${_SYM_DIR}/bc")
    set(_OUT_BC       "${_SYM_DIR}/${SYM_NAME}.bc")

    # ── Resolve target paths (relative to source root, as absolution expects) ──
    set(_REL_TARGETS "")
    set(_ABS_TARGETS "")
    foreach(_t ${SYM_TARGETS})
        get_filename_component(_abs "${_t}" ABSOLUTE)
        file(RELATIVE_PATH _rel "${CMAKE_SOURCE_DIR}" "${_abs}")
        list(APPEND _REL_TARGETS "${_rel}")
        list(APPEND _ABS_TARGETS "${_abs}")
    endforeach()

    # ── Reuse the fuzzer's single-pass tree walk to absorb LINK_LIBRARIES ─────
    set(_dep_sources "")
    set(_absorbed_targets "")
    set(_exe_incs "")
    set(_exe_defs "")
    set(_exe_opts "")
    set(_exe_link_opts "")
    set(_exe_passthrough "")
    set(_visited "")
    if(SYM_LINK_LIBRARIES)
        _absolution_collect_all("${SYM_LINK_LIBRARIES}"
            _dep_sources _absorbed_targets
            _exe_incs _exe_defs _exe_opts _exe_link_opts
            _exe_passthrough _visited)
    endif()
    foreach(_s ${_dep_sources})
        if(NOT "${_s}" IN_LIST _ABS_TARGETS)
            file(RELATIVE_PATH _rel "${CMAKE_SOURCE_DIR}" "${_s}")
            list(APPEND _REL_TARGETS "${_rel}")
            list(APPEND _ABS_TARGETS "${_s}")
        endif()
    endforeach()

    # ── Flag-harvest object library (never built; only its genex props read) ──
    set(_FLAG_LIB "${SYM_NAME}_symflags")
    add_library(${_FLAG_LIB} OBJECT EXCLUDE_FROM_ALL ${_ABS_TARGETS})
    if(SYM_LINK_LIBRARIES)
        target_link_libraries(${_FLAG_LIB} PRIVATE ${SYM_LINK_LIBRARIES})
    endif()
    foreach(_inc ${SYM_INCLUDE_DIRECTORIES})
        target_include_directories(${_FLAG_LIB} PRIVATE "${_inc}")
    endforeach()
    foreach(_def ${SYM_COMPILE_DEFINITIONS})
        target_compile_definitions(${_FLAG_LIB} PRIVATE "${_def}")
    endforeach()
    if(SYM_COMPILE_OPTIONS)
        target_compile_options(${_FLAG_LIB} PRIVATE ${SYM_COMPILE_OPTIONS})
    endif()

    string(REPLACE ";" "\n" _targets_newline "${_REL_TARGETS}")
    file(GENERATE OUTPUT "${_TARGETS_FILE}" CONTENT "${_targets_newline}\n")

    file(GENERATE
        OUTPUT  "${_FLAGS_FILE}"
        CONTENT
"-I$<JOIN:$<TARGET_PROPERTY:${_FLAG_LIB},INCLUDE_DIRECTORIES>,\n-I>
-D$<JOIN:$<TARGET_PROPERTY:${_FLAG_LIB},COMPILE_DEFINITIONS>,\n-D>
$<JOIN:$<TARGET_PROPERTY:${_FLAG_LIB},COMPILE_OPTIONS>,\n>
"
    )

    _absolution_model_args(SYM _model_defs _model_deps)

    # ── Step 1: run absolution --symbolic -> driver.c + redef ─────────────────
    add_custom_command(
        OUTPUT  "${_DRIVER_C}" "${_REDEF_FILE}"
        COMMAND "${CMAKE_COMMAND}"
            "-DABSOLUTION=${ABSOLUTION_EXECUTABLE}"
            "-DTARGETS_FILE=${_TARGETS_FILE}"
            "-DOUT_C=${_DRIVER_C}"
            "-DREDEF=${_REDEF_FILE}"
            "-DENTRY=${SYM_ENTRY}"
            "-DENGINE=${SYM_ENGINE}"
            "-DAPDU_SIZE=${SYM_APDU_SIZE}"
            ${_model_defs}
            "-DSKIP_POINTERS=${SYM_SKIP_POINTERS}"
            "-DNO_POST_CHECK=${SYM_NO_POST_CHECK}"
            "-DFLAGS_FILE=${_FLAGS_FILE}"
            "-DWORK_DIR=${CMAKE_SOURCE_DIR}"
            -P "${_ABSOLUTION_MODULE_DIR}/RunAbsolutionSymbolic.cmake"
        DEPENDS "${ABSOLUTION_EXECUTABLE}" ${_ABS_TARGETS} "${_FLAGS_FILE}" "${_TARGETS_FILE}" ${_model_deps}
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "[absolution] Generating symbolic driver for ${SYM_NAME} (${SYM_ENGINE})"
        VERBATIM
    )

    # ── Step 2: compile to bitcode, IR-rename, link ───────────────────────────
    set(_abs_harness "")
    if(SYM_HARNESS)
        get_filename_component(_abs_harness "${SYM_HARNESS}" ABSOLUTE)
    endif()
    set(_abs_extra "")
    foreach(_e ${SYM_EXTRA_SOURCES})
        get_filename_component(_ae "${_e}" ABSOLUTE)
        list(APPEND _abs_extra "${_ae}")
    endforeach()
    string(REPLACE ";" "," _extra_csv "${_abs_extra}")

    set(_bc_env "")
    if(SYM_LD_LIBRARY_PATH)
        set(_bc_env "${CMAKE_COMMAND}" -E env "LD_LIBRARY_PATH=${SYM_LD_LIBRARY_PATH}")
    endif()

    # The script compiles the TUs itself, so headers reach the build graph only
    # through the depfile it writes.
    set(_bc_depfile "")
    if(CMAKE_GENERATOR MATCHES "Ninja|Makefiles")
        set(_bc_depfile DEPFILE "${_OUT_BC}.d")
    endif()

    add_custom_command(
        OUTPUT  "${_OUT_BC}"
        ${_bc_depfile}
        COMMAND ${_bc_env} "${CMAKE_COMMAND}"
            "-DBC_CC=${_BC_CC}"
            "-DLLVM_DIS=${_LLVM_DIS}"
            "-DLLVM_AS=${_LLVM_AS}"
            "-DLLVM_LINK=${_LLVM_LINK}"
            "-DTARGETS_FILE=${_TARGETS_FILE}"
            "-DFLAGS_FILE=${_FLAGS_FILE}"
            "-DREDEF=${_REDEF_FILE}"
            "-DDRIVER_C=${_DRIVER_C}"
            "-DHARNESS=${_abs_harness}"
            "-DEXTRA_SOURCES=${_extra_csv}"
            "-DENGINE_DEF=${_engine_def}"
            "-DOUT_BC=${_OUT_BC}"
            "-DWORK_DIR=${CMAKE_SOURCE_DIR}"
            "-DBC_DIR=${_BC_DIR}"
            "-DBC_OPT=${SYM_BITCODE_OPT}"
            "-DUBSAN=${_ubsan_flag}"
            "-DUBSAN_STUBS=${SYM_UBSAN_STUBS}"
            "-DCONV_FILES=${_conv_csv}"
            "-DTIER_MOCK_MATCH=${_tier_mock_csv}"
            "-DTIER_SDK_MATCH=${_tier_sdk_csv}"
            "-DALLOC_SHIM=${_alloc_shim}"
            "-DWRAP=${_wrap_csv}"
            -P "${_ABSOLUTION_MODULE_DIR}/BuildSymbolicBitcode.cmake"
        DEPENDS "${_DRIVER_C}" "${_REDEF_FILE}" ${_ABS_TARGETS} "${_abs_harness}" ${_abs_extra} "${_FLAGS_FILE}" "${SYM_UBSAN_STUBS}" "${_alloc_shim}"
                "${_ABSOLUTION_MODULE_DIR}/symbolic/klee_mem_copy.c"
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "[absolution] Building symbolic bitcode for ${SYM_NAME}"
        VERBATIM
    )

    add_custom_target(${SYM_NAME} ALL DEPENDS "${_OUT_BC}")
    set_target_properties(${SYM_NAME} PROPERTIES
        ABSOLUTION_WRAP       "${SYM_WRAP}"
        ABSOLUTION_TIER_MOCK  "${SYM_TIER_MOCK_MATCH}"
        ABSOLUTION_ALLOC_SHIM "${SYM_ALLOC_SHIM_SRC}")

    # ── Step 3: convenience KLEE run target ───────────────────────────────────
    if(SYM_ENGINE STREQUAL "klee")
        set(_klee_out "${_SYM_DIR}/klee_out")
        set(_klee_job_out "${_klee_out}")
        if(SYM_KLEE_JOBS GREATER 1)
            string(FIND "${SYM_KLEE_ARGS}" "@JOB@" _job_arg)
            if(_job_arg EQUAL -1)
                message(FATAL_ERROR "absolution_add_symbolic_target(${SYM_NAME}): KLEE_JOBS ${SYM_KLEE_JOBS} "
                    "needs @JOB@ in KLEE_ARGS, or every job would run the same search")
            endif()
            set(_klee_job_out "${_klee_out}/@JOB@")
        endif()
        set(_klee_env "")
        if(SYM_LD_LIBRARY_PATH)
            set(_klee_env "${CMAKE_COMMAND}" -E env "LD_LIBRARY_PATH=${SYM_LD_LIBRARY_PATH}")
        endif()
        # The launcher swallows KLEE's exit code: a run that ends at --max-time,
        # watchdog kill included, is a normal end. The summary step fails only
        # if no job produced an output directory (a toolchain/setup error).
        add_custom_target(${SYM_NAME}_klee
            COMMAND "${CMAKE_COMMAND}" -E rm -rf "${_klee_out}"
            COMMAND ${_klee_env} bash "${_ABSOLUTION_MODULE_DIR}/symbolic/run_klee_jobs.sh"
                "${SYM_KLEE_JOBS}" "${SYM_KLEE_SEED_SLICE}" "${_klee_out}"
                ${SYM_KLEE_COMMAND}
                "--output-dir=${_klee_job_out}"
                ${SYM_KLEE_ARGS}
                # symbolic/klee_mem_copy.c, linked into every KLEE bitcode
                --function-alias=memcpy:absolution_klee_memcpy
                --function-alias=memmove:absolution_klee_memmove
                "--max-time=${SYM_KLEE_MAX_TIME}"
                "${_OUT_BC}"
            COMMAND "${CMAKE_COMMAND}" "-DKLEE_OUT=${_klee_out}" "-DNAME=${SYM_NAME}"
                "-DJOBS=${SYM_KLEE_JOBS}"
                -P "${_ABSOLUTION_MODULE_DIR}/SummarizeKleeFindings.cmake"
            DEPENDS "${_OUT_BC}"
            WORKING_DIRECTORY "${_SYM_DIR}"
            COMMENT "[absolution] Running KLEE on ${SYM_NAME} (max-time=${SYM_KLEE_MAX_TIME}s)"
            USES_TERMINAL
            VERBATIM
        )
    endif()

    set(${SYM_NAME}_BITCODE  "${_OUT_BC}"     PARENT_SCOPE)
    set(${SYM_NAME}_DRIVER_C "${_DRIVER_C}"   PARENT_SCOPE)
    set(${SYM_NAME}_REDEF    "${_REDEF_FILE}" PARENT_SCOPE)
endfunction()
