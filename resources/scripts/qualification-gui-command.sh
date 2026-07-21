#!/bin/bash

# Runs one qualification command inside Foundry's logged-in GUI launchd session.

set -u

[[ $# -ge 3 ]] || exit 64

log_path="$1"
status_path="$2"
shift 2

stdin_fifo=""
if [[ "${1:-}" == "--stdin-fifo" ]]; then
    [[ $# -ge 3 ]] || exit 64
    stdin_fifo="$2"
    shift 2
    [[ "$stdin_fifo" == /* && -p "$stdin_fifo" ]] || exit 65
fi

set +e
if [[ -n "$stdin_fifo" ]]; then
    "$@" < "$stdin_fifo" > "$log_path" 2>&1
else
    "$@" > "$log_path" 2>&1
fi
command_status=$?
set -e

status_tmp="$status_path.tmp.$$"
printf '%s\n' "$command_status" > "$status_tmp"
mv "$status_tmp" "$status_path"
exit "$command_status"
