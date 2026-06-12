#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

SERVER_BINARY="resources/Servers/detours-server-x86_64-darwin"
SERVER_HASH_FILE="resources/Servers/.cache-hash-darwin"
HASH="$(resources/scripts/server-cache-hash.sh)"

mkdir -p resources/Servers

swift build -c release --arch x86_64 --product detours-server
cp ".build/x86_64-apple-macosx/release/detours-server" "$SERVER_BINARY"
chmod 0755 "$SERVER_BINARY"
echo "$HASH" > "$SERVER_HASH_FILE"

echo "OK built $SERVER_BINARY"
