#!/bin/bash
set -e

cd "$(dirname "$0")/../.."

APP_NAME="Detour"
APP_BUNDLE_ID="com.detour.app"
APP_DIR="build/Detour.app"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "Detour is running; quitting before rebuild..."
    osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in {1..50}; do
        if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "Detour is still running; refusing to overwrite the app bundle."
        exit 1
    fi
fi

echo "Building Detour..."
swift build

echo "Updating app bundle..."
cp .build/arm64-apple-macosx/debug/Detour build/Detour.app/Contents/MacOS/Detour

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Detour Dev}"
CODESIGN_KEYCHAIN="${CODESIGN_KEYCHAIN:-$HOME/Library/Keychains/detour-codesign.keychain-db}"

if [ -d "$APP_DIR" ] && [ -f "$CODESIGN_KEYCHAIN" ]; then
    security unlock-keychain -p "" "$CODESIGN_KEYCHAIN" >/dev/null 2>&1 || true
    /usr/bin/codesign --force --options runtime --keychain "$CODESIGN_KEYCHAIN" -s "$CODESIGN_IDENTITY" "$APP_DIR"
    echo "Codesigned app bundle."
else
    echo "Codesign skipped (missing app bundle or keychain)."
fi

echo "Touching app bundle to refresh Spotlight..."
touch build/Detour.app

echo "Done! App bundle updated at build/Detour.app"
