// Integration test: function pointers + global int state.
// Each handler takes the int from input_value; invariant constrains both.

typedef int (*handler_fn)(int);

// Global state: value passed to all handlers
int input_value;

// Function pointer table (handlers receive input_value)
handler_fn handlers[4];

int handle_a(int n) { return n + 1; }
int handle_b(int n) { return n * 2; }
int handle_c(int n) { return n - 1; }
int handle_d(int n) { return -1; }

void AbsolutionTestRegression() {
    for (int i = 0; i < 4; i++) {
        if (handlers[i] != 0)
            handlers[i](input_value);
    }
}
