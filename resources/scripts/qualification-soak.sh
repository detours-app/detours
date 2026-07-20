#!/bin/bash

# Twelve-hour installed-app soak sourced only by qualification.sh.

SOAK_DURATION_SECONDS=43200

soak_cleanup_on_exit() {
    local original_status="$1"
    set +e
    rm -f -- "$QUALIFICATION_ROOT/.soak-active"
    run_cleanup
    local cleanup_status=$?
    if (( cleanup_status == 0 )); then
        verify_qualification_cleanup
        cleanup_status=$?
    fi
    if (( cleanup_status != 0 )); then
        printf 'qualification: soak cleanup failed with status %s\n' "$cleanup_status" >&2
        exit "$cleanup_status"
    fi
    exit "$original_status"
}

write_soak_marker() {
    [[ ! -e "$QUALIFICATION_ROOT/.soak-active" ]] || fail "a qualification soak is already active"
    {
        printf 'commit=%s\n' "$(canonical_commit)"
        printf 'run_id=%s\n' "$QUALIFICATION_RUN_ID"
        printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'duration_seconds=%s\n' "$SOAK_DURATION_SECONDS"
    } > "$QUALIFICATION_ROOT/.soak-active"
}

request_soak_pane_state() {
    local root="$1"
    local pane="$2"
    local destination="$3"
    local request_id request_file response_file observed_id
    request_id="soak-$QUALIFICATION_RUN_ID-$pane-$(date +%s)"
    request_file="$root/.detours-pane-state-request.json"
    response_file="$root/.detours-pane-state-response.json"
    printf '{"id":"%s","pane":"%s"}\n' "$request_id" "$pane" > "$request_file"
    local _
    for _ in {1..50}; do
        if [[ -f "$response_file" ]]; then
            observed_id="$(plutil -extract id raw -o - "$response_file" 2>/dev/null || true)"
            if [[ "$observed_id" == "$request_id" ]]; then
                cp "$response_file" "$destination"
                return
            fi
        fi
        sleep 0.1
    done
    fail "installed app did not return $pane pane state within 5 seconds"
}

require_quiescent_pane_state() {
    local state_file="$1"
    local key value
    for key in operationRunning refreshInFlight navigationLoadInFlight loadingVisible; do
        value="$(plutil -extract "$key" raw -o - "$state_file")"
        [[ "$value" == "false" ]] || fail "soak state is not quiescent: $key=$value"
    done
    value="$(plutil -extract selectedTabIndex raw -o - "$state_file")"
    (( value >= 0 )) || fail "soak state has no selected tab"
}

sample_soak_health() {
    local cycle="$1"
    local group="$2"
    local root_name="$3"
    local root_path="$4"
    local sample_dir partial_path left_state right_state left_active right_active
    sample_dir="$(run_dir)/state/soak/cycle-$cycle/$group-$root_name"
    mkdir -p "$sample_dir"

    pgrep -fl 'Detours|detours-server|xctest|xcodebuild' > "$sample_dir/processes.txt" || true
    mount > "$sample_dir/mounts.txt"
    [[ -d "$root_path" ]] || fail "soak fixture disappeared: $root_path"
    partial_path="$(find "$root_path" -type f \( -name '*.partial' -o -name '*.detours-partial*' \) -print -quit)"
    [[ -z "$partial_path" ]] || fail "soak found a partial file: $partial_path"
    ! pgrep -x xcodebuild >/dev/null 2>&1 || fail "xcodebuild remained after an installed workflow"
    ! pgrep -x xctest >/dev/null 2>&1 || fail "xctest remained after an installed workflow"

    left_state="$sample_dir/left.json"
    right_state="$sample_dir/right.json"
    request_soak_pane_state "$root_path" left "$left_state"
    request_soak_pane_state "$root_path" right "$right_state"
    require_quiescent_pane_state "$left_state"
    require_quiescent_pane_state "$right_state"
    left_active="$(plutil -extract activePane raw -o - "$left_state")"
    right_active="$(plutil -extract activePane raw -o - "$right_state")"
    [[ "$left_active $right_active" == "true false" || "$left_active $right_active" == "false true" ]] || \
        fail "soak requires exactly one active pane (left=$left_active right=$right_active)"
    printf 'sampled_at=%s\ncycle=%s\ngroup=%s\nroot=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cycle" "$group" "$root_name" > "$sample_dir/health.env"
}

run_twelve_hour_soak() {
    run_reset
    run_preflight
    run_build
    run_prepare_fixtures >/dev/null

    local fixture_file log_dir result_dir started_at deadline cycle group root_name root_path prefix
    fixture_file="$(run_dir)/fixtures.env"
    set -a
    # shellcheck disable=SC1090
    source "$fixture_file"
    set +a
    log_dir="$(run_dir)/logs/soak"
    result_dir="$(run_dir)/results/soak"
    mkdir -p "$log_dir" "$result_dir" "$(run_dir)/state/soak"

    write_soak_marker
    trap 'soak_cleanup_on_exit "$?"' EXIT
    started_at="$(date +%s)"
    deadline=$((started_at + SOAK_DURATION_SECONDS))
    cycle=0
    while (( $(date +%s) < deadline )); do
        cycle=$((cycle + 1))
        while IFS= read -r group; do
            for root_name in LOCAL_ROOT APFS_ROOT ICLOUD_ROOT SMB_ROOT; do
                root_path="${!root_name}"
                prefix="$log_dir/cycle-$cycle-$group-$root_name"
                run_installed_once \
                    "$group" "$root_name" 1 "$prefix" \
                    "$result_dir/cycle-$cycle-$group-$root_name.xcresult"
                sample_soak_health "$cycle" "$group" "$root_name" "$root_path"
            done
        done < <(selected_workflow_groups all)
    done
    (( $(date +%s) - started_at >= SOAK_DURATION_SECONDS )) || fail "soak ended before 12 continuous hours"
    printf 'started_epoch=%s\nended_epoch=%s\nduration_seconds=%s\ncycles=%s\nstatus=passed\n' \
        "$started_at" "$(date +%s)" "$SOAK_DURATION_SECONDS" "$cycle" > "$(run_dir)/soak.env"

    run_cleanup
    verify_qualification_cleanup
    rm -f -- "$QUALIFICATION_ROOT/.soak-active"
    trap - EXIT
}
