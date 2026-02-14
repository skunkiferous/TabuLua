#!/usr/bin/env bash
# ============================================================
# run_bad_input_tests.sh - Bad input test runner for TabuLua
#
# Usage:
#   ./run_bad_input_tests.sh                         Run all tests
#   ./run_bad_input_tests.sh CATEGORY                Run all tests in a category
#   ./run_bad_input_tests.sh CATEGORY TEST           Run a specific test
#   ./run_bad_input_tests.sh --update                Update all expected outputs
#   ./run_bad_input_tests.sh --update CATEGORY       Update expected outputs in a category
#   ./run_bad_input_tests.sh --update CATEGORY TEST  Update a specific expected output
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NORMALIZER="$SCRIPT_DIR/normalize_output.lua"

UPDATE_MODE=0
FILTER_CATEGORY=""
FILTER_TEST=""
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
UPDATE_COUNT=0

# Detect lua binary name
if command -v lua54 &>/dev/null; then
    LUA=lua54
elif command -v lua5.4 &>/dev/null; then
    LUA=lua5.4
elif command -v lua &>/dev/null; then
    LUA=lua
else
    echo "Error: No Lua interpreter found (tried lua54, lua5.4, lua)"
    exit 1
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)
            UPDATE_MODE=1
            shift
            ;;
        *)
            if [[ -z "$FILTER_CATEGORY" ]]; then
                FILTER_CATEGORY="$1"
            elif [[ -z "$FILTER_TEST" ]]; then
                FILTER_TEST="$1"
            fi
            shift
            ;;
    esac
done

echo ""
echo "================================================================"
echo " TabuLua Bad Input Test Runner"
if [[ $UPDATE_MODE -eq 1 ]]; then
    echo " MODE: UPDATE [generating expected outputs]"
fi
echo "================================================================"
echo ""

# compare_output TEST_DIR ACTUAL_FILE
compare_output() {
    local test_dir="$1"
    local actual_file="$2"
    local test_name
    test_name="$(basename "$test_dir")"
    local expected_file="$test_dir/expected_output.txt"

    if [[ $UPDATE_MODE -eq 1 ]]; then
        cp "$actual_file" "$expected_file"
        echo "  UPDATED: $test_name"
        UPDATE_COUNT=$((UPDATE_COUNT + 1))
        return
    fi

    if [[ ! -f "$expected_file" ]]; then
        echo "  SKIP: $test_name [no expected_output.txt - use --update to generate]"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi

    if diff -q "$actual_file" "$expected_file" &>/dev/null; then
        echo "  PASS: $test_name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $test_name"
        echo ""
        echo "  --- Expected ---"
        cat "$expected_file"
        echo ""
        echo "  --- Actual ---"
        cat "$actual_file"
        echo ""
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# run_cli_test TEST_DIR
run_cli_test() {
    local test_dir="$1"
    local cli_args
    cli_args="$(cat "$test_dir/args.txt")"

    local temp_raw temp_norm
    temp_raw="$(mktemp)"
    temp_norm="$(mktemp)"

    # Run reformatter from project root with the specified args
    # shellcheck disable=SC2086
    (cd "$PROJECT_DIR" && $LUA reformatter.lua $cli_args > "$temp_raw" 2>&1) || true

    # Normalize output
    $LUA "$NORMALIZER" "$temp_raw" "$temp_norm"

    compare_output "$test_dir" "$temp_norm"

    rm -f "$temp_raw" "$temp_norm"
}

# run_data_test TEST_DIR
run_data_test() {
    local test_dir="$1"

    local temp_pkg
    temp_pkg="$(mktemp -d)"

    # Copy all files (including subdirectories like libs/)
    cp -r "$test_dir"/* "$temp_pkg/" 2>/dev/null || true
    # Remove files that should not be in the package copy
    rm -f "$temp_pkg/expected_output.txt" "$temp_pkg/args.txt"

    local temp_raw temp_norm
    temp_raw="$(mktemp)"
    temp_norm="$(mktemp)"

    # Run reformatter on the temp copy
    (cd "$PROJECT_DIR" && $LUA reformatter.lua --log-level=warn "$temp_pkg" > "$temp_raw" 2>&1) || true

    # Normalize output (replace temp dir path with {DIR})
    $LUA "$NORMALIZER" --temp-dir="$temp_pkg" "$temp_raw" "$temp_norm"

    compare_output "$test_dir" "$temp_norm"

    rm -f "$temp_raw" "$temp_norm"
    rm -rf "$temp_pkg"
}

# process_test TEST_DIR
process_test() {
    local test_dir="$1"
    local test_name
    test_name="$(basename "$test_dir")"

    # Skip if test filter set and doesn't match
    if [[ -n "$FILTER_TEST" && "$test_name" != "$FILTER_TEST" ]]; then
        return
    fi

    # Determine test type: CLI test (args.txt, no Manifest) or data test
    if [[ -f "$test_dir/Manifest.transposed.tsv" || -f "$test_dir/Files.tsv" ]]; then
        run_data_test "$test_dir"
    elif [[ -f "$test_dir/args.txt" ]]; then
        run_cli_test "$test_dir"
    else
        echo "  SKIP: $test_name [no test files found]"
        SKIP_COUNT=$((SKIP_COUNT + 1))
    fi
}

# process_category CAT_DIR
process_category() {
    local cat_dir="$1"
    local cat_name
    cat_name="$(basename "$cat_dir")"

    # Skip if category filter set and doesn't match
    if [[ -n "$FILTER_CATEGORY" && "$cat_name" != "$FILTER_CATEGORY" ]]; then
        return
    fi

    echo "--- $cat_name ---"

    for test_dir in "$cat_dir"/*/; do
        # Skip if not a directory
        [[ -d "$test_dir" ]] || continue
        # Remove trailing slash
        test_dir="${test_dir%/}"
        process_test "$test_dir"
    done
}

# Main loop: iterate over category directories
for cat_dir in "$SCRIPT_DIR"/*/; do
    [[ -d "$cat_dir" ]] || continue
    cat_dir="${cat_dir%/}"
    process_category "$cat_dir"
done

echo ""
echo "================================================================"
if [[ $UPDATE_MODE -eq 1 ]]; then
    echo " Results: $UPDATE_COUNT updated, $SKIP_COUNT skipped"
else
    echo " Results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
fi
echo "================================================================"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
