#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

SERVER_BINARY="Resources/Servers/detours-server-x86_64-linux"
SERVER_HASH_FILE="Resources/Servers/.cache-hash"
HASH="$(resources/scripts/server-cache-hash.sh)"
DOCKER_IMAGE="${DETOURS_SERVER_DOCKER_IMAGE:-swift:6.2-noble}"
REMOTE_HOST="${DETOURS_DOCKER_HOST:-dockerhost}"
REMOTE_DIR="detours-server-build-$HASH"
REMOTE_TMP="/tmp/$REMOTE_DIR"

mkdir -p Resources/Servers

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" true >/dev/null 2>&1; then
    echo "ERROR dockerhost is unreachable; cannot rebuild detours-server for Linux." >&2
    echo "ERROR Ensure dockerhost is online or provide Resources/Servers/detours-server-x86_64-linux." >&2
    exit 1
fi

# These values are intentionally expanded locally before being passed as
# positional parameters to the remote shell.
# shellcheck disable=SC2029
ssh "$REMOTE_HOST" 'rm -rf "$1" && mkdir -p "$1"' sh "$REMOTE_TMP"
# shellcheck disable=SC2029
tar -czf - Package.swift Server | ssh "$REMOTE_HOST" 'tar -xzf - -C "$1"' sh "$REMOTE_TMP"
# shellcheck disable=SC2029
ssh "$REMOTE_HOST" 'cd "$1" && docker run --rm -v "$PWD:/workspace" -w /workspace "$2" swift build -c release --product detours-server' sh "$REMOTE_TMP" "$DOCKER_IMAGE"
scp "$REMOTE_HOST:$REMOTE_TMP/.build/release/detours-server" "$SERVER_BINARY"
# shellcheck disable=SC2029
ssh "$REMOTE_HOST" 'rm -rf "$1"' sh "$REMOTE_TMP"
chmod 0755 "$SERVER_BINARY"
echo "$HASH" > "$SERVER_HASH_FILE"

echo "OK built $SERVER_BINARY"
