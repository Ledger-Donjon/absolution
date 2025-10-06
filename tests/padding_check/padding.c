#include <string.h>

typedef struct {
  int a;
  short b;
  char c;
} mytype;

mytype astruct;

// Apply a memset on the overall struct to impact the padding
// without changing any of the values of the struct
void mutation() {
  mytype buffer = astruct;
  memset(&astruct, 0x42, sizeof(mytype));
  astruct.a = buffer.a;
  astruct.b = buffer.b;
  astruct.c = buffer.c;
}

void AbsolutionTestRegression() { mutation(); }
