#!/bin/bash

# Runs one qualification command inside Foundry's logged-in GUI launchd session.

set -u

[[ $# -ge 3 ]] || exit 64

log_path="$1"
status_path="$2"
shift 2

set +e
"$@" > "$log_path" 2>&1
command_status=$?
set -e

status_tmp="$status_path.tmp.$$"
printf '%s\n' "$command_status" > "$status_tmp"
mv "$status_tmp" "$status_path"
exit "$command_status"
