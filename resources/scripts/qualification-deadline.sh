#!/bin/bash

# Runs one command in its own process group and terminates the whole group at an
# absolute epoch deadline. Blocking and authorized campaign layers use the same
# descendant-aware termination path.

set -u

[[ $# -ge 2 && "$1" =~ ^[0-9]+$ ]] || exit 64

deadline_epoch="$1"
shift
remaining=$((deadline_epoch - $(date +%s)))
(( remaining > 0 )) || exit 124
active_deadline_file="${QUALIFICATION_ACTIVE_DEADLINE_FILE:-}"
if [[ -n "$active_deadline_file" ]]; then
    [[ "$active_deadline_file" == /* && -d "$(dirname "$active_deadline_file")" \
        && ! -e "$active_deadline_file" ]] || exit 65
fi

set -m
"$@" &
command_pid=$!

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup_active_deadline_file() {
    if [[ -n "$active_deadline_file" && -f "$active_deadline_file" \
        && "$(<"$active_deadline_file")" == "$$" ]]; then
        rm -f -- "$active_deadline_file"
    fi
}
trap cleanup_active_deadline_file EXIT
if [[ -n "$active_deadline_file" ]]; then
    printf '%s\n' "$$" > "$active_deadline_file"
fi

descendant_pids() {
    local parent_pid="$1"
    local child_pid
    while IFS= read -r child_pid; do
        [[ -n "$child_pid" ]] || continue
        descendant_pids "$child_pid"
        printf '%s\n' "$child_pid"
    done < <(pgrep -P "$parent_pid" 2>/dev/null || true)
}

# shellcheck disable=SC2329 # Invoked by terminate_groups through the signal trap.
signal_command_tree() {
    local signal_name="$1"
    local descendants child_pid
    descendants="$(descendant_pids "$command_pid")"
    while IFS= read -r child_pid; do
        [[ -n "$child_pid" ]] || continue
        kill -"$signal_name" "$child_pid" 2>/dev/null || true
    done <<< "$descendants"
    kill -"$signal_name" -- "-$command_pid" 2>/dev/null || true
}

(
    sleep "$remaining"
    descendants="$(descendant_pids "$command_pid")"
    while IFS= read -r child_pid; do
        [[ -n "$child_pid" ]] || continue
        kill -TERM "$child_pid" 2>/dev/null || true
    done <<< "$descendants"
    kill -TERM -- "-$command_pid" 2>/dev/null || true
    sleep 1
    while IFS= read -r child_pid; do
        [[ -n "$child_pid" ]] || continue
        kill -KILL "$child_pid" 2>/dev/null || true
    done <<< "$descendants"
    kill -KILL -- "-$command_pid" 2>/dev/null || true
    exit 124
) &
watchdog_pid=$!
set +m

# shellcheck disable=SC2329 # Invoked by the signal trap below.
terminate_groups() {
    signal_command_tree TERM
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || true
}
trap 'terminate_groups; exit 130' HUP INT TERM

set +e
wait "$command_pid"
status=$?
set -e
if (( $(date +%s) >= deadline_epoch )); then
    set +e
    wait "$watchdog_pid" 2>/dev/null
    watchdog_status=$?
    set -e
    (( watchdog_status == 124 )) && status=124
else
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
fi
trap - HUP INT TERM

exit "$status"
