#include <string.h>

typedef struct {
  short b;
  char c;
  struct {
    int sub_a;
    struct {
        char sub_sub_a;
        int sub_sub_b;
    } sub_b;
  } d;
  enum {
    ONE,
    TWO,
    THREE,
    FOUR,
  } e[12];
  void (*f)(int, int);
} mytype [10][20];

mytype anarray;

// Apply a memset on the overall struct to impact the padding
// without changing any of the values of the struct
void mutation() {
  memset(&anarray, 0x42, sizeof(mytype));
}

void AbsolutionTestRegression() { mutation(); }
