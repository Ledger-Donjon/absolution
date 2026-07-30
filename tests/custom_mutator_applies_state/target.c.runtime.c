#include "fuzzer.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

size_t LLVMFuzzerCustomMutator(
    uint8_t *data, size_t size, size_t max_size, unsigned seed) {
  (void)size;
  (void)seed;

  if (max_size < ABSOLUTION_STATE_PREFIX_SIZE)
    return 0;

  memset(data, 0, ABSOLUTION_STATE_PREFIX_SIZE);
  AbsolutionStatePrefix *state = (AbsolutionStatePrefix *)data;
  state->global_0_app_state.field_0_mode_bytes[0] = 0xA5;
  state->global_0_app_state.field_1_counter_bytes[0] = 0x5A;
  return ABSOLUTION_STATE_PREFIX_SIZE;
}

int main(void) {
  uint8_t data[64] = {0};
  size_t size = LLVMFuzzerCustomMutator(data, 0, sizeof(data), 1);
  if (size != ABSOLUTION_STATE_PREFIX_SIZE)
    return 1;

  return LLVMFuzzerTestOneInput(data, size);
}
