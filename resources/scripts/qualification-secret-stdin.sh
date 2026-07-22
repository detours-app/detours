#!/bin/bash

# Foundry-side credential adapter. The secret is data on stdin, never shell source or an argument.

set -euo pipefail
set +x

if [[ $# -eq 0 ]]; then
    printf 'qualification-secret-stdin: missing command\n' >&2
    exit 64
fi

smb_secret=""
cleanup_secret() {
    unset smb_secret DETOURS_SMB_TEST_PASSWORD DETOURS_QUALIFICATION_SECRET_TRANSPORT
}
trap cleanup_secret EXIT

IFS= read -r smb_secret || {
    printf 'qualification-secret-stdin: could not read credential\n' >&2
    exit 65
}
[[ -n "$smb_secret" ]] || {
    printf 'qualification-secret-stdin: credential is empty\n' >&2
    exit 66
}

export DETOURS_SMB_TEST_PASSWORD="$smb_secret"
export DETOURS_QUALIFICATION_SECRET_TRANSPORT="stdin-v1"
"$@"

