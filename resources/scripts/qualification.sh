#!/bin/bash

# One-time whole-app stability qualification runner.
# Operational modes intentionally refuse to run anywhere except Foundry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
export MATRIX_PATH="$PROJECT_DIR/resources/docs/260720-whole-app-stability-qualification-matrix.md"
QUALIFICATION_ROOT="$PROJECT_DIR/.build/qualification"
LOCAL_PARENT="$HOME/DetoursQualification"
ICLOUD_PARENT="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Detours Qualification"
SMB_MOUNT_POINT=""
APP_BUNDLE_ID="com.detours.app"
QUALIFICATION_KEYCHAIN_SERVICE="com.detours.qualification"
MINIMUM_FREE_KILOBYTES=$((50 * 1024 * 1024))

qualification_guard() {
    local release_guard="$PROJECT_DIR/.build/arm64-apple-macosx/release/detours-qualification-guard"
    local debug_guard="$PROJECT_DIR/.build/arm64-apple-macosx/debug/detours-qualification-guard"
    if [[ -x "$release_guard" ]]; then
        printf '%s\n' "$release_guard"
    elif [[ -x "$debug_guard" ]]; then
        printf '%s\n' "$debug_guard"
    else
        fail "qualification guard is not built; run the build command first"
    fi
}

qualification_smb_mounter() {
    local release_mounter="$PROJECT_DIR/.build/arm64-apple-macosx/release/detours-qualification-smb-mounter"
    local debug_mounter="$PROJECT_DIR/.build/arm64-apple-macosx/debug/detours-qualification-smb-mounter"
    if [[ -x "$release_mounter" ]]; then
        printf '%s\n' "$release_mounter"
    elif [[ -x "$debug_mounter" ]]; then
        printf '%s\n' "$debug_mounter"
    else
        fail "qualification SMB mounter is not built; run the build command first"
    fi
}

usage() {
    cat <<'USAGE'
Usage: resources/scripts/qualification.sh <command> [options]

Commands:
  audit-matrix                  Audit capability-source-check traceability
  preflight                    Validate Foundry and all live environments
  reset                        Remove exact marked qualification state
  smb-auth                     Validate SMB authentication without mounting
  fixtures                     Create and mount every guarded fixture root
  build                        Build the qualifying app without installing it
  in-process <group|all>       Run a named workflow 100 times in process
  installed <group|all>        Run a named workflow 20 times in the installed app
  workflow-run <group|all>     Run both layers with fixtures in one audit session
  installed-smoke <group> <root|target>
                               Run focused installed repetitions in one audit session
  failure-probe <provider>     Prove one provider failure is preserved and cleaned
  cold-run                     Reset and run one complete cold qualification
  soak                         Run the installed-app campaign for 12 hours
  report                       Generate the tracked matrix and result report
  cleanup                      Remove exact marked qualification state
  cancel                       Stop the exact active GUI job for a run
  run                          Run preflight, build, three cold runs, and soak
  help                         Show this help

Options:
  --commit <sha>                Exact clean commit to qualify (default: HEAD)
  --run-id <id>                Evidence run identifier (default: generated UUID)
  --seed <unsigned-integer>     Replay scenario order and fixture-name choices
  --smoke-repetitions <1-20>    Installed-smoke repetition count (default: 1)
  --cold-index <1|2|3>          Cold-run sequence number
  --linux-target <ssh-alias>    Linux qualification endpoint (default: devtest)
  --intel-mac-target <alias>    Intel Mac qualification endpoint (default: wraith)
  --windows-target <alias>      Windows qualification endpoint (default: detours-windows)
  --smb-host <host>             SMB qualification endpoint (default: devtest)
  --smb-share <name>            SMB qualification share (default: Detours Qualification)
  --smb-user <name>             SMB qualification account (default: detours-qualification)

Named workflow groups:
  activation
  refresh
  transfer
  mutation
  connection
  archive
  session
  opening

The third cold run must begin after a Foundry reboot recorded by preflight.
USAGE
}

