#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "Building Detour..."
swift build

echo "Updating app bundle..."
cp .build/arm64-apple-macosx/debug/Detour build/Detour.app/Contents/MacOS/Detour

APP_DIR="build/Detour.app"
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
