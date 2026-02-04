#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Find Zig (reused from integration.sh logic simplified)
ZIG=$(which zig) || true
if [ -z "$ZIG" ]; then
    # try default path
    ZIG="$HOME/.cursor-server/data/User/globalStorage/ziglang.vscode-zig/zig/x86_64-linux-0.15.2/zig"
fi

echo "Using Zig: $ZIG"

# Build fuzzmate
cd "$PROJECT_ROOT"
"$ZIG" build

FUZZMATE="$PROJECT_ROOT/zig-out/bin/fuzzmate"
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

echo "========================================"
echo "Test 1: Conflicting Static Variables"
echo "========================================"

# Run fuzzmate on file1.c
"$FUZZMATE" --targets "tests/manual/conflict/file1.c" --redef "$TMP_DIR/file1.redef" --out "$TMP_DIR/file1_fuzzer.c"
echo "file1.redef:"
cat "$TMP_DIR/file1.redef"

# Run fuzzmate on file2.c
"$FUZZMATE" --targets "tests/manual/conflict/file2.c" --redef "$TMP_DIR/file2.redef" --out "$TMP_DIR/file2_fuzzer.c"
echo "file2.redef:"
cat "$TMP_DIR/file2.redef"

# Verify that both redef files contain 'var' but mangled differently (by path)
MANGLED1=$(awk '{print $3}' "$TMP_DIR/file1.redef")
MANGLED2=$(awk '{print $3}' "$TMP_DIR/file2.redef")

if [ "$MANGLED1" == "$MANGLED2" ]; then
    echo "FAIL: Mangled names are identical: $MANGLED1"
    exit 1
fi

echo "PASS: Mangled names differ ($MANGLED1 vs $MANGLED2)"

echo "========================================"
echo "Test 2: Mixed Static and Global"
echo "========================================"

"$FUZZMATE" --targets "tests/manual/mixed/mixed.c" --redef "$TMP_DIR/mixed.redef" --out "$TMP_DIR/mixed_fuzzer.c"
echo "mixed.redef:"
cat "$TMP_DIR/mixed.redef"

# Verify that 's_var' is in redef, but 'g_var' is NOT.
if grep -q "s_var" "$TMP_DIR/mixed.redef"; then
    echo "PASS: s_var is in redef file"
else
    echo "FAIL: s_var is MISSING from redef file"
    exit 1
fi

if grep -q "g_var" "$TMP_DIR/mixed.redef"; then
    echo "FAIL: g_var SHOULD NOT be in redef file"
    exit 1
else
    echo "PASS: g_var is correctly absent from redef file"
fi

echo "========================================"
echo "Test 3: Multi-file Support"
echo "========================================"

# Run fuzzmate on BOTH file1.c and file2.c at once
"$FUZZMATE" --targets "tests/manual/conflict/file1.c" --targets "tests/manual/conflict/file2.c" --redef "$TMP_DIR/multi.redef" --out "$TMP_DIR/multi_fuzzer.c"
echo "multi.redef:"
cat "$TMP_DIR/multi.redef"

# Verify that BOTH mangled names appear in the single redef file
if grep -q "$MANGLED1" "$TMP_DIR/multi.redef" && grep -q "$MANGLED2" "$TMP_DIR/multi.redef"; then
    echo "PASS: Both mangled names found in multi-file redef"
else
    echo "FAIL: Missing mangled names in multi-file redef"
    exit 1
fi

# Verify generated C file has externs for both
if grep -q "extern uint8_t $MANGLED1" "$TMP_DIR/multi_fuzzer.c" && grep -q "extern uint8_t $MANGLED2" "$TMP_DIR/multi_fuzzer.c"; then
    echo "PASS: Generated C file contains externs for both variables"
else
    echo "FAIL: Generated C file missing externs"
    exit 1
fi

echo "========================================"
echo "All verification tests passed!"
echo "========================================"
