#!/bin/bash
# run_tests.sh - Bash version of the test runner

clear

# Detect if we're running on Windows (Git Bash, MSYS, etc.)
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || -n "$WINDIR" ]]; then
    # On Windows, use busted.bat
    BUSTED_CMD="busted.bat"
else
    # On Linux/Mac, use busted
    BUSTED_CMD="busted"
fi

# Run tests and capture output to test_results.txt
echo "Running tests..."
if [ -z "$1" ]; then
    # No argument provided - run all tests
    $BUSTED_CMD -v --output=TAP --lpath=?.lua --lpath=?/init.lua -p spec --coverage > test_results.txt 2>&1
else
    # Check if file exists
    if [ ! -f "$1" ]; then
        echo "Error: Test file not found: $1"
        exit 1
    fi
    # Argument provided - run specific test
    $BUSTED_CMD -v --output=TAP --lpath=?.lua --lpath=?/init.lua "$1" --coverage > test_results.txt 2>&1
fi

# Extract errors using Lua script
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || -n "$WINDIR" ]]; then
    # On Windows, try lua.exe or lua54.exe
    if command -v lua54.exe &> /dev/null; then
        lua54.exe extract_test_errors.lua test_results.txt test_errors.txt
    elif command -v lua.exe &> /dev/null; then
        lua.exe extract_test_errors.lua test_results.txt test_errors.txt
    else
        echo "Warning: lua not found, skipping error extraction"
        EXTRACT_EXIT_CODE=0
    fi
else
    lua extract_test_errors.lua test_results.txt test_errors.txt
fi
EXTRACT_EXIT_CODE=$?

# Display the errors on console
echo
echo "================================================================================"
cat test_errors.txt
echo "================================================================================"
echo
echo "Full test output saved to: test_results.txt"
echo "Error summary saved to: test_errors.txt"

# Exit with the same code as the error extraction (0 if all passed, 1 if failures)
exit $EXTRACT_EXIT_CODE
