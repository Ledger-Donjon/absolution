#!/bin/bash
# Generate golden files (.zon) for a test directory
#
# Usage: ./scripts/gen-golden.sh <test_directory>
#
# Example:
#   ./scripts/gen-golden.sh tests/basic
#   ./scripts/gen-golden.sh tests/aroccbug
#
# This script finds all .c files in the given test directory and generates
# corresponding .zon golden files by running fuzzmate.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <test_directory>"
    echo "Example: $0 tests/basic"
    exit 1
fi

TEST_DIR="$1"

if [ ! -d "$TEST_DIR" ]; then
    echo "Error: Directory '$TEST_DIR' does not exist"
    exit 1
fi

# Find the fuzzmate binary
FUZZMATE="./zig-out/bin/fuzzmate"
if [ ! -x "$FUZZMATE" ]; then
    echo "Error: fuzzmate binary not found at $FUZZMATE"
    echo "Please run 'zig build' first"
    exit 1
fi

# Find all .c files in the test directory (non-recursive)
C_FILES=$(find "$TEST_DIR" -maxdepth 1 -name "*.c" -type f)

if [ -z "$C_FILES" ]; then
    echo "Error: No .c files found in '$TEST_DIR'"
    exit 1
fi

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

for C_FILE in $C_FILES; do
    BASENAME=$(basename "$C_FILE")
    ZON_FILE="${TEST_DIR}/${BASENAME}.zon"
    FLAGS_FILE="${TEST_DIR}/${BASENAME}.flags"
    
    echo "Generating golden file for: $C_FILE"
    
    # Collect extra flags from .flags sidecar (matches integration.py behavior)
    EXTRA_ARGS=()
    if [ -f "$FLAGS_FILE" ]; then
        while IFS= read -r line; do
            line=${line%%#*}  # strip comments
            line=$(echo "$line" | xargs)
            [ -n "$line" ] || continue
            EXTRA_ARGS+=("$line")
        done < "$FLAGS_FILE"
    fi
    
    # Run fuzzmate to generate the .zon file
    if [ ${#EXTRA_ARGS[@]} -gt 0 ]; then
        "$FUZZMATE" \
            --targets "$C_FILE" \
            --zon "$TMPDIR/${BASENAME}.zon" \
            --out "$TMPDIR/${BASENAME}.fuzzer.c" \
            --redef "$TMPDIR/${BASENAME}.redef.txt" \
            -- "${EXTRA_ARGS[@]}"
    else
        "$FUZZMATE" \
            --targets "$C_FILE" \
            --zon "$TMPDIR/${BASENAME}.zon" \
            --out "$TMPDIR/${BASENAME}.fuzzer.c" \
            --redef "$TMPDIR/${BASENAME}.redef.txt"
    fi
    
    # Copy the generated .zon to the test directory
    cp "$TMPDIR/${BASENAME}.zon" "$ZON_FILE"
    
    echo "  -> Created: $ZON_FILE"
done

echo "Done!"
