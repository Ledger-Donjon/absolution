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
#   LINK_LIBRARIES        — extra libraries to link into the fuzzer.
#                           CMake target properties (PUBLIC/INTERFACE include dirs,
#                           compile definitions, compile options) are automatically
#                           propagated to the OBJECT library compilation.  The same
#                           properties are forwarded to the fuzzmate CLI via
#                           generator expressions.
#   SANITIZERS            — sanitizer list (default: fuzzer,address).
#
# Created targets:
#   ${NAME}_objs      — OBJECT library containing compiled target sources.
#   ${NAME}_generate  — Custom target that runs fuzzmate CLI to produce artifacts.
#   ${NAME}_redef     — Custom target that applies objcopy symbol redefinitions.
#   ${NAME}           — Final fuzzer executable.
#
# Target properties on ${NAME}_generate:
#   FUZZMATE_FUZZER_C  — Path to the generated fuzzer.c file.
#   FUZZMATE_REDEF     — Path to the generated .redef file.
#   FUZZMATE_SEED      — Path to the generated .seed file.
#
# Exported variables (PARENT_SCOPE):
#   ${NAME}_SEED_FILE      — Path to the generated seed file.
#   ${NAME}_FUZZER_C       — Path to the generated fuzzer.c file.
#   ${NAME}_REDEF_FILE     — Path to the generated .redef file.
#   ${NAME}_GENERATE_TARGET — Name of the generate target.
#   ${NAME}_REDEF_TARGET   — Name of the redef target.

