#include <string.h>

typedef struct {
  int a;
  short b;
  char c;
} mytype [10][20];

mytype anarray;

// Apply a memset on the overall struct to impact the padding
// without changing any of the values of the struct
void mutation() {
  memset(&anarray, 0x42, sizeof(mytype));
}

void AbsolutionTestRegression() { mutation(); }