fail() {
    printf 'qualification: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

host_name() {
    if command -v scutil >/dev/null 2>&1; then
        scutil --get LocalHostName 2>/dev/null || hostname -s
    else
        hostname -s
    fi
}

require_foundry() {
    local current_host
    current_host="$(host_name | tr '[:upper:]' '[:lower:]')"
    case "$current_host" in
        foundry|foundry.*) ;;
        *) fail "operational commands run only on Foundry (current host: $current_host)" ;;
    esac
}

path_is_within() {
    local candidate="$1"
    local parent="$2"
    [[ "$candidate" == "$parent" || "$candidate" == "$parent/"* ]]
}

remove_exact_tree() {
    local target="$1"
    local allowed_parent="$2"
    [[ -n "$target" && -n "$allowed_parent" ]] || fail "refusing cleanup with an empty path"
    [[ "$target" != "/" && "$allowed_parent" != "/" ]] || fail "refusing broad cleanup path"
    path_is_within "$target" "$allowed_parent" || fail "cleanup target escapes $allowed_parent: $target"
    [[ -e "$target" || -L "$target" ]] || return 0
    rm -rf -- "$target"
}

canonical_commit() {
    git -C "$PROJECT_DIR" rev-parse "${QUALIFICATION_COMMIT}^{commit}"
}

new_run_id() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        require_command python3
        python3 -c 'import uuid; print(uuid.uuid4())'
    fi
}

is_unsigned_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

