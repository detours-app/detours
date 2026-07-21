#!/bin/bash

# UI Test Runner for Detours
# Usage:
#   resources/scripts/uitest.sh                              # Run all UI tests
#   resources/scripts/uitest.sh TestClass/testMethod         # Run specific test
#   DETOURS_UI_TEST_SCREENSHOT_FIXTURES=1 resources/scripts/uitest.sh TestClass/testMethod

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
XCODEPROJ="$PROJECT_DIR/Tests/UITests/DetoursUITests/DetoursUITests.xcodeproj"
UITEST_DESTINATION="platform=macOS,arch=arm64"
APP_PATH="/Applications/Detours.app"
BUILD_ARGS=()

# Seed the XCUI runner's writable container directly. Creating the fixture in the account home
# makes XCUI fall back to a different unseeded container copy or fail with EPERM when it writes
# control files, so one shared container root is the only truthful ordinary UI-test fixture.
TEST_DIR="$HOME/Library/Containers/MAF.DetoursUITests.xctrunner/Data/DetoursUITests-Temp"
TEST_BUILD_SETTINGS=(
    "DETOURS_QUALIFICATION_APP_PATH_SETTING=$APP_PATH"
    "DETOURS_QUALIFICATION_UI_ROOT_SETTING=$TEST_DIR"
    "DETOURS_QUALIFICATION_UI_CONTROL_ROOT_SETTING=$TEST_DIR"
    "DETOURS_WINDOWS_TEST_TARGET_SETTING=${DETOURS_WINDOWS_TEST_TARGET:-detours-windows}"
    "DETOURS_TEST_ACCOUNT_HOME_SETTING=$HOME"
)

if [ "${DETOURS_UI_TEST_SCREENSHOT_FIXTURES:-0}" = "1" ]; then
    BUILD_ARGS+=(--screenshot-fixtures)
fi

if [ -n "${DETOURS_SCREENSHOT_CAPTURE_DIR:-}" ] && [[ "$DETOURS_SCREENSHOT_CAPTURE_DIR" != /* ]]; then
    export DETOURS_SCREENSHOT_CAPTURE_DIR="$PROJECT_DIR/$DETOURS_SCREENSHOT_CAPTURE_DIR"
fi

copy_screenshot_captures() {
    if [ -z "${DETOURS_SCREENSHOT_CAPTURE_DIR:-}" ]; then
        return
    fi

    local capture_theme="${DETOURS_SCREENSHOT_CAPTURE_THEME:-${DETOURS_SCREENSHOT_THEME:-dark}}"
    local runner_docs="$HOME/Library/Containers/MAF.DetoursUITests.xctrunner/Data/resources/docs"

    mkdir -p "$DETOURS_SCREENSHOT_CAPTURE_DIR"
    cp "$runner_docs/chrome-polish-left-active.png" \
        "$DETOURS_SCREENSHOT_CAPTURE_DIR/chrome-polish-$capture_theme-left-active.png"
    cp "$runner_docs/chrome-polish-right-active.png" \
        "$DETOURS_SCREENSHOT_CAPTURE_DIR/chrome-polish-$capture_theme-right-active.png"
}

# Build app first
echo "Building Detours..."
DETOURS_BUILD_FORCE_QUIT=1 DETOURS_BUILD_SKIP_RELAUNCH=1 "$SCRIPT_DIR/build.sh" "${BUILD_ARGS[@]}"

if [ "${DETOURS_UI_TEST_SCREENSHOT_FIXTURES:-0}" = "1" ]; then
    echo ""
    echo "Setting up screenshot fixtures..."
    "$SCRIPT_DIR/screenshot-setup.sh"
    if [ "${DETOURS_UI_TEST_SCREENSHOT_REMOTE_FIXTURES:-0}" = "1" ]; then
        REMOTE_HOST="${DETOURS_SCREENSHOT_REMOTE_HOST:-devtest}"
        ssh -o BatchMode=yes "$REMOTE_HOST" 'bash -s' < "$SCRIPT_DIR/screenshot-setup.sh"
    fi
    DETOURS_SCREENSHOT_SKIP_RELAUNCH=1 "$SCRIPT_DIR/screenshot-configure.sh"
fi

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

trap 'rm -rf "$TEST_DIR"' EXIT

if [ -n "$1" ]; then
    # Run specific test
    DETOURS_UI_TEST_ROOT="$TEST_DIR" DETOURS_UI_TEST_APP_PATH="$APP_PATH" xcodebuild test \
        -project "$XCODEPROJ" \
        -scheme DetoursUITests \
        -destination "$UITEST_DESTINATION" \
        "${TEST_BUILD_SETTINGS[@]}" \
        -only-testing:"DetoursUITests/$1"
elif [ "${DETOURS_UI_TEST_SCREENSHOT_FIXTURES:-0}" = "1" ]; then
    # Screenshot capture depends on the deterministic session written by
    # screenshot-configure.sh. Run it before any other UI test can save a
    # different pane session, then exclude it from the remaining full suite.
    DETOURS_UI_TEST_ROOT="$TEST_DIR" DETOURS_UI_TEST_APP_PATH="$APP_PATH" xcodebuild test \
        -project "$XCODEPROJ" \
        -scheme DetoursUITests \
        -destination "$UITEST_DESTINATION" \
        "${TEST_BUILD_SETTINGS[@]}" \
        -only-testing:"DetoursUITests/ChromePolishScreenshotTests"

    DETOURS_UI_TEST_ROOT="$TEST_DIR" DETOURS_UI_TEST_APP_PATH="$APP_PATH" xcodebuild test \
        -project "$XCODEPROJ" \
        -scheme DetoursUITests \
        -destination "$UITEST_DESTINATION" \
        "${TEST_BUILD_SETTINGS[@]}" \
        -skip-testing:"DetoursUITests/ChromePolishScreenshotTests"
else
    # Run all tests
    DETOURS_UI_TEST_ROOT="$TEST_DIR" DETOURS_UI_TEST_APP_PATH="$APP_PATH" xcodebuild test \
        -project "$XCODEPROJ" \
        -scheme DetoursUITests \
        -destination "$UITEST_DESTINATION" \
        "${TEST_BUILD_SETTINGS[@]}"
fi

copy_screenshot_captures

exit $?
