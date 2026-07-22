#!/bin/bash
# shellcheck disable=SC2030,SC2031 # Layer deadlines are intentionally scoped through subshell exports.

# Three-minute post-build qualification gate. High repetition remains in the
# separately authorized campaign/soak path.

blocking_layer() {
    local layer="$1"
    local budget_seconds="$2"
    shift 2
    local started_epoch ended_epoch duration status
    started_epoch="$(date +%s)"
    set +e
    (
        export QUALIFICATION_BLOCKING_DEADLINE_EPOCH=$((started_epoch + budget_seconds))
        "$@"
    )
    status="$?"
    set -e
    ended_epoch="$(date +%s)"
    duration=$((ended_epoch - started_epoch))
    printf '%s\t%s\t%s\t%s\n' \
        "$layer" "$duration" "$budget_seconds" "$status" >> "$(run_dir)/timing/blocking-layers.tsv"
    (( status == 0 )) || return "$status"
    (( duration <= budget_seconds )) || \
        fail "$layer exceeded its ${budget_seconds}s blocking budget (${duration}s)"
}

run_blocking_swift_filter() {
    local label="$1"
    local filter="$2"
    local log_path status_path status stream_pid diagnostic detected
    log_path="$(run_dir)/logs/blocking-$label.log"
    status_path="$(run_dir)/logs/blocking-$label.status"
    printf '%s\t%s\t%s\n' "$label" "$filter" "1" >> "$(run_dir)/replay.tsv"
    set +e
    (
        DETOURS_QUALIFICATION_REPETITIONS=1 \
            DETOURS_QUALIFICATION_SEED="$QUALIFICATION_SEED" \
            DETOURS_LINUX_TEST_TARGET="$QUALIFICATION_LINUX_TARGET" \
            DETOURS_INTEL_MAC_TEST_TARGET="$QUALIFICATION_INTEL_MAC_TARGET" \
            DETOURS_WINDOWS_TEST_TARGET="$QUALIFICATION_WINDOWS_TARGET" \
            LOCAL_ROOT="$LOCAL_ROOT" \
            APFS_ROOT="$APFS_ROOT" \
            ICLOUD_ROOT="$ICLOUD_ROOT" \
            SMB_ROOT="$SMB_ROOT" \
            QUALIFICATION_ACTIVE_DEADLINE_FILE="$(run_dir)/active-deadline" \
            "$SCRIPT_DIR/qualification-deadline.sh" \
                "$QUALIFICATION_BLOCKING_DEADLINE_EPOCH" \
                swift test --skip-build --filter "$filter" 2>&1 | tee "$log_path"
        printf '%s\n' "${PIPESTATUS[0]}" > "$status_path"
    ) &
    stream_pid=$!
    detected=0
    while kill -0 "$stream_pid" 2>/dev/null; do
        assert_prompt_guard_healthy
        diagnostic="$(grep -Em1 'Test Case .* (failed|skipped)|:[0-9]+: error:|warning:' \
            "$log_path" 2>/dev/null || true)"
        if [[ -n "$diagnostic" ]]; then
            printf '%s\n' "$diagnostic" >&2
            run_cancel
            detected=1
            break
        fi
        sleep 0.2
    done
    wait "$stream_pid" >/dev/null 2>&1 || true
    set -e
    (( detected == 0 )) || return 92
    [[ -f "$status_path" ]] || fail "$label status is missing"
    IFS= read -r status < "$status_path"
    [[ "$status" =~ ^[0-9]+$ ]] || fail "$label status is invalid"
    (( status == 0 )) || return "$status"
    ! grep -En 'Test Case .* skipped|✘.*skipped|warning:' "$log_path" >/dev/null || \
        fail "$label recorded a skip or warning"
}

run_blocking_deterministic_qualification() {
    run_blocking_swift_filter deterministic-contracts \
        'QualificationWorkflowTests|QualificationRunRootTests|RefreshQualificationContractTests|FileListCellTests|FileListDensityTests|ThemeTests|PreferencesTests|EqualSplitIndicatorViewTests|RemoteConnectionTeardownTests|StatusBarProgressTests/(testProgressModeShowsProgressViews|testProgressUpdatesSetsBarValue|testThemeChangeUpdatesColors)|RemoteInlineRenameRefreshTests'
}

run_blocking_pure_refresh() {
    run_blocking_swift_filter pure-refresh 'RefreshQualificationContractTests'
}

run_blocking_provider_refresh() {
    run_blocking_swift_filter provider-refresh \
        'QualificationProviderRefreshTests|RemoteIntegrationTests/(testListDirectoryReturnsExpectedEntries|testWatchDirectoryReceivesInotifyEvent|testIntelMacListDirectoryReturnsExpectedEntries|testIntelMacWatchDirectoryReceivesDarwinEvent)|WindowsRemoteLiveTests/(testConnectListsProfileAndDrives|testWatchEmitsChangeOnServerSideModification)'
}

run_blocking_installed_refresh() {
    local log_dir result_dir
    log_dir="$(run_dir)/workflows/blocking-installed"
    result_dir="$(run_dir)/results/blocking-installed"
    mkdir -p "$log_dir" "$result_dir"

    run_installed_once \
        refresh LOCAL_ROOT 1 \
        "$log_dir/refresh-LOCAL_ROOT" \
        "$result_dir/refresh-LOCAL_ROOT.xcresult"
}

