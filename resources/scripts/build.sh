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

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy executable
cp .build/arm64-apple-macosx/debug/Detours "$APP_DIR/Contents/MacOS/Detours"

# Copy icon
cp resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

# Create PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Detours</string>
    <key>CFBundleExecutable</key>
    <string>Detours</string>
    <key>CFBundleIdentifier</key>
    <string>com.detours.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Detours</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.7.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Detours needs to control Finder to open Get Info windows and close them when quitting.</string>
</dict>
</plist>
EOF

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Detour Dev}"
CODESIGN_KEYCHAIN="${CODESIGN_KEYCHAIN:-$HOME/Library/Keychains/detour-codesign.keychain-db}"
ENTITLEMENTS="Detours.entitlements"

if [ -f "$CODESIGN_KEYCHAIN" ]; then
    security unlock-keychain -p "" "$CODESIGN_KEYCHAIN" >/dev/null 2>&1 || true
    /usr/bin/codesign --force --options runtime --entitlements "$ENTITLEMENTS" --keychain "$CODESIGN_KEYCHAIN" -s "$CODESIGN_IDENTITY" "$APP_DIR"
    echo "Codesigned app bundle."
else
    echo "Codesign skipped (keychain not found)."
fi

if [ "$1" = "--no-install" ]; then
    echo "Done! App bundle at build/Detours.app"
else
    echo "Installing to ~/Applications..."
    mkdir -p ~/Applications
    rm -rf ~/Applications/Detours.app
    mv build/Detours.app ~/Applications/Detours.app
    echo "Done! App installed to ~/Applications/Detours.app"
fi
