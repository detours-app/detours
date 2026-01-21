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
mkdir -p "$TEST_DIR/FolderA/SubfolderA1"
mkdir -p "$TEST_DIR/FolderA/SubfolderA2"
mkdir -p "$TEST_DIR/FolderB"
echo "test content" > "$TEST_DIR/FolderA/SubfolderA1/file.txt"
echo "test content" > "$TEST_DIR/file1.txt"

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
