#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

SERVER_BINARY="resources/Servers/detours-server-x86_64-linux"
SERVER_HASH_FILE="resources/Servers/.cache-hash-linux"
HASH="$(resources/scripts/server-cache-hash.sh)"
DOCKER_IMAGE="${DETOURS_SERVER_DOCKER_IMAGE:-swift:6.2-noble}"
REMOTE_HOST="devtest"
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
    echo "ERROR devtest is unreachable; cannot rebuild detours-server for Linux." >&2
    echo "ERROR Ensure devtest is online or provide resources/Servers/detours-server-x86_64-linux." >&2
    exit 1
fi

# shellcheck disable=SC2029
ssh "$REMOTE_HOST" "rm -rf $REMOTE_TMP_Q && mkdir -p $REMOTE_TMP_Q"
# shellcheck disable=SC2029
COPYFILE_DISABLE=1 tar --no-xattrs -czf - \
    Server \
    Shared \
    SevenZip \
    ArchiveStreamBridge \
    RemoteOperationSupport \
    FilesystemPrimitives \
    LinuxStaticFoundationGuard \
    Tests/DetoursProcessTests \
    resources/fixtures/rar \
    Tests/ServerArchiveOperationsTests.swift \
    Tests/ServerArchiveStreamTests.swift \
    Tests/ServerOperationArchiveTests.swift \
    Tests/ServerOperationExtractionTests.swift \
    Tests/ServerLegacyMutationTests.swift \
    Tests/ServerAcceptedMutationTests.swift \
    Tests/OperationFilesystemTests.swift \
    Tests/OperationPublicationTests.swift \
    Tests/OperationContentProofTests.swift \
    Tests/OperationManifestTests.swift \
    Tests/ServerOperationServiceTests.swift \
    Tests/ServerOperationTreeCopyTests.swift \
    Tests/ServerOperationPreparationTests.swift \
    Tests/ServerOperationPermanentDeleteTests.swift \
    Tests/ServerOperationTrashTests.swift \
    Tests/ServerOperationBackupTests.swift \
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
            name: "SevenZip", path: "SevenZip",
            exclude: ["README.md", "License.txt", "copying.txt", "unRarLicense.txt"]
        ),
        .target(name: "ArchiveStreamBridge", dependencies: ["SevenZip"], path: "ArchiveStreamBridge"),
        .target(name: "FilesystemPrimitives", path: "FilesystemPrimitives"),
        .target(
            name: "RemoteOperationSupport",
            dependencies: ["FilesystemPrimitives"],
            path: "RemoteOperationSupport"
        ),
        .target(
            name: "DetoursProcess",
            dependencies: ["ArchiveStreamBridge"],
            path: "Shared",
            linkerSettings: [.linkedLibrary("util")]
        ),
        .target(
            name: "LinuxStaticFoundationGuard",
            path: "LinuxStaticFoundationGuard"
        ),
        .executableTarget(
            name: "detours-server",
            dependencies: ["DetoursProcess", "RemoteOperationSupport", "LinuxStaticFoundationGuard"],
            path: "Server"
        ),
        .testTarget(
            name: "DetoursProcessTests",
            dependencies: ["DetoursProcess"],
            path: "Tests/DetoursProcessTests"
        ),
        .testTarget(
            name: "ServerArchiveOperationsTests",
            dependencies: ["detours-server", "DetoursProcess", "RemoteOperationSupport"],
            path: "Tests",
            exclude: ["DetoursProcessTests"],
            sources: [
                "ServerArchiveOperationsTests.swift", "ServerArchiveStreamTests.swift", "ServerOperationArchiveTests.swift", "ServerOperationExtractionTests.swift", "ServerLegacyMutationTests.swift", "ServerAcceptedMutationTests.swift",
                "OperationFilesystemTests.swift", "OperationPublicationTests.swift",
                "OperationContentProofTests.swift", "OperationManifestTests.swift", "ServerOperationServiceTests.swift", "ServerOperationTrashTests.swift",
                "ServerOperationBackupTests.swift", "ServerOperationTreeCopyTests.swift", "ServerOperationPreparationTests.swift",
                "ServerOperationPermanentDeleteTests.swift"
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
EOF
# shellcheck disable=SC2029
ssh "$REMOTE_HOST" "cd $REMOTE_TMP_Q && docker run --rm -e HOME=/tmp -v \"\$PWD:/workspace\" -w /workspace $DOCKER_IMAGE_Q sh -c 'owner=\"\$(stat -c %u:%g /workspace)\"; trap \"chown -R \$owner /workspace\" EXIT; apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--path-include=/usr/share/man/\\* install -y -qq zip unzip p7zip-full bzip2 xz-utils && swift test --filter DetoursProcessTests && swift test --filter ServerArchiveOperationsTests && swift build -c release --product detours-server -Xswiftc -static-stdlib'"
scp "$REMOTE_HOST:$REMOTE_TMP/.build/release/detours-server" "$SERVER_BINARY"
chmod 0755 "$SERVER_BINARY"
echo "$HASH" > "$SERVER_HASH_FILE"

echo "OK built $SERVER_BINARY"
