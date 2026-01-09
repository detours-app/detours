#!/bin/bash
set -e

cd "$(dirname "$0")/../.."

APP_NAME="Detours"
APP_BUNDLE_ID="com.detours.app"
APP_DIR="build/Detours.app"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "Detours is running; quitting before rebuild..."
    osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in {1..50}; do
        if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "Detours is still running; refusing to overwrite the app bundle."
        exit 1
    fi
fi

echo "Building Detours..."
swift build

echo "Updating app bundle..."
cp .build/arm64-apple-macosx/debug/Detours build/Detours.app/Contents/MacOS/Detours

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Detour Dev}"
CODESIGN_KEYCHAIN="${CODESIGN_KEYCHAIN:-$HOME/Library/Keychains/detour-codesign.keychain-db}"

ENTITLEMENTS="Detours.entitlements"

if [ -d "$APP_DIR" ] && [ -f "$CODESIGN_KEYCHAIN" ]; then
    security unlock-keychain -p "" "$CODESIGN_KEYCHAIN" >/dev/null 2>&1 || true
    /usr/bin/codesign --force --options runtime --entitlements "$ENTITLEMENTS" --keychain "$CODESIGN_KEYCHAIN" -s "$CODESIGN_IDENTITY" "$APP_DIR"
    echo "Codesigned app bundle with entitlements."
else
    echo "Codesign skipped (missing app bundle or keychain)."
fi

echo "Touching app bundle to refresh Spotlight..."
touch build/Detours.app

if [ "$1" = "--no-install" ]; then
    echo "Done! App bundle updated at build/Detours.app"
else
    echo "Installing to ~/Applications..."
    mkdir -p ~/Applications
    rm -rf ~/Applications/Detours.app
    cp -R build/Detours.app ~/Applications/Detours.app
    echo "Done! App installed to ~/Applications/Detours.app"
fi