parse_options() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --commit)
                [[ $# -ge 2 ]] || fail "--commit requires a value"
                QUALIFICATION_COMMIT="$2"
                shift 2
                ;;
            --run-id)
                [[ $# -ge 2 ]] || fail "--run-id requires a value"
                QUALIFICATION_RUN_ID="$2"
                shift 2
                ;;
            --seed)
                [[ $# -ge 2 ]] || fail "--seed requires a value"
                QUALIFICATION_SEED="$2"
                shift 2
                ;;
            --smoke-repetitions)
                [[ $# -ge 2 ]] || fail "--smoke-repetitions requires a value"
                QUALIFICATION_SMOKE_REPETITIONS="$2"
                shift 2
                ;;
            --cold-index)
                [[ $# -ge 2 ]] || fail "--cold-index requires a value"
                QUALIFICATION_COLD_INDEX="$2"
                shift 2
                ;;
            --linux-target)
                [[ $# -ge 2 ]] || fail "--linux-target requires a value"
                QUALIFICATION_LINUX_TARGET="$2"
                shift 2
                ;;
            --intel-mac-target)
                [[ $# -ge 2 ]] || fail "--intel-mac-target requires a value"
                QUALIFICATION_INTEL_MAC_TARGET="$2"
                shift 2
                ;;
            --windows-target)
                [[ $# -ge 2 ]] || fail "--windows-target requires a value"
                QUALIFICATION_WINDOWS_TARGET="$2"
                shift 2
                ;;
            --smb-host)
                [[ $# -ge 2 ]] || fail "--smb-host requires a value"
                QUALIFICATION_SMB_HOST="$2"
                shift 2
                ;;
            --smb-share)
                [[ $# -ge 2 ]] || fail "--smb-share requires a value"
                QUALIFICATION_SMB_SHARE="$2"
                shift 2
                ;;
            --smb-user)
                [[ $# -ge 2 ]] || fail "--smb-user requires a value"
                QUALIFICATION_SMB_USER="$2"
                shift 2
                ;;
            *) fail "unknown option: $1" ;;
        esac
    done

    is_unsigned_integer "$QUALIFICATION_SEED" || fail "--seed must be an unsigned integer"
    is_unsigned_integer "$QUALIFICATION_SMOKE_REPETITIONS" || \
        fail "--smoke-repetitions must be an integer from 1 through 20"
    (( QUALIFICATION_SMOKE_REPETITIONS >= 1 && QUALIFICATION_SMOKE_REPETITIONS <= 20 )) || \
        fail "--smoke-repetitions must be an integer from 1 through 20"
    case "$QUALIFICATION_COLD_INDEX" in
        0|1|2|3) ;;
        *) fail "--cold-index must be 1, 2, or 3" ;;
    esac
    local configured_value
    for configured_value in \
        "$QUALIFICATION_LINUX_TARGET" \
        "$QUALIFICATION_INTEL_MAC_TARGET" \
        "$QUALIFICATION_WINDOWS_TARGET" \
        "$QUALIFICATION_SMB_HOST" \
        "$QUALIFICATION_SMB_SHARE" \
        "$QUALIFICATION_SMB_USER"; do
        [[ -n "$configured_value" && "$configured_value" != *$'\n'* ]] || \
            fail "qualification target values must be non-empty single lines"
    done
}

run_dir() {
    printf '%s/%s/%s\n' "$QUALIFICATION_ROOT" "$(canonical_commit)" "$QUALIFICATION_RUN_ID"
}

write_command_metadata() {
    local destination metadata_path
    destination="$(run_dir)"
    mkdir -p "$destination/commands"
    metadata_path="$destination/commands/$(date +%s)-$$-$COMMAND.env"
    {
        printf 'command=%s\n' "$COMMAND"
        printf 'commit=%s\n' "$(canonical_commit)"
        printf 'run_id=%s\n' "$QUALIFICATION_RUN_ID"
        printf 'seed=%s\n' "$QUALIFICATION_SEED"
        printf 'smoke_repetitions=%s\n' "$QUALIFICATION_SMOKE_REPETITIONS"
        printf 'cold_index=%s\n' "$QUALIFICATION_COLD_INDEX"
        printf 'linux_target=%s\n' "$QUALIFICATION_LINUX_TARGET"
        printf 'intel_mac_target=%s\n' "$QUALIFICATION_INTEL_MAC_TARGET"
        printf 'windows_target=%s\n' "$QUALIFICATION_WINDOWS_TARGET"
        printf 'smb_host=%s\n' "$QUALIFICATION_SMB_HOST"
        printf 'smb_share=%s\n' "$QUALIFICATION_SMB_SHARE"
        printf 'smb_user=%s\n' "$QUALIFICATION_SMB_USER"
        printf 'host=%s\n' "$(host_name)"
        printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$metadata_path"
    cp "$metadata_path" "$destination/command.env"
}

workflow_groups() {
    printf '%s\n' activation refresh transfer mutation connection archive session opening
}

validate_group() {
    local requested="$1"
    if [[ "$requested" == "all" ]]; then
        return
    fi
    workflow_groups | grep -Fx "$requested" >/dev/null || fail "unknown workflow group: $requested"
}

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
    if [[ "$scope" == "full" ]]; then
        nc -G 8 -z "$QUALIFICATION_SMB_HOST" 445 >/dev/null 2>&1 || \
            fail "SMB port 445 is unreachable: $QUALIFICATION_SMB_HOST"

        [[ -d "$ICLOUD_PARENT" ]] || fail "iCloud qualification parent is missing: $ICLOUD_PARENT"
        if find "$ICLOUD_PARENT" -name '*.icloud' -print -quit | grep -q .; then
            fail "iCloud qualification parent contains non-local placeholders"
        fi

        [[ "${DETOURS_QUALIFICATION_SECRET_TRANSPORT:-}" == "stdin-v1" ]] || \
            fail "SMB credentials must arrive through qualification-foundry.sh"
        [[ -n "${DETOURS_SMB_TEST_PASSWORD:-}" ]] || fail "SMB credential transport returned an empty value"
        verify_smb_authentication
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
    local active_job_file label
    active_job_file="$(run_dir)/active-gui-job"
    if [[ -f "$active_job_file" ]]; then
        IFS= read -r label < "$active_job_file"
        [[ "$label" =~ ^com\.detours\.qualification\.[A-F0-9-]+$ ]] || \
            fail "active GUI qualification job label is invalid"
        launchctl remove "$label" 2>/dev/null || true
        rm -f -- "$active_job_file"
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
    case "$context_name" in
        LOCAL_ROOT|LINUX_TARGET|INTEL_MAC_TARGET|WINDOWS_TARGET)
            run_preflight "$context_name"
            ;;
        *)
            run_preflight
            ;;
    esac
    run_build
    case "$context_name" in
        LOCAL_ROOT|LINUX_TARGET|INTEL_MAC_TARGET|WINDOWS_TARGET) run_prepare_local_fixture ;;
        *) run_prepare_fixtures ;;
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

run_soak() {
    run_twelve_hour_soak
}

run_report() {
    generate_qualification_report
}

run_cleanup() {
    local descriptors_dir descriptor fixture_file guard_binary
    local progress_dir progress_marker progress_tmp recorded_root root_path
    pkill -x Detours >/dev/null 2>&1 || true
    local _
    for _ in {1..50}; do
        pgrep -x Detours >/dev/null 2>&1 || break
        sleep 0.1
    done
    ! pgrep -x Detours >/dev/null 2>&1 || fail "Detours did not stop during cleanup"
    ! pgrep -x xctest >/dev/null 2>&1 || fail "xctest remains active during cleanup"
    ! pgrep -x xcodebuild >/dev/null 2>&1 || fail "xcodebuild remains active during cleanup"

    descriptors_dir="$(run_dir)/roots"
    fixture_file="$(run_dir)/fixtures.env"
    if [[ -f "$descriptors_dir/smb.json" && -f "$fixture_file" ]]; then
        # Cleanup must use the exact mount recorded when the SMB fixture was
        # created. A remount has a different volume identity and must fail
        # closed instead of weakening or rebinding the destructive guard.
        # shellcheck disable=SC1090
        source "$fixture_file"
        verify_smb_fixture_session_access 0
    fi
    if [[ -d "$descriptors_dir" ]]; then
        guard_binary="$(qualification_guard)"
        progress_dir="$(run_dir)/cleanup/removed-roots"
        mkdir -p "$progress_dir"
        while IFS= read -r descriptor; do
            root_path="$(plutil -extract rootPath raw -o - "$descriptor")"
            progress_marker="$progress_dir/$(basename "$descriptor").env"
            if [[ -f "$progress_marker" ]]; then
                recorded_root="$(sed -n 's/^root_path=//p' "$progress_marker")"
                [[ "$recorded_root" == "$root_path" ]] || \
                    fail "cleanup checkpoint does not match descriptor: $descriptor"
                [[ ! -e "$root_path" && ! -L "$root_path" ]] || \
                    fail "checkpointed qualification root reappeared: $root_path"
                continue
            fi
            "$guard_binary" remove --descriptor "$descriptor"
            progress_tmp="$progress_marker.tmp.$$"
            {
                printf 'root_path=%s\n' "$root_path"
                printf 'removed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            } > "$progress_tmp"
            mv "$progress_tmp" "$progress_marker"
        done < <(find "$descriptors_dir" -maxdepth 1 -type f -name '*.json' | sort)
    fi

    cleanup_fixture_mounts
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-fixtures.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-workflows.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-soak.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-evidence.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-report.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-audit.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/qualification-failure-probe.sh"

run_all() {
    run_build
    local index
    for index in 1 2; do
        "$0" cold-run --commit "$(canonical_commit)" --run-id "$(new_run_id)" --seed "$QUALIFICATION_SEED" --cold-index "$index" "${QUALIFICATION_TARGET_ARGUMENTS[@]}"
    done
    fail "reboot Foundry before cold run 3, then resume with cold-run --cold-index 3"
}

COMMAND="${1:-help}"
if [[ $# -gt 0 ]]; then
    shift
fi

QUALIFICATION_COMMIT="HEAD"
QUALIFICATION_RUN_ID=""
QUALIFICATION_SEED="0"
QUALIFICATION_SMOKE_REPETITIONS="1"
QUALIFICATION_COLD_INDEX="0"
QUALIFICATION_LINUX_TARGET="${DETOURS_QUALIFICATION_LINUX_TARGET:-devtest}"
QUALIFICATION_INTEL_MAC_TARGET="${DETOURS_QUALIFICATION_INTEL_MAC_TARGET:-wraith}"
QUALIFICATION_WINDOWS_TARGET="${DETOURS_QUALIFICATION_WINDOWS_TARGET:-detours-windows}"
QUALIFICATION_SMB_HOST="${DETOURS_QUALIFICATION_SMB_HOST:-devtest}"
QUALIFICATION_SMB_SHARE="${DETOURS_QUALIFICATION_SMB_SHARE:-Detours Qualification}"
QUALIFICATION_SMB_USER="${DETOURS_QUALIFICATION_SMB_USER:-detours-qualification}"
GROUP="all"
SMOKE_ROOT=""
FAILURE_PROVIDER=""

case "$COMMAND" in
    in-process|installed|workflow-run)
        if [[ $# -gt 0 && "$1" != --* ]]; then
            GROUP="$1"
            shift
        fi
        ;;
    installed-smoke)
        [[ $# -ge 2 && "$1" != --* && "$2" != --* ]] || \
            fail "installed-smoke requires a workflow group and context"
        GROUP="$1"
        SMOKE_ROOT="$2"
        shift 2
        ;;
    failure-probe)
        [[ $# -gt 0 && "$1" != --* ]] || fail "failure-probe requires a provider"
        FAILURE_PROVIDER="$1"
        shift
        ;;
esac

parse_options "$@"
if [[ "$COMMAND" != "installed-smoke" && "$QUALIFICATION_SMOKE_REPETITIONS" != "1" ]]; then
    fail "--smoke-repetitions is available only with installed-smoke"
fi
[[ "$QUALIFICATION_SMB_SHARE" != "." \
    && "$QUALIFICATION_SMB_SHARE" != ".." \
    && "$QUALIFICATION_SMB_SHARE" != */* ]] || \
    fail "--smb-share must be a single path component"
SMB_MOUNT_POINT="/Volumes/$QUALIFICATION_SMB_SHARE"
QUALIFICATION_TARGET_ARGUMENTS=(
    --linux-target "$QUALIFICATION_LINUX_TARGET"
    --intel-mac-target "$QUALIFICATION_INTEL_MAC_TARGET"
    --windows-target "$QUALIFICATION_WINDOWS_TARGET"
    --smb-host "$QUALIFICATION_SMB_HOST"
    --smb-share "$QUALIFICATION_SMB_SHARE"
    --smb-user "$QUALIFICATION_SMB_USER"
)

case "$COMMAND" in
    help|-h|--help)
        usage
        exit 0
        ;;
    audit-matrix)
        audit_matrix
        exit 0
        ;;
esac

require_foundry
require_command git
[[ -d "$PROJECT_DIR/.git" ]] || fail "project is not a Git worktree: $PROJECT_DIR"
QUALIFICATION_COMMIT="$(canonical_commit)"
if [[ -z "$QUALIFICATION_RUN_ID" ]]; then
    QUALIFICATION_RUN_ID="$(new_run_id)"
fi
write_command_metadata
prepare_evidence_layout
export QUALIFICATION_FAILURE_CAPTURED=0
trap 'qualification_on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

case "$COMMAND" in
    preflight) run_preflight ;;
    reset) run_reset ;;
    smb-auth) verify_smb_authentication ;;
    fixtures) run_prepare_fixtures_command ;;
    build) run_build ;;
    in-process) run_in_process "$GROUP" ;;
    installed) run_installed "$GROUP" ;;
    workflow-run) run_workflow_campaign "$GROUP" ;;
    installed-smoke) run_installed_smoke_campaign "$GROUP" "$SMOKE_ROOT" ;;
    failure-probe) run_provider_failure_probe "$FAILURE_PROVIDER" ;;
    cold-run) run_cold ;;
    soak) run_soak ;;
    report) run_report ;;
    cleanup) run_cleanup ;;
    cancel) run_cancel ;;
    run) run_all ;;
    *) fail "unknown command: $COMMAND (run '$0 help')" ;;
esac
