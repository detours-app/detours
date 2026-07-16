#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

{
    for path in Server Shared Tests/DetoursProcessTests; do
        if [ -d "$path" ]; then
            find "$path" -type f -print0 | sort -z | xargs -0 shasum -a 256
        fi
    done
    shasum -a 256 Tests/ServerArchiveOperationsTests.swift
    grep -nE 'detours-server|DetoursProcess|path: "(Server|Shared|Tests/DetoursProcessTests)"|products:|targets:' Package.swift
} | shasum -a 256 | awk '{print $1}'
