# Test: function_params

## Purpose
Regression test for spurious function parameter detection.

## Category
regression

## Issue
When parsing C files containing functions with parameters, aro incorrectly emits
`.variable` AST nodes for function parameters (e.g., `size_t size` from a function
signature). Fuzzmate was picking these up as global variables to fuzz, causing
invalid generated code.

## Symptom
Generated `fuzzer.c` contained code like:

```c
extern uint8_t size[4];  // spurious - `size` is a function parameter, not a global
memset(size, 0, sizeof(size));  // compiler error: incompatible integer to pointer
```

Compiler error:
```
fuzzer.c:23:12: error: incompatible integer to pointer conversion passing 'size_t' to parameter of type 'void *'
```

## Root Cause
Aro parser artifact: function parameters appeared in `root_decls` as `.variable`
nodes with:
- `storage_class = .auto`
- `initializer = null`
- `definition = null`  
- `type = .int` (primitive integer type)

Legitimate file-scope variables (like `mytype astruct;`) have `type = .typedef`
or other user-defined types, allowing us to distinguish them.

## Fix
`src/Parser.zig` - In `collect_globals`, filter variables that have ALL of:
- `storage_class == .auto` (invalid at file scope in C)
- `initializer == null`
- `definition == null`
- `type == .int` (primitive integer, not user-defined type)

## Test Validation
- `funcparams.c` declares functions with various parameter types
- `real_global` is a legitimate static variable that SHOULD be detected
- Function parameters (`size`, `length`, `count`, `data`, `buffer`) should NOT appear
- Golden file expects only `real_global` in the output

## Related Files
- `src/Parser.zig` - The fix location (collect_globals function, ~line 198)
- `tests/manual/conflict/absolution.c` - Original file that triggered this bug
- `tests/basic/basic.c` - Tests legitimate typedef variables still work

## Notes
The fix relies on the observation that aro marks spurious parameter artifacts with
primitive integer types (`.int`), while legitimate file-scope variables typically
have user-defined types (`.typedef`, `.@"struct"`, etc.). This heuristic may need
refinement if edge cases are discovered.
