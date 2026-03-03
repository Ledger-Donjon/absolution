# AbsolutionConfig.cmake — find_package(Absolution) support.
#
# After a successful find_package(Absolution), the following variables are set:
#
#   ABSOLUTION_EXECUTABLE  — path to the absolution binary
#   ABSOLUTION_OBJCOPY     — path to objcopy / llvm-objcopy
#   Absolution_FOUND       — TRUE
#
# And the function absolution_add_fuzzer() is available (see AbsolutionFuzzer.cmake).

find_program(ABSOLUTION_EXECUTABLE absolution
    HINTS "${CMAKE_CURRENT_LIST_DIR}/../../../bin"
)
if(NOT ABSOLUTION_EXECUTABLE)
    message(FATAL_ERROR "Could not find the absolution binary.  "
        "Make sure absolution is installed and on your PATH, or set "
        "ABSOLUTION_EXECUTABLE explicitly.")
endif()

# Prefer llvm-objcopy when available — better LLVM bitcode compatibility.
find_program(ABSOLUTION_OBJCOPY
    NAMES llvm-objcopy objcopy
)
if(NOT ABSOLUTION_OBJCOPY)
    message(FATAL_ERROR "Could not find objcopy or llvm-objcopy.  "
        "Install binutils or llvm and make sure objcopy is on your PATH.")
endif()

set(_ABSOLUTION_MODULE_DIR "${CMAKE_CURRENT_LIST_DIR}")

include("${CMAKE_CURRENT_LIST_DIR}/AbsolutionFuzzer.cmake")

set(Absolution_FOUND TRUE)