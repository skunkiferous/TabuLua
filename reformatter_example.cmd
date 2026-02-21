@echo off
REM ============================================================================
REM  reformatter_example.cmd -- Windows CMD wrapper for TabuLua's reformatter
REM
REM  QUICK START
REM    1. Copy this file into the root of your data directory.
REM    2. Edit the CONFIGURATION section below (two variables).
REM    3. Call it from your data directory:
REM
REM         reformatter.cmd [options] <data-directory>
REM
REM  COMMON INVOCATIONS
REM    Validate and reformat all files in-place:
REM         reformatter.cmd .
REM
REM    Export to JSON (output goes to .\exported\ by default):
REM         reformatter.cmd --file=json .
REM
REM    Export to several formats at once:
REM         reformatter.cmd --file=json --file=lua --file=xml .
REM
REM    Choose a different export directory:
REM         reformatter.cmd --file=json --export-dir=build\data .
REM
REM    Print all available options:
REM         reformatter.cmd
REM
REM  NOTE
REM    The data-directory argument is the folder that contains your package
REM    sub-directories (each with a Manifest.transposed.tsv or Files.tsv).
REM    You can pass multiple directories to process several packages at once.
REM    Use "." to refer to the current directory.
REM ============================================================================

REM ============================================================================
REM  CONFIGURATION -- the only two lines you should normally need to edit
REM ============================================================================

REM  Path to your TabuLua installation directory.
REM  Can be absolute or relative to the location of this script.
REM  The default below assumes TabuLua is a sibling of this script's directory
REM  (e.g. both live under C:\Projects\: C:\Projects\MyGame\ and
REM   C:\Projects\TabuLua\).
REM  Other examples:
REM    set TABULUA_DIR=C:\Tools\TabuLua
REM    set TABULUA_DIR=%~dp0..\TabuLua
set TABULUA_DIR=%~dp0..\TabuLua

REM  The Lua 5.4 executable.  Adjust if your system uses a different name
REM  or if the executable is not on PATH and needs a full path.
REM  Examples:
REM    set LUA=lua5.4
REM    set LUA=C:\Lua\bin\lua54.exe
set LUA=lua54

REM ============================================================================
REM  END OF CONFIGURATION -- no changes needed below this line
REM ============================================================================

if not defined LUA_PATH set LUA_PATH=;;
set LUA_PATH=%TABULUA_DIR%\?.lua;%TABULUA_DIR%\parsers\?.lua;%LUA_PATH%
%LUA% "%TABULUA_DIR%\reformatter.lua" %*
