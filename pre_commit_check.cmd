@echo off
setlocal enabledelayedexpansion

REM ============================================================
REM pre_commit_check.cmd - Pre-commit quality gate for TabuLua
REM
REM Runs all verification steps before committing:
REM   1. Unit tests (busted specs)
REM   2. Tutorial export checks (reformatter on tutorial packages)
REM   3. Bad input tests (error detection regression tests)
REM
REM Usage:
REM   pre_commit_check.cmd          Run all checks
REM   pre_commit_check.cmd --quick  Skip export checks (faster)
REM ============================================================

set "SCRIPT_DIR=%~dp0"
set "STEP=0"
set "FAILURES=0"
set "QUICK_MODE=0"

REM Parse arguments
if "%~1"=="--quick" set "QUICK_MODE=1"

echo.
echo ================================================================
echo  TabuLua Pre-Commit Check
echo ================================================================
echo.

REM -----------------------------------------------------------
REM Step 1: Unit tests
REM -----------------------------------------------------------
set /a STEP+=1
echo [%STEP%] Running unit tests...

call "%SCRIPT_DIR%run_tests.cmd"
if errorlevel 1 (
    echo.
    echo [%STEP%] FAILED -- Unit tests have failures
    set /a FAILURES+=1
) else (
    echo [%STEP%] PASSED -- All unit tests passed
)
echo.

REM -----------------------------------------------------------
REM Step 2: Tutorial export checks
REM -----------------------------------------------------------
if %QUICK_MODE%==1 (
    echo [*] Skipping export checks (--quick mode^)
    echo.
    goto :skip_exports
)

set "TUTORIAL_DIRS=tutorial\core\ tutorial\expansion\"

set "EXPORT_LABEL=JSON export"
set "EXPORT_ARGS=--log-level=error --file=json %TUTORIAL_DIRS%"
call :run_export_check
echo.
set "EXPORT_LABEL=SQL + MPK export"
set "EXPORT_ARGS=--log-level=error --file=sql --data=mpk %TUTORIAL_DIRS%"
call :run_export_check
echo.
set "EXPORT_LABEL=Lua export"
set "EXPORT_ARGS=--log-level=error --file=lua %TUTORIAL_DIRS%"
call :run_export_check
echo.
set "EXPORT_LABEL=TSV reformat only"
set "EXPORT_ARGS=--log-level=error %TUTORIAL_DIRS%"
call :run_export_check
echo.

:skip_exports

REM -----------------------------------------------------------
REM Step 3: Bad input tests
REM -----------------------------------------------------------
set /a STEP+=1
echo [%STEP%] Running bad input tests...

call "%SCRIPT_DIR%bad_input\run_bad_input_tests.cmd"
if errorlevel 1 (
    echo.
    echo [%STEP%] FAILED -- Bad input tests have failures
    set /a FAILURES+=1
) else (
    echo [%STEP%] PASSED -- All bad input tests passed
)
echo.

REM -----------------------------------------------------------
REM Summary
REM -----------------------------------------------------------
echo ================================================================
if %FAILURES%==0 (
    echo  All checks passed -- ready to commit!
) else (
    echo  %FAILURES% check(s^) FAILED -- please fix before committing
)
echo ================================================================
echo.

if %FAILURES% GTR 0 exit /b 1
exit /b 0

REM ============================================================
REM Subroutine: run_export_check
REM   Reads EXPORT_LABEL and EXPORT_ARGS set by the caller
REM ============================================================
:run_export_check
set /a STEP+=1
echo [!STEP!] Export check: !EXPORT_LABEL!...

set "TEMP_OUT=%TEMP%\tabulua_export_check_%RANDOM%.txt"

REM Run reformatter from project directory
pushd "%SCRIPT_DIR%"
lua54 reformatter.lua !EXPORT_ARGS! > "!TEMP_OUT!" 2>&1
popd

REM Check for ERROR or FATAL level messages in output
findstr /C:"	ERROR	" /C:"	FATAL	" "!TEMP_OUT!" > nul 2>&1
if not errorlevel 1 (
    echo [!STEP!] FAILED -- Errors in: !EXPORT_LABEL!
    echo   Error output:
    for /f "tokens=*" %%L in ('findstr /C:"ERROR" /C:"FATAL" "!TEMP_OUT!"') do (
        echo     %%L
    )
    set /a FAILURES+=1
) else (
    echo [!STEP!] PASSED -- !EXPORT_LABEL!
)

del /q "!TEMP_OUT!" 2>nul
goto :eof
