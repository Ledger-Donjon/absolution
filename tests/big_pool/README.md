Fix for a large `uint8_t` array with a one-value `.values` domain (`target.c` + `target.c.in`). There is also `counter` so the expected global prefix stays small once the bug is fixed.

Used to catch the case where the sampler still bumped `off` on every array element even though the domain had nothing to choose from.
