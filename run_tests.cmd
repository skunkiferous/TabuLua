@echo off
setlocal

cls

REM Run tests and capture output to test_results.txt
echo Running tests...
del /Q test_results.txt
if "%~1"=="" (
    :: No argument provided - run all tests
    call busted -v --output=TAP --lpath=?.lua --lpath=?/init.lua -p spec --coverage > test_results.txt 2>&1
) else (
    :: Check if file exists
    if not exist "%~1" (
        echo Error: Test file not found: %~1
        exit /b 1
    )
    :: Argument provided - run specific test
    call busted -v --output=TAP --lpath=?.lua --lpath=?/init.lua "%~1" --coverage > test_results.txt 2>&1
)

REM Extract errors using Lua script
del /Q test_errors.txt
lua54 extract_test_errors.lua test_results.txt test_errors.txt
set "TEST_EXIT=%ERRORLEVEL%"

REM Display the errors on console
echo.
echo ================================================================================
type test_errors.txt
echo ================================================================================
echo.
echo Full test output saved to: test_results.txt
echo Error summary saved to: test_errors.txt

REM Exit with the same code as the error extraction (0 if all passed, 1 if failures)
exit /b %TEST_EXIT%