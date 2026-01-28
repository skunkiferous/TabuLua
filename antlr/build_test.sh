#!/bin/bash

# Based on TypeSpec.g4, generates the parser for Java, and test it with schema.tsv

set -e  # Exit on error

# Validating ...
if [ ! -f "antlr-4.13.2-complete.jar" ]; then
    echo "ERROR: antlr-4.13.2-complete.jar not found!"
    echo "Please download it from https://www.antlr.org/download/antlr-4.13.2-complete.jar"
    echo "For example: curl -O https://www.antlr.org/download/antlr-4.13.2-complete.jar"
    exit 1
fi

if [ ! -f "../TypeSpec.g4" ]; then
    echo "ERROR: grammar file TypeSpec.g4 not found!"
    exit 1
fi

if [ ! -f "../exported/schema.tsv" ]; then
    echo "ERROR: Schema file schema.tsv not found!"
    echo "Please run the reformatter at least once with an export option first"
    exit 1
fi

echo "Cleaning up previous build ..."
rm -f *.class TypeSpec*.* 2>/dev/null || true

echo "Generating parser ..."
# org.antlr.v4.Tool generates the files in the directory of the grammar by default.
# It seems to have a bug, where it ignores the "-o" option to specify the output directory
# So we have to copy the grammar here first.
cp ../TypeSpec.g4 .
java -cp antlr-4.13.2-complete.jar org.antlr.v4.Tool TypeSpec.g4

echo "Building the parser ..."
javac -cp antlr-4.13.2-complete.jar *.java

echo "Building the parser tester ..."
javac -cp "antlr-4.13.2-complete.jar:." TestSchemaParser.java

echo "Running the parser tester with ../exported/schema.tsv ..."
java -cp "antlr-4.13.2-complete.jar:." TestSchemaParser ../exported/schema.tsv

echo "Cleaning up copied grammar file ..."
rm -f TypeSpec.g4 2>/dev/null || true
