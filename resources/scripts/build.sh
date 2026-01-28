#!/bin/bash
set -e

cd "$(dirname "$0")/../.."

# Read version from single source of truth
VERSION=$(cat VERSION)

APP_NAME="Detours"
APP_BUNDLE_ID="com.detours.app"
APP_DIR="build/Detours.app"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
DIMMED='\033[38;5;245m'
NC='\033[0m'

log_info() { echo -e "${DIMMED}INFO  $1${NC}" >&2; }
log_ok()   { echo -e "${GREEN}OK    $1${NC}" >&2; }
log_error() { echo -e "${RED}ERROR $1${NC}" >&2; }

# Parse arguments
BUILD_CONFIG="release"
for arg in "$@"; do
    case $arg in
        --debug)
            BUILD_CONFIG="debug"
            shift
            ;;
    esac
done

echo "DETOURS BUILD" >&2
echo "-------------" >&2

# Check if running
WAS_RUNNING=false
log_info "Check if Detours is running"
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    WAS_RUNNING=true
    log_info "Quit running instance"
    osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in {1..50}; do
        if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        log_error "Detours is still running; refusing to overwrite"
        exit 1
    fi
    log_ok "Quit complete"
else
    log_ok "Not running"
fi

# Build
log_info "Swift build ($BUILD_CONFIG)"
swift build -c "$BUILD_CONFIG"
log_ok "Build complete"

# Create app bundle
log_info "Create app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp ".build/arm64-apple-macosx/$BUILD_CONFIG/Detours" "$APP_DIR/Contents/MacOS/Detours"
cp resources/icons/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

cat > "$APP_DIR/Contents/Info.plist" << EOF
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
    <string>$VERSION</string>
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
log_ok "App bundle created"

# Codesign
log_info "Codesign app bundle"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Marco Fruh (AHUQTWVD7X)}"
ENTITLEMENTS="Detours.entitlements"
/usr/bin/codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" -s "$CODESIGN_IDENTITY" "$APP_DIR" 2>&1
log_ok "Codesigned"

if [ "$1" = "--no-install" ]; then
    log_ok "Done (app bundle at build/Detours.app)"
    exit 0
fi

# Remove stale copies
log_info "Check for stale installations"
STALE_FOUND=false
while IFS= read -r app_path; do
    if [ "$app_path" != "/Applications/Detours.app" ] && [ -d "$app_path" ]; then
        log_info "Remove stale copy: $app_path"
        rm -rf "$app_path"
        STALE_FOUND=true
    fi
done < <(mdfind "kMDItemCFBundleIdentifier == 'com.detours.app'" 2>/dev/null)
if [ "$STALE_FOUND" = true ]; then
    log_ok "Stale copies removed"
else
    log_ok "No stale copies found"
fi

# Install
log_info "Install to /Applications"
rm -rf /Applications/Detours.app
mv build/Detours.app /Applications/Detours.app
log_ok "Installed"

# Always relaunch after successful build
log_info "Relaunch Detours"
open -g /Applications/Detours.app
log_ok "Relaunched"

log_ok "Done"
