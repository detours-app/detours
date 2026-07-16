#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

SERVER_BINARY="resources/Servers/detours-server-x86_64-linux"
SERVER_HASH_FILE="resources/Servers/.cache-hash-linux"
HASH="$(resources/scripts/server-cache-hash.sh)"
DOCKER_IMAGE="${DETOURS_SERVER_DOCKER_IMAGE:-swift:6.2-noble}"
REMOTE_HOST="${DETOURS_DOCKER_HOST:-dockerhost}"
REMOTE_DIR="detours-server-build-$HASH-$(date +%s)-$$"
REMOTE_TMP="/tmp/$REMOTE_DIR"
REMOTE_TMP_Q="$(printf '%q' "$REMOTE_TMP")"
DOCKER_IMAGE_Q="$(printf '%q' "$DOCKER_IMAGE")"

cleanup() {
    # shellcheck disable=SC2029
    ssh "$REMOTE_HOST" "rm -rf $REMOTE_TMP_Q" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p resources/Servers

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" true >/dev/null 2>&1; then
    echo "ERROR dockerhost is unreachable; cannot rebuild detours-server for Linux." >&2
    echo "ERROR Ensure dockerhost is online or provide resources/Servers/detours-server-x86_64-linux." >&2
    exit 1
fi

# shellcheck disable=SC2029
ssh "$REMOTE_HOST" "rm -rf $REMOTE_TMP_Q && mkdir -p $REMOTE_TMP_Q"
# shellcheck disable=SC2029
COPYFILE_DISABLE=1 tar --no-xattrs -czf - \
    Server \
    Shared \
    SharedTests \
    Tests/ServerArchiveOperationsTests.swift \
    Tests/Helpers/TestHelpers.swift \
    | ssh "$REMOTE_HOST" "tar -xzf - -C $REMOTE_TMP_Q"
# shellcheck disable=SC2029
ssh "$REMOTE_HOST" "cat > $REMOTE_TMP_Q/Package.swift" <<'EOF'
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DetoursServer",
    products: [
        .executable(name: "detours-server", targets: ["detours-server"]),
    ],
    targets: [
        .target(
            name: "DetoursProcess",
            path: "Shared",
            linkerSettings: [.linkedLibrary("util")]
        ),
        .executableTarget(
            name: "detours-server",
            dependencies: ["DetoursProcess"],
            path: "Server"
        ),
        .testTarget(
            name: "DetoursProcessTests",
            dependencies: ["DetoursProcess"],
            path: "SharedTests"
        ),
        .testTarget(
            name: "ServerArchiveOperationsTests",
            dependencies: ["detours-server", "DetoursProcess"],
            path: "Tests",
            sources: ["ServerArchiveOperationsTests.swift", "Helpers/TestHelpers.swift"]
        ),
    ]
)
EOF
# shellcheck disable=SC2029
ssh "$REMOTE_HOST" "cd $REMOTE_TMP_Q && docker run --rm --user \"\$(id -u):\$(id -g)\" -e HOME=/tmp -v \"\$PWD:/workspace\" -w /workspace $DOCKER_IMAGE_Q sh -c 'swift test --filter DetoursProcessTests && swift test --filter ServerArchiveOperationsTests && swift build -c release --product detours-server -Xswiftc -static-stdlib'"
scp "$REMOTE_HOST:$REMOTE_TMP/.build/release/detours-server" "$SERVER_BINARY"
chmod 0755 "$SERVER_BINARY"
echo "$HASH" > "$SERVER_HASH_FILE"

echo "OK built $SERVER_BINARY"
