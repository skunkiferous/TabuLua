@echo off

REM Based on TypeSpec.g4, generates the parser for Java, and test it with schema.tsv

REM Validating ...
IF NOT EXIST antlr-4.13.2-complete.jar (
    echo ERROR: antlr-4.13.2-complete.jar not found!
    echo Please download it from https://www.antlr.org/download/antlr-4.13.2-complete.jar
    echo For example: curl -O https://www.antlr.org/download/antlr-4.13.2-complete.jar
    exit /b 1
)

IF NOT EXIST ..\TypeSpec.g4 (
    echo ERROR: grammar file TypeSpec.g4 not found!
    exit /b 1
)

IF NOT EXIST ..\exported\schema.tsv (
    echo ERROR: Schema file schema.tsv not found!
    echo Please run the reformatter at least once with an export option first
    exit /b 1
)

echo Cleaning up previous build ...
erase /q *.class TypeSpec*.* 2>nul

echo Generating parser ...
REM org.antlr.v4.Tool generates the files in the directory of the grammar by default.
REM It seems to have a bug, where it ignores the "-o" option to specify the output directory
REM So we have to copy the grammar here first.
copy /y ..\TypeSpec.g4 . >nul
java -cp antlr-4.13.2-complete.jar org.antlr.v4.Tool TypeSpec.g4 || exit /b 1

echo Building the parser ...
javac -cp antlr-4.13.2-complete.jar *.java || exit /b 1

echo Building the parser tester ...
javac -cp antlr-4.13.2-complete.jar;. TestSchemaParser.java || exit /b 1

echo Running the parser tester with ..\exported\schema.tsv ...
java -cp antlr-4.13.2-complete.jar;. TestSchemaParser ..\exported\schema.tsv

echo Cleaning up copied grammar file ...
erase /q TypeSpec.g4 2>nul
