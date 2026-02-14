@echo off
setlocal enabledelayedexpansion

REM ============================================================
REM run_bad_input_tests.cmd - Bad input test runner for TabuLua
REM
REM Usage:
REM   run_bad_input_tests.cmd                         Run all tests
REM   run_bad_input_tests.cmd CATEGORY                Run all tests in a category
REM   run_bad_input_tests.cmd CATEGORY TEST           Run a specific test
REM   run_bad_input_tests.cmd --update                Update all expected outputs
REM   run_bad_input_tests.cmd --update CATEGORY       Update expected outputs in a category
REM   run_bad_input_tests.cmd --update CATEGORY TEST  Update a specific expected output
REM ============================================================

set "SCRIPT_DIR=%~dp0"
set "PROJECT_DIR=%SCRIPT_DIR%.."
set "NORMALIZER=%SCRIPT_DIR%normalize_output.lua"
set "UPDATE_MODE=0"
set "FILTER_CATEGORY="
set "FILTER_TEST="
set "PASS_COUNT=0"
set "FAIL_COUNT=0"
set "SKIP_COUNT=0"
set "UPDATE_COUNT=0"

REM Parse arguments
:parse_args
if "%~1"=="" goto :done_args
if "%~1"=="--update" (
    set "UPDATE_MODE=1"
    shift
    goto :parse_args
)
if "!FILTER_CATEGORY!"=="" (
    set "FILTER_CATEGORY=%~1"
    shift
    goto :parse_args
)
if "!FILTER_TEST!"=="" (
    set "FILTER_TEST=%~1"
    shift
    goto :parse_args
)
shift
goto :parse_args
:done_args

echo.
echo ================================================================
echo  TabuLua Bad Input Test Runner
if "!UPDATE_MODE!"=="1" echo  MODE: UPDATE [generating expected outputs]
echo ================================================================
echo.

REM Iterate over category directories
for /d %%C in ("%SCRIPT_DIR%*") do call :process_category "%%C"

echo.
echo ================================================================
if "!UPDATE_MODE!"=="1" (
    echo  Results: !UPDATE_COUNT! updated, !SKIP_COUNT! skipped
) else (
    echo  Results: !PASS_COUNT! passed, !FAIL_COUNT! failed, !SKIP_COUNT! skipped
)
echo ================================================================

if !FAIL_COUNT! gtr 0 exit /b 1
exit /b 0

REM ============================================================
:process_category
REM   %1 = category directory path
REM ============================================================
set "CAT_DIR=%~1"
for %%X in ("%CAT_DIR%") do set "CAT_NAME=%%~nxX"

REM Skip if category filter set and doesn't match
if "!FILTER_CATEGORY!" neq "" (
    if /i "!CAT_NAME!" neq "!FILTER_CATEGORY!" goto :eof
)

echo --- !CAT_NAME! ---

REM Iterate over test case directories
for /d %%T in ("%CAT_DIR%\*") do call :process_test "%%T"
goto :eof

REM ============================================================
:process_test
REM   %1 = test case directory path
REM ============================================================
set "TEST_DIR=%~1"
for %%X in ("%TEST_DIR%") do set "TEST_NAME=%%~nxX"

REM Skip if test filter set and doesn't match
if "!FILTER_TEST!" neq "" (
    if /i "!TEST_NAME!" neq "!FILTER_TEST!" goto :eof
)

REM Determine test type: CLI test (has args.txt and no Manifest) or data test
if exist "%TEST_DIR%\Manifest.transposed.tsv" (
    call :run_data_test "%TEST_DIR%"
) else if exist "%TEST_DIR%\Files.tsv" (
    call :run_data_test "%TEST_DIR%"
) else if exist "%TEST_DIR%\args.txt" (
    call :run_cli_test "%TEST_DIR%"
) else (
    echo   SKIP: !TEST_NAME! [no test files found]
    set /a SKIP_COUNT+=1
)
goto :eof

REM ============================================================
:run_cli_test
REM   %1 = test case directory path
REM ============================================================
set "T_DIR=%~1"
for %%X in ("%T_DIR%") do set "T_NAME=%%~nxX"

