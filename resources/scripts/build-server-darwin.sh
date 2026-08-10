#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

SERVER_BINARY="resources/Servers/detours-server-x86_64-darwin"
SERVER_HASH_FILE="resources/Servers/.cache-hash-darwin"
HASH="$(resources/scripts/server-cache-hash.sh)"

mkdir -p resources/Servers

# Universal, so the helper runs natively on both Intel and Apple Silicon. The
# tests that exercise the real helper run on an Apple Silicon machine, and an
# Intel-only binary meant they were skipped there rather than run under
# emulation, which hid real faults in the helper for as long as they were.
swift build -c release --arch x86_64 --arch arm64 --product detours-server
cp ".build/apple/Products/Release/detours-server" "$SERVER_BINARY"
/usr/bin/lipo -info "$SERVER_BINARY"
chmod 0755 "$SERVER_BINARY"
echo "$HASH" > "$SERVER_HASH_FILE"

echo "OK built $SERVER_BINARY"
