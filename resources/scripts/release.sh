#!/bin/bash
set -euo pipefail

# Release script for Detours
# Usage: ./resources/scripts/release.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Extract version from AppDelegate.swift
VERSION=$(grep -o 'applicationVersion: "[^"]*"' "$PROJECT_DIR/src/App/AppDelegate.swift" | sed 's/applicationVersion: "//;s/"//')

if [[ -z "$VERSION" ]]; then
    echo "Error: Could not extract version from AppDelegate.swift"
    exit 1
fi

echo "Version: $VERSION"
APP_PATH="$PROJECT_DIR/.build/Build/Products/Release/Detours.app"
ZIP_NAME="Detours-$VERSION.zip"
ZIP_PATH="$PROJECT_DIR/$ZIP_NAME"

cd "$PROJECT_DIR"

echo "==> Building release..."
"$SCRIPT_DIR/build.sh"

if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: Build failed, no app at $APP_PATH"
    exit 1
fi

echo "==> Notarizing..."
# Submit for notarization (requires keychain profile "detours-notarize")
# Set up with: xcrun notarytool store-credentials "detours-notarize" ...
xcrun notarytool submit "$APP_PATH" --keychain-profile "detours-notarize" --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

echo "==> Creating ZIP..."
cd "$(dirname "$APP_PATH")"
zip -r "$ZIP_PATH" Detours.app
cd "$PROJECT_DIR"

echo "==> Tagging v$VERSION..."
git tag -a "v$VERSION" -m "Version $VERSION"

echo ""
echo "Release prepared: $ZIP_PATH"
echo ""
echo "Next steps:"
echo "  1. Push tag to public repo:"
echo "     git push public v$VERSION"
echo ""
echo "  2. Create GitHub release:"
echo "     gh release create v$VERSION --repo detours-app/detours --title \"Detours v$VERSION\" --notes \"Release notes\" $ZIP_NAME"
