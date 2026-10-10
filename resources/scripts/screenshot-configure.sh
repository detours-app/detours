#!/bin/bash
set -euo pipefail

# Configure Detours for the README screenshot after screenshot-setup.sh has
# created the fixture folders. Intended to run on the screenshot Mac.

BASE="${DETOURS_SCREENSHOT_BASE:-$HOME/Projects}"
DOMAIN="com.detours.app"
PLIST="$HOME/Library/Preferences/$DOMAIN.plist"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
REMOTE_HOST="${DETOURS_SCREENSHOT_REMOTE_HOST:-devtest}"
REMOTE_HOST_ID="$(uuidgen)"
FILE_SERVER_NAME="${DETOURS_SCREENSHOT_FILE_SERVER:-Acme NAS}"
FILE_SERVER_SHARE="${DETOURS_SCREENSHOT_FILE_SHARE:-Projects}"
FILE_SERVER_PROTOCOL="${DETOURS_SCREENSHOT_FILE_SERVER_PROTOCOL:-SMB}"
REMOTE_BASE="${DETOURS_SCREENSHOT_REMOTE_BASE:-}"
SPARSEBUNDLE_MOUNT="${DETOURS_SCREENSHOT_SPARSEBUNDLE_MOUNT:-/Volumes/Specs.sparsebundle}"
DISK_IMAGE_MOUNT="${DETOURS_SCREENSHOT_DISK_IMAGE_MOUNT:-/Volumes/Detours.dmg}"
THEME="${DETOURS_SCREENSHOT_THEME:-dark}"
LEFT_TAB_COUNT=4
RIGHT_TAB_COUNT=4
LEFT_LOCAL_TAB_INDEX=2
LEFT_SPARSEBUNDLE_TAB_INDEX=3
RIGHT_REMOTE_TAB_INDEX=2
RIGHT_DISK_IMAGE_TAB_INDEX=3

if [[ -z "$REMOTE_BASE" ]]; then
    if remote_home=$(ssh -o BatchMode=yes "$REMOTE_HOST" 'printf %s "$HOME"' 2>/dev/null); then
        REMOTE_BASE="$remote_home/Projects"
    else
        REMOTE_BASE="$BASE"
    fi
fi

case "$THEME" in
    dark|light)
        ;;
    *)
        echo "Error: DETOURS_SCREENSHOT_THEME must be dark or light, got '$THEME'."
        exit 1
        ;;
esac

REMOTE_API_PATH="$REMOTE_BASE/taskflow/api"

require_directory() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        echo "Error: Missing $path"
        echo "Run resources/scripts/screenshot-setup.sh first."
        exit 1
    fi
}

reset_array() {
    local key="$1"
    "$PLIST_BUDDY" -c "Delete :$key" "$PLIST" >/dev/null 2>&1 || true
    "$PLIST_BUDDY" -c "Add :$key array" "$PLIST"
}

reset_indexed_arrays() {
    local key="$1"
    local count="$2"
    local index

    reset_array "$key"
    for ((index = 0; index < count; index++)); do
        "$PLIST_BUDDY" -c "Add :$key:$index array" "$PLIST"
    done
}

reset_indexed_dicts() {
    local key="$1"
    local count="$2"
    local index

    reset_array "$key"
    for ((index = 0; index < count; index++)); do
        "$PLIST_BUDDY" -c "Add :$key:$index dict" "$PLIST"
    done
}

quit_detours() {
    osascript -e 'tell application id "com.detours.app" to quit' >/dev/null 2>&1 || true
    for _ in {1..50}; do
        if ! pgrep -x Detours >/dev/null 2>&1; then
            return
        fi
        sleep 0.1
    done
    killall Detours >/dev/null 2>&1 || true
}

require_directory "$BASE/acme-corp"
require_directory "$BASE/taskflow/api"
require_directory "$SPARSEBUNDLE_MOUNT"
require_directory "$DISK_IMAGE_MOUNT"

mkdir -p \
    "$BASE/Tools" \
    "$BASE/Finance" \
    "$BASE/INBOX" \
    "$BASE/Downloads" \
    "$HOME/INBOX" \
    "$HOME/1 Projects" \
    "$HOME/2 Areas" \
    "$HOME/3 Resources" \
    "$HOME/4 Archive" \
    "$HOME/dev" \
    "$HOME/Documents" \
    "$HOME/Downloads" \
    "$HOME/Applications"

quit_detours

settings_json=$(printf '{"schemaVersion":1,"restoreSession":true,"showHiddenByDefault":false,"searchIncludesHidden":false,"theme":"%s","fontSize":13,"fileListRowDensity":"compact","dateFormatCurrentYear":"d. MMM H:mm","dateFormatOtherYears":"d.M.yy","showStatusBar":true,"sidebarVisible":true,"folderExpansionEnabled":true,"foldersOnTop":true,"favorites":["%s/INBOX","%s/1 Projects","%s/2 Areas","%s/3 Resources","%s/4 Archive","%s/dev"],"recentServers":[],"gitStatusEnabled":true,"shortcuts":{}}' "$THEME" "$HOME" "$HOME" "$HOME" "$HOME" "$HOME" "$HOME")
settings_hex=$(printf '%s' "$settings_json" | xxd -p -c 100000)
remote_hosts_json=$(printf '[{"id":"%s","displayName":"%s","sshTarget":"%s"}]' "$REMOTE_HOST_ID" "$REMOTE_HOST" "$REMOTE_HOST")
remote_hosts_hex=$(printf '%s' "$remote_hosts_json" | xxd -p -c 100000)

