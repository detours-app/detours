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
APP_PATH="$PROJECT_DIR/build/Detours.app"
DMG_NAME="Detours-$VERSION.dmg"
DMG_PATH="$PROJECT_DIR/$DMG_NAME"
STAGING_DIR="$PROJECT_DIR/.build/dmg-staging"

cd "$PROJECT_DIR"

echo "==> Building release..."
"$SCRIPT_DIR/build.sh" --no-install

if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: Build failed, no app at $APP_PATH"
    exit 1
fi

echo "==> Creating DMG..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "Detours" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING_DIR"

echo "==> Notarizing DMG..."
# Submit for notarization (requires keychain profile "detours-notarize")
# Set up with: xcrun notarytool store-credentials "detours-notarize" ...
xcrun notarytool submit "$DMG_PATH" --keychain-profile "detours-notarize" --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo "==> Tagging v$VERSION..."
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "Tag v$VERSION already exists, skipping"
else
    git tag -a "v$VERSION" -m "Version $VERSION"
fi

echo ""
echo "Release prepared: $DMG_PATH"
echo ""
read -p "Push tag and upload DMG to GitHub? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "==> Pushing tag v$VERSION..."
    git push public "v$VERSION"

    echo "==> Waiting for GitHub Actions to create release..."
    sleep 10

    echo "==> Uploading DMG..."
    gh release upload "v$VERSION" "$DMG_NAME" --repo detours-app/detours

    echo ""
    echo "Done! https://github.com/detours-app/detours/releases/tag/v$VERSION"
else
    echo "Skipped. To publish manually:"
    echo "  git push public v$VERSION"
    echo "  gh release upload v$VERSION $DMG_NAME --repo detours-app/detours"
fi
