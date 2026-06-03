#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

SERVER_BINARY="Resources/Servers/detours-server-x86_64-linux"
SERVER_HASH_FILE="Resources/Servers/.cache-hash"
HASH="$(resources/scripts/server-cache-hash.sh)"
DOCKER_IMAGE="${DETOURS_SERVER_DOCKER_IMAGE:-swift:6.2-noble}"
REMOTE_HOST="${DETOURS_DOCKER_HOST:-dockerhost}"
REMOTE_DIR="detours-server-build-$HASH"

mkdir -p Resources/Servers

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" true >/dev/null 2>&1; then
    echo "ERROR dockerhost is unreachable; cannot rebuild detours-server for Linux." >&2
    echo "ERROR Ensure dockerhost is online or provide Resources/Servers/detours-server-x86_64-linux." >&2
    exit 1
fi

ssh "$REMOTE_HOST" "rm -rf /tmp/$REMOTE_DIR && mkdir -p /tmp/$REMOTE_DIR"
tar -czf - Package.swift Server | ssh "$REMOTE_HOST" "tar -xzf - -C /tmp/$REMOTE_DIR"
ssh "$REMOTE_HOST" "cd /tmp/$REMOTE_DIR && docker run --rm -v \"\$PWD:/workspace\" -w /workspace $DOCKER_IMAGE swift build -c release --product detours-server"
scp "$REMOTE_HOST:/tmp/$REMOTE_DIR/.build/release/detours-server" "$SERVER_BINARY"
ssh "$REMOTE_HOST" "rm -rf /tmp/$REMOTE_DIR"
chmod 0755 "$SERVER_BINARY"
echo "$HASH" > "$SERVER_HASH_FILE"

echo "OK built $SERVER_BINARY"
