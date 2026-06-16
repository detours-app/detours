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

if [[ -z "$REMOTE_BASE" ]]; then
    if remote_home=$(ssh -o BatchMode=yes "$REMOTE_HOST" 'printf %s "$HOME"' 2>/dev/null); then
        REMOTE_BASE="$remote_home/Projects"
    else
        REMOTE_BASE="$BASE"
    fi
fi

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

settings_json=$(printf '{"schemaVersion":1,"restoreSession":true,"showHiddenByDefault":false,"searchIncludesHidden":false,"theme":"dark","fontSize":13,"dateFormatCurrentYear":"d. MMM H:mm","dateFormatOtherYears":"d.M.yy","showStatusBar":true,"sidebarVisible":true,"folderExpansionEnabled":true,"foldersOnTop":true,"favorites":["%s/INBOX","%s/1 Projects","%s/2 Areas","%s/3 Resources","%s/4 Archive","%s/dev"],"recentServers":[],"gitStatusEnabled":true,"shortcuts":{}}' "$HOME" "$HOME" "$HOME" "$HOME" "$HOME" "$HOME")
settings_hex=$(printf '%s' "$settings_json" | xxd -p -c 100000)
remote_hosts_json=$(printf '[{"id":"%s","displayName":"%s","sshTarget":"%s"}]' "$REMOTE_HOST_ID" "$REMOTE_HOST" "$REMOTE_HOST")
remote_hosts_hex=$(printf '%s' "$remote_hosts_json" | xxd -p -c 100000)

defaults write "$DOMAIN" Detours.Settings -data "$settings_hex"
defaults write "$DOMAIN" Detours.RemoteHosts -data "$remote_hosts_hex"
defaults write "$DOMAIN" Detours.LeftPaneTabs -array "$BASE/Tools" "$BASE/Finance" "$BASE/acme-corp"
defaults write "$DOMAIN" Detours.LeftPaneSelectedIndex -int 2
defaults write "$DOMAIN" Detours.LeftPaneShowHiddenFiles -array false false false
defaults write "$DOMAIN" Detours.LeftPaneICloudListingModes -array normal normal normal
defaults write "$DOMAIN" Detours.RightPaneTabs -array "$BASE/INBOX" "$BASE/Downloads" "$BASE/taskflow/api"
defaults write "$DOMAIN" Detours.RightPaneSelectedIndex -int 2
defaults write "$DOMAIN" Detours.RightPaneShowHiddenFiles -array false false false
defaults write "$DOMAIN" Detours.RightPaneICloudListingModes -array normal normal normal
defaults write "$DOMAIN" Detours.ActivePane -int 0
defaults write "$DOMAIN" Detours.SidebarVisible -bool true
defaults write "$DOMAIN" Detours.SidebarWidth -int 189
defaults write "$DOMAIN" Detours.SplitDividerPosition -float 0.5

reset_array "Detours.LeftPaneSelections"
"$PLIST_BUDDY" -c "Add :Detours.LeftPaneSelections:0 array" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.LeftPaneSelections:1 array" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.LeftPaneSelections:2 array" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.LeftPaneSelections:2:0 string $BASE/acme-corp/Budget-2026.xlsx" "$PLIST"

reset_array "Detours.RightPaneSelections"
"$PLIST_BUDDY" -c "Add :Detours.RightPaneSelections:0 array" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.RightPaneSelections:1 array" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.RightPaneSelections:2 array" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.RightPaneSelections:2:0 string $REMOTE_API_PATH/database.py" "$PLIST"

for key in Detours.LeftPaneExpansions Detours.RightPaneExpansions; do
    reset_array "$key"
    "$PLIST_BUDDY" -c "Add :$key:0 array" "$PLIST"
    "$PLIST_BUDDY" -c "Add :$key:1 array" "$PLIST"
    "$PLIST_BUDDY" -c "Add :$key:2 array" "$PLIST"
done

for key in Detours.LeftPaneRemoteTabs Detours.RightPaneRemoteTabs; do
    reset_array "$key"
    "$PLIST_BUDDY" -c "Add :$key:0 dict" "$PLIST"
    "$PLIST_BUDDY" -c "Add :$key:1 dict" "$PLIST"
    "$PLIST_BUDDY" -c "Add :$key:2 dict" "$PLIST"
done

"$PLIST_BUDDY" -c "Add :Detours.RightPaneRemoteTabs:2:hostID string $REMOTE_HOST_ID" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.RightPaneRemoteTabs:2:path string $REMOTE_API_PATH" "$PLIST"

reset_array "Detours.ScreenshotFileServers"
"$PLIST_BUDDY" -c "Add :Detours.ScreenshotFileServers:0 dict" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.ScreenshotFileServers:0:host string $FILE_SERVER_NAME" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.ScreenshotFileServers:0:protocol string $FILE_SERVER_PROTOCOL" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.ScreenshotFileServers:0:shares array" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.ScreenshotFileServers:0:shares:0 dict" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.ScreenshotFileServers:0:shares:0:name string $FILE_SERVER_SHARE" "$PLIST"
"$PLIST_BUDDY" -c "Add :Detours.ScreenshotFileServers:0:shares:0:path string $REMOTE_API_PATH" "$PLIST"

killall cfprefsd >/dev/null 2>&1 || true
open -g /Applications/Detours.app

echo "Detours configured for README screenshot."
echo "Left pane:  $BASE/acme-corp"
echo "Right pane: $REMOTE_HOST:$REMOTE_API_PATH"
echo "File server: $FILE_SERVER_NAME / $FILE_SERVER_SHARE"
