
typedef struct {
  int a;
  short b;
  char c;
} sometype [10];

typedef struct {
  union {
    sometype a;
    sometype b[3];
    sometype* c;
  };
} mytype;


mytype astruct;

#include <string.h>
// Apply a memset on the overall struct to impact the padding
// without changing any of the values of the struct
void mutation() {
  memset(&astruct, 0x42, sizeof(astruct));
}

void AbsolutionTestRegression() { mutation(); }