REM Read args from args.txt
set "CLI_ARGS="
for /f "usebackq delims=" %%A in ("%T_DIR%\args.txt") do set "CLI_ARGS=%%A"

REM Create temp files for output
set "TEMP_RAW=%TEMP%\tabulua_bi_raw_%RANDOM%.txt"
set "TEMP_NORM=%TEMP%\tabulua_bi_norm_%RANDOM%.txt"

REM Run reformatter from project root with the specified args
pushd "%PROJECT_DIR%"
lua54 reformatter.lua !CLI_ARGS! > "!TEMP_RAW!" 2>&1
popd

REM Normalize output
lua54 "%NORMALIZER%" "!TEMP_RAW!" "!TEMP_NORM!"

REM Compare or update
call :compare_output "%T_DIR%" "!TEMP_NORM!"

REM Cleanup temp files
del /q "!TEMP_RAW!" 2>nul
del /q "!TEMP_NORM!" 2>nul
goto :eof

REM ============================================================
:run_data_test
REM   %1 = test case directory path
REM ============================================================
set "T_DIR=%~1"
for %%X in ("%T_DIR%") do set "T_NAME=%%~nxX"

REM Create temp directory for the copy
set "TEMP_PKG=%TEMP%\tabulua_bi_%RANDOM%_%TIME:~6,2%"
mkdir "!TEMP_PKG!" 2>nul

REM Copy all files (including subdirectories like libs/)
xcopy "%T_DIR%\*" "!TEMP_PKG!\" /s /e /q /y >nul 2>&1
REM Remove files that should not be in the package copy
if exist "!TEMP_PKG!\expected_output.txt" del /q "!TEMP_PKG!\expected_output.txt"
if exist "!TEMP_PKG!\args.txt" del /q "!TEMP_PKG!\args.txt"

REM Create temp files for output
set "TEMP_RAW=%TEMP%\tabulua_bi_raw_%RANDOM%.txt"
set "TEMP_NORM=%TEMP%\tabulua_bi_norm_%RANDOM%.txt"

REM Run reformatter on the temp copy
pushd "%PROJECT_DIR%"
lua54 reformatter.lua --log-level=warn "!TEMP_PKG!" > "!TEMP_RAW!" 2>&1
popd

REM Normalize output (replace temp dir path with {DIR})
lua54 "%NORMALIZER%" --temp-dir="!TEMP_PKG!" "!TEMP_RAW!" "!TEMP_NORM!"

REM Compare or update
call :compare_output "%T_DIR%" "!TEMP_NORM!"

REM Cleanup
del /q "!TEMP_RAW!" 2>nul
del /q "!TEMP_NORM!" 2>nul
rd /s /q "!TEMP_PKG!" 2>nul
goto :eof

REM ============================================================
:compare_output
REM   %1 = test case directory path
REM   %2 = path to normalized actual output
REM ============================================================
set "CMP_DIR=%~1"
set "CMP_ACTUAL=%~2"
for %%X in ("%CMP_DIR%") do set "CMP_NAME=%%~nxX"

set "CMP_EXPECTED=%CMP_DIR%\expected_output.txt"

if "!UPDATE_MODE!"=="1" (
    copy /y "!CMP_ACTUAL!" "!CMP_EXPECTED!" >nul
    echo   UPDATED: !CMP_NAME!
    set /a UPDATE_COUNT+=1
    goto :eof
)

if not exist "!CMP_EXPECTED!" (
    echo   SKIP: !CMP_NAME! [no expected_output.txt - use --update to generate]
    set /a SKIP_COUNT+=1
    goto :eof
)

fc /a "!CMP_ACTUAL!" "!CMP_EXPECTED!" >nul 2>&1
if !ERRORLEVEL!==0 (
    echo   PASS: !CMP_NAME!
    set /a PASS_COUNT+=1
) else (
    echo   FAIL: !CMP_NAME!
    echo.
    echo   --- Expected ---
    type "!CMP_EXPECTED!"
    echo.
    echo   --- Actual ---
    type "!CMP_ACTUAL!"
    echo.
    set /a FAIL_COUNT+=1
)
goto :eof
