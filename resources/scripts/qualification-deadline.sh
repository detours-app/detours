#!/bin/bash

# Runs one command in its own process group and terminates the whole group at an
# absolute epoch deadline. This is used only by the bounded qualification gate.

set -u

[[ $# -ge 2 && "$1" =~ ^[0-9]+$ ]] || exit 64

deadline_epoch="$1"
shift
remaining=$((deadline_epoch - $(date +%s)))
(( remaining > 0 )) || exit 124

set -m
"$@" &
command_pid=$!
(
    sleep "$remaining"
    kill -TERM -- "-$command_pid" 2>/dev/null || exit 0
    sleep 1
    kill -KILL -- "-$command_pid" 2>/dev/null || true
) &
watchdog_pid=$!
set +m

# shellcheck disable=SC2329 # Invoked by the signal trap below.
terminate_groups() {
    kill -TERM -- "-$command_pid" 2>/dev/null || true
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || true
}
trap 'terminate_groups; exit 130' HUP INT TERM

set +e
wait "$command_pid"
status=$?
set -e
kill -TERM -- "-$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
trap - HUP INT TERM

exit "$status"
