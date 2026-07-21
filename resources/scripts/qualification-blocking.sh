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
    local log_path status
    log_path="$(run_dir)/logs/blocking-$label.log"
    printf '%s\t%s\t%s\n' "$label" "$filter" "1" >> "$(run_dir)/replay.tsv"
    set +e
    DETOURS_LINUX_TEST_TARGET="$QUALIFICATION_LINUX_TARGET" \
        DETOURS_INTEL_MAC_TEST_TARGET="$QUALIFICATION_INTEL_MAC_TARGET" \
        DETOURS_WINDOWS_TEST_TARGET="$QUALIFICATION_WINDOWS_TARGET" \
        LOCAL_ROOT="$LOCAL_ROOT" \
        APFS_ROOT="$APFS_ROOT" \
        ICLOUD_ROOT="$ICLOUD_ROOT" \
        SMB_ROOT="$SMB_ROOT" \
        "$SCRIPT_DIR/qualification-deadline.sh" \
            "$QUALIFICATION_BLOCKING_DEADLINE_EPOCH" \
            swift test --skip-build --filter "$filter" 2>&1 | tee "$log_path"
    status="${PIPESTATUS[0]}"
    set -e
    (( status == 0 )) || return "$status"
    ! grep -En 'Test Case .* skipped|✘.*skipped' "$log_path" >/dev/null || \
        fail "$label recorded a skipped test"
}

run_blocking_pure_refresh() {
    run_blocking_swift_filter pure-refresh 'RefreshQualificationContractTests'
}

run_blocking_provider_refresh() {
    run_blocking_swift_filter provider-refresh \
        'QualificationProviderRefreshTests|RemoteIntegrationTests/(testListDirectoryReturnsExpectedEntries|testWatchDirectoryReceivesInotifyEvent|testIntelMacListDirectoryReturnsExpectedEntries|testIntelMacWatchDirectoryReceivesDarwinEvent)|WindowsRemoteLiveTests/(testConnectListsProfileAndDrives|testWatchEmitsChangeOnServerSideModification)'
}

run_blocking_storage_permissions() {
    local log_dir result_dir context_name
    log_dir="$(run_dir)/workflows/blocking-permissions"
    result_dir="$(run_dir)/results/blocking-permissions"
    mkdir -p "$log_dir" "$result_dir"

    for context_name in ICLOUD_ROOT SMB_ROOT; do
        run_installed_once \
            refresh "$context_name" 1 \
            "$log_dir/$context_name" \
            "$result_dir/$context_name.xcresult" \
            "" "$context_name" \
            'QualificationRefreshUITests/testStoragePermissionPreflight'
    done
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
    run_reset
    run_preflight
    run_build
    run_prepare_fixtures
    set -a
    # shellcheck disable=SC1090,SC1091
    source "$(run_dir)/fixtures.env"
    set +a
    prepare_blocking_refresh_bundles
    capture_outside_root_snapshots before

    started_epoch="$(date +%s)"
    blocking_layer storage-permissions 30 run_blocking_storage_permissions
    blocking_layer pure-refresh 10 run_blocking_pure_refresh
    blocking_layer provider-refresh 60 run_blocking_provider_refresh
    blocking_layer installed-refresh 90 run_blocking_installed_refresh
    capture_outside_root_snapshots after
    compare_outside_root_snapshots
    run_cleanup
    verify_qualification_cleanup
    ended_epoch="$(date +%s)"
    duration=$((ended_epoch - started_epoch))
    printf 'status=passed\nwall_seconds=%s\nbudget_seconds=180\nbaseline_seconds=2153.055\nspeedup=%s\n' \
        "$duration" "$(awk -v baseline=2153.055 -v actual="$duration" 'BEGIN { printf "%.2f", baseline / actual }')" \
        > "$(run_dir)/timing/blocking-summary.env"
    (( duration <= 180 )) || fail "blocking refresh exceeded its 180s budget (${duration}s)"
    trap - EXIT
}

require_gate2_authorization() {
    [[ "${DETOURS_QUALIFICATION_GATE2_AUTHORIZED:-}" == "1" ]] || \
        fail "campaign repetition is suspended until Gate 2 authorization; use blocking-refresh"
}
