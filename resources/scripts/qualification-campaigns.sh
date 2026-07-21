#!/bin/bash

# Foundry-only qualification campaign orchestration.

run_preflight() {
    local scope="${1:-full}"
    local requested_commit head_commit current_branch free_kilobytes boot_epoch
    local linux_platform intel_mac_platform windows_platform
    linux_platform=""
    intel_mac_platform=""
    windows_platform=""
    requested_commit="$(canonical_commit)"
    head_commit="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
    [[ "$head_commit" == "$requested_commit" ]] || fail "HEAD $head_commit does not match requested commit $requested_commit"
    current_branch="$(git -C "$PROJECT_DIR" branch --show-current)"
    [[ "$current_branch" == "testing/whole-app-stability-qualification" ]] || fail "Foundry is on unexpected branch: $current_branch"
    [[ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ]] || fail "Foundry worktree is not clean"

    audit_matrix
    free_kilobytes="$(df -Pk "$PROJECT_DIR" | awk 'NR == 2 { print $4 }')"
    is_unsigned_integer "$free_kilobytes" || fail "could not read free storage"
    (( free_kilobytes >= MINIMUM_FREE_KILOBYTES )) || fail "qualification needs at least 50 GB free"
    boot_epoch="$(sysctl -n kern.boottime | sed -E 's/^.*sec = ([0-9]+).*$/\1/')"
    is_unsigned_integer "$boot_epoch" || fail "could not read Foundry boot time"

    if [[ "$scope" == "full" || "$scope" == "LINUX_TARGET" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=8 "$QUALIFICATION_LINUX_TARGET" 'exit 0' >/dev/null 2>&1 || \
            fail "required host is unreachable: $QUALIFICATION_LINUX_TARGET"
        linux_platform="$(ssh -o BatchMode=yes -o ConnectTimeout=8 \
            "$QUALIFICATION_LINUX_TARGET" 'uname -s')"
        [[ "$linux_platform" == "Linux" ]] || \
            fail "configured Linux endpoint reported an unexpected platform: $linux_platform"
    fi
    if [[ "$scope" == "full" || "$scope" == "INTEL_MAC_TARGET" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=8 "$QUALIFICATION_INTEL_MAC_TARGET" 'exit 0' >/dev/null 2>&1 || \
            fail "required host is unreachable: $QUALIFICATION_INTEL_MAC_TARGET"
        intel_mac_platform="$(ssh -o BatchMode=yes -o ConnectTimeout=8 \
            "$QUALIFICATION_INTEL_MAC_TARGET" 'uname -sm')"
        [[ "$intel_mac_platform" == "Darwin x86_64" ]] || \
            fail "configured Intel Mac endpoint reported an unexpected platform: $intel_mac_platform"
    fi
    if [[ "$scope" == "full" || "$scope" == "WINDOWS_TARGET" ]]; then
        # `exit 0` is accepted by the PowerShell SSH endpoint.
        ssh -o BatchMode=yes -o ConnectTimeout=8 "$QUALIFICATION_WINDOWS_TARGET" 'exit 0' >/dev/null 2>&1 || \
            fail "required host is unreachable: $QUALIFICATION_WINDOWS_TARGET"
        windows_platform="$(ssh -o BatchMode=yes -o ConnectTimeout=8 \
            "$QUALIFICATION_WINDOWS_TARGET" \
            '[Console]::WriteLine("DETOURS_WINDOWS_POWERSHELL`t$([System.Environment]::OSVersion.Platform)")')"
        [[ "$windows_platform" == *$'DETOURS_WINDOWS_POWERSHELL\tWin32NT'* ]] || \
            fail "configured Windows endpoint did not provide Windows PowerShell: $windows_platform"
    fi
    if [[ "$scope" == "full" || "$scope" == "SMB_ROOT" || "$scope" == "STORAGE_ROOTS" ]]; then
        nc -G 8 -z "$QUALIFICATION_SMB_HOST" 445 >/dev/null 2>&1 || \
            fail "SMB port 445 is unreachable: $QUALIFICATION_SMB_HOST"

        [[ "${DETOURS_QUALIFICATION_SECRET_TRANSPORT:-}" == "stdin-v1" ]] || \
            fail "SMB credentials must arrive through qualification-foundry.sh"
        [[ -n "${DETOURS_SMB_TEST_PASSWORD:-}" ]] || fail "SMB credential transport returned an empty value"
        verify_smb_authentication
    fi
    if [[ "$scope" == "full" || "$scope" == "ICLOUD_ROOT" || "$scope" == "STORAGE_ROOTS" ]]; then
        [[ -d "$ICLOUD_PARENT" ]] || fail "iCloud qualification parent is missing: $ICLOUD_PARENT"
        if find "$ICLOUD_PARENT" -name '*.icloud' -print -quit | grep -q .; then
            fail "iCloud qualification parent contains non-local placeholders"
        fi
    fi

    ! pgrep -x Detours >/dev/null 2>&1 || fail "Detours is running"
    ! pgrep -x detours-server >/dev/null 2>&1 || fail "a local detours-server process is running"
    [[ ! -e "$QUALIFICATION_ROOT/.soak-active" ]] || fail "a prior qualification soak marker remains"
    ! mount | grep -F "$SMB_MOUNT_POINT" >/dev/null 2>&1 || fail "qualification SMB share is still mounted"
    [[ ! -e "$SMB_MOUNT_POINT" ]] || fail "qualification SMB mountpoint remains; run reset"
    ! mount | grep -E '/Volumes/DetoursQualification-[0-9a-f-]{36}' >/dev/null 2>&1 || fail "qualification APFS image is still mounted"
    ! defaults read "$APP_BUNDLE_ID" >/dev/null 2>&1 || fail "Detours preferences remain; run reset"
    [[ ! -e "$HOME/Library/Caches/$APP_BUNDLE_ID" ]] || fail "Detours cache remains; run reset"
    [[ ! -e "$HOME/Library/Saved Application State/$APP_BUNDLE_ID.savedState" ]] || fail "Detours saved state remains; run reset"
    [[ ! -e "$HOME/DetoursUITests-Temp" ]] || fail "UI test fixture root remains; run reset"
    ! security find-generic-password -s "$QUALIFICATION_KEYCHAIN_SERVICE" >/dev/null 2>&1 || fail "qualification Keychain credential remains; run reset"

    mkdir -p "$(run_dir)/preflight"
    {
        printf 'commit=%s\n' "$head_commit"
        printf 'branch=%s\n' "$current_branch"
        printf 'host=%s\n' "$(host_name)"
        printf 'free_kilobytes=%s\n' "$free_kilobytes"
        printf 'boot_epoch=%s\n' "$boot_epoch"
        printf 'macos=%s\n' "$(sw_vers -productVersion)"
        printf 'xcode=%s\n' "$(xcodebuild -version | tr '\n' ' ')"
        printf 'swift=%s\n' "$(swift --version | head -1)"
        printf 'linux_target=%s\n' "$QUALIFICATION_LINUX_TARGET"
        printf 'intel_mac_target=%s\n' "$QUALIFICATION_INTEL_MAC_TARGET"
        printf 'windows_target=%s\n' "$QUALIFICATION_WINDOWS_TARGET"
        printf 'smb_host=%s\n' "$QUALIFICATION_SMB_HOST"
        printf 'smb_share=%s\n' "$QUALIFICATION_SMB_SHARE"
        printf 'smb_user=%s\n' "$QUALIFICATION_SMB_USER"
        printf 'linux_platform=%s\n' "$linux_platform"
        printf 'intel_mac_platform=%s\n' "$intel_mac_platform"
        printf 'windows_platform=%s\n' "$windows_platform"
        printf 'checked_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$(run_dir)/preflight/environment.env"
}

run_reset() {
    pkill -x Detours >/dev/null 2>&1 || true
    local _
    for _ in {1..50}; do
        pgrep -x Detours >/dev/null 2>&1 || break
        sleep 0.1
    done
    ! pgrep -x Detours >/dev/null 2>&1 || fail "Detours did not stop during reset"

    local guard_binary=""
    if guard_binary="$(qualification_guard 2>/dev/null)"; then
        local parent sentinel
        for parent in "$LOCAL_PARENT" "$ICLOUD_PARENT"; do
            [[ -d "$parent" ]] || continue
            while IFS= read -r sentinel; do
                "$guard_binary" remove --descriptor "$sentinel"
            done < <(find "$parent" -mindepth 2 -maxdepth 2 -type f -name '.detours-qualification-root.json' | sort)
        done
        run_cleanup
    fi

    if mount | grep -F "$SMB_MOUNT_POINT" >/dev/null 2>&1; then
        diskutil unmount "$SMB_MOUNT_POINT" >/dev/null
    fi
    remove_exact_tree "$SMB_MOUNT_POINT" /Volumes
    local mounted_apfs
    while IFS= read -r mounted_apfs; do
        [[ -n "$mounted_apfs" ]] || continue
        diskutil unmount "$mounted_apfs" >/dev/null
    done < <(mount | sed -nE 's|^.* on (/Volumes/DetoursQualification-[0-9a-f-]{36}) \(.*$|\1|p')

    defaults delete "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
    security delete-generic-password -s "$QUALIFICATION_KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
    remove_exact_tree "$HOME/Library/Caches/$APP_BUNDLE_ID" "$HOME/Library/Caches"
    remove_exact_tree "$HOME/Library/Saved Application State/$APP_BUNDLE_ID.savedState" "$HOME/Library/Saved Application State"
    remove_exact_tree "$HOME/Library/Containers/MAF.DetoursUITests.xctrunner" "$HOME/Library/Containers"
    remove_exact_tree "$HOME/DetoursUITests-Temp" "$HOME"
    rm -f -- "$QUALIFICATION_ROOT/.soak-active"

    # Every SMB campaign starts from the same consent state. The qualification
    # UI test accepts only the network-volume prompt and only when its fixture
    # root is on a non-local volume.
    tccutil reset SystemPolicyNetworkVolumes "$APP_BUNDLE_ID" >/dev/null

    mkdir -p "$(run_dir)/reset"
    printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$(run_dir)/reset/result.env"
}

run_build() {
    mkdir -p "$(run_dir)/logs"
    DETOURS_BUILD_FORCE_QUIT=1 DETOURS_BUILD_SKIP_RELAUNCH=1 \
        "$SCRIPT_DIR/build.sh" --no-install 2>&1 | tee "$(run_dir)/logs/build.log"
}

run_cancel() {
    local active_job_file active_deadline_file label deadline_pid deadline_command attempt
    active_job_file="$(run_dir)/active-gui-job"
    if [[ -f "$active_job_file" ]]; then
        IFS= read -r label < "$active_job_file"
        [[ "$label" =~ ^com\.detours\.qualification\.[A-F0-9-]+$ ]] || \
            fail "active GUI qualification job label is invalid"
        launchctl remove "$label" 2>/dev/null || true
        rm -f -- "$active_job_file"
    fi
    active_deadline_file="$(run_dir)/active-deadline"
    if [[ -f "$active_deadline_file" ]]; then
        IFS= read -r deadline_pid < "$active_deadline_file"
        [[ "$deadline_pid" =~ ^[0-9]+$ && "$deadline_pid" -gt 1 ]] || \
            fail "active qualification deadline PID is invalid"
        deadline_command="$(ps -p "$deadline_pid" -o command= 2>/dev/null || true)"
        [[ "$deadline_command" == *"/qualification-deadline.sh "* ]] || \
            fail "active qualification deadline process does not match its record"
        kill -TERM "$deadline_pid" 2>/dev/null || true
        for (( attempt = 1; attempt <= 50; attempt++ )); do
            kill -0 "$deadline_pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -0 "$deadline_pid" 2>/dev/null && \
            fail "active qualification deadline did not stop"
        rm -f -- "$active_deadline_file"
    fi
    # xcodebuild may have already detached the tested application from its
    # launchd job. Removing that job therefore does not guarantee that the
    # qualification app has stopped.
    stop_installed_app
}

run_cold() {
    [[ "$QUALIFICATION_COLD_INDEX" != "0" ]] || fail "cold-run requires --cold-index 1, 2, or 3"
    trap 'campaign_cleanup_on_exit "$?"' EXIT
    run_reset
    run_preflight
    run_build
    run_prepare_fixtures
    capture_outside_root_snapshots before
    capture_state_observation cold-before
    run_in_process all
    run_installed all
    capture_state_observation cold-after
    capture_outside_root_snapshots after
    compare_outside_root_snapshots
    run_cleanup
    verify_qualification_cleanup
    {
        printf 'status=passed\n'
        printf 'commit=%s\n' "$(canonical_commit)"
        printf 'cold_index=%s\n' "$QUALIFICATION_COLD_INDEX"
        printf 'seed=%s\n' "$QUALIFICATION_SEED"
        printf 'boot_epoch=%s\n' "$(sed -n 's/^boot_epoch=//p' "$(run_dir)/preflight/environment.env")"
        printf 'linux_target=%s\n' "$QUALIFICATION_LINUX_TARGET"
        printf 'intel_mac_target=%s\n' "$QUALIFICATION_INTEL_MAC_TARGET"
        printf 'windows_target=%s\n' "$QUALIFICATION_WINDOWS_TARGET"
        printf 'smb_host=%s\n' "$QUALIFICATION_SMB_HOST"
        printf 'completed_epoch=%s\n' "$(date +%s)"
        printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$(run_dir)/cold.env"
    trap - EXIT
}

run_workflow_campaign() {
    local group="$1"
    validate_group "$group"
    trap 'campaign_cleanup_on_exit "$?"' EXIT
    run_reset
    run_preflight
    run_build
    run_prepare_fixtures
    capture_outside_root_snapshots before
    if [[ "$group" == "refresh" ]]; then
        set -a
        # shellcheck disable=SC1090,SC1091
        source "$(run_dir)/fixtures.env"
        set +a
        prepare_blocking_refresh_bundles
        blocking_layer storage-permissions 30 run_blocking_storage_permissions
    fi
    capture_state_observation workflow-before
    run_in_process "$group"
    run_installed "$group"
    capture_state_observation workflow-after
    capture_outside_root_snapshots after
    compare_outside_root_snapshots
    run_cleanup
    verify_qualification_cleanup
    {
        printf 'status=passed\n'
        printf 'commit=%s\n' "$(canonical_commit)"
        printf 'group=%s\n' "$group"
        printf 'seed=%s\n' "$QUALIFICATION_SEED"
        printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$(run_dir)/workflow.env"
    trap - EXIT
}

run_in_process_campaign() {
    local group="$1"
    validate_group "$group"
    trap 'campaign_cleanup_on_exit "$?"' EXIT
    run_reset
    run_preflight STORAGE_ROOTS
    run_build
    run_prepare_fixtures
    capture_outside_root_snapshots before
    capture_state_observation in-process-before
    run_in_process "$group"
    capture_state_observation in-process-after
    capture_outside_root_snapshots after
    compare_outside_root_snapshots
    run_cleanup
    verify_qualification_cleanup
    {
        printf 'status=passed\n'
        printf 'commit=%s\n' "$(canonical_commit)"
        printf 'group=%s\n' "$group"
        printf 'seed=%s\n' "$QUALIFICATION_SEED"
        printf 'repetitions=%s\n' "$QUALIFICATION_IN_PROCESS_REPETITIONS"
        printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$(run_dir)/in-process.env"
    trap - EXIT
}

run_installed_smoke_campaign() {
    local group="$1"
    local context_name="$2"
    validate_group "$group"
    [[ "$group" != "all" ]] || fail "installed-smoke requires one named workflow group"
    case "$context_name" in
        LOCAL_ROOT|APFS_ROOT|ICLOUD_ROOT|SMB_ROOT) ;;
        LINUX_TARGET|INTEL_MAC_TARGET|WINDOWS_TARGET)
            installed_group_uses_remote_targets "$group" || \
                fail "remote installed smoke is unavailable for $group"
            ;;
        *) fail "installed-smoke context must be a fixture root or live remote target" ;;
    esac
    installed_contexts "$group" | grep -Fx "$context_name" >/dev/null || \
        fail "$context_name is not an applicable installed context for $group"
    trap 'campaign_cleanup_on_exit "$?"' EXIT
    run_reset
    run_preflight "$context_name"
    run_build
    case "$context_name" in
        LOCAL_ROOT|LINUX_TARGET|INTEL_MAC_TARGET|WINDOWS_TARGET) run_prepare_local_fixture ;;
        APFS_ROOT) run_prepare_apfs_fixture ;;
        ICLOUD_ROOT) run_prepare_icloud_fixture ;;
        SMB_ROOT) run_prepare_smb_fixture ;;
    esac
    capture_outside_root_snapshots before
    capture_state_observation installed-smoke-before
    run_installed_smoke "$group" "$context_name" "$QUALIFICATION_SMOKE_REPETITIONS"
    capture_state_observation installed-smoke-after
    capture_outside_root_snapshots after
    compare_outside_root_snapshots
    run_cleanup
    verify_qualification_cleanup
    trap - EXIT
}
