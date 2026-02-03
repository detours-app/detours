#!/bin/bash

# UI Test Runner for Detours
# Usage:
#   resources/scripts/uitest.sh                              # Run all UI tests
#   resources/scripts/uitest.sh TestClass/testMethod         # Run specific test

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
XCODEPROJ="$PROJECT_DIR/Tests/UITests/DetoursUITests/DetoursUITests.xcodeproj"

# Test directory setup in home (accessible and easy to navigate)
TEST_DIR="$HOME/DetoursUITests-Temp"

# Build app first
echo "Building Detours..."
"$SCRIPT_DIR/build.sh"

echo ""
echo "Setting up test directory..."

# Clean up and create test directory structure
rm -rf "$TEST_DIR"

# Root level - multiple folders and files
# IMPORTANT: Some folders must sort BEFORE "Folder" alphabetically
# to test that new folder selection works when "Folder" is in the middle
mkdir -p "$TEST_DIR/AAA_First"
mkdir -p "$TEST_DIR/BBB_Second/SubfolderB1"
mkdir -p "$TEST_DIR/BBB_Second/SubfolderB2"
mkdir -p "$TEST_DIR/CCC_Third"
mkdir -p "$TEST_DIR/FolderA/SubfolderA1"
mkdir -p "$TEST_DIR/FolderA/SubfolderA2"
mkdir -p "$TEST_DIR/FolderB/SubfolderB1"
mkdir -p "$TEST_DIR/FolderB/SubfolderB2"
mkdir -p "$TEST_DIR/FolderC"
mkdir -p "$TEST_DIR/FolderD"

# Files in various locations
echo "test" > "$TEST_DIR/FolderA/SubfolderA1/file.txt"
echo "test" > "$TEST_DIR/FolderA/alpha-file.txt"
echo "test" > "$TEST_DIR/FolderB/beta-file.txt"
echo "test" > "$TEST_DIR/FolderB/SubfolderB1/nested.txt"
echo "test" > "$TEST_DIR/file1.txt"
echo "test" > "$TEST_DIR/file2.txt"

# Unique target for selection tests - NOT first alphabetically in root
# Root order: FolderA, FolderB, FolderC, FolderD, file1.txt, file2.txt, zz-target.txt
echo "target" > "$TEST_DIR/zz-target.txt"

# Another unique target inside FolderB (not first in FolderB)
# FolderB order: SubfolderB1, SubfolderB2, beta-file.txt, unique-in-B.txt
echo "target" > "$TEST_DIR/FolderB/unique-in-B.txt"

# Folder with year for duplicate structure tests
mkdir -p "$TEST_DIR/Projects2025/Quarterly/Q1"
mkdir -p "$TEST_DIR/Projects2025/Quarterly/Q2"
mkdir -p "$TEST_DIR/Projects2025/Annual"
echo "data" > "$TEST_DIR/Projects2025/notes.txt"

echo "Running UI tests..."

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

if [ -n "$1" ]; then
    # Run specific test
    xcodebuild test \
        -project "$XCODEPROJ" \
        -scheme DetoursUITests \
        -destination 'platform=macOS' \
        -only-testing:"DetoursUITests/$1"
else
    # Run all tests
    xcodebuild test \
        -project "$XCODEPROJ" \
        -scheme DetoursUITests \
        -destination 'platform=macOS'
fi

exit $?
