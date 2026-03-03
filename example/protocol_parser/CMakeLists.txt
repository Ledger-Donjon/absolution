cmake_minimum_required(VERSION 3.20)
project(protocol_parser C)

# ── Normal library + application build ──────────────────────────────

add_library(protocol STATIC
    src/decoder.c
    src/session.c
)
target_include_directories(protocol PUBLIC include)
target_compile_definitions(protocol PUBLIC PROTO_MAX_VERSIONS=8)

add_executable(parser src/main.c)
target_link_libraries(parser PRIVATE protocol)

# ── Fuzzing targets ─────────────────────────────────────────────────
#
# Enable with:
#   cmake -B build -G Ninja \
#       -DENABLE_FUZZING=ON \
#       -DCMAKE_C_COMPILER=clang \
#       -DAbsolution_DIR=<prefix>/lib/cmake/Absolution
#
#   cmake --build build --target fuzz_decode
#
# Run:
#   ./build/fuzz_decode corpus/ -seed=1

option(ENABLE_FUZZING "Build fuzz targets" OFF)

if(ENABLE_FUZZING)
    find_package(Absolution REQUIRED)

    # The TARGETS are the .c files whose globals we want absolution to sample.
    # The HARNESS is our test function that exercises the code under those globals.
    # ENTRY names the function in the harness (must match the C definition).
    #
    # LINK_LIBRARIES automatically propagates include dirs and compile
    # definitions from the protocol target (declared PUBLIC above), so we
    # don't need to duplicate INCLUDE_DIRECTORIES or COMPILE_DEFINITIONS.
    absolution_add_fuzzer(
        NAME fuzz_decode
        TARGETS
            src/decoder.c
            src/session.c
        HARNESS
            fuzz/fuzz_decode.c
        ENTRY
            FuzzDecode
        LINK_LIBRARIES
            protocol
    )
endif()
