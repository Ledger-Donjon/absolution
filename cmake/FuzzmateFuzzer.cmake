# FuzzmateFuzzer.cmake — provides the fuzzmate_add_fuzzer() function.
#
# Usage:
#
#   find_package(Fuzzmate REQUIRED)
#
#   fuzzmate_add_fuzzer(
#       NAME fuzz_my_target
#       TARGETS src/module_a.c src/module_b.c
#       HARNESS fuzz/fuzz_my_target.c
#       ENTRY   MyTestOneInput
#       INCLUDE_DIRECTORIES "${CMAKE_SOURCE_DIR}/include"
#       COMPILE_DEFINITIONS FUZZING=1 MAX_BUF=4096
#       COMPILE_OPTIONS -Wall
#       LINK_LIBRARIES m my_sdk_target
#   )
#
# Keywords:
#   NAME      (required)  — name of the fuzzer executable target.
#   TARGETS   (required)  — C source files whose globals will be fuzzed.
#   HARNESS   (optional)  — C file containing the user's test function.
#   ENTRY     (optional)  — harness function name (default: AbsolutionTestOneInput).
#   INVARIANT (optional)  — .zon constraint file.
#   INCLUDE_DIRECTORIES   — extra -I paths for compiling targets.
#   COMPILE_DEFINITIONS   — preprocessor defines (NAME or NAME=VALUE).
#   COMPILE_OPTIONS       — extra compiler flags for compiling targets.
#   LINK_LIBRARIES        — libraries to link into the fuzzer.  CMake targets in
#                           this list are "absorbed": their source files (and those
#                           of their transitive link dependencies) are compiled into
#                           the OBJECT library and passed to fuzzmate for analysis.
#                           Non-target names (e.g. -lm) and IMPORTED targets are
#                           linked normally.
#   SANITIZERS            — sanitizer list (default: fuzzer,address).
#
# Created targets:
#   ${NAME}_objs      — OBJECT library containing compiled target sources.
#   ${NAME}_generate  — Custom target that runs fuzzmate CLI to produce artifacts.
#   ${NAME}_redef     — Custom target that applies objcopy symbol redefinitions.
#   ${NAME}           — Final fuzzer executable.
#
# Exported variables (PARENT_SCOPE):
#   ${NAME}_SEED_FILE       — Path to the generated seed file.
#   ${NAME}_FUZZER_C        — Path to the generated fuzzer.c file.
#   ${NAME}_REDEF_FILE      — Path to the generated .redef file.
#   ${NAME}_GENERATE_TARGET — Name of the generate target.
#   ${NAME}_REDEF_TARGET    — Name of the redef target.

