#!/bin/bash

# Structured qualification evidence sourced only by qualification.sh.

prepare_evidence_layout() {
    mkdir -p \
        "$(run_dir)/preflight" \
        "$(run_dir)/timing" \
        "$(run_dir)/state" \
        "$(run_dir)/snapshots/before" \
        "$(run_dir)/snapshots/after" \
        "$(run_dir)/logs" \
        "$(run_dir)/screenshots" \
        "$(run_dir)/results" \
        "$(run_dir)/failures" \
        "$(run_dir)/cleanup" \
        "$(run_dir)/commands"
}

record_scenario_timing() {
    local layer="$1"
    local scenario="$2"
    local context="$3"
    local repetitions="$4"
    local started_epoch="$5"
    local status="$6"
    local ended_epoch
    ended_epoch="$(date +%s)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$layer" "$scenario" "$context" \
        "$repetitions" "$started_epoch" "$ended_epoch" "$status" >> "$(run_dir)/timing/scenarios.tsv"
}

capture_state_observation() {
    local label="$1"
    local destination
    destination="$(run_dir)/state/$label"
    mkdir -p "$destination"
    pgrep -fl 'Detours|detours-server|xctest|xcodebuild|ssh' > "$destination/processes.txt" || true
    mount > "$destination/mounts.txt"
    ps -axo pid,ppid,state,etime,command > "$destination/process-table.txt"
    printf 'captured_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$destination/capture.env"
}

capture_outside_root_snapshots() {
    local phase="$1"
    local descriptor name destination guard_binary
    guard_binary="$(qualification_guard)"
    while IFS= read -r descriptor; do
        name="$(basename "$descriptor" .json)"
        destination="$(run_dir)/snapshots/$phase/$name.json"
        "$guard_binary" snapshot --descriptor "$descriptor" --output "$destination" >/dev/null
    done < <(find "$(run_dir)/roots" -maxdepth 1 -type f -name '*.json' | sort)
}

compare_outside_root_snapshots() {
    local before name after
    while IFS= read -r before; do
        name="$(basename "$before")"
        after="$(run_dir)/snapshots/after/$name"
        [[ -f "$after" ]] || fail "outside-root after snapshot is missing: $after"
        "$(qualification_guard)" compare-snapshots --before "$before" --after "$after" >/dev/null
    done < <(find "$(run_dir)/snapshots/before" -maxdepth 1 -type f -name '*.json' | sort)
}

capture_qualification_failure() {
    local status="$1"
    local line="$2"
    local failed_command="$3"
    local failure_dir
    [[ "${QUALIFICATION_FAILURE_CAPTURED:-0}" == "0" ]] || return
    QUALIFICATION_FAILURE_CAPTURED=1
    failure_dir="$(run_dir)/failures/$(date +%s)-$$-$line"
    mkdir -p "$failure_dir"
    {
        printf 'status=%s\n' "$status"
        printf 'line=%s\n' "$line"
        printf 'command=%q\n' "$failed_command"
        printf 'captured_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$failure_dir/failure.env"
    [[ ! -f "$(run_dir)/replay.tsv" ]] || cp "$(run_dir)/replay.tsv" "$failure_dir/replay.tsv"
    capture_state_observation "failure-$(basename "$failure_dir")" || true
    if command -v screencapture >/dev/null 2>&1; then
        screencapture -x "$failure_dir/screenshot.png" >/dev/null 2>&1 || true
    fi
}

qualification_on_error() {
    local status="$1"
    local line="$2"
    local failed_command="$3"
    trap - ERR
    set +e
    capture_qualification_failure "$status" "$line" "$failed_command"
    return "$status"
}

verify_qualification_cleanup() {
    local descriptor root_path image_path
    if [[ -d "$(run_dir)/roots" ]]; then
        while IFS= read -r descriptor; do
            root_path="$(plutil -extract rootPath raw -o - "$descriptor")"
            [[ ! -e "$root_path" && ! -L "$root_path" ]] || fail "marked root remains after cleanup: $root_path"
        done < <(find "$(run_dir)/roots" -maxdepth 1 -type f -name '*.json' | sort)
    fi
    if [[ -f "$(run_dir)/fixtures.env" ]]; then
        # shellcheck disable=SC1090,SC1091
        source "$(run_dir)/fixtures.env"
        image_path="${APFS_IMAGE:-}"
        [[ -z "$image_path" || ! -e "$image_path" ]] || fail "APFS image remains after cleanup: $image_path"
    fi
    ! pgrep -x Detours >/dev/null 2>&1 || fail "Detours remains after cleanup"
    ! pgrep -x xctest >/dev/null 2>&1 || fail "xctest remains after cleanup"
    ! pgrep -x xcodebuild >/dev/null 2>&1 || fail "xcodebuild remains after cleanup"
    ! mount | grep -F " on $SMB_MOUNT_POINT " >/dev/null 2>&1 || fail "SMB mount remains after cleanup"
    ! mount | grep -E '/Volumes/DetoursQualification-[0-9a-f-]{36}' >/dev/null 2>&1 || fail "APFS mount remains after cleanup"
    printf 'status=passed\nverified_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$(run_dir)/cleanup/result.env"
}

campaign_cleanup_on_exit() {
    local original_status="$1"
    trap - EXIT
    set +e
    run_cleanup
    local cleanup_status=$?
    if (( cleanup_status == 0 )); then
        verify_qualification_cleanup
        cleanup_status=$?
    fi
    if [[ -n "${QUALIFICATION_PROMPT_GUARD_PID:-}" \
        || -n "${QUALIFICATION_PROMPT_AUDIT_START:-}" ]]; then
        finish_prompt_guard
        local prompt_status=$?
        if (( cleanup_status == 0 && prompt_status != 0 )); then
            cleanup_status="$prompt_status"
        fi
    fi
    if (( cleanup_status != 0 )); then
        printf 'qualification: campaign cleanup failed with status %s\n' "$cleanup_status" >&2
        exit "$cleanup_status"
    fi
    exit "$original_status"
}