run_blocking_installed_qualification() {
    local log_dir result_dir selected_group remote_target context_name
    log_dir="$(run_dir)/workflows/blocking-installed"
    result_dir="$(run_dir)/results/blocking-installed"
    mkdir -p "$log_dir" "$result_dir"

    while IFS= read -r selected_group; do
        remote_target=""
        context_name="LOCAL_ROOT"
        if [[ "$selected_group" == "connection" ]]; then
            remote_target="$QUALIFICATION_LINUX_TARGET"
            context_name="LINUX_TARGET"
        fi
        run_installed_once \
            "$selected_group" LOCAL_ROOT 1 \
            "$log_dir/$selected_group-$context_name" \
            "$result_dir/$selected_group-$context_name.xcresult" \
            "$remote_target" "$context_name"
    done < <(workflow_groups)
}

prepare_blocking_refresh_bundles() {
    local swift_log
    swift_log="$(run_dir)/logs/blocking-test-build.log"
    DETOURS_LINUX_TEST_TARGET="$QUALIFICATION_LINUX_TARGET" \
        DETOURS_INTEL_MAC_TEST_TARGET="$QUALIFICATION_INTEL_MAC_TARGET" \
        DETOURS_WINDOWS_TEST_TARGET="$QUALIFICATION_WINDOWS_TARGET" \
        swift test list > "$swift_log" 2>&1
    ! grep -En 'warning:' "$swift_log" >/dev/null || fail "blocking test build emitted warnings"
    prepare_installed_test_bundle "$(run_dir)/logs/blocking-ui-build.log"
}

run_blocking_refresh() {
    local started_epoch ended_epoch duration
    trap 'campaign_cleanup_on_exit "$?"' EXIT
    start_console_awake_guard
    run_reset
    run_preflight
    run_build
    start_prompt_guard
    run_prepare_fixtures
    set -a
    # shellcheck disable=SC1090,SC1091
    source "$(run_dir)/fixtures.env"
    set +a
    prepare_blocking_refresh_bundles
    capture_outside_root_snapshots before

    started_epoch="$(date +%s)"
    blocking_layer pure-refresh 10 run_blocking_pure_refresh
    blocking_layer provider-refresh 75 run_blocking_provider_refresh
    blocking_layer installed-refresh 90 run_blocking_installed_refresh
    capture_outside_root_snapshots after
    compare_outside_root_snapshots
    run_cleanup
    verify_qualification_cleanup
    finish_prompt_guard
    ended_epoch="$(date +%s)"
    duration=$((ended_epoch - started_epoch))
    printf 'status=passed\nwall_seconds=%s\nbudget_seconds=180\nbaseline_seconds=2153.055\nspeedup=%s\n' \
        "$duration" "$(awk -v baseline=2153.055 -v actual="$duration" 'BEGIN { printf "%.2f", baseline / actual }')" \
        > "$(run_dir)/timing/blocking-summary.env"
    (( duration <= 180 )) || fail "blocking refresh exceeded its 180s budget (${duration}s)"
    trap - EXIT
}

run_blocking_qualification() {
    local started_epoch ended_epoch duration bundle_count
    trap 'campaign_cleanup_on_exit "$?"' EXIT
    start_console_awake_guard
    run_reset
    run_preflight
    run_build
    start_prompt_guard
    run_prepare_fixtures
    set -a
    # shellcheck disable=SC1090,SC1091
    source "$(run_dir)/fixtures.env"
    set +a
    prepare_blocking_refresh_bundles
    capture_outside_root_snapshots before
    capture_state_observation blocking-before

    started_epoch="$(date +%s)"
    blocking_layer deterministic-contracts 10 run_blocking_deterministic_qualification
    blocking_layer provider-contracts 75 run_blocking_provider_refresh
    blocking_layer installed-workflows 90 run_blocking_installed_qualification
    capture_state_observation blocking-after
    capture_outside_root_snapshots after
    compare_outside_root_snapshots
    run_cleanup
    verify_qualification_cleanup
    finish_prompt_guard
    ended_epoch="$(date +%s)"
    duration=$((ended_epoch - started_epoch))
    bundle_count="$(find "$(run_dir)/results/blocking-installed" -maxdepth 1 \
        -type d -name '*.xcresult' | wc -l | tr -d '[:space:]')"
    [[ "$bundle_count" == "8" ]] || \
        fail "whole-app blocking gate produced $bundle_count installed result bundles instead of 8"
    {
        printf 'status=passed\n'
        printf 'commit=%s\n' "$(canonical_commit)"
        printf 'run_id=%s\n' "$QUALIFICATION_RUN_ID"
        printf 'completed_epoch=%s\n' "$ended_epoch"
        printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'wall_seconds=%s\n' "$duration"
        printf 'budget_seconds=180\n'
        printf 'baseline_seconds=2153.055\n'
        printf 'speedup=%s\n' \
            "$(awk -v baseline=2153.055 -v actual="$duration" 'BEGIN { printf "%.2f", baseline / actual }')"
        printf 'installed_workflows=8\n'
    } > "$(run_dir)/blocking.env"
    (( duration <= 180 )) || fail "whole-app blocking gate exceeded its 180s budget (${duration}s)"
    trap - EXIT
}

require_gate2_authorization() {
    [[ "${DETOURS_QUALIFICATION_GATE2_AUTHORIZED:-}" == "1" ]] || \
        fail "campaign repetition is suspended until Gate 2 authorization; use blocking-refresh"
}
