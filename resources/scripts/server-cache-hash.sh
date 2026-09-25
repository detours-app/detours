#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

{
    for DETOURS_PATH in Server Shared RemoteOperationSupport FilesystemPrimitives LinuxStaticFoundationGuard Tests/DetoursProcessTests; do
        if [ -d "$DETOURS_PATH" ]; then
            find "$DETOURS_PATH" -type f -print0 | sort -z | xargs -0 shasum -a 256
        fi
    done
    shasum -a 256 Tests/ServerArchiveOperationsTests.swift
    shasum -a 256 Tests/OperationFilesystemTests.swift
    shasum -a 256 Tests/OperationPublicationTests.swift
    shasum -a 256 Tests/OperationContentProofTests.swift
    shasum -a 256 Tests/OperationManifestTests.swift
    shasum -a 256 Tests/ServerOperationServiceTests.swift
    shasum -a 256 Tests/ServerOperationTreeCopyTests.swift
    shasum -a 256 Tests/ServerOperationPreparationTests.swift
    shasum -a 256 Tests/ServerOperationTrashTests.swift
    shasum -a 256 Tests/ServerOperationBackupTests.swift
    shasum -a 256 resources/scripts/build-server-linux.sh
    grep -nE 'detours-server|DetoursProcess|path: "(Server|Shared|Tests/DetoursProcessTests)"|products:|targets:' Package.swift
} | shasum -a 256 | awk '{print $1}'