function(fuzzmate_add_fuzzer)
    cmake_parse_arguments(
        FUZZ                                    # prefix
        ""                                      # boolean options
        "NAME;HARNESS;INVARIANT;ENTRY;SANITIZERS" # single-value keywords
        "TARGETS;COMPILE_OPTIONS;INCLUDE_DIRECTORIES;COMPILE_DEFINITIONS;LINK_LIBRARIES" # multi-value
        ${ARGN}
    )

    # ── Validate ────────────────────────────────────────────────────────
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

    # ── Working directories ─────────────────────────────────────────────
    set(_FUZZ_DIR "${CMAKE_CURRENT_BINARY_DIR}/_fuzzmate/${FUZZ_NAME}")
    file(MAKE_DIRECTORY "${_FUZZ_DIR}")

    set(_FUZZER_C    "${_FUZZ_DIR}/fuzzer.c")
    set(_REDEF_FILE  "${_FUZZ_DIR}/fuzzer.redef")
    set(_SEED_FILE   "${_FUZZ_DIR}/fuzzer.seed")
    set(_OBJ_LIST    "${_FUZZ_DIR}/objfiles.txt")

    # ── Resolve target paths ────────────────────────────────────────────
    # Source-relative paths are passed to fuzzmate and written into the
    # redef file.  Absolute paths are used for the OBJECT library sources.
    set(_REL_TARGETS "")
    set(_ABS_TARGETS "")
    foreach(_t ${FUZZ_TARGETS})
        get_filename_component(_abs "${_t}" ABSOLUTE)
        file(RELATIVE_PATH _rel "${CMAKE_SOURCE_DIR}" "${_abs}")
        list(APPEND _REL_TARGETS "${_rel}")
        list(APPEND _ABS_TARGETS "${_abs}")
    endforeach()

    # ── Step 1: OBJECT library (compile targets) ─────────────────────────
    # CMake handles compilation natively — include dirs, definitions, and
    # compile options propagate automatically via target_link_libraries().
    # No manual clang invocation or generator-expression gymnastics needed.
    set(_OBJ_LIB "${FUZZ_NAME}_objs")

    add_library(${_OBJ_LIB} OBJECT ${_ABS_TARGETS})
    target_compile_options(${_OBJ_LIB} PRIVATE -g)

    # Propagate transitive properties from linked libraries.
    if(FUZZ_LINK_LIBRARIES)
        target_link_libraries(${_OBJ_LIB} PRIVATE ${FUZZ_LINK_LIBRARIES})
    endif()

    # Add explicit keyword arguments.
    foreach(_inc ${FUZZ_INCLUDE_DIRECTORIES})
        target_include_directories(${_OBJ_LIB} PRIVATE "${_inc}")
    endforeach()
    foreach(_def ${FUZZ_COMPILE_DEFINITIONS})
        target_compile_definitions(${_OBJ_LIB} PRIVATE "${_def}")
    endforeach()
    if(FUZZ_COMPILE_OPTIONS)
        target_compile_options(${_OBJ_LIB} PRIVATE ${FUZZ_COMPILE_OPTIONS})
    endif()

    # Write the object file list at generation time so that ApplyRedef.cmake
    # can locate objects by suffix-matching at build time.
    file(GENERATE
        OUTPUT "${_OBJ_LIST}"
        CONTENT "$<JOIN:$<TARGET_OBJECTS:${_OBJ_LIB}>,\n>\n"
    )

    # ── Step 2: Run fuzzmate (named custom target) ────────────────────────
    # C compiler flags (-I, -D, -f*, etc.) are passed after '--' separator.
    # We query the OBJECT library's full property closure via generator expressions.
    set(_FM_GENEX_INCS
        "$<$<BOOL:$<TARGET_PROPERTY:${_OBJ_LIB},INCLUDE_DIRECTORIES>>:-I$<SEMICOLON>$<JOIN:$<TARGET_PROPERTY:${_OBJ_LIB},INCLUDE_DIRECTORIES>,$<SEMICOLON>-I$<SEMICOLON>>>")
    set(_FM_GENEX_DEFS
        "$<$<BOOL:$<TARGET_PROPERTY:${_OBJ_LIB},COMPILE_DEFINITIONS>>:-D$<SEMICOLON>$<JOIN:$<TARGET_PROPERTY:${_OBJ_LIB},COMPILE_DEFINITIONS>,$<SEMICOLON>-D$<SEMICOLON>>>")
    # COMPILE_OPTIONS are passed as-is (e.g. -fshort-enums, -std=c99)
    set(_FM_GENEX_OPTS
        "$<$<BOOL:$<TARGET_PROPERTY:${_OBJ_LIB},COMPILE_OPTIONS>>:$<JOIN:$<TARGET_PROPERTY:${_OBJ_LIB},COMPILE_OPTIONS>,$<SEMICOLON>>>")

    set(_FM_CMD "${FUZZMATE_EXECUTABLE}")
    foreach(_t ${_REL_TARGETS})
        list(APPEND _FM_CMD -t "${_t}")
    endforeach()
    list(APPEND _FM_CMD
        -o "${_FUZZER_C}"
        --redef "${_REDEF_FILE}"
        --seed "${_SEED_FILE}"
        --entry "${FUZZ_ENTRY}"
    )
    if(FUZZ_INVARIANT)
        get_filename_component(_abs_inv "${FUZZ_INVARIANT}" ABSOLUTE)
        list(APPEND _FM_CMD -i "${_abs_inv}")
    endif()

    # Named custom target for the fuzzmate generation step.
    # BYPRODUCTS tells the build system about the files we produce.
    # C flags are passed after '--' separator.
    set(_GENERATE_TARGET "${FUZZ_NAME}_generate")
    add_custom_target(${_GENERATE_TARGET}
        COMMAND ${_FM_CMD} -- ${_FM_GENEX_INCS} ${_FM_GENEX_DEFS} ${_FM_GENEX_OPTS}
        BYPRODUCTS "${_FUZZER_C}" "${_REDEF_FILE}" "${_SEED_FILE}"
        COMMAND_EXPAND_LISTS
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        DEPENDS ${_ABS_TARGETS}
        COMMENT "[fuzzmate] Generating harness for ${FUZZ_NAME}"
        VERBATIM
    )

    # Set target properties for artifact discovery.
    set_target_properties(${_GENERATE_TARGET} PROPERTIES
        FUZZMATE_FUZZER_C  "${_FUZZER_C}"
        FUZZMATE_REDEF     "${_REDEF_FILE}"
        FUZZMATE_SEED      "${_SEED_FILE}"
    )

    # ── Step 3: Apply symbol redefinitions (objcopy) ─────────────────────
    # Mutates the OBJECT library's .o files in place.  The dependency chain
    # (obj lib + fuzzmate → redef → link) ensures objcopy finishes before
    # linking and only runs after both the objects and the redef file exist.
    set(_REDEF_TARGET "${FUZZ_NAME}_redef")
    add_custom_target(${_REDEF_TARGET}
        COMMAND "${CMAKE_COMMAND}"
            "-DREDEF_FILE=${_REDEF_FILE}"
            "-DOBJ_LIST_FILE=${_OBJ_LIST}"
            "-DOBJCOPY=${FUZZMATE_OBJCOPY}"
            -P "${_FUZZMATE_MODULE_DIR}/ApplyRedef.cmake"
        WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
        COMMENT "[fuzzmate] Applying symbol redefinitions for ${FUZZ_NAME}"
        VERBATIM
    )

    # Ensure: (objects compiled + fuzzmate done) → objcopy runs → link
    add_dependencies(${_REDEF_TARGET} ${_OBJ_LIB} ${_GENERATE_TARGET})

    # ── Step 4: Link into the fuzzer executable ──────────────────────────
    add_executable(${FUZZ_NAME} "${_FUZZER_C}")

    if(FUZZ_HARNESS)
        target_sources(${FUZZ_NAME} PRIVATE "${FUZZ_HARNESS}")
    endif()

    target_compile_options(${FUZZ_NAME} PRIVATE -g "-fsanitize=${FUZZ_SANITIZERS}")
    target_link_options(${FUZZ_NAME}    PRIVATE    "-fsanitize=${FUZZ_SANITIZERS}")

    # Link the (objcopy-mutated) object files from the OBJECT library.
    target_sources(${FUZZ_NAME} PRIVATE $<TARGET_OBJECTS:${_OBJ_LIB}>)

    # Link additional libraries (for the linker, not compilation).
    if(FUZZ_LINK_LIBRARIES)
        target_link_libraries(${FUZZ_NAME} PRIVATE ${FUZZ_LINK_LIBRARIES})
    endif()

    # Include dirs for the fuzzer.c / harness compilation.
    foreach(_inc ${FUZZ_INCLUDE_DIRECTORIES})
        target_include_directories(${FUZZ_NAME} PRIVATE "${_inc}")
    endforeach()
    foreach(_def ${FUZZ_COMPILE_DEFINITIONS})
        target_compile_definitions(${FUZZ_NAME} PRIVATE "${_def}")
    endforeach()

    add_dependencies(${FUZZ_NAME} ${_REDEF_TARGET})

    # ── Export useful variables to the caller ───────────────────────────
    set(${FUZZ_NAME}_SEED_FILE       "${_SEED_FILE}"       PARENT_SCOPE)
    set(${FUZZ_NAME}_FUZZER_C        "${_FUZZER_C}"        PARENT_SCOPE)
    set(${FUZZ_NAME}_REDEF_FILE      "${_REDEF_FILE}"      PARENT_SCOPE)
    set(${FUZZ_NAME}_GENERATE_TARGET "${_GENERATE_TARGET}" PARENT_SCOPE)
    set(${FUZZ_NAME}_REDEF_TARGET    "${_REDEF_TARGET}"    PARENT_SCOPE)
endfunction()