# ── Unified single-pass tree walker ─────────────────────────────────────────
# Collects sources, absorbed targets, compile/link interface properties, and
# passthrough link items from a target dependency tree in a single traversal.
#
# Arguments (pass variable *names*, not values, for all _out_* and _visited):
#   _targets         — list of items to walk
#   _out_sources     — accumulated absolute source file paths
#   _out_absorbed    — accumulated non-imported CMake target names
#   _out_incs        — INTERFACE_INCLUDE_DIRECTORIES
#   _out_defs        — INTERFACE_COMPILE_DEFINITIONS
#   _out_opts        — INTERFACE_COMPILE_OPTIONS
#   _out_link_opts   — INTERFACE_LINK_OPTIONS
#   _out_passthrough — non-target items + IMPORTED targets (link as-is)
#   _visited         — bookkeeping set (pass an empty var on first call)
function(_fuzzmate_collect_all
        _targets
        _out_sources _out_absorbed
        _out_incs _out_defs _out_opts _out_link_opts
        _out_passthrough _visited)

    set(_srcs  ${${_out_sources}})
    set(_abs   ${${_out_absorbed}})
    set(_incs  ${${_out_incs}})
    set(_defs  ${${_out_defs}})
    set(_opts  ${${_out_opts}})
    set(_lopts ${${_out_link_opts}})
    set(_pass  ${${_out_passthrough}})
    set(_vis   ${${_visited}})

    foreach(_item ${_targets})
        if("${_item}" MATCHES "^\\$<")
            continue()
        endif()

        if(NOT TARGET "${_item}")
            list(APPEND _pass "${_item}")
            continue()
        endif()

        if("${_item}" IN_LIST _vis)
            continue()
        endif()
        list(APPEND _vis "${_item}")

        get_target_property(_type     "${_item}" TYPE)
        get_target_property(_imported "${_item}" IMPORTED)

        # Collect INTERFACE properties from every reachable target.
        get_target_property(_iincs  "${_item}" INTERFACE_INCLUDE_DIRECTORIES)
        if(_iincs)
            list(APPEND _incs ${_iincs})
        endif()
        get_target_property(_idefs  "${_item}" INTERFACE_COMPILE_DEFINITIONS)
        if(_idefs)
            list(APPEND _defs ${_idefs})
        endif()
        get_target_property(_iopts  "${_item}" INTERFACE_COMPILE_OPTIONS)
        if(_iopts)
            list(APPEND _opts ${_iopts})
        endif()
        get_target_property(_ilopts "${_item}" INTERFACE_LINK_OPTIONS)
        if(_ilopts)
            list(APPEND _lopts ${_ilopts})
        endif()

        if(_imported)
            list(APPEND _pass "${_item}")
        else()
            if(NOT _type STREQUAL "INTERFACE_LIBRARY")
                get_target_property(_target_srcs "${_item}" SOURCES)
                if(_target_srcs)
                    get_target_property(_src_dir "${_item}" SOURCE_DIR)
                    foreach(_s ${_target_srcs})
                        if(NOT IS_ABSOLUTE "${_s}")
                            set(_s "${_src_dir}/${_s}")
                        endif()
                        list(APPEND _srcs "${_s}")
                    endforeach()
                endif()
                get_target_property(_deps "${_item}" LINK_LIBRARIES)
                if(_deps)
                    _fuzzmate_collect_all("${_deps}"
                        _srcs _abs _incs _defs _opts _lopts _pass _vis)
                endif()
            endif()
            list(APPEND _abs "${_item}")
        endif()

        get_target_property(_ideps "${_item}" INTERFACE_LINK_LIBRARIES)
        if(_ideps)
            _fuzzmate_collect_all("${_ideps}"
                _srcs _abs _incs _defs _opts _lopts _pass _vis)
        endif()
    endforeach()

    set(${_out_sources}     "${_srcs}"  PARENT_SCOPE)
    set(${_out_absorbed}    "${_abs}"   PARENT_SCOPE)
    set(${_out_incs}        "${_incs}"  PARENT_SCOPE)
    set(${_out_defs}        "${_defs}"  PARENT_SCOPE)
    set(${_out_opts}        "${_opts}"  PARENT_SCOPE)
    set(${_out_link_opts}   "${_lopts}" PARENT_SCOPE)
    set(${_out_passthrough} "${_pass}"  PARENT_SCOPE)
    set(${_visited}         "${_vis}"   PARENT_SCOPE)
endfunction()

