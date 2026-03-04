#include <string.h>

typedef struct {
  int a;
  short b;
  char c;
} mytype[10];

mytype anarray[10];

// Apply a memset on the overall struct to impact the padding
// without changing any of the values of the struct
void mutation() {
  memset(&anarray, 0x42, sizeof(anarray));
}

void AbsolutionTestRegression() { mutation(); }
