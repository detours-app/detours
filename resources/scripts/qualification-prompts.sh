#!/bin/bash

# Prompt-safety lifecycle sourced only by qualification.sh.

prompt_log_predicate() {
    printf '%s\n' 'process == "tccd" && eventMessage CONTAINS "display_prompt"'
}

start_prompt_guard() {
    local evidence_dir ready_file attempt
    [[ -z "${QUALIFICATION_PROMPT_GUARD_PID:-}" ]] || fail "prompt sentry is already recorded"
    evidence_dir="$(run_dir)/prompt-guard"
    ready_file="$evidence_dir/ready.env"
    mkdir -p "$evidence_dir"
    [[ ! -e "$ready_file" && ! -e "$evidence_dir/incident.env" ]] || \
        fail "prompt sentry evidence already exists"
    # macOS `log show` accepts this local-time format for --start/--end.
    QUALIFICATION_PROMPT_AUDIT_START="$(date '+%Y-%m-%d %H:%M:%S')"
    "$SCRIPT_DIR/qualification-prompt-guard.sh" live \
        "$$" "$PROJECT_DIR" "$(canonical_commit)" "$QUALIFICATION_RUN_ID" "$evidence_dir" &
    QUALIFICATION_PROMPT_GUARD_PID=$!
    for (( attempt = 1; attempt <= 50; attempt++ )); do
        if [[ -f "$ready_file" ]]; then
            assert_prompt_guard_healthy
            return 0
        fi
        kill -0 "$QUALIFICATION_PROMPT_GUARD_PID" 2>/dev/null || \
            fail "prompt sentry exited before readiness"
        sleep 0.1
    done
    stop_prompt_guard
    fail "prompt sentry did not become ready within 5 seconds"
}

assert_prompt_guard_healthy() {
    local evidence_dir stream_pid visible_pid
    evidence_dir="$(run_dir)/prompt-guard"
    [[ -n "${QUALIFICATION_PROMPT_GUARD_PID:-}" ]] || fail "prompt sentry is not active"
    [[ -f "$evidence_dir/ready.env" ]] || fail "prompt sentry readiness record is missing"
    [[ ! -f "$evidence_dir/incident.env" ]] || fail "prompt sentry recorded an incident"
    kill -0 "$QUALIFICATION_PROMPT_GUARD_PID" 2>/dev/null || fail "prompt sentry is not running"
    stream_pid="$(sed -n 's/^stream_pid=//p' "$evidence_dir/ready.env")"
    [[ "$stream_pid" =~ ^[0-9]+$ && "$stream_pid" -gt 1 ]] || \
        fail "prompt sentry stream PID is invalid"
    kill -0 "$stream_pid" 2>/dev/null || fail "prompt sentry log stream is not running"
    visible_pid="$(sed -n 's/^visible_pid=//p' "$evidence_dir/ready.env")"
    [[ "$visible_pid" =~ ^[0-9]+$ && "$visible_pid" -gt 1 ]] || \
        fail "prompt sentry visible-window PID is invalid"
    kill -0 "$visible_pid" 2>/dev/null || fail "prompt sentry visible-window scan is not running"
}

stop_prompt_guard() {
    local attempt
    [[ -n "${QUALIFICATION_PROMPT_GUARD_PID:-}" ]] || return 0
    if kill -0 "$QUALIFICATION_PROMPT_GUARD_PID" 2>/dev/null; then
        kill -TERM "$QUALIFICATION_PROMPT_GUARD_PID" 2>/dev/null || true
        for (( attempt = 1; attempt <= 50; attempt++ )); do
            kill -0 "$QUALIFICATION_PROMPT_GUARD_PID" 2>/dev/null || break
            sleep 0.1
        done
    fi
    wait "$QUALIFICATION_PROMPT_GUARD_PID" 2>/dev/null || true
    QUALIFICATION_PROMPT_GUARD_PID=""
}

finish_prompt_guard() {
    local evidence_dir audit_end audit_log status visible_prompt xcui_prompt
    evidence_dir="$(run_dir)/prompt-guard"
    audit_end="$(date '+%Y-%m-%d %H:%M:%S')"
    stop_prompt_guard
    [[ -n "${QUALIFICATION_PROMPT_AUDIT_START:-}" ]] || fail "prompt audit start time is missing"
    audit_log="$evidence_dir/post-run-audit.log"
    set +e
    /usr/bin/log show --style compact \
        --start "$QUALIFICATION_PROMPT_AUDIT_START" --end "$audit_end" \
        --predicate "$(prompt_log_predicate)" > "$audit_log" 2> "$evidence_dir/post-run-audit-stderr.log"
    status=$?
    set -e
    (( status == 0 )) || fail "post-run prompt audit failed"
    if grep -F 'display_prompt: called' "$audit_log" >/dev/null; then
        fail "post-run prompt audit found a TCC consent dialog"
    fi
    xcui_prompt="$(find "$(run_dir)" -type f -name StandardOutputAndStandardError.txt -exec \
        grep -hEm1 "Application 'com.apple.UserNotificationCenter'" \
        {} + 2>/dev/null | head -1 || true)"
    [[ -z "$xcui_prompt" ]] || fail "post-run prompt audit found an XCUI interruption: $xcui_prompt"
    set +e
    visible_prompt="$(/usr/bin/osascript -l JavaScript \
        "$SCRIPT_DIR/qualification-visible-prompt-scan.js" 2> "$evidence_dir/visible-final-stderr.log")"
    status=$?
    set -e
    (( status == 0 )) || fail "post-run visible-prompt audit failed"
    [[ -z "$visible_prompt" ]] || fail "post-run prompt audit found a visible dialog: $visible_prompt"
    [[ ! -f "$evidence_dir/incident.env" ]] || fail "prompt sentry recorded an incident"
    {
        printf 'status=passed\n'
        printf 'started_at=%s\n' "$QUALIFICATION_PROMPT_AUDIT_START"
        printf 'ended_at=%s\n' "$audit_end"
        printf 'timezone=%s\n' "$(date +%z)"
        printf 'prompt_events=0\n'
        printf 'tcc_prompt_events=0\n'
        printf 'xcui_interruptions=0\n'
        printf 'visible_prompt_windows=0\n'
    } > "$evidence_dir/result.env"
    QUALIFICATION_PROMPT_AUDIT_START=""
}