function(fuzzmate_add_fuzzer)
    cmake_parse_arguments(
        FUZZ
        ""
        "NAME;HARNESS;INVARIANT;ENTRY;SANITIZERS"
        "TARGETS;COMPILE_OPTIONS;INCLUDE_DIRECTORIES;COMPILE_DEFINITIONS;LINK_LIBRARIES"
        ${ARGN}
    )

    # ── Validate ─────────────────────────────────────────────────────────────
    if(NOT FUZZ_NAME)
        message(FATAL_ERROR "fuzzmate_add_fuzzer: NAME is required")
    endif()
    if(NOT FUZZ_TARGETS)
        message(FATAL_ERROR "fuzzmate_add_fuzzer: TARGETS is required")
    endif()
    if(NOT FUZZ_ENTRY)
        set(FUZZ_ENTRY "AbsolutionTestOneInput")
    endif()
    if(NOT FUZZ_SANITIZERS)
        set(FUZZ_SANITIZERS "fuzzer,address")
    endif()

    # ── Working directory ─────────────────────────────────────────────────────
    set(_FUZZ_DIR "${CMAKE_CURRENT_BINARY_DIR}/_fuzzmate/${FUZZ_NAME}")
    file(MAKE_DIRECTORY "${_FUZZ_DIR}")

    set(_FUZZER_C      "${_FUZZ_DIR}/fuzzer.c")
    set(_REDEF_FILE    "${_FUZZ_DIR}/fuzzer.redef")
    set(_SEED_FILE     "${_FUZZ_DIR}/fuzzer.seed")
    set(_OBJ_LIST      "${_FUZZ_DIR}/objfiles.txt")
    set(_FLAGS_FILE    "${_FUZZ_DIR}/fuzzmate_flags.rsp")
    set(_TARGETS_FILE  "${_FUZZ_DIR}/fuzzmate_targets.txt")
    set(_REDEF_STAMP   "${_FUZZ_DIR}/redef.stamp")

    # ── Resolve target paths ──────────────────────────────────────────────────
    set(_REL_TARGETS "")
    set(_ABS_TARGETS "")
    foreach(_t ${FUZZ_TARGETS})
        get_filename_component(_abs "${_t}" ABSOLUTE)
        file(RELATIVE_PATH _rel "${CMAKE_SOURCE_DIR}" "${_abs}")
        list(APPEND _REL_TARGETS "${_rel}")
        list(APPEND _ABS_TARGETS "${_abs}")
    endforeach()

    # ── Single-pass tree walk over LINK_LIBRARIES ─────────────────────────────
    set(_dep_sources "")
    set(_absorbed_targets "")
    set(_exe_incs "")
    set(_exe_defs "")
    set(_exe_opts "")
    set(_exe_link_opts "")
    set(_exe_passthrough "")
    set(_visited "")

    if(FUZZ_LINK_LIBRARIES)
        _fuzzmate_collect_all("${FUZZ_LINK_LIBRARIES}"
            _dep_sources _absorbed_targets
            _exe_incs _exe_defs _exe_opts _exe_link_opts
            _exe_passthrough _visited)
    endif()

    foreach(_s ${_dep_sources})
        if(NOT "${_s}" IN_LIST _ABS_TARGETS)
            if(NOT EXISTS "${_s}")
                set_source_files_properties("${_s}" PROPERTIES GENERATED TRUE)
            endif()
            file(RELATIVE_PATH _rel "${CMAKE_SOURCE_DIR}" "${_s}")
            list(APPEND _REL_TARGETS "${_rel}")
            list(APPEND _ABS_TARGETS "${_s}")
        endif()
    endforeach()

    # ── Step 1: OBJECT library ────────────────────────────────────────────────
    set(_OBJ_LIB "${FUZZ_NAME}_objs")

    add_library(${_OBJ_LIB} OBJECT ${_ABS_TARGETS})
    target_compile_options(${_OBJ_LIB} PRIVATE -g)

    if(FUZZ_LINK_LIBRARIES)
        target_link_libraries(${_OBJ_LIB} PRIVATE ${FUZZ_LINK_LIBRARIES})
    endif()
    foreach(_inc ${FUZZ_INCLUDE_DIRECTORIES})
        target_include_directories(${_OBJ_LIB} PRIVATE "${_inc}")
    endforeach()
    foreach(_def ${FUZZ_COMPILE_DEFINITIONS})
        target_compile_definitions(${_OBJ_LIB} PRIVATE "${_def}")
    endforeach()
    if(FUZZ_COMPILE_OPTIONS)
        target_compile_options(${_OBJ_LIB} PRIVATE ${FUZZ_COMPILE_OPTIONS})
    endif()

    file(GENERATE
        OUTPUT  "${_OBJ_LIST}"
        CONTENT "$<JOIN:$<TARGET_OBJECTS:${_OBJ_LIB}>,\n>\n"
    )

    # ── Step 2: Run fuzzmate — incremental via add_custom_command ─────────────
    # The targets list is written at generation time (no genexes needed).
    # Compiler flags are written one-per-line via genex and read by
    # RunFuzzmate.cmake at build time, which passes them as individual
    # arguments to fuzzmate after the '--' separator.
    string(REPLACE ";" "\n" _targets_newline "${_REL_TARGETS}")
    file(GENERATE
        OUTPUT  "${_TARGETS_FILE}"
        CONTENT "${_targets_newline}\n"
    )

    file(GENERATE
        OUTPUT  "${_FLAGS_FILE}"
        CONTENT
"-I$<JOIN:$<TARGET_PROPERTY:${_OBJ_LIB},INCLUDE_DIRECTORIES>,\n-I>
-D$<JOIN:$<TARGET_PROPERTY:${_OBJ_LIB},COMPILE_DEFINITIONS>,\n-D>
$<JOIN:$<TARGET_PROPERTY:${_OBJ_LIB},COMPILE_OPTIONS>,\n>
"
    )

    set(_abs_inv "")
    if(FUZZ_INVARIANT)
        get_filename_component(_abs_inv "${FUZZ_INVARIANT}" ABSOLUTE)
    endif()

    set(_GENERATE_TARGET "${FUZZ_NAME}_generate")

    add_custom_command(
        OUTPUT  "${_FUZZER_C}" "${_REDEF_FILE}" "${_SEED_FILE}"
        COMMAND "${CMAKE_COMMAND}"
            "-DFUZZMATE=${FUZZMATE_EXECUTABLE}"
            "-DTARGETS_FILE=${_TARGETS_FILE}"
            "-DOUT_C=${_FUZZER_C}"
            "-DREDEF=${_REDEF_FILE}"
            "-DSEED=${_SEED_FILE}"
            "-DENTRY=${FUZZ_ENTRY}"
            "-DINVARIANT=${_abs_inv}"
            "-DFLAGS_FILE=${_FLAGS_FILE}"
            "-DWORK_DIR=${CMAKE_SOURCE_DIR}"
            -P "${_FUZZMATE_MODULE_DIR}/RunFuzzmate.cmake"
        DEPENDS ${_ABS_TARGETS} $<TARGET_OBJECTS:${_OBJ_LIB}> "${_FLAGS_FILE}" "${_TARGETS_FILE}"
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "[fuzzmate] Generating harness for ${FUZZ_NAME}"
        VERBATIM
    )
    add_custom_target(${_GENERATE_TARGET}
        DEPENDS "${_FUZZER_C}" "${_REDEF_FILE}" "${_SEED_FILE}"
    )

    set_target_properties(${_GENERATE_TARGET} PROPERTIES
        FUZZMATE_FUZZER_C  "${_FUZZER_C}"
        FUZZMATE_REDEF     "${_REDEF_FILE}"
        FUZZMATE_SEED      "${_SEED_FILE}"
    )

    add_dependencies(${_GENERATE_TARGET} ${_OBJ_LIB})

    foreach(_tgt ${_absorbed_targets})
        if(TARGET "${_tgt}")
            get_target_property(_tgt_type "${_tgt}" TYPE)
            if(NOT "${_tgt_type}" STREQUAL "INTERFACE_LIBRARY")
                get_target_property(_manual_deps "${_tgt}" MANUALLY_ADDED_DEPENDENCIES)
                if(_manual_deps)
                    add_dependencies(${_OBJ_LIB} ${_manual_deps})
                endif()
            endif()
        endif()
    endforeach()

    # ── Step 3: Apply symbol redefinitions — incremental via stamp file ───────
    set(_REDEF_TARGET "${FUZZ_NAME}_redef")

    add_custom_command(
        OUTPUT  "${_REDEF_STAMP}"
        COMMAND "${CMAKE_COMMAND}"
            "-DREDEF_FILE=${_REDEF_FILE}"
            "-DOBJ_LIST_FILE=${_OBJ_LIST}"
            "-DOBJCOPY=${FUZZMATE_OBJCOPY}"
            -P "${_FUZZMATE_MODULE_DIR}/ApplyRedef.cmake"
        COMMAND "${CMAKE_COMMAND}" -E touch "${_REDEF_STAMP}"
        DEPENDS "${_REDEF_FILE}" "${_OBJ_LIST}"
        WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
        COMMENT "[fuzzmate] Applying symbol redefinitions for ${FUZZ_NAME}"
        VERBATIM
    )
    add_custom_target(${_REDEF_TARGET}
        DEPENDS "${_REDEF_STAMP}"
    )

    add_dependencies(${_REDEF_TARGET} ${_OBJ_LIB} ${_GENERATE_TARGET})

    # ── Step 4: Link into the fuzzer executable ───────────────────────────────
    add_executable(${FUZZ_NAME} "${_FUZZER_C}")

    if(FUZZ_HARNESS)
        target_sources(${FUZZ_NAME} PRIVATE "${FUZZ_HARNESS}")
    endif()

    target_compile_options(${FUZZ_NAME} PRIVATE -g "-fsanitize=${FUZZ_SANITIZERS}")
    target_link_options(${FUZZ_NAME}    PRIVATE    "-fsanitize=${FUZZ_SANITIZERS}")

    target_sources(${FUZZ_NAME} PRIVATE $<TARGET_OBJECTS:${_OBJ_LIB}>)

    if(_absorbed_targets)
        target_link_options(${FUZZ_NAME} PRIVATE "LINKER:--allow-multiple-definition")
    endif()

    foreach(_inc  ${_exe_incs})
        target_include_directories(${FUZZ_NAME} PRIVATE "${_inc}")
    endforeach()
    foreach(_def  ${_exe_defs})
        target_compile_definitions(${FUZZ_NAME} PRIVATE "${_def}")
    endforeach()
    foreach(_opt  ${_exe_opts})
        target_compile_options(${FUZZ_NAME} PRIVATE "${_opt}")
    endforeach()
    foreach(_lopt ${_exe_link_opts})
        target_link_options(${FUZZ_NAME} PRIVATE "${_lopt}")
    endforeach()
    foreach(_lib  ${_exe_passthrough})
        target_link_libraries(${FUZZ_NAME} PRIVATE "${_lib}")
    endforeach()

    foreach(_inc ${FUZZ_INCLUDE_DIRECTORIES})
        target_include_directories(${FUZZ_NAME} PRIVATE "${_inc}")
    endforeach()
    foreach(_def ${FUZZ_COMPILE_DEFINITIONS})
        target_compile_definitions(${FUZZ_NAME} PRIVATE "${_def}")
    endforeach()

    add_dependencies(${FUZZ_NAME} ${_REDEF_TARGET})

    # ── Export ────────────────────────────────────────────────────────────────
    set(${FUZZ_NAME}_SEED_FILE       "${_SEED_FILE}"       PARENT_SCOPE)
    set(${FUZZ_NAME}_FUZZER_C        "${_FUZZER_C}"        PARENT_SCOPE)
    set(${FUZZ_NAME}_REDEF_FILE      "${_REDEF_FILE}"      PARENT_SCOPE)
    set(${FUZZ_NAME}_GENERATE_TARGET "${_GENERATE_TARGET}" PARENT_SCOPE)
    set(${FUZZ_NAME}_REDEF_TARGET    "${_REDEF_TARGET}"    PARENT_SCOPE)
endfunction()