#!/usr/bin/env bash
# ============================================================
# pre_commit_check.sh - Pre-commit quality gate for TabuLua
#
# Runs all verification steps before committing:
#   1. Unit tests (busted specs)
#   2. Tutorial export checks (reformatter on tutorial packages)
#   3. Bad input tests (error detection regression tests)
#
# Usage:
#   ./pre_commit_check.sh          Run all checks
#   ./pre_commit_check.sh --quick  Skip export checks (faster)
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP=0
FAILURES=0
QUICK_MODE=0

# Parse arguments
for a in "$@"; do
    if [[ "$a" == "--quick" ]]; then
        QUICK_MODE=1
    fi
done

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

echo ""
echo "================================================================"
echo " TabuLua Pre-Commit Check"
echo "================================================================"
echo ""

# -----------------------------------------------------------
# Step 1: Unit tests
# -----------------------------------------------------------
STEP=$((STEP + 1))
echo "[$STEP] Running unit tests..."

bash "$SCRIPT_DIR/run_tests.sh"
UNIT_EXIT=$?

if [[ $UNIT_EXIT -ne 0 ]]; then
    echo ""
    echo "[$STEP] FAILED — Unit tests have failures"
    FAILURES=$((FAILURES + 1))
else
    echo "[$STEP] PASSED — All unit tests passed"
fi
echo ""

# -----------------------------------------------------------
# Step 2: Tutorial export checks
# -----------------------------------------------------------
if [[ $QUICK_MODE -eq 1 ]]; then
    echo "[*] Skipping export checks (--quick mode)"
    echo ""
else
    TUTORIAL_DIRS="tutorial/core/ tutorial/expansion/"

    # Export check helper: runs reformatter with given args,
    # checks for ERROR/FATAL lines in output
    run_export_check() {
        local label="$1"
        shift
        STEP=$((STEP + 1))
        echo "[$STEP] Export check: $label..."

        local temp_out
        temp_out="$(mktemp)"

        # Run reformatter from project directory
        (cd "$SCRIPT_DIR" && $LUA reformatter.lua "$@" > "$temp_out" 2>&1) || true

        # Check for ERROR or FATAL level messages in output
        # Log format: timestamp\tLEVEL\t[module]\tmessage
        if grep -qP '\tERROR\t|\tFATAL\t' "$temp_out" 2>/dev/null || \
           grep -qE $'\tERROR\t|'$'\tFATAL\t' "$temp_out" 2>/dev/null; then
            echo "[$STEP] FAILED — Errors in: $label"
            echo "  Error output:"
            grep -E 'ERROR|FATAL' "$temp_out" | while IFS= read -r line; do
                echo "    $line"
            done
            FAILURES=$((FAILURES + 1))
        else
            echo "[$STEP] PASSED — $label"
        fi

        rm -f "$temp_out"
    }

    # shellcheck disable=SC2086
    run_export_check "JSON export" --log-level=error --file=json $TUTORIAL_DIRS
    echo ""

    # shellcheck disable=SC2086
    run_export_check "SQL + MPK export" --log-level=error --file=sql --data=mpk $TUTORIAL_DIRS
    echo ""

    # shellcheck disable=SC2086
    run_export_check "Lua export" --log-level=error --file=lua $TUTORIAL_DIRS
    echo ""

    # shellcheck disable=SC2086
    run_export_check "TSV reformat only" --log-level=error $TUTORIAL_DIRS
    echo ""
fi

# -----------------------------------------------------------
# Step 3: Bad input tests
# -----------------------------------------------------------
STEP=$((STEP + 1))
echo "[$STEP] Running bad input tests..."

bash "$SCRIPT_DIR/bad_input/run_bad_input_tests.sh"
BAD_INPUT_EXIT=$?

if [[ $BAD_INPUT_EXIT -ne 0 ]]; then
    echo ""
    echo "[$STEP] FAILED — Bad input tests have failures"
    FAILURES=$((FAILURES + 1))
else
    echo "[$STEP] PASSED — All bad input tests passed"
fi
echo ""

# -----------------------------------------------------------
# Summary
# -----------------------------------------------------------
echo "================================================================"
if [[ $FAILURES -eq 0 ]]; then
    echo " All checks passed — ready to commit!"
else
    echo " $FAILURES check(s) FAILED — please fix before committing"
fi
echo "================================================================"
echo ""

if [[ $FAILURES -gt 0 ]]; then
    exit 1
fi
exit 0
