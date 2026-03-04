

typedef struct {
  short some;
  char data;
} state;

typedef short (*functionptr)(int, state *);

typedef struct {
  short step;
  functionptr methods[12];
} mytype;

mytype astruct;

// run all steps present in astruct until one of the method
// returns -1;
void execution() {
  state state = {0};

  while (astruct.step != -1) {
    astruct.step = astruct.methods[astruct.step](astruct.step, &state);
  }
}

short method1(int step, state *s) {
  if (step >= 10)
    return -1;
  return step++;
}

short method2(int step, state *s) {
  s->some = 0x42;
  s->data = s->data + 1;
  return step++;
}

short method3(int step, state *s) { return step--; }

short method4(int step, state *s) { return -1; }

void AbsolutionTestRegression() { execution(); }
