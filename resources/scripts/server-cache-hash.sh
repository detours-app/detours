#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

{
    if [ -d Server ]; then
        find Server -type f -print0 | sort -z | xargs -0 shasum -a 256
    fi
    grep -nE 'detours-server|path: "Server"|products:|targets:' Package.swift
} | shasum -a 256 | awk '{print $1}'