defaults write "$DOMAIN" Detours.Settings -data "$settings_hex"
defaults write "$DOMAIN" Detours.RemoteHosts -data "$remote_hosts_hex"
defaults write "$DOMAIN" Detours.LeftPaneTabs -array "$BASE/Tools" "$BASE/Finance" "$BASE/acme-corp" "$SPARSEBUNDLE_MOUNT"
defaults write "$DOMAIN" Detours.LeftPaneSelectedIndex -int "$LEFT_LOCAL_TAB_INDEX"
defaults write "$DOMAIN" Detours.LeftPaneShowHiddenFiles -array false false false false
defaults write "$DOMAIN" Detours.LeftPaneICloudListingModes -array normal normal normal normal
defaults write "$DOMAIN" Detours.RightPaneTabs -array "$BASE/INBOX" "$BASE/Downloads" "$BASE/taskflow/api" "$DISK_IMAGE_MOUNT"
defaults write "$DOMAIN" Detours.RightPaneSelectedIndex -int "$RIGHT_REMOTE_TAB_INDEX"
defaults write "$DOMAIN" Detours.RightPaneShowHiddenFiles -array false false false false
defaults write "$DOMAIN" Detours.RightPaneICloudListingModes -array normal normal normal normal
defaults write "$DOMAIN" Detours.ActivePane -int 0

reset_indexed_arrays "Detours.LeftPaneSelections" "$LEFT_TAB_COUNT"
"$PLIST_BUDDY" -c "Add :Detours.LeftPaneSelections:$LEFT_LOCAL_TAB_INDEX:0 string $BASE/acme-corp/Budget-2027.xlsx" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.LeftPaneSelections:$LEFT_SPARSEBUNDLE_TAB_INDEX:0 string $SPARSEBUNDLE_MOUNT/token" "$PLIST"

reset_indexed_arrays "Detours.RightPaneSelections" "$RIGHT_TAB_COUNT"
"$PLIST_BUDDY" -c "Add :Detours.RightPaneSelections:$RIGHT_REMOTE_TAB_INDEX:0 string $REMOTE_API_PATH/database.py" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.RightPaneSelections:$RIGHT_DISK_IMAGE_TAB_INDEX:0 string $DISK_IMAGE_MOUNT/Detours.app" "$PLIST"

reset_indexed_arrays "Detours.LeftPaneExpansions" "$LEFT_TAB_COUNT"
reset_indexed_arrays "Detours.RightPaneExpansions" "$RIGHT_TAB_COUNT"

reset_indexed_dicts "Detours.LeftPaneRemoteTabs" "$LEFT_TAB_COUNT"
reset_indexed_dicts "Detours.RightPaneRemoteTabs" "$RIGHT_TAB_COUNT"

"$PLIST_BUDDY" -c "Add :Detours.RightPaneRemoteTabs:$RIGHT_REMOTE_TAB_INDEX:hostID string $REMOTE_HOST_ID" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.RightPaneRemoteTabs:$RIGHT_REMOTE_TAB_INDEX:path string $REMOTE_API_PATH" "$PLIST"

reset_array "Detours.ScreenshotFileServers"
"$PLIST_BUDDY" -c "Add :Detours.ScreenshotFileServers:0 dict" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.ScreenshotFileServers:0:host string $FILE_SERVER_NAME" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.ScreenshotFileServers:0:protocol string $FILE_SERVER_PROTOCOL" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.ScreenshotFileServers:0:shares array" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.ScreenshotFileServers:0:shares:0 dict" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.ScreenshotFileServers:0:shares:0:name string $FILE_SERVER_SHARE" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.ScreenshotFileServers:0:shares:0:path string $REMOTE_API_PATH" "$PLIST"

killall cfprefsd >/dev/null 2>&1 || true
if [[ "${DETOURS_SCREENSHOT_SKIP_RELAUNCH:-0}" == "1" ]]; then
    echo "Skipping Detours relaunch because DETOURS_SCREENSHOT_SKIP_RELAUNCH=1."
else
    open -g /Applications/Detours.app
fi

echo "Detours configured for README screenshot."
echo "Theme:      $THEME"
echo "Left pane:  $BASE/acme-corp"
echo "Right pane: $REMOTE_HOST:$REMOTE_API_PATH"
echo "Mounted:    $SPARSEBUNDLE_MOUNT"
echo "Mounted:    $DISK_IMAGE_MOUNT"
echo "File server: $FILE_SERVER_NAME / $FILE_SERVER_SHARE"
