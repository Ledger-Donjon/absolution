# FuzzmateConfig.cmake — find_package(Fuzzmate) support.
#
# After a successful find_package(Fuzzmate), the following variables are set:
#
#   FUZZMATE_EXECUTABLE  — path to the fuzzmate binary
#   FUZZMATE_OBJCOPY     — path to objcopy / llvm-objcopy
#   Fuzzmate_FOUND       — TRUE
#
# And the function fuzzmate_add_fuzzer() is available (see FuzzmateFuzzer.cmake).

find_program(FUZZMATE_EXECUTABLE fuzzmate
    HINTS "${CMAKE_CURRENT_LIST_DIR}/../../../bin"
)
if(NOT FUZZMATE_EXECUTABLE)
    message(FATAL_ERROR "Could not find the fuzzmate binary.  "
        "Make sure fuzzmate is installed and on your PATH, or set "
        "FUZZMATE_EXECUTABLE explicitly.")
endif()

# Prefer llvm-objcopy when available — better LLVM bitcode compatibility.
find_program(FUZZMATE_OBJCOPY
    NAMES llvm-objcopy objcopy
)
if(NOT FUZZMATE_OBJCOPY)
    message(FATAL_ERROR "Could not find objcopy or llvm-objcopy.  "
        "Install binutils or llvm and make sure objcopy is on your PATH.")
endif()

set(_FUZZMATE_MODULE_DIR "${CMAKE_CURRENT_LIST_DIR}")

include("${CMAKE_CURRENT_LIST_DIR}/FuzzmateFuzzer.cmake")

set(Fuzzmate_FOUND TRUE)