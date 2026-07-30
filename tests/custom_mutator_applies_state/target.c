#include <stddef.h>
#include <stdint.h>

struct {
  uint8_t mode;
  uint8_t counter;
} app_state;

int AbsolutionTestOneInput(const uint8_t *data, size_t size) {
  (void)data;
  (void)size;

  if (app_state.mode != 0xA5 || app_state.counter != 0x5A)
    __builtin_trap();

  return 0;
}
