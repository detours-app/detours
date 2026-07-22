#!/bin/bash

# Independent Foundry prompt sentry. This process must remain outside XCTest so
# it can stop a run even when the test runner is blocked behind a TCC dialog.

set -euo pipefail

usage() {
    printf 'Usage: %s live <parent-pid> <project-dir> <commit> <run-id> <evidence-dir>\n' "$0" >&2
    printf '       %s replay <input-log> <evidence-dir>\n' "$0" >&2
    exit 64
}

write_incident() {
    local incident_type="$1"
    local message="$2"
    local destination="$3"
    local temporary="$destination.tmp.$$"
    {
        printf 'status=failed\n'
        printf 'type=%s\n' "$incident_type"
        printf 'detected_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'message=%s\n' "$message"
    } > "$temporary"
    mv "$temporary" "$destination"
}

contains_prompt_event() {
    [[ "$1" == *'display_prompt: called'* ]] \
        || [[ "$1" == visible_prompt:\ owner=UserNotificationCenter* ]] \
        || [[ "$1" =~ Found\ [1-9][0-9]*\ interrupting\ element ]] \
        || [[ "$1" == *"Application 'com.apple.UserNotificationCenter'"* ]] \
        || [[ "$1" == runner_network_violation:* ]]
}

runner_network_violation() {
    local runner_pid helper
    while IFS= read -r runner_pid; do
        [[ "$runner_pid" =~ ^[0-9]+$ ]] || continue
        helper="$(ps -axo pid=,ppid=,comm= | awk -v parent="$runner_pid" '
            $2 == parent && $3 ~ /\/(ssh|sftp|scp|curl|nc)$/ { print $1 " " $3; exit }
        ')"
        if [[ -n "$helper" ]]; then
            printf 'runner_network_violation: runner=%s helper=%s\n' "$runner_pid" "$helper"
            return 0
        fi
    done < <(ps -axo pid=,comm= | awk '$2 ~ /\/DetoursUITests-Runner$/ { print $1 }')
    return 1
}

run_replay() {
    local input_log="$1"
    local evidence_dir="$2"
    local line
    [[ -r "$input_log" ]] || usage
    mkdir -p "$evidence_dir"
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line" >> "$evidence_dir/replay.log"
        if contains_prompt_event "$line"; then
            write_incident prompt_detected "$line" "$evidence_dir/incident.env"
            return 90
        fi
    done < "$input_log"
    printf 'status=passed\nchecked_at=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$evidence_dir/replay-result.env"
}

