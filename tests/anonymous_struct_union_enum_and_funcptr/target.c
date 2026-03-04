#include <string.h>

struct {
  union {
    int a;
  };
  short b;
  char c;
  double d;
  enum {
    ONE,
    TWO,
    THREE,
    FOUR,
  } e[12];
  void (*f)(int, int);
} astruct;

// Apply a memset on the overall struct to impact the padding
// without changing any of the values of the struct
void mutation() { memset(&astruct, 0x42, sizeof(astruct)); }

void AbsolutionTestRegression() { mutation(); }
