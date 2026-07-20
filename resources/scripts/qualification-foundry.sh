#!/bin/bash

# Spectre-side launcher for credential-bearing Foundry qualification commands.
# The exact credential is removed from the combined SSH output before that output is emitted.

set -euo pipefail
set +x

GET_SECRET="$HOME/dev/scripts/get_secret"

usage() {
    printf 'Usage: resources/scripts/qualification-foundry.sh <qualification arguments...>\n' >&2
}

[[ $# -gt 0 ]] || {
    usage
    exit 64
}

smb_secret=""
# shellcheck disable=SC2329
cleanup_secret() {
    unset smb_secret
}
trap cleanup_secret EXIT
trap 'exit 130' HUP INT TERM

if [[ "$1" == "--self-test" ]]; then
    [[ $# -eq 1 ]] || {
        usage
        exit 64
    }
    smb_secret="qualification-secret-canary-$(uuidgen)"
    # shellcheck disable=SC2016
    remote_command='cd ~/dev/detours && exec resources/scripts/qualification-secret-stdin.sh /bin/bash -c '\''printf "%s\n" "$DETOURS_SMB_TEST_PASSWORD"; test "$DETOURS_QUALIFICATION_SECRET_TRANSPORT" = stdin-v1'\'''
else
    [[ -x "$GET_SECRET" ]] || {
        printf 'qualification-foundry: secret helper is unavailable\n' >&2
        exit 65
    }
    smb_secret="$($GET_SECRET infra DETOURS_SMB_TEST_PASSWORD prd)"
    [[ -n "$smb_secret" ]] || {
        printf 'qualification-foundry: credential is empty\n' >&2
        exit 66
    }

    remote_command="cd ~/dev/detours && exec resources/scripts/qualification-secret-stdin.sh resources/scripts/qualification.sh"
    for argument in "$@"; do
        printf -v quoted_argument '%q' "$argument"
        remote_command+=" $quoted_argument"
    done
fi

redact_secret() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "${line//"$smb_secret"/[REDACTED]}"
    done
}

set +e
# shellcheck disable=SC2029
printf '%s\n' "$smb_secret" \
    | ssh foundry "$remote_command" 2>&1 \
    | redact_secret
launcher_status="${PIPESTATUS[1]}"
set -e

if [[ "$launcher_status" -ne 0 ]]; then
    printf 'qualification-foundry: remote command failed with status %s\n' "$launcher_status" >&2
fi
exit "$launcher_status"