run_live() {
    local parent_pid="$1"
    local project_dir="$2"
    local commit="$3"
    local run_id="$4"
    local evidence_dir="$5"
    local stream_pid=""
    local visible_pid=""
    local visible_ready="$evidence_dir/visible-ready.env"
    local visible_incident="$evidence_dir/visible-incident.log"
    local tccd_log="$evidence_dir/live.log"
    local visible_scan="$project_dir/resources/scripts/qualification-visible-prompt-scan.js"
    local line attempt

    [[ "$parent_pid" =~ ^[0-9]+$ && "$parent_pid" -gt 1 ]] || usage
    [[ -d "$project_dir/.git" ]] || usage
    case "$evidence_dir" in
        "$project_dir"/.build/qualification/*) ;;
        *) usage ;;
    esac
    kill -0 "$parent_pid" 2>/dev/null || exit 1
    [[ -r "$visible_scan" ]] || exit 1
    mkdir -p "$evidence_dir"
    [[ ! -e "$visible_ready" && ! -e "$visible_incident" && ! -e "$tccd_log" ]] || exit 1

    cleanup() {
        if [[ -n "$stream_pid" ]] && kill -0 "$stream_pid" 2>/dev/null; then
            kill -TERM "$stream_pid" 2>/dev/null || true
            wait "$stream_pid" 2>/dev/null || true
        fi
        if [[ -n "$visible_pid" ]] && kill -0 "$visible_pid" 2>/dev/null; then
            kill -TERM "$visible_pid" 2>/dev/null || true
            wait "$visible_pid" 2>/dev/null || true
        fi
    }
    trap 'cleanup; exit 0' HUP INT TERM
    trap cleanup EXIT

    /usr/bin/log stream --style compact --level info \
        --predicate 'process == "tccd" && eventMessage CONTAINS "display_prompt"' \
        > "$tccd_log" 2> "$evidence_dir/stream-stderr.log" &
    stream_pid=$!

    (
        while true; do
            line="$(/usr/bin/osascript -l JavaScript "$visible_scan")" || exit 92
            if [[ -n "$line" ]]; then
                printf '%s\n' "$line" > "$visible_incident.tmp.$$"
                mv "$visible_incident.tmp.$$" "$visible_incident"
                exit 90
            fi
            if [[ ! -f "$visible_ready" ]]; then
                printf 'status=ready\nchecked_at=%s\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$visible_ready.tmp.$$"
                mv "$visible_ready.tmp.$$" "$visible_ready"
            fi
            sleep 0.2
        done
    ) > "$evidence_dir/visible-stdout.log" 2> "$evidence_dir/visible-stderr.log" &
    visible_pid=$!

    for (( attempt = 1; attempt <= 50; attempt++ )); do
        if [[ -f "$visible_incident" ]]; then
            line="$(head -1 "$visible_incident")"
            write_incident prompt_detected "$line" "$evidence_dir/incident.env"
            "$project_dir/resources/scripts/qualification.sh" cancel \
                --commit "$commit" --run-id "$run_id" \
                > "$evidence_dir/cancel.log" 2>&1 || true
            kill -TERM "$parent_pid" 2>/dev/null || true
            exit 90
        fi
        [[ -f "$visible_ready" ]] && break
        kill -0 "$stream_pid" 2>/dev/null || exit 91
        kill -0 "$visible_pid" 2>/dev/null || exit 91
        sleep 0.1
    done
    [[ -f "$visible_ready" ]] || exit 91
    {
        printf 'status=ready\n'
        printf 'guard_pid=%s\n' "$$"
        printf 'stream_pid=%s\n' "$stream_pid"
        printf 'visible_pid=%s\n' "$visible_pid"
        printf 'parent_pid=%s\n' "$parent_pid"
        printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$evidence_dir/ready.env"

    while kill -0 "$parent_pid" 2>/dev/null; do
        line="$(grep -F -m1 'display_prompt: called' "$tccd_log" 2>/dev/null || true)"
        if [[ -z "$line" && -f "$visible_incident" ]]; then
            line="$(head -1 "$visible_incident")"
        fi
        if [[ -z "$line" ]]; then
            line="$(runner_network_violation || true)"
        fi
        if [[ -n "$line" ]] && contains_prompt_event "$line"; then
            write_incident prompt_detected "$line" "$evidence_dir/incident.env"
            "$project_dir/resources/scripts/qualification.sh" cancel \
                --commit "$commit" --run-id "$run_id" \
                > "$evidence_dir/cancel.log" 2>&1 || true
            kill -TERM "$parent_pid" 2>/dev/null || true
            exit 90
        fi
        if ! kill -0 "$stream_pid" 2>/dev/null || ! kill -0 "$visible_pid" 2>/dev/null; then
            write_incident guard_failed \
                'a prompt-detection channel ended while the qualification parent was active' \
                "$evidence_dir/incident.env"
            "$project_dir/resources/scripts/qualification.sh" cancel \
                --commit "$commit" --run-id "$run_id" \
                > "$evidence_dir/cancel.log" 2>&1 || true
            kill -TERM "$parent_pid" 2>/dev/null || true
            exit 91
        fi
        sleep 0.1
    done
}

case "${1:-}" in
    live)
        [[ $# -eq 6 ]] || usage
        run_live "$2" "$3" "$4" "$5" "$6"
        ;;
    replay)
        [[ $# -eq 3 ]] || usage
        run_replay "$2" "$3"
        ;;
    *) usage ;;
esac
