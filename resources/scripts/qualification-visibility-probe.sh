#!/bin/bash

# Live failure-visibility contract probe sourced only by qualification.sh.

run_failure_visibility_probe() {
    local control_root result_bundle probe_log descendant_pid_file late_marker lifecycle_file
    local started_epoch ended_epoch probe_status descendant_pid attempt descendant_command
    local -a pipeline_status

    trap 'campaign_cleanup_on_exit "$?"' EXIT
    start_console_awake_guard
    run_reset
    run_preflight LOCAL_ROOT
    start_prompt_guard

    control_root="$RUNNER_CONTROL_PARENT/$QUALIFICATION_COMMIT/$QUALIFICATION_RUN_ID/visibility-probe-LOCAL_ROOT"
    result_bundle="$(run_dir)/results/visibility-probe.xcresult"
    probe_log="$(run_dir)/logs/visibility-probe.log"
    descendant_pid_file="$(run_dir)/state/visibility-probe-descendant.pid"
    late_marker="$(run_dir)/state/visibility-probe-iteration-two-ran"
    lifecycle_file="$(run_dir)/state/visibility-probe-child-lifecycle.txt"
    mkdir -p "$control_root" "$(dirname "$probe_log")"

    started_epoch="$(date +%s)"
    if (
        QUALIFICATION_GUI_RESULT_BUNDLE="$result_bundle" \
            run_gui_command "$(run_dir)/logs/visibility-probe.raw.log" \
                /bin/bash "$SCRIPT_DIR/qualification-visibility-probe-child.sh" \
                "$control_root" "$result_bundle" "$descendant_pid_file" \
                "$late_marker" "$lifecycle_file"
    ) 2>&1 | tee "$probe_log"; then
        probe_status=0
    else
        pipeline_status=("${PIPESTATUS[@]}")
        probe_status="${pipeline_status[0]}"
    fi
    ended_epoch="$(date +%s)"

    (( probe_status != 0 )) || fail "visibility probe did not fail"
    (( ended_epoch - started_epoch <= 8 )) || \
        fail "visibility probe took longer than 8 seconds to report the deliberate assertion"
    grep -F \
        'XCTAssertTrue failed - deliberate live failure visibility probe' \
        "$probe_log" >/dev/null || \
        fail "visibility probe did not report the live XCTest assertion"
    grep -F \
        'qualification: installed run reported a test failure' \
        "$probe_log" >/dev/null || \
        fail "visibility probe did not report parent cancellation"
    [[ ! -e "$late_marker" ]] || \
        fail "visibility probe allowed iteration two to execute"
    [[ -f "$descendant_pid_file" ]] || \
        fail "visibility probe did not record its descendant PID"
    IFS= read -r descendant_pid < "$descendant_pid_file"
    [[ "$descendant_pid" =~ ^[0-9]+$ && "$descendant_pid" -gt 1 ]] || \
        fail "visibility probe recorded an invalid descendant PID"
    for (( attempt = 1; attempt <= 50; attempt++ )); do
        kill -0 "$descendant_pid" 2>/dev/null || break
        /bin/sleep 0.1
    done
    if kill -0 "$descendant_pid" 2>/dev/null; then
        descendant_command="$(ps -p "$descendant_pid" -o command= 2>/dev/null || true)"
        if [[ "$descendant_command" == "/bin/sleep 300" ]]; then
            kill -TERM "$descendant_pid" 2>/dev/null || true
        fi
        fail "visibility probe left its descendant running: $descendant_pid $descendant_command"
    fi
    [[ ! -e "$(run_dir)/active-gui-job" ]] || \
        fail "visibility probe left an active GUI job record"

    run_cleanup
    verify_qualification_cleanup
    finish_prompt_guard
    {
        printf 'status=passed\n'
        printf 'commit=%s\n' "$(canonical_commit)"
        printf 'failure_report_seconds=%s\n' "$((ended_epoch - started_epoch))"
        printf 'first_progress_count=1\n'
        printf 'later_iterations=0\n'
        printf 'descendants_remaining=0\n'
        printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$(run_dir)/visibility.env"
    trap - EXIT
}
