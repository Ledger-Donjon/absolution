#include <stdint.h>
#include <stddef.h>

// Function with parameters that should NOT be picked up as global variables.
// This is a regression test for a bug where aro incorrectly emits .variable
// nodes for function parameters, causing fuzzmate to try fuzzing them.
int TestFunctionWithParams(const uint8_t *data, size_t size) {
    return 0;
}

// Another function with various parameter types
void AnotherFunction(int count, char *buffer, size_t length) {
    // empty
}

// A real global variable that SHOULD be fuzzed
static int real_global = 42;

// Entry point for the fuzzer
void AbsolutionTestRegression() {
    TestFunctionWithParams(0, 0);
}
