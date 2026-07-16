#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

{
    for path in Server Shared SharedTests; do
        if [ -d "$path" ]; then
            find "$path" -type f -print0 | sort -z | xargs -0 shasum -a 256
        fi
    done
    shasum -a 256 Tests/ServerArchiveOperationsTests.swift Tests/Helpers/TestHelpers.swift
    grep -nE 'detours-server|DetoursProcess|path: "(Server|Shared|SharedTests)"|products:|targets:' Package.swift
} | shasum -a 256 | awk '{print $1}'
